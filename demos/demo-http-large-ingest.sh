#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${SYDRADB_BIN:-$ROOT/zig-out/bin/sydradb}"

if [[ ! -x "$BIN" ]]; then
  echo "expected $BIN; run 'zig build' first" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
PORT="$((20000 + RANDOM % 10000))"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

cat >"$TMPDIR/sydradb.toml" <<EOF
data_dir = "$TMPDIR/data"
http_port = $PORT
ingest_socket_path = ""
ingest_socket_max_frame_bytes = 8388608
fsync = "none"
flush_interval_ms = 5
memtable_max_bytes = 8388608
mem_limit_bytes = 536870912
auth_token = ""
enable_influx = false
enable_prom = true
retention_days = 0
EOF

python3 - <<'PY' >"$TMPDIR/body.ndjson"
for i in range(100000):
    print('{"series":"demo.http.large","ts":%d,"value":%d,"tags":{"slot":"0"}}' % (i, i))
PY

(
  cd "$TMPDIR"
  "$BIN" serve >"$TMPDIR/server.out" 2>"$TMPDIR/server.err"
) &
SERVER_PID=$!

for _ in {1..200}; do
  if curl -sS "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

if ! curl -sS "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
  echo "HTTP server did not start" >&2
  cat "$TMPDIR/server.err" >&2 || true
  exit 1
fi

RESPONSE="$(curl -sS -H 'Expect: 100-continue' -X POST --data-binary @"$TMPDIR/body.ndjson" "http://127.0.0.1:$PORT/api/v1/ingest")"
printf '%s\n' "$RESPONSE"
grep -q '"ingested":100000' <<<"$RESPONSE"

echo "CHECKPOINT live HTTP ingest accepted a large Expect: 100-continue upload on port $PORT"
echo "CHECKPOINT response reported ingested=100000"
