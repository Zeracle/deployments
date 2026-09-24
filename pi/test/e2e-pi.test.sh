#!/usr/bin/env bash
# deployments/pi/test/e2e-pi.test.sh
# ZER-17: pi/e2e-pi.sh's pure parts, offline — no Pi, no chain, no ssh.
#
# What this pins:
#   - manifests_agree: every address the suite reads (v1-l2/deployment.json,
#     v1-l1/deployments/{bridge,local}.json) must equal the Pi manifest's
#     (ZER-75: a synced laptop copy once described another chain),
#     compared case-insensitively.
#   - rpc_classify: a dead node or an error response is never read as
#     "contract absent" (L2 reset) or as "has code".
#   - run_suite: the strict switch is always on, and a lenient
#     ZERACLE_E2E_ALLOW_UNCOLLATERALISED=1 left exported in the caller's shell
#     cannot reach the suite. Either regression turns a green run back into
#     "maybe it ran" — the thing ZER-74 and this ticket exist to prevent.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../e2e-pi.sh"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT does not exist"; exit 1; }
# Sourcing must not run main: it would touch systemctl and the chain.
# shellcheck source=/dev/null
. "$SCRIPT"
set +e  # the script sets -e; assertions below inspect non-zero statuses
# Defined AFTER sourcing: the script has its own ok()/fail() and would shadow them.
pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FD_MIXED="0x1A3d7fffC402f41d9716c20f0302924e5fa572a356a577b905ff01973ab4ac44"
FD_LOWER="0x1a3d7fffc402f41d9716c20f0302924e5fa572a356a577b905ff01973ab4ac44"
FD_OTHER="0x0b7a43d2bf27ce641c0984632ce5f085e5c5a84efcdbdf815ac9f1ba43c5d07a"
PORTAL="0x1D1aEE6D5dC35F3c15E2D11083D0e59C026b64c4"
POOL="0x0b48aF34f4c854F5ae1A3D587da471FeA45bAD52"
OTHER_L1="0xAbC0000000000000000000000000000000000dEf"
# A consistent set, as deploy-pi.sh leaves it; each case then breaks one file.
fixtures() {
  echo "{\"contracts\":{\"feeDistribution\":\"$FD_MIXED\"},\"l1\":{\"tokenPortal\":\"$PORTAL\"}}" > "$TMP/v1l2.json"
  echo "{\"tokenPortal\":\"$PORTAL\"}" > "$TMP/bridge.json"
  echo "{\"liquidityPoolProxy\":\"$POOL\"}" > "$TMP/local.json"
  echo "{\"l2\":{\"contracts\":{\"feeDistribution\":\"$FD_LOWER\"}},\"l1\":{\"contracts\":{\"tokenPortal\":\"$PORTAL\",\"liquidityPoolProxy\":\"$POOL\"}}}" > "$TMP/manifest.json"
}
agree() { manifests_agree "$TMP/v1l2.json" "$TMP/bridge.json" "$TMP/local.json" "$TMP/manifest.json"; }

echo "TEST: json_addr lowercases and returns empty for a missing path"
fixtures
check "lowercased"         "$(json_addr "$TMP/v1l2.json" '.contracts.feeDistribution')" "$FD_LOWER"
check "missing path empty" "$(json_addr "$TMP/v1l2.json" '.contracts.nope')" ""

echo "TEST: manifests_agree"
fixtures; agree >/dev/null
check "consistent set (mixed case) -> agree" "$?" "0"

fixtures; echo "{\"l2\":{\"contracts\":{\"feeDistribution\":\"$FD_OTHER\"}},\"l1\":{\"contracts\":{\"tokenPortal\":\"$PORTAL\",\"liquidityPoolProxy\":\"$POOL\"}}}" > "$TMP/manifest.json"
out=$(agree); st=$?
check "L2 FeeDistribution differs -> disagree" "$st" "1"
check "reason names both addresses" "$(echo "$out" | grep -c "$FD_LOWER.*$FD_OTHER")" "1"

# ZER-75 / review I4: a sync can overwrite the v1-l1 manifests the suite reads.
fixtures; echo "{\"tokenPortal\":\"$OTHER_L1\"}" > "$TMP/bridge.json"
out=$(agree); st=$?
check "bridge.json portal differs -> disagree" "$st" "1"
check "reason names bridge.json" "$(echo "$out" | grep -c 'bridge.json')" "1"

fixtures; echo "{\"liquidityPoolProxy\":\"$OTHER_L1\"}" > "$TMP/local.json"
agree >/dev/null; check "local.json pool differs -> disagree" "$?" "1"

fixtures; echo "{\"contracts\":{\"feeDistribution\":\"$FD_MIXED\"},\"l1\":{\"tokenPortal\":\"$OTHER_L1\"}}" > "$TMP/v1l2.json"
agree >/dev/null; check "deployment.json portal differs -> disagree" "$?" "1"

fixtures; echo '{"l2":{"contracts":{}}}' > "$TMP/manifest.json"
out=$(agree); st=$?
check "manifest without feeDistribution -> disagree" "$st" "1"
check "reason names the manifest field" "$(echo "$out" | grep -c 'l2.contracts.feeDistribution')" "1"

fixtures; echo '{}' > "$TMP/v1l2.json"
agree >/dev/null; check "deployment.json without feeDistribution -> disagree" "$?" "1"

# Review I1/I2: a dead node, an error response and an absent contract all have
# a null .result or none at all; only the last one means "L2 reset".
echo "TEST: rpc_classify tells unreachable, error, absent and present apart"
check "empty (curl failed) -> unreachable" "$(printf '' | rpc_classify)" "unreachable"
check "non-JSON -> unreachable"           "$(echo '<html>502</html>' | rpc_classify)" "unreachable"
check "error member -> error"             "$(echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}' | rpc_classify | cut -d' ' -f1)" "error"
check "error keeps the message"           "$(echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}' | rpc_classify | grep -c '"message":"no"')" "1"
check "result null -> null (absent)"      "$(echo '{"jsonrpc":"2.0","id":1,"result":null}' | rpc_classify)" "null"
check "empty code -> ok 0x"               "$(echo '{"jsonrpc":"2.0","id":1,"result":"0x"}' | rpc_classify)" "ok 0x"
check "real result -> ok"                 "$(echo '{"jsonrpc":"2.0","id":1,"result":"0x6080"}' | rpc_classify)" "ok 0x6080"

echo "TEST: run_suite always runs strict, never lenient"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/yarn" <<'EOF'
#!/usr/bin/env bash
echo "REQUIRE=${ZERACLE_E2E_REQUIRE_SANDBOX-unset} ALLOW=${ZERACLE_E2E_ALLOW_UNCOLLATERALISED-unset} ARGS=$*"
EOF
chmod +x "$TMP/bin/yarn"
got=$(PATH="$TMP/bin:$PATH" ZERACLE_E2E_ALLOW_UNCOLLATERALISED=1 ZERACLE_E2E_REQUIRE_SANDBOX=0 run_suite)
check "REQUIRE forced to 1 over a caller's 0"  "$(echo "$got" | grep -o 'REQUIRE=[^ ]*')" "REQUIRE=1"
check "a caller's ALLOW=1 does not leak"       "$(echo "$got" | grep -o 'ALLOW=[^ ]*')" "ALLOW=unset"
check "scoped to the flush-claim suite"        "$(echo "$got" | grep -c 'test:e2e --testPathPattern flush-claim')" "1"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
