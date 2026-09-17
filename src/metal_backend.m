#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "pg_metal_backend.h"
#include "../build/pg_metal_kernels.h"

#include <limits.h>
#include <stdio.h>
#include <string.h>

enum { PG_METAL_GROUP_SIZE = 256, PG_METAL_ITEMS_PER_THREAD = 8 };

typedef struct PgMetalParams
{
    uint32_t n;
    uint32_t has_lo;
    int32_t lo;
    uint32_t has_hi;
    int32_t hi;
} PgMetalParams;

typedef struct PgMetalPartial
{
    int64_t count;
    int64_t sum;
    int32_t min_value;
    int32_t max_value;
} PgMetalPartial;

_Static_assert(sizeof(PgMetalParams) == 20, "Metal parameter layout mismatch");
_Static_assert(sizeof(PgMetalPartial) == 24, "Metal partial layout mismatch");

/* PostgreSQL backends are separate processes; initialization stays post-fork. */
static id<MTLDevice> pg_metal_device;
static id<MTLCommandQueue> pg_metal_queue;
static id<MTLComputePipelineState> pg_metal_pipeline;
static id<MTLBuffer> pg_metal_values;
static id<MTLBuffer> pg_metal_valid;
static id<MTLBuffer> pg_metal_partials;
static size_t pg_metal_capacity;
static bool pg_metal_initialized;
static char pg_metal_init_error[512];

static void
pg_metal_copy_text(char *target, size_t size, const char *source)
{
    if (target && size)
        snprintf(target, size, "%s", source ? source : "unknown Metal error");
}

static bool
pg_metal_initialize(void)
{
    NSError *error = nil;
    MTLCompileOptions *options;
    id<MTLLibrary> library;
    id<MTLFunction> function;

    if (pg_metal_initialized)
        return pg_metal_pipeline != nil;
    pg_metal_initialized = true;
    pg_metal_device = MTLCreateSystemDefaultDevice();
    if (!pg_metal_device)
    {
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       "No Metal device is accessible to this process");
        return false;
    }
    pg_metal_queue = [pg_metal_device newCommandQueue];
    if (!pg_metal_queue)
    {
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       "Metal could not create a command queue");
        return false;
    }

    options = [MTLCompileOptions new];
    if (@available(macOS 15.0, *))
        options.mathMode = MTLMathModeSafe;
    library = [pg_metal_device newLibraryWithSource:
               [NSString stringWithUTF8String:pg_metal_kernel_source]
               options:options error:&error];
    if (!library)
    {
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       error.localizedDescription.UTF8String);
        return false;
    }
    function = [library newFunctionWithName:@"pg_metal_reduce_int4"];
    if (!function)
    {
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       "Metal library is missing pg_metal_reduce_int4");
        return false;
    }
    pg_metal_pipeline = [pg_metal_device newComputePipelineStateWithFunction:function
                     error:&error];
    if (!pg_metal_pipeline)
    {
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       error.localizedDescription.UTF8String);
        return false;
    }
    if (pg_metal_pipeline.maxTotalThreadsPerThreadgroup < PG_METAL_GROUP_SIZE)
    {
        pg_metal_pipeline = nil;
        pg_metal_copy_text(pg_metal_init_error, sizeof(pg_metal_init_error),
                       "Metal device does not support 256-thread compute groups");
        return false;
    }
    return true;
}

static bool
pg_metal_ensure_capacity(size_t n, char *error, size_t error_size)
{
    size_t capacity = pg_metal_capacity ? pg_metal_capacity : 2048;
    size_t groups;
    id<MTLBuffer> values;
    id<MTLBuffer> valid;
    id<MTLBuffer> partials;

    if (n <= pg_metal_capacity)
        return true;
    while (capacity < n)
        capacity *= 2;
    groups = (capacity + PG_METAL_GROUP_SIZE * PG_METAL_ITEMS_PER_THREAD - 1) /
             (PG_METAL_GROUP_SIZE * PG_METAL_ITEMS_PER_THREAD);
    values = [pg_metal_device newBufferWithLength:capacity * sizeof(int32_t)
              options:MTLResourceStorageModeShared];
    valid = [pg_metal_device newBufferWithLength:capacity * sizeof(uint8_t)
             options:MTLResourceStorageModeShared];
    partials = [pg_metal_device newBufferWithLength:groups * sizeof(PgMetalPartial)
                options:MTLResourceStorageModeShared];
    if (!values || !valid || !partials)
    {
        pg_metal_copy_text(error, error_size, "Metal could not allocate shared buffers");
        return false;
    }
    pg_metal_values = values;
    pg_metal_valid = valid;
    pg_metal_partials = partials;
    pg_metal_capacity = capacity;
    return true;
}

bool
pg_metal_metal_available(char *device, size_t device_size,
                     char *error, size_t error_size)
{
    @autoreleasepool
    {
        pg_metal_copy_text(device, device_size, "");
        pg_metal_copy_text(error, error_size, "");
        if (!pg_metal_initialize())
        {
            pg_metal_copy_text(error, error_size, pg_metal_init_error);
            return false;
        }
        pg_metal_copy_text(device, device_size, pg_metal_device.name.UTF8String);
        return true;
    }
}

bool
pg_metal_metal_reduce(const int32_t *values, const uint8_t *valid, size_t n,
                  bool has_lo, int32_t lo, bool has_hi, int32_t hi,
                  PgMetalResult *result, char *error, size_t error_size)
{
    @autoreleasepool
    {
        PgMetalParams params;
        size_t groups;
        size_t i;
        id<MTLCommandBuffer> command;
        id<MTLComputeCommandEncoder> encoder;
        const PgMetalPartial *partials;

        *result = (PgMetalResult) {0};
        pg_metal_copy_text(error, error_size, "");
        if (n > PG_METAL_MAX_BATCH_ROWS)
        {
            pg_metal_copy_text(error, error_size, "Metal batch exceeds 1048576 rows");
            return false;
        }
        if (!pg_metal_initialize())
        {
            pg_metal_copy_text(error, error_size, pg_metal_init_error);
            return false;
        }
        if (n == 0)
            return true;
        if (!values)
        {
            pg_metal_copy_text(error, error_size, "Metal input values pointer is NULL");
            return false;
        }
        if (!pg_metal_ensure_capacity(n, error, error_size))
            return false;

        memcpy(pg_metal_values.contents, values, n * sizeof(int32_t));
        if (valid)
            memcpy(pg_metal_valid.contents, valid, n * sizeof(uint8_t));
        else
            memset(pg_metal_valid.contents, 1, n * sizeof(uint8_t));

        params = (PgMetalParams) {(uint32_t) n, has_lo, lo, has_hi, hi};
        groups = (n + PG_METAL_GROUP_SIZE * PG_METAL_ITEMS_PER_THREAD - 1) /
                 (PG_METAL_GROUP_SIZE * PG_METAL_ITEMS_PER_THREAD);
        command = [pg_metal_queue commandBuffer];
        encoder = [command computeCommandEncoder];
        if (!command || !encoder)
        {
            pg_metal_copy_text(error, error_size, "Metal could not create a compute command");
            return false;
        }
        [encoder setComputePipelineState:pg_metal_pipeline];
        [encoder setBuffer:pg_metal_values offset:0 atIndex:0];
        [encoder setBuffer:pg_metal_valid offset:0 atIndex:1];
        [encoder setBytes:&params length:sizeof(params) atIndex:2];
        [encoder setBuffer:pg_metal_partials offset:0 atIndex:3];
        [encoder dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(PG_METAL_GROUP_SIZE, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
        {
            pg_metal_copy_text(error, error_size,
                           command.error.localizedDescription.UTF8String);
            return false;
        }

        result->min = INT32_MAX;
        result->max = INT32_MIN;
        partials = pg_metal_partials.contents;
        for (i = 0; i < groups; i++)
        {
            result->count += partials[i].count;
            result->sum += partials[i].sum;
            if (partials[i].count == 0)
                continue;
            if (partials[i].min_value < result->min)
                result->min = partials[i].min_value;
            if (partials[i].max_value > result->max)
                result->max = partials[i].max_value;
        }
        if (result->count == 0)
            result->min = result->max = 0;
        result->gpu_ms = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}
