#!/usr/bin/env bash
# Writes the secret-free public manifest (schema zeracle.env/v1) that chain-view
# loads. Design: temp/versions/260913/chain-view-control-plane-design.md §4.
# Required: PM_ENV_ID PM_KIND PM_LABEL PM_CHAIN_ID PM_L1_DIR PM_L2_DIR PM_OUT
#           PM_PUBLIC_L1_RPC PM_PUBLIC_AZTEC_NODE
# Optional: PM_SUFFIX ("" or "-testnet"), PM_PUBLIC_CHAIN_SERVER, PM_EXPLORER_L1,
#           PM_EXPLORER_L2, PM_READ_L1_RPC / PM_READ_AZTEC_NODE (deploy-time reads;
#           never written), test overrides PM_NODE_INFO_FILE PM_EXPECTED_FILE
#           PM_DEPLOY_BLOCK PM_SOURCES_JSON.
set -euo pipefail
die() { echo "public-manifest: $*" >&2; exit 1; }
for v in PM_ENV_ID PM_KIND PM_LABEL PM_CHAIN_ID PM_L1_DIR PM_L2_DIR PM_OUT PM_PUBLIC_L1_RPC PM_PUBLIC_AZTEC_NODE; do
  [ -n "${!v:-}" ] || die "$v is required"
done

SUFFIX="${PM_SUFFIX:-}"
D="$PM_L1_DIR/deployments"
LOCAL="$D/local$SUFFIX.json"; TOKENS="$D/tokens$SUFFIX.json"; BRIDGE="$D/bridge$SUFFIX.json"
GOV="$D/governance$SUFFIX.json"; BASKET="$D/basket$SUFFIX.json"; L2="$PM_L2_DIR/deployment.json"
for f in "$LOCAL" "$TOKENS" "$BRIDGE" "$GOV" "$BASKET" "$L2"; do [ -f "$f" ] || die "missing $f"; done

# The Aztec node's own facts: its L1 contracts and version.
if [ -n "${PM_NODE_INFO_FILE:-}" ]; then
  NODE_INFO=$(cat "$PM_NODE_INFO_FILE")
else
  [ -n "${PM_READ_AZTEC_NODE:-}" ] || die "PM_READ_AZTEC_NODE (or PM_NODE_INFO_FILE) is required"
  NODE_INFO=$(curl -sf -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"node_getNodeInfo","params":[]}' "$PM_READ_AZTEC_NODE" | jq -c '.result') \
    || die "node_getNodeInfo failed"
fi

# Expected values = as deployed (read on-chain now; drift checks flag later changes).
if [ -n "${PM_EXPECTED_FILE:-}" ]; then
  EXPECTED=$(cat "$PM_EXPECTED_FILE")
else
  [ -n "${PM_READ_L1_RPC:-}" ] || die "PM_READ_L1_RPC (or PM_EXPECTED_FILE) is required"
  call() { cast call "$1" "$2" --rpc-url "$PM_READ_L1_RPC" | awk '{print $1}'; }
  EXPECTED=$(jq -n \
    --argjson cushion "$(call "$(jq -r '.liquidityPoolProxy' "$LOCAL")" 'cushionRateBps()(uint256)')" \
    --arg wcap "$(call "$(jq -r '.treasury' "$LOCAL")" 'withdrawalCap()(uint256)')" \
    --arg scap "$(call "$(jq -r '.networkFund' "$LOCAL")" 'sponsorCap()(uint256)')" \
    --argjson slip "$(call "$(jq -r '.feeConverter' "$LOCAL")" 'maxSlippageBps()(uint256)')" \
    '{cushionRateBps: $cushion, treasuryWithdrawalCap: $wcap, networkSponsorCap: $scap,
      converterMaxSlippageBps: $slip, feeTokenSymbol: "LUSD"}')
fi

if [ -n "${PM_DEPLOY_BLOCK:-}" ]; then
  DEPLOY_BLOCK=$PM_DEPLOY_BLOCK
else
  RUN="$PM_L1_DIR/broadcast/DeployLocal.s.sol/$PM_CHAIN_ID/run-latest.json"
  [ -f "$RUN" ] || die "missing $RUN (needed for l1.deployBlock)"
  DEPLOY_BLOCK=$(cast to-dec "$(jq -r '.receipts[0].blockNumber' "$RUN")")
fi

if [ -n "${PM_SOURCES_JSON:-}" ]; then
  SOURCES=$PM_SOURCES_JSON
else
  rev() { git -C "$1" rev-parse --short HEAD; }
  SOURCES=$(jq -n --arg a "$(rev "$PM_L1_DIR")" --arg b "$(rev "$PM_L2_DIR")" --arg c "$(rev "$(dirname "$0")/..")" \
    '{"v1-l1": $a, "v1-l2": $b, "deployments": $c}')
fi

json_or_null() { if [ -n "$1" ]; then jq -n --arg v "$1" '$v'; else echo null; fi; }

TMP=$(mktemp)
jq -n \
  --arg id "$PM_ENV_ID" --arg kind "$PM_KIND" --arg label "$PM_LABEL" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson sources "$SOURCES" --arg l1Rpc "$PM_PUBLIC_L1_RPC" --arg aztecNode "$PM_PUBLIC_AZTEC_NODE" \
  --argjson chainServer "$(json_or_null "${PM_PUBLIC_CHAIN_SERVER:-}")" \
  --argjson explorerL1 "$(json_or_null "${PM_EXPLORER_L1:-}")" --argjson explorerL2 "$(json_or_null "${PM_EXPLORER_L2:-}")" \
  --argjson chainId "$PM_CHAIN_ID" --argjson deployBlock "$DEPLOY_BLOCK" \
  --slurpfile local "$LOCAL" --slurpfile tokens "$TOKENS" --slurpfile bridge "$BRIDGE" \
  --slurpfile gov "$GOV" --slurpfile basket "$BASKET" --slurpfile l2 "$L2" \
  --argjson ni "$NODE_INFO" --argjson expected "$EXPECTED" '
  def nn: if . == null or . == "" then null else . end;
  def nz: if type == "string" and test("^0x0{40}$"; "i") then null else . end;
  ($local[0]) as $L | ($tokens[0]) as $T | ($l2[0]) as $D | ($gov[0]) as $G | ($ni.l1ContractAddresses) as $A |
  {
    schema: "zeracle.env/v1",
    env: {id: $id, kind: $kind, label: $label, generatedAt: $now, sources: $sources},
    endpoints: {l1Rpc: $l1Rpc, aztecNode: $aztecNode, chainServer: $chainServer,
                explorers: {l1: $explorerL1, l2: $explorerL2}},
    l1: {
      chainId: $chainId, deployBlock: $deployBlock,
      contracts: {
        liquidityPoolProxy: $L.liquidityPoolProxy, liquidityPoolImpl: $L.liquidityPoolImpl,
        depositAdapter: $L.depositAdapter, withdrawalAdapter: $L.withdrawalAdapter, bridgeGuard: $L.bridgeGuard,
        treasury: $L.treasury, collateralReserve: $L.collateralReserve, networkFund: $L.networkFund,
        feeConverter: $L.feeConverter, tokenPortal: $bridge[0].tokenPortal, basketManager: $basket[0].basketManager,
        chainlinkOracle: $L.chainlinkOracle, uniswapTwap: $L.uniswapTwap,
        complianceRegistry: null,
        mockDexAggregator: ($L.mockDexAggregator | nn),
        feeAssetHandler: ($D.l1ContractAddresses.feeAssetHandler | nn)
      },
      tokens: ([["LUSD",18],["USDT",6],["USDC",6],["DAI",18],["WETH",18],["WBTC",8],["PAXG",18],["PAXS",18]]
               | map(select($T[.[0]] != null) | {key: .[0], value: {address: $T[.[0]], decimals: .[1]}})
               | from_entries),
      governance: {authority: $G.authority, timelock: $G.timelock, validator: $G.validator, admin: $G.admin,
                   guardian: $G.guardian, proposers: ([$G.proposer, $G.proposer2] | map(nn | nz) | map(select(. != null))),
                   transitionAt: $G.transitionAt, timelockDelay: $G.timelockDelay, executionWindow: $G.executionWindow},
      aztec: {rollup: $A.rollupAddress, inbox: $A.inboxAddress, registry: $A.registryAddress,
              feeJuicePortal: $A.feeJuicePortalAddress, feeJuice: $A.feeJuiceAddress, nodeVersion: $ni.nodeVersion}
    },
    l2: {
      contracts: {zeracleToken: $D.contracts.zeracleToken, tokenBridge: $D.contracts.tokenBridge,
                  feeDistribution: $D.contracts.feeDistribution, paymentEscrow: $D.contracts.paymentEscrow,
                  sponsoredFpc: $D.contracts.sponsoredFpc, compliance: ($D.contracts.compliance | nn)},
      complianceEnabled: (if $D.complianceEnabled == false then false else true end),
      feeDistributionTestHelpers: ($D.feeDistributionTestHelpers // false),
      deployer: $D.deployer, feeCustodian: ($D.feeCustodian | nn)
    },
    expected: $expected,
    thresholds: {}
  }' > "$TMP"

# Deny-list, same rules as chain-view src/env/secrets.ts (commit d024d72):
# key names matched anywhere (unanchored, case-insensitive), and a URL is
# credentialed if it has userinfo, any >=20-char [A-Za-z0-9_-] path segment
# (Alchemy/Infura/QuickNode/Blast/Ankr-style provider keys), or a query
# param whose NAME (not value) matches key|token|auth|secret.
if jq -e '[paths(scalars) | map(tostring) | last
          | test("private_?key|secret|signing_?key|mnemonic|seed|api_?key|password|passphrase|salt"; "i")] | any' \
     "$TMP" >/dev/null; then
  rm -f "$TMP"; die "refusing to write: a secret-looking key name is present"
fi

url_carries_credentials() {
  local s="$1"
  [[ "$s" =~ ^(https?|wss?):// ]] || return 1
  local rest="${s#*://}"
  local authority="${rest%%/*}"
  [[ "$authority" == *@* ]] && return 0
  local pathAndQuery=""
  [[ "$rest" == */* ]] && pathAndQuery="/${rest#*/}"
  local path="${pathAndQuery%%\?*}"
  local query=""
  [[ "$pathAndQuery" == *'?'* ]] && query="${pathAndQuery#*'?'}"
  local seg segs=()
  IFS='/' read -ra segs <<< "$path"
  for seg in "${segs[@]}"; do
    [[ -n "$seg" && ${#seg} -ge 20 && "$seg" =~ ^[A-Za-z0-9_-]+$ ]] && return 0
  done
  if [[ -n "$query" ]]; then
    local p name lc params=()
    IFS='&' read -ra params <<< "$query"
    for p in "${params[@]}"; do
      name="${p%%=*}"
      lc=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
      [[ "$lc" =~ (key|token|auth|secret) ]] && return 0
    done
  fi
  return 1
}

while IFS= read -r s; do
  if url_carries_credentials "$s"; then
    rm -f "$TMP"; die "refusing to write: an endpoint URL carries credentials — use a public or origin-restricted RPC"
  fi
done < <(jq -r '.. | strings' "$TMP")

mv "$TMP" "$PM_OUT"
echo "public-manifest: wrote $PM_OUT ($PM_ENV_ID)"
