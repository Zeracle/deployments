#!/usr/bin/env bash
# D-b keeper: sweep -> flush -> relay (claim+retire) -> convert -> cushion.
#
# Runs on its own low-value L1 key (KEEPER_L1_PRIVATE_KEY), OUTSIDE
# chain-server (chain-server is not part of testnet — see
# feedback_chain_server_not_on_testnet). Installed on a schedule via the
# zeracle-keeper.service/.timer templates in this directory; this script
# itself is invoked directly and is never gated on any network flag.
#
# Sequence (Db-10): sweep (operator mode, everything) -> flush (parses
# FLUSH_TX) -> claim+retire relay (skipped when nothing was flushed) ->
# convert -> cushion. Every step runs regardless of an earlier step's
# outcome — the summary at the end is what tells the operator (or the
# systemd unit's exit code) whether anything genuinely failed.
#
# Env (required):
#   KEEPER_L1_PRIVATE_KEY  - a SEPARATE, low-value L1 key. NEVER the
#                            deployer key (DEPLOYER_PRIVATE_KEY /
#                            L1_DEPLOYER_PRIVATE_KEY). There is no fallback
#                            to any deployer key anywhere in this script —
#                            L1_CLAIMER_PRIVATE_KEY is set from this var
#                            explicitly, only for the claim step, so
#                            claim-fees-l1.ts's own deployer-key fallback
#                            chain is never reached.
#   V1_L2_DIR              - path to the v1-l2 checkout that has sweep-fees.ts,
#                            flush-fees.ts, claim-fees-l1.ts, and the
#                            keeper:convert / keeper:cushion package scripts.
#
# Env (passed through, unmodified, to the v1-l2 scripts — see each script's
# own header for the full list and defaults):
#   AZTEC_RPC_HOST, L1_RPC_URL (or ETH_RPC_URL), ZRCL_ADDRESS,
#   FEE_DISTRIBUTION_ADDRESS, L1_TOKEN_PORTAL, LIQUIDITY_POOL_ADDRESS,
#   FEE_CUSTODIAN_ACCOUNT_FILE (testnet only; unset = sandbox test account).
#
# Sandbox example keeper key (anvil #4 — never #0, the sequencer's key, and
# never #1/#2/#3, the deployer/guardian/governance keys):
#   KEEPER_L1_PRIVATE_KEY=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
#
# This script never echoes KEEPER_L1_PRIVATE_KEY or any other key value.
set -uo pipefail  # NOT -e: every step must run even if an earlier one failed.

if [ -z "${KEEPER_L1_PRIVATE_KEY:-}" ]; then
  echo "KEEPER_L1_PRIVATE_KEY is required (a separate, low-value L1 key —" >&2
  echo "NEVER the deployer key). Aborting before any step runs." >&2
  exit 1
fi

V1_L2_DIR="${V1_L2_DIR:?V1_L2_DIR is required (path to the v1-l2 checkout)}"

FAILS=0
SUMMARY=()

step() { echo; echo "=== $* ==="; }
record_ok()   { SUMMARY+=("$1: ok"); }
record_fail() { SUMMARY+=("$1: FAILED"); FAILS=$((FAILS + 1)); }

# --- 1. sweep (operator mode: ZRCL_ADDRESS from env, sweep everything) ------
step "sweep-fees"
if yarn --cwd "$V1_L2_DIR" tsx scripts/sweep-fees.ts --all; then
  record_ok "sweep-fees"
else
  record_fail "sweep-fees"
fi

# --- 2. flush ----------------------------------------------------------------
# Captured (not streamed) so FLUSH_TX can be parsed, then echoed verbatim so
# the operator/journal still sees the full output. pipefail is suspended
# around the capture itself: we want FLUSH_STATUS to be flush-fees.ts's own
# exit code, not a pipeline's.
step "flush-fees"
set +o pipefail
FLUSH_OUTPUT="$(yarn --cwd "$V1_L2_DIR" tsx scripts/flush-fees.ts 2>&1)"
FLUSH_STATUS=$?
set -o pipefail
echo "$FLUSH_OUTPUT"

FLUSH_TX=""
while IFS= read -r line; do
  case "$line" in
    FLUSH_TX=*) FLUSH_TX="${line#FLUSH_TX=}" ;;
  esac
done <<< "$FLUSH_OUTPUT"

if [ "$FLUSH_STATUS" -eq 0 ]; then
  record_ok "flush-fees"
else
  record_fail "flush-fees"
fi

# --- 3. claim + retire relay --------------------------------------------------
# Db-9: pass the flush tx via claim-fees-l1.ts's real --tx flag (its default
# is "scan only the latest L2 block", which would miss a flush that isn't in
# it). L1_CLAIMER_PRIVATE_KEY is set ONLY for this step, ONLY from
# KEEPER_L1_PRIVATE_KEY — claim-fees-l1.ts's own fallback chain
# (L1_CLAIMER_PRIVATE_KEY -> L1_DEPLOYER_PRIVATE_KEY -> DEPLOYER_PRIVATE_KEY)
# stays as-is, but setting it explicitly here means the keeper never falls
# through to a deployer key.
step "claim + retire relay"
if [ -n "$FLUSH_TX" ]; then
  if L1_CLAIMER_PRIVATE_KEY="$KEEPER_L1_PRIVATE_KEY" \
      yarn --cwd "$V1_L2_DIR" claim:fees --tx "$FLUSH_TX"; then
    record_ok "claim + retire relay"
  else
    record_fail "claim + retire relay"
  fi
else
  echo "flush produced no FLUSH_TX -- nothing to relay, skipping claim:fees."
  record_ok "claim + retire relay (skipped: nothing to relay)"
fi

# --- 4. convert ----------------------------------------------------------------
# convert-fees.ts (keeper:convert) resolves L1 addresses/RPC the same way
# claim-fees-l1.ts does (env first, then deployment files) and requires
# KEEPER_L1_PRIVATE_KEY itself — already in this script's environment, so it
# is passed through unmodified rather than renamed.
step "convert"
if yarn --cwd "$V1_L2_DIR" keeper:convert; then
  record_ok "convert"
else
  record_fail "convert"
fi

# --- 5. cushion ----------------------------------------------------------------
step "cushion"
if yarn --cwd "$V1_L2_DIR" keeper:cushion; then
  record_ok "cushion"
else
  record_fail "cushion"
fi

echo
echo "=== summary ==="
for line in "${SUMMARY[@]}"; do
  echo "  $line"
done

if [ "$FAILS" -gt 0 ]; then
  echo "keeper run: $FAILS step(s) failed."
  exit 1
fi
echo "keeper run: all steps ok (some may have been idle -- see the step logs above)."
