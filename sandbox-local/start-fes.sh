#!/bin/bash
set -e

# ===========================================================================
# Zeracle Frontends Launcher
#
# Starts the frontends in dev mode and streams their logs side by side:
#   - Web app   (Vite)       → http://localhost:5173   interfaces/apps/web
#   - Docs app  (Docusaurus) → http://localhost:3000   docs-app/app
#   - Chain view (Vite)      → http://localhost:5174   chain-view
#
# All run in the foreground; Ctrl+C stops them cleanly.
#
# Usage:
#   ./start-fes.sh           # start all frontends
#   ./start-fes.sh web       # start only the web app
#   ./start-fes.sh docs      # start only the docs app
#   ./start-fes.sh chain     # start only the chain view
# ===========================================================================

# Script lives in scripts/; the project root is one level up.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WEB_DIR="$ROOT_DIR/interfaces/apps/web"
DOCS_DIR="$ROOT_DIR/docs-app/app"
CHAIN_DIR="$ROOT_DIR/chain-view"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
warn() { echo -e "${YELLOW}  ⚠${NC} ${1}"; }

TARGET="${1:-all}"

PIDS=()

# Kill all child processes on exit (Ctrl+C or error). Each frontend is started
# in its own process group via setsid so we can take down vite/docusaurus and
# any node workers they spawn.
cleanup() {
  step "Stopping frontends..."
  for pid in "${PIDS[@]}"; do
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  ok "Stopped"
}
trap cleanup EXIT INT TERM

start_fe() {
  local name=$1 dir=$2 color=$3 pm=$4
  shift 4
  if [ ! -d "$dir/node_modules" ]; then
    warn "$name: node_modules missing in $dir — run '$pm install' there first"
  fi
  step "Starting $name ($dir)..."
  # setsid puts the process in its own group so cleanup() can signal the whole
  # tree. Prefix each line with the frontend name so interleaved logs stay
  # readable.
  ( cd "$dir" && setsid "$pm" run dev "$@" 2>&1 | sed "s/^/$(echo -e "${color}[$name]${NC} ")/" ) &
  PIDS+=($!)
}

case "$TARGET" in
  web)
    start_fe "web"   "$WEB_DIR"   "$GREEN"  "yarn"
    ;;
  docs)
    start_fe "docs"  "$DOCS_DIR"  "$BLUE"   "yarn"
    ;;
  chain)
    start_fe "chain" "$CHAIN_DIR" "$YELLOW" "npm"
    ;;
  all)
    start_fe "web"   "$WEB_DIR"   "$GREEN"  "yarn"
    start_fe "docs"  "$DOCS_DIR"  "$BLUE"   "yarn"
    start_fe "chain" "$CHAIN_DIR" "$YELLOW" "npm"
    ;;
  *)
    echo "Usage: $0 [web|docs|chain|all]"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Zeracle Frontends Running                 ${NC}"
echo -e "${GREEN}============================================${NC}"
{ [ "$TARGET" = "all" ] || [ "$TARGET" = "web" ]; }   && echo -e "  ${BLUE}Web app:${NC}     http://localhost:5173" || true
{ [ "$TARGET" = "all" ] || [ "$TARGET" = "docs" ]; }  && echo -e "  ${BLUE}Docs app:${NC}    http://localhost:3000" || true
{ [ "$TARGET" = "all" ] || [ "$TARGET" = "chain" ]; } && echo -e "  ${BLUE}Chain view:${NC}  http://localhost:5174" || true
echo ""
echo -e "  ${YELLOW}Press Ctrl+C to stop.${NC}"
echo ""

# Wait for any frontend to exit; cleanup() handles the rest.
wait
