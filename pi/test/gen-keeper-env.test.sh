#!/usr/bin/env bash
# deployments/pi/test/gen-keeper-env.test.sh
# ZER-16: pi/gen-keeper-env.sh, offline — no Pi, no chain, no root.
#
# What this pins:
#   - ZRCL_ADDRESS comes from the manifest's .l2.contracts.zeracleToken. A
#     missing or malformed one fails loud and writes nothing: a keeper without
#     it silently sweeps and flushes FIXTURE data.
#   - A failed run leaves an existing env file untouched (the next timer run
#     keeps working against the last good chain rather than an empty file).
#   - The file is 0600 and the key is never echoed to stdout/stderr.
#   - The Pi's measured overrides (claim wait, 30-day expiry) are written.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../gen-keeper-env.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT does not exist"; exit 1; }

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ZRCL="0x2d0ba80fa798bd69578d0bf9173dcb45aaafd958d968387b603dea22e5f538f1"
KEY="47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
FD="0x0cdfe6b256d77e2125da0be82f9b6d141e8fa6137277f0e251ac42a89182bb7d"
POOL="0x0b48aF34f4c854F5ae1A3D587da471FeA45bAD52"
PORTAL="0x1D1aEE6D5dC35F3c15E2D11083D0e59C026b64c4"
DEX="0xAbC0000000000000000000000000000000000dEf"
TREAS="0x381445710b5e73d34af196c53a3d5cda58edbf7a"
RESV="0xe6b98f104c1bef218f3893adab4160dc73eb8367"
NETF="0x5c7c905b505f0cf40ab6600d05e677f717916f6b"
L1_GOOD="{\"tokenPortal\":\"$PORTAL\",\"liquidityPoolProxy\":\"$POOL\",\"mockDexAggregator\":\"$DEX\",\"treasury\":\"$TREAS\",\"collateralReserve\":\"$RESV\",\"networkFund\":\"$NETF\"}"
# manifest <l2 contracts json> [l1 contracts json]
manifest() {
  echo "{\"generatedAt\":\"2026-09-25T00:00:00Z\",\"l2\":{\"contracts\":$1},\"l1\":{\"contracts\":${2:-$L1_GOOD}}}" > "$TMP/m.json"
}
L2_GOOD() { echo "{\"zeracleToken\":\"$ZRCL\",\"feeDistribution\":\"$FD\"}"; }
envval() { sed -n "s/^$1=//p" "$TMP/keeper.env"; }

echo "# a good manifest"
manifest "$(L2_GOOD)"
st=0; out=$(REPO=/opt/zeracle bash "$SCRIPT" "$TMP/m.json" "$TMP/keeper.env" 2>&1) || st=$?
check "exits 0" "$st" 0
check "ZRCL_ADDRESS from the manifest" "$(envval ZRCL_ADDRESS)" "$ZRCL"
check "keeper key is anvil #4" "$(envval KEEPER_L1_PRIVATE_KEY)" "0x$KEY"
check "V1_L2_DIR under REPO" "$(envval V1_L2_DIR)" "/opt/zeracle/v1-l2"
check "state dir matches the unit's StateDirectory=" "$(envval KEEPER_STATE_DIR)" "/var/lib/zeracle-keeper"
check "claim wait override" "$(envval KEEPER_CLAIM_WAIT_SECS)" "1800"
check "30-day pending expiry" "$(envval PENDING_FLUSH_MAX_AGE_SECS)" "2592000"
echo "# every address the keeper uses is pinned from the manifest, not the synced repo files"
check "FEE_DISTRIBUTION_ADDRESS" "$(envval FEE_DISTRIBUTION_ADDRESS)" "$FD"
check "L1_TOKEN_PORTAL" "$(envval L1_TOKEN_PORTAL)" "$PORTAL"
check "L1_LIQUIDITY_POOL" "$(envval L1_LIQUIDITY_POOL)" "$POOL"
check "L1_MOCK_DEX_AGGREGATOR" "$(envval L1_MOCK_DEX_AGGREGATOR)" "$DEX"
check "L1_TREASURY" "$(envval L1_TREASURY)" "$TREAS"
check "L1_COLLATERAL_RESERVE" "$(envval L1_COLLATERAL_RESERVE)" "$RESV"
check "L1_NETWORK_FUND" "$(envval L1_NETWORK_FUND)" "$NETF"
check "no blank or malformed lines" "$(grep -cvE '^(#|[A-Z0-9_]+=.+$)' "$TMP/keeper.env")" "0"
check "mode 0600" "$(stat -c %a "$TMP/keeper.env")" "600"
case "$out" in *"$KEY"*) bad "key echoed to the console" ;; *) ok "key not echoed" ;; esac
check "no temp file left behind" "$(find "$TMP" -name 'keeper.env.*' | wc -l)" "0"

echo "# bad manifests fail loud and leave the last good file alone"
cp "$TMP/keeper.env" "$TMP/good.env"
for case_ in '{}' '{"zeracleToken":null}' '{"zeracleToken":"0x1234"}' \
  "{\"zeracleToken\":\"${ZRCL}00\"}" "{\"zeracleToken\":\"${ZRCL:2}\"}"; do
  manifest "$case_"
  st=0; bash "$SCRIPT" "$TMP/m.json" "$TMP/keeper.env" >/dev/null 2>&1 || st=$?
  check "rejects $case_" "$st" 1
  if cmp -s "$TMP/keeper.env" "$TMP/good.env"; then ok "keeps the last good file ($case_)"; else bad "overwrote the env file ($case_)"; fi
done
for bad_l1 in "{\"tokenPortal\":\"$PORTAL\"}" "$(echo "$L1_GOOD" | sed "s/$POOL/0x1234/")" \
  "$(echo "$L1_GOOD" | sed "s/$TREAS/$FD/")"; do
  manifest "$(L2_GOOD)" "$bad_l1"
  st=0; bash "$SCRIPT" "$TMP/m.json" "$TMP/keeper.env" >/dev/null 2>&1 || st=$?
  check "rejects a manifest with a missing or malformed L1 address" "$st" 1
  if cmp -s "$TMP/keeper.env" "$TMP/good.env"; then ok "keeps the last good file (bad L1)"; else bad "overwrote the env file (bad L1)"; fi
done
manifest "{\"zeracleToken\":\"$ZRCL\"}"
st=0; bash "$SCRIPT" "$TMP/m.json" "$TMP/keeper.env" >/dev/null 2>&1 || st=$?
check "rejects a manifest with no L2 feeDistribution" "$st" 1
st=0; bash "$SCRIPT" "$TMP/absent.json" "$TMP/keeper.env" >/dev/null 2>&1 || st=$?
check "rejects a missing manifest" "$st" 1
if cmp -s "$TMP/keeper.env" "$TMP/good.env"; then ok "keeps the last good file (missing manifest)"; else bad "overwrote the env file (missing manifest)"; fi

echo "# a failure after the temp file exists leaves no key behind"
# A stub `mv` on PATH fails the final move, after the temp file holding the
# key has been written.
manifest "$(L2_GOOD)"
mkdir -p "$TMP/bin" "$TMP/out"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/mv"; chmod +x "$TMP/bin/mv"
st=0; PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$TMP/m.json" "$TMP/out/keeper.env" >/dev/null 2>&1 || st=$?
check "fails when the env cannot be moved into place" "$st" 1
check "no temp file (key) left behind on failure" "$(find "$TMP/out" -name 'keeper.env.*' | wc -l)" "0"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
