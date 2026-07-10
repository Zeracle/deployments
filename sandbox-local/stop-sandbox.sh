#!/bin/bash
# ===========================================================================
# Zeracle Local Stack Shutdown
#
# Usage:
#   ./stop-sandbox.sh             # Stop services, keep logs
#   ./stop-sandbox.sh --clean-logs   # Also delete /tmp/zeracle-*.log
#
# Stops the processes started by deploy-sandbox.sh:
#   • Anvil (L1) — plain or mainnet-forked
#   • Aztec Sandbox (L2, Docker)
#   • Block Producer loop
#
# Chain Server is started manually in its own terminal, so it's NOT touched.
# ===========================================================================

# Script lives in deployments/sandbox-local/; the project root is two levels up.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
L2_DIR="$ROOT_DIR/v1-l2"

# Parity with deploy-sandbox.sh — pick up .env so future flags (e.g. fork config)
# resolve consistently when stopping. Lives at deployments/sandbox-local/.env (moved from the
# repo root), not the repo root itself.
if [ -f "$ROOT_DIR/deployments/sandbox-local/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/deployments/sandbox-local/.env"
  set +a
fi

CLEAN_LOGS=false
if [ "$1" = "--clean-logs" ]; then
  CLEAN_LOGS=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
warn() { echo -e "${YELLOW}  ⚠${NC} ${1}"; }

# Wait briefly for a TCP port to be free after a kill. Gives docker/anvil a
# moment to actually release the socket so a subsequent deploy-sandbox.sh can
# bind it without racing.
wait_for_port_free() {
  local port=$1 name=$2
  for _ in 1 2 3 4 5; do
    if ! nc -z localhost "$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  warn "$name port $port still bound"
}

echo -e "\nStopping Zeracle local stack...\n"

# Block Producer (kill parent loop + any in-flight trigger-l2-block tsx child)
pkill -f "sandbox-block-producer.sh" 2>/dev/null && ok "Block Producer stopped" || ok "Block Producer not running"
pkill -f "scripts/trigger-l2-block.ts" 2>/dev/null || true

# Chain Server is started manually — not managed by this script.

# Aztec Sandbox (Docker) — match any aztecprotocol/aztec image (with or without tag)
(cd "$L2_DIR" && docker-compose -f docker-compose.local.yml down 2>/dev/null) || true
docker ps -q | xargs -r docker inspect --format '{{.Id}} {{.Config.Image}}' 2>/dev/null | grep "aztecprotocol/aztec" | awk '{print $1}' | xargs -r docker stop 2>/dev/null && ok "Aztec container stopped" || ok "No Aztec container running"
wait_for_port_free 8080 "Aztec Sandbox"

# Anvil (plain or mainnet-forked — the flags are on the cmdline so pkill still matches)
pkill -f "anvil" 2>/dev/null && ok "Anvil stopped" || ok "Anvil not running"
wait_for_port_free 8545 "Anvil"

if [ "$CLEAN_LOGS" = true ]; then
  rm -f /tmp/zeracle-anvil.log /tmp/zeracle-sandbox.log /tmp/zeracle-block-producer.log
  ok "Cleaned /tmp/zeracle-*.log"
else
  ok "Logs preserved at /tmp/zeracle-*.log (use --clean-logs to delete)"
fi

echo -e "\n${GREEN}All services stopped.${NC}\n"
