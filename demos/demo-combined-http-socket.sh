#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/sydradb"

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
ingest_socket_path = "$TMPDIR/ingest.sock"
ingest_socket_max_frame_bytes = 8388608
fsync = "none"
flush_interval_ms = 5
memtable_max_bytes = 8388608
mem_limit_bytes = 268435456
auth_token = ""
enable_influx = false
enable_prom = true
retention_days = 0
EOF

(
  cd "$TMPDIR"
  "$BIN" serve >"$TMPDIR/server.out" 2>"$TMPDIR/server.err"
) &
SERVER_PID=$!

for _ in {1..200}; do
  if [[ -S "$TMPDIR/ingest.sock" ]] && curl -sS "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

if ! curl -sS "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
  echo "combined listeners did not start" >&2
  cat "$TMPDIR/server.err" >&2 || true
  exit 1
fi

curl -sS \
  -X POST \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary '{"series":"combined.http","ts":10,"value":1.0}
' \
  "http://127.0.0.1:$PORT/api/v1/ingest"

cat <<'EOF' | "$BIN" ingest --socket "$TMPDIR/ingest.sock"
{"series":"combined.socket","ts":20,"value":2.0}
EOF

STATUS_JSON="$(curl -sS "http://127.0.0.1:$PORT/status")"
printf '%s\n' "$STATUS_JSON"

grep -q '"local_ingest_enabled":true' <<<"$STATUS_JSON"
grep -q '"local_ingest_append_points_total":1' <<<"$STATUS_JSON"

echo "CHECKPOINT combined server exposed HTTP on $PORT and socket at $TMPDIR/ingest.sock"
echo "CHECKPOINT HTTP ingest accepted combined.http"
echo "CHECKPOINT socket ingest incremented local_ingest_append_points_total"
