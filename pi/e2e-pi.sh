#!/usr/bin/env bash
# Run the real-Outbox fee round-trip (v1-l2 fees.flush-claim.e2e) on the Pi
# chain host, end to end, from one command (ZER-17). Runs ON the Pi — the
# sandbox tools refuse non-localhost endpoints, and tunnelling to fake that
# defeats the guard — so from the laptop use `make -C deployments e2e-pi`.
#
#   1. Chain up. Services down or no manifest -> deploy-pi.sh (resume, or a
#      first-run deploy of L1 + L2 when there is no manifest; ~35 min).
#   2. Chain matches the manifest. The L2 resets on any aztec-sandbox restart
#      while L1 and the manifest survive (pi/README.md, "Known limitation"), so
#      a green L1 and a present manifest prove nothing. A reset is REPORTED,
#      never repaired here: the fix is a fresh chain, which changes every
#      address and is an owner call.
#   3. Portal collateralised: bridge-deposit.ts --if-needed deposits only when
#      the portal is short of the shares the suite consumes.
#   4. The suite, with ZERACLE_E2E_REQUIRE_SANDBOX=1: an unmet precondition
#      FAILS instead of skipping, so a green run means the round-trip ran.
#
# Tests run whatever code is on the box: `make -C deployments sync-pi` first to
# test a branch. Syncing v1-l2 contract changes does not redeploy them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "\n${BLUE}==>${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
fail(){ echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

SERVICES="anvil aztec-sandbox chain-server block-producer"

# Lowercased address at a jq path, or empty. Pure: tested offline.
json_addr(){ jq -r "$2 // empty" "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

# The suite reads v1-l2/deployment.json; chain-server and the web read the
# manifest. They must describe the same FeeDistribution, or the suite passes
# against a chain nothing else is using (ZER-75). Prints the reason on mismatch.
manifests_agree(){
  local v1l2="$1" manifest="$2" a b
  a="$(json_addr "$v1l2" '.contracts.feeDistribution')"
  b="$(json_addr "$manifest" '.l2.contracts.feeDistribution')"
  [ -n "$a" ] || { echo "no .contracts.feeDistribution in $v1l2"; return 1; }
  [ -n "$b" ] || { echo "no .l2.contracts.feeDistribution in $manifest"; return 1; }
  [ "$a" = "$b" ] || { echo "FeeDistribution differs: $v1l2 has $a, $manifest has $b"; return 1; }
}

# The exact suite invocation. Kept in one place so the offline test can assert
# the strict switch is set and the lenient one cannot leak in from the shell.
run_suite(){
  env -u ZERACLE_E2E_ALLOW_UNCOLLATERALISED ZERACLE_E2E_REQUIRE_SANDBOX=1 \
    yarn -s test:e2e --testPathPattern flush-claim
}

rpc(){ curl -fsS -m 10 -X POST -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1"; }

elapsed(){ echo "$(( $(date +%s) - $1 ))s"; }

main(){
  # shellcheck source=pi.env disable=SC1091
  . "$SCRIPT_DIR/pi.env"
  local V1L2="$REPO/v1-l2" MANIFEST="$DATA_MOUNT/deployment-manifest.json"
  local t0 t; t0=$(date +%s)
  local timings=""

  step "1/4 Chain up"
  t=$(date +%s)
  local down=""
  for s in $SERVICES; do systemctl is-active --quiet "$s" || down="$down $s"; done
  if [ ! -f "$MANIFEST" ] || [ -n "$down" ]; then
    echo "  ${down:+inactive:$down; }${MANIFEST} $([ -f "$MANIFEST" ] && echo present || echo absent) -> deploy-pi.sh"
    bash "$SCRIPT_DIR/deploy-pi.sh"
  else
    ok "all services active, manifest present — no deploy"
  fi
  timings="$timings chain-up=$(elapsed "$t")"

  step "2/4 Chain matches the manifest"
  t=$(date +%s)
  [ -f "$V1L2/deployment.json" ] || fail "$V1L2/deployment.json is missing — deploy-pi.sh did not produce it"
  local why
  why="$(manifests_agree "$V1L2/deployment.json" "$MANIFEST")" || fail "$why"
  local fd portal
  fd="$(json_addr "$V1L2/deployment.json" '.contracts.feeDistribution')"
  portal="$(json_addr "$V1L2/deployment.json" '.l1.tokenPortal')"
  [ -n "$portal" ] || fail "no .l1.tokenPortal in $V1L2/deployment.json"
  if [ "$(rpc http://127.0.0.1:8080 node_getContract "[\"$fd\"]" | jq -r '.result')" = "null" ]; then
    fail "FeeDistribution $fd is not on the L2 node: the L2 chain has reset under its manifest.
    Recovery is a fresh chain, which changes every address — see deployments/pi/README.md
    (\"Known limitation\" and \"Force a fresh chain\"). Not done automatically."
  fi
  ok "L2 FeeDistribution $fd present on the node"
  local code
  code="$(rpc http://127.0.0.1:8545 eth_getCode "[\"$portal\",\"latest\"]" | jq -r '.result')"
  [ -n "$code" ] && [ "$code" != "0x" ] || fail "TokenPortal $portal has no code on anvil: L1 does not match the manifest"
  ok "L1 TokenPortal $portal has code"
  timings="$timings verify=$(elapsed "$t")"

  # The deployer key the suite signs L1 claims with. deploy-sandbox.sh writes
  # it (anvil's public dev key) to v1-l1/.env.local on every deploy.
  set -a
  # shellcheck disable=SC1091
  . "$REPO/v1-l1/.env.local"
  set +a
  [ -n "${L1_DEPLOYER_PRIVATE_KEY:-${DEPLOYER_PRIVATE_KEY:-}}" ] \
    || fail "no DEPLOYER_PRIVATE_KEY in $REPO/v1-l1/.env.local"

  cd "$V1L2"
  step "3/4 Portal collateralised"
  t=$(date +%s)
  NODE_NO_WARNINGS=1 PROVER_ENABLED=false npx tsx scripts/bridge-deposit.ts --if-needed \
    || fail "bridge-deposit.ts --if-needed failed"
  timings="$timings collateral=$(elapsed "$t")"

  step "4/4 fees.flush-claim (ZERACLE_E2E_REQUIRE_SANDBOX=1)"
  t=$(date +%s)
  local status=0
  run_suite || status=$?
  timings="$timings suite=$(elapsed "$t")"

  echo -e "\nTimings:$timings total=$(elapsed "$t0")"
  [ "$status" -eq 0 ] || fail "fees.flush-claim failed (exit $status)"
  ok "fees.flush-claim ran and passed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
