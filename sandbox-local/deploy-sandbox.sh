#!/bin/bash
set -e

# ===========================================================================
# Zeracle Local Deployment Script
#
# Deploys the full stack from scratch:
#   1. Start Anvil (L1)
#   2. Start Aztec Sandbox (L2)
#   3. Deploy L1 contracts + mock tokens
#   4. Deploy L2 contracts (compile, codegen, deploy)
#   5. Deploy L1 TokenPortal bridge
#   6. Redeploy L2 bridge with real portal
#   7. Wire L1 portal to L2 bridge
#   8. Update web app env
#   9. Generate deployment manifest
#  10. Wipe chain-server state (server itself is started manually)
#
# Usage:
#   ./deploy-sandbox.sh          # Full deploy (starts Anvil + Sandbox)
#   ./deploy-sandbox.sh --skip-infra  # Skip Anvil/Sandbox (already running)
#
# Prerequisites: Docker, Node.js 18+, Yarn, Foundry (forge/cast/anvil), jq
#
# Environment (sandbox-local/.env is auto-loaded):
#   MAINNET_RPC_URL — Mainnet RPC for forking (loaded from .env only if not
#                      already exported; export MAINNET_RPC_URL="" to force
#                      an unforked anvil with mock feeds).
#   FORK_BLOCK       — (optional) pin the fork to a specific block number for
#                      deterministic deploys across runs.
# ===========================================================================

# Script lives in deployments/sandbox-local/; the project root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
L1_DIR="$ROOT_DIR/v1-l1"
L2_DIR="$ROOT_DIR/v1-l2"
WEB_DIR="$ROOT_DIR/interfaces/apps/web"
SERVER_DIR="$ROOT_DIR/chain-server"

# Load sandbox-local/.env and v1-l1/.env.local as DEFAULTS only: anything the
# caller exported — including an explicitly empty MAINNET_RPC_URL to force an
# unforked anvil — wins (G17). `.env` lives at sandbox-local/.env, this
# environment's own config, not the repo root; v1-l1/.env.local supplies
# DEPLOYER_PRIVATE_KEY for the L2 fee-juice bridge step.
# shellcheck source=lib/env-defaults.sh
. "$SCRIPT_DIR/lib/env-defaults.sh"
load_env_defaults "$SCRIPT_DIR/.env"
load_env_defaults "$L1_DIR/.env.local"

# Anvil default — used as a fallback so a fresh checkout works without any
# manual env setup. Override via .env or v1-l1/.env.local for production.
: "${DEPLOYER_PRIVATE_KEY:=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

: "${ETH_RPC_URL:=http://localhost:8545}"
export DEPLOYER_PRIVATE_KEY ETH_RPC_URL

# G17: the caller's environment now wins over .env files, so a DEPLOYER_PRIVATE_KEY
# left exported from another environment (e.g. after deploy-testnet.sh) is honoured.
if [ "$DEPLOYER_PRIVATE_KEY" != "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" ]; then
  echo "WARN: DEPLOYER_PRIVATE_KEY is not the anvil default — using the caller's key for the sandbox deploy." >&2
fi

SKIP_INFRA=false
if [ "$1" = "--skip-infra" ]; then
  SKIP_INFRA=true
fi

# Headless chain-host mode (EC2 production box). When set:
#  - anvil + the Aztec sandbox already run as systemd units → skip starting them
#    (implies --skip-infra; the script nc-checks :8545/:8080 instead).
#  - the web + chain-view app dirs are NOT present on the box → skip their
#    .env.local writes.
#  - the L2 `yarn build` (aztec-nargo compile + codegen + cross-repo
#    sync-artifacts into ../interfaces/...) is skipped; the box deploys from the
#    precompiled v1-l2/{artifacts,target} shipped in the release tarball.
CHAIN_HOST_HEADLESS=${CHAIN_HOST_HEADLESS:-0}
if [ "$CHAIN_HOST_HEADLESS" = 1 ]; then
  SKIP_INFRA=true
fi

# Mainnet fork URL — required for real Chainlink feeds on local. Anvil will copy
# mainnet bytecode for contracts on first read, so addresses like the LUSD/USD
# price feed become callable. Without it, the pool reverts on oracle reads.
: "${MAINNET_RPC_URL:=}"
: "${FORK_BLOCK:=}" # optional — pin to a block for reproducible deploys

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
warn() { echo -e "${YELLOW}  ⚠${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}"; exit 1; }

# Governance (G3): admin-controlled until GOV_TRANSITION_SECONDS after deploy, then the
# GOV_PROPOSER Safe behind a GOV_TIMELOCK_DELAY timelock. Sandbox defaults: 365 d / 1 h.
# The contract base rejects proposer == admin, so proposer/guardian can no longer default
# to the deployer: they default to two of the anvil dev accounts instead — deployer
# (account #0) = admin, account #2 = Safe stand-in (GOV_PROPOSER), account #3 = guardian
# (GOV_GUARDIAN). All three keys/addresses are well-known anvil defaults and are also
# listed in the generated manifest's "accounts" array. A real Safe is a testnet/mainnet
# requirement, not a sandbox one.
# (Moved to after the fail()/step()/ok()/warn() helpers are defined above, since the
# deployer-address derivation below now uses fail() on error.)
: "${GOV_TRANSITION_SECONDS:=31536000}"
: "${GOV_TIMELOCK_DELAY:=3600}"
if ! DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" 2>&1); then
  fail "Could not derive an address from DEPLOYER_PRIVATE_KEY: $DEPLOYER_ADDRESS"
fi
: "${GOV_PROPOSER:=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"  # anvil #2
: "${GOV_GUARDIAN:=0x90F79bf6EB2c4f870365E785982E1f101E93b906}"  # anvil #3
if [ "$(echo "$GOV_PROPOSER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "GOV_PROPOSER equals the deployer/admin address — the timelock proposer must not be the deployer/admin key."
fi
# D1: break-glass second proposer. Optional on the sandbox (default none ->
# single proposer); testnet/mainnet require it (see deploy-testnet.sh).
: "${GOV_PROPOSER_2:=}"
export GOV_TRANSITION_SECONDS GOV_TIMELOCK_DELAY GOV_PROPOSER GOV_GUARDIAN GOV_PROPOSER_2

wait_for_port() {
  local port=$1 name=$2 timeout=${3:-120}
  step "Waiting for $name on port $port..."
  for i in $(seq 1 $timeout); do
    if nc -z localhost "$port" 2>/dev/null; then
      ok "$name is ready"
      return 0
    fi
    sleep 1
  done
  fail "$name did not start within ${timeout}s"
}

# ===========================================================================
# 1. Infrastructure
# ===========================================================================

if [ "$SKIP_INFRA" = false ]; then
  # Stop any existing instances
  step "Stopping existing services..."
  pkill -f "anvil" 2>/dev/null || true
  (cd "$L2_DIR" && docker-compose -f docker-compose.local.yml down -v 2>/dev/null) || true
  sleep 2

  # Start Anvil
  step "Starting Anvil (L1)..."
  cd "$L1_DIR"
  # 5 dev accounts is plenty (deployer + test users); fewer genesis RPC calls
  # means public mainnet RPCs are less likely to 429 while forking.
  # --chain-id 31337 keeps the local chain ID stable regardless of fork origin
  # (forking mainnet otherwise inherits chainId=1, which the Aztec sandbox
  # rejects because it expects 31337).
  ANVIL_FORK_ARGS="--accounts 5 --chain-id 31337"
  if [ -n "$MAINNET_RPC_URL" ]; then
    # Pre-flight the RPC so we fail fast on a dead endpoint rather than burning
    # the full anvil startup window.
    RPC_CHECK=$(curl -sS --max-time 8 -X POST "$MAINNET_RPC_URL" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>&1 || true)
    if ! echo "$RPC_CHECK" | grep -q '"result"'; then
      fail "MAINNET_RPC_URL is unreachable or unhealthy.
     Response: $RPC_CHECK
     Try a keyed endpoint (Alchemy/Infura free tier includes archive data).
     Keyless list: https://chainlist.org/chain/1"
    fi

    # Archive-state probe: read a Chainlink feed's latestRoundData through the
    # RPC. Full nodes (cloudflare, publicnode, llamarpc) only keep ~128 blocks
    # of state — contract reads like Chainlink feeds fail a few minutes after
    # fork with "historical state not available". Archive nodes (Alchemy/Infura
    # free tier, drpc, paid Quicknode) serve it.
    ARCHIVE_CHECK=$(curl -sS --max-time 8 -X POST "$MAINNET_RPC_URL" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x3D7aE7E594f2f2091Ad8798313450130d0Aba3a0","data":"0xfeaf968c"},"latest"],"id":1}' 2>&1 || true)
    if echo "$ARCHIVE_CHECK" | grep -qi "historical state"; then
      fail "MAINNET_RPC_URL does not expose archive state.
     Response: $ARCHIVE_CHECK
     Without archive, Chainlink feed reads will revert once the fork drifts
     past ~128 blocks. Use a keyed Alchemy or Infura endpoint instead."
    fi
    ANVIL_FORK_ARGS="$ANVIL_FORK_ARGS --fork-url $MAINNET_RPC_URL --compute-units-per-second 100 --retries 10 --timeout 30000"
    if [ -n "$FORK_BLOCK" ]; then
      ANVIL_FORK_ARGS="$ANVIL_FORK_ARGS --fork-block-number $FORK_BLOCK"
    fi
    ok "Forking mainnet: $MAINNET_RPC_URL${FORK_BLOCK:+ @ block $FORK_BLOCK}"
  else
    warn "MAINNET_RPC_URL not set — anvil starts without a fork."
    warn "Chainlink price reads will revert. Add MAINNET_RPC_URL=<rpc> to .env"
  fi
  # shellcheck disable=SC2086
  nohup anvil --host 0.0.0.0 --allow-origin '*' $ANVIL_FORK_ARGS > /tmp/zeracle-anvil.log 2>&1 &
  ANVIL_PID=$!
  disown "$ANVIL_PID" 2>/dev/null || true
  wait_for_port 8545 "Anvil" 120

  # Start Aztec Sandbox
  step "Starting Aztec Sandbox (L2)..."
  cd "$L2_DIR"
  nohup bash scripts/start-sandbox.sh > /tmp/zeracle-sandbox.log 2>&1 &
  SANDBOX_PID=$!
  disown "$SANDBOX_PID" 2>/dev/null || true
  wait_for_port 8080 "Aztec Sandbox" 300
else
  step "Skipping infrastructure (--skip-infra)"
  # Verify they're running
  nc -z localhost 8545 2>/dev/null || fail "Anvil not running on :8545"
  nc -z localhost 8080 2>/dev/null || fail "Aztec Sandbox not running on :8080"
  ok "Anvil and Sandbox are running"
fi

# ===========================================================================
# 2. Deploy L1 Contracts
# ===========================================================================

step "Deploying L1 contracts + mock tokens..."
cd "$L1_DIR"

# Ensure .env.local exists
if [ ! -f .env.local ]; then
  make env-local 2>/dev/null || true
fi

make full-deploy-local
ok "L1 contracts deployed"

# Verify
[ -f deployments/local.json ] || fail "deployments/local.json not created"
[ -f deployments/tokens.json ] || fail "deployments/tokens.json not created"

POOL=$(jq -r '.liquidityPoolProxy' deployments/local.json)
ADAPTER=$(jq -r '.depositAdapter' deployments/local.json)
LUSD=$(jq -r '.mockLusd' deployments/local.json)
ok "LiquidityPool: $POOL"
ok "DepositAdapter: $ADAPTER"

# Install mock Chainlink feeds when the chain has none. install-mock-feeds.sh
# probes the LUSD/USD feed address for code (a forked anvil has the real feed;
# an unforked one has nothing and every deposit would revert on the price
# read), so this is correct whether anvil was started here or by hand.
step "Checking Chainlink price feeds (installs mocks on an unforked anvil)..."
L1_DIR="$L1_DIR" ETH_RPC_URL="$ETH_RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
  bash "$SCRIPT_DIR/install-mock-feeds.sh"
ok "Price feeds verified"

# ===========================================================================
# 3. Deploy L1 TokenPortal Bridge
# ===========================================================================

step "Deploying L1 TokenPortal bridge..."
cd "$L1_DIR"
make deploy-bridge
ok "TokenPortal deployed"

[ -f deployments/bridge.json ] || fail "deployments/bridge.json not created"
TOKEN_PORTAL=$(jq -r '.tokenPortal' deployments/bridge.json)
ok "TokenPortal: $TOKEN_PORTAL"

# ===========================================================================
# 4. Build & Deploy L2 Contracts
# ===========================================================================

cd "$L2_DIR"
if [ "$CHAIN_HOST_HEADLESS" = 0 ]; then
  step "Building L2 contracts (compile + codegen + sync artifacts)..."
  yarn build
  ok "L2 contracts built and artifacts synced to web app"
else
  step "Headless: skipping L2 build — deploying from precompiled artifacts/ + target/ (no aztec-nargo on the box, no cross-repo sync)."
  [ -f artifacts/index.ts ] || fail "v1-l2/artifacts/index.ts missing — the release tarball must ship precompiled L2 artifacts (see make-release-tarball.sh)."
  [ -n "$(ls target/*.json 2>/dev/null)" ] || fail "v1-l2/target/*.json missing — the release tarball must ship the compiled Noir artifacts."
fi

step "Deploying L2 contracts (clean)..."
# G1: the FeeDistribution test_* helpers are switched by a deploy-time immutable; the sandbox
# is the only environment that turns them on (jest suites + demo seeding rely on them).
ZERACLE_ENABLE_TEST_HELPERS=1 yarn deploy:clean
ok "L2 contracts deployed (FeeDistribution test helpers ENABLED — sandbox only)"

[ -f deployment.json ] || fail "deployment.json not created"
ZRCL=$(jq -r '.contracts.zeracleToken' deployment.json)
BRIDGE_L2=$(jq -r '.contracts.tokenBridge' deployment.json)
FEE_DIST=$(jq -r '.contracts.feeDistribution' deployment.json)
PAYMENT_ESCROW=$(jq -r '.contracts.paymentEscrow' deployment.json)
SPONSORED_FPC=$(jq -r '.contracts.sponsoredFpc' deployment.json)
ok "ZeracleToken:    $ZRCL"
ok "TokenBridge:     $BRIDGE_L2"
ok "FeeDistrib:      $FEE_DIST"
ok "PaymentEscrow:   $PAYMENT_ESCROW"
ok "SponsoredFPC:    $SPONSORED_FPC"

# Deploy the canonical HandshakeRegistry standard contract. The aztec sandbox
# does NOT deploy it at genesis, but aztec-nr's private note discovery
# (do_sync_state → get_handshakes) queries it at its canonical address — without
# it, recipients can never discover incoming cross-account transfers (balances
# stay 0). Idempotent: the script no-ops if it's already published. Pays via the
# canonical SponsoredFPC provisioned by deploy:clean above.
step "Deploying canonical HandshakeRegistry (enables private note discovery)..."
yarn deploy:handshake
ok "HandshakeRegistry ready (canonical address)"

# Fund the Zeracle SponsoredFPC (local only). deploy.ts leaves it unfunded on
# purpose (treasury is a separate concern; on EC2 the admin tops it up from
# chain-view). Since the aztec 5.2.0 upgrade the web app deploys accounts
# in-browser through this FPC, so a local stack with an empty FPC rejects the
# very first user action ("Insufficient fee payer balance"). Mint + bridge the
# faucet amount and claim it for the FPC as the sandbox deployer.
if [ "$CHAIN_HOST_HEADLESS" = 0 ]; then
  step "Funding Zeracle SponsoredFPC with fee juice (local dev)..."
  yarn fund:fpc
  ok "SponsoredFPC funded"
fi

# Dump the sandbox's deterministic Schnorr test accounts (address + secret +
# signing key) into a shell variable — later embedded directly into the
# deployment manifest under l2.testAccounts so developers can copy a signing
# key into the web app without generating a fresh account per run.
step "Dumping L2 test accounts..."
L2_TEST_ACCOUNTS_JSON=$(yarn --silent dump-test-accounts)
[ -n "$L2_TEST_ACCOUNTS_JSON" ] || fail "dump-test-accounts returned no output"
ok "Captured $(echo "$L2_TEST_ACCOUNTS_JSON" | jq 'length') L2 test accounts"

# ===========================================================================
# 5. Redeploy L2 Bridge with Real L1 Portal
# ===========================================================================

step "Redeploying L2 TokenBridge with real L1 portal..."
cd "$L2_DIR"
npx tsx scripts/redeploy-bridge.ts "$TOKEN_PORTAL"
ok "L2 TokenBridge redeployed"

# Re-read updated bridge address
BRIDGE_L2=$(jq -r '.contracts.tokenBridge' deployment.json)
ok "New TokenBridge: $BRIDGE_L2"

# ===========================================================================
# 6. Wire L1 Portal to L2 Bridge
# ===========================================================================

step "Wiring L1 TokenPortal to L2 TokenBridge..."
cd "$L1_DIR"
make wire-bridge
ok "Bridge wired"

# ===========================================================================
# 6b. Governance deploy + ownership handover (FINAL L1 stage — after bridge wiring,
#     because wire-bridge.sh calls TokenPortal.setL2Bridge as the deployer)
# ===========================================================================
step "Deploying governance (authority + timelock + validator) and handing over L1 ownership..."
cd "$L1_DIR"
# GOV_PROPOSER == deployer is already rejected (fail) when the governance
# defaults are set up above, so no proposer/deployer check is needed here.
# GOV_PROPOSER_2 is already exported above; passed explicitly here too so the
# intent (D1 break-glass second proposer, optional on the sandbox) is visible
# at the call site.
# Unset GOV_AUTHORITY/GOV_TIMELOCK/GOV_VALIDATOR before this call: those
# names are also used by Upgrade.s.sol sessions, and a stale export left
# over from an earlier upgrade run in this shell must not leak into a fresh
# governance deploy here.
unset GOV_AUTHORITY GOV_TIMELOCK GOV_VALIDATOR
GOV_PROPOSER_2="$GOV_PROPOSER_2" make deploy-governance
[ -f deployments/governance.json ] || fail "deployments/governance.json not created"
GOV_AUTHORITY=$(jq -r '.authority' deployments/governance.json)
GOV_TIMELOCK=$(jq -r '.timelock' deployments/governance.json)
ok "GovernanceAuthority: $GOV_AUTHORITY (admin until $(jq -r '.transitionAt' deployments/governance.json))"
ok "ZeracleTimelock:     $GOV_TIMELOCK (delay $(jq -r '.timelockDelay' deployments/governance.json)s)"
cd "$ROOT_DIR"

# ===========================================================================
# 7. Update Web App Environment
# ===========================================================================

step "Updating web app environment..."
# Vite loads .env.local in every mode by default; writing anywhere else
# (e.g. .env.dev) requires a matching --mode flag. Matches chain-view.
# This overwrites the file wholesale — if you need user-only overrides add
# them to .env instead, which survives redeploys.
ENV_FILE="$WEB_DIR/.env.local"

# L2 addresses from deployment.json
ZRCL=$(jq -r '.contracts.zeracleToken' "$L2_DIR/deployment.json")
BRIDGE_L2=$(jq -r '.contracts.tokenBridge' "$L2_DIR/deployment.json")
FEE_DIST=$(jq -r '.contracts.feeDistribution' "$L2_DIR/deployment.json")
PAYMENT_ESCROW=$(jq -r '.contracts.paymentEscrow' "$L2_DIR/deployment.json")
COMPLIANCE=$(jq -r '.contracts.compliance' "$L2_DIR/deployment.json")
TOKEN_PORTAL=$(jq -r '.tokenPortal' "$L1_DIR/deployments/bridge.json")

# L1 FeeJuicePortal + fee asset — needed by the chain-view admin panel to
# bridge ETH→fee-juice for the SponsoredFPC. Sourced from the Aztec node's
# l1ContractAddresses and captured in deployment.json by the L2 deploy.
FEE_JUICE_PORTAL=$(jq -r '.l1ContractAddresses.feeJuicePortal' "$L2_DIR/deployment.json")
FEE_JUICE_ASSET=$(jq -r '.l1ContractAddresses.feeJuice' "$L2_DIR/deployment.json")
FEE_ASSET_HANDLER=$(jq -r '.l1ContractAddresses.feeAssetHandler // ""' "$L2_DIR/deployment.json")

# L1 addresses from deployments
POOL=$(jq -r '.liquidityPoolProxy' "$L1_DIR/deployments/local.json")
ADAPTER=$(jq -r '.depositAdapter' "$L1_DIR/deployments/local.json")
BRIDGE_GUARD_WEB=$(jq -r '.bridgeGuard' "$L1_DIR/deployments/local.json")
LUSD=$(jq -r '.mockLusd' "$L1_DIR/deployments/local.json")

if [ "$CHAIN_HOST_HEADLESS" = 0 ]; then
cat > "$ENV_FILE" << EOF
# Aztec L2 Sandbox
VITE_AZTEC_PXE_URL=http://localhost:8080
# Sandbox bundles the PXE and node on the same port; separating them points
# at a non-existent endpoint and surfaces as "NetworkError fetching :8079".
VITE_AZTEC_NODE_URL=http://localhost:8080

# Ethereum L1 (Anvil)
VITE_ETH_RPC_URL=http://localhost:8545
VITE_ETH_CHAIN_ID=31337

# L1 Contracts (auto-generated by deploy-sandbox.sh)
VITE_LIQUIDITY_POOL_ADDRESS=$POOL
VITE_DEPOSIT_ADAPTER_ADDRESS=$ADAPTER
VITE_TOKEN_PORTAL_ADDRESS=$TOKEN_PORTAL
VITE_BRIDGE_GUARD_ADDRESS=$BRIDGE_GUARD_WEB

# L2 Contracts (auto-generated by deploy-sandbox.sh)
VITE_ZRCL_CONTRACT_ADDRESS=$ZRCL
VITE_BRIDGE_CONTRACT_ADDRESS=$BRIDGE_L2
VITE_FEE_DISTRIBUTION_ADDRESS=$FEE_DIST
VITE_PAYMENT_ESCROW_ADDRESS=$PAYMENT_ESCROW
VITE_SPONSORED_FPC_ADDRESS=$SPONSORED_FPC
VITE_COMPLIANCE_CONTRACT_ADDRESS=$COMPLIANCE

# L1 Mock Token (LUSD — pool reserve / fee token)
VITE_LUSD_L1_ADDRESS=$LUSD
EOF

ok "Written $ENV_FILE"
fi

# ===========================================================================
# 7b. Update chain-view environment
# ===========================================================================

step "Updating chain-view environment..."
CHAIN_VIEW_ENV="$ROOT_DIR/chain-view/.env.local"

# Additional L1 addresses chain-view needs
WITHDRAWAL_ADAPTER=$(jq -r '.withdrawalAdapter'  "$L1_DIR/deployments/local.json")
BRIDGE_GUARD=$(jq       -r '.bridgeGuard'        "$L1_DIR/deployments/local.json")
TREASURY=$(jq           -r '.treasury'           "$L1_DIR/deployments/local.json")
INSURANCE_FUND=$(jq     -r '.insuranceFund'      "$L1_DIR/deployments/local.json")

# All token addresses from tokens.json
USDT=$(jq -r '.USDT' "$L1_DIR/deployments/tokens.json")
DAI=$(jq  -r '.DAI'  "$L1_DIR/deployments/tokens.json")
WETH=$(jq -r '.WETH' "$L1_DIR/deployments/tokens.json")
WBTC=$(jq -r '.WBTC' "$L1_DIR/deployments/tokens.json")
PAXG=$(jq -r '.PAXG' "$L1_DIR/deployments/tokens.json")
PAXS=$(jq -r '.PAXS' "$L1_DIR/deployments/tokens.json")

# L2 deployer
L2_DEPLOYER=$(jq -r '.deployer' "$L2_DIR/deployment.json")

if [ "$CHAIN_HOST_HEADLESS" = 0 ]; then
cat > "$CHAIN_VIEW_ENV" << EOF
# Auto-generated by deploy-sandbox.sh — do not edit by hand
VITE_ETH_RPC_URL=http://localhost:8545
VITE_ETH_CHAIN_ID=31337
VITE_AZTEC_PXE_URL=http://localhost:8080

# L1 contracts
VITE_LIQUIDITY_POOL_ADDRESS=$POOL
VITE_DEPOSIT_ADAPTER_ADDRESS=$ADAPTER
VITE_WITHDRAWAL_ADAPTER_ADDRESS=$WITHDRAWAL_ADAPTER
VITE_BRIDGE_GUARD_ADDRESS=$BRIDGE_GUARD
VITE_TREASURY_ADDRESS=$TREASURY
VITE_INSURANCE_FUND_ADDRESS=$INSURANCE_FUND
VITE_TOKEN_PORTAL_ADDRESS=$TOKEN_PORTAL
VITE_FEE_JUICE_PORTAL_ADDRESS=$FEE_JUICE_PORTAL
VITE_FEE_JUICE_L1_ADDRESS=$FEE_JUICE_ASSET
VITE_FEE_ASSET_HANDLER_ADDRESS=$FEE_ASSET_HANDLER
VITE_SPONSORED_FPC_ADDRESS=$SPONSORED_FPC

# L1 tokens
VITE_LUSD_L1_ADDRESS=$LUSD
VITE_USDT_L1_ADDRESS=$USDT
VITE_DAI_L1_ADDRESS=$DAI
VITE_WETH_L1_ADDRESS=$WETH
VITE_WBTC_L1_ADDRESS=$WBTC
VITE_PAXG_L1_ADDRESS=$PAXG
VITE_PAXS_L1_ADDRESS=$PAXS

# L2 contracts
VITE_ZRCL_CONTRACT_ADDRESS=$ZRCL
VITE_BRIDGE_CONTRACT_ADDRESS=$BRIDGE_L2
VITE_FEE_DISTRIBUTION_ADDRESS=$FEE_DIST
VITE_PAYMENT_ESCROW_ADDRESS=$PAYMENT_ESCROW
VITE_L2_DEPLOYER_ADDRESS=$L2_DEPLOYER
EOF

ok "Written $CHAIN_VIEW_ENV"
fi

# ===========================================================================
# 8. Wipe stale PXE/wallet LMDB state
#
# Chain-server and v1-l2 scripts persist PXE state in pxe_data_*/wallet_data_*
# LMDB dirs keyed by sandbox rollup address. When the sandbox is redeployed
# those directories point at block hashes that no longer exist and startup
# fails with "Block hash not found". Wipe them here so the chain-server
# (started manually) boots cleanly against the new sandbox.
# ===========================================================================

step "Wiping stale PXE/wallet LMDB state..."
# aztec >= 5.0.1: the embedded wallet roots its LMDB stores under
# ./aztec-wallet-data/ (per-chain sub-stores) instead of cwd-relative
# pxe_data_*/wallet_data_* — wipe both layouts.
rm -rf "$SERVER_DIR"/pxe_data_* "$SERVER_DIR"/wallet_data_* "$SERVER_DIR"/aztec-wallet-data \
       "$L2_DIR"/pxe_data_*   "$L2_DIR"/wallet_data_*   "$L2_DIR"/aztec-wallet-data 2>/dev/null || true
ok "Stale PXE state cleared"

# ===========================================================================
# 8b. Start L2 Block Producer (v4.2.0 expiration-timestamp fix)
#
# v4.2.0 `.simulate()` / `.send()` embed an expiration timestamp that's
# checked against block.timestamp. An idle sandbox produces no blocks, its
# block.timestamp lags wall-clock, and simulate fails with "Invalid expiration
# timestamp". The existing sandbox-block-producer.sh loops trigger-l2-block
# every N seconds to keep block.timestamp current.
# ===========================================================================

step "Starting L2 block producer (60s interval)..."
cd "$L2_DIR"
setsid nohup bash scripts/sandbox-block-producer.sh --loop 60 > /tmp/zeracle-block-producer.log 2>&1 < /dev/null &
BLOCK_PRODUCER_PID=$!
disown "$BLOCK_PRODUCER_PID" 2>/dev/null || true
sleep 2
if kill -0 "$BLOCK_PRODUCER_PID" 2>/dev/null; then
  ok "Block producer running (PID $BLOCK_PRODUCER_PID, log: /tmp/zeracle-block-producer.log)"
else
  warn "Block producer exited immediately — check /tmp/zeracle-block-producer.log"
fi

# ===========================================================================
# 9. Generate deployment manifest
# ===========================================================================

step "Generating deployment manifest..."

# Read all addresses
L1_LOCAL="$L1_DIR/deployments/local.json"
L1_BRIDGE="$L1_DIR/deployments/bridge.json"
L1_GOV="$L1_DIR/deployments/governance.json"
L1_TOKENS="$L1_DIR/deployments/tokens.json"
L2_DEPLOY="$L2_DIR/deployment.json"

cat > "$SCRIPT_DIR/deployment-manifest.json" << MANIFEST
{
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "network": "local",
  "rpc": {
    "l1": "http://localhost:8545",
    "l2Pxe": "http://localhost:8080",
    "accountServer": "http://localhost:3001"
  },
  "accounts": [
    {
      "index": 0,
      "address": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "privateKey": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
      "role": "deployer"
    },
    {
      "index": 1,
      "address": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      "privateKey": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
      "role": "user"
    },
    {
      "index": 2,
      "address": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      "privateKey": "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
      "role": "user"
    },
    {
      "index": 3,
      "address": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
      "privateKey": "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
      "role": "user"
    },
    {
      "index": 4,
      "address": "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
      "privateKey": "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
      "role": "user"
    },
    {
      "index": 5,
      "address": "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
      "privateKey": "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
      "role": "user"
    },
    {
      "index": 6,
      "address": "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
      "privateKey": "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
      "role": "user"
    },
    {
      "index": 7,
      "address": "0x14dC79964da2C08dA15Fd353d30d9CBd31045D41",
      "privateKey": "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
      "role": "user"
    },
    {
      "index": 8,
      "address": "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
      "privateKey": "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
      "role": "user"
    },
    {
      "index": 9,
      "address": "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
      "privateKey": "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
      "role": "user"
    }
  ],
  "l1": {
    "chainId": 31337,
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
      "proposer2": "$(jq -r '.proposer2 // ""' "$L1_GOV")",
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
      "compliance": "$(jq -r '.contracts.compliance' "$L2_DEPLOY")",
      "tokenBridge": "$(jq -r '.contracts.tokenBridge' "$L2_DEPLOY")",
      "feeDistribution": "$(jq -r '.contracts.feeDistribution' "$L2_DEPLOY")",
      "paymentEscrow": "$(jq -r '.contracts.paymentEscrow' "$L2_DEPLOY")",
      "sponsoredFpc": "$(jq -r '.contracts.sponsoredFpc' "$L2_DEPLOY")"
    },
    "deployer": "$(jq -r '.deployer' "$L2_DEPLOY")",
    "bridge": {
      "l1Portal": "$(jq -r '.bridge.l1Portal' "$L2_DEPLOY")",
      "l2Bridge": "$(jq -r '.bridge.l2Bridge' "$L2_DEPLOY")"
    },
    "testAccounts": $L2_TEST_ACCOUNTS_JSON
  },
  "env": {
    "VITE_AZTEC_PXE_URL": "http://localhost:8080",
    "VITE_ETH_RPC_URL": "http://localhost:8545",
    "VITE_ETH_CHAIN_ID": "31337",
    "VITE_LIQUIDITY_POOL_ADDRESS": "$(jq -r '.liquidityPoolProxy' "$L1_LOCAL")",
    "VITE_DEPOSIT_ADAPTER_ADDRESS": "$(jq -r '.depositAdapter' "$L1_LOCAL")",
    "VITE_WITHDRAWAL_ADAPTER_ADDRESS": "$(jq -r '.withdrawalAdapter' "$L1_LOCAL")",
    "VITE_BRIDGE_GUARD_ADDRESS": "$(jq -r '.bridgeGuard' "$L1_LOCAL")",
    "VITE_TREASURY_ADDRESS": "$(jq -r '.treasury' "$L1_LOCAL")",
    "VITE_INSURANCE_FUND_ADDRESS": "$(jq -r '.insuranceFund' "$L1_LOCAL")",
    "VITE_TOKEN_PORTAL_ADDRESS": "$(jq -r '.tokenPortal' "$L1_BRIDGE")",
    "VITE_FEE_JUICE_PORTAL_ADDRESS": "$(jq -r '.l1ContractAddresses.feeJuicePortal' "$L2_DEPLOY")",
    "VITE_FEE_JUICE_L1_ADDRESS": "$(jq -r '.l1ContractAddresses.feeJuice' "$L2_DEPLOY")",
    "VITE_FEE_ASSET_HANDLER_ADDRESS": "$(jq -r '.l1ContractAddresses.feeAssetHandler // ""' "$L2_DEPLOY")",
    "VITE_ZRCL_CONTRACT_ADDRESS": "$(jq -r '.contracts.zeracleToken' "$L2_DEPLOY")",
    "VITE_COMPLIANCE_CONTRACT_ADDRESS": "$(jq -r '.contracts.compliance' "$L2_DEPLOY")",
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

ok "Written $SCRIPT_DIR/deployment-manifest.json"

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Zeracle Local Stack Deployed Successfully ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${BLUE}Anvil (L1):${NC}           http://localhost:8545"
echo -e "  ${BLUE}Aztec PXE (L2):${NC}       http://localhost:8080"
echo ""
echo -e "  ${BLUE}TokenPortal (L1):${NC}      $TOKEN_PORTAL"
echo -e "  ${BLUE}ZeracleToken (L2):${NC}     $ZRCL"
echo -e "  ${BLUE}TokenBridge (L2):${NC}      $BRIDGE_L2"
echo -e "  ${BLUE}PaymentEscrow (L2):${NC}    $PAYMENT_ESCROW"
echo ""
echo -e "  ${BLUE}Manifest:${NC}              ./deployments/sandbox-local/deployment-manifest.json"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    1. Clear the site's browser storage (OPFS + IndexedDB) if you used an older chain"
echo -e "    2. cd chain-server && npm start  ${BLUE}# run manually in its own terminal${NC}"
echo -e "    3. cd interfaces/apps/web && yarn dev"
echo -e "    4. Open http://localhost:5173"
echo ""
echo -e "  ${YELLOW}Logs:${NC}"
echo -e "    Anvil:         /tmp/zeracle-anvil.log"
echo -e "    Sandbox:       /tmp/zeracle-sandbox.log"
echo -e "    Block Producer: /tmp/zeracle-block-producer.log"
echo ""
