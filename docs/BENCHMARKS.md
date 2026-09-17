# Measurements — 2026-09-17

Host: Apple M3 Max, arm64, macOS Darwin 25.6.0, PostgreSQL 14.20 (Homebrew),
Apple clang 17. Source: pg_metal 0.1.0 in this repository. These are local prototype
measurements, not guarantees for another workload or machine.

## Complete SQL queries

Run `make benchmark`. Each execution starts a private database cluster and
creates its own fixture tables. Both workloads use a lower-inclusive,
upper-exclusive `[-50000, 50000)` filter. All output fields match builtin
PostgreSQL aggregates. Pipeline initialization and one warm-up query per mode
are excluded. Times below are medians of warm complete SQL calls, measured
with PostgreSQL `clock_timestamp()`.

| Workload | Builtin PostgreSQL | pg_metal CPU | pg_metal Metal | CPU / Metal |
| --- | ---: | ---: | ---: | ---: |
| Heap scan: 4,000,000 rows with NULLs | 215.109 ms | 129.785 ms | 133.248 ms | 0.974× |
| Packed array: 1,048,576 integers | 124.297 ms | 1.966 ms | 1.033 ms | 1.903× |

Heap scan: five reported trials/mode, batch size 262,144; warm GPU command time
averaged 2.541 ms per query. Most execution time remains in PostgreSQL heap
scanning, SPI materialization and CPU packing. Metal was slightly slower than
the CPU extension. pg_metal's advantage over builtin SQL here comes primarily
from its fused reduction path and execution overhead, not GPU acceleration.

Packed array: ten reported trials/mode, batch size 1,048,576. The array has no
NULL bitmap, so the extension can read contiguous int4 input directly. GPU
command time averaged 0.474 ms. The complete Metal SQL call was about 1.9×
faster than the same CPU extension. Comparing to builtin `unnest` includes a
large representation/execution advantage; that 120× ratio must not be
attributed entirely to the GPU.

Building the packed table cost **324.603 ms**, measured separately and excluded
from repeated-query time. That setup cost should be amortized over repeated
queries. Both modes include array detoasting, transfers to cached shared Metal
buffers when applicable, command submission/wait, and exact CPU final merge.

Builtin parallel execution is disabled (`max_parallel_workers_per_gather=0`)
and JIT is disabled. This establishes a serial comparison, not a claim that
pg_metal beats an optimally tuned parallel PostgreSQL plan. Timing modes are run
sequentially after warming each mode; normal host scheduling still introduces
noise.

Expected heap result: count 1,979,383; sum -1,036,596; min -50,000; max 49,999.
Expected packed result: count 524,283; sum -304,355; min -50,000; max 49,999.
`bench/benchmark.sql` asserts result equality before reporting timings.
The raw local output is retained in `results/sql-benchmark.txt` (gitignored).

## Backend-only dispatch

Run `make backend-bench`. This independently checks 168 CPU/Metal input/bound
combinations, an all-NULL maximum-size input, and an oversized-batch error.
It then times 30 warm reductions on deterministic pseudorandom integers with
a `[-1000000000,1000000000)` filter.

| Rows | CPU wall | Metal wall | GPU command | CPU / Metal |
| ---: | ---: | ---: | ---: | ---: |
| 65,536 | 0.181 ms | 0.387 ms | 0.120 ms | 0.467× |
| 131,072 | 0.399 ms | 0.442 ms | 0.158 ms | 0.903× |
| 1,048,576 | 3.862 ms | 0.587 ms | 0.170 ms | 6.582× |

The final standalone run measured pipeline initialization at 41.072 ms;
earlier cold runs measured 104–131 ms. Metal wall timing includes input copies,
submission/wait, and CPU partial reduction. GPU command timing measures only
the completed GPU command. Neither is a heap-table SQL measurement.

These measurements motivated a conservative automatic threshold of 262,144
rows/batch. Actual break-even depends on predicates, data distribution,
NULLs, batch size and host load.
