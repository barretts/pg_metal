\set ON_ERROR_STOP on
\pset pager off

-- Run as the superuser of a disposable test database with PgMetal loaded. All
-- fixtures, helper functions, and the test role are rolled back at the end.
SELECT pg_metal_device() AS pg_metal_test_device,
       lower(pg_metal_device()) NOT LIKE '%unavailable%' AS pg_metal_has_metal,
       format('metal_test_reader_%s', pg_backend_pid()) AS pg_metal_test_role
\gset
\echo 'PgMetal device:' :pg_metal_test_device

BEGIN;
SET LOCAL client_min_messages = warning;
SET LOCAL pg_metal.backend = 'cpu';
SET LOCAL pg_metal.min_gpu_rows = 65536;
SET LOCAL pg_metal.batch_rows = 65536;

CREATE SCHEMA metal_validation;
CREATE SCHEMA "metal validation";

CREATE FUNCTION metal_validation.assert_result(
    test_label text,
    actual pg_metal_result,
    expected_count bigint,
    expected_sum bigint,
    expected_min integer,
    expected_max integer,
    expected_rows bigint,
    expected_backend text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(actual.count, actual.sum, actual.min, actual.max, actual.rows)
       IS DISTINCT FROM
       ROW(expected_count, expected_sum, expected_min, expected_max,
           expected_rows) THEN
        RAISE EXCEPTION '%: actual %, expected count=%, sum=%, min=%, max=%, rows=%',
            test_label, actual, expected_count, expected_sum, expected_min,
            expected_max, expected_rows;
    END IF;
    IF actual.backend IS DISTINCT FROM expected_backend THEN
        RAISE EXCEPTION '%: backend %, expected %',
            test_label, actual.backend, expected_backend;
    END IF;
    IF actual.gpu_ms IS NULL OR
       NOT (actual.gpu_ms >= 0 AND
            actual.gpu_ms < 'Infinity'::double precision) THEN
        RAISE EXCEPTION '%: invalid GPU duration %', test_label, actual.gpu_ms;
    END IF;
    IF actual.backend = 'cpu' AND actual.gpu_ms IS DISTINCT FROM 0::double precision THEN
        RAISE EXCEPTION '%: CPU execution reported GPU duration %',
            test_label, actual.gpu_ms;
    END IF;
END
$$;

CREATE FUNCTION metal_validation.check_array(
    test_label text,
    input_values integer[],
    lower_bound integer DEFAULT NULL,
    upper_bound integer DEFAULT NULL,
    expected_backend text DEFAULT 'cpu'
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual pg_metal_result;
    expected_count bigint;
    expected_sum bigint;
    expected_min integer;
    expected_max integer;
    expected_rows bigint;
BEGIN
    actual := pg_metal_stats(input_values, lower_bound, upper_bound);
    SELECT count(value), sum(value), min(value), max(value)
      INTO expected_count, expected_sum, expected_min, expected_max
      FROM unnest(input_values) AS input(value)
     WHERE (lower_bound IS NULL OR value >= lower_bound)
       AND (upper_bound IS NULL OR value < upper_bound);
    SELECT count(*) INTO expected_rows FROM unnest(input_values);
    PERFORM metal_validation.assert_result(
        test_label, actual, expected_count, expected_sum, expected_min,
        expected_max, expected_rows,
        CASE WHEN expected_rows = 0 THEN 'cpu' ELSE expected_backend END);
END
$$;

CREATE FUNCTION metal_validation.check_scan(
    test_label text,
    input_table regclass,
    input_column name,
    lower_bound integer DEFAULT NULL,
    upper_bound integer DEFAULT NULL,
    expected_backend text DEFAULT 'cpu'
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual pg_metal_result;
    expected_count bigint;
    expected_sum bigint;
    expected_min integer;
    expected_max integer;
    expected_rows bigint;
BEGIN
    actual := pg_metal_scan(input_table, input_column, lower_bound, upper_bound);
    EXECUTE format(
        'SELECT count(%1$I), sum(%1$I), min(%1$I), max(%1$I) FROM %2$s '
        'WHERE ($1 IS NULL OR %1$I >= $1) AND ($2 IS NULL OR %1$I < $2)',
        input_column, input_table)
       INTO expected_count, expected_sum, expected_min, expected_max
       USING lower_bound, upper_bound;
    -- Refer explicitly to the granted column: this also works for a role
    -- holding SELECT on one column rather than the entire table.
    EXECUTE format('SELECT count(%1$I IS NULL) FROM %2$s',
                   input_column, input_table)
       INTO expected_rows;
    PERFORM metal_validation.assert_result(
        test_label, actual, expected_count, expected_sum, expected_min,
        expected_max, expected_rows,
        CASE WHEN expected_rows = 0 THEN 'cpu' ELSE expected_backend END);
END
$$;

CREATE FUNCTION metal_validation.check_sum(
    test_label text,
    input_values integer[]
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual bigint;
    expected bigint;
BEGIN
    SELECT pg_metal_sum(value), sum(value) INTO actual, expected
      FROM unnest(input_values) AS input(value);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '%: pg_metal_sum %, builtin sum %',
            test_label, actual, expected;
    END IF;
END
$$;

-- Boundaries include the lower endpoint and exclude the upper endpoint.
SELECT metal_validation.check_array('CPU empty', ARRAY[]::integer[]);
SELECT metal_validation.check_array('CPU all NULL', ARRAY[NULL,NULL,NULL]::integer[]);
SELECT metal_validation.check_array('CPU negative extrema', ARRAY[-9,-3,-7,NULL,-1]);
SELECT metal_validation.check_array('CPU integer extrema and bigint sum',
    ARRAY['-2147483648'::integer,2147483647,2147483647,NULL]);
SELECT metal_validation.check_array('CPU bigint positive sum',
    ARRAY[2147483647,2147483647,2147483647]);
SELECT metal_validation.check_array('CPU bigint negative sum',
    ARRAY['-2147483648'::integer,'-2147483648'::integer,'-2147483648'::integer]);
SELECT metal_validation.check_array('CPU bounded', ARRAY[-2,-1,0,1,2,NULL], -1, 2);
SELECT metal_validation.check_array('CPU lower-only', ARRAY[-2,-1,0,1,2,NULL], 0, NULL);
SELECT metal_validation.check_array('CPU upper-only', ARRAY[-2,-1,0,1,2,NULL], NULL, 0);
SELECT metal_validation.check_array('CPU equal bounds', ARRAY[-2,-1,0,1,2,NULL], 1, 1);
SELECT metal_validation.check_array('CPU reversed bounds', ARRAY[-2,-1,0,1,2,NULL], 2, -2);
SELECT metal_validation.check_array('CPU no matches', ARRAY[-2,-1,0,1,2,NULL], 10, 20);
SELECT metal_validation.check_array('CPU int4 minimum bound',
    ARRAY['-2147483648'::integer,-1,0,2147483647,NULL], '-2147483648'::integer, 0);
SELECT metal_validation.check_array('CPU int4 maximum excluded',
    ARRAY['-2147483648'::integer,-1,0,2147483647,NULL], 0, 2147483647);
SELECT metal_validation.check_array('CPU multidimensional array', ARRAY[[1,NULL::integer],[3,-4]]);
SELECT metal_validation.check_array('CPU nonstandard array lower bound', '[0:3]={1,NULL,-2,4}'::integer[]);

DO $$ BEGIN
    IF pg_metal_stats(NULL::integer[]) IS DISTINCT FROM NULL::pg_metal_result THEN
        RAISE EXCEPTION 'NULL input array must return NULL';
    END IF;
    IF pg_metal_scan(NULL::regclass, 'value') IS DISTINCT FROM NULL::pg_metal_result OR
       pg_metal_scan('pg_class', NULL::name) IS DISTINCT FROM NULL::pg_metal_result THEN
        RAISE EXCEPTION 'NULL scan source or column must return NULL';
    END IF;
END $$;

SELECT metal_validation.check_sum('CPU aggregate empty', ARRAY[]::integer[]);
SELECT metal_validation.check_sum('CPU aggregate all NULL', ARRAY[NULL,NULL]::integer[]);
SELECT metal_validation.check_sum('CPU aggregate integer extrema',
    ARRAY['-2147483648'::integer,2147483647,2147483647,NULL]);

CREATE TABLE metal_validation.sample(id integer PRIMARY KEY, value integer);
INSERT INTO metal_validation.sample
SELECT i,
       CASE WHEN i % 17 = 0 THEN NULL
            WHEN i % 29 = 0 THEN '-2147483648'::integer
            WHEN i % 31 = 0 THEN 2147483647
            WHEN i % 2 = 0 THEN -i
            ELSE i END
  FROM generate_series(1, 131089) AS input(i);
CREATE TABLE metal_validation.empty(value integer);
CREATE TABLE metal_validation.all_null(value integer);
INSERT INTO metal_validation.all_null VALUES (NULL), (NULL), (NULL);
CREATE TABLE metal_validation.window_values(id integer PRIMARY KEY, value integer);
INSERT INTO metal_validation.window_values VALUES
    (1, NULL), (2, 2147483647), (3, 2147483647), (4, -1), (5, NULL),
    (6, '-2147483648'::integer), (7, 7), (8, NULL), (9, 5);

CREATE FUNCTION metal_validation.check_aggregate_shapes(test_label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    mismatched record;
BEGIN
    SELECT * INTO mismatched FROM (
        SELECT id % 7 AS bucket, pg_metal_sum(value) AS actual, sum(value) AS expected
          FROM metal_validation.sample GROUP BY id % 7
    ) AS grouped WHERE actual IS DISTINCT FROM expected LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '%: grouped aggregate mismatch %', test_label, mismatched;
    END IF;

    -- Include a group containing only NULLs, alongside ordinary groups.
    SELECT * INTO mismatched FROM (
        SELECT CASE WHEN value IS NULL THEN -1 ELSE id % 2 END AS bucket,
               pg_metal_sum(value) AS actual, sum(value) AS expected
          FROM metal_validation.window_values
         GROUP BY CASE WHEN value IS NULL THEN -1 ELSE id % 2 END
    ) AS grouped WHERE actual IS DISTINCT FROM expected LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '%: all-NULL group mismatch %', test_label, mismatched;
    END IF;

    -- Running frames reuse transition state after repeated final calls.
    -- Sliding frames also require PostgreSQL to reset/rebuild aggregate state.
    SELECT * INTO mismatched FROM (
        SELECT id,
               pg_metal_sum(value) OVER running AS actual_running,
               sum(value) OVER running AS expected_running,
               pg_metal_sum(value) OVER sliding AS actual_sliding,
               sum(value) OVER sliding AS expected_sliding
          FROM metal_validation.window_values
        WINDOW running AS (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
               sliding AS (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
    ) AS windowed
    WHERE actual_running IS DISTINCT FROM expected_running
       OR actual_sliding IS DISTINCT FROM expected_sliding LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '%: window aggregate mismatch %', test_label, mismatched;
    END IF;
END
$$;

SELECT metal_validation.check_scan('CPU empty scan', 'metal_validation.empty', 'value');
SELECT metal_validation.check_scan('CPU all NULL scan', 'metal_validation.all_null', 'value');
SELECT metal_validation.check_scan('CPU multiple scan batches', 'metal_validation.sample', 'value');
SELECT metal_validation.check_scan('CPU filtered scan batches', 'metal_validation.sample', 'value', -70000, 70000);
SELECT metal_validation.check_array('CPU multiple array batches',
    (SELECT array_agg(value ORDER BY id) FROM metal_validation.sample));

DO $$ DECLARE actual bigint; expected bigint; BEGIN
    SELECT pg_metal_sum(value), sum(value) INTO actual, expected FROM metal_validation.sample;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'CPU table aggregate %, builtin sum %', actual, expected;
    END IF;
END $$;
SELECT metal_validation.check_aggregate_shapes('CPU');

CREATE TABLE "metal validation"."odd.table" ("odd""column" integer);
INSERT INTO "metal validation"."odd.table" VALUES (-4), (0), (NULL), (4), (8);
SELECT metal_validation.check_scan('CPU quoted schema/table/column',
    '"metal validation"."odd.table"', 'odd"column', 0, 8);

CREATE TABLE metal_validation.invalid_types(
    text_value text, bigint_value bigint, numeric_value numeric);
DO $$ BEGIN
    BEGIN
        PERFORM pg_metal_scan('metal_validation.invalid_types', 'text_value');
        RAISE EXCEPTION 'Text column was accepted as int4';
    EXCEPTION WHEN datatype_mismatch THEN NULL;
    END;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.invalid_types', 'bigint_value');
        RAISE EXCEPTION 'Bigint column was accepted as int4';
    EXCEPTION WHEN datatype_mismatch THEN NULL;
    END;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.invalid_types', 'numeric_value');
        RAISE EXCEPTION 'Numeric column was accepted as int4';
    EXCEPTION WHEN datatype_mismatch THEN NULL;
    END;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.sample', 'missing_column');
        RAISE EXCEPTION 'Missing column was accepted';
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.sample', 'value); DROP TABLE metal_validation.sample; --');
        RAISE EXCEPTION 'SQL text was accepted as a column identifier';
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
END $$;

-- Invoker permissions and row-level security are checked as a role that cannot
-- bypass RLS, with permission on only the scanned int4 column.
CREATE ROLE :"pg_metal_test_role" NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE TABLE metal_validation.access_control(owner_name text, value integer, secret_value integer);
INSERT INTO metal_validation.access_control VALUES
    (:'pg_metal_test_role', 10, 1000),
    (:'pg_metal_test_role', -4, 2000),
    (:'pg_metal_test_role', NULL, 3000),
    ('another_user', 900, 4000),
    ('another_user', 500, 5000);
ALTER TABLE metal_validation.access_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE metal_validation.access_control FORCE ROW LEVEL SECURITY;
CREATE POLICY metal_validation_reader ON metal_validation.access_control
    FOR SELECT USING (owner_name = current_user);
CREATE TABLE metal_validation.denied_data(value integer);
INSERT INTO metal_validation.denied_data VALUES (100);
GRANT USAGE ON SCHEMA metal_validation TO :"pg_metal_test_role";
GRANT SELECT (value) ON metal_validation.access_control TO :"pg_metal_test_role";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA metal_validation TO :"pg_metal_test_role";

SET LOCAL ROLE :"pg_metal_test_role";
SELECT metal_validation.check_scan('CPU invoker RLS', 'metal_validation.access_control', 'value');
SELECT metal_validation.check_scan('CPU invoker RLS filtered', 'metal_validation.access_control', 'value', 0, 20);
DO $$ DECLARE actual pg_metal_result; BEGIN
    actual := pg_metal_scan('metal_validation.access_control', 'value');
    IF actual.count IS DISTINCT FROM 2::bigint OR
       actual.sum IS DISTINCT FROM 6::bigint OR
       actual.rows IS DISTINCT FROM 3::bigint THEN
        RAISE EXCEPTION 'RLS leaked rows: %', actual;
    END IF;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.denied_data', 'value');
        RAISE EXCEPTION 'Table SELECT privilege was bypassed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.access_control', 'secret_value');
        RAISE EXCEPTION 'Column SELECT privilege was bypassed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;

-- Scan visibility must match PostgreSQL after own-transaction writes, and
-- again after rolling back those writes to a savepoint.
SAVEPOINT pg_metal_visibility;
INSERT INTO metal_validation.sample VALUES (200001, 2147483647);
UPDATE metal_validation.sample SET value = '-2147483648'::integer WHERE id = 1;
DELETE FROM metal_validation.sample WHERE id = 2;
SELECT metal_validation.check_scan('CPU transaction-local changes', 'metal_validation.sample', 'value');
ROLLBACK TO SAVEPOINT pg_metal_visibility;
SELECT metal_validation.check_scan('CPU savepoint rollback visibility', 'metal_validation.sample', 'value');

SET LOCAL pg_metal.backend = 'auto';
SELECT metal_validation.check_array('Auto small array chooses CPU', ARRAY[1,NULL,-2,3]);

\if :pg_metal_has_metal
\echo 'Validating forced Metal against PostgreSQL aggregates'
SET LOCAL pg_metal.backend = 'metal';
SELECT metal_validation.check_array('Forced Metal bypasses automatic threshold',
    ARRAY[1,NULL,-2,3], NULL, NULL, 'metal');
SELECT metal_validation.check_scan('Forced Metal scan bypasses automatic threshold',
    '"metal validation"."odd.table"', 'odd"column', NULL, NULL, 'metal');
SET LOCAL pg_metal.min_gpu_rows = 0;
SELECT metal_validation.check_array('Metal empty', ARRAY[]::integer[], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal all NULL', ARRAY[NULL,NULL,NULL]::integer[], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal negative extrema', ARRAY[-9,-3,-7,NULL,-1], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal int4 extremes',
    ARRAY['-2147483648'::integer,2147483647,2147483647,NULL], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal bigint positive sum',
    ARRAY[2147483647,2147483647,2147483647], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal bigint negative sum',
    ARRAY['-2147483648'::integer,'-2147483648'::integer,'-2147483648'::integer], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal bounded', ARRAY[-2,-1,0,1,2,NULL], -1, 2, 'metal');
SELECT metal_validation.check_array('Metal lower-only', ARRAY[-2,-1,0,1,2,NULL], 0, NULL, 'metal');
SELECT metal_validation.check_array('Metal upper-only', ARRAY[-2,-1,0,1,2,NULL], NULL, 0, 'metal');
SELECT metal_validation.check_array('Metal equal bounds', ARRAY[-2,-1,0,1,2,NULL], 1, 1, 'metal');
SELECT metal_validation.check_array('Metal reversed bounds', ARRAY[-2,-1,0,1,2,NULL], 2, -2, 'metal');
SELECT metal_validation.check_array('Metal no matches', ARRAY[-2,-1,0,1,2,NULL], 10, 20, 'metal');
SELECT metal_validation.check_array('Metal minimum included',
    ARRAY['-2147483648'::integer,-1,0,2147483647,NULL], '-2147483648'::integer, 0, 'metal');
SELECT metal_validation.check_array('Metal maximum excluded',
    ARRAY['-2147483648'::integer,-1,0,2147483647,NULL], 0, 2147483647, 'metal');
SELECT metal_validation.check_array('Metal multidimensional', ARRAY[[1,NULL::integer],[3,-4]], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal nonstandard lower bound', '[0:3]={1,NULL,-2,4}'::integer[], NULL, NULL, 'metal');
SELECT metal_validation.check_array('Metal multiple array batches',
    (SELECT array_agg(value ORDER BY id) FROM metal_validation.sample), NULL, NULL, 'metal');
SELECT metal_validation.check_scan('Metal empty scan', 'metal_validation.empty', 'value', NULL, NULL, 'metal');
SELECT metal_validation.check_scan('Metal all NULL scan', 'metal_validation.all_null', 'value', NULL, NULL, 'metal');
SELECT metal_validation.check_scan('Metal multiple scan batches', 'metal_validation.sample', 'value', NULL, NULL, 'metal');
SELECT metal_validation.check_scan('Metal filtered scan batches', 'metal_validation.sample', 'value', -70000, 70000, 'metal');
SELECT metal_validation.check_scan('Metal quoted identifiers',
    '"metal validation"."odd.table"', 'odd"column', 0, 8, 'metal');
SELECT metal_validation.check_sum('Metal aggregate empty', ARRAY[]::integer[]);
SELECT metal_validation.check_sum('Metal aggregate all NULL', ARRAY[NULL,NULL]::integer[]);
SELECT metal_validation.check_sum('Metal aggregate int4 extremes',
    ARRAY['-2147483648'::integer,2147483647,2147483647,NULL]);
DO $$ DECLARE actual bigint; expected bigint; BEGIN
    SELECT pg_metal_sum(value), sum(value) INTO actual, expected FROM metal_validation.sample;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Metal table aggregate %, builtin sum %', actual, expected;
    END IF;
END $$;
SELECT metal_validation.check_aggregate_shapes('Metal');

SET LOCAL ROLE :"pg_metal_test_role";
SELECT metal_validation.check_scan('Metal invoker RLS', 'metal_validation.access_control', 'value', NULL, NULL, 'metal');
RESET ROLE;

SET LOCAL pg_metal.backend = 'auto';
SET LOCAL pg_metal.min_gpu_rows = 65536;
SELECT metal_validation.check_array('Auto GPU batches with CPU tail',
    (SELECT array_agg(value ORDER BY id) FROM metal_validation.sample), NULL, NULL, 'mixed');
SELECT metal_validation.check_scan('Auto GPU scan batches with CPU tail',
    'metal_validation.sample', 'value', NULL, NULL, 'mixed');
\else
\echo 'Metal unavailable: validating automatic CPU fallback and forced-Metal failure'
SELECT metal_validation.check_scan('Auto unavailable GPU falls back to CPU', 'metal_validation.sample', 'value');
SET LOCAL pg_metal.backend = 'metal';
DO $$ DECLARE rejected boolean := false; BEGIN
    BEGIN
        PERFORM pg_metal_stats(ARRAY[1,-2,NULL,3]);
    EXCEPTION WHEN external_routine_exception THEN rejected := true;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'Forced Metal array call succeeded without a Metal device';
    END IF;
    rejected := false;
    BEGIN
        PERFORM pg_metal_scan('metal_validation.sample', 'value');
    EXCEPTION WHEN external_routine_exception THEN rejected := true;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'Forced Metal scan succeeded without a Metal device';
    END IF;
END $$;
\endif

ROLLBACK;
\echo 'PgMetal SQL validation passed'
