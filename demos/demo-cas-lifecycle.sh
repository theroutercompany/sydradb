#!/usr/bin/env bash
set -euo pipefail

SYDRADB_BIN="${SYDRADB_BIN:-./zig-out/bin/sydradb}"
PORT="${PORT:-$((18082 + RANDOM % 1000))}"

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
      echo "server exited before restored data became queryable" >&2
      [[ -f "$log_file" ]] && cat "$log_file" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "timed out waiting for restored data from $url" >&2
  [[ -f "$log_file" ]] && cat "$log_file" >&2
  return 1
}

rootdir="$(mktemp -d "${TMPDIR:-/tmp}/sydra-demo-cas.XXXXXX")"
src_dir="$rootdir/source"
restore_dir="$rootdir/restore"
bundle_dir="$rootdir/bundle"
mkdir -p "$src_dir" "$restore_dir"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$rootdir"
}
trap cleanup EXIT

cat >"$src_dir/sydradb.toml" <<EOF
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

cat >"$restore_dir/sydradb.toml" <<EOF
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

(cd "$src_dir" && "$SYDRADB_BIN" >server.log 2>&1) &
server_pid=$!

wait_for_http "http://127.0.0.1:$PORT/metrics" "$src_dir/server.log"

curl -fsS -XPOST "http://127.0.0.1:$PORT/api/v1/ingest" \
  --data-binary $'{"series":"cas.demo","ts":1,"value":1.0}\n{"series":"cas.demo","ts":2,"value":2.0}\n' \
  >/dev/null

source_query="$(post_until_contains \
  "http://127.0.0.1:$PORT/api/v1/query/range" \
  '{"series":"cas.demo","start":0,"end":10}' \
  "$src_dir/server.log" \
  '"ts":1' \
  '"value":2')"

kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" >/dev/null 2>&1 || true
unset server_pid

refs_output="$(cd "$src_dir" && "$SYDRADB_BIN" cas refs 2>&1)"
log_output="$(cd "$src_dir" && "$SYDRADB_BIN" cas log 2>&1)"
(cd "$src_dir" && "$SYDRADB_BIN" cas bundle create "$bundle_dir" >/dev/null)
verify_output="$(cd "$src_dir" && "$SYDRADB_BIN" cas bundle verify "$bundle_dir" 2>&1)"
(cd "$restore_dir" && "$SYDRADB_BIN" restore "$bundle_dir" >/dev/null)

(cd "$restore_dir" && "$SYDRADB_BIN" >server.log 2>&1) &
server_pid=$!

wait_for_http "http://127.0.0.1:$PORT/metrics" "$restore_dir/server.log"

restored_query="$(post_until_contains \
  "http://127.0.0.1:$PORT/api/v1/query/range" \
  '{"series":"cas.demo","start":0,"end":10}' \
  "$restore_dir/server.log" \
  '"ts":1' \
  '"value":2')"

if [[ "$refs_output" != *"heads/main"* ]]; then
  echo "missing CAS head in refs output: $refs_output" >&2
  exit 1
fi

if [[ "$verify_output" != *"reftable_files="* ]]; then
  echo "unexpected bundle verify output: $verify_output" >&2
  exit 1
fi

if [[ "$restored_query" != *'"ts":1'* || "$restored_query" != *'"value":2'* ]]; then
  echo "unexpected restored query output: $restored_query" >&2
  exit 1
fi

echo "CHECKPOINT cas_refs_ok $refs_output"
echo "CHECKPOINT cas_log_ok $log_output"
echo "CHECKPOINT cas_source_ingest_ok $source_query"
echo "CHECKPOINT cas_restore_ok $restored_query"
