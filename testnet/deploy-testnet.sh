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
: "${GOV_GUARDIAN:=$DEPLOYER_ADDRESS}"
[ -n "${GOV_PROPOSER:-}" ] || fail "GOV_PROPOSER (the Safe that proposes in phase 2) is required for a testnet deploy. Set it in $SCRIPT_DIR/.env."
if [ "$(echo "$GOV_PROPOSER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_PROPOSER equals the deployer address. Phase 2 must be a different authority (a Safe), or the transition is meaningless."
fi
if ! PROPOSER_CODE=$(cast code "$GOV_PROPOSER" --rpc-url "$TESTNET_L1_RPC_URL" 2>&1); then
  fail "Could not fetch code for GOV_PROPOSER ($GOV_PROPOSER) from $TESTNET_L1_RPC_URL: $PROPOSER_CODE"
fi
[ "$PROPOSER_CODE" != "0x" ] || fail "GOV_PROPOSER ($GOV_PROPOSER) has no code on Sepolia — it must be a deployed Safe, not an EOA."
export GOV_TRANSITION_SECONDS GOV_TIMELOCK_DELAY GOV_PROPOSER GOV_GUARDIAN
ok "GOV_PROPOSER: $GOV_PROPOSER (contract)"
ok "GOV_GUARDIAN: $GOV_GUARDIAN"
ok "Transition:   ${GOV_TRANSITION_SECONDS}s after deploy; timelock delay ${GOV_TIMELOCK_DELAY}s"

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

step "Preflight summary"
cat <<SUMMARY

  TESTNET_L1_RPC_URL:          $TESTNET_L1_RPC_URL
  AZTEC_NODE_URL:               $AZTEC_NODE_URL
  Deployer address:             $DEPLOYER_ADDRESS
  Deployer balance:             ${DEPLOYER_BALANCE_ETH} ETH
  GOV_PROPOSER:                 $GOV_PROPOSER
  GOV_TRANSITION_SECONDS:       $GOV_TRANSITION_SECONDS
  Aztec node version:           $NODE_VERSION
  Local SDK version:            $LOCAL_SDK_VERSION
  L1 Inbox address:             $L1_INBOX_ADDRESS
  L1 Rollup address:            $L1_ROLLUP_ADDRESS
  L1 Registry address:          $L1_REGISTRY_ADDRESS
  L1 FeeJuicePortal address:    $L1_FEE_JUICE_PORTAL_ADDRESS

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
# preflight-exported and .env-loaded vars above. DEPLOYER_ACCOUNT_FILE (Task
# 4) tells deploy.ts's isTestnetL1Mode() branch where to persist/reload the
# real testnet deployer keypair (sandbox has no such file — it uses the
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
    DEPLOY_TX_TIMEOUT_SECS=600 \
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

  cd "$ROOT_DIR"
}

# ===========================================================================
# Stage 2b: governance deploy + ownership handover (FINAL L1 stage, after bridge wiring)
# ===========================================================================
stage_governance_handover() {
  cd "$L1_DIR"
  step "Governance: deploying authority/timelock/validator and handing over L1 ownership (Sepolia)..."
  ETH_RPC_URL="$TESTNET_L1_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    GOV_PROPOSER="$GOV_PROPOSER" GOV_GUARDIAN="$GOV_GUARDIAN" \
    GOV_TRANSITION_SECONDS="$GOV_TRANSITION_SECONDS" GOV_TIMELOCK_DELAY="$GOV_TIMELOCK_DELAY" \
    make deploy-governance-testnet
  [ -f deployments/governance-testnet.json ] || fail "v1-l1/deployments/governance-testnet.json was not created by 'make deploy-governance-testnet'. Check the forge output above."
  ok "GovernanceAuthority: $(jq -r '.authority' deployments/governance-testnet.json)"
  ok "ZeracleTimelock:     $(jq -r '.timelock' deployments/governance-testnet.json)"
  ok "UpgradeValidator:    $(jq -r '.validator' deployments/governance-testnet.json)"
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
  L2_DEPLOY="$L2_DIR/deployment.json"

  for f in "$L1_LOCAL" "$L1_TOKENS" "$L1_BRIDGE" "$L1_GOV" "$L2_DEPLOY"; do
    [ -f "$f" ] || fail "$f is missing — stage_l1_deploy and stage_l2_deploy must both complete successfully before the manifest stage can run."
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
      "mockDexAggregator": "$(jq -r '.mockDexAggregator' "$L1_LOCAL")"
    },
    "governance": {
      "authority": "$(jq -r '.authority' "$L1_GOV")",
      "timelock": "$(jq -r '.timelock' "$L1_GOV")",
      "validator": "$(jq -r '.validator' "$L1_GOV")",
      "admin": "$(jq -r '.admin' "$L1_GOV")",
      "guardian": "$(jq -r '.guardian' "$L1_GOV")",
      "proposer": "$(jq -r '.proposer' "$L1_GOV")",
      "transitionAt": $(jq -r '.transitionAt' "$L1_GOV"),
      "timelockDelay": $(jq -r '.timelockDelay' "$L1_GOV"),
      "executionWindow": $(jq -r '.executionWindow' "$L1_GOV")
    },
    "tokens": {
      "LUSD": { "address": "$(jq -r '.LUSD' "$L1_TOKENS")", "decimals": 18 },
      "USDT": { "address": "$(jq -r '.USDT' "$L1_TOKENS")", "decimals": 6 },
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
    "VITE_TOKEN_PORTAL_ADDRESS": "$(jq -r '.tokenPortal' "$L1_BRIDGE")",
    "VITE_ZRCL_CONTRACT_ADDRESS": "$(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")",
    "VITE_BRIDGE_CONTRACT_ADDRESS": "$(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")",
    "VITE_FEE_DISTRIBUTION_ADDRESS": "$(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")",
    "VITE_PAYMENT_ESCROW_ADDRESS": "$(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")",
    "VITE_SPONSORED_FPC_ADDRESS": "$(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY")",
    "VITE_LUSD_L1_ADDRESS": "$(jq -r '.LUSD' "$L1_TOKENS")",
    "VITE_USDT_L1_ADDRESS": "$(jq -r '.USDT' "$L1_TOKENS")",
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
    TokenPortal:        $(jq -r '.tokenPortal' "$L1_BRIDGE") (wired to L2 TokenBridge below)
    LUSD / USDT / DAI / WETH / WBTC / PAXG / PAXS: see $L1_TOKENS

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

step "Stage 3: manifest + web env sync"
stage_manifest_sync
