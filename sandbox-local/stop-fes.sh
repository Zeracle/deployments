#!/bin/bash

# ===========================================================================
# Zeracle Frontends Stopper
#
# Stops the frontends started by start-fes.sh:
#   - Web app    (Vite)       on :5173
#   - Docs app   (Docusaurus) on :3000
#   - Chain view (Vite)       on :5174
#
# Usage:
#   ./stop-fes.sh           # stop all frontends
#   ./stop-fes.sh web       # stop only the web app
#   ./stop-fes.sh docs      # stop only the docs app
#   ./stop-fes.sh chain     # stop only the chain view
# ===========================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
warn() { echo -e "${YELLOW}  ⚠${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}"; }

stop_port() {
  local port=$1 name=$2
  if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    step "Stopping $name on port $port..."
    kill $(lsof -t -i ":$port") 2>/dev/null || true
    sleep 1
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
      # Force kill if still running
      kill -9 $(lsof -t -i ":$port") 2>/dev/null || true
      sleep 0.5
    fi
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
      fail "$name still running on port $port"
      return 1
    fi
    ok "$name stopped"
    return 0
  else
    warn "$name not running on port $port"
    return 0
  fi
}

TARGET="${1:-all}"

case "$TARGET" in
  web)
    stop_port 5173 "Web app (Vite)"
    ;;
  docs)
    stop_port 3000 "Docs app (Docusaurus)"
    ;;
  chain)
    stop_port 5174 "Chain view (Vite)"
    ;;
  all)
    stop_port 5173 "Web app (Vite)"
    stop_port 3000 "Docs app (Docusaurus)"
    stop_port 5174 "Chain view (Vite)"
    ;;
  *)
    echo "Usage: $0 [web|docs|chain|all]"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}Done.${NC}"
echo ""
