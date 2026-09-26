#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); FX="$HERE/fixtures"
GEN="$HERE/../public-manifest.sh"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
run() {
  env PM_ENV_ID=sandbox-local PM_KIND=sandbox PM_LABEL="Sandbox (local)" PM_CHAIN_ID=31337 \
    PM_L1_DIR="$FX/v1-l1" PM_L2_DIR="$FX/v1-l2" PM_OUT="$OUT/pm.json" \
    PM_PUBLIC_L1_RPC=http://localhost:8545 PM_PUBLIC_AZTEC_NODE=http://localhost:8080 \
    PM_PUBLIC_CHAIN_SERVER=http://localhost:3001 \
    PM_NODE_INFO_FILE="$FX/node-info.json" PM_EXPECTED_FILE="$FX/expected.json" PM_DEPLOY_BLOCK=7 \
    PM_SOURCES_JSON='{"v1-l1":"0000001","v1-l2":"0000002","deployments":"0000003"}' \
    "$@" bash "$GEN"
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
# ZER-178 (ZER-32): the FeeDistribution flush minimum, carried from deployment.json.
check '.l2.feeDistributionFlushMinimumEnforced == true'
check '.l2.feeDistributionFlushMinimum == "10000000000000000000"'

# I1: the output file must be world-readable (0644) — mktemp's default 0600
# would otherwise survive the mv and break the EC2 scp pull.
PM_MODE=$(stat -c '%a' "$OUT/pm.json" 2>/dev/null || stat -f '%Lp' "$OUT/pm.json")
[ "$PM_MODE" = "644" ] || { echo "FAIL: output mode is $PM_MODE, expected 644"; exit 1; }

# Keep this good manifest for the chain-view validator call at the very end.
# Every sub-test below that expects a refusal writes to a SEPARATE path
# ($REFUSED): I3 makes a fresh run `rm -f` its own $PM_OUT before regenerating,
# so reusing $OUT/pm.json for an expected-refusal run would delete the very
# file the final validator check reads.
GOOD="$OUT/pm.json"
REFUSED="$OUT/refused.json"

if run PM_OUT="$REFUSED" PM_PUBLIC_L1_RPC=https://eth-mainnet.g.alchemy.com/v2/AbCdEfGhIjKlMnOpQrStU >/dev/null 2>"$OUT/err"; then
  echo "FAIL: keyed RPC accepted"; exit 1
fi
grep -q 'carries credentials' "$OUT/err" || { echo "FAIL: wrong refusal message"; cat "$OUT/err"; exit 1; }
[ -f "$REFUSED" ] && { echo "FAIL: a refused run left an output file"; exit 1; }

if run PM_OUT="$REFUSED" PM_PUBLIC_L1_RPC=https://x.quiknode.pro/0123456789abcdef0123456789abcdef/ >/dev/null 2>"$OUT/err-quicknode"; then
  echo "FAIL: QuickNode-style keyed RPC accepted"; exit 1
fi
grep -q 'carries credentials' "$OUT/err-quicknode" || { echo "FAIL: wrong refusal message (quicknode)"; cat "$OUT/err-quicknode"; exit 1; }

if run PM_OUT="$REFUSED" PM_PUBLIC_AZTEC_NODE='https://example.drpc.org/rpc?dkey=abc' >/dev/null 2>"$OUT/err-drpc"; then
  echo "FAIL: dRPC-style keyed RPC (query param) accepted"; exit 1
fi
grep -q 'carries credentials' "$OUT/err-drpc" || { echo "FAIL: wrong refusal message (drpc)"; cat "$OUT/err-drpc"; exit 1; }

# M1 + M3: key-name refusal, injected via PM_EXPECTED_FILE (an apiKey-named
# key). The injected key's value is itself an object, not a leaf scalar — only
# a check that walks every key at every depth (M3) catches it.
if run PM_OUT="$REFUSED" PM_EXPECTED_FILE="$FX/expected-with-secret.json" >/dev/null 2>"$OUT/err-secret-key"; then
  echo "FAIL: a secret-looking key name was accepted"; exit 1
fi
grep -q 'secret-looking key name' "$OUT/err-secret-key" || { echo "FAIL: wrong refusal message (secret key)"; cat "$OUT/err-secret-key"; exit 1; }
[ -f "$REFUSED" ] && { echo "FAIL: a refused run (secret key) left an output file"; exit 1; }

# M1: a missing required env var stops the script (run() always sets
# PM_CHAIN_ID, so this invokes the generator directly without it).
if env PM_ENV_ID=sandbox-local PM_KIND=sandbox PM_LABEL="Sandbox (local)" \
     PM_L1_DIR="$FX/v1-l1" PM_L2_DIR="$FX/v1-l2" PM_OUT="$REFUSED" \
     PM_PUBLIC_L1_RPC=http://localhost:8545 PM_PUBLIC_AZTEC_NODE=http://localhost:8080 \
     bash "$GEN" >/dev/null 2>"$OUT/err-missing-var"; then
  echo "FAIL: missing PM_CHAIN_ID was accepted"; exit 1
fi
grep -q 'PM_CHAIN_ID is required' "$OUT/err-missing-var" || { echo "FAIL: wrong message for missing env var"; cat "$OUT/err-missing-var"; exit 1; }
[ -f "$REFUSED" ] && { echo "FAIL: a refused run (missing env var) left an output file"; exit 1; }

# M1: a missing input file stops the script.
MISSING_FX=$(mktemp -d)
cp -r "$FX/v1-l1" "$MISSING_FX/v1-l1"
cp -r "$FX/v1-l2" "$MISSING_FX/v1-l2"
rm -f "$MISSING_FX/v1-l1/deployments/tokens.json"
if run PM_OUT="$REFUSED" PM_L1_DIR="$MISSING_FX/v1-l1" PM_L2_DIR="$MISSING_FX/v1-l2" >/dev/null 2>"$OUT/err-missing-file"; then
  echo "FAIL: a missing input file was accepted"; exit 1
fi
grep -q 'missing' "$OUT/err-missing-file" || { echo "FAIL: wrong message for missing input file"; cat "$OUT/err-missing-file"; exit 1; }
[ -f "$REFUSED" ] && { echo "FAIL: a refused run (missing input file) left an output file"; exit 1; }
rm -rf "$MISSING_FX"

# ZER-178: a deployment.json written by a v1-l2 that predates ZER-32 has neither
# flush-minimum field. The manifest must still be written, with both as null
# (unknown), never as a fabricated false / "0".
PRE_FX=$(mktemp -d)
cp -r "$FX/v1-l1" "$PRE_FX/v1-l1"
mkdir -p "$PRE_FX/v1-l2"
jq 'del(.feeDistributionFlushMinimumEnforced, .feeDistributionFlushMinimum)' \
  "$FX/v1-l2/deployment.json" > "$PRE_FX/v1-l2/deployment.json"
PRE_OUT="$OUT/pre-zer32.json"
run PM_OUT="$PRE_OUT" PM_L1_DIR="$PRE_FX/v1-l1" PM_L2_DIR="$PRE_FX/v1-l2" >/dev/null \
  || { echo "FAIL: a pre-ZER-32 deployment.json was refused"; exit 1; }
jq -e '.l2 | has("feeDistributionFlushMinimumEnforced") and has("feeDistributionFlushMinimum")
       and .feeDistributionFlushMinimumEnforced == null and .feeDistributionFlushMinimum == null' \
  "$PRE_OUT" >/dev/null || { echo "FAIL: pre-ZER-32 flush-minimum fields are not null"; jq '.l2' "$PRE_OUT"; exit 1; }
# An explicit false is carried as false, not collapsed to null by a `//` default.
jq '.feeDistributionFlushMinimumEnforced = false | .feeDistributionFlushMinimum = "1000"' \
  "$FX/v1-l2/deployment.json" > "$PRE_FX/v1-l2/deployment.json"
run PM_OUT="$PRE_OUT" PM_L1_DIR="$PRE_FX/v1-l1" PM_L2_DIR="$PRE_FX/v1-l2" >/dev/null \
  || { echo "FAIL: an unenforced deployment.json was refused"; exit 1; }
jq -e '.l2.feeDistributionFlushMinimumEnforced == false and .l2.feeDistributionFlushMinimum == "1000"' \
  "$PRE_OUT" >/dev/null || { echo "FAIL: an explicit false/1000 was not carried verbatim"; jq '.l2' "$PRE_OUT"; exit 1; }
rm -rf "$PRE_FX"

# M1: a non-hex PM_SOURCES_JSON source is refused.
if run PM_OUT="$REFUSED" PM_SOURCES_JSON='{"v1-l1":"not-hex!!","v1-l2":"0000002","deployments":"0000003"}' >/dev/null 2>"$OUT/err-bad-sha"; then
  echo "FAIL: a non-hex source sha was accepted"; exit 1
fi
grep -q 'not a valid git sha' "$OUT/err-bad-sha" || { echo "FAIL: wrong message for non-hex source"; cat "$OUT/err-bad-sha"; exit 1; }
[ -f "$REFUSED" ] && { echo "FAIL: a refused run (bad sha) left an output file"; exit 1; }

# M1: --check-url mode runs only the credentialed-URL check, and never prints
# the URL either way.
KEYED_URL='https://eth-mainnet.g.alchemy.com/v2/AbCdEfGhIjKlMnOpQrStU'
if bash "$GEN" --check-url "$KEYED_URL" >"$OUT/check-url-out" 2>"$OUT/check-url-err"; then
  echo "FAIL: --check-url accepted a keyed URL"; exit 1
fi
grep -q 'carries credentials' "$OUT/check-url-err" || { echo "FAIL: --check-url wrong message"; cat "$OUT/check-url-err"; exit 1; }
if grep -q 'AbCdEfGhIjKlMnOpQrStU' "$OUT/check-url-out" "$OUT/check-url-err"; then
  echo "FAIL: --check-url printed the URL"; exit 1
fi
bash "$GEN" --check-url 'https://ethereum-rpc.publicnode.com' >/dev/null || { echo "FAIL: --check-url refused a clean URL"; exit 1; }

CV="$HERE/../../../chain-view"
if [ -d "$CV/node_modules" ]; then
  npm --prefix "$CV" run -s validate-manifest -- "$GOOD"
else
  echo "SKIPPED chain-view validation (chain-view/node_modules absent)"
fi
echo "public-manifest tests: ok"
