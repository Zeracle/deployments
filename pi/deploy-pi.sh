#!/usr/bin/env bash
# Orchestrates deploy-once/resume for the Pi chain host, mirroring bootstrap.sh
# §6 (deploy-once/resume); kept in sync manually — see
# devops/production/ec2/files/ops/bootstrap.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pi.env disable=SC1091
. "$SCRIPT_DIR/pi.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "\n${BLUE}==>${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
fail(){ echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

step "Preflight"
[ -d "$REPO/deployments/sandbox-local" ] || fail "repo not staged at $REPO (run sync-to-pi.sh)"
for b in docker anvil forge node yarn jq; do command -v "$b" >/dev/null || fail "$b missing — run provision-pi.sh"; done
ok "tools present"
step "JS deps (node_modules excluded from sync)"
( cd "$REPO/v1-l2" && yarn install --frozen-lockfile ) || fail "v1-l2 yarn install failed"
( cd "$REPO/chain-server" && yarn install --frozen-lockfile ) || fail "chain-server yarn install failed"
ok "deps installed"

# The embedded wallet's LMDB stores must be owned by the service user. The `pi.conf`
# drop-ins set `User=admin` precisely so new artefacts land admin-owned, but a store
# created before those landed — or by anything run under sudo — stays root-owned, and
# deploy-sandbox.sh runs unprivileged and cannot remove it. chain-server then crash-loops
# on `mdb_env_open: 13 - Permission denied`, and block-producer's
# `Requires=chain-server.service` restarts it on every cycle, so the L2 chain stops
# advancing while every service still reports active.
#
# This is the platform layer, and it has sudo, so clear them here before the deploy sees
# them. deploy-sandbox.sh now also ASSERTS its own wipe, so if one reappears the deploy
# stops there instead of shipping a chain whose L2 never moves.
# rpc-proxy carries `Requires=anvil.service`, which propagates a STOP but never a start:
# stopping anvil (which every redeploy does) takes the proxy down with it, and starting
# anvil does not bring it back. Nothing else references it, so it stays dead and the
# public /anvil path answers 502 — the chain is fine, the frontend just cannot reach it.
# Started explicitly here, in both the first-run and resume branches, so a redeploy always
# restores public access.
_start_rpc_proxy() {
  if systemctl list-unit-files rpc-proxy.service >/dev/null 2>&1; then
    sudo systemctl start rpc-proxy || echo "  ! rpc-proxy failed to start — the public /anvil path will 502"
    systemctl is-active --quiet rpc-proxy && ok "rpc-proxy running (public /anvil)"
  fi
}

# The fee keeper (ZER-16) must not run mid-deploy: its sweep and flush would hit
# a chain that is half-deployed or about to be replaced. Stop the timer and any
# run in flight. Killing a run is safe: run-keeper.sh records a flush in
# pending-flush BEFORE relaying it, and a replayed claim is detected as already
# consumed. The timer is started again at the end, once keeper.env is current.
KEEPER_STATE="/var/lib/zeracle-keeper"
_keeper_installed() { systemctl list-unit-files zeracle-keeper.timer >/dev/null 2>&1; }
if _keeper_installed; then
  sudo systemctl stop zeracle-keeper.timer zeracle-keeper.service 2>/dev/null || true
  ok "keeper paused for the deploy"
fi

step "Clearing stale embedded-wallet LMDB stores"
for stale in "$REPO/chain-server/aztec-wallet-data" "$REPO/v1-l2/aztec-wallet-data"; do
  if [ -e "$stale" ]; then
    sudo rm -rf "$stale" && echo "  removed $stale"
  fi
done
ok "no stale wallet stores"

step "Bring up chain + deploy (once) or resume"
sudo systemctl reset-failed anvil aztec-sandbox chain-server block-producer rpc-proxy 2>/dev/null || true
if [ -f "$DATA_MOUNT/deployment-manifest.json" ]; then
  echo "Manifest present: resuming persisted chain (no redeploy)."
  sudo systemctl start anvil || fail "anvil failed (mock-feed install fails the start; see journalctl -u anvil)"
  # Writes /etc/zeracle/chain-server.env — root-owned path. EC2 runs this as root
  # via cloud-init; deploy-pi.sh runs as admin, so it needs sudo here.
  sudo bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start aztec-sandbox chain-server block-producer
  _start_rpc_proxy
else
  echo "First run: deploying contracts."
  # A fresh chain makes every pending L2 flush hash meaningless; left in place,
  # each would cost a full claim wait on every run until it aged out.
  if [ -f "$KEEPER_STATE/pending-flush" ]; then
    sudo rm -f "$KEEPER_STATE/pending-flush" && echo "  cleared stale keeper pending-flush"
  fi
  sudo systemctl start anvil
  timeout 120 bash -c 'until curl -fsS -X POST -H "content-type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}" http://127.0.0.1:8545 >/dev/null; do sleep 3; done' || fail "anvil RPC never came up"
  sudo systemctl start aztec-sandbox
  timeout 300 bash -c 'until curl -fsS http://127.0.0.1:8080/status >/dev/null 2>&1 || curl -fsS http://127.0.0.1:8080 >/dev/null 2>&1; do sleep 5; done' || fail "aztec PXE never came up"
  DEPLOY_STATUS=0
  ( cd "$REPO" && CHAIN_HOST_HEADLESS=1 DOMAIN="$DOMAIN" MAINNET_RPC_URL="${MAINNET_RPC_URL:-}" \
      FOUNDRY_SOLC="/opt/zeracle/toolchain/solc-$SOLC_VERSION" \
      bash deployments/sandbox-local/deploy-sandbox.sh ) || DEPLOY_STATUS=$?
  for m in deployment-manifest.json public-manifest.json; do
    if [ -f "$REPO/deployments/sandbox-local/$m" ]; then
      cp "$REPO/deployments/sandbox-local/$m" "$DATA_MOUNT/$m"
    fi
  done
  [ "$DEPLOY_STATUS" -eq 0 ] || fail "deploy-sandbox.sh failed (exit $DEPLOY_STATUS); manifest persisted if produced"
  # Writes /etc/zeracle/chain-server.env — root-owned path. EC2 runs this as root
  # via cloud-init; deploy-pi.sh runs as admin, so it needs sudo here.
  sudo bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start chain-server block-producer
  _start_rpc_proxy
  ok "first-run deploy complete; manifest at $DATA_MOUNT"
fi

# deploy-sandbox.sh hard-codes the public manifest's identity and endpoints
# for the EC2 shape (PM_ENV_ID=sandbox-ec2, https://anvil.$DOMAIN). Decision 1
# forbids editing that script, so correct the result here — this is exactly
# the platform-layer work deploy-pi.sh exists to do.
#
# Funnel routes by PATH on one host, which the anvil.$DOMAIN subdomain shape
# cannot express, so the endpoints are rebuilt from PUBLIC_BASE_URL.
PUB="$DATA_MOUNT/public-manifest.json"
if [ -f "$PUB" ] && [ -n "${PUBLIC_BASE_URL:-}" ]; then
  tmp="$(mktemp)"
  jq --arg base "$PUBLIC_BASE_URL" '
    .env.id = "pi"
    | .env.label = "Sandbox (Pi)"
    | .endpoints.l1Rpc = ($base + "/anvil")
    | .endpoints.aztecNode = ($base + "/aztec")
    | .endpoints.chainServer = ($base + "/api")
  ' "$PUB" > "$tmp" || fail "failed to rewrite $PUB"
  mv "$tmp" "$PUB"
  # chain-view sources ../deployments/pi/public-manifest.json; keep a copy in
  # the repo tree so gen-web-env.sh can pull it back to the laptop.
  cp "$PUB" "$SCRIPT_DIR/public-manifest.json"
  ok "public manifest rewritten for the Pi ($PUBLIC_BASE_URL)"
elif [ -f "$PUB" ]; then
  echo "  ! PUBLIC_BASE_URL unset — public manifest still carries EC2 endpoints"
fi

# The keeper's env carries ZRCL_ADDRESS, which changes with every fresh chain,
# so it is regenerated from the manifest on every deploy and resume.
if _keeper_installed; then
  step "Fee keeper"
  if [ -f "$DATA_MOUNT/deployment-manifest.json" ]; then
    sudo REPO="$REPO" bash "$SCRIPT_DIR/gen-keeper-env.sh" "$DATA_MOUNT/deployment-manifest.json"
    # e2e-pi.sh holds the keeper for its whole run and restarts it itself.
    if [ -n "${ZERACLE_KEEPER_HOLD:-}" ]; then
      echo "  keeper timer left stopped (ZERACLE_KEEPER_HOLD set by the caller)"
    else
      sudo systemctl start zeracle-keeper.timer
      ok "keeper timer running ($(systemctl show -p NextElapseUSecRealtime --value zeracle-keeper.timer))"
    fi
  else
    echo "  ! no manifest — keeper timer left stopped"
  fi
else
  echo "  ! zeracle-keeper.timer not installed — run provision-pi.sh (make -C deployments provision-pi)"
fi

step "Status"; systemctl --no-pager --failed || true
ok "deploy-pi complete"
