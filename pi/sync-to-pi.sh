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

# Provenance guard. The tarball is built from each repo's WORKING TREE, so the
# Pi silently inherits whatever branch happens to be checked out. That is how a
# chain got deployed from an unmerged solc-0.8.37 branch while `dev` still
# pinned 0.8.22 — release-sources.json recorded the sha, but nothing said it was
# off-trunk, and a second Pi built from `dev` would have failed on ARM outright
# (no aarch64 solc binary below 0.8.31).
#
# Warn by default rather than block: deploying a feature branch to the sandbox
# is a legitimate thing to do. Set ZERACLE_STRICT_BRANCH=1 to make it fatal.
echo "==> Checking source provenance"
off_trunk=""
for repo in v1-l1 v1-l2 chain-server deployments interfaces; do
  d="$ROOT/$repo"
  [ -d "$d/.git" ] || continue
  head_sha="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)" || continue
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if ! git -C "$d" rev-parse --verify --quiet origin/dev >/dev/null 2>&1; then
    printf '    %-14s %s (%s) — no origin/dev to compare against\n' "$repo" "$head_sha" "$branch"
    continue
  fi
  if git -C "$d" merge-base --is-ancestor HEAD origin/dev 2>/dev/null; then
    printf '    %-14s %s (%s) on dev\n' "$repo" "$head_sha" "$branch"
  else
    printf '    %-14s %s (%s) NOT ON dev\n' "$repo" "$head_sha" "$branch"
    off_trunk="$off_trunk $repo"
  fi
  # Uncommitted changes ship too, and no sha records them.
  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    printf '    %-14s has UNCOMMITTED changes — they will ship unrecorded\n' "$repo"
    off_trunk="$off_trunk $repo(dirty)"
  fi
done
if [ -n "$off_trunk" ]; then
  echo ""
  echo "  WARNING: shipping sources that are not on dev:$off_trunk"
  echo "  The Pi will run code that no one else can reproduce from dev."
  if [ "${ZERACLE_STRICT_BRANCH:-0}" = "1" ]; then
    echo "  ZERACLE_STRICT_BRANCH=1 — refusing." >&2
    exit 1
  fi
  echo "  Continuing (set ZERACLE_STRICT_BRANCH=1 to make this fatal)."
  echo ""
fi

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
