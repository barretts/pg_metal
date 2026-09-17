CREATE TYPE pg_metal_result AS (
    count bigint,
    sum bigint,
    min integer,
    max integer,
    backend text,
    rows bigint,
    gpu_ms double precision
);

CREATE FUNCTION pg_metal_device() RETURNS text
AS 'MODULE_PATHNAME', 'pg_metal_device'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

CREATE FUNCTION pg_metal_stats(input_values integer[], lower_bound integer DEFAULT NULL,
                           upper_bound integer DEFAULT NULL)
RETURNS pg_metal_result
AS 'MODULE_PATHNAME', 'pg_metal_stats'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

CREATE FUNCTION pg_metal_scan(source regclass, value_column name,
                          lower_bound integer DEFAULT NULL,
                          upper_bound integer DEFAULT NULL)
RETURNS pg_metal_result
AS 'MODULE_PATHNAME', 'pg_metal_scan'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

CREATE FUNCTION pg_metal_sum_trans(internal, integer) RETURNS internal
AS 'MODULE_PATHNAME', 'pg_metal_sum_trans'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

CREATE FUNCTION pg_metal_sum_final(internal) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_metal_sum_final'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

CREATE AGGREGATE pg_metal_sum(integer) (
    SFUNC = pg_metal_sum_trans,
    STYPE = internal,
    FINALFUNC = pg_metal_sum_final,
    PARALLEL = UNSAFE
);

COMMENT ON FUNCTION pg_metal_scan(regclass, name, integer, integer) IS
    'Scan an integer column under invoker permissions and MVCC; GPU filter uses lower <= value < upper.';
COMMENT ON FUNCTION pg_metal_stats(integer[], integer, integer) IS
    'Exact count/sum/min/max over integer array; NULLs ignored and range is [lower, upper).';
