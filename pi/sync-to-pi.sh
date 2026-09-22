#!/usr/bin/env bash
# Push the zeracle tree to the Pi at /opt/zeracle. Run from the laptop.
#
# Uses the SAME release tarball EC2's cloud-init fetches
# (devops/production/ec2/scripts/make-release-tarball.sh) rather than a
# hand-rolled rsync, so the two platform layers cannot drift — the same rule
# deploy-ec2.sh states for the deploy logic itself.
#
# This matters concretely: the tarball keeps precompiled v1-l2/{artifacts,target}
# (headless deploy has no aztec-nargo on the box), ships
# interfaces/packages/instant-pay-core WITH its built dist/ (v1-l2 depends on it
# via file:), writes release-sources.json (lib/public-manifest.sh needs the shas
# because .git is not shipped), stages ops/ (systemd units + helpers), and
# applies the scoped secret excludes. A blanket "--exclude artifacts" rsync
# silently breaks the first three.
set -euo pipefail

PI="${PI_HOST:-pi}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # deployments/pi -> zeracle root
REMOTE=/opt/zeracle
TARBALL_SCRIPT="$ROOT/devops/production/ec2/scripts/make-release-tarball.sh"
OUT="$ROOT/dist/zeracle-chain-pi.tar.gz"

[ -f "$TARBALL_SCRIPT" ] || { echo "FATAL: tarball builder not found at $TARBALL_SCRIPT" >&2; exit 1; }

echo "==> Building release tarball"
bash "$TARBALL_SCRIPT" "$OUT"

echo "==> Extracting to $PI:$REMOTE"
# shellcheck disable=SC2029  # $REMOTE is a local constant; client-side expansion is intended
ssh "$PI" "sudo mkdir -p $REMOTE && sudo chown \$(id -u):\$(id -g) $REMOTE"
# Stream straight into place. Extraction overwrites tracked files and leaves
# on-box-generated dirs (node_modules, toolchain/) alone, so it is re-runnable.
# shellcheck disable=SC2029  # same: $REMOTE expands locally by design
ssh "$PI" "tar -C $REMOTE -xzf -" < "$OUT"

echo "Synced $OUT -> $PI:$REMOTE"
