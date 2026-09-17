# pg_metal handoff — 2026-09-17

## Push preparation

Renamed the initial Puda prototype to `pg_metal` throughout the extension,
SQL functions/types, GUCs, native symbols, shader, source filenames, scripts,
examples, benchmarks and MIT copyright notice. The workspace folder remains
`puda`; no filesystem move is necessary to publish a repository as `pg_metal`.
This is an initial release with no compatibility migration from the unpublished
prototype. The predecessor installation remains on the host under its old name.

## Verification

The renamed native build passed on PostgreSQL 14.20 / Apple M3 Max.
Real-Metal SQL assertions passed, including NULL/bounds/batching, permissions,
RLS, transaction-local changes, and grouped/window aggregates. CPU-only SQL
assertions passed, including automatic fallback and forced-GPU errors.
The standalone benchmark passed 168 CPU/GPU differential cases, all-NULL
input and oversized-batch rejection. PostgreSQL reserves `pg_` role and schema names; test roles use
`metal_test` and `metal_test_reader_*`, and test schemas use `metal_validation`.
Package installation was staged under `build/stage` to verify renamed artifact
paths without changing existing host installations. Temporary clusters were
stopped and removed. Detailed historical performance evidence is retained in
`docs/BENCHMARKS.md`; those measurements precede the mechanical rename.

Commands: `make -j4`, `./scripts/run-local.sh test`, `make cpu-test`,
`make backend-bench`, `make install DESTDIR="$PWD/build/stage"`.

## Scope and limitations

Exact int4 filtering and count/sum/min/max, packed-array reduction, batched sum,
and CPU fallback work. Transparent planner routing, joins, other datatypes,
Linux execution and other PostgreSQL majors remain unverified or unimplemented.
Packed analytics gained about 1.9x over the CPU extension in the recorded
complete-SQL benchmark. Heap scans did not gain over the fused CPU path.
Array construction has a separate setup cost and snapshots need explicit refresh.
Metal buffers retain up to about 5 MiB/session; aggregate buffers are per group.
Cross-session concurrency, injected hardware failure and long soak were not tested.

## Git state

Prepared as the first commit on `main`. Source, scripts, docs and MIT license
are included; native binaries, generated headers, private database data and
raw benchmark output are ignored. The initial source commit is `5ad5eb6`.
The private GitHub repository is https://github.com/barretts/pg_metal;
`origin` points to that repository and `main` tracks `origin/main`.
The initial source commit was pushed and remote visibility was verified private.
