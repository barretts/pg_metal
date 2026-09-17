#!/usr/bin/env bash
set -euo pipefail

# All database state belongs to this invocation; no existing service is used.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
pg_config_bin="${PG_CONFIG:-pg_config}"
pg_bin="$("$pg_config_bin" --bindir)"
mode="${1:-demo}"
case "$mode" in test|demo|benchmark) ;; *) echo "Usage: $0 [test|demo|benchmark]" >&2; exit 2 ;; esac
cluster_dir="$(mktemp -d "${TMPDIR:-/tmp}/pg_metal.XXXXXX")"
socket_dir="$cluster_dir/socket"
mkdir -m 700 "$socket_dir"
started=0
cleanup() {
    if [[ "$started" == 1 ]]; then
        if ! "$pg_bin/pg_ctl" -D "$cluster_dir/data" -m fast -w stop >/dev/null; then
            echo "Could not stop private cluster; retained its data at $cluster_dir" >&2
            return
        fi
    fi
    if [[ "${PG_METAL_KEEP_CLUSTER:-0}" == 1 ]]; then
        echo "Stopped private cluster retained at $cluster_dir"
    else
        rm -rf "$cluster_dir"
    fi
}
trap cleanup EXIT
"$pg_bin/initdb" -D "$cluster_dir/data" -A trust -U metal_test --no-locale -E UTF8 >/dev/null
# Private Unix socket only. Metal is initialized lazily in the query backend.
started=1
"$pg_bin/pg_ctl" -D "$cluster_dir/data" -l "$cluster_dir/postgres.log" \
    -o "-k $socket_dir -c listen_addresses='' -c max_connections=10 -c shared_buffers=128MB" \
    -w start >/dev/null
pg_client=("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -h "$socket_dir" -U metal_test -d postgres)
library_path="${PG_METAL_LIBRARY:-$project_dir/pg_metal}"
# Load local objects into this throwaway cluster. Normal installs use CREATE EXTENSION.
python3 - "$project_dir/sql/pg_metal--0.1.0.sql" "$cluster_dir/bootstrap.sql" "$library_path" <<'PY'
import pathlib, sys
source, target, library = sys.argv[1:]
sql = pathlib.Path(source).read_text().replace("'MODULE_PATHNAME'", "'" + library.replace("'", "''") + "'")
pathlib.Path(target).write_text(sql)
PY
"${pg_client[@]}" -q -f "$cluster_dir/bootstrap.sql"
if [[ "${PG_METAL_CHECK_INSTALLED:-0}" == 1 ]]; then
    "${pg_client[@]}" -q <<'SQL'
CREATE SCHEMA packaged;
CREATE EXTENSION pg_metal SCHEMA packaged;
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_metal';
SELECT packaged.pg_metal_device();
SET pg_metal.backend = 'metal';
SELECT * FROM packaged.pg_metal_stats(ARRAY[-2147483648, 2147483647, NULL, 5], 0, NULL);
SELECT packaged.pg_metal_sum(value) FROM unnest(ARRAY[2147483647,2147483647,NULL]) AS input(value);
DROP EXTENSION pg_metal;
DROP SCHEMA packaged;
SQL
fi
"${pg_client[@]}" -c 'SELECT version(), pg_metal_device();'
case "$mode" in
    test) "${pg_client[@]}" -f "$project_dir/scripts/test.sql" ;;
    demo) "${pg_client[@]}" -f "$project_dir/scripts/demo.sql" ;;
    benchmark)
        mkdir -p "$project_dir/results"
        "${pg_client[@]}" -f "$project_dir/bench/benchmark.sql" | tee "$project_dir/results/sql-benchmark.txt"
        ;;
esac
