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
# systemctl stub: logs every call; `is-active` reports the service active for
# the first $ACTIVE_POLLS calls, then inactive.
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1" = is-active ]; then
  n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT"
  [ "$n" -le "$ACTIVE_POLLS" ] && exit 0 || exit 3
fi
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
check "polled until inactive" "$(grep -c '^is-active' "$STUB_LOG")" 4
check "never stops the service" "$(grep -c 'stop.*zeracle-keeper.service' "$STUB_LOG")" 0

echo "# a run that outlasts the timeout"
st=0; run 1000 5 || st=$?
check "returns 1 after the timeout" "$st" 1
check "still never stops the service" "$(grep -c 'stop.*zeracle-keeper.service' "$STUB_LOG")" 0

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
