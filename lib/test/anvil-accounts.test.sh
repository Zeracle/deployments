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

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
