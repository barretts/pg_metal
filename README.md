# pg_metal — Metal analytics for PostgreSQL

pg_metal is a native PostgreSQL extension that runs exact `integer` range filtering
and count/sum/min/max reductions on an Apple GPU. It includes a streaming table
scan, a fast packed-array path, and a batched `pg_metal_sum(integer)` aggregate.
Small batches and unavailable GPUs use a CPU implementation; a forced Metal
mode proves that a query actually ran a GPU kernel.

Version 0.1.0 was built and tested on PostgreSQL 14.20, macOS, Apple M3 Max.
The packed-array SQL benchmark measured **1.033 ms on Metal versus 1.966 ms on
the extension's CPU path** for 1,048,576 integers, including detoasting, input
staging, submission, synchronization, and final reduction. Heap-table scans
still spend most of their time decoding tuples. See [the measurements](docs/BENCHMARKS.md).

## Build and try it

Requirements: PostgreSQL server headers/PGXS and `pg_config`, a C compiler,
Python 3, and the macOS SDK with Foundation and Metal. Shader compilation
happens at runtime; a separate offline Metal toolchain is unnecessary.

```sh
make -j4
make demo
make test
make cpu-test
make benchmark
make backend-bench
```

`demo`, `test`, and `benchmark` create a temporary database cluster, expose only
a private Unix socket, load the local library, and stop/delete that cluster on
exit. They need permission to use PostgreSQL shared memory and the GPU. They
never connect to an existing PostgreSQL service. `cpu-test` links the same
extension to the no-Metal backend to check fallback and explicit GPU errors.
These temporary tests create loose SQL objects; package installation uses
`CREATE EXTENSION` as below.

To retain a stopped temporary cluster for inspection:

```sh
PG_METAL_KEEP_CLUSTER=1 ./scripts/run-local.sh test
```

For another PostgreSQL installation, select its `pg_config` at build and run:

```sh
make clean
make PG_CONFIG=/path/to/pg_config
PG_CONFIG=/path/to/pg_config ./scripts/run-local.sh demo
```

On non-macOS systems, the Makefile selects the CPU-only backend. This source
path was compiled and exercised on macOS; Linux and other PostgreSQL majors
have not been verified yet.

## Install into PostgreSQL

```sh
make install
```

Then enable the extension in the database you want to query, as a database
superuser:

```sql
CREATE EXTENSION pg_metal;
SELECT pg_metal_device();              -- Apple M3 Max, or unavailable: <reason>
```

No `shared_preload_libraries` setting or server restart is needed. The library
is built for the PostgreSQL major selected by `pg_config`; rebuild it for a
different major. Existing sessions that loaded an older library need to
reconnect after a binary update.

The predecessor build was installed locally as `puda`. The renamed package is
verified independently; install it with the command above. Existing databases
are not changed by the test scripts.

## Query a table

```sql
CREATE TABLE measurements (value integer);
INSERT INTO measurements SELECT (i % 100000) - 50000
FROM generate_series(1, 1000000) AS input(i);

SELECT * FROM pg_metal_scan('measurements'::regclass, 'value'::name, -10000, 10000);
-- Equivalent result fields to:
SELECT count(value), sum(value), min(value), max(value)
FROM measurements WHERE value >= -10000 AND value < 10000;

SELECT pg_metal_sum(value) FROM measurements;
```

`pg_metal_scan` streams a single `integer` column through PostgreSQL's read-only
SPI cursor. PostgreSQL handles MVCC, table/column SELECT permissions and RLS;
the GPU performs the supplied range filter and reductions. Identifiers are
resolved through `regclass` and quoted; the API accepts no SQL fragments.
The scan uses ordinary SELECT inheritance/partition/view semantics and rejects
columns whose type is not exactly `integer` (`int4`). A `bigint`, `numeric`,
domain, or floating-point column must be handled by normal SQL first.

Call the composite-returning functions in `FROM`, as shown. Expanding
`(pg_metal_scan(...)).*` in the SELECT list can evaluate the function repeatedly.

## Query a packed analytical column

An `integer[]` without NULLs is already contiguous; pg_metal reads its data directly
instead of decoding one heap tuple per value. NULL-containing arrays use a
batched packing path. Multidimensional arrays are flattened in storage order.

```sql
SELECT * FROM pg_metal_stats(ARRAY[NULL, -3, 0, 4, 10], 0, 10);
-- count=2, sum=4, min=0, max=4, rows=5

-- Prepare a snapshot once for repeated analytical queries.
CREATE TABLE analytical_snapshot AS
SELECT array_agg(value) AS values
FROM measurements WHERE value IS NOT NULL;

SET pg_metal.batch_rows = 1048576;
SET pg_metal.backend = 'metal';
SELECT result.*
FROM analytical_snapshot
CROSS JOIN LATERAL pg_metal_stats(values, -10000, 10000) AS result;
```

An array constructed from a table is an explicit snapshot. Refresh it when
underlying rows change; pg_metal does not maintain that snapshot automatically.
Array construction is a separate cost, so packing is useful when repeated
queries amortize it. Avoid building an `array_agg` on every query just to feed
the GPU. PostgreSQL's normal array/datum size limits still apply.

## Result and backend controls

All range APIs use **`lower <= value < upper`**. A NULL bound is unbounded.
NULL values never contribute. Equal/reversed bounds produce no matches.

| Result field | Meaning |
| --- | --- |
| `count bigint` | Number of non-NULL matching values |
| `sum bigint` | Exact signed 64-bit sum; overflow raises an error |
| `min integer`, `max integer` | Exact extrema |
| `backend text` | `cpu`, `metal`, or `mixed` when batches differ |
| `rows bigint` | Input elements or visible rows, including NULLs and rejected values |
| `gpu_ms double precision` | Total GPU command execution time; zero for CPU |

Empty/all-NULL/no-match input returns count zero and NULL sum/min/max, like
PostgreSQL's corresponding aggregates. A NULL input array, relation, or column
argument returns NULL. An empty input reports `cpu` because no kernel ran.

| Setting | Default | Behavior |
| --- | --- | --- |
| `pg_metal.backend` | `auto` | `auto`, `cpu`, or `metal` |
| `pg_metal.min_gpu_rows` | `262144` | Minimum rows in a batch for automatic GPU execution |
| `pg_metal.batch_rows` | `262144` | Batch size, configurable from 256 to 1,048,576 |

In `auto`, unavailable devices and failed GPU commands recompute the batch on
CPU; further GPU attempts stop for that operation. The result reports the
backend that actually produced the data. In `metal`, every nonempty batch uses
the GPU regardless of the threshold; GPU unavailability/failure raises an
error rather than quietly falling back. Initialization is cached per session.

The first GPU call compiles its pipeline and is slower than warm calls.
Metal shared buffers are cached per backend and may retain about 5 MiB at the
largest batch size. `pg_metal_sum` also buffers per aggregate group, up to 4 MiB per
large group at the maximum batch size. Builtin `sum` is preferable for many
small groups. Window queries are supported, but sliding frames may need
recalculation because this aggregate has no inverse transition function.

## Scope and next work

This version provides explicit SQL acceleration for integer analytics. It does
not rewrite arbitrary SQL plans, accelerate joins/indexes/writes, provide a
GPU columnar storage engine, or support double-precision reductions. All GPU
entry points are `PARALLEL UNSAFE`, so they run in a normal PostgreSQL backend.
The benchmark disables parallel builtin scans for a reproducible serial
comparison; tune and compare against your actual PostgreSQL plan.

The next useful step is a planner/custom-scan integration over a columnar input
path, with cost selection informed by full query measurements. Add datatype
support only with explicit numerical and NULL semantics. Signed 64-bit Metal
arithmetic is documented for recent Apple GPU families; unsupported hardware
will fail compilation and use CPU in automatic mode.
[Apple's GPU feature table](https://developer.apple.com/metal/feature-sets/).

The source entry points are `src/pg_metal.c` (PostgreSQL integration),
`src/metal_backend.m` (device/pipeline/shared buffers), `src/kernels.metal`
(parallel exact reduction), and `src/cpu_backend.c` (fallback).
PostgreSQL documents the [SPI cursor](https://www.postgresql.org/docs/14/spi-spi-cursor-open.html)
and [extension packaging](https://www.postgresql.org/docs/14/extend-extensions.html);
Apple documents [shared storage on Apple GPUs](https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus)
and [GPU command timing](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime).
