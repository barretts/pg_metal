#include "pg_metal_backend.h"
#include <stdio.h>

bool pg_metal_metal_available(char *device, size_t device_size, char *error, size_t error_size)
{
    if (device_size) device[0] = '\0';
    snprintf(error, error_size, "Metal requires macOS; CPU backend is available");
    return false;
}

bool pg_metal_metal_reduce(const int32_t *values, const uint8_t *valid, size_t n,
                       bool has_lo, int32_t lo, bool has_hi, int32_t hi,
                       PgMetalResult *result, char *error, size_t error_size)
{
    (void)values; (void)valid; (void)n; (void)has_lo; (void)lo;
    (void)has_hi; (void)hi; (void)result;
    snprintf(error, error_size, "Metal requires macOS; CPU backend is available");
    return false;
}
