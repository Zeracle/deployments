#!/bin/bash
# ===========================================================================
# Zeracle EC2 Sandbox Deploy
#
# Thin wrapper around the real EC2 chain-host flow in devops/production/ec2.
# The EC2 host is a hosted SANDBOX (persistent, shared) — not "testnet".
# "testnet" always means the official Aztec testnet; see ../testnet/.
#
# Why this script doesn't deploy contracts or install mock feeds itself:
# the chain deployment runs ON the box, not from this machine. The tarball
# built here ships the whole deployments/ dir; at first boot the instance's
# bootstrap.sh (devops/production/ec2/files/ops/) runs the SAME scripts as a
# local deploy — ../sandbox-local/install-mock-feeds.sh and then
# ../sandbox-local/deploy-sandbox.sh (headless). One copy of the sandbox
# deploy logic serves both environments so they cannot drift.
#
# Usage:
#   ./deploy-ec2.sh          # Build the release tarball, print next steps
#   ./deploy-ec2.sh --apply  # Build the tarball, then `terraform apply`
#
# Full runbook: devops/production/ec2/README.md
# ===========================================================================

set -euo pipefail

# Script lives in deployments/sandbox-ec2/; the project root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

EC2_DIR="$ROOT_DIR/devops/production/ec2"
TARBALL_SCRIPT="$EC2_DIR/scripts/make-release-tarball.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}" >&2; exit 1; }

[ -f "$TARBALL_SCRIPT" ] || fail "Tarball builder not found at $TARBALL_SCRIPT — is devops/production/ec2 present?"
[ -d "$EC2_DIR" ] || fail "Terraform dir not found at $EC2_DIR — is devops/production/ec2 present?"

APPLY=false
if [ "${1:-}" = "--apply" ]; then
  APPLY=true
fi

step "Building release tarball..."
bash "$TARBALL_SCRIPT"
ok "Release tarball built: $SCRIPT_DIR/zeracle-chain.tar.gz"

if [ "$APPLY" = true ]; then
  step "Running terraform apply in $EC2_DIR (interactive — review the plan before confirming)..."
  ( cd "$EC2_DIR" && terraform apply )
  ok "terraform apply finished"
else
  echo ""
  echo -e "${YELLOW}Next steps${NC} (full detail in devops/production/ec2/README.md):"
  echo ""
  echo -e "  1. Configure Terraform variables (first time only):"
  echo -e "       cd devops/production/ec2"
  echo -e "       cp terraform.tfvars.example terraform.tfvars"
  echo -e "       \$EDITOR terraform.tfvars   # admin_cidr, code_tarball_path, domain, fe_origin, aztec_image_tag"
  echo ""
  echo -e "  2. Initialise and apply:"
  echo -e "       cd devops/production/ec2 && terraform apply"
  echo -e "     (or re-run this script with --apply)"
  echo ""
  echo -e "  3. Watch first-boot bootstrap over SSH:"
  echo -e "       terraform output ssh_command"
  echo -e "       ssh -i zeracle-key.pem ec2-user@<elastic-ip>"
  echo -e "       sudo tail -f /var/log/zeracle-bootstrap.log"
  echo ""
  echo -e "  First-boot takes 10-20 minutes. Final log line reads:"
  echo -e "    Bootstrap finished. Endpoints: https://anvil.<domain> https://aztec.<domain> https://api.<domain>"
  echo ""
fi
