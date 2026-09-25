#!/usr/bin/env bash
# Run the real-Outbox fee round-trip (v1-l2 fees.flush-claim.e2e) on the Pi
# chain host, end to end, from one command (ZER-17). Runs ON the Pi — the
# sandbox tools refuse non-localhost endpoints, and tunnelling to fake that
# defeats the guard — so from the laptop use `make -C deployments e2e-pi`.
#
#   1. Chain up. No manifest, or anvil/aztec-sandbox down -> deploy-pi.sh
#      (a first-run deploy of L1 + L2 when there is no manifest, ~30-35 min;
#      otherwise resume). Only chain-server/block-producer down -> just start
#      them: deploy-pi.sh would also wipe chain-server's open wallet store.
#   2. Chain matches the manifest. The suite reads v1-l2/deployment.json and
#      v1-l1/deployments/{bridge,local}.json; chain-server and the web read the
#      manifest. All must agree, the FeeDistribution must be on the L2 node and
#      the TokenPortal must have code on anvil. The L2 resets on any
#      aztec-sandbox restart while L1 and the manifests survive
#      (pi/README.md, "Known limitation"), so an L2 reset is REPORTED, never
#      repaired here: the fix is a fresh chain, which changes every address and
#      is an owner call.
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

L2_RPC=http://127.0.0.1:8080
L1_RPC=http://127.0.0.1:8545

# Lowercased address at a jq path, or empty. Pure: tested offline.
json_addr(){ jq -r "$2 // empty" "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

# Every address the suite reads must equal the manifest's, or the suite runs
# against a chain nothing else is using (ZER-75: a synced laptop copy once
# described another chain). Prints the first disagreement; pure, tested offline.
#   $1 v1-l2/deployment.json  $2 v1-l1/deployments/bridge.json
#   $3 v1-l1/deployments/local.json  $4 the Pi manifest
manifests_agree(){
  local pair a b
  for pair in \
    "$1|.contracts.feeDistribution|.l2.contracts.feeDistribution" \
    "$1|.l1.tokenPortal|.l1.contracts.tokenPortal" \
    "$2|.tokenPortal|.l1.contracts.tokenPortal" \
    "$3|.liquidityPoolProxy|.l1.contracts.liquidityPoolProxy"; do
    IFS='|' read -r file path mpath <<<"$pair"
    a="$(json_addr "$file" "$path")"
    b="$(json_addr "$4" "$mpath")"
    [ -n "$a" ] || { echo "no $path in $file"; return 1; }
    [ -n "$b" ] || { echo "no $mpath in $4"; return 1; }
    [ "$a" = "$b" ] || { echo "$file $path is $a, but $4 $mpath is $b"; return 1; }
  done
}

# Classify a JSON-RPC response read from stdin. Prints one of:
#   unreachable | error <message> | null | ok <result>
# A curl failure leaves stdin empty; an error response has .result null too,
# so the two must be told apart before a null means "absent". Pure, tested.
rpc_classify(){
  local body; body="$(cat)"
  [ -n "$body" ] || { echo unreachable; return; }
  jq -e . >/dev/null 2>&1 <<<"$body" || { echo unreachable; return; }
  if jq -e 'has("error")' >/dev/null 2>&1 <<<"$body"; then
    echo "error $(jq -c '.error' <<<"$body")"; return
  fi
  if [ "$(jq -r '.result' <<<"$body")" = null ]; then echo null; return; fi
  echo "ok $(jq -r '.result' <<<"$body")"
}

# The exact suite invocation. Kept in one place so the offline test can assert
# the strict switch is set and the lenient one cannot leak in from the shell.
run_suite(){
  env -u ZERACLE_E2E_ALLOW_UNCOLLATERALISED ZERACLE_E2E_REQUIRE_SANDBOX=1 \
    yarn -s test:e2e --testPathPattern flush-claim
}

rpc(){ curl -fsS -m 10 -X POST -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1" 2>/dev/null || true; }

elapsed(){ echo "$(( $(date +%s) - $1 ))s"; }

# The fee keeper (ZER-16) sweeps and flushes the same fees this suite does, so a
# timer run landing mid-suite would take them from under it. Stop the timer and
# wait for any run in flight to finish (never kill it: keeper-ctl.sh), then
# restart the timer on exit — failures included — only if it was running
# before, or a deploy this run made succeeded.
# shellcheck source=keeper-ctl.sh disable=SC1091
. "$SCRIPT_DIR/keeper-ctl.sh"
KEEPER_WAS_ACTIVE=""
keeper_pause(){
  keeper_installed || return 0
  systemctl is-active --quiet zeracle-keeper.timer && KEEPER_WAS_ACTIVE=1
  keeper_quiesce || fail "a keeper run is still in flight; rerun once it finishes"
  ok "keeper paused for the suite"
}
keeper_resume(){
  [ -n "$KEEPER_WAS_ACTIVE" ] || return 0
  keeper_installed || return 0
  sudo systemctl start zeracle-keeper.timer || echo "  ! could not restart zeracle-keeper.timer"
}

# Timings print on every exit, failures included: a slow failure is still a
# measured duration.
TIMINGS=""; T0=""
print_timings(){ [ -z "$T0" ] || echo -e "\nTimings:${TIMINGS:- (none)} total=$(elapsed "$T0")"; }

main(){
  # shellcheck source=pi.env disable=SC1091
  . "$SCRIPT_DIR/pi.env"
  local V1L2="$REPO/v1-l2" V1L1="$REPO/v1-l1" MANIFEST="$DATA_MOUNT/deployment-manifest.json"
  local t s
  T0=$(date +%s); trap 'keeper_resume; print_timings' EXIT
  keeper_pause

  step "1/4 Chain up"
  t=$(date +%s)
  local core_down="" app_down=""
  for s in anvil aztec-sandbox; do systemctl is-active --quiet "$s" || core_down="$core_down $s"; done
  for s in chain-server block-producer; do systemctl is-active --quiet "$s" || app_down="$app_down $s"; done
  if [ ! -f "$MANIFEST" ] || [ -n "$core_down" ]; then
    echo "  manifest $([ -f "$MANIFEST" ] && echo present || echo absent)${core_down:+; inactive:$core_down} -> deploy-pi.sh"
    # Not restarted against a chain whose deploy failed: cleared until it succeeds.
    KEEPER_WAS_ACTIVE=""
    ZERACLE_KEEPER_HOLD=1 bash "$SCRIPT_DIR/deploy-pi.sh"
    # deploy-pi.sh would have started the timer (if enabled); keeper_resume
    # does it instead, under the same enabled check.
    systemctl is-enabled --quiet zeracle-keeper.timer && KEEPER_WAS_ACTIVE=1
  elif [ -n "$app_down" ]; then
    echo "  inactive:$app_down -> starting them (chain untouched)"
    # shellcheck disable=SC2086  # word-splitting the unit list is intended
    sudo systemctl start $app_down
  else
    ok "all services active, manifest present — no deploy"
  fi
  # deploy-pi.sh's resume branch starts aztec-sandbox without waiting for it.
  timeout 300 bash -c "until curl -fsS -m 5 $L2_RPC/status >/dev/null 2>&1; do sleep 5; done" \
    || fail "the L2 node at $L2_RPC never answered /status (journalctl -u aztec-sandbox)"
  ok "L2 node answering"
  TIMINGS="$TIMINGS chain-up=$(elapsed "$t")"

  step "2/4 Chain matches the manifest"
  t=$(date +%s)
  local f why
  for f in "$V1L2/deployment.json" "$V1L1/deployments/bridge.json" "$V1L1/deployments/local.json" "$MANIFEST"; do
    [ -f "$f" ] || fail "$f is missing — deploy-pi.sh did not produce it"
  done
  why="$(manifests_agree "$V1L2/deployment.json" "$V1L1/deployments/bridge.json" \
    "$V1L1/deployments/local.json" "$MANIFEST")" || fail "manifests disagree: $why"
  ok "deployment.json, bridge.json and local.json agree with the manifest"

  local fd portal verdict
  fd="$(json_addr "$V1L2/deployment.json" '.contracts.feeDistribution')"
  portal="$(json_addr "$V1L2/deployment.json" '.l1.tokenPortal')"
  verdict="$(rpc "$L2_RPC" node_getContract "[\"$fd\"]" | rpc_classify)"
  case "$verdict" in
    ok*) ok "L2 FeeDistribution $fd present on the node" ;;
    null) fail "FeeDistribution $fd is not on the L2 node: the L2 chain has reset under its manifest.
    Recovery is a fresh chain, which changes every address — see deployments/pi/README.md
    (\"Known limitation\" and \"Force a fresh chain\"). Not done automatically." ;;
    unreachable) fail "the L2 node at $L2_RPC did not answer node_getContract" ;;
    *) fail "node_getContract($fd) returned an error: ${verdict#error }" ;;
  esac
  verdict="$(rpc "$L1_RPC" eth_getCode "[\"$portal\",\"latest\"]" | rpc_classify)"
  case "$verdict" in
    "ok 0x") fail "TokenPortal $portal has no code on anvil: L1 does not match the manifest" ;;
    ok\ 0x[0-9a-fA-F]*) ok "L1 TokenPortal $portal has code" ;;
    unreachable) fail "anvil at $L1_RPC did not answer eth_getCode" ;;
    *) fail "eth_getCode($portal) returned: $verdict" ;;
  esac
  TIMINGS="$TIMINGS verify=$(elapsed "$t")"

  # The deployer key the suite signs L1 claims with. deploy-sandbox.sh writes
  # it (anvil's public dev key) to v1-l1/.env.local on every deploy.
  [ -f "$V1L1/.env.local" ] || fail "$V1L1/.env.local is missing — deploy-pi.sh writes it"
  set -a +u
  # shellcheck disable=SC1091
  . "$V1L1/.env.local"
  set +a -u
  [ -n "${L1_DEPLOYER_PRIVATE_KEY:-${DEPLOYER_PRIVATE_KEY:-}}" ] \
    || fail "no DEPLOYER_PRIVATE_KEY in $V1L1/.env.local"

  cd "$V1L2"
  step "3/4 Portal collateralised"
  t=$(date +%s)
  NODE_NO_WARNINGS=1 PROVER_ENABLED=false npx tsx scripts/bridge-deposit.ts --if-needed \
    || fail "bridge-deposit.ts --if-needed failed"
  TIMINGS="$TIMINGS collateral=$(elapsed "$t")"

  step "4/4 fees.flush-claim (ZERACLE_E2E_REQUIRE_SANDBOX=1)"
  t=$(date +%s)
  local status=0
  run_suite || status=$?
  TIMINGS="$TIMINGS suite=$(elapsed "$t")"
  [ "$status" -eq 0 ] || fail "fees.flush-claim failed (exit $status)"
  ok "fees.flush-claim ran and passed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
