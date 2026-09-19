#!/usr/bin/env bash
# deployments/lib/test/deploy-testnet-bridge-portal.test.sh
#
# ZER-27 (T6): deploy-testnet.sh must prove the L2 bridge was deployed against
# Stage 1's L1 TokenPortal BEFORE it spends the one-shot wire-bridge-testnet
# call.
#
# ZeracleBridge's `portal` is a PublicImmutable written once by its constructor
# (v1-l2/contracts/zeracle-bridge/src/zeracle_bridge.nr). Deposits consume L1
# messages from it and exits message it, so a bridge paired to the wrong (or a
# zero) portal is permanently dead -- and off-sandbox there is no re-pairing
# path: redeploy-bridge.ts is only ever called by deploy-sandbox.sh. The
# existing post-wire asserts check the L1 side only (TokenPortal.l2Bridge()),
# which a zero-portal bridge passes happily.
#
# This test NEVER executes deploy-testnet.sh. It parses the script, extracts
# the single assert function, and drives THAT in a subshell against temp
# fixtures -- so it is safe to run anywhere: no RPC, no keys, no network.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-$HERE/../../testnet/deploy-testnet.sh}"
FN=assert_bridge_portal_matches

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# 1. The script still parses (the plan's `bash -n` check, folded in here so one
#    command covers both).
bash -n "$SCRIPT" || { echo "FAIL: deploy-testnet.sh is not syntactically valid"; exit 1; }

# 2. The assert function exists. Extracted rather than sourced: deploy-testnet.sh
#    runs all four stages at the bottom of the file, so sourcing it would start a
#    real Sepolia deploy.
FN_SRC=$(awk -v fn="$FN" '
  $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
  inside { print }
  inside && /^\}/ { exit }
' "$SCRIPT")
if [ -z "$FN_SRC" ]; then
  echo "FAIL: deploy-testnet.sh defines no $FN()."
  echo "      Without it, Stage 2 wires the L1 TokenPortal to whatever bridge it"
  echo "      finds -- including one deployed with a zero portal, which the"
  echo "      post-wire L1-side asserts cannot detect."
  exit 1
fi

# 3. It is actually CALLED, and before the wire step. A correct assert that runs
#    after `make wire-bridge-testnet` has already spent the one-shot call is no
#    better than no assert at all.
strip_comments() { grep -vE '^[0-9]+:[[:space:]]*#'; }
CALL_LINE=$(grep -nE "^[[:space:]]*$FN[[:space:]]" "$SCRIPT" | strip_comments | head -1 | cut -d: -f1 || true)
# Matched in COMMAND position (`make ... wire-bridge-testnet`), not anywhere the
# string appears: the assert's own failure messages name the target in prose, and
# matching those would compare the assert against itself.
WIRE_LINE=$(grep -nE '^[[:space:]]*make[[:space:]].*wire-bridge-testnet[[:space:]]*$' "$SCRIPT" | strip_comments | head -1 | cut -d: -f1 || true)
[ -n "$CALL_LINE" ] || { echo "FAIL: $FN is defined but never called."; exit 1; }
[ -n "$WIRE_LINE" ] || { echo "FAIL: no 'make ... wire-bridge-testnet' invocation found in deploy-testnet.sh."; exit 1; }
if [ "$CALL_LINE" -ge "$WIRE_LINE" ]; then
  echo "FAIL: $FN is called at line $CALL_LINE, at or after the"
  echo "      wire-bridge-testnet step at line $WIRE_LINE. The assert exists to stop"
  echo "      that call being spent on a mismatched bridge, so it must run first."
  exit 1
fi

# --- behavioural cases -----------------------------------------------------
#
# Each runs the extracted function in a subshell with a stub `fail` (the real
# one exits 1, which is the contract under test) and a temp deployment.json.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PORTAL_LC="0x$(printf '5%.0s' $(seq 40))"
PORTAL_UC=$(echo "$PORTAL_LC" | tr '[:lower:]' '[:upper:]' | sed 's/^0X/0x/')
ZERO="0x$(printf '0%.0s' $(seq 40))"

# Runs the assert with deployment.json holding $1 as .contracts.tokenBridgePortal
# (the literal "OMIT" writes the file without the field at all) and $2 as the
# Stage 1 TokenPortal. Echoes "PASS" or "FAIL:<message>".
run_case() {
  local recorded="$1" expected="$2"
  if [ "$recorded" = "OMIT" ]; then
    printf '{"contracts":{"tokenBridge":"0xabc"}}' > "$WORK/deployment.json"
  else
    printf '{"contracts":{"tokenBridge":"0xabc","tokenBridgePortal":"%s"}}' "$recorded" \
      > "$WORK/deployment.json"
  fi
  (
    cd "$WORK"
    fail() { echo "FAIL:$1"; exit 1; }
    ok()   { :; }
    step() { :; }
    eval "$FN_SRC"
    "$FN" "$expected" && echo "PASS"
  ) 2>&1
}

expect_pass() {
  local out; out=$(run_case "$1" "$2" || true)
  case "$out" in
    *PASS*) ;;
    *) echo "FAIL: expected the assert to accept recorded=$1 expected=$2, got: $out"; exit 1 ;;
  esac
}

# $4 is a substring the failure message must contain. Asserted, not optional:
# the zero-portal and missing-field branches would otherwise be invisible to
# this test -- the generic mismatch branch refuses those inputs too, so dropping
# either one keeps every case "passing" while the operator loses the only line
# telling them WHICH went wrong. These fire on a live deploy that has already
# spent Sepolia gas; "portal mismatch" sends someone hunting a stale Stage 1
# rerun when the real cause is that L1_TOKEN_PORTAL never reached deploy.ts.
expect_fail() {
  local desc="$1" recorded="$2" expected="$3" wantmsg="$4"
  local out; out=$(run_case "$recorded" "$expected" || true)
  case "$out" in
    *PASS*) echo "FAIL: $desc -- the assert accepted recorded=$recorded expected=$expected"; exit 1 ;;
    FAIL:*) ;;
    *) echo "FAIL: $desc -- expected a fail() call, got: $out"; exit 1 ;;
  esac
  case "$out" in
    *"$wantmsg"*) ;;
    *) echo "FAIL: $desc -- refused, but the message never says \"$wantmsg\". Got: $out"; exit 1 ;;
  esac
}

# a. The good case: the bridge records exactly the portal Stage 1 deployed.
expect_pass "$PORTAL_LC" "$PORTAL_LC"

# b. Casing must not matter. jq echoes deployment.json verbatim and v1-l1
#    writes its addresses through cast/forge, so the two sides are not
#    guaranteed to agree on EIP-55 checksum casing -- only on value. Every
#    other address comparison in this script lowercases both sides first.
expect_pass "$PORTAL_UC" "$PORTAL_LC"
expect_pass "$PORTAL_LC" "$PORTAL_UC"

# c. The T6 bug itself: the bridge was constructed with EthAddress.ZERO.
expect_fail "zero portal accepted" "$ZERO" "$PORTAL_LC" "ZERO L1 portal"

# d. A bridge paired to some other portal (a stale Stage 1 rerun).
expect_fail "mismatched portal accepted" "0x$(printf '6%.0s' $(seq 40))" "$PORTAL_LC" "but Stage 1 deployed TokenPortal at"

# e. deployment.json written by a v1-l2 that predates the T6 fix: no field at
#    all. jq prints "null" for a missing key, which must not read as a match.
expect_fail "missing tokenBridgePortal accepted" "OMIT" "$PORTAL_LC" "has no .contracts.tokenBridgePortal"
expect_fail "null tokenBridgePortal accepted" "null" "$PORTAL_LC" "has no .contracts.tokenBridgePortal"
expect_fail "empty tokenBridgePortal accepted" "" "$PORTAL_LC" "has no .contracts.tokenBridgePortal"

echo "deploy-testnet bridge-portal assert: ok (7 cases)"
