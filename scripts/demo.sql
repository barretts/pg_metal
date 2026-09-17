\pset pager off
\timing on
CREATE TABLE samples (value integer);
INSERT INTO samples
SELECT CASE WHEN i % 97 = 0 THEN NULL ELSE (i % 200000) - 100000 END
FROM generate_series(1, 1000000) AS g(i);
ANALYZE samples;

SELECT * FROM pg_metal_stats(ARRAY[NULL, -2147483648, -3, 0, 7, 2147483647]);
SELECT * FROM pg_metal_scan('samples', 'value', -50000, 50000);
SELECT count(value), sum(value), min(value), max(value)
FROM samples WHERE value >= -50000 AND value < 50000;
SELECT pg_metal_sum(value) AS gpu_eligible_sum, sum(value) AS postgres_sum FROM samples;
