#ifndef PG_METAL_BACKEND_H
#define PG_METAL_BACKEND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* At most 2^20 int32 values: the exact sum fits comfortably in int64. */
#define PG_METAL_MAX_BATCH_ROWS ((size_t) 1048576)

typedef struct PgMetalResult
{
    int64_t count;
    int64_t sum;
    int32_t min;
    int32_t max;
    double gpu_ms;
} PgMetalResult;

/* Lower bounds are inclusive; upper bounds are exclusive ([lo, hi)).
 * A NULL valid pointer means every value is non-NULL. */
void pg_metal_cpu_reduce(const int32_t *values, const uint8_t *valid, size_t n,
                     bool has_lo, int32_t lo, bool has_hi, int32_t hi,
                     PgMetalResult *result);

bool pg_metal_metal_available(char *device, size_t device_size,
                          char *error, size_t error_size);

/* Returns false on any GPU failure; callers may recompute on the CPU. */
bool pg_metal_metal_reduce(const int32_t *values, const uint8_t *valid, size_t n,
                       bool has_lo, int32_t lo, bool has_hi, int32_t hi,
                       PgMetalResult *result, char *error, size_t error_size);

#endif
