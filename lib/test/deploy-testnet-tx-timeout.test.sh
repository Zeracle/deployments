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
# This test NEVER executes deploy-testnet.sh. It only parses and reads its
# source, so it is safe to run anywhere: no RPC, no keys, no network.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../testnet/deploy-testnet.sh"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# 1. The script still parses (the plan's `bash -n` check, folded in here so one
#    command covers both).
bash -n "$SCRIPT" || { echo "FAIL: deploy-testnet.sh is not syntactically valid"; exit 1; }

# 2. DEPLOY_TX_TIMEOUT_SECS is set at all.
TIMEOUT_LINES=$(grep -n 'DEPLOY_TX_TIMEOUT_SECS=' "$SCRIPT" || true)
if [ -z "$TIMEOUT_LINES" ]; then
  echo "FAIL: deploy-testnet.sh no longer sets DEPLOY_TX_TIMEOUT_SECS."
  echo "      Without it the L2 deploy falls back to the 180 s default, which the"
  echo "      Phase 2 rehearsal (~165 s message wait) very nearly exceeded."
  exit 1
fi

# 3. Every occurrence is 600 -- not 180, and not some other value.
while IFS= read -r line; do
  value=${line#*DEPLOY_TX_TIMEOUT_SECS=}
  value=${value%% *}          # drop a trailing " \" continuation
  value=${value%%\\*}         # ...and a bare trailing backslash
  if [ "$value" != "600" ]; then
    echo "FAIL: expected DEPLOY_TX_TIMEOUT_SECS=600, got '$value' at ${line%%:*}"
    exit 1
  fi
done <<< "$TIMEOUT_LINES"

# 4. It actually reaches the L2 deploy: the assignment must sit inside the
#    backslash-continued env prefix of the `yarn deploy:clean` invocation, not
#    merely somewhere in the file (a stray assignment in a comment or an
#    unrelated stage would not be exported to deploy.ts).
#    Comment lines are skipped: the Stage 2 header block above the invocation
#    describes `yarn deploy:clean` in prose, and matching that instead would
#    make this guard pass while checking nothing.
DEPLOY_BLOCK=$(awk '
  { lines[NR] = $0 }
  /yarn deploy:clean/ && $0 !~ /^[[:space:]]*#/ && !found { found = NR }
  END {
    if (!found) exit 1
    start = found
    while (start > 1 && lines[start - 1] ~ /\\[[:space:]]*$/) start--
    for (i = start; i <= found; i++) print lines[i]
  }
' "$SCRIPT") || { echo "FAIL: no 'yarn deploy:clean' invocation found in deploy-testnet.sh"; exit 1; }

if ! grep -q 'DEPLOY_TX_TIMEOUT_SECS=600' <<< "$DEPLOY_BLOCK"; then
  echo "FAIL: the 'yarn deploy:clean' invocation does not carry DEPLOY_TX_TIMEOUT_SECS=600."
  echo "      Found this env prefix:"
  sed 's/^/        /' <<< "$DEPLOY_BLOCK"
  exit 1
fi

echo "deploy-testnet DEPLOY_TX_TIMEOUT_SECS guard: ok"
