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
# FLUSH_TX) -> relay every pending flush tx (claim+retire) -> convert ->
# cushion. Every step runs regardless of an earlier step's outcome — the
# summary at the end is what tells the operator (or the systemd unit's exit
# code) whether anything genuinely failed.
#
# Pending relays (final review Important 2): a flush's L2->L1 messages can
# only be relayed once its epoch is proven on L1, which on testnet often
# takes longer than one claim wait. So every FLUSH_TX is appended to
# $KEEPER_STATE_DIR/pending-flush BEFORE the relay runs, and every run
# retries each pending hash with `claim:fees --tx <hash>`, removing a hash
# only once its claim exits 0. A failed claim keeps the hash and fails the
# relay step. The node serves message proofs for roughly 2 h only, so the
# in-run wait (KEEPER_CLAIM_WAIT_SECS) is what covers slow proving; the
# cross-run retry only helps if the next run comes inside that window.
#
# Env (required):
#   KEEPER_L1_PRIVATE_KEY  - a SEPARATE, low-value L1 key. NEVER the
#                            deployer key: this script refuses to start if it
#                            equals DEPLOYER_PRIVATE_KEY or
#                            L1_DEPLOYER_PRIVATE_KEY (when either is set;
#                            compared without echoing either value). There is
#                            no fallback to any deployer key anywhere —
#                            L1_CLAIMER_PRIVATE_KEY is set from this var
#                            explicitly, only for the relay, so
#                            claim-fees-l1.ts's own deployer-key fallback
#                            chain is never reached.
#   V1_L2_DIR              - path to the v1-l2 checkout. Every script runs
#                            with it as cwd (`yarn --cwd` for the package
#                            scripts; `cd` + `npx tsx` for sweep and flush,
#                            see v1l2_tsx below), so the default
#                            deployment.json is $V1_L2_DIR/deployment.json and
#                            the default L1 deployment files live in
#                            $V1_L2_DIR/../v1-l1/deployments/.
#   ZRCL_ADDRESS           - the deployed ZeracleToken. Required: without it
#                            sweep-fees.ts and flush-fees.ts silently fall
#                            into FIXTURE mode (test/fixtures/*).
#
# Env (optional, keeper):
#   KEEPER_STATE_DIR       - default /var/lib/zeracle-keeper (created if
#                            missing; the service template's StateDirectory=
#                            creates it too). Holds `pending-flush`, one L2 flush
#                            tx hash per line.
#   KEEPER_CLAIM_WAIT_SECS - default 5400 (90 min, inside the ~2 h proof
#                            window). Passed to claim-fees-l1.ts as
#                            CLAIM_WITNESS_TIMEOUT_SECS, per pending hash.
#
# Env contract (final review Important 3), passed through unmodified to the
# v1-l2 scripts — see each script's header for the full defaults:
#   L2 side (sweep, flush, relay):
#     AZTEC_RPC_HOST              - Aztec node RPC (default http://localhost:8080)
#     FEE_DISTRIBUTION_ADDRESS    - default: deployment.json contracts.feeDistribution
#     FEE_CUSTODIAN_ACCOUNT_FILE  - testnet: a copy of the custodian key file
#                                   deploy.ts wrote (deployments/testnet/
#                                   fee-custodian-account.json); deployment.json
#                                   must record the matching `feeCustodian`.
#                                   Unset on the sandbox (genesis test account
#                                   [1]). The custodian needs NO on-chain
#                                   deployment: it is an initializerless
#                                   account, so sweep sends from it directly
#                                   and pays through the sponsored FPC.
#     L1_TOKEN_PORTAL             - relay; default deployment.json l1.tokenPortal
#   L1 side (relay, convert, cushion):
#     L1_RPC_URL (or ETH_RPC_URL) - default http://localhost:8545
#     ETH_CHAIN_ID                - set 11155111 on testnet. claim-fees-l1.ts
#                                   signs for foundry (31337) without it;
#                                   convert/cushion build their chain from the
#                                   RPC's own chain id and refuse an ETH_CHAIN_ID
#                                   that disagrees with it.
#     L1_LIQUIDITY_POOL           - convert + cushion; default `liquidityPoolProxy`
#                                   from ../v1-l1/deployments/local.json (31337)
#                                   or local-testnet.json (11155111), chosen by
#                                   the RPC's chain id
#     L1_MOCK_DEX_AGGREGATOR      - convert; default `mockDexAggregator` from the
#                                   same file
#     L1_TREASURY, L1_COLLATERAL_RESERVE, L1_NETWORK_FUND
#                                 - convert; default deployment.json l1.*
#   No fee-token, quoter or deposit-adapter address is configured: convert
#   reads FeeFund.token() and MockDexAggregator.quoter()/pool() on-chain.
#
# Testnet env block (placeholders; fill in from v1-l2/deployment.json and
# v1-l1/deployments/local-testnet.json):
#   KEEPER_L1_PRIVATE_KEY=<separate, funded, low-value Sepolia key>
#   V1_L2_DIR=/opt/zeracle/v1-l2
#   ZRCL_ADDRESS=<deployment.json contracts.zeracleToken>
#   AZTEC_RPC_HOST=<Aztec testnet node URL>
#   L1_RPC_URL=<Sepolia RPC URL>
#   ETH_CHAIN_ID=11155111
#   FEE_CUSTODIAN_ACCOUNT_FILE=<path to the fee-custodian-account.json copy>
#   KEEPER_STATE_DIR=/var/lib/zeracle-keeper
#   KEEPER_CLAIM_WAIT_SECS=5400
# The L1_* address overrides are optional there when both deployment files
# sit where the defaults expect them.
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
: "${ZRCL_ADDRESS:?ZRCL_ADDRESS is required (the deployed ZeracleToken) — without it sweep-fees.ts and flush-fees.ts silently run in FIXTURE mode. Aborting before any step runs.}"

# Final review Minor 8: refuse to run on a deployer key. Keys are compared
# with any 0x prefix and case normalised away, and never printed.
normalize_key() {
  local k="${1#0x}"
  k="${k#0X}"
  printf '%s' "${k,,}"
}
KEEPER_KEY_NORM=$(normalize_key "$KEEPER_L1_PRIVATE_KEY")
for DEPLOYER_KEY_VAR in DEPLOYER_PRIVATE_KEY L1_DEPLOYER_PRIVATE_KEY; do
  if [ -n "${!DEPLOYER_KEY_VAR:-}" ] &&
     [ "$(normalize_key "${!DEPLOYER_KEY_VAR}")" = "$KEEPER_KEY_NORM" ]; then
    echo "KEEPER_L1_PRIVATE_KEY is the same key as $DEPLOYER_KEY_VAR. The keeper must run on its" >&2
    echo "own low-value key, never a deployer key. Aborting before any step runs." >&2
    exit 1
  fi
done
unset KEEPER_KEY_NORM DEPLOYER_KEY_VAR

KEEPER_STATE_DIR="${KEEPER_STATE_DIR:-/var/lib/zeracle-keeper}"
KEEPER_CLAIM_WAIT_SECS="${KEEPER_CLAIM_WAIT_SECS:-5400}"
PENDING_FLUSH_FILE="$KEEPER_STATE_DIR/pending-flush"
if ! mkdir -p "$KEEPER_STATE_DIR"; then
  echo "Cannot create KEEPER_STATE_DIR=$KEEPER_STATE_DIR (pending flush relays live there)." >&2
  echo "Set KEEPER_STATE_DIR to a writable directory. Aborting before any step runs." >&2
  exit 1
fi

FAILS=0
SUMMARY=()

step() { echo; echo "=== $* ==="; }
# Summary lines are always "<step>: <status>".
record()      { SUMMARY+=("$1: $2"); }
record_fail() { SUMMARY+=("$1: FAILED${2:+ ($2)}"); FAILS=$((FAILS + 1)); }

# v1l2_tsx <script> [args...]: run a v1-l2 TypeScript script from V1_L2_DIR.
# v1-l2 has no tsx dependency, so `yarn tsx …` fails with 'Command "tsx" not
# found' before the script ever runs (T12 batch C, the first real keeper run).
# Every v1-l2 package script runs through `npx tsx` instead (claim:fees,
# keeper:*), so this does the same. The scripts resolve deployment.json
# against their cwd, hence the cd. The caller's environment passes through.
v1l2_tsx() { (cd "$V1_L2_DIR" && NODE_NO_WARNINGS=1 npx tsx "$@"); }

# write_pending <hash>...: atomically replace the pending file's contents.
write_pending() {
  local tmp="$PENDING_FLUSH_FILE.tmp"
  if [ "$#" -eq 0 ]; then : > "$tmp"; else printf '%s\n' "$@" > "$tmp"; fi
  mv -f "$tmp" "$PENDING_FLUSH_FILE"
}

# --- 1. sweep (operator mode: ZRCL_ADDRESS from env, sweep everything) ------
step "sweep"
if v1l2_tsx scripts/sweep-fees.ts --all; then
  record "sweep" "ok"
else
  record_fail "sweep"
fi

# --- 2. flush ----------------------------------------------------------------
# Captured (not streamed) so FLUSH_TX can be parsed, then echoed verbatim so
# the operator/journal still sees the full output. pipefail is suspended
# around the capture itself: we want FLUSH_STATUS to be flush-fees.ts's own
# exit code, not a pipeline's.
step "flush"
set +o pipefail
FLUSH_OUTPUT="$(v1l2_tsx scripts/flush-fees.ts 2>&1)"
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
  record "flush" "ok"
else
  record_fail "flush"
fi

# Every pending hash, oldest first; this run's FLUSH_TX is appended (once)
# and persisted BEFORE the relay, so a crash mid-claim still leaves it pending.
PENDING=()
if [ -f "$PENDING_FLUSH_FILE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && PENDING+=("$line")
  done < "$PENDING_FLUSH_FILE"
fi
if [ -n "$FLUSH_TX" ]; then
  ALREADY_PENDING=0
  for hash in ${PENDING[@]+"${PENDING[@]}"}; do
    [ "$hash" = "$FLUSH_TX" ] && ALREADY_PENDING=1
  done
  [ "$ALREADY_PENDING" -eq 0 ] && PENDING+=("$FLUSH_TX")
  write_pending "${PENDING[@]}"
fi

# --- 3. relay: claim + retire every pending flush tx --------------------------
# Db-9: each hash goes through claim-fees-l1.ts's real --tx flag (its default
# is "scan only the latest L2 block", which would miss an earlier flush).
# L1_CLAIMER_PRIVATE_KEY is set ONLY for this step, ONLY from
# KEEPER_L1_PRIVATE_KEY — claim-fees-l1.ts's own fallback chain
# (L1_CLAIMER_PRIVATE_KEY -> L1_DEPLOYER_PRIVATE_KEY -> DEPLOYER_PRIVATE_KEY)
# stays as-is, but setting it explicitly here means the keeper never falls
# through to a deployer key.
step "relay (claim + retire)"
if [ "${#PENDING[@]}" -eq 0 ]; then
  if [ "$FLUSH_STATUS" -ne 0 ]; then
    echo "flush failed and nothing is pending -- skipping claim:fees."
    record "relay" "skipped (flush failed)"
  else
    echo "nothing flushed and nothing pending -- nothing to relay."
    record "relay" "ok (idle: nothing to relay)"
  fi
else
  STILL_PENDING=()
  RELAYED=0
  for hash in "${PENDING[@]}"; do
    echo "relaying flush tx $hash (claim wait up to ${KEEPER_CLAIM_WAIT_SECS}s)..."
    if L1_CLAIMER_PRIVATE_KEY="$KEEPER_L1_PRIVATE_KEY" \
        CLAIM_WITNESS_TIMEOUT_SECS="$KEEPER_CLAIM_WAIT_SECS" \
        yarn --cwd "$V1_L2_DIR" claim:fees --tx "$hash"; then
      RELAYED=$((RELAYED + 1))
    else
      STILL_PENDING+=("$hash")
    fi
  done
  write_pending ${STILL_PENDING[@]+"${STILL_PENDING[@]}"}
  if [ "${#STILL_PENDING[@]}" -gt 0 ]; then
    record_fail "relay" "${#STILL_PENDING[@]} of ${#PENDING[@]} still pending in $PENDING_FLUSH_FILE, retried next run"
  elif [ "$FLUSH_STATUS" -ne 0 ]; then
    record "relay" "ok ($RELAYED relayed; flush failed)"
  else
    record "relay" "ok ($RELAYED relayed)"
  fi
fi

# --- 4. convert ----------------------------------------------------------------
# convert-fees.ts (keeper:convert) takes its chain and deployment file from
# the RPC's chain id and requires KEEPER_L1_PRIVATE_KEY itself — already in
# this script's environment, so it is passed through unmodified rather than
# renamed.
step "convert"
if yarn --cwd "$V1_L2_DIR" keeper:convert; then
  record "convert" "ok"
else
  record_fail "convert"
fi

# --- 5. cushion ----------------------------------------------------------------
step "cushion"
if yarn --cwd "$V1_L2_DIR" keeper:cushion; then
  record "cushion" "ok"
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
