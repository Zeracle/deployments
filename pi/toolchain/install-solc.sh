#!/usr/bin/env bash
# Install the pinned, official aarch64 solc for the Pi chain host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${SOLC_VERSION:-0.8.37}"
DEST_DIR=/opt/zeracle/toolchain
DEST="$DEST_DIR/solc-$VERSION"
SUMFILE="$SCRIPT_DIR/solc-$VERSION.sha256"
ASSET="solc-static-linux-arm"
URL="https://github.com/argotorg/solidity/releases/download/v$VERSION/$ASSET"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "\n${BLUE}==>${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
fail(){ echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

# Pin must match v1-l1/foundry.toml, or CI and the deploy use different compilers.
CFG_SOLC="$(grep -E '^\s*solc_version' /opt/zeracle/v1-l1/foundry.toml | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/')"
[ "$CFG_SOLC" = "$VERSION" ] || fail "solc pin $VERSION != v1-l1/foundry.toml solc_version $CFG_SOLC"
# solc-$VERSION.sha256 is NOT committed by this script or by Wave A — it is
# populated once from a real download (see Task 2 Step 1 in the build plan).
# This check fails loudly until that first fetch records the real checksum.
[ -f "$SUMFILE" ] || fail "missing committed checksum $SUMFILE"

if [ -x "$DEST" ] && (cd "$DEST_DIR" && sha256sum -c <(sed "s#$ASSET#solc-$VERSION#" "$SUMFILE") >/dev/null 2>&1); then
  ok "solc $VERSION already installed and checksum-valid ($DEST)"
else
  step "Downloading solc $VERSION ($ASSET)"
  mkdir -p "$DEST_DIR"
  tmp="$(mktemp)"; curl -fL -o "$tmp" "$URL" || fail "download failed: $URL"
  echo "$(awk '{print $1}' "$SUMFILE")  $tmp" | sha256sum -c - >/dev/null 2>&1 \
    || fail "SHA-256 mismatch for downloaded solc — refusing to install"
  install -m 0755 "$tmp" "$DEST"; rm -f "$tmp"
  ok "installed $DEST"
fi

step "Verify native + runnable"
file "$DEST" | grep -q 'aarch64' || fail "$DEST is not an AArch64 binary"
"$DEST" --version >/dev/null || fail "$DEST failed to run"
ok "$("$DEST" --version | tail -1)"
