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
  # Writes /etc/zeracle/chain-server.env — root-owned path. EC2 runs this as root
  # via cloud-init; deploy-pi.sh runs as admin, so it needs sudo here.
  sudo bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
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
  # Writes /etc/zeracle/chain-server.env — root-owned path. EC2 runs this as root
  # via cloud-init; deploy-pi.sh runs as admin, so it needs sudo here.
  sudo bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start chain-server block-producer
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

step "Status"; systemctl --no-pager --failed || true
ok "deploy-pi complete"
