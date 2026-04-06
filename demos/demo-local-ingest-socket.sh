#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/sydradb"

if [[ ! -x "$BIN" ]]; then
  echo "expected $BIN; run 'zig build' first" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
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
http_port = 0
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
  [[ -S "$TMPDIR/ingest.sock" ]] && break
  sleep 0.05
done

if [[ ! -S "$TMPDIR/ingest.sock" ]]; then
  echo "socket listener did not start" >&2
  cat "$TMPDIR/server.err" >&2 || true
  exit 1
fi

cat <<'EOF' | "$BIN" ingest --socket "$TMPDIR/ingest.sock"
{"series":"socket.demo","ts":10,"value":1.5}
{"metric":"socket.telemetry","ts":20,"value":2.0,"fields":{"user":0.5},"labels":{"host":"demo-1"},"kind":"gauge"}
EOF

SID="$(grep '"series":"socket.demo"' "$TMPDIR/data/series_catalog.jsonl" | sed -n 's/.*"series_id":\([0-9][0-9]*\).*/\1/p' | head -n1)"
if [[ -z "$SID" ]]; then
  echo "failed to resolve socket.demo series id" >&2
  exit 1
fi

QUERY_OUT="$(cd "$TMPDIR" && "$BIN" query "$SID" 0 100 < /dev/null)"
printf '%s\n' "$QUERY_OUT"

grep -q '^10,1.5$' <<<"$QUERY_OUT"
grep -q '"series":"socket.telemetry.user"' "$TMPDIR/data/series_catalog.jsonl"

echo "CHECKPOINT socket listener started at $TMPDIR/ingest.sock"
echo "CHECKPOINT socket ingest wrote socket.demo and socket.telemetry.user"
echo "CHECKPOINT query returned socket.demo ts=10 value=1.5"
