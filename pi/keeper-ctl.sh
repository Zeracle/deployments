#!/usr/bin/env bash
# Pausing the fee keeper (ZER-16) without losing a flush. Sourced by
# deploy-pi.sh and e2e-pi.sh; defines functions only.
#
# Why a run is waited for, not killed: run-keeper.sh records a flush in
# pending-flush only AFTER flush-fees.ts returns, and flush-fees.ts prints the
# tx hash only once the L2 receipt is back — minutes on the Pi (~2.5 min per
# block). A SIGTERM in that window lets the already-submitted flush mine while
# its hash is never recorded, so nothing ever claims those fees from the L1
# Outbox. A kill mid-CLAIM would be harmless (the hash is still pending and
# claim-fees-l1.ts skips an already-consumed message), but from outside there
# is no telling which step a run is in. So: stop the timer, then wait.

KEEPER_TIMER=zeracle-keeper.timer
KEEPER_SERVICE=zeracle-keeper.service
# Worst case for a run in flight: sweep and flush (a few Pi blocks each) plus
# the Pi's 1800 s claim wait per pending hash, plus convert and cushion.
KEEPER_WAIT_TIMEOUT_SECS="${KEEPER_WAIT_TIMEOUT_SECS:-3600}"
KEEPER_WAIT_POLL_SECS="${KEEPER_WAIT_POLL_SECS:-10}"

keeper_installed() { systemctl list-unit-files "$KEEPER_TIMER" >/dev/null 2>&1; }

# keeper_quiesce: stop the timer so no new run starts, then wait for any run in
# flight to finish on its own. Returns 1 if it is still running after
# KEEPER_WAIT_TIMEOUT_SECS; the caller decides whether that is fatal.
keeper_quiesce() {
  sudo systemctl stop "$KEEPER_TIMER" 2>/dev/null || true
  local waited=0
  while systemctl is-active --quiet "$KEEPER_SERVICE"; do
    if [ "$waited" -ge "$KEEPER_WAIT_TIMEOUT_SECS" ]; then
      echo "  ! a keeper run is still in flight after ${waited}s (journalctl -u zeracle-keeper)" >&2
      return 1
    fi
    [ "$waited" -eq 0 ] && echo "  a keeper run is in flight — waiting for it to finish (up to ${KEEPER_WAIT_TIMEOUT_SECS}s)"
    sleep "$KEEPER_WAIT_POLL_SECS"
    waited=$((waited + KEEPER_WAIT_POLL_SECS))
  done
}
