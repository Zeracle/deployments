#!/usr/bin/env bash
# Writes the secret-free public manifest (schema zeracle.env/v1) that chain-view
# loads. Design: temp/versions/260913/chain-view-control-plane-design.md §4.
# Required: PM_ENV_ID PM_KIND PM_LABEL PM_CHAIN_ID PM_L1_DIR PM_L2_DIR PM_OUT
#           PM_PUBLIC_L1_RPC PM_PUBLIC_AZTEC_NODE
# Optional: PM_SUFFIX ("" or "-testnet"), PM_PUBLIC_CHAIN_SERVER, PM_EXPLORER_L1,
#           PM_EXPLORER_L2, PM_READ_L1_RPC / PM_READ_AZTEC_NODE (deploy-time reads;
#           never written), test overrides PM_NODE_INFO_FILE PM_EXPECTED_FILE
#           PM_DEPLOY_BLOCK PM_SOURCES_JSON.
#
# Other mode: `public-manifest.sh --check-url <url>` does nothing but run the
# same credentialed-URL check this script refuses endpoint values with, then
# exits 0/1. Never prints the URL either way.
set -euo pipefail
die() { echo "public-manifest: $*" >&2; exit 1; }

# Same rules as chain-view src/env/secrets.ts (commit d024d72): a URL carries
# credentials if it has userinfo, any >=20-char [A-Za-z0-9_-] path segment
# (Alchemy/Infura/QuickNode/Blast/Ankr-style provider keys), or a query param
# whose NAME (not value) matches key|token|auth|secret.
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

if [ "${1:-}" = "--check-url" ]; then
  [ -n "${2:-}" ] || die "--check-url requires a URL argument"
  if url_carries_credentials "$2"; then
    die "refusing to write: an endpoint URL carries credentials — use a public or origin-restricted RPC"
  fi
  echo "public-manifest: --check-url ok (no embedded credentials)"
  exit 0
fi

for v in PM_ENV_ID PM_KIND PM_LABEL PM_CHAIN_ID PM_L1_DIR PM_L2_DIR PM_OUT PM_PUBLIC_L1_RPC PM_PUBLIC_AZTEC_NODE; do
  [ -n "${!v:-}" ] || die "$v is required"
done

SUFFIX="${PM_SUFFIX:-}"
D="$PM_L1_DIR/deployments"
LOCAL="$D/local$SUFFIX.json"; TOKENS="$D/tokens$SUFFIX.json"; BRIDGE="$D/bridge$SUFFIX.json"
GOV="$D/governance$SUFFIX.json"; BASKET="$D/basket$SUFFIX.json"; L2="$PM_L2_DIR/deployment.json"
for f in "$LOCAL" "$TOKENS" "$BRIDGE" "$GOV" "$BASKET" "$L2"; do [ -f "$f" ] || die "missing $f"; done

# I3: a failed regeneration must not leave a stale manifest in place — same
# pattern deploy-sandbox.sh already uses for governance.json/basket.json.
rm -f "$PM_OUT"

# The Aztec node's own facts: its L1 contracts and version.
if [ -n "${PM_NODE_INFO_FILE:-}" ]; then
  NODE_INFO=$(cat "$PM_NODE_INFO_FILE") || die "could not read PM_NODE_INFO_FILE"
else
  [ -n "${PM_READ_AZTEC_NODE:-}" ] || die "PM_READ_AZTEC_NODE (or PM_NODE_INFO_FILE) is required"
  NODE_INFO_RESPONSE=$(curl -sf -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"node_getNodeInfo","params":[]}' "$PM_READ_AZTEC_NODE") \
    || die "node_getNodeInfo failed"
  jq -e '.error == null' <<<"$NODE_INFO_RESPONSE" >/dev/null \
    || die "node_getNodeInfo returned a JSON-RPC error: $(jq -c '.error // empty' <<<"$NODE_INFO_RESPONSE")"
  NODE_INFO=$(jq -c '.result' <<<"$NODE_INFO_RESPONSE") || die "node_getNodeInfo: could not read .result"
fi
jq -e '(.l1ContractAddresses.rollupAddress // "") | length > 0' <<<"$NODE_INFO" >/dev/null \
  || die "node_getNodeInfo response missing .result.l1ContractAddresses.rollupAddress"

# Expected values = as deployed (read on-chain now; drift checks flag later changes).
if [ -n "${PM_EXPECTED_FILE:-}" ]; then
  EXPECTED=$(cat "$PM_EXPECTED_FILE") || die "could not read PM_EXPECTED_FILE"
else
  [ -n "${PM_READ_L1_RPC:-}" ] || die "PM_READ_L1_RPC (or PM_EXPECTED_FILE) is required"
  call() { cast call "$1" "$2" --rpc-url "$PM_READ_L1_RPC" | awk '{print $1}'; }
  # Each read is its own assignment: a $(...) embedded as a jq --arg value would
  # let `set -e` see only jq's (successful) exit status and swallow the failure
  # (the same bug class as C1's git shas).
  CUSHION_RATE_BPS=$(call "$(jq -r '.liquidityPoolProxy' "$LOCAL")" 'cushionRateBps()(uint256)') || die "cushionRateBps() read failed"
  TREASURY_WITHDRAWAL_CAP=$(call "$(jq -r '.treasury' "$LOCAL")" 'withdrawalCap()(uint256)') || die "withdrawalCap() read failed"
  NETWORK_SPONSOR_CAP=$(call "$(jq -r '.networkFund' "$LOCAL")" 'sponsorCap()(uint256)') || die "sponsorCap() read failed"
  CONVERTER_MAX_SLIPPAGE_BPS=$(call "$(jq -r '.feeConverter' "$LOCAL")" 'maxSlippageBps()(uint256)') || die "maxSlippageBps() read failed"
  for nv in "cushionRateBps:$CUSHION_RATE_BPS" "treasuryWithdrawalCap:$TREASURY_WITHDRAWAL_CAP" \
            "networkSponsorCap:$NETWORK_SPONSOR_CAP" "converterMaxSlippageBps:$CONVERTER_MAX_SLIPPAGE_BPS"; do
    name="${nv%%:*}"; val="${nv#*:}"
    [[ "$val" =~ ^[0-9]+$ ]] || die "$name ('$val') from on-chain read is not a numeric value"
  done
  EXPECTED=$(jq -n \
    --argjson cushion "$CUSHION_RATE_BPS" --arg wcap "$TREASURY_WITHDRAWAL_CAP" \
    --arg scap "$NETWORK_SPONSOR_CAP" --argjson slip "$CONVERTER_MAX_SLIPPAGE_BPS" \
    '{cushionRateBps: $cushion, treasuryWithdrawalCap: $wcap, networkSponsorCap: $scap,
      converterMaxSlippageBps: $slip, feeTokenSymbol: "LUSD"}')
fi

if [ -n "${PM_DEPLOY_BLOCK:-}" ]; then
  DEPLOY_BLOCK=$PM_DEPLOY_BLOCK
else
  RUN="$PM_L1_DIR/broadcast/DeployLocal.s.sol/$PM_CHAIN_ID/run-latest.json"
  [ -f "$RUN" ] || die "missing $RUN (needed for l1.deployBlock)"
  DEPLOY_BLOCK=$(cast to-dec "$(jq -r '.receipts[0].blockNumber' "$RUN")") || die "could not read deployBlock from $RUN"
fi

# C1: sources.* must be real, verifiable git shas — never silently empty.
# Each git read is its own assignment (see CUSHION_RATE_BPS et al. above for
# why), and every source value — whether computed here or handed in via
# PM_SOURCES_JSON — is shape-checked below.
validate_sources() {
  local json="$1" k v
  for k in v1-l1 v1-l2 deployments; do
    v=$(jq -r --arg k "$k" '.[$k] // ""' <<<"$json") || die "PM_SOURCES_JSON is not valid JSON"
    [[ "$v" =~ ^[0-9a-f]{7,40}$ ]] || die "sources.$k ('$v') is not a valid git sha (expected 7-40 lowercase hex chars)"
  done
}

if [ -n "${PM_SOURCES_JSON:-}" ]; then
  # PM_SOURCES_JSON is authoritative when given: never touch git in this branch
  # (release tarballs exclude .git, so `git -C ... rev-parse` would fail there).
  SOURCES=$PM_SOURCES_JSON
else
  L1_SHA=$(git -C "$PM_L1_DIR" rev-parse --short HEAD) \
    || die "git rev-parse failed for $PM_L1_DIR (v1-l1) — pass PM_SOURCES_JSON when running from a checkout without .git (e.g. a release tarball)"
  L2_SHA=$(git -C "$PM_L2_DIR" rev-parse --short HEAD) \
    || die "git rev-parse failed for $PM_L2_DIR (v1-l2) — pass PM_SOURCES_JSON when running from a checkout without .git (e.g. a release tarball)"
  DEPLOYMENTS_SHA=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD) \
    || die "git rev-parse failed for the deployments repo — pass PM_SOURCES_JSON when running from a checkout without .git (e.g. a release tarball)"
  SOURCES=$(jq -n --arg a "$L1_SHA" --arg b "$L2_SHA" --arg c "$DEPLOYMENTS_SHA" \
    '{"v1-l1": $a, "v1-l2": $b, "deployments": $c}')
fi
validate_sources "$SOURCES"

json_or_null() { if [ -n "$1" ]; then jq -n --arg v "$1" '$v'; else echo null; fi; }

# I1: create the temp file beside the output (not in system tmp) so `mv` is a
# same-filesystem rename, and chmod it below before the mv — mktemp's default
# 0600 would otherwise survive the mv and break the EC2 scp pull.
# M2: trap covers every exit path (die, a later failed check, or success).
TMP=$(mktemp "$(dirname "$PM_OUT")/.pm.XXXXXX")
trap 'rm -f "$TMP"' EXIT

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
      # ZER-49 §3: the asset set is tokens.json's own `decimals` map (emitted by v1-l1's
      # BasketTable), not a list repeated here. The literal below is the pre-crvUSD
      # fallback for a tokens.json written by a v1-l1 older than ZER-49; it is what this
      # line used to be, and it is the reason the published manifest carried eight tokens
      # for a nine-token deployment once crvUSD landed.
      tokens: (($T.decimals // {"LUSD":18,"USDT":6,"USDC":6,"DAI":18,"WETH":18,"WBTC":8,"PAXG":18,"PAXS":18})
               | to_entries
               | map(select($T[.key] != null) | {key: .key, value: {address: $T[.key], decimals: .value}})
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

# M3: deny-list must test every key at EVERY depth (not just leaf keys) to
# match chain-view src/env/secrets.ts findSecrets()'s walk — a key like
# `{"apiKeyBundle": {...}}` must be caught even though its value isn't a leaf.
if jq -e '[paths | .[] | strings
          | test("private_?key|secret|signing_?key|mnemonic|seed|api_?key|password|passphrase|salt"; "i")] | any' \
     "$TMP" >/dev/null; then
  die "refusing to write: a secret-looking key name is present"
fi

# Same URL-credential rule as --check-url above, applied to every string value
# in the generated document.
while IFS= read -r s; do
  if url_carries_credentials "$s"; then
    die "refusing to write: an endpoint URL carries credentials — use a public or origin-restricted RPC"
  fi
done < <(jq -r '.. | strings' "$TMP")

# I2: don't rely solely on chain-view's own validator (not available on EC2) —
# assert every REQUIRED field from chain-view/src/env/schema.ts is non-null
# and (for strings) non-empty before writing. Fields that are `.optional()` or
# `.nullable()` in the schema (chainServer, explorers.l1/l2, complianceRegistry,
# mockDexAggregator, feeAssetHandler, l1.governance, l2.contracts.compliance,
# feeCustodian, sponsoredFpcFeeJuiceSlot) are intentionally left out below.
MISSING_FIELDS=$(jq -r '
  def required: [
    ["schema"], ["env","id"], ["env","kind"], ["env","label"], ["env","generatedAt"],
    ["env","sources","v1-l1"], ["env","sources","v1-l2"], ["env","sources","deployments"],
    ["endpoints","l1Rpc"], ["endpoints","aztecNode"], ["endpoints","explorers"],
    ["l1","chainId"], ["l1","deployBlock"],
    ["l1","contracts","liquidityPoolProxy"], ["l1","contracts","liquidityPoolImpl"],
    ["l1","contracts","depositAdapter"], ["l1","contracts","withdrawalAdapter"],
    ["l1","contracts","bridgeGuard"], ["l1","contracts","treasury"],
    ["l1","contracts","collateralReserve"], ["l1","contracts","networkFund"],
    ["l1","contracts","feeConverter"], ["l1","contracts","tokenPortal"],
    ["l1","contracts","basketManager"], ["l1","contracts","chainlinkOracle"],
    ["l1","contracts","uniswapTwap"],
    ["l1","tokens"],
    ["l1","aztec","rollup"], ["l1","aztec","inbox"], ["l1","aztec","registry"],
    ["l1","aztec","feeJuicePortal"], ["l1","aztec","feeJuice"], ["l1","aztec","nodeVersion"],
    ["l2","contracts","zeracleToken"], ["l2","contracts","tokenBridge"],
    ["l2","contracts","feeDistribution"], ["l2","contracts","paymentEscrow"],
    ["l2","contracts","sponsoredFpc"],
    ["l2","complianceEnabled"], ["l2","feeDistributionTestHelpers"], ["l2","deployer"],
    ["expected","cushionRateBps"], ["expected","treasuryWithdrawalCap"],
    ["expected","networkSponsorCap"], ["expected","converterMaxSlippageBps"],
    ["expected","feeTokenSymbol"],
    ["thresholds"]
  ];
  . as $doc |
  [ required[] | . as $p | ($doc | getpath($p)) as $v |
    if $v == null then ($p | join("."))
    elif ($v|type) == "string" and ($v|length) == 0 then ($p | join("."))
    else empty end
  ] | join(", ")
' "$TMP") || die "required-field check failed to run against the generated manifest"
[ -z "$MISSING_FIELDS" ] || die "refusing to write: schema-required field(s) missing or empty: $MISSING_FIELDS"

chmod 0644 "$TMP"
mv "$TMP" "$PM_OUT"
echo "public-manifest: wrote $PM_OUT ($PM_ENV_ID)"
