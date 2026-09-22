#!/usr/bin/env bash
# Push the zeracle tree to the Pi at /opt/zeracle. Run from the laptop.
set -euo pipefail
PI="${PI_HOST:-pi}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # zeracle root (deployments/pi -> ../..)
REMOTE=/opt/zeracle
# SC2029: $REMOTE is intentionally expanded client-side (it's a fixed laptop-
# side constant); only $(id -u)/$(id -g) are meant to run on the Pi, hence
# the escaped \$( ).
# shellcheck disable=SC2029
ssh "$PI" "sudo mkdir -p $REMOTE && sudo chown \$(id -u):\$(id -g) $REMOTE"
# Main tree. --delete keeps the Pi in sync; excludes keep it lean and safe.
rsync -a --delete \
  --exclude '.git' --exclude 'node_modules' --exclude 'artifacts' --exclude 'cache' \
  --exclude 'dist' --exclude 'out' --exclude '**/.env' --exclude '**/.env.local' \
  --include 'deployments/pi/toolchain/solc-*.sha256' \
  --exclude 'deployments/pi/toolchain/solc-*' \
  "$ROOT/v1-l1" "$ROOT/v1-l2" "$ROOT/chain-server" "$ROOT/deployments" \
  "$ROOT/interfaces" "$PI:$REMOTE/"
# Stage ops/ (systemd units + helpers) from the EC2 files dir.
rsync -a --delete "$ROOT/devops/production/ec2/files/ops/" "$PI:$REMOTE/ops/"
echo "Synced to $PI:$REMOTE"
