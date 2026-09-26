#!/usr/bin/env bash
# deployments/lib/test/deploy-testnet-flush-minimum.test.sh
#
# ZER-178 (follow-up to ZER-32): deploy-testnet.sh must
#   1. hand Stage 2 (`yarn deploy:clean`) the owner's flush minimum -- 10 ZRCL,
#      i.e. 10e18 base units, measured across the four fee buckets combined
#      (owner decision 2026-09-26) -- with enforcement explicitly on, and
#   2. prove the deployed FeeDistribution REPORTS that minimum as enforced
#      before it spends the one-shot wire-bridge-testnet call.
#
# FeeDistribution's `minimum_batch_enforced` is a PublicImmutable written once
# by its constructor, so an unenforced (or wrongly thresholded) testnet
# FeeDistribution lets anyone force four paid L1 relays for a trivial flush
# for its whole lifetime. v1-l2/scripts/deploy.ts reads both values back from
# the contract's getters (is_minimum_batch_enforced, get_minimum_batch_amount)
# after the deploy and records them in deployment.json; this assert checks
# those recorded, chain-reported values.
#
# This test NEVER executes deploy-testnet.sh. It parses the script, extracts
# the assert function, and drives THAT in a subshell against temp fixtures --
# no RPC, no keys, no network.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-$HERE/../../testnet/deploy-testnet.sh}"
FN=assert_fee_distribution_flush_minimum
TEN_ZRCL=10000000000000000000

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

bash -n "$SCRIPT" || { echo "FAIL: deploy-testnet.sh is not syntactically valid"; exit 1; }

strip_comments() { grep -vE '^[0-9]+:[[:space:]]*#'; }

# --- 1. The threshold constant is the owner's 10 ZRCL -----------------------
CONST_LINES=$(grep -nE '^TESTNET_FLUSH_MINIMUM=' "$SCRIPT" || true)
[ "$(printf '%s' "$CONST_LINES" | grep -c .)" = "1" ] \
  || { echo "FAIL: expected exactly one top-level TESTNET_FLUSH_MINIMUM= assignment, found: ${CONST_LINES:-none}"; exit 1; }
CONST_VALUE=$(printf '%s\n' "$CONST_LINES" | sed -E 's/^[0-9]+:TESTNET_FLUSH_MINIMUM=([0-9]+).*/\1/')
[ "$CONST_VALUE" = "$TEN_ZRCL" ] \
  || { echo "FAIL: TESTNET_FLUSH_MINIMUM is '$CONST_VALUE', expected $TEN_ZRCL (10 ZRCL, owner decision 2026-09-26)"; exit 1; }

# --- 2. Stage 2 passes it (and enforcement) into yarn deploy:clean ----------
STAGE_SRC=$(awk '
  /^stage_l2_deploy\(\) \{/ { inside = 1 }
  inside { print }
  inside && /^\}/ { exit }
' "$SCRIPT")
[ -n "$STAGE_SRC" ] || { echo "FAIL: deploy-testnet.sh defines no stage_l2_deploy()"; exit 1; }
# The env-prefixed command: every line from AZTEC_RPC_HOST= down to `yarn deploy:clean`.
DEPLOY_CMD=$(printf '%s\n' "$STAGE_SRC" | awk '
  /^[[:space:]]*AZTEC_RPC_HOST=/ { inside = 1 }
  inside { print }
  inside && /yarn deploy:clean/ { exit }
')
printf '%s\n' "$DEPLOY_CMD" | grep -q 'yarn deploy:clean' \
  || { echo "FAIL: could not find the env-prefixed 'yarn deploy:clean' command in stage_l2_deploy"; exit 1; }
printf '%s\n' "$DEPLOY_CMD" | grep -qE '^[[:space:]]+ZERACLE_FLUSH_MINIMUM="\$TESTNET_FLUSH_MINIMUM"[[:space:]]*\\$' \
  || { echo "FAIL: Stage 2 does not pass ZERACLE_FLUSH_MINIMUM=\"\$TESTNET_FLUSH_MINIMUM\" to yarn deploy:clean"; exit 1; }
printf '%s\n' "$DEPLOY_CMD" | grep -qE '^[[:space:]]+ZERACLE_ENFORCE_FLUSH_MINIMUM=1[[:space:]]*\\$' \
  || { echo "FAIL: Stage 2 does not pass ZERACLE_ENFORCE_FLUSH_MINIMUM=1 to yarn deploy:clean"; exit 1; }

# --- 3. The assert exists and is called once, unconditionally, before wiring -
FN_SRC=$(awk -v fn="$FN" '
  $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
  inside { print }
  inside && /^\}/ { exit }
' "$SCRIPT")
[ -n "$FN_SRC" ] || { echo "FAIL: deploy-testnet.sh defines no $FN()"; exit 1; }

# Exactly two spaces of indentation = function-body top level (see the
# bridge-portal test for why): anything deeper means it was nested in a conditional.
CALL_LINES=$(grep -nE '^  '"$FN"'[[:space:]]+"\$TESTNET_FLUSH_MINIMUM"[[:space:]]*$' "$SCRIPT" | strip_comments || true)
CALL_COUNT=$(printf '%s' "$CALL_LINES" | grep -c . || true)
if [ "$CALL_COUNT" != "1" ]; then
  echo "FAIL: expected exactly one unconditional call of the form:"
  echo "          $FN \"\$TESTNET_FLUSH_MINIMUM\""
  echo "      found $CALL_COUNT."
  exit 1
fi
CALL_LINE=$(printf '%s\n' "$CALL_LINES" | head -1 | cut -d: -f1)
DEPLOY_LINE=$(grep -nE 'yarn deploy:clean[[:space:]]*$' "$SCRIPT" | strip_comments | head -1 | cut -d: -f1 || true)
WIRE_LINE=$(grep -nE 'wire-bridge-testnet[[:space:]]*$' "$SCRIPT" | strip_comments | head -1 | cut -d: -f1 || true)
[ -n "$DEPLOY_LINE" ] && [ -n "$WIRE_LINE" ] \
  || { echo "FAIL: could not locate the yarn deploy:clean / wire-bridge-testnet lines"; exit 1; }
if [ "$CALL_LINE" -le "$DEPLOY_LINE" ] || [ "$CALL_LINE" -ge "$WIRE_LINE" ]; then
  echo "FAIL: $FN is called at line $CALL_LINE; it must run after yarn deploy:clean"
  echo "      (line $DEPLOY_LINE) and before wire-bridge-testnet (line $WIRE_LINE)."
  exit 1
fi

# --- 4. Behaviour -------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# $1 = deployment.json body. Echoes PASS or FAIL:<message>.
run_case() {
  printf '%s' "$1" > "$WORK/deployment.json"
  (
    cd "$WORK"
    fail() { echo "FAIL:$1"; exit 1; }
    ok()   { :; }
    step() { :; }
    eval "$FN_SRC"
    if "$FN" "$TEN_ZRCL"; then echo "PASS"; fi
  ) 2>&1
}

expect_pass() {
  local desc="$1" body="$2" out
  out=$(run_case "$body" || true)
  case "$out" in
    *PASS*) ;;
    *) echo "FAIL: $desc -- expected the assert to accept, got: $out"; exit 1 ;;
  esac
}

expect_fail() {
  local desc="$1" body="$2" wantmsg="$3" out
  out=$(run_case "$body" || true)
  case "$out" in
    *PASS*) echo "FAIL: $desc -- the assert accepted: $body"; exit 1 ;;
    FAIL:*) ;;
    *) echo "FAIL: $desc -- expected a fail() call, got: $out"; exit 1 ;;
  esac
  case "$out" in
    *"$wantmsg"*) ;;
    *) echo "FAIL: $desc -- refused, but the message never says \"$wantmsg\". Got: $out"; exit 1 ;;
  esac
}

GOOD='{"feeDistributionFlushMinimumEnforced":true,"feeDistributionFlushMinimum":"10000000000000000000"}'
expect_pass "enforced at 10 ZRCL" "$GOOD"

expect_fail "unenforced accepted" \
  '{"feeDistributionFlushMinimumEnforced":false,"feeDistributionFlushMinimum":"10000000000000000000"}' \
  "NOT enforced"
# The STRING "true" is not what deploy.ts writes; a writer emitting it is broken.
expect_fail "string \"true\" accepted as enforced" \
  '{"feeDistributionFlushMinimumEnforced":"true","feeDistributionFlushMinimum":"10000000000000000000"}' \
  "NOT enforced"
expect_fail "old 1000-unit default accepted" \
  '{"feeDistributionFlushMinimumEnforced":true,"feeDistributionFlushMinimum":"1000"}' \
  "expected 10000000000000000000"
expect_fail "a larger minimum accepted" \
  '{"feeDistributionFlushMinimumEnforced":true,"feeDistributionFlushMinimum":"100000000000000000000"}' \
  "expected 10000000000000000000"
# A JSON number would lose precision in jq 1.6 (1e+19); deploy.ts writes a string.
expect_fail "numeric minimum accepted" \
  '{"feeDistributionFlushMinimumEnforced":true,"feeDistributionFlushMinimum":10000000000000000000}' \
  "expected 10000000000000000000"
expect_fail "pre-ZER-32 deployment.json accepted" \
  '{"contracts":{"feeDistribution":"0xabc"}}' \
  "predates ZER-32"
expect_fail "null fields accepted" \
  '{"feeDistributionFlushMinimumEnforced":null,"feeDistributionFlushMinimum":null}' \
  "predates ZER-32"
expect_fail "malformed deployment.json accepted" '{"feeDistribution' "not valid JSON"

echo "deploy-testnet flush-minimum assert: ok (9 cases)"
