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
# The WHOLE call line, and exactly one of them. Matching the bare identifier
# was not enough: a tautological argument
# (`$FN "$(jq -r .bridge.l1Portal deployment.json)"`, which compares the value
# to itself and can never fail) and a `[ "${SKIP:-}" != 1 ] && ...` bypass both
# satisfied that looser form. This is still a TEXTUAL guard -- it cannot stop
# someone hoisting the call into a function that is never reached -- but it
# closes the two edits a maintainer actually makes under deploy pressure.
# Exactly two spaces, not `[[:space:]]*`: that is function-body top level
# throughout this file, so anything more means the call has been nested inside
# a conditional -- `if [ "${SKIP_T6_CHECK:-}" != 1 ]; then ...` is the edit this
# is here to refuse, and it is otherwise indistinguishable from the real thing.
CALL_LINES=$(grep -nE '^  '"$FN"'[[:space:]]+"\$TOKEN_PORTAL"[[:space:]]*$' "$SCRIPT" | strip_comments || true)
CALL_COUNT=$(printf '%s' "$CALL_LINES" | grep -c . || true)
if [ "$CALL_COUNT" != "1" ]; then
  echo "FAIL: expected exactly one call, at function-body indentation, of the form:"
  echo "          $FN \"\$TOKEN_PORTAL\""
  echo "      found $CALL_COUNT. Stage 1's portal must reach the assert unmodified,"
  echo "      on a line of its own and unconditionally, so nothing can route around it."
  exit 1
fi
CALL_LINE=$(printf '%s\n' "$CALL_LINES" | head -1 | cut -d: -f1)
# Matched in COMMAND position (`make ... wire-bridge-testnet`), not anywhere the
# string appears: the assert's own failure messages name the target in prose, and
# matching those would compare the assert against itself.
# In command position, but NOT requiring `make` at line start: collapsing the
# env prefix onto one line (`ETH_RPC_URL=... make -C ... wire-bridge-testnet`)
# is a benign refactor, and a guard that fails on correct code gets deleted.
# Requiring the target to END the line is what keeps the assert's own prose --
# which names the target three times mid-sentence -- from matching.
WIRE_LINE=$(grep -nE 'wire-bridge-testnet[[:space:]]*$' "$SCRIPT" | strip_comments | head -1 | cut -d: -f1 || true)
[ -n "$WIRE_LINE" ] || { echo "FAIL: no wire-bridge-testnet invocation found in deploy-testnet.sh."; exit 1; }
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

# MUST contain letters. An all-digit fixture makes the upper/lower pair
# byte-identical, which silently turns the two casing cases below into
# duplicates of the first and leaves the lowercasing in the assert untested --
# a mutant that drops `tr` then survives the whole suite.
PORTAL_LC="0xabcdef0123456789abcdef0123456789abcdef01"
PORTAL_UC="0xABCDEF0123456789ABCDEF0123456789ABCDEF01"
ZERO="0x$(printf '0%.0s' $(seq 40))"

# Runs the assert with deployment.json holding $1 as .bridge.l1Portal
# (the literal "OMIT" writes the file without the field at all) and $2 as the
# Stage 1 TokenPortal. Echoes "PASS" or "FAIL:<message>".
run_case() {
  local recorded="$1" expected="$2"
  if [ "$recorded" = "OMIT" ]; then
    printf '{"contracts":{"tokenBridge":"0xabc"}}' > "$WORK/deployment.json"
  elif [ "$recorded" = "JSONNULL" ]; then
    # Unquoted JSON null, which is what a writer that recorded "no portal"
    # emits -- distinct from the STRING "null" tested below.
    printf '{"bridge":{"l1Portal":null}}' > "$WORK/deployment.json"
  elif [ "$recorded" = "BADJSON" ]; then
    printf '{"bridge": {' > "$WORK/deployment.json"
  else
    printf '{"contracts":{"tokenBridge":"0xabc"},"bridge":{"l1Portal":"%s"}}' "$recorded" \
      > "$WORK/deployment.json"
  fi
  (
    cd "$WORK"
    fail() { echo "FAIL:$1"; exit 1; }
    ok()   { :; }
    step() { :; }
    eval "$FN_SRC"
    # NOT `"$FN" ... && echo PASS`: putting the call on the left of && disables
    # errexit for its whole body, so a future edit that fails a command instead
    # of calling fail() would be invisible here while aborting a real deploy.
    if "$FN" "$expected"; then echo "PASS"; fi
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
#    all. `jq '// ""'` turns both a missing key and a JSON null into the empty
#    string, so all three land in the same branch -- tested separately because
#    only the first is realistic, and the guard's own `= "null"` half is
#    otherwise unreachable defensive code.
expect_fail "missing .bridge.l1Portal accepted" "OMIT" "$PORTAL_LC" "has no .bridge.l1Portal"
expect_fail "JSON null l1Portal accepted" "JSONNULL" "$PORTAL_LC" "has no .bridge.l1Portal"
expect_fail "the string \"null\" accepted" "null" "$PORTAL_LC" "has no .bridge.l1Portal"
expect_fail "empty l1Portal accepted" "" "$PORTAL_LC" "has no .bridge.l1Portal"

# f. Stage 1's side. An empty or null TOKEN_PORTAL means deploy-bridge-testnet
#    never recorded a portal; reporting that as an L2 mismatch sends the
#    operator hunting a stale rerun when the fault is a stage earlier.
expect_fail "empty Stage 1 portal reported as an L2 mismatch" "$PORTAL_LC" "" "STAGE 1 failure"
expect_fail "null Stage 1 portal reported as an L2 mismatch" "$PORTAL_LC" "null" "STAGE 1 failure"

# g. A deployment.json that is not valid JSON at all: a named failure, not a
#    raw jq parse error mid-deploy.
expect_fail "malformed deployment.json accepted" "BADJSON" "$PORTAL_LC" "not valid JSON"

echo "deploy-testnet bridge-portal assert: ok (12 cases)"
