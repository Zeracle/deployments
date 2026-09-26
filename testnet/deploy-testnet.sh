#!/bin/bash
# ===========================================================================
# Zeracle Testnet Deploy
#
# Deploys Zeracle to the OFFICIAL Aztec testnet (real sequencing, proving,
# and fee infrastructure) with L1 contracts on Sepolia. "Testnet" here NEVER
# means the EC2-hosted sandbox in ../sandbox-ec2/ or the local sandbox in
# ../sandbox-local/. Sepolia chain id is 11155111; the local sandbox L1 is
# 31337 and must never be reachable via TESTNET_L1_RPC_URL — the preflight
# below guards this so a pasted mainnet/sandbox RPC can't broadcast here.
#
# Stages:
#   0. Preflight — tools, env, L1 RPC chain id, deployer balance, Aztec node
#                  reachability + version match, deployer L1 fee-asset
#                  (fee-juice token) balance. (this file, implemented)
#   1. L1 deploy — Sepolia contracts + mock tokens/feeds + bridge. (stub —
#                  Tasks 3-4 of the testnet-deploy-pipeline plan fill this in)
#   2. L2 deploy — Aztec testnet contracts + fee-juice bootstrap. (stub)
#   3. Manifest  — deployment-manifest.json + web app .env.testnet sync. (stub)
#
# Usage:
#   ./deploy-testnet.sh                  # full pipeline (asks to confirm)
#   ./deploy-testnet.sh --preflight-only # run checks only; exit 0/1, no deploy
#   ./deploy-testnet.sh --force-version  # node/SDK version mismatch -> warning
#                                        # (relaxes ONLY that gate; ZER-71)
#   ./deploy-testnet.sh --allow-unverified-fpc
#                                        # canonical SponsoredFPC preflight
#                                        # failure -> warning, and carried into
#                                        # Stage 2 (ZER-28). Separate on purpose.
#
# The HandshakeRegistry preflight (ZER-29) has no override. See README.md,
# "Deploying across a node/SDK version skew", for the runbook.
#
# Config: copy deployments/testnet/.env.example to deployments/testnet/.env
# and fill in real values. NEVER commit or ship that file — it holds a real
# Sepolia-funded private key.
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
L1_DIR="$ROOT_DIR/v1-l1"
L2_DIR="$ROOT_DIR/v1-l2"
WEB_DIR="$ROOT_DIR/interfaces/apps/web"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
warn() { echo -e "${YELLOW}  ⚠${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}"; exit 1; }

# ===========================================================================
# Arg parsing
# ===========================================================================

PREFLIGHT_ONLY=false
FORCE_VERSION=false
ALLOW_UNVERIFIED_FPC=false
for arg in "$@"; do
  case "$arg" in
    --preflight-only) PREFLIGHT_ONLY=true ;;
    --force-version) FORCE_VERSION=true ;;
    --allow-unverified-fpc) ALLOW_UNVERIFIED_FPC=true ;;
    *) fail "Unknown argument: $arg (supported: --preflight-only, --force-version, --allow-unverified-fpc)" ;;
  esac
done

# ===========================================================================
# Load config
# ===========================================================================

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  fail "$SCRIPT_DIR/.env not found. Copy $SCRIPT_DIR/.env.example to $SCRIPT_DIR/.env and fill in real values before running this script."
fi
set -a
# shellcheck disable=SC1091
. "$SCRIPT_DIR/.env"
set +a

# ZER-71: Stage 2 (v1-l2/scripts/deploy.ts) skips its own canonical-FPC abort
# when ZERACLE_ALLOW_UNVERIFIED_FPC=1. The ONLY way to grant that here is the
# --allow-unverified-fpc flag. A value left in .env (sourced with `set -a`
# above) or in the calling shell would otherwise reach `yarn deploy:clean`
# silently, with no warning and no line in the preflight summary.
unset ZERACLE_ALLOW_UNVERIFIED_FPC

: "${MIN_DEPLOYER_BALANCE_ETH:=0.5}"

# ZER-178 (ZER-32): FeeDistribution's flush_fees_to_l1 minimum, in ZRCL base
# units: 10 ZRCL = 10e18, measured across the four fee buckets combined (owner
# decision 2026-09-26). Fixed here, not read from .env: Stage 2 passes it
# inline, which overrides any ZERACLE_FLUSH_MINIMUM the sourced .env set, and
# assert_fee_distribution_flush_minimum refuses anything else afterwards.
TESTNET_FLUSH_MINIMUM=10000000000000000000

# ===========================================================================
# Stage 0: Preflight
# ===========================================================================

step "Preflight: checking required tools..."
MISSING_TOOLS=()
for tool in forge cast jq node yarn python3; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS+=("$tool")
done
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  fail "Missing required tools on PATH: ${MISSING_TOOLS[*]}. Install them and re-run."
fi
ok "forge, cast, jq, node, yarn, python3 all on PATH"

step "Preflight: checking required env vars..."
MISSING_VARS=()
[ -n "${TESTNET_L1_RPC_URL:-}" ] || MISSING_VARS+=("TESTNET_L1_RPC_URL")
[ -n "${DEPLOYER_PRIVATE_KEY:-}" ] || MISSING_VARS+=("DEPLOYER_PRIVATE_KEY")
[ -n "${AZTEC_NODE_URL:-}" ] || MISSING_VARS+=("AZTEC_NODE_URL")
[ -n "${PUBLIC_L1_RPC:-}" ] || MISSING_VARS+=("PUBLIC_L1_RPC")
if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  fail "Missing required env vars in $SCRIPT_DIR/.env: ${MISSING_VARS[*]}. See $SCRIPT_DIR/.env.example."
fi
ok "TESTNET_L1_RPC_URL, DEPLOYER_PRIVATE_KEY, AZTEC_NODE_URL, PUBLIC_L1_RPC all set"

# I4: both endpoints this run publishes into the public manifest (chain-view)
# must be checked for embedded credentials before anything is broadcast to
# Sepolia — not only after, when a refusal would be far more expensive to
# unwind. Uses the same check public-manifest.sh itself refuses a keyed
# endpoint with, exposed as a side-effect-free mode.
step "Preflight: checking PUBLIC_L1_RPC and AZTEC_NODE_URL carry no credentials..."
bash "$SCRIPT_DIR/../lib/public-manifest.sh" --check-url "$PUBLIC_L1_RPC" \
  || fail "PUBLIC_L1_RPC carries credentials — it is published in the public manifest chain-view loads. Use a public or origin-restricted RPC. See $SCRIPT_DIR/.env.example."
bash "$SCRIPT_DIR/../lib/public-manifest.sh" --check-url "$AZTEC_NODE_URL" \
  || fail "AZTEC_NODE_URL carries credentials — it is published in the public manifest chain-view loads. Use a public or origin-restricted endpoint. See $SCRIPT_DIR/.env.example."
ok "PUBLIC_L1_RPC and AZTEC_NODE_URL carry no embedded credentials"

# ZER-29: both values are substituted into `sed s|...|...|` replacement text
# when Stage 3 fills the web env. In replacement text `&` means "the whole
# match" and `\` starts an escape, so either character silently corrupts the
# written value. The credential check above does not catch this: it only
# rejects query params NAMED key/token/auth/secret, so a perfectly innocent
# `...?chain=sepolia&format=json` passes it and then mangles.
#
# Checked HERE rather than at the sed, because Stage 3 runs after every
# broadcast has been paid for — the Stage 3 assertion would catch it, but only
# once the whole Sepolia suite, the L2 deploy and the one-shot setBasketManager
# are already spent.
assert_sed_safe() {
  case "$2" in
    *['&\|']*) fail "$1 contains one of & \\ | — Stage 3 substitutes it into sed replacement text when filling the web env, where those characters change the meaning of the replacement and corrupt the value. Use an endpoint URL without them." ;;
  esac
}
assert_sed_safe PUBLIC_L1_RPC "$PUBLIC_L1_RPC"
assert_sed_safe AZTEC_NODE_URL "$AZTEC_NODE_URL"
ok "PUBLIC_L1_RPC and AZTEC_NODE_URL are safe to substitute into the web env"

step "Preflight: checking L1 RPC chain id (must be Sepolia 11155111)..."
if ! L1_CHAIN_ID=$(cast chain-id --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
  fail "Could not reach TESTNET_L1_RPC_URL ($TESTNET_L1_RPC_URL): $L1_CHAIN_ID"
fi
if [ "$L1_CHAIN_ID" != "11155111" ]; then
  fail "TESTNET_L1_RPC_URL ($TESTNET_L1_RPC_URL) reports chain id $L1_CHAIN_ID, not Sepolia (11155111). This guard exists precisely so a pasted mainnet or local-sandbox (31337) RPC URL can never broadcast a real testnet deploy. Fix TESTNET_L1_RPC_URL in $SCRIPT_DIR/.env."
fi
ok "L1 RPC is Sepolia (chain id 11155111)"

step "Preflight: checking deployer balance..."
if ! DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" 2>&1); then
  fail "Could not derive an address from DEPLOYER_PRIVATE_KEY: $DEPLOYER_ADDRESS. Check the key format (0x-prefixed 32-byte hex) in $SCRIPT_DIR/.env."
fi
if ! DEPLOYER_BALANCE_ETH=$(cast balance "$DEPLOYER_ADDRESS" --ether --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
  fail "Could not fetch balance for $DEPLOYER_ADDRESS from $TESTNET_L1_RPC_URL: $DEPLOYER_BALANCE_ETH"
fi
if ! awk -v bal="$DEPLOYER_BALANCE_ETH" -v min="$MIN_DEPLOYER_BALANCE_ETH" 'BEGIN { exit !(bal + 0 >= min + 0) }'; then
  fail "Deployer $DEPLOYER_ADDRESS has ${DEPLOYER_BALANCE_ETH} ETH on Sepolia, below MIN_DEPLOYER_BALANCE_ETH (${MIN_DEPLOYER_BALANCE_ETH}). Fund it from a Sepolia faucet before retrying."
fi
ok "Deployer:  $DEPLOYER_ADDRESS"
ok "Balance:   ${DEPLOYER_BALANCE_ETH} ETH (>= ${MIN_DEPLOYER_BALANCE_ETH} required)"

step "Preflight: governance parameters (G3)..."
: "${GOV_TRANSITION_SECONDS:=15552000}"   # 180 d
: "${GOV_TIMELOCK_DELAY:=172800}"         # 48 h
[ -n "${GOV_PROPOSER:-}" ] || fail "GOV_PROPOSER (the Safe that proposes in phase 2) is required for a testnet deploy. Set it in $SCRIPT_DIR/.env."
[[ "$GOV_PROPOSER" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "GOV_PROPOSER ($GOV_PROPOSER) is not a 0x-prefixed 20-byte hex address."
if [ "$(echo "$GOV_PROPOSER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_PROPOSER equals the deployer address. Phase 2 must be a different authority (a Safe), or the transition is meaningless."
fi
if ! PROPOSER_CODE=$(cast code "$GOV_PROPOSER" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
  fail "Could not fetch code for GOV_PROPOSER ($GOV_PROPOSER) from $TESTNET_L1_RPC_URL: $PROPOSER_CODE"
fi
[ "$PROPOSER_CODE" != "0x" ] || fail "GOV_PROPOSER ($GOV_PROPOSER) has no code on Sepolia — it must be a deployed Safe, not an EOA."

# D1: break-glass second proposer — a cold EOA or second Safe, so loss of the
# primary Safe cannot freeze governance after the transition. No code check:
# an EOA is the expected shape for this key.
[ -n "${GOV_PROPOSER_2:-}" ] || fail "GOV_PROPOSER_2 is required for a testnet deploy — the break-glass second proposer — a cold key or second Safe — is required so loss of the Safe cannot freeze governance after T. Set it in $SCRIPT_DIR/.env."
[[ "$GOV_PROPOSER_2" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "GOV_PROPOSER_2 ($GOV_PROPOSER_2) is not a 0x-prefixed 20-byte hex address."
if [ "$(echo "$GOV_PROPOSER_2" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_PROPOSER_2 equals the deployer address. The break-glass proposer must be a separate key from the deployer."
fi
if [ "$(echo "$GOV_PROPOSER_2" | tr '[:upper:]' '[:lower:]')" = "$(echo "$GOV_PROPOSER" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_PROPOSER_2 equals GOV_PROPOSER. The break-glass proposer must be a separate key from the primary Safe, or it provides no redundancy."
fi

# D2: guardian must be a separate key from the deployer on testnet.
[ -n "${GOV_GUARDIAN:-}" ] || fail "GOV_GUARDIAN is required for a testnet deploy — the guardian must be a separate key from the deployer. Set it in $SCRIPT_DIR/.env."
[[ "$GOV_GUARDIAN" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "GOV_GUARDIAN ($GOV_GUARDIAN) is not a 0x-prefixed 20-byte hex address."
if [ "$(echo "$GOV_GUARDIAN" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_GUARDIAN equals the deployer address. The guardian must be a separate key from the deployer."
fi

# D5: resumable deploy. GOV_AUTHORITY/GOV_TIMELOCK/GOV_VALIDATOR are optional,
# but when any one is set all three must be, and each must already have code
# on Sepolia — the script then reuses them instead of deploying fresh.
RESUME_MODE=false
if [ -n "${GOV_AUTHORITY:-}" ] || [ -n "${GOV_TIMELOCK:-}" ] || [ -n "${GOV_VALIDATOR:-}" ]; then
  [ -n "${GOV_AUTHORITY:-}" ] || fail "GOV_AUTHORITY is unset but GOV_TIMELOCK/GOV_VALIDATOR is set — resume mode requires all three (GOV_AUTHORITY, GOV_TIMELOCK, GOV_VALIDATOR) to reuse a prior governance deploy."
  [ -n "${GOV_TIMELOCK:-}" ] || fail "GOV_TIMELOCK is unset but GOV_AUTHORITY/GOV_VALIDATOR is set — resume mode requires all three (GOV_AUTHORITY, GOV_TIMELOCK, GOV_VALIDATOR) to reuse a prior governance deploy."
  [ -n "${GOV_VALIDATOR:-}" ] || fail "GOV_VALIDATOR is unset but GOV_AUTHORITY/GOV_TIMELOCK is set — resume mode requires all three (GOV_AUTHORITY, GOV_TIMELOCK, GOV_VALIDATOR) to reuse a prior governance deploy."
  for RESUME_PAIR in "GOV_AUTHORITY:$GOV_AUTHORITY" "GOV_TIMELOCK:$GOV_TIMELOCK" "GOV_VALIDATOR:$GOV_VALIDATOR"; do
    RESUME_NAME="${RESUME_PAIR%%:*}"
    RESUME_ADDR="${RESUME_PAIR#*:}"
    [[ "$RESUME_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "$RESUME_NAME ($RESUME_ADDR) is not a 0x-prefixed 20-byte hex address."
    if ! RESUME_CODE=$(cast code "$RESUME_ADDR" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
      fail "Could not fetch code for $RESUME_NAME ($RESUME_ADDR) from $TESTNET_L1_RPC_URL: $RESUME_CODE"
    fi
    [ "$RESUME_CODE" != "0x" ] || fail "$RESUME_NAME ($RESUME_ADDR) has no code on Sepolia — resume mode requires a previously deployed contract."
  done
  # I2: roles cannot be changed after deployment — confirm GOV_PROPOSER and
  # GOV_PROPOSER_2 actually hold PROPOSER_ROLE on the reused timelock, so a
  # mistyped/mismatched resume address is caught here rather than silently
  # producing a handover that later can't be proposed against.
  if ! PROPOSER_ROLE=$(cast call "$GOV_TIMELOCK" "PROPOSER_ROLE()(bytes32)" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
    fail "Could not fetch PROPOSER_ROLE from GOV_TIMELOCK ($GOV_TIMELOCK) at $TESTNET_L1_RPC_URL: $PROPOSER_ROLE"
  fi
  for RESUME_ROLE_ADDR in "$GOV_PROPOSER" "$GOV_PROPOSER_2"; do
    if ! HAS_ROLE=$(cast call "$GOV_TIMELOCK" "hasRole(bytes32,address)(bool)" "$PROPOSER_ROLE" "$RESUME_ROLE_ADDR" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
      fail "Could not check PROPOSER_ROLE for $RESUME_ROLE_ADDR on GOV_TIMELOCK ($GOV_TIMELOCK) at $TESTNET_L1_RPC_URL: $HAS_ROLE"
    fi
    [ "$HAS_ROLE" = "true" ] || fail "RESUME: $RESUME_ROLE_ADDR does not hold PROPOSER_ROLE on $GOV_TIMELOCK — use the proposer addresses the original deploy used; roles cannot be changed after deployment."
  done
  RESUME_MODE=true
  ok "RESUME mode: reusing authority/timelock/validator"
fi

export GOV_TRANSITION_SECONDS GOV_TIMELOCK_DELAY GOV_PROPOSER GOV_PROPOSER_2 GOV_GUARDIAN GOV_AUTHORITY GOV_TIMELOCK GOV_VALIDATOR
ok "GOV_PROPOSER:   $GOV_PROPOSER (contract)"
ok "GOV_PROPOSER_2: $GOV_PROPOSER_2"
ok "GOV_GUARDIAN:   $GOV_GUARDIAN"
ok "Transition:     ${GOV_TRANSITION_SECONDS}s after deploy; timelock delay ${GOV_TIMELOCK_DELAY}s"

step "Preflight: basket lifecycle parameters (Phase 1)..."
# BasketManager durations. Testnet+ runs the real thing: 5 d voting window /
# 48 h execution delay, with IMMUTABLE floors of 3 d / 24 h — no later setParams
# call can go below them, so getting these wrong here is unfixable without a
# redeploy. (The sandbox runs 30 min / 1 h, the contract's hard minima.)
: "${BASKET_VOTING_WINDOW:=432000}"        # 5 d
: "${BASKET_EXECUTION_DELAY:=172800}"      # 48 h
: "${BASKET_VOTING_WINDOW_FLOOR:=259200}"  # 3 d
: "${BASKET_EXECUTION_DELAY_FLOOR:=86400}" # 24 h
for BASKET_VAR in BASKET_VOTING_WINDOW BASKET_EXECUTION_DELAY BASKET_VOTING_WINDOW_FLOOR BASKET_EXECUTION_DELAY_FLOOR; do
  BASKET_VAL=${!BASKET_VAR}
  [[ "$BASKET_VAL" =~ ^[0-9]+$ ]] || fail "$BASKET_VAR ($BASKET_VAL) must be a whole number of seconds."
done
# Spec §8 minima for testnet+, asserted here rather than only inside the deploy
# script so --preflight-only catches a bad .env before anything is broadcast.
[ "$BASKET_VOTING_WINDOW_FLOOR" -ge 259200 ] || fail "BASKET_VOTING_WINDOW_FLOOR ($BASKET_VOTING_WINDOW_FLOOR) is below the 3 d (259200 s) testnet floor. It is IMMUTABLE — a redeploy is the only way to change it."
[ "$BASKET_EXECUTION_DELAY_FLOOR" -ge 86400 ] || fail "BASKET_EXECUTION_DELAY_FLOOR ($BASKET_EXECUTION_DELAY_FLOOR) is below the 24 h (86400 s) testnet floor. It is IMMUTABLE — a redeploy is the only way to change it."
[ "$BASKET_VOTING_WINDOW" -ge "$BASKET_VOTING_WINDOW_FLOOR" ] || fail "BASKET_VOTING_WINDOW ($BASKET_VOTING_WINDOW) is below its own floor ($BASKET_VOTING_WINDOW_FLOOR) — the constructor would revert."
[ "$BASKET_EXECUTION_DELAY" -ge "$BASKET_EXECUTION_DELAY_FLOOR" ] || fail "BASKET_EXECUTION_DELAY ($BASKET_EXECUTION_DELAY) is below its own floor ($BASKET_EXECUTION_DELAY_FLOOR) — the constructor would revert."
# MAX_VOTING_WINDOW / MAX_EXECUTION_DELAY are both 30 d in BasketManager.
[ "$BASKET_VOTING_WINDOW" -le 2592000 ] || fail "BASKET_VOTING_WINDOW ($BASKET_VOTING_WINDOW) exceeds BasketManager.MAX_VOTING_WINDOW (30 d / 2592000 s)."
[ "$BASKET_EXECUTION_DELAY" -le 2592000 ] || fail "BASKET_EXECUTION_DELAY ($BASKET_EXECUTION_DELAY) exceeds BasketManager.MAX_EXECUTION_DELAY (30 d / 2592000 s)."
# NO swap router is allow-listed on testnet. On the sandbox the pipeline
# allow-lists a MockDexAggregator because a local chain has no other swap venue;
# on a real network, picking the venue a migration tranche routes through is a
# governance decision, not a deploy-script default. Set BASKET_ROUTER explicitly
# if you have decided on one.
: "${BASKET_ROUTER:=}"

# Resumable basket stage, same shape as the D5 governance resume block above.
# BASKET_MANAGER is optional, but when it IS set this run reuses that manager
# instead of deploying a fresh one — and that decision has to be ANNOUNCED here,
# before anything broadcasts. Without this block an operator who exported
# BASKET_MANAGER days ago for a one-off `cast` check and then resumed a partial
# run would silently resume onto it: DeployBasketManager's immutable checks
# (pool/authority/safe/rollup/version) can all pass for a manager that is
# nonetheless not the one this deploy meant to use, and nothing in preflight
# would show the choice was made.
BASKET_RESUME_MODE=false
if [ -n "${BASKET_MANAGER:-}" ]; then
  [[ "$BASKET_MANAGER" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "BASKET_MANAGER ($BASKET_MANAGER) is not a 0x-prefixed 20-byte hex address. Unset it to deploy a fresh BasketManager."
  if ! BASKET_MANAGER_CODE=$(cast code "$BASKET_MANAGER" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
    fail "Could not fetch code for BASKET_MANAGER ($BASKET_MANAGER) from $TESTNET_L1_RPC_URL: $BASKET_MANAGER_CODE"
  fi
  [ "$BASKET_MANAGER_CODE" != "0x" ] || fail "BASKET_MANAGER ($BASKET_MANAGER) has no code on Sepolia — resume mode requires a previously deployed BasketManager. Unset BASKET_MANAGER to deploy a fresh one."
  BASKET_RESUME_MODE=true
fi
export BASKET_VOTING_WINDOW BASKET_EXECUTION_DELAY BASKET_VOTING_WINDOW_FLOOR BASKET_EXECUTION_DELAY_FLOOR BASKET_ROUTER BASKET_MANAGER
ok "Voting window:   ${BASKET_VOTING_WINDOW}s (immutable floor ${BASKET_VOTING_WINDOW_FLOOR}s)"
ok "Execution delay: ${BASKET_EXECUTION_DELAY}s (immutable floor ${BASKET_EXECUTION_DELAY_FLOOR}s)"
if [ -z "$BASKET_ROUTER" ]; then
  ok "Swap router:     none (allow-list one through governance when the venue is chosen)"
else
  [[ "$BASKET_ROUTER" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "BASKET_ROUTER ($BASKET_ROUTER) is not a 0x-prefixed 20-byte hex address."
  if ! BASKET_ROUTER_CODE=$(cast code "$BASKET_ROUTER" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
    fail "Could not fetch code for BASKET_ROUTER ($BASKET_ROUTER) from $TESTNET_L1_RPC_URL: $BASKET_ROUTER_CODE"
  fi
  [ "$BASKET_ROUTER_CODE" != "0x" ] || fail "BASKET_ROUTER ($BASKET_ROUTER) has no code on Sepolia — it must be a deployed swap router, not an EOA or a typo'd address."
  ok "Swap router:     $BASKET_ROUTER (will be allow-listed)"
fi
if [ "$BASKET_RESUME_MODE" = true ]; then
  ok "RESUME mode: reusing BasketManager $BASKET_MANAGER (NO fresh BasketManager will be deployed)"
fi

step "Preflight: checking Aztec node ($AZTEC_NODE_URL)..."
# getNodeInfo one-liner pattern (see v1-l1/Makefile's deploy-bridge target,
# ~line 252: createAztecNodeClient from '@aztec/aztec.js/node'). Run from
# v1-l2 so @aztec/aztec.js resolves from its own node_modules.
read -r -d '' GET_NODE_INFO_JS <<'NODE_INFO_EOF' || true
import { createAztecNodeClient } from '@aztec/aztec.js/node';
const url = process.argv.at(-1);
try {
  const client = createAztecNodeClient(url);
  const info = await client.getNodeInfo();
  console.log(JSON.stringify({
    nodeVersion: info.nodeVersion,
    l1ChainId: info.l1ChainId,
    inboxAddress: info.l1ContractAddresses.inboxAddress.toString(),
    rollupAddress: info.l1ContractAddresses.rollupAddress.toString(),
    registryAddress: info.l1ContractAddresses.registryAddress.toString(),
    feeJuicePortalAddress: info.l1ContractAddresses.feeJuicePortalAddress.toString(),
    feeJuiceAddress: info.l1ContractAddresses.feeJuiceAddress.toString(),
  }));
} catch (err) {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
}
NODE_INFO_EOF

# Node's own error output is a very verbose retry/stack-trace dump (three
# retries with backoff) — swallow it and report our own clean message
# instead; --preflight-only output stays readable either way.
if ! NODE_INFO_JSON=$(cd "$L2_DIR" && node --input-type=module -e "$GET_NODE_INFO_JS" "$AZTEC_NODE_URL" 2>/dev/null); then
  fail "Could not reach Aztec node at $AZTEC_NODE_URL (getNodeInfo failed after retries). Check AZTEC_NODE_URL points at a running Aztec testnet node."
fi

NODE_VERSION=$(echo "$NODE_INFO_JSON" | jq -r '.nodeVersion')
NODE_L1_CHAIN_ID=$(echo "$NODE_INFO_JSON" | jq -r '.l1ChainId')
L1_INBOX_ADDRESS=$(echo "$NODE_INFO_JSON" | jq -r '.inboxAddress')
L1_ROLLUP_ADDRESS=$(echo "$NODE_INFO_JSON" | jq -r '.rollupAddress')
L1_REGISTRY_ADDRESS=$(echo "$NODE_INFO_JSON" | jq -r '.registryAddress')
L1_FEE_JUICE_PORTAL_ADDRESS=$(echo "$NODE_INFO_JSON" | jq -r '.feeJuicePortalAddress')
# Exported for Tasks 3-4's L1/L2/manifest stages.
export L1_INBOX_ADDRESS L1_ROLLUP_ADDRESS L1_REGISTRY_ADDRESS L1_FEE_JUICE_PORTAL_ADDRESS NODE_VERSION

if [ "$NODE_L1_CHAIN_ID" != "11155111" ]; then
  fail "Aztec node at $AZTEC_NODE_URL is settling on L1 chain id $NODE_L1_CHAIN_ID, not Sepolia (11155111). Check AZTEC_NODE_URL points at the official Aztec testnet, not a sandbox."
fi
ok "Aztec node reachable, settling on Sepolia (11155111)"

LOCAL_SDK_VERSION=$(jq -r '.version' "$L2_DIR/node_modules/@aztec/aztec.js/package.json")
if [ "$NODE_VERSION" != "$LOCAL_SDK_VERSION" ]; then
  if [ "$FORCE_VERSION" = true ]; then
    warn "Node version ($NODE_VERSION) != local SDK version ($LOCAL_SDK_VERSION) — continuing anyway due to --force-version."
    warn "This relaxes ONLY the version comparison. The SponsoredFPC and HandshakeRegistry preflights below still have to pass."
    warn "Accepted residual risk and the signals that it went wrong: testnet/README.md, \"Deploying across a node/SDK version skew\"."
    VERSION_GATE_SUMMARY="FORCED (node $NODE_VERSION, SDK $LOCAL_SDK_VERSION; --force-version)"
  else
    fail "Aztec node version ($NODE_VERSION) does not match the local SDK version ($LOCAL_SDK_VERSION) in $L2_DIR/node_modules/@aztec/aztec.js. Contract/RPC incompatibilities are likely — upgrade v1-l2's @aztec/aztec.js to match, or pass --force-version to proceed anyway at your own risk."
  fi
else
  ok "Node version matches local SDK version ($NODE_VERSION)"
  VERSION_GATE_SUMMARY="matched ($NODE_VERSION)"
fi

ok "L1_INBOX_ADDRESS:            $L1_INBOX_ADDRESS"
ok "L1_ROLLUP_ADDRESS:           $L1_ROLLUP_ADDRESS"
ok "L1_REGISTRY_ADDRESS:         $L1_REGISTRY_ADDRESS"
ok "L1_FEE_JUICE_PORTAL_ADDRESS: $L1_FEE_JUICE_PORTAL_ADDRESS"

# ZER-28 (T7): user fees on testnet ride on Aztec's canonical SponsoredFPC,
# whose address Stage 2 DERIVES rather than looks up (contract class id + salt
# 0 + zero deployer). The class id moves between aztec versions, so a mismatch
# yields a well-formed address with no contract behind it — Stage 2 would
# record it, the deploy would look completely successful, and every browser
# would fail at boot. The version gate above catches the common cause, but it
# compares the SDK to the node, not the FPC to the chain, so check the chain
# too. Here rather than in Stage 2: the pipeline has no resume flag for Stage
# 1, so a failure found later has already cost every Sepolia transaction.
# Delegates to v1-l2 so there is ONE derivation path, shared with the deploy.
#
# `npx --yes`: without it npx prompts to install tsx, and with stderr
# suppressed that prompt is invisible and reads as a hang. tsx is already a
# hard dependency of this pipeline (Stage 2 runs `yarn deploy:clean` ->
# `npx tsx scripts/deploy.ts`), so this adds no new requirement.
step "Preflight: canonical SponsoredFPC (code + fee-juice balance)..."
if ! CANONICAL_FPC_JSON=$(cd "$L2_DIR" && AZTEC_RPC_HOST="$AZTEC_NODE_URL" npx --yes tsx scripts/check-canonical-fpc.ts 2>/dev/null); then
  # `.message // "fallback"` does NOT cover empty input: with nothing on
  # stdin jq emits nothing and the message would come out blank — which is
  # precisely the case where the script never ran. Test for empty explicitly.
  CANONICAL_FPC_MSG=$(printf '%s' "$CANONICAL_FPC_JSON" | jq -r '.message // empty' 2>/dev/null || true)
  [ -n "$CANONICAL_FPC_MSG" ] || CANONICAL_FPC_MSG="Could not run the canonical SponsoredFPC preflight (cd $L2_DIR && npx --yes tsx scripts/check-canonical-fpc.ts) — it produced no output. Check that v1-l2's dependencies are installed and that AZTEC_NODE_URL ($AZTEC_NODE_URL) is reachable."
  # ZER-71: --force-version used to downgrade this check too, on the theory
  # that a version skew is the most likely reason it fails. That made one flag
  # silence two different questions. The owner's 2026-09-26 route runs a
  # 5.2.0 SDK against a 5.0.0 node on purpose, and this check PASSES there,
  # which is the evidence that route rests on. If it stops passing, the
  # skew has moved the derived FPC address, the case this check exists
  # for, and proceeding records an address with no contract behind it and a
  # deploy that is dead for every user. So the FPC has its own explicit
  # override, for the rare case where the operator knows why it fails and
  # still wants the deploy (e.g. Aztec's instance is briefly unfunded).
  if [ "$ALLOW_UNVERIFIED_FPC" = true ]; then
    warn "Canonical SponsoredFPC preflight FAILED — continuing anyway due to --allow-unverified-fpc."
    warn "$CANONICAL_FPC_MSG"
    warn "If this is wrong, Stage 2 records an FPC address with no contract behind it and every user tx fails at boot."
    # Carry the override into Stage 2, whose own preflight would otherwise
    # abort the deploy and quietly revoke what was just granted here.
    export ZERACLE_ALLOW_UNVERIFIED_FPC=1
    FPC_SUMMARY="UNVERIFIED (--allow-unverified-fpc; Stage 2 gets ZERACLE_ALLOW_UNVERIFIED_FPC=1)"
  elif [ "$FORCE_VERSION" = true ]; then
    fail "$CANONICAL_FPC_MSG
    --force-version relaxes only the node/SDK version gate; it does not relax this check (ZER-71). Under a version skew, this failing usually means the derived FPC address moved, so the deploy would be dead on arrival. Check by hand with: cd v1-l2 && AZTEC_RPC_HOST=$AZTEC_NODE_URL yarn check:canonical-fpc. Only if you know why it fails and still want the deploy, add --allow-unverified-fpc."
  else
    fail "$CANONICAL_FPC_MSG"
  fi
else
  CANONICAL_FPC_ADDRESS=$(printf '%s' "$CANONICAL_FPC_JSON" | jq -r '.address')
  ok "Canonical SponsoredFPC: $CANONICAL_FPC_ADDRESS (fee-juice balance $(printf '%s' "$CANONICAL_FPC_JSON" | jq -r '.balance'))"
  FPC_SUMMARY="verified ($CANONICAL_FPC_ADDRESS)"
fi

# ZER-29 (T11): cross-account private note discovery needs the standard
# HandshakeRegistry published at the canonical address baked into the circuits.
# Its absence is SILENT — transfers land and the recipient simply never sees
# them — so it is checked rather than assumed. Whether Aztec's testnet has it
# at genesis is unverified, which is exactly why this runs here, before any
# Sepolia broadcast, rather than being discovered after the L1 suite is paid
# for. Delegates to v1-l2 so the canonical address has one definition, shared
# with scripts/deploy-handshake-registry.ts.
#
# Fails loud rather than auto-deploying: publishing the registry is a real
# universal deploy, and slipping an unplanned one into an already-long
# pipeline run is a bigger blast radius than stopping and pointing at the
# existing idempotent script.
step "Preflight: standard HandshakeRegistry published on the Aztec node..."
if ! HANDSHAKE_JSON=$(cd "$L2_DIR" && AZTEC_RPC_HOST="$AZTEC_NODE_URL" npx --yes tsx scripts/check-handshake-registry.ts 2>/dev/null); then
  # Same empty-input trap as the FPC preflight above: `.message // "fallback"`
  # would yield a blank error when the script never ran at all.
  HANDSHAKE_MSG=$(printf '%s' "$HANDSHAKE_JSON" | jq -r '.message // empty' 2>/dev/null || true)
  [ -n "$HANDSHAKE_MSG" ] || HANDSHAKE_MSG="Could not run the HandshakeRegistry preflight (cd $L2_DIR && npx --yes tsx scripts/check-handshake-registry.ts) — it produced no output. Check that v1-l2's dependencies are installed and that AZTEC_NODE_URL ($AZTEC_NODE_URL) is reachable."
  fail "$HANDSHAKE_MSG"
fi
ok "HandshakeRegistry published at $(printf '%s' "$HANDSHAKE_JSON" | jq -r '.address')"

# T5-R9: Stage 2 (v1-l2/scripts/deploy.ts) bridges the deployer's OWN L1
# fee-asset balance non-mint — a real network has no faucet. Stage 2 only runs
# after every Stage 1 Sepolia tx has spent gas, and the pipeline has no resume
# flag for Stage 1, so a short balance must be caught HERE, before anything
# broadcasts. The token is the L1 fee-juice ERC20 the node itself reports (the
# one L1FeeJuicePortalManager bridges). The signer matches: stage_l2_deploy
# passes L1_DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY". The amount matches:
# L1_FEE_ASSET_BRIDGE_AMOUNT is exported from .env (set -a), and empty or unset
# means 1e18 here exactly as in resolveFeeAssetBridgeMode(). deploy.ts repeats
# this check right before its bridge as a second guard.
step "Preflight: checking deployer L1 fee-asset balance (fee-juice token)..."
L1_FEE_JUICE_ADDRESS=$(echo "$NODE_INFO_JSON" | jq -r '.feeJuiceAddress')
[[ "$L1_FEE_JUICE_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "Aztec node at $AZTEC_NODE_URL did not report a valid L1 fee-juice token address (got '$L1_FEE_JUICE_ADDRESS')."
# ZER-11: a re-run that reuses an already-bridged fee-juice claim makes no new
# L1 fee-asset spend, so this gate must not demand the amount a second time.
# The operator funds the deployer with exactly L1_FEE_ASSET_BRIDGE_AMOUNT (what
# .env.example tells them to do); the run that crashed already spent it, so the
# balance is now ~0. Demanding it again would fail here and make the recovery
# path unreachable in precisely the case it exists for. deploy.ts applies the
# same rule on its side (resolveDeployerClaimSource, utils/deployer_account.ts).
# The path mirrors v1-l2's pendingFeeClaimPath(DEPLOYER_ACCOUNT_FILE), and
# stage_l2_deploy sets DEPLOYER_ACCOUNT_FILE="$SCRIPT_DIR/deployer-account.json".
PENDING_CLAIM_FILE="$SCRIPT_DIR/deployer-account.json.pending-claim.json"
if [ -f "$PENDING_CLAIM_FILE" ]; then
  FEE_ASSET_REQUIRED=0
  FEE_ASSET_SUMMARY="not checked — Stage 2 reuses a pending claim, so it bridges nothing"
  ok "Fee-juice token:   $L1_FEE_JUICE_ADDRESS"
  warn "Pending fee-juice claim found: $PENDING_CLAIM_FILE"
  warn "Stage 2 will REUSE the claim a previous run already bridged on L1 rather than bridging again,"
  warn "so the deployer fee-asset balance gate is skipped for this run."
  warn "That file holds the claim SECRET: keep it private, never commit or ship it. It is cleared"
  warn "automatically once the claim is spent by the first L2 deploy (ZER-28: the ZeracleToken"
  warn "deploy on testnet, since testnet no longer deploys a SponsoredFPC of its own)."
else
  FEE_ASSET_REQUIRED="${L1_FEE_ASSET_BRIDGE_AMOUNT:-1000000000000000000}"
  [[ "$FEE_ASSET_REQUIRED" =~ ^[0-9]+$ ]] || fail "L1_FEE_ASSET_BRIDGE_AMOUNT ($FEE_ASSET_REQUIRED) must be a base-10 integer (base units of the fee-juice token). See $SCRIPT_DIR/.env.example."
  if ! FEE_ASSET_BALANCE_OUT=$(cast call "$L1_FEE_JUICE_ADDRESS" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
    fail "Could not read the fee-juice token balance (token $L1_FEE_JUICE_ADDRESS, deployer $DEPLOYER_ADDRESS) from $TESTNET_L1_RPC_URL: $FEE_ASSET_BALANCE_OUT"
  fi
  # cast prints large uint256 values as "<decimal> [<scientific>]"; keep the decimal.
  FEE_ASSET_BALANCE="${FEE_ASSET_BALANCE_OUT%% *}"
  [[ "$FEE_ASSET_BALANCE" =~ ^[0-9]+$ ]] || fail "Unexpected balanceOf output from fee-juice token $L1_FEE_JUICE_ADDRESS: $FEE_ASSET_BALANCE_OUT"
  # Exact big-integer compare: bash arithmetic overflows past 2^63 and awk rounds.
  if ! python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$FEE_ASSET_BALANCE" "$FEE_ASSET_REQUIRED"; then
    fail "Fee-asset shortfall: deployer $DEPLOYER_ADDRESS holds $FEE_ASSET_BALANCE base units of the L1 fee-juice token $L1_FEE_JUICE_ADDRESS, but the L2 deploy bridges $FEE_ASSET_REQUIRED (L1_FEE_ASSET_BRIDGE_AMOUNT, default 1e18). There is no faucet on a real network: fund the deployer with that token and retry. Nothing has been broadcast."
  fi
  FEE_ASSET_SUMMARY="$FEE_ASSET_BALANCE base units (L2 deploy bridges $FEE_ASSET_REQUIRED)"
  ok "Fee-juice token:   $L1_FEE_JUICE_ADDRESS"
  ok "Fee-asset balance: $FEE_ASSET_BALANCE base units (>= $FEE_ASSET_REQUIRED required)"
fi

step "Preflight: checking prebuilt L2 artifacts + web env template..."
# Hoisted from stage_l2_deploy/stage_manifest_sync (same fail messages) so a
# missing prebuilt artifact or template file is caught here, before the
# confirmation prompt, instead of after Stage 1 has already broadcast L1
# transactions. The later checks stay in place too (idempotent) in case this
# script is ever invoked past preflight without going through main().
[ -f "$L2_DIR/artifacts/index.ts" ] || fail "v1-l2/artifacts/index.ts is missing. Testnet deploys never build Noir on the fly (same rule as deploy-sandbox.sh's headless branch) — run 'yarn build' once and ship the resulting artifacts/ + target/ directories before running this script."
[ -n "$(ls "$L2_DIR"/target/*.json 2>/dev/null)" ] || fail "v1-l2/target/*.json is missing. Compiled Noir artifacts must already be present — run 'yarn build' first."
ok "Prebuilt L2 artifacts present (artifacts/index.ts, target/*.json)"

WEB_ENV="$WEB_DIR/.env.testnet"
[ -f "$WEB_ENV" ] || fail "$WEB_ENV not found. It must exist (with the placeholder VITE_* keys already in place) before this script can sync addresses into it."
ok "Web env template present ($WEB_ENV)"

step "Preflight: checking optional ETHERSCAN_API_KEY..."
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  ok "ETHERSCAN_API_KEY is set — forge --verify will attempt Etherscan verification on the L1 targets"
else
  warn "ETHERSCAN_API_KEY is not set — forge --verify will be skipped/will fail on the L1 targets; contracts still deploy, just unverified on Etherscan. See testnet/.env.example."
fi

step "Preflight summary"
cat <<SUMMARY

  TESTNET_L1_RPC_URL:          $TESTNET_L1_RPC_URL
  AZTEC_NODE_URL:               $AZTEC_NODE_URL
  Deployer address:             $DEPLOYER_ADDRESS
  Deployer balance:             ${DEPLOYER_BALANCE_ETH} ETH
  GOV_PROPOSER:                 $GOV_PROPOSER
  GOV_PROPOSER_2:               $GOV_PROPOSER_2
  GOV_TRANSITION_SECONDS:       $GOV_TRANSITION_SECONDS
  Resume mode:                  $([ "$RESUME_MODE" = true ] && echo "yes (reusing GOV_AUTHORITY/GOV_TIMELOCK/GOV_VALIDATOR)" || echo "no (fresh governance deploy)")
  Basket resume mode:           $([ "$BASKET_RESUME_MODE" = true ] && echo "yes (reusing BASKET_MANAGER $BASKET_MANAGER)" || echo "no (fresh BasketManager deploy)")
  Aztec node version:           $NODE_VERSION
  Local SDK version:            $LOCAL_SDK_VERSION
  Version gate:                 $VERSION_GATE_SUMMARY
  Canonical SponsoredFPC:       $FPC_SUMMARY
  L1 Inbox address:             $L1_INBOX_ADDRESS
  L1 Rollup address:            $L1_ROLLUP_ADDRESS
  L1 Registry address:          $L1_REGISTRY_ADDRESS
  L1 FeeJuicePortal address:    $L1_FEE_JUICE_PORTAL_ADDRESS
  L1 fee-juice token:           $L1_FEE_JUICE_ADDRESS
  Deployer fee-asset balance:   $FEE_ASSET_SUMMARY
  FeeDistribution flush min:    $TESTNET_FLUSH_MINIMUM base units (10 ZRCL, enforced; ZER-32)
  ETHERSCAN_API_KEY set:        $([ -n "${ETHERSCAN_API_KEY:-}" ] && echo "yes (--verify will run on L1 targets)" || echo "no (contracts deploy unverified)")

SUMMARY

if [ "$PREFLIGHT_ONLY" = true ]; then
  echo "PREFLIGHT PASS"
  exit 0
fi

if [ "${SKIP_CONFIRM:-}" != "1" ]; then
  read -r -p "Type 'deploy' to continue and broadcast real transactions to Sepolia + the Aztec testnet: " CONFIRM
  [ "$CONFIRM" = "deploy" ] || fail "Aborted (confirmation not given)."
fi

# ===========================================================================
# Stage 1: L1 deploy (Sepolia)
#
# Reuses v1-l1's env-driven testnet make targets (Task 2 of the
# testnet-deploy-pipeline plan): deploy-testnet-l1 -> deploy-mocks-testnet
# (which now deploys fresh Sepolia-native price feeds itself — T2 — with no
# separate anvil-only feed-install step) -> deploy-bridge-testnet. Each target writes its own
# `*-testnet.json` output (never clobbering the sandbox's local.json/
# tokens.json/bridge.json); every write is asserted with jq before we trust
# it and move on.
# ===========================================================================

# ===========================================================================
# ZER-29: shared plumbing for the "forge exited non-zero, but it may only be
# Etherscan verification" tolerance used by Stages 1, 2b and 2c.
# ===========================================================================

# Is the tolerance even admissible? v1-l1/Makefile passes --verify only as
# `$${ETHERSCAN_API_KEY:+--verify ...}`, so with no key forge is never asked to
# verify — and a non-zero exit therefore CANNOT be a verification failure.
# Warning-and-continuing in that configuration would wave through a real deploy
# failure, which is the common case since the key is optional.
require_verify_was_attempted() {
  [ -n "${ETHERSCAN_API_KEY:-}" ] || fail "$1 failed and ETHERSCAN_API_KEY is unset, so --verify was never attempted (see v1-l1/Makefile) — a non-zero exit here is a real deploy failure, not an Etherscan one. Check the forge output above."
}

# Does an address have contract code? Empty output counts as NO code: `cast
# code` can exit 0 with nothing on stdout, and `[ "$x" != "0x" ]` is true for
# the empty string — which would read as "has code". Mirrors the -n test the
# feed-code loop below already uses.
has_code() {
  local addr="${1:-}" code
  [ -n "$addr" ] && [ "$addr" != "null" ] || return 1
  code=$(cast code "$addr" --rpc-url "$TESTNET_L1_RPC_URL" 2>/dev/null || echo 0x)
  [ -n "$code" ] && [ "$code" != "0x" ]
}

# Every address a stage's output file records must have code, not just the one
# we happened to check. forge writes that file during execution, so a broadcast
# that died partway still leaves a complete-looking JSON.
require_all_have_code() {
  local file="$1" what="$2"; shift 2
  local f addr
  for f in "$@"; do
    addr=$(jq -r --arg f "$f" '.[$f] // ""' "$file" 2>/dev/null || true)
    has_code "$addr" || fail "$what exited non-zero and .$f ($addr) in $file has no code on-chain — this is a real deploy failure, not an Etherscan one. Check the forge output above."
  done
}

stage_l1_deploy() {
  cd "$L1_DIR"

  step "L1: deploying core contracts (Sepolia)..."
  # ZER-29: tolerate a --verify-only failure, mirroring Stage 2b/2c. Removing
  # the output file FIRST matters: forge writes it at simulation time, so a
  # stale file from a previous run would leave an address whose code is
  # already on-chain and produce a false "the broadcast landed" warning.
  rm -f deployments/local-testnet.json
  if ! ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-testnet-l1; then
    # The file existing is NOT proof the broadcast landed. Check on-chain code
    # at the recorded pool proxy: a non-zero forge exit after a successful
    # broadcast is most likely Etherscan verification failing.
    require_verify_was_attempted "make deploy-testnet-l1"
    # DeployLocal broadcasts ~30 operations and the pool proxy is only the
    # SECOND, so "the proxy has code" says almost nothing about whether the
    # rest landed. A later broadcast dying (dropped RPC, nonce gap, underpriced)
    # leaves the file written and the proxy deployed. That matters here more
    # than anywhere else in the pipeline: Stage 2b hands L1 ownership to the
    # GovernanceAuthority, after which a missed setPoolAddress can only be
    # repaired through a proposal behind the timelock delay. So require code at
    # EVERY address this stage records, including feeConverter, which is
    # deployed last.
    require_all_have_code deployments/local-testnet.json "make deploy-testnet-l1" \
      liquidityPoolProxy liquidityPoolImpl depositAdapter withdrawalAdapter \
      bridgeGuard treasury collateralReserve networkFund feeConverter
    warn "forge exited non-zero but every contract deploy-testnet-l1 records has code on-chain — the broadcast landed; most likely Etherscan verification failed. Retry verification only with: cd $L1_DIR && FOUNDRY_PROFILE=deploy DEPLOYER_PRIVATE_KEY=\$DEPLOYER_PRIVATE_KEY DEPLOY_OUTPUT_JSON=deployments/local-testnet.json forge script script/DeployLocal.s.sol:DeployLocal --rpc-url \$TESTNET_L1_RPC_URL --resume --verify --etherscan-api-key \$ETHERSCAN_API_KEY"
  fi
  [ -f deployments/local-testnet.json ] || fail "v1-l1/deployments/local-testnet.json was not created by 'make deploy-testnet-l1'. Check the forge output above for the actual failure."
  LIQUIDITY_POOL_PROXY=$(jq -r '.liquidityPoolProxy' deployments/local-testnet.json)
  DEPOSIT_ADAPTER=$(jq -r '.depositAdapter' deployments/local-testnet.json)
  WITHDRAWAL_ADAPTER=$(jq -r '.withdrawalAdapter' deployments/local-testnet.json)
  BRIDGE_GUARD=$(jq -r '.bridgeGuard' deployments/local-testnet.json)
  TREASURY=$(jq -r '.treasury' deployments/local-testnet.json)
  COLLATERAL_RESERVE=$(jq -r '.collateralReserve' deployments/local-testnet.json)
  NETWORK_FUND=$(jq -r '.networkFund' deployments/local-testnet.json)
  ok "LiquidityPool:     $LIQUIDITY_POOL_PROXY"
  ok "DepositAdapter:    $DEPOSIT_ADAPTER"
  ok "WithdrawalAdapter: $WITHDRAWAL_ADAPTER"
  ok "BridgeGuard:       $BRIDGE_GUARD"
  ok "Treasury:          $TREASURY"
  ok "CollateralReserve:     $COLLATERAL_RESERVE"
  ok "NetworkFund:       $NETWORK_FUND"

  step "L1: deploying mock tokens (Sepolia)..."
  # ZER-29: same tolerance. LUSD is only a PROXY for "did this land" — this
  # target deploys 8 tokens, 8 feeds and the input-feed wiring, so one address
  # having code does not prove every leg succeeded. That is fine here: the
  # feed-code and input-price-feed loops below remain the authoritative
  # postcondition checks, and they run whether or not this tolerated the exit.
  rm -f deployments/tokens-testnet.json
  if ! ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-mocks-testnet; then
    require_verify_was_attempted "make deploy-mocks-testnet"
    # All 8 tokens, not just LUSD. The feeds and the input-feed wiring are
    # still covered more thoroughly by the two loops below, which run whether
    # or not this tolerated the exit — so this only has to establish that the
    # token leg landed.
    require_all_have_code deployments/tokens-testnet.json "make deploy-mocks-testnet" \
      LUSD USDT USDC DAI WETH WBTC PAXG PAXS
    warn "forge exited non-zero but all 8 mock tokens have code — the broadcast landed; most likely Etherscan verification failed. The feed-code and input-price-feed checks below still have to pass. Retry verification only with: cd $L1_DIR && FOUNDRY_PROFILE=deploy DEPLOYER_PRIVATE_KEY=\$DEPLOYER_PRIVATE_KEY DEPLOY_INPUT_JSON=deployments/local-testnet.json DEPLOY_OUTPUT_JSON=deployments/tokens-testnet.json forge script script/DeployMocks.s.sol:DeployMocks --rpc-url \$TESTNET_L1_RPC_URL --resume --verify --etherscan-api-key \$ETHERSCAN_API_KEY"
  fi
  [ -f deployments/tokens-testnet.json ] || fail "v1-l1/deployments/tokens-testnet.json was not created by 'make deploy-mocks-testnet'. Check the forge output above for the actual failure."
  ok "LUSD:  $(jq -r '.LUSD' deployments/tokens-testnet.json)"
  ok "USDT:  $(jq -r '.USDT' deployments/tokens-testnet.json)"
  ok "USDC:  $(jq -r '.USDC' deployments/tokens-testnet.json)"
  ok "DAI:   $(jq -r '.DAI' deployments/tokens-testnet.json)"
  ok "WETH:  $(jq -r '.WETH' deployments/tokens-testnet.json)"
  ok "WBTC:  $(jq -r '.WBTC' deployments/tokens-testnet.json)"
  ok "PAXG:  $(jq -r '.PAXG' deployments/tokens-testnet.json)"
  ok "PAXS:  $(jq -r '.PAXS' deployments/tokens-testnet.json)"

  ok "Mock price feeds: deployed fresh by DeployMocks (T2 — this chain id is not 31337)"

  # Feed-code preflight (T2): DeployMocks (T2, run above via 'make deploy-mocks-testnet')
  # always deploys a fresh MockPriceFeed per basket/entry leg on a non-31337 chain and
  # publishes all 8 addresses under tokens-testnet.json .feeds.*. There is no more
  # "known gap" — a missing or codeless feed here means DeployMocks' Sepolia branch
  # did not run, so this is a hard failure, not a warning.
  step "L1: verifying all 8 feed addresses have code (T2 feed-code preflight)..."
  for sym in LUSD PAXG DAI PAXS WBTC WETH USDC USDT; do
    feed=$(jq -r --arg s "$sym" '.feeds[$s]' deployments/tokens-testnet.json)
    [ -n "$feed" ] && [ "$feed" != "null" ] || fail "$sym missing from deployments/tokens-testnet.json .feeds — 'make deploy-mocks-testnet' did not deploy it (see T2)."
    code=$(cast code "$feed" --rpc-url "$TESTNET_L1_RPC_URL")
    [ -n "$code" ] && [ "$code" != "0x" ] || fail "$sym feed $feed has NO CODE on $TESTNET_L1_RPC_URL — DeployMocks' fresh-feed deploy (T2) did not run or the RPC points at the wrong chain."
    ok "  $sym feed -> $feed (code present)"
  done

  # Entry-asset (USDC/USDT) input pricing. These two are accepted as deposit INPUTS
  # but are not basket legs (WETH IS a basket leg and has no input feed, so it is
  # deliberately not checked here); DepositAdapter prices them through
  # `inputPriceFeeds`, which DeployMocks step 3b wires to the fresh Sepolia feeds
  # above (.feeds.USDC / .feeds.USDT).
  step "L1: verifying entry-asset (USDC/USDT) input price feeds..."
  for sym in USDC USDT; do
    tok=$(jq -r --arg s "$sym" '.[$s]' deployments/tokens-testnet.json)
    [ -n "$tok" ] && [ "$tok" != "null" ] || fail "$sym missing from deployments/tokens-testnet.json — 'make deploy-mocks-testnet' did not deploy it."
    want=$(jq -r --arg s "$sym" '.feeds[$s]' deployments/tokens-testnet.json)
    got=$(cast call "$DEPOSIT_ADAPTER" "inputPriceFeeds(address)(address)" "$tok" --rpc-url "$TESTNET_L1_RPC_URL")
    [ "$(echo "$got" | tr '[:upper:]' '[:lower:]')" = "$(echo "$want" | tr '[:upper:]' '[:lower:]')" ] \
      || fail "DepositAdapter.inputPriceFeeds($sym $tok) is $got, expected $want — 'make deploy-mocks-testnet' did not run DeployMocks step 3b."
    ok "  $sym -> $want (live)"
  done

  step "L1: deploying TokenPortal bridge (Sepolia)..."
  # ZER-29: same tolerance as the two targets above and Stage 2b/2c.
  rm -f deployments/bridge-testnet.json
  if ! INBOX_ADDRESS="$L1_INBOX_ADDRESS" ROLLUP_ADDRESS="$L1_ROLLUP_ADDRESS" \
    ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-bridge-testnet; then
    require_verify_was_attempted "make deploy-bridge-testnet"
    PORTAL_CHECK=$(jq -r '.tokenPortal // ""' deployments/bridge-testnet.json 2>/dev/null || true)
    has_code "$PORTAL_CHECK" || fail "make deploy-bridge-testnet failed and the TokenPortal ($PORTAL_CHECK) has no code on-chain — a real deploy failure, not an Etherscan one. Check the forge output above."
    # Deploying the portal is only the FIRST of five broadcast operations.
    # The other four wire it up, and nothing downstream checks them:
    # assert_l2_bridge_portal_pairing only verifies the L2 side's recorded L1
    # portal. A half-wired bridge that reaches Stage 2b becomes a governance
    # proposal to fix, so read all four back here. A verification-only failure
    # leaves every one of them correct, so this does not narrow the intended
    # tolerance at all — it only refuses to extend it to a partial broadcast.
    _wired() { cast call "$1" "$2" --rpc-url "$TESTNET_L1_RPC_URL" 2>/dev/null || echo ""; }
    BR_POOL=$(jq -r '.liquidityPoolProxy // ""' deployments/local-testnet.json 2>/dev/null || true)
    BR_DEP=$(jq -r '.depositAdapter // ""' deployments/local-testnet.json 2>/dev/null || true)
    BR_WDR=$(jq -r '.withdrawalAdapter // ""' deployments/local-testnet.json 2>/dev/null || true)
    for pair in "$BR_POOL:aztecBridge()(address):LiquidityPool.aztecBridge" \
                "$BR_DEP:tokenPortal()(address):DepositAdapter.tokenPortal" \
                "$BR_WDR:aztecBridge()(address):WithdrawalAdapter.aztecBridge"; do
      _addr="${pair%%:*}"; _rest="${pair#*:}"; _sig="${_rest%%:*}"; _label="${_rest##*:}"
      _got=$(_wired "$_addr" "$_sig")
      [ "$(printf '%s' "$_got" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$PORTAL_CHECK" | tr 'A-Z' 'a-z')" ] \
        || fail "make deploy-bridge-testnet failed and $_label is '$_got', not the new TokenPortal $PORTAL_CHECK — the broadcast died partway through wiring, which Etherscan verification cannot cause. Check the forge output above."
    done
    _got_wdr=$(_wired "$PORTAL_CHECK" "withdrawalAdapter()(address)")
    [ "$(printf '%s' "$_got_wdr" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$BR_WDR" | tr 'A-Z' 'a-z')" ] \
      || fail "make deploy-bridge-testnet failed and TokenPortal.withdrawalAdapter is '$_got_wdr', not $BR_WDR — the broadcast died partway through wiring. Check the forge output above."
    warn "forge exited non-zero but the TokenPortal at $PORTAL_CHECK has code and all four wirings read back correctly — the broadcast landed; most likely Etherscan verification failed. Retry verification only with: cd $L1_DIR && FOUNDRY_PROFILE=deploy DEPLOYER_PRIVATE_KEY=\$DEPLOYER_PRIVATE_KEY INBOX_ADDRESS=$L1_INBOX_ADDRESS ROLLUP_ADDRESS=$L1_ROLLUP_ADDRESS LIQUIDITY_POOL_PROXY=$BR_POOL DEPOSIT_ADAPTER=$BR_DEP WITHDRAWAL_ADAPTER=$BR_WDR DEPLOY_OUTPUT_JSON=deployments/bridge-testnet.json forge script script/DeployBridge.s.sol:DeployBridge --rpc-url \$TESTNET_L1_RPC_URL --resume --verify --etherscan-api-key \$ETHERSCAN_API_KEY"
  fi
  [ -f deployments/bridge-testnet.json ] || fail "v1-l1/deployments/bridge-testnet.json was not created by 'make deploy-bridge-testnet'. Check the forge output above for the actual failure."
  TOKEN_PORTAL=$(jq -r '.tokenPortal' deployments/bridge-testnet.json)
  # Checked here, not just where it is consumed: Stage 2 passes this straight into
  # `yarn deploy:clean` as L1_TOKEN_PORTAL, and a literal "null" would deploy an
  # unusable bridge after spending L2 gas. v1-l1/Makefile guards it the same way.
  { [ -n "$TOKEN_PORTAL" ] && [ "$TOKEN_PORTAL" != "null" ]; } \
    || fail "deployments/bridge-testnet.json has no .tokenPortal — 'make deploy-bridge-testnet' did not record the TokenPortal address. Nothing downstream can be wired without it."

  ok "TokenPortal: $TOKEN_PORTAL"
  # Not wired to an L2 TokenBridge yet — the L2 TokenBridge doesn't exist
  # until stage_l2_deploy runs. Wiring happens there (see wire-bridge-testnet
  # call at the end of stage_l2_deploy below).

  cd "$ROOT_DIR"
}

# ===========================================================================
# Stage 2: L2 deploy (Aztec testnet)
#
# Testnet deploys never build Noir on the fly (mirrors deploy-sandbox.sh's
# CHAIN_HOST_HEADLESS branch) — v1-l2/artifacts + v1-l2/target must already
# be prebuilt and shipped. yarn deploy:clean is Task 3's env-driven
# fee-juice bootstrap: AZTEC_RPC_HOST/L1_RPC_URL/L1_DEPLOYER_PRIVATE_KEY/
# L1_FEE_JUICE_PORTAL_ADDRESS/DEPLOY_TX_TIMEOUT_SECS all come from the
# preflight-exported and .env-loaded vars above. ETH_CHAIN_ID=11155111 is
# passed explicitly (B6) so v1-l2/utils/fee_juice.ts builds its viem client
# for sepolia instead of defaulting to foundry (31337) — without it,
# EIP-155-signed txs get rejected by a real testnet RPC. DEPLOYER_ACCOUNT_FILE
# (Task 4) tells deploy.ts's isTestnetL1Mode() branch where to persist/reload
# the real testnet deployer keypair (sandbox has no such file — it uses the
# canonical pre-deployed test account instead, unaffected by this var).
# FEE_CUSTODIAN_ACCOUNT_FILE (D-b/Db-4) is the same idea for the fee
# custodian: deploy.ts now REQUIRES it in testnet mode (a separate key file
# from DEPLOYER_ACCOUNT_FILE, so a keeper that sweeps as the custodian never
# needs the deployer's L2 secret) and refuses to run without it — set the
# same way, right below, so this stage doesn't regress the moment deploy.ts
# starts requiring it.
#
# After the L2 contracts land, wires the freshly deployed L2 TokenBridge into
# the Stage 1 L1 TokenPortal via `make wire-bridge-testnet` (v1-l1/Makefile,
# Task 4) — the same script the sandbox uses (scripts/wire-bridge.sh),
# pointed at deployments/bridge-testnet.json.
# ===========================================================================

# ---------------------------------------------------------------------------
# ZER-27 (T6): prove the L2 bridge is paired to Stage 1's L1 TokenPortal.
#
# ZeracleBridge's `portal` is a PublicImmutable its constructor writes once
# (v1-l2/contracts/zeracle-bridge/src/zeracle_bridge.nr). Deposits consume L1
# messages from it and exits message it, so a bridge holding the wrong -- or a
# zero -- portal is dead in both directions, and off-sandbox nothing can repair
# it: redeploy-bridge.ts is only ever called by deploy-sandbox.sh.
#
# The post-wire asserts below check the L1 side only (TokenPortal.l2Bridge()),
# which a zero-portal bridge passes happily. This runs first, and reads the
# portal the bridge was actually CONSTRUCTED with, as recorded in
# deployment.json's `bridge.l1Portal` by scripts/deploy.ts -- the same block
# redeploy-bridge.ts rewrites, so the two writers cannot drift apart.
#
# Reads deployment.json from the current directory (stage_l2_deploy has already
# cd'd to $L2_DIR). $1 is Stage 1's TokenPortal address.
# ---------------------------------------------------------------------------
assert_bridge_portal_matches() {
  local expected="$1"
  local recorded

  # Stage 1's side first. TOKEN_PORTAL is read straight out of bridge-testnet.json
  # with no validation, so an empty or null value here means Stage 1 never produced
  # a portal -- and reporting that as an L2 mismatch would send the operator hunting
  # a stale rerun when the fault is upstream.
  if [ -z "$expected" ] || [ "$expected" = "null" ]; then
    fail "Stage 1 produced no TokenPortal address (v1-l1/deployments/bridge-testnet.json .tokenPortal is empty or null), so the L2 bridge's pairing cannot be checked. This is a STAGE 1 failure, not an L2 one -- re-read the 'make deploy-bridge-testnet' output above."
  fi

  jq -e . deployment.json >/dev/null 2>&1 \
    || fail "v1-l2/deployment.json is not valid JSON. 'yarn deploy:clean' reported success but left a file that cannot be read, so nothing downstream can be trusted."

  recorded=$(jq -r '.bridge.l1Portal // ""' deployment.json)

  if [ -z "$recorded" ] || [ "$recorded" = "null" ]; then
    fail "v1-l2/deployment.json has no .bridge.l1Portal. The L2 bridge deploy did not record the L1 portal it was constructed with, so there is no way to tell whether it is paired to $expected or to nothing at all. This field is written by v1-l2/scripts/deploy.ts (ZER-27 T6) -- deploying from a v1-l2 that predates it is not supported on a live network."
  fi

  local recorded_lc expected_lc
  recorded_lc=$(echo "$recorded" | tr '[:upper:]' '[:lower:]')
  expected_lc=$(echo "$expected" | tr '[:upper:]' '[:lower:]')

  if [ "$recorded_lc" = "0x0000000000000000000000000000000000000000" ]; then
    fail "The L2 bridge was deployed with a ZERO L1 portal. Its portal is a write-once PublicImmutable and there is no off-sandbox re-pairing path, so this bridge can never carry a deposit or an exit. Check that L1_TOKEN_PORTAL reached 'yarn deploy:clean' in Stage 2 above. Refusing to spend the one-shot wire-bridge-testnet call on it."
  fi

  if [ "$recorded_lc" != "$expected_lc" ]; then
    fail "The L2 bridge was deployed against L1 portal $recorded, but Stage 1 deployed TokenPortal at $expected. The bridge's portal is immutable, so wiring this pair would produce a permanently one-sided bridge. Refusing to spend the one-shot wire-bridge-testnet call on it."
  fi

  ok "L2 bridge portal matches Stage 1 TokenPortal ($expected)"
}

# ---------------------------------------------------------------------------
# ZER-178 (ZER-32): prove the deployed FeeDistribution enforces the owner's
# flush minimum.
#
# FeeDistribution's `minimum_batch_enforced` is a PublicImmutable its
# constructor writes once, so a testnet FeeDistribution deployed without it
# lets anyone force four paid L1 relays for a trivial flush, for its lifetime.
# v1-l2/scripts/deploy.ts reads both values back from the deployed contract
# (is_minimum_batch_enforced, get_minimum_batch_amount) and records what the
# chain reports in deployment.json; this checks those recorded values against
# $1 (TESTNET_FLUSH_MINIMUM) before the one-shot wire-bridge-testnet call is
# spent on a FeeDistribution with the wrong flush policy.
#
# Reads deployment.json from the current directory (stage_l2_deploy has
# already cd'd to $L2_DIR).
# ---------------------------------------------------------------------------
assert_fee_distribution_flush_minimum() {
  local expected="$1"
  local recorded

  jq -e . deployment.json >/dev/null 2>&1 \
    || fail "v1-l2/deployment.json is not valid JSON. 'yarn deploy:clean' reported success but left a file that cannot be read, so nothing downstream can be trusted."

  if ! jq -e '.feeDistributionFlushMinimumEnforced != null and .feeDistributionFlushMinimum != null' deployment.json >/dev/null; then
    fail "v1-l2/deployment.json has no feeDistributionFlushMinimumEnforced / feeDistributionFlushMinimum. The v1-l2 that ran Stage 2 predates ZER-32, so its FeeDistribution cannot enforce a flush minimum at all -- deploying it to a live network is not supported. Refusing to spend the one-shot wire-bridge-testnet call on it."
  fi

  # `== true`, not `jq -r` + string compare: the string "true" is not a boolean.
  if ! jq -e '.feeDistributionFlushMinimumEnforced == true' deployment.json >/dev/null; then
    fail "The deployed FeeDistribution reports the flush minimum NOT enforced (feeDistributionFlushMinimumEnforced=$(jq -c '.feeDistributionFlushMinimumEnforced' deployment.json)). The flag is immutable, so this FeeDistribution can never enforce it; check that ZERACLE_ENFORCE_FLUSH_MINIMUM=1 reached 'yarn deploy:clean'. Refusing to spend the one-shot wire-bridge-testnet call on it."
  fi

  # A string, exactly as deploy.ts writes it: a JSON number this large loses
  # precision in some jq versions, so only the string form is trusted.
  recorded=$(jq -r '.feeDistributionFlushMinimum | if type == "string" then . else "not a string: \(tojson)" end' deployment.json)
  if [ "$recorded" != "$expected" ]; then
    fail "The deployed FeeDistribution reports a flush minimum of $recorded base units, expected $expected (10 ZRCL, owner decision 2026-09-26). Check that ZERACLE_FLUSH_MINIMUM reached 'yarn deploy:clean'."
  fi

  ok "FeeDistribution flush minimum: $recorded base units (10 ZRCL), enforced"
}

stage_l2_deploy() {
  cd "$L2_DIR"

  step "L2: checking for prebuilt artifacts..."
  [ -f artifacts/index.ts ] || fail "v1-l2/artifacts/index.ts is missing. Testnet deploys never build Noir on the fly (same rule as deploy-sandbox.sh's headless branch) — run 'yarn build' once and ship the resulting artifacts/ + target/ directories before running this script."
  [ -n "$(ls target/*.json 2>/dev/null)" ] || fail "v1-l2/target/*.json is missing. Compiled Noir artifacts must already be present — run 'yarn build' first."
  ok "Prebuilt L2 artifacts present (artifacts/index.ts, target/*.json)"

  step "L2: deploying Aztec testnet contracts + fee-juice bootstrap..."
  DEPLOYER_ACCOUNT_FILE="$SCRIPT_DIR/deployer-account.json"
  export DEPLOYER_ACCOUNT_FILE
  # D-b/Db-4: same treatment as DEPLOYER_ACCOUNT_FILE above — set + exported
  # (not passed inline to yarn deploy:clean, mirroring exactly how
  # DEPLOYER_ACCOUNT_FILE itself reaches deploy.ts) rather than read from
  # .env, since it names a path this script computes, not a value the
  # operator supplies.
  FEE_CUSTODIAN_ACCOUNT_FILE="$SCRIPT_DIR/fee-custodian-account.json"
  export FEE_CUSTODIAN_ACCOUNT_FILE
  # Compliance (attestor + zkPassport + bridge exit enforcement) is not part of
  # the testnet release (owner decision 2026-09-13). ZERACLE_COMPLIANCE=off
  # deploys no Compliance contract and gives the bridge AztecAddress.ZERO (exit
  # enforcement disabled); deploy.ts refuses a live-network deploy without it.
  # ZER-178 (ZER-32): the FeeDistribution flush minimum is passed explicitly --
  # enforced, at TESTNET_FLUSH_MINIMUM (10 ZRCL) -- and checked right after by
  # assert_fee_distribution_flush_minimum.
  AZTEC_RPC_HOST="$AZTEC_NODE_URL" \
    L1_RPC_URL="$TESTNET_L1_RPC_URL" \
    L1_DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    L1_FEE_JUICE_PORTAL_ADDRESS="$L1_FEE_JUICE_PORTAL_ADDRESS" \
    L1_TOKEN_PORTAL="$TOKEN_PORTAL" \
    L1_TREASURY="$TREASURY" \
    L1_COLLATERAL_RESERVE="$COLLATERAL_RESERVE" \
    L1_NETWORK_FUND="$NETWORK_FUND" \
    DEPLOY_TX_TIMEOUT_SECS=600 \
    ETH_CHAIN_ID=11155111 \
    ZERACLE_COMPLIANCE=off \
    ZERACLE_ENFORCE_FLUSH_MINIMUM=1 \
    ZERACLE_FLUSH_MINIMUM="$TESTNET_FLUSH_MINIMUM" \
    yarn deploy:clean
  [ -f deployment.json ] || fail "v1-l2/deployment.json was not created by 'yarn deploy:clean'. Check the deploy output above for the actual failure."
  [ "$(jq -r '.complianceEnabled' deployment.json)" = "false" ] || fail "v1-l2/deployment.json reports complianceEnabled=$(jq -r '.complianceEnabled' deployment.json) — the testnet release must deploy with ZERACLE_COMPLIANCE=off (no attestor/zkPassport on testnet)."
  [ "$(jq -r '.contracts.compliance' deployment.json)" = "null" ] || fail "v1-l2/deployment.json lists a Compliance contract ($(jq -r '.contracts.compliance' deployment.json)) — expected none with ZERACLE_COMPLIANCE=off."
  ok "Compliance OFF: no Compliance contract deployed; bridge exit enforcement disabled"

  ok "ZeracleToken:    $(jq -r '.contracts.zeracleToken' deployment.json)"
  ok "TokenBridge:     $(jq -r '.contracts.tokenBridge' deployment.json)"
  ok "FeeDistribution: $(jq -r '.contracts.feeDistribution' deployment.json)"
  ok "PaymentEscrow:   $(jq -r '.contracts.paymentEscrow' deployment.json)"
  ok "SponsoredFPC:    $(jq -r '.contracts.sponsoredFpc' deployment.json) (Aztec's canonical instance — deployed and funded by Aztec; Zeracle deploys none here and has no funding step to run)"
  ok "Deployer:        $(jq -r '.deployer' deployment.json)"
  ok "Deployer keys:   $DEPLOYER_ACCOUNT_FILE (BACK THIS UP — never commit/ship it)"
  ok "Fee-custodian keys: $FEE_CUSTODIAN_ACCOUNT_FILE (BACK THIS UP — never commit/ship it; no on-chain deployment needed: initializerless, sweep pays via the sponsored FPC)"

  assert_bridge_portal_matches "$TOKEN_PORTAL"
  assert_fee_distribution_flush_minimum "$TESTNET_FLUSH_MINIMUM"

  step "L2: wiring L1 TokenPortal to the freshly deployed L2 TokenBridge..."
  L2_BRIDGE_ADDRESS=$(jq -r '.contracts.tokenBridge' deployment.json)
  ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make -C "$L1_DIR" wire-bridge-testnet
  WIRED_L2_BRIDGE=$(cast call "$(jq -r '.tokenPortal' "$L1_DIR/deployments/bridge-testnet.json")" "l2Bridge()(bytes32)" --rpc-url "$TESTNET_L1_RPC_URL")
  # Case-insensitive substring match: cast's bytes32 output and AztecAddress's
  # toString() aren't guaranteed to agree on hex casing, only on value.
  WIRED_L2_BRIDGE_LC=$(echo "$WIRED_L2_BRIDGE" | tr '[:upper:]' '[:lower:]')
  L2_BRIDGE_ADDRESS_LC=$(echo "${L2_BRIDGE_ADDRESS#0x}" | tr '[:upper:]' '[:lower:]')
  [[ "$WIRED_L2_BRIDGE_LC" == *"$L2_BRIDGE_ADDRESS_LC"* ]] || fail "wire-bridge-testnet ran but TokenPortal.l2Bridge() ($WIRED_L2_BRIDGE) does not match the deployed TokenBridge ($L2_BRIDGE_ADDRESS). Check v1-l1/scripts/wire-bridge.sh output above."
  ok "TokenPortal wired to TokenBridge $L2_BRIDGE_ADDRESS"

  # Same postcondition for the fee-flush leg: wire-bridge.sh sets BOTH l2Bridge
  # and l2FeeDistribution, and TokenPortal.claimFees only accepts messages whose
  # sender is l2FeeDistribution — so an unwired FeeDistribution makes every
  # flushed fee message unconsumable. Assert it rather than trusting the script.
  L2_FEE_DISTRIBUTION_ADDRESS=$(jq -r '.contracts.feeDistribution' deployment.json)
  WIRED_L2_FD=$(cast call "$(jq -r '.tokenPortal' "$L1_DIR/deployments/bridge-testnet.json")" "l2FeeDistribution()(bytes32)" --rpc-url "$TESTNET_L1_RPC_URL")
  WIRED_L2_FD_LC=$(echo "$WIRED_L2_FD" | tr '[:upper:]' '[:lower:]')
  L2_FEE_DISTRIBUTION_ADDRESS_LC=$(echo "${L2_FEE_DISTRIBUTION_ADDRESS#0x}" | tr '[:upper:]' '[:lower:]')
  [[ "$WIRED_L2_FD_LC" == *"$L2_FEE_DISTRIBUTION_ADDRESS_LC"* ]] || fail "wire-bridge-testnet ran but TokenPortal.l2FeeDistribution() ($WIRED_L2_FD) does not match the deployed FeeDistribution ($L2_FEE_DISTRIBUTION_ADDRESS). Fee flushes would produce messages claimFees can never consume. Check v1-l1/scripts/wire-bridge.sh output above."
  ok "TokenPortal wired to FeeDistribution $L2_FEE_DISTRIBUTION_ADDRESS"

  cd "$ROOT_DIR"
}

# ===========================================================================
# Stage 2b: governance deploy + ownership handover (FINAL L1 stage, after bridge wiring)
# ===========================================================================
stage_governance_handover() {
  cd "$L1_DIR"
  step "Governance: deploying authority/timelock/validator and handing over L1 ownership (Sepolia)..."
  # GOV_AUTHORITY/GOV_TIMELOCK/GOV_VALIDATOR: exported by the preflight
  # (only when set); forge's vm.envOr treats an empty-but-set env var as
  # unset, so nothing further is needed here to signal fresh-deploy vs
  # resume mode. (A ${VAR:+NAME="$VAR"} prefix on the command line is NOT
  # safe here: once expanded it becomes the literal word `NAME=value`,
  # which bash parses as the COMMAND NAME, not an env assignment -> "command
  # not found" (exit 127) whenever the var is set.)
  # The verify-tolerance check below must only ever see a file written by
  # THIS run: a failure before forge rewrites the file would otherwise leave
  # a stale governance-testnet.json from a previous run, whose .authority
  # still has code on-chain -> a false "the broadcast landed" warning.
  rm -f deployments/governance-testnet.json
  if ! ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    GOV_PROPOSER="$GOV_PROPOSER" GOV_PROPOSER_2="$GOV_PROPOSER_2" GOV_GUARDIAN="$GOV_GUARDIAN" \
    GOV_TRANSITION_SECONDS="$GOV_TRANSITION_SECONDS" GOV_TIMELOCK_DELAY="$GOV_TIMELOCK_DELAY" \
    make deploy-governance-testnet; then
    # deployments/governance-testnet.json is written at simulation time, so
    # its mere existence is NOT proof the broadcast landed. Check on-chain
    # code at the recorded authority address instead: a non-zero forge exit
    # after a successful broadcast is most likely --verify (Etherscan) failing.
    # ZER-29: with no Etherscan key, --verify was never attempted, so this
    # cannot be a verification failure. Also uses has_code, which treats empty
    # `cast code` output as NO code rather than as success.
    require_verify_was_attempted "make deploy-governance-testnet"
    AUTH=$(jq -r '.authority // ""' deployments/governance-testnet.json 2>/dev/null || true)
    if has_code "$AUTH"; then
      warn "forge exited non-zero but the GovernanceAuthority at $AUTH has code — the broadcast landed; most likely Etherscan verification failed. Retry verification only by re-running the SAME make target with --resume added, keeping every env var the recipe sets: DeployGovernance reads GOV_PROPOSER, GOV_PROPOSER_2, GOV_GUARDIAN, GOV_TRANSITION_SECONDS, GOV_TIMELOCK_DELAY, LIQUIDITY_POOL_PROXY, DEPOSIT_ADAPTER, WITHDRAWAL_ADAPTER, BRIDGE_GUARD, TREASURY, COLLATERAL_RESERVE and more via vm.envAddress, so a bare forge invocation aborts immediately. See the deploy-governance-testnet recipe in v1-l1/Makefile"
    else
      fail "make deploy-governance-testnet failed before the broadcast landed (no code at the authority address). Check the forge output above; to resume a partial handover set GOV_AUTHORITY/GOV_TIMELOCK/GOV_VALIDATOR."
    fi
  fi
  [ -f deployments/governance-testnet.json ] || fail "v1-l1/deployments/governance-testnet.json was not created by 'make deploy-governance-testnet'. Check the forge output above."
  ok "GovernanceAuthority: $(jq -r '.authority' deployments/governance-testnet.json)"
  ok "ZeracleTimelock:     $(jq -r '.timelock' deployments/governance-testnet.json)"
  ok "UpgradeValidator:    $(jq -r '.validator' deployments/governance-testnet.json)"
  cd "$ROOT_DIR"
}

# ===========================================================================
# Stage 2c: BasketManager deploy + pool wiring (after the governance handover)
#
# ORDERING. `LiquidityPool.setBasketManager` is owner-gated and ONE-SHOT, so it
# gets exactly one chance to land — but it cannot run before Stage 2b:
# BasketManager's constructor takes the GovernanceAuthority address, and
# DeployGovernance deploys the authority AND hands ownership over in a single
# broadcast, leaving no seam between them. This stage therefore runs immediately
# AFTER the handover and routes the call through
# `authority.execute(pool, setBasketManager(...))`, which the deployer may do
# for as long as it is the authority's currentAuthority() — the whole
# GOV_TRANSITION_SECONDS admin phase (180 d by default). DeployBasketManager
# asserts `pool.basketManager() != 0` afterwards, so a deploy can never silently
# leave the one-shot unfired.
#
# `setBasketVote` stays UNSET — the L2 BasketVote contract is Phase 2 and
# nothing here may fail on its absence. No BasketManager selector is added to
# the guardian's emergency allow-list, deliberately: the guardian lane is
# stop-only, and `setParams` would hand one guardian key control of quorum,
# majority and the execution delay. DeployBasketManager asserts that too.
# ===========================================================================
stage_basket_manager() {
  cd "$L1_DIR"
  step "Basket: deploying BasketManager and wiring it into the LiquidityPool (Sepolia)..."

  # Never fire the one-shot `setBasketManager` onto an EMPTY basket. If
  # `deploy-mocks-testnet` ever "succeeded" without its `setComposition` call
  # actually landing, locking an empty pool behind the manager means repopulating
  # it needs a full open -> queue -> execute cycle — 48 h on testnet
  # (BASKET_EXECUTION_DELAY_FLOOR) — before a single asset can be added back.
  BASKET_ASSETS=$(cast call "$LIQUIDITY_POOL_PROXY" "getSupportedAssets()(address[])" --rpc-url "$TESTNET_L1_RPC_URL")
  [ "$BASKET_ASSETS" != "[]" ] || fail "LiquidityPool ($LIQUIDITY_POOL_PROXY) has an EMPTY basket (getSupportedAssets() returned []) — refusing to wire/fire the one-shot setBasketManager onto it. Confirm 'make deploy-mocks-testnet' actually ran setComposition before retrying."

  # BASKET_MANAGER is the deploy script's RESUME variable, exported by the
  # preflight, which has already proved it has code on-chain and ANNOUNCED that
  # this run resumes onto it instead of deploying fresh.
  # The verify-tolerance check below must only ever see a file written by THIS
  # run: a failure before forge rewrites it would otherwise leave a stale
  # basket-testnet.json whose .basketManager still has code on-chain -> a false
  # "the broadcast landed" warning.
  rm -f deployments/basket-testnet.json
  if ! ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    BASKET_VOTING_WINDOW="$BASKET_VOTING_WINDOW" BASKET_EXECUTION_DELAY="$BASKET_EXECUTION_DELAY" \
    BASKET_VOTING_WINDOW_FLOOR="$BASKET_VOTING_WINDOW_FLOOR" \
    BASKET_EXECUTION_DELAY_FLOOR="$BASKET_EXECUTION_DELAY_FLOOR" \
    make deploy-basket-manager-testnet; then
    # deployments/basket-testnet.json is written at simulation time, so its mere
    # existence is NOT proof the broadcast landed. Check on-chain code at the
    # recorded manager address instead: a non-zero forge exit after a successful
    # broadcast is most likely --verify (Etherscan) failing.
    # ZER-29: same two corrections as Stage 2b above.
    require_verify_was_attempted "make deploy-basket-manager-testnet"
    BM=$(jq -r '.basketManager // ""' deployments/basket-testnet.json 2>/dev/null || true)
    if has_code "$BM"; then
      warn "forge exited non-zero but the BasketManager at $BM has code — the broadcast landed; most likely Etherscan verification failed. Retry verification only by re-running the SAME make target with --resume added, keeping every env var the recipe sets: DeployBasketManager reads TOKEN_PORTAL, LIQUIDITY_POOL_PROXY, GOV_AUTHORITY, GOV_PROPOSER and the four BASKET_* window/floor values via vm.env*, so a bare forge invocation aborts immediately. See the deploy-basket-manager-testnet recipe in v1-l1/Makefile"
      warn "NOTE on --libraries: BasketManager needs NONE (it only reads compile-time constants from BasketCompositionLib), so a library flag will not fix a failure here. The LiquidityPool IMPLEMENTATION is the contract that does need --libraries, and the usual cause of ITS verification failing is a STALE basketCompositionLib: the link is per-implementation, so a UUPS upgrade redeploys the implementation and may relink it against a newly deployed library, leaving the recorded value describing a library the live pool no longer uses. Nothing asserts that value is current — re-read the link target Upgrade.s.sol logs after every upgrade and refresh local-testnet.json + the manifest before verifying."
    else
      fail "make deploy-basket-manager-testnet failed before the broadcast landed (no code at the manager address). Check the forge output above; to resume a partial wiring set BASKET_MANAGER to the manager this run deployed."
    fi
  fi
  [ -f deployments/basket-testnet.json ] || fail "v1-l1/deployments/basket-testnet.json was not created by 'make deploy-basket-manager-testnet'. Check the forge output above."
  BASKET_MANAGER=$(jq -r '.basketManager' deployments/basket-testnet.json)
  [ -n "$BASKET_MANAGER" ] && [ "$BASKET_MANAGER" != "null" ] || fail "basketManager not found in deployments/basket-testnet.json"

  # Post-handover postcondition, re-checked from the shell so the stage fails
  # even if the script's own assertions were somehow skipped. The one-shot has
  # no second chance, so this is the last place it can be caught cheaply.
  POOL_BM=$(cast call "$(jq -r '.liquidityPoolProxy' deployments/local-testnet.json)" "basketManager()(address)" --rpc-url "$TESTNET_L1_RPC_URL")
  POOL_BM_LC=$(echo "$POOL_BM" | tr '[:upper:]' '[:lower:]')
  BASKET_MANAGER_LC=$(echo "$BASKET_MANAGER" | tr '[:upper:]' '[:lower:]')
  [ "$POOL_BM_LC" = "$BASKET_MANAGER_LC" ] || fail "LiquidityPool.basketManager() ($POOL_BM) does not match the deployed BasketManager ($BASKET_MANAGER) — the one-shot setBasketManager did not land, and it cannot be retried against a different manager."

  # Read the manager's ACTUAL on-chain params from the JSON `_save()` wrote (populated
  # from `manager.votingWindow()` etc., not echoed env vars) — same shape as
  # deploy-sandbox.sh's basket.json re-read. This matters in RESUME mode: with
  # BASKET_MANAGER set, DeployBasketManager.s.sol's `_resolveManager` adopts the
  # manager's ON-CHAIN floors (overwriting `w.votingWindowFloor`/`w.executionDelayFloor`)
  # and `_wire` never calls `setParams`, so a resumed manager's real window/delay/floors
  # can differ from whatever BASKET_VOTING_WINDOW/BASKET_EXECUTION_DELAY this shell holds
  # — printing the env vars here would silently misreport what actually got wired.
  ACTUAL_VOTING_WINDOW=$(jq -r '.votingWindow' deployments/basket-testnet.json)
  ACTUAL_EXECUTION_DELAY=$(jq -r '.executionDelay' deployments/basket-testnet.json)
  ACTUAL_VOTING_WINDOW_FLOOR=$(jq -r '.votingWindowFloor' deployments/basket-testnet.json)
  ACTUAL_EXECUTION_DELAY_FLOOR=$(jq -r '.executionDelayFloor' deployments/basket-testnet.json)

  # `_assertBasketManager` only re-checks the CONTRACT's hard minima (30 min / 1 h),
  # not the stricter testnet floor (3 d / 24 h) this script's own preflight enforces for
  # a FRESH deploy. A resume onto a manager wired for a different environment (e.g. the
  # sandbox) would sail through that assertion and land here with real params below the
  # testnet minimum — so check the ON-CHAIN values again, explicitly, against the
  # testnet floor constants (not the shell's possibly-irrelevant BASKET_*_FLOOR env vars,
  # which only bind a FRESH deploy's constructor args).
  [ "$ACTUAL_VOTING_WINDOW_FLOOR" -ge 259200 ] || fail "BasketManager $BASKET_MANAGER has votingWindowFloor=${ACTUAL_VOTING_WINDOW_FLOOR}s on-chain — below the 3 d (259200 s) testnet minimum. This manager was wired for a different environment (e.g. the sandbox) and must not be reused here."
  [ "$ACTUAL_EXECUTION_DELAY_FLOOR" -ge 86400 ] || fail "BasketManager $BASKET_MANAGER has executionDelayFloor=${ACTUAL_EXECUTION_DELAY_FLOOR}s on-chain — below the 24 h (86400 s) testnet minimum. This manager was wired for a different environment (e.g. the sandbox) and must not be reused here."
  [ "$ACTUAL_VOTING_WINDOW" -ge 259200 ] || fail "BasketManager $BASKET_MANAGER has votingWindow=${ACTUAL_VOTING_WINDOW}s on-chain — below the 3 d (259200 s) testnet minimum."
  [ "$ACTUAL_EXECUTION_DELAY" -ge 86400 ] || fail "BasketManager $BASKET_MANAGER has executionDelay=${ACTUAL_EXECUTION_DELAY}s on-chain — below the 24 h (86400 s) testnet minimum."
  ok "BasketManager: $BASKET_MANAGER (window ${ACTUAL_VOTING_WINDOW}s / delay ${ACTUAL_EXECUTION_DELAY}s) [on-chain]"

  # Verification of the LiquidityPool IMPLEMENTATION (not this manager) needs the
  # linked library address, which forge deploys during the L1 stage:
  #   --libraries contracts/libraries/BasketCompositionLib.sol:BasketCompositionLib:<addr>
  # It is recorded as basketCompositionLib in local-testnet.json and carried into
  # the manifest. The link is per-implementation, so a UUPS upgrade may relink
  # and the recorded value must be refreshed from the upgrade's output.
  BASKET_LIB=$(jq -r '.basketCompositionLib // ""' deployments/local-testnet.json)
  if [ -n "$BASKET_LIB" ] && [ "$BASKET_LIB" != "null" ]; then
    ok "BasketCompositionLib: $BASKET_LIB (pass to --libraries when verifying the pool implementation; NOT needed for BasketManager)"
    ok "  ^ recorded by THIS deploy. Nothing re-checks it later: a UUPS upgrade redeploys the"
    ok "    pool implementation and may relink it against a new library, so refresh this value"
    ok "    from Upgrade.s.sol's log before verifying an upgraded implementation."
  else
    warn "basketCompositionLib is missing from local-testnet.json — LiquidityPool implementation verification will fail without --libraries. Re-run the L1 stage with an up-to-date DeployLocal."
  fi
  cd "$ROOT_DIR"
}

# ===========================================================================
# Stage 3: manifest + web env sync
#
# Composes deployments/testnet/deployment-manifest.json (same shape as
# sandbox-local's generated manifest, minus rpc.accountServer — there is no
# chain-server on testnet — and with l1ChainId added to rpc), then syncs its
# *_ADDRESS keys into interfaces/apps/web/.env.testnet via the existing
# sync-env-addresses.py, then fills the endpoint vars that script
# deliberately leaves alone.
# ===========================================================================

stage_manifest_sync() {
  cd "$ROOT_DIR"
  step "Manifest: composing deployments/testnet/deployment-manifest.json..."

  L1_LOCAL="$L1_DIR/deployments/local-testnet.json"
  L1_TOKENS="$L1_DIR/deployments/tokens-testnet.json"
  L1_BRIDGE="$L1_DIR/deployments/bridge-testnet.json"
  L1_GOV="$L1_DIR/deployments/governance-testnet.json"
  L1_BASKET="$L1_DIR/deployments/basket-testnet.json"
  L2_DEPLOY="$L2_DIR/deployment.json"

  for f in "$L1_LOCAL" "$L1_TOKENS" "$L1_BRIDGE" "$L1_GOV" "$L1_BASKET" "$L2_DEPLOY"; do
    [ -f "$f" ] || fail "$f is missing — stage_l1_deploy, stage_l2_deploy, stage_governance_handover and stage_basket_manager must all complete successfully before the manifest stage can run."
  done

  MANIFEST_PATH="$SCRIPT_DIR/deployment-manifest.json"
  cat > "$MANIFEST_PATH" <<MANIFEST
{
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "network": "testnet",
  "rpc": {
    "l1": "$TESTNET_L1_RPC_URL",
    "l2Pxe": "$AZTEC_NODE_URL",
    "l1ChainId": 11155111
  },
  "l1": {
    "chainId": 11155111,
    "contracts": {
      "liquidityPoolProxy": "$(jq -r '.liquidityPoolProxy' "$L1_LOCAL")",
      "liquidityPoolImpl": "$(jq -r '.liquidityPoolImpl' "$L1_LOCAL")",
      "depositAdapter": "$(jq -r '.depositAdapter' "$L1_LOCAL")",
      "withdrawalAdapter": "$(jq -r '.withdrawalAdapter' "$L1_LOCAL")",
      "bridgeGuard": "$(jq -r '.bridgeGuard' "$L1_LOCAL")",
      "treasury": "$(jq -r '.treasury' "$L1_LOCAL")",
      "collateralReserve": "$(jq -r '.collateralReserve' "$L1_LOCAL")",
      "networkFund": "$(jq -r '.networkFund' "$L1_LOCAL")",
      "tokenPortal": "$(jq -r '.tokenPortal' "$L1_BRIDGE")",
      "feeJuicePortal": "$(jq -r '.l1ContractAddresses.feeJuicePortal' "$L2_DEPLOY")",
      "feeJuice": "$(jq -r '.l1ContractAddresses.feeJuice' "$L2_DEPLOY")",
      "feeAssetHandler": "$(jq -r '.l1ContractAddresses.feeAssetHandler // ""' "$L2_DEPLOY")",
      "mockAztecBridge": "$(jq -r '.mockAztecBridge' "$L1_LOCAL")",
      "chainlinkOracle": "$(jq -r '.chainlinkOracle' "$L1_LOCAL")",
      "uniswapTwap": "$(jq -r '.uniswapTwap' "$L1_LOCAL")",
      "mockDexAggregator": "$(jq -r '.mockDexAggregator' "$L1_LOCAL")",
      "basketManager": "$(jq -r '.basketManager' "$L1_BASKET")",
      "basketCompositionLib": "$(jq -r '.basketCompositionLib' "$L1_LOCAL")"
    },
    "basket": {
      "manager": "$(jq -r '.basketManager' "$L1_BASKET")",
      "allowedRouter": "$(jq -r '.allowedRouter' "$L1_BASKET")",
      "votingWindow": $(jq -r '.votingWindow' "$L1_BASKET"),
      "executionDelay": $(jq -r '.executionDelay' "$L1_BASKET"),
      "votingWindowFloor": $(jq -r '.votingWindowFloor' "$L1_BASKET"),
      "executionDelayFloor": $(jq -r '.executionDelayFloor' "$L1_BASKET"),
      "quorumBps": $(jq -r '.quorumBps' "$L1_BASKET"),
      "majorityBps": $(jq -r '.majorityBps' "$L1_BASKET"),
      "priceSources": $(jq -c '.priceSources' "$L1_TOKENS")
    },
    "governance": {
      "authority": "$(jq -r '.authority' "$L1_GOV")",
      "timelock": "$(jq -r '.timelock' "$L1_GOV")",
      "validator": "$(jq -r '.validator' "$L1_GOV")",
      "admin": "$(jq -r '.admin' "$L1_GOV")",
      "guardian": "$(jq -r '.guardian' "$L1_GOV")",
      "proposer": "$(jq -r '.proposer' "$L1_GOV")",
      "proposer2": "$(jq -r '.proposer2 // ""' "$L1_GOV")",
      "transitionAt": $(jq -r '.transitionAt' "$L1_GOV"),
      "timelockDelay": $(jq -r '.timelockDelay' "$L1_GOV"),
      "executionWindow": $(jq -r '.executionWindow' "$L1_GOV")
    },
    "tokens": {
      "LUSD": { "address": "$(jq -r '.LUSD' "$L1_TOKENS")", "decimals": 18 },
      "USDT": { "address": "$(jq -r '.USDT' "$L1_TOKENS")", "decimals": 6 },
      "USDC": { "address": "$(jq -r '.USDC' "$L1_TOKENS")", "decimals": 6 },
      "DAI":  { "address": "$(jq -r '.DAI' "$L1_TOKENS")",  "decimals": 18 },
      "WETH": { "address": "$(jq -r '.WETH' "$L1_TOKENS")", "decimals": 18 },
      "WBTC": { "address": "$(jq -r '.WBTC' "$L1_TOKENS")", "decimals": 8 },
      "PAXG": { "address": "$(jq -r '.PAXG' "$L1_TOKENS")", "decimals": 18 },
      "PAXS": { "address": "$(jq -r '.PAXS' "$L1_TOKENS")", "decimals": 18 }
    }
  },
  "l2": {
    "pxeUrl": "$(jq -r '.network' "$L2_DEPLOY")",
    "contracts": {
      "zeracleToken": "$(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")",
      "tokenBridge": "$(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")",
      "feeDistribution": "$(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")",
      "paymentEscrow": "$(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")",
      "sponsoredFpc": "$(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY")"
    },
    "deployer": "$(jq -r '.deployer' "$L2_DEPLOY")"
  },
  "env": {
    "VITE_LIQUIDITY_POOL_ADDRESS": "$(jq -r '.liquidityPoolProxy' "$L1_LOCAL")",
    "VITE_DEPOSIT_ADAPTER_ADDRESS": "$(jq -r '.depositAdapter' "$L1_LOCAL")",
    "VITE_WITHDRAWAL_ADAPTER_ADDRESS": "$(jq -r '.withdrawalAdapter' "$L1_LOCAL")",
    "VITE_BRIDGE_GUARD_ADDRESS": "$(jq -r '.bridgeGuard' "$L1_LOCAL")",
    "VITE_TREASURY_ADDRESS": "$(jq -r '.treasury' "$L1_LOCAL")",
    "VITE_COLLATERAL_RESERVE_ADDRESS": "$(jq -r '.collateralReserve' "$L1_LOCAL")",
    "VITE_BASKET_MANAGER_ADDRESS": "$(jq -r '.basketManager' "$L1_BASKET")",
    "VITE_TOKEN_PORTAL_ADDRESS": "$(jq -r '.tokenPortal' "$L1_BRIDGE")",
    "VITE_ZRCL_CONTRACT_ADDRESS": "$(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")",
    "VITE_BRIDGE_CONTRACT_ADDRESS": "$(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")",
    "VITE_FEE_DISTRIBUTION_ADDRESS": "$(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")",
    "VITE_PAYMENT_ESCROW_ADDRESS": "$(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")",
    "VITE_SPONSORED_FPC_ADDRESS": "$(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY")",
    "VITE_LUSD_L1_ADDRESS": "$(jq -r '.LUSD' "$L1_TOKENS")",
    "VITE_USDT_L1_ADDRESS": "$(jq -r '.USDT' "$L1_TOKENS")",
    "VITE_USDC_L1_ADDRESS": "$(jq -r '.USDC' "$L1_TOKENS")",
    "VITE_DAI_L1_ADDRESS": "$(jq -r '.DAI' "$L1_TOKENS")",
    "VITE_WETH_L1_ADDRESS": "$(jq -r '.WETH' "$L1_TOKENS")",
    "VITE_WBTC_L1_ADDRESS": "$(jq -r '.WBTC' "$L1_TOKENS")",
    "VITE_PAXG_L1_ADDRESS": "$(jq -r '.PAXG' "$L1_TOKENS")",
    "VITE_PAXS_L1_ADDRESS": "$(jq -r '.PAXS' "$L1_TOKENS")",
    "VITE_LUSD_USD_FEED_ADDRESS": "$(jq -r '.feeds.LUSD' "$L1_TOKENS")",
    "VITE_USDT_USD_FEED_ADDRESS": "$(jq -r '.feeds.USDT' "$L1_TOKENS")",
    "VITE_USDC_USD_FEED_ADDRESS": "$(jq -r '.feeds.USDC' "$L1_TOKENS")",
    "VITE_ETH_USD_FEED_ADDRESS": "$(jq -r '.feeds.WETH' "$L1_TOKENS")",
    "VITE_BTC_USD_FEED_ADDRESS": "$(jq -r '.feeds.WBTC' "$L1_TOKENS")"
  }
}
MANIFEST
  ok "Written $MANIFEST_PATH"

  step "Manifest: writing the public manifest for chain-view..."
  PM_ENV_ID=testnet PM_KIND=live PM_LABEL="Aztec testnet + Sepolia" PM_CHAIN_ID=11155111 \
    PM_L1_DIR="$L1_DIR" PM_L2_DIR="$L2_DIR" PM_SUFFIX=-testnet PM_OUT="$SCRIPT_DIR/public-manifest.json" \
    PM_PUBLIC_L1_RPC="$PUBLIC_L1_RPC" PM_PUBLIC_AZTEC_NODE="$AZTEC_NODE_URL" PM_PUBLIC_CHAIN_SERVER= \
    PM_EXPLORER_L1=https://sepolia.etherscan.io PM_EXPLORER_L2= \
    PM_READ_L1_RPC="$TESTNET_L1_RPC_URL" PM_READ_AZTEC_NODE="$AZTEC_NODE_URL" \
    bash "$ROOT_DIR/deployments/lib/public-manifest.sh"

  step "Syncing addresses into interfaces/apps/web/.env.testnet..."
  WEB_ENV="$WEB_DIR/.env.testnet"
  [ -f "$WEB_ENV" ] || fail "$WEB_ENV not found. It must exist (with the placeholder VITE_* keys already in place) before this script can sync addresses into it."
  python3 "$ROOT_DIR/devops/production/ec2/scripts/sync-env-addresses.py" "$MANIFEST_PATH" "$WEB_ENV"
  ok "Address vars (*_ADDRESS) synced into $WEB_ENV"

  step "Filling endpoint vars in .env.testnet (sync-env-addresses.py deliberately leaves these alone)..."
  sed -i "s|^VITE_AZTEC_PXE_URL=.*|VITE_AZTEC_PXE_URL=$AZTEC_NODE_URL|" "$WEB_ENV"
  sed -i "s|^VITE_AZTEC_NODE_URL=.*|VITE_AZTEC_NODE_URL=$AZTEC_NODE_URL|" "$WEB_ENV"
  # R18: the PUBLIC (keyless) RPC, never TESTNET_L1_RPC_URL. Vite inlines every
  # VITE_* var into the client bundle at build time, so the keyed broadcasting
  # URL written here would be readable by every browser that loads the testnet
  # web app. TESTNET_L1_RPC_URL needs its key precisely because it broadcasts;
  # PUBLIC_L1_RPC is the one already vetted for publication (see the Stage 0
  # credential preflight) and already used for the public manifest.
  grep -q '^VITE_ETH_RPC_URL=' "$WEB_ENV" || fail "$WEB_ENV has no VITE_ETH_RPC_URL line to fill — the sed below would silently do nothing and ship an app with no L1 RPC."
  sed -i "s|^VITE_ETH_RPC_URL=.*|VITE_ETH_RPC_URL=$PUBLIC_L1_RPC|" "$WEB_ENV"
  sed -i "s|^VITE_ETH_CHAIN_ID=.*|VITE_ETH_CHAIN_ID=11155111|" "$WEB_ENV"
  # Must match the L2 deploy above (ZERACLE_COMPLIANCE=off): the bridge enforces
  # nothing, so the web app must not ask anyone to verify.
  grep -q '^VITE_COMPLIANCE_ENABLED=' "$WEB_ENV" || fail "$WEB_ENV has no VITE_COMPLIANCE_ENABLED line — src/config/env.ts refuses to boot without it."
  sed -i "s|^VITE_COMPLIANCE_ENABLED=.*|VITE_COMPLIANCE_ENABLED=false|" "$WEB_ENV"
  # R18 regression guard, checked against what actually landed in the file
  # rather than against what we meant to write. Two assertions, because they
  # catch different mistakes:
  #
  #   1. Exact equality with PUBLIC_L1_RPC. This is the strong one. It fails
  #      the moment anyone reintroduces a different variable here, whatever
  #      that variable happens to look like.
  #   2. The credential check. Weaker on its own -- it is a heuristic
  #      (userinfo, a >=20-char path segment, a key-ish query param name), so a
  #      keyed URL shaped differently could pass it -- but it is what catches
  #      PUBLIC_L1_RPC itself being wrong, independently of Stage 0.
  #
  # Neither prints the value: a failure here is about a credential.
  WEB_RPC_VALUE=$(grep '^VITE_ETH_RPC_URL=' "$WEB_ENV" | head -1 | cut -d= -f2-)
  [ -n "$WEB_RPC_VALUE" ] || fail "$WEB_ENV's VITE_ETH_RPC_URL is empty after sync — the web app cannot reach L1. Check the sed above."
  [ "$WEB_RPC_VALUE" = "$PUBLIC_L1_RPC" ] || fail "$WEB_ENV's VITE_ETH_RPC_URL does not match PUBLIC_L1_RPC after sync. Vite inlines VITE_* into the client bundle, so this must be the keyless public RPC and nothing else. Check the sed above."
  if ! bash "$SCRIPT_DIR/../lib/public-manifest.sh" --check-url "$WEB_RPC_VALUE" >/dev/null; then
    # Blank the line before dying. $WEB_ENV is a TRACKED file in the interfaces
    # repo, so exiting with the credential still written leaves it one
    # `git add -A` from being committed — the exact outcome this assertion
    # exists to prevent. lib/public-manifest.sh does the same for its own
    # output (temp file + rm on refusal).
    sed -i "s|^VITE_ETH_RPC_URL=.*|VITE_ETH_RPC_URL=|" "$WEB_ENV" || true
    fail "$WEB_ENV's VITE_ETH_RPC_URL carried credentials after sync — it would ship in the web bundle. The line has been blanked; check the sed above and PUBLIC_L1_RPC before re-running."
  fi
  ok "VITE_AZTEC_PXE_URL, VITE_AZTEC_NODE_URL, VITE_ETH_CHAIN_ID filled; VITE_ETH_RPC_URL set to the keyless PUBLIC_L1_RPC and asserted credential-free; VITE_COMPLIANCE_ENABLED=false"

  step "Testnet deploy summary"
  cat <<SUMMARY

  Manifest:   $MANIFEST_PATH
  Web env:    $WEB_ENV

  L1 (Sepolia, chain id 11155111):
    LiquidityPool:      $(jq -r '.liquidityPoolProxy' "$L1_LOCAL")
    DepositAdapter:     $(jq -r '.depositAdapter' "$L1_LOCAL")
    WithdrawalAdapter:  $(jq -r '.withdrawalAdapter' "$L1_LOCAL")
    BridgeGuard:        $(jq -r '.bridgeGuard' "$L1_LOCAL")
    Treasury:           $(jq -r '.treasury' "$L1_LOCAL")
    CollateralReserve:      $(jq -r '.collateralReserve' "$L1_LOCAL")
    NetworkFund:        $(jq -r '.networkFund' "$L1_LOCAL")
    BasketManager:      $(jq -r '.basketManager' "$L1_BASKET")
    TokenPortal:        $(jq -r '.tokenPortal' "$L1_BRIDGE") (wired to L2 TokenBridge below)
    LUSD / USDT / USDC / DAI / WETH / WBTC / PAXG / PAXS: see $L1_TOKENS

  L2 (Aztec testnet, $AZTEC_NODE_URL):
    ZeracleToken:       $(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")
    TokenBridge:        $(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")
    FeeDistribution:    $(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")
    PaymentEscrow:      $(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")
    SponsoredFPC:       $(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY") (Aztec canonical, Aztec-funded)

  Endpoints:
    TESTNET_L1_RPC_URL: $TESTNET_L1_RPC_URL
    AZTEC_NODE_URL:     $AZTEC_NODE_URL

SUMMARY

  warn "App-level testnet gaps remain. Read docs/versions/260709/existing-limitations.md §§1-2 (chain-server sandbox-only infra: block production, account deployment, account-address directory) before treating this deploy as feature-complete."
}

step "Stage 1: L1 deploy (Sepolia)"
stage_l1_deploy

step "Stage 2: L2 deploy (Aztec testnet)"
stage_l2_deploy

step "Stage 2b: governance handover (Sepolia)"
stage_governance_handover

step "Stage 2c: BasketManager deploy + pool wiring (Sepolia)"
stage_basket_manager

step "Stage 3: manifest + web env sync"
stage_manifest_sync
