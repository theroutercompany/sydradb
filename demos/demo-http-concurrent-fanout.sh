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

for worker in 0 1 2 3; do
  python3 - <<PY >"$TMPDIR/body-$worker.ndjson"
start = $worker * 25
for i in range(2500):
    idx = start + (i % 25)
    print('{"series":"demo.http.fanout.%d","ts":%d,"value":%d,"tags":{"slot":"%d"}}' % (idx, ($worker * 1000000) + i, i, idx))
PY
done

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

python3 - <<'PY' "$TMPDIR" "$PORT" >"$TMPDIR/http-fanout.log"
import concurrent.futures
import http.client
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])

def upload(worker: int) -> str:
    body = (root / f"body-{worker}.ndjson").read_bytes()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    conn.request("POST", "/api/v1/ingest", body=body, headers={
        "Content-Type": "application/x-ndjson",
    })
    resp = conn.getresponse()
    payload = resp.read().decode("utf-8")
    conn.close()
    return f"{worker}:{resp.status}:{payload}"

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = sorted(pool.map(upload, range(4)))

for line in results:
    print(line)
PY

for worker in 0 1 2 3; do
  grep -q "^${worker}:200:{\"ingested\":2500}$" "$TMPDIR/http-fanout.log"
done

for _ in {1..200}; do
  STATUS_JSON="$(curl -sS "http://127.0.0.1:$PORT/status")"
  if python3 - <<'PY' "$STATUS_JSON"
import json, sys
payload = json.loads(sys.argv[1])
sys.exit(0 if payload["runtime"]["queue_depth"] == 0 else 1)
PY
  then
    break
  fi
  sleep 0.05
done

METRICS="$(curl -sS "http://127.0.0.1:$PORT/metrics")"
grep -q '^sydradb_ingest_total 10000$' <<<"$METRICS"

echo "CHECKPOINT concurrent live HTTP fanout uploads all returned ingested=2500"
echo "CHECKPOINT status drained and metrics reported ingest_total=10000 on port $PORT"
