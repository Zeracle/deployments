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
# How long to wait for a run in flight. Worst case: sweep and flush (a few Pi
# blocks each, ~2.5 min per block), then up to KEEPER_CLAIM_WAIT_SECS (the Pi
# sets 1800) for EVERY pending hash plus the one this run may flush, then
# convert and cushion. So the default grows with the pending list; set
# KEEPER_WAIT_TIMEOUT_SECS to override.
KEEPER_STATE_DIR="${KEEPER_STATE_DIR:-/var/lib/zeracle-keeper}"
KEEPER_WAIT_POLL_SECS="${KEEPER_WAIT_POLL_SECS:-10}"

keeper_installed() { systemctl list-unit-files "$KEEPER_TIMER" >/dev/null 2>&1; }

# keeper_wait_budget: seconds keeper_quiesce waits by default.
keeper_wait_budget() {
  local pending=0
  [ -r "$KEEPER_STATE_DIR/pending-flush" ] && pending=$(grep -c . "$KEEPER_STATE_DIR/pending-flush" || true)
  echo $(( 1800 + 1800 * (pending + 1) ))
}

# keeper_running: is a keeper run in flight? NOT `systemctl is-active`: a
# Type=oneshot unit is "activating" for its whole run, and is-active reports
# that as inactive (exit 3) — the first version of this check returned at once
# with a run in flight (ZER-16 review).
keeper_running() {
  case "$(systemctl show -p ActiveState --value "$KEEPER_SERVICE")" in
    activating | active | deactivating | reloading) return 0 ;;
    *) return 1 ;;
  esac
}

# keeper_quiesce: stop the timer so no new run starts, then wait for any run in
# flight to finish on its own. Returns 1 if it is still running after the
# budget; the caller decides whether that is fatal.
keeper_quiesce() {
  sudo systemctl stop "$KEEPER_TIMER" 2>/dev/null || true
  local timeout="${KEEPER_WAIT_TIMEOUT_SECS:-$(keeper_wait_budget)}" waited=0
  while keeper_running; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "  ! a keeper run is still in flight after ${waited}s (journalctl -u zeracle-keeper)" >&2
      return 1
    fi
    [ "$waited" -eq 0 ] && echo "  a keeper run is in flight — waiting for it to finish (up to ${timeout}s)"
    sleep "$KEEPER_WAIT_POLL_SECS"
    waited=$((waited + KEEPER_WAIT_POLL_SECS))
  done
}
