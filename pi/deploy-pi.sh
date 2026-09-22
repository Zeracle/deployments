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

step "Bring up chain + deploy (once) or resume"
sudo systemctl reset-failed anvil aztec-sandbox chain-server block-producer 2>/dev/null || true
if [ -f "$DATA_MOUNT/deployment-manifest.json" ]; then
  echo "Manifest present: resuming persisted chain (no redeploy)."
  sudo systemctl start anvil || fail "anvil failed (mock-feed install fails the start; see journalctl -u anvil)"
  bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start aztec-sandbox chain-server block-producer
else
  echo "First run: deploying contracts."
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
  bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start chain-server block-producer
  ok "first-run deploy complete; manifest at $DATA_MOUNT"
fi
step "Status"; systemctl --no-pager --failed || true
ok "deploy-pi complete"
