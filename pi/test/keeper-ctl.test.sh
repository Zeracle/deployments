#!/usr/bin/env bash
# deployments/pi/test/keeper-ctl.test.sh
# ZER-16: pi/keeper-ctl.sh's keeper_quiesce, offline — systemctl and sudo are
# stubs on PATH, so nothing on this machine is touched.
#
# What this pins: pausing the keeper stops the TIMER and WAITS for a run in
# flight; it never stops the service (a kill mid-flush loses the flush hash),
# and it gives up with status 1 after the timeout rather than waiting forever.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../keeper-ctl.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT does not exist"; exit 1; }

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# systemctl stub: logs every call. `show -p ActiveState` reports the service
# "activating" for the first $ACTIVE_POLLS calls, then "inactive" — which is
# what systemd really reports for a running Type=oneshot unit. `is-active`
# always exits 3 for it, exactly like systemd, so a check built on is-active
# (the first version of keeper_quiesce) sees an idle keeper and fails below.
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  show)
    n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT"
    if [ "$n" -le "$ACTIVE_POLLS" ]; then echo activating; else echo inactive; fi ;;
  is-active) exit 3 ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\n"$@"\n' > "$TMP/bin/sudo"
chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_COUNT="$TMP/count"
export KEEPER_WAIT_POLL_SECS=0
# shellcheck source=../keeper-ctl.sh disable=SC1091
. "$SCRIPT"
sleep() { :; }   # the poll interval is 0 anyway; keep the test instant

run() { : > "$STUB_LOG"; rm -f "$STUB_COUNT"; ACTIVE_POLLS=$1 KEEPER_WAIT_TIMEOUT_SECS=$2 keeper_quiesce >/dev/null 2>&1; }

echo "# idle keeper"
st=0; run 0 3600 || st=$?
check "returns 0" "$st" 0
check "stops the timer" "$(grep -c '^stop zeracle-keeper.timer$' "$STUB_LOG")" 1

echo "# a run in flight finishes"
KEEPER_WAIT_POLL_SECS=1
st=0; run 3 3600 || st=$?
check "returns 0 once the run ends" "$st" 0
check "polled until inactive" "$(grep -c '^show -p ActiveState' "$STUB_LOG")" 4
check "never stops the service" "$(grep -c 'stop.*zeracle-keeper.service' "$STUB_LOG")" 0

echo "# a run that outlasts the timeout"
st=0; run 1000 5 || st=$?
check "returns 1 after the timeout" "$st" 1
check "still never stops the service" "$(grep -c 'stop.*zeracle-keeper.service' "$STUB_LOG")" 0

echo "# the default wait budget grows with the pending list"
export KEEPER_STATE_DIR="$TMP/state"; mkdir -p "$KEEPER_STATE_DIR"
check "no pending file: one claim wait + margin" "$(keeper_wait_budget)" 3600
printf 'a,1\nb,2\n' > "$KEEPER_STATE_DIR/pending-flush"
check "two pending: three claim waits + margin" "$(keeper_wait_budget)" 7200

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
