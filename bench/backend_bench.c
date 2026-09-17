/* Standalone correctness/dispatch benchmark, independent of PostgreSQL. */
#include "../src/pg_metal_backend.h"

#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double
now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static uint32_t
random_bits(uint32_t *state)
{
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static int
same_result(const PgMetalResult *a, const PgMetalResult *b)
{
    return a->count == b->count && a->sum == b->sum &&
           a->min == b->min && a->max == b->max;
}

int
main(int argc, char **argv)
{
    const size_t sizes[] = {0, 1, 7, 255, 256, 257, 2047, 2048, 2049,
                            65536, 131072, PG_METAL_MAX_BATCH_ROWS};
    const struct { bool has_lo; int32_t lo; bool has_hi; int32_t hi; } bounds[] = {
        {false, 0, false, 0}, {true, -1000000000, true, 1000000000},
        {true, 0, false, 0}, {false, 0, true, 0},
        {true, 1, true, -1}, {true, INT32_MAX, true, INT32_MAX},
        {true, INT32_MIN, true, INT32_MIN}
    };
    int32_t *values = malloc(PG_METAL_MAX_BATCH_ROWS * sizeof(int32_t));
    uint8_t *valid = malloc(PG_METAL_MAX_BATCH_ROWS);
    uint32_t state = 0xC001D00D;
    char device[256], error[1024];
    PgMetalResult cpu, gpu;
    bool cpu_only = argc > 1 && strcmp(argv[1], "--cpu-only") == 0;
    bool available;
    size_t i, j, k;
    unsigned cases = 0;
    double cold_start;
    double cold_ms;

    if (!values || !valid)
    {
        fprintf(stderr, "Unable to allocate input buffers\n");
        return 1;
    }
    for (i = 0; i < PG_METAL_MAX_BATCH_ROWS; i++)
    {
        uint32_t bits = random_bits(&state);
        memcpy(&values[i], &bits, sizeof(bits));
        if (i % 127 == 0)
            values[i] = INT32_MAX;
        else if (i % 127 == 1)
            values[i] = INT32_MIN;
        valid[i] = (random_bits(&state) % 8 != 0);
    }

    /* Explicit int64 overflow-of-int32, NULL and half-open-bound fixtures. */
    {
        const int32_t fixture[] = {INT32_MAX, INT32_MAX, INT32_MIN, 7, -7, 2};
        const uint8_t present[] = {1, 1, 1, 0, 1, 1};
        pg_metal_cpu_reduce(fixture, present, 6, false, 0, false, 0, &cpu);
        if (cpu.count != 5 || cpu.sum != INT64_C(2147483641) ||
            cpu.min != INT32_MIN || cpu.max != INT32_MAX)
        {
            fprintf(stderr, "CPU known-result fixture failed\n");
            return 1;
        }
        pg_metal_cpu_reduce(fixture, present, 6, true, 2, true, INT32_MAX, &cpu);
        if (cpu.count != 1 || cpu.sum != 2 || cpu.min != 2 || cpu.max != 2)
        {
            fprintf(stderr, "CPU half-open-bound fixture failed\n");
            return 1;
        }
    }
    if (cpu_only)
    {
        puts("CPU known-result fixtures passed");
        free(valid);
        free(values);
        return 0;
    }

    cold_start = now_ms();
    available = pg_metal_metal_available(device, sizeof(device), error, sizeof(error));
    cold_ms = now_ms() - cold_start;
    if (!available)
    {
        fprintf(stderr, "GPU unavailable: %s (CPU fixtures passed)\n", error);
        free(valid);
        free(values);
        return 77;
    }
    printf("device=%s initialization_ms=%.3f\n", device, cold_ms);

    for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++)
    {
        for (j = 0; j < sizeof(bounds) / sizeof(bounds[0]); j++)
        {
            for (k = 0; k < 2; k++)
            {
                const uint8_t *present = k ? NULL : valid;
                pg_metal_cpu_reduce(values, present, sizes[i], bounds[j].has_lo,
                                 bounds[j].lo, bounds[j].has_hi, bounds[j].hi, &cpu);
                if (!pg_metal_metal_reduce(values, present, sizes[i], bounds[j].has_lo,
                                       bounds[j].lo, bounds[j].has_hi, bounds[j].hi,
                                       &gpu, error, sizeof(error)))
                {
                    fprintf(stderr, "GPU failure: %s\n", error);
                    return 1;
                }
                if (!same_result(&cpu, &gpu))
                {
                    fprintf(stderr, "Mismatch rows=%zu bounds=%zu valid=%zu "
                            "CPU=(%" PRId64 ",%" PRId64 ",%" PRId32 ",%" PRId32 ") "
                            "GPU=(%" PRId64 ",%" PRId64 ",%" PRId32 ",%" PRId32 ")\n",
                            sizes[i], j, k, cpu.count, cpu.sum, cpu.min, cpu.max,
                            gpu.count, gpu.sum, gpu.min, gpu.max);
                    return 1;
                }
                cases++;
            }
        }
    }

    memset(valid, 0, PG_METAL_MAX_BATCH_ROWS);
    pg_metal_cpu_reduce(values, valid, PG_METAL_MAX_BATCH_ROWS, false, 0, false, 0, &cpu);
    if (!pg_metal_metal_reduce(values, valid, PG_METAL_MAX_BATCH_ROWS, false, 0, false, 0,
                           &gpu, error, sizeof(error)) || !same_result(&cpu, &gpu))
    {
        fprintf(stderr, "All-NULL input check failed: %s\n", error);
        return 1;
    }
    if (pg_metal_metal_reduce(values, NULL, PG_METAL_MAX_BATCH_ROWS + 1, false, 0,
                          false, 0, &gpu, error, sizeof(error)))
    {
        fprintf(stderr, "Oversized GPU batch was accepted\n");
        return 1;
    }
    printf("differential_cases=%u all_null=passed oversized_rejected=passed\n", cases);

    puts("rows,cpu_ms,metal_wall_ms,metal_kernel_ms,cpu_over_metal");
    for (i = 9; i < sizeof(sizes) / sizeof(sizes[0]); i++)
    {
        const unsigned iterations = 30;
        double start, cpu_ms, wall_ms, gpu_ms = 0;
        start = now_ms();
        for (j = 0; j < iterations; j++)
            pg_metal_cpu_reduce(values, NULL, sizes[i], true, -1000000000,
                             true, 1000000000, &cpu);
        cpu_ms = (now_ms() - start) / iterations;
        start = now_ms();
        for (j = 0; j < iterations; j++)
        {
            if (!pg_metal_metal_reduce(values, NULL, sizes[i], true, -1000000000,
                                   true, 1000000000, &gpu, error, sizeof(error)))
            {
                fprintf(stderr, "Benchmark GPU failure: %s\n", error);
                return 1;
            }
            gpu_ms += gpu.gpu_ms;
        }
        wall_ms = (now_ms() - start) / iterations;
        if (!same_result(&cpu, &gpu))
        {
            fprintf(stderr, "Benchmark parity failed\n");
            return 1;
        }
        printf("%zu,%.6f,%.6f,%.6f,%.3f\n", sizes[i], cpu_ms,
                wall_ms, gpu_ms / iterations, cpu_ms / wall_ms);
    }
    free(valid);
    free(values);
    return 0;
}
