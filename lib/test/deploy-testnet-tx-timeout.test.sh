#!/usr/bin/env bash
# deployments/lib/test/deploy-testnet-tx-timeout.test.sh
#
# ZER-11 (c): STATIC guard on deploy-testnet.sh's Stage 2 L2 deploy.
#
# The testnet L1->L2 message wait was measured at ~165 s in the Phase 2
# rehearsal, against waitForL1ToL2Message's 180 s default budget
# (v1-l2/utils/fee_juice.ts, readDeployTxTimeoutSecs(180)) -- about 15 s of
# headroom. deploy-testnet.sh therefore passes DEPLOY_TX_TIMEOUT_SECS=600 into
# `yarn deploy:clean`. If that assignment is ever dropped, moved out of the
# invocation, or edited back down, the deploy silently reverts to the 180 s
# default and a real testnet deploy times out mid-flight -- after Stage 1 has
# already broadcast (and paid for) every L1 transaction.
#
# The same variable also caps the sandbox block-nudge wait
# (readDeployTxTimeoutSecs(60), v1-l2/utils/fee_juice.ts), so 600 raises that
# too. Harmless here: testnet mode returns from nudgeSandboxBlock before the
# wait, but anyone retuning the value should know it is not single-purpose.
#
# Cross-repo caveat: this guard asserts the deployments side only. Renaming the
# variable or changing the 180 s default in v1-l2 passes this guard while still
# breaking production. No test in this repo can catch that.
#
# This test NEVER executes deploy-testnet.sh. It only parses and reads its
# source, so it is safe to run anywhere: no RPC, no keys, no network.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-$HERE/../../testnet/deploy-testnet.sh}"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# 1. The script still parses (the plan's `bash -n` check, folded in here so one
#    command covers both).
bash -n "$SCRIPT" || { echo "FAIL: deploy-testnet.sh is not syntactically valid"; exit 1; }

# Comment lines are skipped throughout. Documenting the 180 s default in prose
# is a legitimate edit -- the sibling half of this very ticket documents
# defaults in .env.example -- and a guard that fails on correct code gets
# loosened or deleted.
strip_comments() { grep -vE '^[0-9]+:[[:space:]]*#'; }

# 2. DEPLOY_TX_TIMEOUT_SECS is set at all, in real code.
TIMEOUT_LINES=$(grep -n 'DEPLOY_TX_TIMEOUT_SECS=' "$SCRIPT" | strip_comments || true)
if [ -z "$TIMEOUT_LINES" ]; then
  echo "FAIL: deploy-testnet.sh no longer sets DEPLOY_TX_TIMEOUT_SECS."
  echo "      Without it the L2 deploy falls back to the 180 s default, which the"
  echo "      Phase 2 rehearsal (~165 s message wait) very nearly exceeded."
  exit 1
fi

# 3. Every real assignment is 600 -- not 180, and not some other value.
#    Tolerates tabs, a trailing continuation backslash and quoting; deliberately
#    does NOT tolerate an env-overridable default such as ${VAR:-600}, because
#    that would let .env silently reinstate 180.
while IFS= read -r line; do
  value=${line#*DEPLOY_TX_TIMEOUT_SECS=}
  value=${value%%[[:space:]]*}     # drop a trailing " \" / tab continuation
  value=${value%%\\*}              # ...and a bare trailing backslash
  value=${value//\"/}              # ...and surrounding quotes
  value=${value//\'/}
  if [ "$value" != "600" ]; then
    echo "FAIL: expected DEPLOY_TX_TIMEOUT_SECS=600, got '$value' at line ${line%%:*}"
    case "$value" in
      *'${'*)
        echo "      An env-overridable default is rejected on purpose: deploy-testnet.sh"
        echo "      sources .env with \`set -a\`, so it would let .env reinstate 180 s."
        ;;
    esac
    exit 1
  fi
done <<< "$TIMEOUT_LINES"

# 4. EVERY real invocation carries it. Matching `yarn deploy:clean` only where
#    it starts a command excludes both the prose comments above the Stage 2
#    block and the error-message string on the line after the invocation, so
#    each hit below is a genuine command whose env prefix must be checked. A
#    retry or stage-rerun branch added later is exactly the case where a 180 s
#    timeout bites, so a second invocation must not slip through unchecked.
INVOCATION_LINES=$(grep -nE '^[[:space:]]*yarn[[:space:]]+deploy:clean([[:space:]]|$)' "$SCRIPT" | cut -d: -f1 || true)
if [ -z "$INVOCATION_LINES" ]; then
  echo "FAIL: no 'yarn deploy:clean' command found in deploy-testnet.sh."
  echo "      Either Stage 2 no longer runs the L2 deploy, or the invocation was"
  echo "      reshaped so this guard can no longer see it. Check both."
  exit 1
fi

while IFS= read -r lineno; do
  # Walk back over the backslash-continued env prefix of this invocation.
  BLOCK=$(awk -v target="$lineno" '
    { lines[NR] = $0 }
    END {
      start = target
      while (start > 1 && lines[start - 1] ~ /\\[[:space:]]*$/) start--
      for (i = start; i <= target; i++) print lines[i]
    }
  ' "$SCRIPT")

  # Presence, not value: check 3 has already proved that every real assignment
  # in the file is exactly 600, so re-matching the literal "=600" here would
  # false-fail on a perfectly correct DEPLOY_TX_TIMEOUT_SECS="600". What this
  # check adds is that the assignment reaches THIS invocation's env prefix,
  # rather than sitting somewhere else in the file where deploy.ts never sees it.
  if ! grep -q 'DEPLOY_TX_TIMEOUT_SECS=' <<< "$BLOCK"; then
    echo "FAIL: the 'yarn deploy:clean' invocation at line $lineno does not carry"
    echo "      DEPLOY_TX_TIMEOUT_SECS in its env prefix. Found:"
    sed 's/^/        /' <<< "$BLOCK"
    exit 1
  fi
done <<< "$INVOCATION_LINES"

echo "deploy-testnet DEPLOY_TX_TIMEOUT_SECS guard: ok ($(wc -l <<< "$INVOCATION_LINES") invocation(s) checked)"
