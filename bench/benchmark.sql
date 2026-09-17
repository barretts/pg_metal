\pset pager off
\timing off
SET max_parallel_workers_per_gather = 0;
SET jit = off;
CREATE UNLOGGED TABLE bench_values AS
SELECT CASE WHEN i % 97 = 0 THEN NULL ELSE (i % 200000) - 100000 END::integer AS value
FROM generate_series(1, 4000000) AS g(i);
VACUUM ANALYZE bench_values;

CREATE TEMP TABLE measurements (
    workload text, label text, trial integer, elapsed_ms double precision, gpu_ms double precision,
    backend text, count bigint, sum bigint, min integer, max integer
);

DO $$
DECLARE
    label text;
    trial integer;
    started timestamptz;
    elapsed double precision;
    r pg_metal_result;
BEGIN
    FOREACH label IN ARRAY ARRAY['postgres', 'pg_metal_cpu', 'pg_metal_metal'] LOOP
        IF label = 'pg_metal_metal' AND pg_metal_device() LIKE 'unavailable:%' THEN
            RAISE NOTICE 'Skipping forced Metal: %', pg_metal_device();
            CONTINUE;
        END IF;
        PERFORM set_config('pg_metal.backend', CASE WHEN label = 'pg_metal_metal' THEN 'metal' ELSE 'cpu' END, true);
        -- Warm the buffer cache and the Metal pipeline; trial zero is not reported.
        FOR trial IN 0..5 LOOP
            started := clock_timestamp();
            IF label = 'postgres' THEN
                SELECT count(value), sum(value), min(value), max(value)
                INTO r.count, r.sum, r.min, r.max
                FROM bench_values WHERE value >= -50000 AND value < 50000;
                r.backend := 'postgres';
                r.gpu_ms := 0;
            ELSE
                SELECT * INTO r FROM pg_metal_scan('bench_values', 'value', -50000, 50000);
            END IF;
            elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
            IF trial > 0 THEN
                INSERT INTO measurements VALUES
                    ('heap_scan', label, trial, elapsed, r.gpu_ms, r.backend, r.count, r.sum, r.min, r.max);
            END IF;
        END LOOP;
    END LOOP;
    IF (SELECT count(DISTINCT ROW(count, sum, min, max)) FROM measurements) <> 1 THEN
        RAISE EXCEPTION 'Benchmark result mismatch';
    END IF;
END $$;

-- A packed column avoids heap tuple decoding on repeated analytical queries.
-- Construction is measured separately and is not included in repeated queries.
\timing on
CREATE UNLOGGED TABLE packed_values AS
SELECT array_agg(value ORDER BY id) AS values
FROM (SELECT i AS id, ((i::bigint * 48271) % 200000 - 100000)::integer AS value
      FROM generate_series(1, 1048576) AS g(i)) AS input;
\timing off

DO $$
DECLARE
    label text;
    trial integer;
    started timestamptz;
    elapsed double precision;
    r pg_metal_result;
BEGIN
    PERFORM set_config('pg_metal.batch_rows', '1048576', true);
    FOREACH label IN ARRAY ARRAY['postgres', 'pg_metal_cpu', 'pg_metal_metal'] LOOP
        IF label = 'pg_metal_metal' AND pg_metal_device() LIKE 'unavailable:%' THEN
            CONTINUE;
        END IF;
        PERFORM set_config('pg_metal.backend', CASE WHEN label = 'pg_metal_metal' THEN 'metal' ELSE 'cpu' END, true);
        FOR trial IN 0..10 LOOP
            started := clock_timestamp();
            IF label = 'postgres' THEN
                SELECT count(value), sum(value), min(value), max(value)
                INTO r.count, r.sum, r.min, r.max
                FROM packed_values CROSS JOIN LATERAL unnest(values) AS input(value)
                WHERE value >= -50000 AND value < 50000;
                r.backend := 'postgres';
                r.gpu_ms := 0;
            ELSE
                SELECT computed.* INTO r
                FROM packed_values CROSS JOIN LATERAL pg_metal_stats(values, -50000, 50000) AS computed;
            END IF;
            elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
            IF trial > 0 THEN
                INSERT INTO measurements VALUES
                    ('packed_array', label, trial, elapsed, r.gpu_ms, r.backend, r.count, r.sum, r.min, r.max);
            END IF;
        END LOOP;
    END LOOP;
    IF (SELECT count(DISTINCT ROW(count, sum, min, max)) FROM measurements WHERE workload = 'packed_array') <> 1 THEN
        RAISE EXCEPTION 'Packed benchmark result mismatch';
    END IF;
END $$;

SELECT workload, label, count(*) AS trials,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY elapsed_ms)::numeric, 3) AS median_sql_ms,
       round(min(elapsed_ms)::numeric, 3) AS best_sql_ms,
       round(avg(gpu_ms)::numeric, 3) AS mean_kernel_ms
FROM measurements GROUP BY workload, label ORDER BY workload, label;
SELECT DISTINCT workload, backend, count, sum, min, max FROM measurements ORDER BY workload, backend;
\echo Full SQL times include heap scan, SPI tuple materialization, packing, GPU submission, and final reduction.
\echo Kernel time alone does not establish faster SQL. Parallel PostgreSQL is disabled for this serial comparison.
