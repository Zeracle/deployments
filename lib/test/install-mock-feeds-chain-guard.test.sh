#!/usr/bin/env bash
# deployments/lib/test/install-mock-feeds-chain-guard.test.sh
# Verifies install-mock-feeds.sh refuses a non-31337 chain WITHOUT needing a
# real anvil or Sepolia RPC: a tiny python http.server stub answers
# eth_chainId with 11155111 (Sepolia) for `cast chain-id` to read.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../sandbox-local/install-mock-feeds.sh"

STUB_PORT=8597
if command -v lsof >/dev/null 2>&1 && lsof -i ":$STUB_PORT" >/dev/null 2>&1; then
  echo "FAIL: port $STUB_PORT is already in use — pick a free STUB_PORT" >&2
  exit 1
fi

python3 - "$STUB_PORT" <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('content-length', 0))
        body = json.loads(self.rfile.read(length) or b'{}')
        result = hex(11155111) if body.get('method') == 'eth_chainId' else '0x'
        resp = json.dumps({"jsonrpc": "2.0", "id": body.get("id", 1), "result": result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def log_message(self, *a): pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
PY
STUB_PID=$!

ERR_FILE=$(mktemp)
trap 'kill "$STUB_PID" 2>/dev/null || true; rm -f "$ERR_FILE"' EXIT
sleep 1

if ETH_RPC_URL="http://127.0.0.1:$STUB_PORT" bash "$SCRIPT" >/dev/null 2>"$ERR_FILE"; then
  echo "FAIL: install-mock-feeds.sh ran against a non-31337 chain"; exit 1
fi
grep -q 'refusing' "$ERR_FILE" || { echo "FAIL: wrong refusal message"; cat "$ERR_FILE"; exit 1; }
grep -q '31337' "$ERR_FILE" || { echo "FAIL: refusal message missing 31337"; cat "$ERR_FILE"; exit 1; }
echo "install-mock-feeds chain-guard test: ok"
