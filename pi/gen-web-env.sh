#!/usr/bin/env bash
# Generate interfaces/apps/web/.env.pi from the Pi's deployment manifest.
#
# The Pi provisions a FRESH chain (spec Decision 5), so every contract address
# changes on each first-run deploy. deploy-sandbox.sh already records the whole
# frontend variable set in the manifest's `.env` object — this copies that
# across rather than anyone hand-transcribing ~40 addresses.
#
# Usage:
#   ./gen-web-env.sh                               # pull the manifest over ssh
#   ./gen-web-env.sh --manifest /path/to/m.json    # use a local manifest
#   ./gen-web-env.sh --funnel-host pi.tail1234.ts.net
#
# Env:
#   PI_HOST   ssh alias for the Pi (default: pi)
#
# Everything ABOVE the generated marker in .env.pi is preserved (endpoints,
# feature flags, secrets); everything below it is rewritten from the manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # deployments/pi -> zeracle root
ENV_FILE="$ROOT/interfaces/apps/web/.env.pi"
PI="${PI_HOST:-pi}"
MARKER='# --- GENERATED from /data/deployment-manifest.json (.env block) ---'

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}" >&2; exit 1; }

MANIFEST=""
FUNNEL_HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --funnel-host) FUNNEL_HOST="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || fail "jq not found"
[ -f "$ENV_FILE" ] || fail "missing $ENV_FILE"

TMP_MANIFEST=""
if [ -z "$MANIFEST" ]; then
  step "Fetching /data/deployment-manifest.json from $PI"
  TMP_MANIFEST="$(mktemp)"
  # shellcheck disable=SC2064  # expand TMP_MANIFEST now, not at trap time
  trap "rm -f '$TMP_MANIFEST'" EXIT
  ssh "$PI" 'cat /data/deployment-manifest.json' > "$TMP_MANIFEST" 2>/dev/null \
    || fail "could not read /data/deployment-manifest.json on $PI — has deploy-pi.sh completed?"
  MANIFEST="$TMP_MANIFEST"
fi
[ -s "$MANIFEST" ] || fail "manifest $MANIFEST is empty"
jq -e '.env | objects' "$MANIFEST" >/dev/null 2>&1 \
  || fail "manifest has no .env object — wrong manifest format?"
ok "manifest read ($(jq -r '.env | length' "$MANIFEST") variables)"

step "Rewriting the generated block in .env.pi"
NEW="$(mktemp)"
# Keep everything up to and including the marker + its following comment lines.
awk -v marker="$MARKER" '
  { print }
  index($0, marker) { found=1; exit }
  END { if (!found) exit 3 }
' "$ENV_FILE" > "$NEW" || fail "marker line not found in $ENV_FILE — was it hand-edited?"

{
  echo "# Regenerated $(date -u +%Y-%m-%dT%H:%M:%SZ) from the Pi manifest."
  echo "# Chain: $(jq -r '.network // "unknown"' "$MANIFEST") | deployed: $(jq -r '.generatedAt // "unknown"' "$MANIFEST")"
  echo ""
  # Endpoint vars live in the preserved section above; skip them here so the
  # manifest's loopback URLs cannot overwrite the public Funnel endpoints.
  jq -r '.env | to_entries[]
         | select(.key | test("_URL$|^VITE_ETH_CHAIN_ID$|^VITE_ZERACLE_ENV$") | not)
         | "\(.key)=\(.value // "")"' "$MANIFEST" | sort
} >> "$NEW"

mv "$NEW" "$ENV_FILE"
ok "generated block written"

if [ -n "$FUNNEL_HOST" ]; then
  step "Setting Funnel host to $FUNNEL_HOST"
  sed -i "s#REPLACE-ME\.ts\.net#${FUNNEL_HOST}#g" "$ENV_FILE"
  ok "endpoints updated"
fi

if grep -q 'REPLACE-ME\.ts\.net' "$ENV_FILE"; then
  echo ""
  echo "NOTE: endpoints still contain REPLACE-ME.ts.net. Re-run with"
  echo "      --funnel-host <machine>.<tailnet>.ts.net once Funnel is up."
fi
echo ""
echo "Wrote $ENV_FILE"
