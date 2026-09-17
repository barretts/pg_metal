#include "pg_metal_backend.h"

#include <limits.h>

void
pg_metal_cpu_reduce(const int32_t *values, const uint8_t *valid, size_t n,
                bool has_lo, int32_t lo, bool has_hi, int32_t hi,
                PgMetalResult *result)
{
    size_t i;

    *result = (PgMetalResult) {0};
    result->min = INT32_MAX;
    result->max = INT32_MIN;

    for (i = 0; i < n; i++)
    {
        int32_t value;

        if (valid && !valid[i])
            continue;
        value = values[i];
        if ((has_lo && value < lo) || (has_hi && value >= hi))
            continue;
        result->count++;
        result->sum += (int64_t) value;
        if (value < result->min)
            result->min = value;
        if (value > result->max)
            result->max = value;
    }

    if (result->count == 0)
        result->min = result->max = 0;
}
