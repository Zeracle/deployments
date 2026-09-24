#!/usr/bin/env bash
# deployments/pi/test/e2e-pi.test.sh
# ZER-17: pi/e2e-pi.sh's pure parts, offline — no Pi, no chain, no ssh.
#
# What this pins:
#   - manifests_agree: the suite's v1-l2/deployment.json and the Pi manifest
#     must name the same FeeDistribution (ZER-75: a synced laptop copy once
#     described another chain), compared case-insensitively.
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
v1l2() { echo "{\"contracts\":{\"feeDistribution\":\"$1\"},\"l1\":{\"tokenPortal\":\"0xAbC0000000000000000000000000000000000dEf\"}}" > "$TMP/v1l2.json"; }
manifest() { echo "{\"l2\":{\"contracts\":{\"feeDistribution\":\"$1\"}}}" > "$TMP/manifest.json"; }

echo "TEST: sourcing the script does not run main"
check "main is defined but did not run" "$(type -t main)" "function"

echo "TEST: json_addr lowercases and returns empty for a missing path"
v1l2 "$FD_MIXED"
check "lowercased"         "$(json_addr "$TMP/v1l2.json" '.contracts.feeDistribution')" "$FD_LOWER"
check "portal lowercased"  "$(json_addr "$TMP/v1l2.json" '.l1.tokenPortal')" "0xabc0000000000000000000000000000000000def"
check "missing path empty" "$(json_addr "$TMP/v1l2.json" '.contracts.nope')" ""

echo "TEST: manifests_agree"
v1l2 "$FD_MIXED"; manifest "$FD_LOWER"
manifests_agree "$TMP/v1l2.json" "$TMP/manifest.json" >/dev/null
check "same address, different case -> agree" "$?" "0"

manifest "$FD_OTHER"
out=$(manifests_agree "$TMP/v1l2.json" "$TMP/manifest.json"); st=$?
check "different address -> disagree" "$st" "1"
check "reason names both addresses" "$(echo "$out" | grep -c "$FD_LOWER.*$FD_OTHER")" "1"

echo '{"l2":{"contracts":{}}}' > "$TMP/manifest.json"
out=$(manifests_agree "$TMP/v1l2.json" "$TMP/manifest.json"); st=$?
check "manifest without feeDistribution -> disagree" "$st" "1"
check "reason names the manifest field" "$(echo "$out" | grep -c 'l2.contracts.feeDistribution')" "1"

echo '{}' > "$TMP/v1l2.json"; manifest "$FD_LOWER"
manifests_agree "$TMP/v1l2.json" "$TMP/manifest.json" >/dev/null; st=$?
check "deployment.json without feeDistribution -> disagree" "$st" "1"

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
