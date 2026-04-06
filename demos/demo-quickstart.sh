#!/usr/bin/env bash
set -euo pipefail

SYDRADB_BIN="${SYDRADB_BIN:-./zig-out/bin/sydradb}"
PORT="${PORT:-$((18080 + RANDOM % 1000))}"

if [[ "$SYDRADB_BIN" != /* ]]; then
  SYDRADB_BIN="$(cd "$(dirname "$SYDRADB_BIN")" && pwd)/$(basename "$SYDRADB_BIN")"
fi

if [[ ! -x "$SYDRADB_BIN" ]]; then
  echo "missing binary: $SYDRADB_BIN" >&2
  exit 1
fi

wait_for_http() {
  local url="$1"
  local log_file="$2"

  for _ in $(seq 1 100); do
    if [[ -n "${server_pid:-}" ]] && ! kill -0 "$server_pid" >/dev/null 2>&1; then
      echo "server exited before becoming ready" >&2
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
      echo "server exited before data became queryable" >&2
      [[ -f "$log_file" ]] && cat "$log_file" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "timed out waiting for expected response from $url" >&2
  [[ -f "$log_file" ]] && cat "$log_file" >&2
  return 1
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sydra-demo-quickstart.XXXXXX")"
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

cat >"$workdir/sydradb.toml" <<EOF
data_dir = "./data"
http_port = $PORT
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

wait_for_http "http://127.0.0.1:$PORT/metrics" "$workdir/server.log"

curl -fsS -XPOST "http://127.0.0.1:$PORT/api/v1/ingest" \
  --data-binary $'{"series":"weather.room1","ts":1694300000,"value":24.2}\n{"series":"weather.room1","ts":1694300060,"value":24.5}\n' \
  >/tmp/sydra-demo-ingest.json

range_response="$(post_until_contains \
  "http://127.0.0.1:$PORT/api/v1/query/range" \
  '{"series":"weather.room1","start":1694300000,"end":1694300120}' \
  "$workdir/server.log" \
  "1694300000" \
  "24.5")"

sydraql_response="$(post_until_contains \
  "http://127.0.0.1:$PORT/api/v1/sydraql" \
  "select time, value from weather.room1 where time >= 0 order by time limit 10" \
  "$workdir/server.log" \
  '"rows"' \
  '"legacy_fallback":false' \
  "1694300000" \
  "24.5")"

echo "CHECKPOINT quickstart_range_ok $range_response"
echo "CHECKPOINT quickstart_sydraql_ok $sydraql_response"
