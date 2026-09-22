#!/usr/bin/env bash
# ExecStartPre for anvil: write the extra --host flag for the Tailscale iface.
# Loopback is always bound; this adds the tailnet IP when ANVIL_BIND=tailscale.
set -euo pipefail
OUT=/run/zeracle/anvil-bind.env
mkdir -p /run/zeracle
BIND=""
if [ "${ANVIL_BIND:-tailscale}" = "tailscale" ] && command -v tailscale >/dev/null; then
  IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$IP" ] && BIND="--host $IP"
fi
echo "ANVIL_EXTRA_HOST=$BIND" > "$OUT"
