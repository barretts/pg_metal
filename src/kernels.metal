#include <metal_stdlib>
using namespace metal;

constant uint PG_METAL_GROUP_SIZE = 256;
constant uint PG_METAL_ITEMS_PER_THREAD = 8;

struct PgMetalParams
{
    uint n;
    uint has_lo;
    int lo;
    uint has_hi;
    int hi;
};

struct PgMetalPartial
{
    long count;
    long sum;
    int min_value;
    int max_value;
};

/* Each group writes its own partial; there are no contended global atomics. */
kernel void pg_metal_reduce_int4(device const int *values [[buffer(0)]],
                             device const uchar *valid [[buffer(1)]],
                             constant PgMetalParams &params [[buffer(2)]],
                             device PgMetalPartial *partials [[buffer(3)]],
                             uint tid [[thread_index_in_threadgroup]],
                             uint group [[threadgroup_position_in_grid]])
{
    threadgroup long counts[PG_METAL_GROUP_SIZE];
    threadgroup long sums[PG_METAL_GROUP_SIZE];
    threadgroup int minima[PG_METAL_GROUP_SIZE];
    threadgroup int maxima[PG_METAL_GROUP_SIZE];

    long count = 0;
    long sum = 0;
    int min_value = 2147483647;
    int max_value = (-2147483647 - 1);
    uint base = group * PG_METAL_GROUP_SIZE * PG_METAL_ITEMS_PER_THREAD + tid;

    for (uint k = 0; k < PG_METAL_ITEMS_PER_THREAD; k++)
    {
        uint i = base + k * PG_METAL_GROUP_SIZE;
        if (i >= params.n || !valid[i])
            continue;
        int value = values[i];
        if ((params.has_lo && value < params.lo) ||
            (params.has_hi && value >= params.hi))
            continue;
        count++;
        sum += long(value);
        min_value = min(min_value, value);
        max_value = max(max_value, value);
    }

    counts[tid] = count;
    sums[tid] = sum;
    minima[tid] = min_value;
    maxima[tid] = max_value;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = PG_METAL_GROUP_SIZE / 2; stride > 0; stride /= 2)
    {
        if (tid < stride)
        {
            counts[tid] += counts[tid + stride];
            sums[tid] += sums[tid + stride];
            minima[tid] = min(minima[tid], minima[tid + stride]);
            maxima[tid] = max(maxima[tid], maxima[tid + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0)
    {
        PgMetalPartial partial;
        partial.count = counts[0];
        partial.sum = sums[0];
        partial.min_value = minima[0];
        partial.max_value = maxima[0];
        partials[group] = partial;
    }
}
