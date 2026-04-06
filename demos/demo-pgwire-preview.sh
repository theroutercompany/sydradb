#!/usr/bin/env bash
set -euo pipefail

SYDRADB_BIN="${SYDRADB_BIN:-./zig-out/bin/sydradb}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-$((16432 + RANDOM % 1000))}"
HTTP_PORT="${HTTP_PORT:-$((18083 + RANDOM % 1000))}"
PGURI="postgresql://$PGHOST:$PGPORT/postgres?sslmode=disable"

if [[ "$SYDRADB_BIN" != /* ]]; then
  SYDRADB_BIN="$(cd "$(dirname "$SYDRADB_BIN")" && pwd)/$(basename "$SYDRADB_BIN")"
fi

if [[ ! -x "$SYDRADB_BIN" ]]; then
  echo "missing binary: $SYDRADB_BIN" >&2
  exit 1
fi

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$@"
    return
  fi
  nix shell nixpkgs#postgresql -c psql "$@"
}

wait_for_http() {
  local url="$1"
  local log_file="$2"

  for _ in $(seq 1 100); do
    if [[ -n "${server_pid:-}" ]] && ! kill -0 "$server_pid" >/dev/null 2>&1; then
      echo "seed server exited before becoming ready" >&2
      [[ -f "$log_file" ]] && cat "$log_file" >&2
      return 1
    fi
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "timed out waiting for $url" >&2
  [[ -f "$log_file" ]] && cat "$log_file" >&2
  return 1
}

post_until_contains() {
  local url="$1"
  local body="$2"
  local log_file="$3"
  shift 3

  local response=""
  for _ in $(seq 1 100); do
    response="$(curl -fsS -XPOST "$url" --data-binary "$body" 2>/dev/null || true)"

    local matched=1
    for needle in "$@"; do
      if [[ "$response" != *"$needle"* ]]; then
        matched=0
        break
      fi
    done
    if (( matched )); then
      printf '%s' "$response"
      return 0
    fi

    if [[ -n "${server_pid:-}" ]] && ! kill -0 "$server_pid" >/dev/null 2>&1; then
      echo "seed server exited before data became queryable" >&2
      [[ -f "$log_file" ]] && cat "$log_file" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "timed out waiting for expected response from $url" >&2
  [[ -f "$log_file" ]] && cat "$log_file" >&2
  return 1
}

pgwire_tcp_ready() {
  if command -v nc >/dev/null 2>&1; then
    nc -z "$PGHOST" "$PGPORT" >/dev/null 2>&1
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PGHOST" "$PGPORT" <<'PY' >/dev/null 2>&1
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
    return
  fi

  bash -c "exec 3<>/dev/tcp/$PGHOST/$PGPORT" >/dev/null 2>&1
}

wait_for_pgwire() {
  local log_file="$1"

  for _ in $(seq 1 100); do
    if [[ -n "${pgwire_pid:-}" ]] && ! kill -0 "$pgwire_pid" >/dev/null 2>&1; then
      echo "pgwire exited before becoming ready" >&2
      [[ -f "$log_file" ]] && cat "$log_file" >&2
      return 1
    fi
    if pgwire_tcp_ready; then
      return 0
    fi
    sleep 0.1
  done

  echo "timed out waiting for pgwire server" >&2
  [[ -f "$log_file" ]] && cat "$log_file" >&2
  return 1
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sydra-demo-pgwire.XXXXXX")"
cleanup() {
  if [[ -n "${pgwire_pid:-}" ]]; then
    kill "$pgwire_pid" >/dev/null 2>&1 || true
    wait "$pgwire_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

cat >"$workdir/sydradb.toml" <<EOF
data_dir = "./data"
http_port = $HTTP_PORT
fsync = "none"
flush_interval_ms = 25
memtable_max_bytes = 32768
mem_limit_bytes = 268435456
auth_token = ""
enable_influx = false
enable_prom = true
cas_mode = "dual_write"
metadata_read_mode = "primary"
query_compiler_mode = "compiled"
retention_days = 0
EOF

(cd "$workdir" && "$SYDRADB_BIN" >server.log 2>&1) &
server_pid=$!

wait_for_http "http://127.0.0.1:$HTTP_PORT/metrics" "$workdir/server.log"

curl -fsS -XPOST "http://127.0.0.1:$HTTP_PORT/api/v1/ingest" \
  --data-binary $'{"series":"ext.room1","ts":10,"value":1.0}\n{"series":"ext.room1","ts":20,"value":3.0}\n' \
  >/dev/null

seed_query="$(post_until_contains \
  "http://127.0.0.1:$HTTP_PORT/api/v1/query/range" \
  '{"series":"ext.room1","start":0,"end":30}' \
  "$workdir/server.log" \
  '"ts":10' \
  '"value":3')"

kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" >/dev/null 2>&1 || true
unset server_pid

(cd "$workdir" && "$SYDRADB_BIN" pgwire "$PGHOST" "$PGPORT" >pgwire.log 2>&1) &
pgwire_pid=$!

wait_for_pgwire "$workdir/pgwire.log"

simple_output="$(run_psql "$PGURI" -v ON_ERROR_STOP=1 -Atqc "SELECT 1")"
prepared_output="$(run_psql "$PGURI" -v ON_ERROR_STOP=1 -At <<'SQL'
SELECT time, value FROM ext.room1 WHERE time >= $1 ORDER BY time ASC LIMIT 1
\bind 0
\g
SQL
)"

if [[ "$simple_output" != "1" ]]; then
  echo "unexpected simple query output: $simple_output" >&2
  exit 1
fi

if [[ "$prepared_output" != *"1"* ]]; then
  echo "unexpected extended preview output: $prepared_output" >&2
  exit 1
fi

echo "CHECKPOINT pgwire_simple_ok $simple_output"
echo "CHECKPOINT pgwire_seed_ok $seed_query"
echo "CHECKPOINT pgwire_extended_preview_ok $prepared_output"
