#!/usr/bin/env bash
# Expose the Pi chain host's three endpoints publicly over HTTPS via Tailscale
# Funnel. Runs ON the Pi.
#
#   https://<host>.ts.net/anvil  -> 127.0.0.1:8546  (rpc-proxy -> anvil, filtered)
#   https://<host>.ts.net/aztec  -> 127.0.0.1:8080  (Aztec PXE/node)
#   https://<host>.ts.net/api    -> 127.0.0.1:3001  (chain-server)
#
# Path-routed on 443 because Funnel only serves 443/8443/10000 — one hostname
# per port is not available. The frontend is served over HTTPS from CloudFront,
# so plaintext endpoints would be blocked as mixed content; Funnel terminates
# TLS with a Tailscale-issued cert for the ts.net name.
#
# /anvil deliberately points at the proxy (8546), NOT anvil (8545): a public
# raw anvil exposes state-rewriting admin methods and unlocked funded accounts.
#
# Prereq: Funnel must be enabled for the tailnet (ACL nodeAttrs "funnel") and
# HTTPS certs/MagicDNS switched on. If it is not, tailscale prints a URL to
# enable it and this script fails loudly rather than half-configuring.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
ok()   { echo -e "${GREEN}  ✓${NC} ${1}"; }
fail() { echo -e "${RED}  ✗ ${1}${NC}" >&2; exit 1; }

command -v tailscale >/dev/null || fail "tailscale not installed"
sudo tailscale status >/dev/null 2>&1 || fail "tailscale is not up — run: sudo tailscale up"

HOSTNAME_FQDN="$(sudo tailscale status --json | grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$HOSTNAME_FQDN" ] || fail "could not resolve this node's MagicDNS name"
ok "node: $HOSTNAME_FQDN"

step "Checking backends are listening"
for spec in "8546:rpc-proxy" "8080:aztec" "3001:chain-server"; do
  port="${spec%%:*}"; name="${spec##*:}"
  ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN \
    || fail "$name is not listening on $port — start it before exposing it"
  ok "$name listening on $port"
done

# --yes is load-bearing: without it `tailscale serve` prompts for confirmation
# and blocks forever when run over a non-TTY ssh session.
step "Configuring serve paths on :443"
sudo tailscale serve --bg --yes --https=443 --set-path=/anvil http://127.0.0.1:8546 \
  || fail "failed to set /anvil — check 'tailscale serve' syntax for $(tailscale version | head -1)"
sudo tailscale serve --bg --yes --https=443 --set-path=/aztec http://127.0.0.1:8080 \
  || fail "failed to set /aztec"
sudo tailscale serve --bg --yes --https=443 --set-path=/api http://127.0.0.1:3001 \
  || fail "failed to set /api"
# `tailscale serve` exits 0 even when it refuses (e.g. "Serve is not enabled on
# your tailnet" + an enable URL), so the exit codes above prove nothing. Assert
# the config actually landed — same reason bootstrap.sh asserts a mountpoint
# rather than trusting `mount -a`.
SERVE_STATUS="$(sudo tailscale serve status 2>&1 || true)"
for p in /anvil /aztec /api; do
  echo "$SERVE_STATUS" | grep -q -- "$p" \
    || fail "serve path $p is not in 'tailscale serve status' — the tailnet likely needs Serve enabled (an enable URL was printed above)"
done
ok "serve paths configured and verified"

step "Enabling Funnel on :443 (public)"
sudo tailscale funnel --bg --yes --https=443 on \
  || fail "could not enable Funnel — the tailnet may need the 'funnel' node attribute in its ACL policy (tailscale prints an enable URL above)"
FUNNEL_STATUS="$(sudo tailscale funnel status 2>&1 || true)"
echo "$FUNNEL_STATUS" | grep -qi "funnel on\|https://" \
  || fail "Funnel is not actually on — check the enable URL printed above"
ok "funnel on and verified"

step "Current config"
sudo tailscale serve status || true
sudo tailscale funnel status || true

cat <<EOF

Public endpoints (use these in interfaces/apps/web/.env.pi):
  VITE_ETH_RPC_URL=https://$HOSTNAME_FQDN/anvil
  VITE_AZTEC_PXE_URL=https://$HOSTNAME_FQDN/aztec
  VITE_AZTEC_NODE_URL=https://$HOSTNAME_FQDN/aztec
  VITE_DEPLOY_SERVER_URL=https://$HOSTNAME_FQDN/api
  VITE_ATTESTOR_URL=https://$HOSTNAME_FQDN/api

Regenerate that file with:
  deployments/pi/gen-web-env.sh --funnel-host $HOSTNAME_FQDN
EOF
