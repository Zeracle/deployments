#!/usr/bin/env bash
# deployments/lib/test/anvil-accounts.test.sh
# ZER-50: the manifest must advertise exactly the accounts anvil unlocks.
#
# The bug this pins: deploy-sandbox.sh started anvil with `--accounts 5` while
# hardcoding all TEN standard anvil accounts (with private keys) into the
# manifest. Accounts 5-9 were published as usable and the node refused to sign
# for them — `eth_sendTransaction` returned `-32602 No Signer available`, which
# viem renders as the unhelpful "Invalid parameters were provided to the RPC
# method". The count and the list were two sources of truth; now they are one.
#
# No anvil needed: the helper is pure, and the wiring check is a static read of
# deploy-sandbox.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../anvil-accounts.sh"
DEPLOY="$HERE/../../sandbox-local/deploy-sandbox.sh"

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

[ -f "$LIB" ] || { echo "FAIL: $LIB does not exist"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

echo "TEST: the helper emits exactly the requested number of accounts"
five=$(anvil_accounts_json 5)
check "5 requested -> 5 entries"      "$(echo "$five" | jq 'length')" "5"
check "indices are 0..4"              "$(echo "$five" | jq -c '[.[].index]')" "[0,1,2,3,4]"
check "account 0 is the deployer"     "$(echo "$five" | jq -r '.[0].role')" "deployer"
check "account 0 address is anvil's"  "$(echo "$five" | jq -r '.[0].address')" "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
check "every entry has a private key" "$(echo "$five" | jq '[.[] | select(.privateKey | test("^0x[0-9a-f]{64}$"))] | length')" "5"
check "output is valid JSON"          "$(echo "$five" | jq -e 'type' >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo "TEST: a different count is honoured (the point of the fix)"
check "10 requested -> 10 entries"    "$(anvil_accounts_json 10 | jq 'length')" "10"
check "1 requested -> 1 entry"        "$(anvil_accounts_json 1 | jq 'length')" "1"

echo "TEST: an impossible count fails loudly rather than truncating silently"
if anvil_accounts_json 11 >/dev/null 2>&1; then bad "11 should fail (only 10 anvil keys are known)"; else ok "11 fails"; fi
if anvil_accounts_json 0  >/dev/null 2>&1; then bad "0 should fail"; else ok "0 fails"; fi
if anvil_accounts_json "" >/dev/null 2>&1; then bad "empty should fail"; else ok "empty fails"; fi

# The regression that matters: one variable must feed BOTH the anvil flag and
# the manifest, so they cannot drift again.
echo "TEST: deploy-sandbox.sh drives both the --accounts flag and the manifest from one variable"
check "no hardcoded 10-account array left" \
  "$(grep -c '"privateKey": "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"' "$DEPLOY" || true)" "0"
if grep -qE -- '--accounts \$\{?ANVIL_ACCOUNT_COUNT\}?' "$DEPLOY"; then
  ok "--accounts reads ANVIL_ACCOUNT_COUNT"
else
  bad "--accounts does not read ANVIL_ACCOUNT_COUNT (hardcoded count?)"
fi
if grep -qE 'anvil_accounts_json "?\$\{?ANVIL_ACCOUNT_COUNT\}?"?' "$DEPLOY"; then
  ok "the manifest is built from the same variable"
else
  bad "the manifest does not call anvil_accounts_json with ANVIL_ACCOUNT_COUNT"
fi
if grep -q 'anvil-accounts.sh' "$DEPLOY"; then ok "deploy-sandbox.sh sources the helper"; else bad "helper is not sourced"; fi

# ---------------------------------------------------------------------------
# Gaps the ZER-50 review found by mutation: each block below kills a mutant that
# the first version of this file let through.
# ---------------------------------------------------------------------------

# Mutant that survived: corrupt any key or address for indices 1-9. The suite
# checked only index 0's address and the SHAPE of the rest, leaving 90% of the
# load-bearing data unverified — and these rows are not inert: deploy-sandbox.sh
# defaults GOV_PROPOSER to anvil #2 and GOV_GUARDIAN to #3, so a plausible-looking
# wrong key ships a manifest whose keys do not control the governance roles.
echo "TEST: every address is the one its private key actually derives"
if command -v cast >/dev/null 2>&1; then
  all=$(anvil_accounts_json 10)
  mismatches=0
  for i in $(seq 0 9); do
    key=$(echo "$all" | jq -r ".[$i].privateKey")
    want=$(echo "$all" | jq -r ".[$i].address")
    got=$(cast wallet address --private-key "$key" 2>/dev/null || echo "DERIVE-FAILED")
    if [ "$(echo "$got" | tr 'A-Z' 'a-z')" != "$(echo "$want" | tr 'A-Z' 'a-z')" ]; then
      bad "index $i: key derives $got, table says $want"; mismatches=$((mismatches+1))
    fi
  done
  [ "$mismatches" -eq 0 ] && ok "all 10 keys derive their stated address"
else
  echo "  skip - cast not on PATH (foundry absent); key/address pairing unverified"
fi

# Mutant that survived: gut anvil_assert_unlocked_matches (or delete its call
# site) — nothing exercised it at all. A stubbed RPC covers it without anvil,
# the same way install-mock-feeds-chain-guard.test.sh does.
echo "TEST: anvil_assert_unlocked_matches compares against the node"
STUB_PORT=8598
if command -v lsof >/dev/null 2>&1 && lsof -i ":$STUB_PORT" >/dev/null 2>&1; then
  echo "  skip - port $STUB_PORT busy"
else
  python3 - "$STUB_PORT" <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
# Reports THREE unlocked accounts, whatever is asked.
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        json.loads(self.rfile.read(n) or b'{}')
        body = json.dumps({"jsonrpc":"2.0","id":1,"result":["0x1","0x2","0x3"]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
  STUB_PID=$!
  trap 'kill $STUB_PID 2>/dev/null || true' EXIT
  for _ in $(seq 1 40); do curl -sS -m 1 "http://127.0.0.1:$STUB_PORT" -X POST -d '{}' >/dev/null 2>&1 && break; sleep 0.1; done

  if anvil_assert_unlocked_matches "http://127.0.0.1:$STUB_PORT" 3 >/dev/null 2>&1; then
    ok "matching count passes"
  else
    bad "matching count should pass (node says 3, expected 3)"
  fi
  if anvil_assert_unlocked_matches "http://127.0.0.1:$STUB_PORT" 5 >/dev/null 2>&1; then
    bad "mismatch should FAIL (node says 3, expected 5)"
  else
    ok "mismatch fails"
  fi
  msg=$(anvil_assert_unlocked_matches "http://127.0.0.1:$STUB_PORT" 5 2>&1 || true)
  case "$msg" in
    *"No Signer available"*) ok "the error names the symptom it prevents" ;;
    *) bad "error should mention 'No Signer available', got: $msg" ;;
  esac
  kill $STUB_PID 2>/dev/null || true; trap - EXIT
fi

# Mutant that survived: drop the indent, or break the trailing comma. The wiring
# greps check shape, not output — so render the real line and parse it.
echo "TEST: the manifest's accounts line renders as valid JSON in place"
rendered=$(ACCOUNTS_JSON=$(anvil_accounts_json 5); printf '%s\n' "$ACCOUNTS_JSON" | sed '1!s/^/  /')
doc=$(printf '{\n  "accounts": %s,\n  "l1": { "chainId": 31337 }\n}\n' "$rendered")
if printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
  ok "spliced manifest parses"
  check "spliced manifest has 5 accounts" "$(printf '%s' "$doc" | jq '.accounts | length')" "5"
else
  bad "spliced manifest does not parse: $(printf '%s' "$doc" | jq . 2>&1 | head -2)"
fi

# The Critical the review found: a bad count must stop the script, not write
# `"accounts": ,` and exit 0.
echo "TEST: an unpublishable count is refused before the manifest is written"
if grep -qE 'anvil_accounts_json "\$ANVIL_ACCOUNT_COUNT" >/dev/null' "$DEPLOY"; then
  ok "deploy-sandbox.sh validates the count up front"
else
  bad "no early validation of ANVIL_ACCOUNT_COUNT in deploy-sandbox.sh"
fi
if grep -qE 'ACCOUNTS_JSON=\$\(anvil_accounts_json "\$ANVIL_ACCOUNT_COUNT"\)$' "$DEPLOY"; then
  ok "the capture has no pipe (so set -e can see it fail)"
else
  bad "the accounts capture still pipes, which hides a failure from set -e"
fi
if grep -qE 'if \[ "\$SKIP_INFRA" = false \]; then' "$DEPLOY" && grep -A2 -E 'if \[ "\$SKIP_INFRA" = false \]; then' "$DEPLOY" | grep -q anvil_assert_unlocked_matches; then
  bad "the unlocked-count guard is gated on SKIP_INFRA=false — the path where anvil is OURS"
else
  ok "the unlocked-count guard is not gated on the path that does not need it"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
