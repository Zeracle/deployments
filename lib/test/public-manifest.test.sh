#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); FX="$HERE/fixtures"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
run() {
  env PM_ENV_ID=sandbox-local PM_KIND=sandbox PM_LABEL="Sandbox (local)" PM_CHAIN_ID=31337 \
    PM_L1_DIR="$FX/v1-l1" PM_L2_DIR="$FX/v1-l2" PM_OUT="$OUT/pm.json" \
    PM_PUBLIC_L1_RPC=http://localhost:8545 PM_PUBLIC_AZTEC_NODE=http://localhost:8080 \
    PM_PUBLIC_CHAIN_SERVER=http://localhost:3001 \
    PM_NODE_INFO_FILE="$FX/node-info.json" PM_EXPECTED_FILE="$FX/expected.json" PM_DEPLOY_BLOCK=7 \
    PM_SOURCES_JSON='{"v1-l1":"test","v1-l2":"test","deployments":"test"}' \
    "$@" bash "$HERE/../public-manifest.sh"
}
check() { jq -e "$1" "$OUT/pm.json" >/dev/null || { echo "FAIL: $1"; exit 1; }; }

run >/dev/null
check '.schema == "zeracle.env/v1" and .env.id == "sandbox-local" and .env.kind == "sandbox"'
check '.l1.contracts.feeConverter == "0x000000000000000000000000000000000000a009"'
check '.l1.contracts.tokenPortal == "0x000000000000000000000000000000000000a00a"'
check '.l1.governance.proposers == ["0x000000000000000000000000000000000000d006"]'
check '.l1.aztec.rollup == "0x000000000000000000000000000000000000e001" and .l1.deployBlock == 7'
check '.l2.complianceEnabled == true and .l2.contracts.compliance != null'
check '.l1.tokens | keys == ["LUSD","USDC","USDT","WETH"]'
check '[paths | map(tostring) | last] | index("privateKey") == null'

if run PM_PUBLIC_L1_RPC=https://eth-mainnet.g.alchemy.com/v2/AbCdEfGhIjKlMnOpQrStU >/dev/null 2>"$OUT/err"; then
  echo "FAIL: keyed RPC accepted"; exit 1
fi
grep -q 'carries credentials' "$OUT/err" || { echo "FAIL: wrong refusal message"; cat "$OUT/err"; exit 1; }

CV="$HERE/../../../chain-view"
if [ -d "$CV/node_modules" ]; then npm --prefix "$CV" run -s validate-manifest -- "$OUT/pm.json"; fi
echo "public-manifest tests: ok"
