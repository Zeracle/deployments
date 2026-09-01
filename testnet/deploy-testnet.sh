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
#                  reachability + version match. (this file, implemented)
#   1. L1 deploy — Sepolia contracts + mock tokens/feeds + bridge. (stub —
#                  Tasks 3-4 of the testnet-deploy-pipeline plan fill this in)
#   2. L2 deploy — Aztec testnet contracts + fee-juice bootstrap. (stub)
#   3. Manifest  — deployment-manifest.json + web app .env.testnet sync. (stub)
#
# Usage:
#   ./deploy-testnet.sh                  # full pipeline (asks to confirm)
#   ./deploy-testnet.sh --preflight-only # run checks only; exit 0/1, no deploy
#   ./deploy-testnet.sh --force-version  # skip the node/SDK version match check
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
for arg in "$@"; do
  case "$arg" in
    --preflight-only) PREFLIGHT_ONLY=true ;;
    --force-version) FORCE_VERSION=true ;;
    *) fail "Unknown argument: $arg (supported: --preflight-only, --force-version)" ;;
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

: "${MIN_DEPLOYER_BALANCE_ETH:=0.5}"

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
if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  fail "Missing required env vars in $SCRIPT_DIR/.env: ${MISSING_VARS[*]}. See $SCRIPT_DIR/.env.example."
fi
ok "TESTNET_L1_RPC_URL, DEPLOYER_PRIVATE_KEY, AZTEC_NODE_URL all set"

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
  else
    fail "Aztec node version ($NODE_VERSION) does not match the local SDK version ($LOCAL_SDK_VERSION) in $L2_DIR/node_modules/@aztec/aztec.js. Contract/RPC incompatibilities are likely — upgrade v1-l2's @aztec/aztec.js to match, or pass --force-version to proceed anyway at your own risk."
  fi
else
  ok "Node version matches local SDK version ($NODE_VERSION)"
fi

ok "L1_INBOX_ADDRESS:            $L1_INBOX_ADDRESS"
ok "L1_ROLLUP_ADDRESS:           $L1_ROLLUP_ADDRESS"
ok "L1_REGISTRY_ADDRESS:         $L1_REGISTRY_ADDRESS"
ok "L1_FEE_JUICE_PORTAL_ADDRESS: $L1_FEE_JUICE_PORTAL_ADDRESS"

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
  L1 Inbox address:             $L1_INBOX_ADDRESS
  L1 Rollup address:            $L1_ROLLUP_ADDRESS
  L1 Registry address:          $L1_REGISTRY_ADDRESS
  L1 FeeJuicePortal address:    $L1_FEE_JUICE_PORTAL_ADDRESS
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
# testnet-deploy-pipeline plan): deploy-testnet-l1 -> deploy-mocks-testnet ->
# install-mock-feeds.sh -> deploy-bridge-testnet. Each target writes its own
# `*-testnet.json` output (never clobbering the sandbox's local.json/
# tokens.json/bridge.json); every write is asserted with jq before we trust
# it and move on.
# ===========================================================================

stage_l1_deploy() {
  cd "$L1_DIR"

  step "L1: deploying core contracts (Sepolia)..."
  ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-testnet-l1
  [ -f deployments/local-testnet.json ] || fail "v1-l1/deployments/local-testnet.json was not created by 'make deploy-testnet-l1'. Check the forge output above for the actual failure."
  LIQUIDITY_POOL_PROXY=$(jq -r '.liquidityPoolProxy' deployments/local-testnet.json)
  DEPOSIT_ADAPTER=$(jq -r '.depositAdapter' deployments/local-testnet.json)
  WITHDRAWAL_ADAPTER=$(jq -r '.withdrawalAdapter' deployments/local-testnet.json)
  BRIDGE_GUARD=$(jq -r '.bridgeGuard' deployments/local-testnet.json)
  TREASURY=$(jq -r '.treasury' deployments/local-testnet.json)
  INSURANCE_FUND=$(jq -r '.insuranceFund' deployments/local-testnet.json)
  ok "LiquidityPool:     $LIQUIDITY_POOL_PROXY"
  ok "DepositAdapter:    $DEPOSIT_ADAPTER"
  ok "WithdrawalAdapter: $WITHDRAWAL_ADAPTER"
  ok "BridgeGuard:       $BRIDGE_GUARD"
  ok "Treasury:          $TREASURY"
  ok "InsuranceFund:     $INSURANCE_FUND"

  step "L1: deploying mock tokens (Sepolia)..."
  ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-mocks-testnet
  [ -f deployments/tokens-testnet.json ] || fail "v1-l1/deployments/tokens-testnet.json was not created by 'make deploy-mocks-testnet'. Check the forge output above for the actual failure."
  ok "LUSD:  $(jq -r '.LUSD' deployments/tokens-testnet.json)"
  ok "USDT:  $(jq -r '.USDT' deployments/tokens-testnet.json)"
  ok "USDC:  $(jq -r '.USDC' deployments/tokens-testnet.json)"
  ok "DAI:   $(jq -r '.DAI' deployments/tokens-testnet.json)"
  ok "WETH:  $(jq -r '.WETH' deployments/tokens-testnet.json)"
  ok "WBTC:  $(jq -r '.WBTC' deployments/tokens-testnet.json)"
  ok "PAXG:  $(jq -r '.PAXG' deployments/tokens-testnet.json)"
  ok "PAXS:  $(jq -r '.PAXS' deployments/tokens-testnet.json)"

  step "L1: installing mock Chainlink price feeds..."
  # Mock Chainlink feeds. install-mock-feeds.sh now decides by probing the chain for
  # code at the LUSD/USD feed address (G17); it installs via anvil_setCode, which a
  # real Sepolia RPC does not expose — this stage is a known live-run blocker until a
  # Sepolia-native feed strategy exists (see README).
  ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    L1_DIR="$L1_DIR" \
    bash "$ROOT_DIR/deployments/sandbox-local/install-mock-feeds.sh"
  ok "Mock price feeds installed"

  step "L1: deploying TokenPortal bridge (Sepolia)..."
  INBOX_ADDRESS="$L1_INBOX_ADDRESS" ROLLUP_ADDRESS="$L1_ROLLUP_ADDRESS" \
    ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    make deploy-bridge-testnet
  [ -f deployments/bridge-testnet.json ] || fail "v1-l1/deployments/bridge-testnet.json was not created by 'make deploy-bridge-testnet'. Check the forge output above for the actual failure."
  TOKEN_PORTAL=$(jq -r '.tokenPortal' deployments/bridge-testnet.json)
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
#
# After the L2 contracts land, wires the freshly deployed L2 TokenBridge into
# the Stage 1 L1 TokenPortal via `make wire-bridge-testnet` (v1-l1/Makefile,
# Task 4) — the same script the sandbox uses (scripts/wire-bridge.sh),
# pointed at deployments/bridge-testnet.json.
# ===========================================================================

stage_l2_deploy() {
  cd "$L2_DIR"

  step "L2: checking for prebuilt artifacts..."
  [ -f artifacts/index.ts ] || fail "v1-l2/artifacts/index.ts is missing. Testnet deploys never build Noir on the fly (same rule as deploy-sandbox.sh's headless branch) — run 'yarn build' once and ship the resulting artifacts/ + target/ directories before running this script."
  [ -n "$(ls target/*.json 2>/dev/null)" ] || fail "v1-l2/target/*.json is missing. Compiled Noir artifacts must already be present — run 'yarn build' first."
  ok "Prebuilt L2 artifacts present (artifacts/index.ts, target/*.json)"

  step "L2: deploying Aztec testnet contracts + fee-juice bootstrap..."
  DEPLOYER_ACCOUNT_FILE="$SCRIPT_DIR/deployer-account.json"
  export DEPLOYER_ACCOUNT_FILE
  AZTEC_RPC_HOST="$AZTEC_NODE_URL" \
    L1_RPC_URL="$TESTNET_L1_RPC_URL" \
    L1_DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    L1_FEE_JUICE_PORTAL_ADDRESS="$L1_FEE_JUICE_PORTAL_ADDRESS" \
    L1_TOKEN_PORTAL="$TOKEN_PORTAL" \
    L1_TREASURY="$TREASURY" \
    L1_INSURANCE_FUND="$INSURANCE_FUND" \
    DEPLOY_TX_TIMEOUT_SECS=600 \
    ETH_CHAIN_ID=11155111 \
    yarn deploy:clean
  [ -f deployment.json ] || fail "v1-l2/deployment.json was not created by 'yarn deploy:clean'. Check the deploy output above for the actual failure."

  ok "ZeracleToken:    $(jq -r '.contracts.zeracleToken' deployment.json)"
  ok "TokenBridge:     $(jq -r '.contracts.tokenBridge' deployment.json)"
  ok "FeeDistribution: $(jq -r '.contracts.feeDistribution' deployment.json)"
  ok "PaymentEscrow:   $(jq -r '.contracts.paymentEscrow' deployment.json)"
  ok "SponsoredFPC:    $(jq -r '.contracts.sponsoredFpc' deployment.json) (deployed but UNFUNDED — top up via the chain-view admin panel before any sponsored tx will go through)"
  ok "Deployer:        $(jq -r '.deployer' deployment.json)"
  ok "Deployer keys:   $DEPLOYER_ACCOUNT_FILE (BACK THIS UP — never commit/ship it)"

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
    AUTH=$(jq -r '.authority // ""' deployments/governance-testnet.json 2>/dev/null || true)
    CODE=$(cast code "$AUTH" --rpc-url "$TESTNET_L1_RPC_URL" 2>/dev/null || echo 0x)
    if [ -n "$AUTH" ] && [ "$CODE" != "0x" ]; then
      warn "forge exited non-zero but the GovernanceAuthority at $AUTH has code — the broadcast landed; most likely Etherscan verification failed. Retry verification only with: cd $L1_DIR && forge script script/DeployGovernance.s.sol:DeployGovernance --rpc-url \$TESTNET_L1_RPC_URL --resume --verify --etherscan-api-key \$ETHERSCAN_API_KEY"
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
    BM=$(jq -r '.basketManager // ""' deployments/basket-testnet.json 2>/dev/null || true)
    BM_CODE=$(cast code "$BM" --rpc-url "$TESTNET_L1_RPC_URL" 2>/dev/null || echo 0x)
    if [ -n "$BM" ] && [ "$BM_CODE" != "0x" ]; then
      warn "forge exited non-zero but the BasketManager at $BM has code — the broadcast landed; most likely Etherscan verification failed. Retry verification only with: cd $L1_DIR && forge script script/DeployBasketManager.s.sol:DeployBasketManager --rpc-url \$TESTNET_L1_RPC_URL --resume --verify --etherscan-api-key \$ETHERSCAN_API_KEY"
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
      "insuranceFund": "$(jq -r '.insuranceFund' "$L1_LOCAL")",
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
    "VITE_INSURANCE_FUND_ADDRESS": "$(jq -r '.insuranceFund' "$L1_LOCAL")",
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
    "VITE_PAXS_L1_ADDRESS": "$(jq -r '.PAXS' "$L1_TOKENS")"
  }
}
MANIFEST
  ok "Written $MANIFEST_PATH"

  step "Syncing addresses into interfaces/apps/web/.env.testnet..."
  WEB_ENV="$WEB_DIR/.env.testnet"
  [ -f "$WEB_ENV" ] || fail "$WEB_ENV not found. It must exist (with the placeholder VITE_* keys already in place) before this script can sync addresses into it."
  python3 "$ROOT_DIR/devops/production/ec2/scripts/sync-env-addresses.py" "$MANIFEST_PATH" "$WEB_ENV"
  ok "Address vars (*_ADDRESS) synced into $WEB_ENV"

  step "Filling endpoint vars in .env.testnet (sync-env-addresses.py deliberately leaves these alone)..."
  sed -i "s|^VITE_AZTEC_PXE_URL=.*|VITE_AZTEC_PXE_URL=$AZTEC_NODE_URL|" "$WEB_ENV"
  sed -i "s|^VITE_AZTEC_NODE_URL=.*|VITE_AZTEC_NODE_URL=$AZTEC_NODE_URL|" "$WEB_ENV"
  sed -i "s|^VITE_ETH_RPC_URL=.*|VITE_ETH_RPC_URL=$TESTNET_L1_RPC_URL|" "$WEB_ENV"
  sed -i "s|^VITE_ETH_CHAIN_ID=.*|VITE_ETH_CHAIN_ID=11155111|" "$WEB_ENV"
  ok "VITE_AZTEC_PXE_URL, VITE_AZTEC_NODE_URL, VITE_ETH_RPC_URL, VITE_ETH_CHAIN_ID filled"

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
    InsuranceFund:      $(jq -r '.insuranceFund' "$L1_LOCAL")
    BasketManager:      $(jq -r '.basketManager' "$L1_BASKET")
    TokenPortal:        $(jq -r '.tokenPortal' "$L1_BRIDGE") (wired to L2 TokenBridge below)
    LUSD / USDT / USDC / DAI / WETH / WBTC / PAXG / PAXS: see $L1_TOKENS

  L2 (Aztec testnet, $AZTEC_NODE_URL):
    ZeracleToken:       $(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")
    TokenBridge:        $(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")
    FeeDistribution:    $(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")
    PaymentEscrow:      $(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")
    SponsoredFPC:       $(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY") (UNFUNDED)

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
