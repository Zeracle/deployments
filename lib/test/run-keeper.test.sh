#!/usr/bin/env bash
# TDD RED/GREEN coverage for lib/keeper/run-keeper.sh (D-b, Db-10 + the final
# review fixes). Puts stub yarn/npx/node binaries on PATH and drives run-keeper.sh
# through:
#   - the step order (sweep -> flush -> relay -> convert -> cushion)
#   - a missing KEEPER_L1_PRIVATE_KEY / ZRCL_ADDRESS exiting non-zero before
#     any step runs (Minor 4)
#   - a keeper key equal to a deployer key refusing to start, without echoing
#     the key (Minor 8)
#   - idle steps (no FLUSH_TX) still giving an overall exit 0
#   - one failing step giving exit 1 while every later step still runs
#   - FLUSH_TX printed by flush reaching the relay's --tx argument
#   - Important 2: a pending flush hash surviving a failed claim, being
#     retried and cleared on the next run, a flush failure never being
#     reported as a relay ok, and the claim wait budget reaching claim:fees
#   - ZER-13 / Db-R19: a second, overlapping run refusing to start rather than
#     racing the first one's read-modify-write of pending-flush (flock)
#   - ZER-13: a pending hash past the ~2 h proof window being EXPIRED and
#     dropped instead of retried (and re-FAILED) forever, while a still-fresh
#     hash keeps failing loudly and keeps its ORIGINAL timestamp
#   - ZER-13 (review): a corrupt pending line (octal-looking, overflowing,
#     future-stamped, undateable) expiring cleanly instead of aborting the
#     relay step; the lock being held for the WHOLE run and not leaking into
#     children; and the claim wait being clamped to the time actually left in
#     the proof window
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RUN_KEEPER="$HERE/../keeper/run-keeper.sh"
STUB_BIN=$(mktemp -d)
STUB_LOG=$(mktemp)
STATE_ROOT=$(mktemp -d)
# A real directory: sweep and flush `cd` into V1_L2_DIR before running.
FAKE_L2=$(mktemp -d)
export STUB_LOG # the stub yarn/npx/node binaries below run as SEPARATE processes
                # (found via PATH from inside run-keeper.sh) and need this
                # in their own environment, not just this script's shell.
trap 'rm -rf "$STUB_BIN" "$STUB_LOG" "$STATE_ROOT" "$FAKE_L2"' EXIT

# --- stub yarn: records "STEP=<name> ... ARGS=<argv>" for every invocation it
# recognizes, and fakes each script's exit code / stdout via STUB_* env vars
# the test sets per-scenario. Recognizes invocations by substring so it does
# not need to track flag order.
cat > "$STUB_BIN/yarn" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
LINE="yarn $*"
case "$LINE" in
  *" tsx "*)
    # Real yarn: v1-l2 has no tsx dependency, so `yarn [--cwd …] tsx …` never
    # runs the script — it fails with 'Command "tsx" not found' (T12 batch C,
    # the first real run). Mirror that, so a regression back to `yarn tsx`
    # fails this test the way it fails on a real checkout.
    echo "STEP=yarn-tsx ARGS=$*" >> "$STUB_LOG"
    echo 'error Command "tsx" not found. Did you mean "tsc"?' >&2
    exit 1
    ;;
  *"claim:fees"*)
    # ZER-13: two things only a CHILD of the keeper can observe.
    # LOCK=  does the keeper still hold its state-dir lock while the relay is
    #        running? (A keeper that took the lock and released it immediately
    #        would pass Test 14 just as happily.)
    # FD9=   did the keeper close its lock fd before exec'ing this child? An
    #        inherited fd 9 keeps the lock alive in any process that outlives
    #        the run, and the NEXT run then reports an overlap that is not real.
    LOCKSTATE=unprobed
    if [ -n "${STUB_LOCK_FILE:-}" ]; then
      if flock -n 7 7>"$STUB_LOCK_FILE" 2>/dev/null; then LOCKSTATE=free; else LOCKSTATE=held; fi
    fi
    if [ -e /proc/self/fd/9 ]; then FD9=open; else FD9=closed; fi
    echo "STEP=claim WAIT=${CLAIM_WITNESS_TIMEOUT_SECS:-unset} LOCK=$LOCKSTATE FD9=$FD9 ARGS=$*" >> "$STUB_LOG"
    exit "${STUB_CLAIM_EXIT:-0}"
    ;;
  *"keeper:convert"*)
    echo "STEP=convert ARGS=$*" >> "$STUB_LOG"
    exit "${STUB_CONVERT_EXIT:-0}"
    ;;
  *"keeper:cushion"*)
    echo "STEP=cushion ARGS=$*" >> "$STUB_LOG"
    exit "${STUB_CUSHION_EXIT:-0}"
    ;;
  *)
    echo "run-keeper.test.sh: unrecognized stub yarn invocation: $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUB_BIN/yarn"

# --- stub npx: sweep and flush run their v1-l2 scripts as `npx tsx …` from
# V1_L2_DIR, the same runner every v1-l2 package script uses. Records the tool
# and the cwd so Test 13 can assert both.
cat > "$STUB_BIN/npx" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
LINE="npx $*"
case "$LINE" in
  *"tsx scripts/sweep-fees.ts"*)
    echo "STEP=sweep TOOL=npx CWD=$PWD ARGS=$*" >> "$STUB_LOG"
    exit "${STUB_SWEEP_EXIT:-0}"
    ;;
  *"tsx scripts/flush-fees.ts"*)
    echo "STEP=flush TOOL=npx CWD=$PWD ARGS=$*" >> "$STUB_LOG"
    if [ -n "${STUB_FLUSH_TX:-}" ]; then
      echo "FLUSH_TX=${STUB_FLUSH_TX}"
      echo "FLUSH_BLOCK=42"
    else
      echo "nothing to flush"
    fi
    exit "${STUB_FLUSH_EXIT:-0}"
    ;;
  *)
    echo "run-keeper.test.sh: unrecognized stub npx invocation: $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUB_BIN/npx"

# Stub node too (per the plan's test setup), even though the current
# run-keeper.sh never shells out to node directly (Db-1: convert/cushion are
# invoked via `yarn keeper:convert`/`keeper:cushion`, not `node ...mjs`) —
# harmless, and catches a future regression that reintroduces a direct node
# call.
cat > "$STUB_BIN/node" <<'STUB'
#!/usr/bin/env bash
echo "STEP=node ARGS=$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/node"

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok: $1"; }

# steps_seen: the ordered list of "STEP=<name>" tags recorded in $STUB_LOG.
steps_seen() {
  local out="" line
  while IFS= read -r line; do
    case "$line" in
      STEP=*)
        local rest="${line#STEP=}"
        local name="${rest%% *}"
        out="$out$name,"
        ;;
    esac
  done < "$STUB_LOG"
  echo "$out"
}

# claim_lines: every STEP=claim log line, one per line, in call order.
claim_lines() {
  local line
  while IFS= read -r line; do
    case "$line" in
      STEP=claim*) echo "$line" ;;
    esac
  done < "$STUB_LOG"
}

# claim_args: the ARGS=... tail of the FIRST STEP=claim log line, or "".
claim_args() {
  local first
  first=$(claim_lines | { IFS= read -r l || true; echo "${l:-}"; })
  if [ -n "$first" ]; then echo "${first#*ARGS=}"; else echo ""; fi
}

# new_state: a fresh, empty KEEPER_STATE_DIR for one scenario.
new_state() { STATE_DIR=$(mktemp -d "$STATE_ROOT/state.XXXXXX"); PENDING="$STATE_DIR/pending-flush"; }

# pending_has <hash>: 0 if <hash> is the hash field of a line of the pending
# file. Lines are "<hash>,<unix epoch>" (ZER-13); a legacy bare hash has no
# comma, and ${line%%,*} yields the whole line for it, so both shapes match.
pending_has() {
  local line
  [ -f "$PENDING" ] || return 1
  while IFS= read -r line; do
    [ "${line%%,*}" = "$1" ] && return 0
  done < "$PENDING"
  return 1
}

# pending_seed <hash> <age-in-seconds>: write one pending line aged <age> s.
pending_seed() { printf '%s,%s\n' "$1" "$(( $(date +%s) - $2 ))" >> "$PENDING"; }

# run_keeper [VAR=value ...]: runs run-keeper.sh with the stub PATH and a
# complete default env (later assignments override earlier ones), capturing
# OUTPUT and STATUS.
run_keeper() {
  : > "$STUB_LOG"
  set +e
  OUTPUT=$(env PATH="$STUB_BIN:$PATH" V1_L2_DIR="$FAKE_L2" ZRCL_ADDRESS=0xzrcl \
    KEEPER_L1_PRIVATE_KEY=0xkeeper KEEPER_STATE_DIR="$STATE_DIR" "$@" \
    bash "$RUN_KEEPER" 2>&1)
  STATUS=$?
  set -e
}

summary_has() {
  case "$OUTPUT" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Test 1: missing KEEPER_L1_PRIVATE_KEY exits non-zero, no step runs -----
: > "$STUB_LOG"
new_state
set +e
OUTPUT=$(env -u KEEPER_L1_PRIVATE_KEY PATH="$STUB_BIN:$PATH" V1_L2_DIR="$FAKE_L2" \
  ZRCL_ADDRESS=0xzrcl KEEPER_STATE_DIR="$STATE_DIR" bash "$RUN_KEEPER" 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then ok "missing KEEPER_L1_PRIVATE_KEY: exit non-zero"; else fail "missing KEEPER_L1_PRIVATE_KEY: exit was 0"; fi
if [ ! -s "$STUB_LOG" ]; then ok "missing KEEPER_L1_PRIVATE_KEY: no step ran"; else fail "missing KEEPER_L1_PRIVATE_KEY: a step ran anyway ($(cat "$STUB_LOG"))"; fi
case "$OUTPUT" in
  *KEEPER_L1_PRIVATE_KEY*) ok "missing KEEPER_L1_PRIVATE_KEY: error message names the var" ;;
  *) fail "missing KEEPER_L1_PRIVATE_KEY: error message doesn't name the var: $OUTPUT" ;;
esac

# --- Test 1b (Minor 4): missing ZRCL_ADDRESS exits non-zero, no step runs ---
: > "$STUB_LOG"
new_state
set +e
OUTPUT=$(env -u ZRCL_ADDRESS PATH="$STUB_BIN:$PATH" V1_L2_DIR="$FAKE_L2" \
  KEEPER_L1_PRIVATE_KEY=0xkeeper KEEPER_STATE_DIR="$STATE_DIR" bash "$RUN_KEEPER" 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then ok "missing ZRCL_ADDRESS: exit non-zero"; else fail "missing ZRCL_ADDRESS: exit was 0"; fi
if [ ! -s "$STUB_LOG" ]; then ok "missing ZRCL_ADDRESS: no step ran (no silent fixture mode)"; else fail "missing ZRCL_ADDRESS: a step ran anyway ($(cat "$STUB_LOG"))"; fi
case "$OUTPUT" in
  *ZRCL_ADDRESS*) ok "missing ZRCL_ADDRESS: error message names the var" ;;
  *) fail "missing ZRCL_ADDRESS: error message doesn't name the var: $OUTPUT" ;;
esac

# --- Test 1c (Minor 8): keeper key == a deployer key refuses to start -------
# Same key, different spelling (0x prefix and case) must still be caught.
for DEPLOYER_VAR in DEPLOYER_PRIVATE_KEY L1_DEPLOYER_PRIVATE_KEY; do
  new_state
  run_keeper KEEPER_L1_PRIVATE_KEY=0xDEADbeef00112233 "$DEPLOYER_VAR=deadBEEF00112233"
  if [ "$STATUS" -ne 0 ]; then ok "keeper key == $DEPLOYER_VAR: exit non-zero"; else fail "keeper key == $DEPLOYER_VAR: exit was 0"; fi
  if [ ! -s "$STUB_LOG" ]; then ok "keeper key == $DEPLOYER_VAR: no step ran"; else fail "keeper key == $DEPLOYER_VAR: a step ran anyway"; fi
  LOWER_OUTPUT="${OUTPUT,,}"
  case "$LOWER_OUTPUT" in
    *deadbeef00112233*) fail "keeper key == $DEPLOYER_VAR: the key value was echoed" ;;
    *) ok "keeper key == $DEPLOYER_VAR: the key value was not echoed" ;;
  esac
  case "$OUTPUT" in
    *"$DEPLOYER_VAR"*) ok "keeper key == $DEPLOYER_VAR: error names the var" ;;
    *) fail "keeper key == $DEPLOYER_VAR: error doesn't name the var: $OUTPUT" ;;
  esac
done

# --- Test 1d: a DIFFERENT deployer key set alongside does not block ---------
new_state
run_keeper DEPLOYER_PRIVATE_KEY=0xdeployer L1_DEPLOYER_PRIVATE_KEY=0xdeployer STUB_FLUSH_TX=""
if [ "$STATUS" -eq 0 ]; then ok "distinct deployer key: runs (exit 0)"; else fail "distinct deployer key: exit was $STATUS"; fi

# --- Test 2: idle scenario (no FLUSH_TX) -> relay idle, overall exit 0 ------
new_state
run_keeper STUB_FLUSH_TX=""
if [ "$STATUS" -eq 0 ]; then ok "idle run: exit 0"; else fail "idle run: exit was $STATUS"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,convert,cushion," ]; then
  ok "idle run: claim skipped, remaining steps in order ($SEQ)"
else
  fail "idle run: unexpected step sequence ($SEQ)"
fi
if summary_has "relay: ok (idle: nothing to relay)"; then ok "idle run: relay summary is idle"; else fail "idle run: relay summary line missing: $OUTPUT"; fi

# --- Test 3: full run (FLUSH_TX present) -> step order + FLUSH_TX in claim's args
new_state
run_keeper STUB_FLUSH_TX=0xabc123flushtx
if [ "$STATUS" -eq 0 ]; then ok "full run: exit 0"; else fail "full run: exit was $STATUS"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,claim,convert,cushion," ]; then
  ok "full run: step order ($SEQ)"
else
  fail "full run: unexpected step sequence ($SEQ)"
fi
CLAIM_ARGS=$(claim_args)
case "$CLAIM_ARGS" in
  *"--tx 0xabc123flushtx"*) ok "full run: FLUSH_TX reached claim's --tx argument" ;;
  *) fail "full run: claim args did not carry FLUSH_TX (got: $CLAIM_ARGS)" ;;
esac
case "$CLAIM_ARGS" in
  *"claim:fees"*) ok "full run: claim step invokes claim:fees" ;;
  *) fail "full run: claim step did not invoke claim:fees (got: $CLAIM_ARGS)" ;;
esac
if pending_has 0xabc123flushtx; then fail "full run: relayed hash left pending"; else ok "full run: relayed hash not left pending"; fi

# --- Test 4: one failing step (convert) -> exit 1, later step (cushion) still runs
new_state
run_keeper STUB_FLUSH_TX=0xabc123flushtx STUB_CONVERT_EXIT=1
if [ "$STATUS" -ne 0 ]; then ok "one failing step: overall exit non-zero"; else fail "one failing step: overall exit was 0"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,claim,convert,cushion," ]; then
  ok "one failing step: every step still ran, in order ($SEQ)"
else
  fail "one failing step: unexpected step sequence ($SEQ)"
fi

# --- Test 5: an earlier failure (sweep) does not stop later steps either ---
new_state
run_keeper STUB_SWEEP_EXIT=1 STUB_FLUSH_TX=""
if [ "$STATUS" -ne 0 ]; then ok "sweep fails: overall exit non-zero"; else fail "sweep fails: overall exit was 0"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,convert,cushion," ]; then
  ok "sweep fails: later steps still ran ($SEQ)"
else
  fail "sweep fails: unexpected step sequence ($SEQ)"
fi

# --- Test 6 (Important 2): a pending hash survives a failed claim ----------
new_state
run_keeper STUB_FLUSH_TX=0xaaa111 STUB_CLAIM_EXIT=1
if [ "$STATUS" -ne 0 ]; then ok "failed claim: overall exit non-zero"; else fail "failed claim: overall exit was 0"; fi
if pending_has 0xaaa111; then ok "failed claim: flush hash kept in $PENDING"; else fail "failed claim: flush hash NOT persisted as pending"; fi
if summary_has "relay: FAILED"; then ok "failed claim: relay summary is FAILED"; else fail "failed claim: relay summary not FAILED: $OUTPUT"; fi

# --- Test 7 (Important 2): ... and is retried and cleared on the next run --
# Same STATE_DIR; this run's flush has nothing new.
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=0
if [ "$STATUS" -eq 0 ]; then ok "retry run: exit 0"; else fail "retry run: exit was $STATUS"; fi
CLAIM_ARGS=$(claim_args)
case "$CLAIM_ARGS" in
  *"--tx 0xaaa111"*) ok "retry run: pending hash retried via claim:fees --tx" ;;
  *) fail "retry run: pending hash not retried (claim args: $CLAIM_ARGS)" ;;
esac
if pending_has 0xaaa111; then fail "retry run: hash still pending after a successful claim"; else ok "retry run: hash cleared after a successful claim"; fi
if summary_has "relay: ok (1 relayed)"; then ok "retry run: relay summary counts the retried hash"; else fail "retry run: relay summary wrong: $OUTPUT"; fi

# --- Test 8 (Important 2): a flush failure is never reported as a relay ok --
new_state
run_keeper STUB_FLUSH_EXIT=1 STUB_FLUSH_TX=""
if [ "$STATUS" -ne 0 ]; then ok "flush fails: overall exit non-zero"; else fail "flush fails: overall exit was 0"; fi
if summary_has "relay: skipped (flush failed)"; then ok "flush fails: relay recorded as skipped (flush failed)"; else fail "flush fails: relay not recorded as skipped (flush failed): $OUTPUT"; fi
if summary_has "relay: ok"; then fail "flush fails: relay reported ok"; else ok "flush fails: relay not reported ok"; fi

# --- Test 9: a flush failure still retries an OLDER pending hash -----------
new_state
pending_seed 0xbbb222 0
run_keeper STUB_FLUSH_EXIT=1 STUB_FLUSH_TX=""
CLAIM_ARGS=$(claim_args)
case "$CLAIM_ARGS" in
  *"--tx 0xbbb222"*) ok "flush fails + older pending: pending hash still retried" ;;
  *) fail "flush fails + older pending: pending hash not retried (claim args: $CLAIM_ARGS)" ;;
esac
if pending_has 0xbbb222; then fail "flush fails + older pending: hash not cleared"; else ok "flush fails + older pending: hash cleared"; fi

# --- Test 10: several pending hashes, oldest first, a new one deduplicated --
new_state
pending_seed 0xold001 0
pending_seed 0xnew002 0
run_keeper STUB_FLUSH_TX=0xnew002
N_CLAIMS=$(claim_lines | awk 'END{print NR}')
if [ "$N_CLAIMS" -eq 2 ]; then ok "multi pending: one claim per distinct hash ($N_CLAIMS)"; else fail "multi pending: expected 2 claims, got $N_CLAIMS"; fi
FIRST=$(claim_args)
case "$FIRST" in
  *"--tx 0xold001"*) ok "multi pending: oldest hash relayed first" ;;
  *) fail "multi pending: oldest hash not first (got: $FIRST)" ;;
esac
if [ -s "$PENDING" ]; then fail "multi pending: pending file not emptied ($(cat "$PENDING"))"; else ok "multi pending: pending file emptied"; fi

# --- Test 11: the state dir is created when missing ------------------------
STATE_DIR="$STATE_ROOT/created/by/keeper"
PENDING="$STATE_DIR/pending-flush"
run_keeper STUB_FLUSH_TX=0xccc333 STUB_CLAIM_EXIT=1
if [ -d "$STATE_DIR" ]; then ok "state dir: created when missing"; else fail "state dir: not created"; fi
if pending_has 0xccc333; then ok "state dir: pending hash written into it"; else fail "state dir: pending hash missing"; fi

# --- Test 12 (Important 2): the claim wait budget reaches claim:fees -------
new_state
run_keeper STUB_FLUSH_TX=0xddd444
case "$(claim_lines)" in
  *"WAIT=5400 "*) ok "claim wait: default budget 5400 s passed as CLAIM_WITNESS_TIMEOUT_SECS" ;;
  *) fail "claim wait: default budget not passed ($(claim_lines))" ;;
esac
new_state
run_keeper STUB_FLUSH_TX=0xddd444 KEEPER_CLAIM_WAIT_SECS=7000
case "$(claim_lines)" in
  *"WAIT=7000 "*) ok "claim wait: KEEPER_CLAIM_WAIT_SECS overrides the budget" ;;
  *) fail "claim wait: KEEPER_CLAIM_WAIT_SECS not honoured ($(claim_lines))" ;;
esac

# --- Test 13 (T12 batch C): sweep and flush run their v1-l2 scripts through
# `npx tsx` FROM V1_L2_DIR. v1-l2 has no tsx dependency (every v1-l2 package
# script uses `npx tsx`), so `yarn tsx` fails before the script runs, and the
# scripts resolve deployment.json against their cwd.
new_state
run_keeper STUB_FLUSH_TX=0xeee555
for S in sweep flush; do
  L=$(while IFS= read -r line; do case "$line" in "STEP=$S "*) echo "$line" ;; esac; done < "$STUB_LOG")
  case "$L" in
    *"TOOL=npx CWD=$FAKE_L2 "*) ok "$S: runs via npx tsx from V1_L2_DIR" ;;
    *) fail "$S: not run via npx tsx from V1_L2_DIR (got: ${L:-nothing})" ;;
  esac
done
case "$(while IFS= read -r line; do case "$line" in "STEP=sweep "*) echo "$line" ;; esac; done < "$STUB_LOG")" in
  *"tsx scripts/sweep-fees.ts --all"*) ok "sweep: still operator mode, --all" ;;
  *) fail "sweep: --all not passed" ;;
esac

# --- Test 14 (ZER-13 / Db-R19): an overlapping run refuses to start --------
# Two keeper runs (a manual one during a timer-triggered one) each read
# pending-flush, each rewrite it, and the last `mv -f` wins — silently dropping
# an in-flight relay's hash. flock -n makes the second run fail fast and loud.
new_state
pending_seed 0xlocked111 0
BEFORE=$(cat "$PENDING")
exec 8>"$STATE_DIR/lock"
if flock -n 8; then
  run_keeper STUB_FLUSH_TX=0xlocked222
  if [ "$STATUS" -ne 0 ]; then ok "lock held: exit non-zero"; else fail "lock held: exit was 0"; fi
  if [ ! -s "$STUB_LOG" ]; then ok "lock held: no step ran"; else fail "lock held: a step ran anyway ($(cat "$STUB_LOG"))"; fi
  if summary_has "Another keeper run holds the lock"; then ok "lock held: names the lock as the reason"; else fail "lock held: no lock message: $OUTPUT"; fi
  if [ "$(cat "$PENDING")" = "$BEFORE" ]; then ok "lock held: pending-flush left untouched"; else fail "lock held: pending-flush was rewritten ($(cat "$PENDING"))"; fi
  exec 8>&-
  run_keeper STUB_FLUSH_TX=0xlocked222
  if [ "$STATUS" -eq 0 ]; then ok "lock released: the next run proceeds"; else fail "lock released: exit was $STATUS"; fi
else
  fail "test 14 setup: could not take $STATE_DIR/lock first"
  exec 8>&-
fi

# --- Test 15 (ZER-13): a hash past the proof window is EXPIRED, not retried -
# The node serves L2->L1 message proofs for roughly 2 h. Past that a hash can
# never be claimed, so retrying it costs a full KEEPER_CLAIM_WAIT_SECS every
# run and reports FAILED forever, hiding any NEW failure behind the noise.
new_state
pending_seed 0xstale001 10000
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
if [ -z "$(claim_args)" ]; then ok "stale pending: expired hash never retried"; else fail "stale pending: expired hash was retried ($(claim_args))"; fi
if pending_has 0xstale001; then fail "stale pending: expired hash still in the pending file"; else ok "stale pending: expired hash dropped from the pending file"; fi
if summary_has "EXPIRED"; then ok "stale pending: reported as EXPIRED"; else fail "stale pending: no EXPIRED report: $OUTPUT"; fi
if summary_has "relay: FAILED"; then fail "stale pending: expiry counted as an ordinary relay failure"; else ok "stale pending: expiry not counted as a relay failure"; fi
if [ "$STATUS" -eq 0 ]; then ok "stale pending: overall exit 0 (nothing genuinely failed)"; else fail "stale pending: overall exit was $STATUS"; fi
# Exit 0 is the plan's ruling, but the summary must not call permanent,
# unrecoverable value loss "ok" -- that line is the only signal an operator gets.
if summary_has "relay: ok"; then fail "stale pending: permanent loss reported as a plain 'ok'"; else ok "stale pending: permanent loss not reported as a plain 'ok'"; fi

# --- Test 16 (ZER-13): a fresh hash alongside a stale one still fails loudly
new_state
pending_seed 0xstale002 10000
pending_seed 0xfresh002 0
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
CLAIM_ARGS=$(claim_args)
case "$CLAIM_ARGS" in
  *"--tx 0xfresh002"*) ok "mixed pending: the fresh hash is still retried" ;;
  *) fail "mixed pending: fresh hash not retried (claim args: $CLAIM_ARGS)" ;;
esac
if [ "$(claim_lines | awk 'END{print NR}')" -eq 1 ]; then ok "mixed pending: only the fresh hash is claimed"; else fail "mixed pending: expected 1 claim, got $(claim_lines | awk 'END{print NR}')"; fi
if pending_has 0xstale002; then fail "mixed pending: stale hash kept"; else ok "mixed pending: stale hash dropped"; fi
if pending_has 0xfresh002; then ok "mixed pending: fresh hash kept for the next run"; else fail "mixed pending: fresh hash lost"; fi
if summary_has "relay: FAILED"; then ok "mixed pending: the fresh failure is still reported FAILED"; else fail "mixed pending: fresh failure not reported: $OUTPUT"; fi

# --- Test 17 (ZER-13): a legacy bare-hash line has unknown age -> expired ---
# The pre-ZER-13 format carried no timestamp. Treating it as fresh would keep
# an unclaimable hash alive forever; expiring it forces a clean migration.
new_state
echo 0xlegacy001 > "$PENDING"
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
if [ -z "$(claim_args)" ]; then ok "legacy line: not retried"; else fail "legacy line: retried anyway ($(claim_args))"; fi
if pending_has 0xlegacy001; then fail "legacy line: still in the pending file"; else ok "legacy line: dropped from the pending file"; fi
if summary_has "EXPIRED"; then ok "legacy line: reported as EXPIRED"; else fail "legacy line: no EXPIRED report: $OUTPUT"; fi

# --- Test 18 (ZER-13): PENDING_FLUSH_MAX_AGE_SECS widens the window --------
# The window tracks the node's proof-serving retention, which is infra config
# (WS_NUM_HISTORIC_CHECKPOINTS), not a constant of this repo.
new_state
pending_seed 0xwide001 10000
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1 PENDING_FLUSH_MAX_AGE_SECS=86400
case "$(claim_args)" in
  *"--tx 0xwide001"*) ok "max-age override: a hash inside the widened window is retried" ;;
  *) fail "max-age override: hash not retried (claim args: $(claim_args))" ;;
esac
if pending_has 0xwide001; then ok "max-age override: hash kept pending"; else fail "max-age override: hash dropped despite the override"; fi

# --- Test 19 (ZER-13): a new FLUSH_TX is recorded as "<hash>,<epoch>" ------
new_state
run_keeper STUB_FLUSH_TX=0xfmt999 STUB_CLAIM_EXIT=1
LINE=$(head -n 1 "$PENDING")
case "$LINE" in
  0xfmt999,[0-9]*) ok "pending format: recorded as hash,epoch" ;;
  *) fail "pending format: expected '0xfmt999,<epoch>', got '$LINE'" ;;
esac

# --- Test 20 (ZER-13): a hash that stays pending keeps its ORIGINAL epoch ---
# Stamping it afresh on every rewrite would push the expiry window out of
# reach and restore the retry-forever behaviour Test 15 fixes.
new_state
SEED_TS=$(( $(date +%s) - 7000 ))
printf '%s,%s\n' 0xkeepts "$SEED_TS" > "$PENDING"
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
if [ "$(cat "$PENDING")" = "0xkeepts,$SEED_TS" ]; then
  ok "pending timestamp: preserved across a failed retry"
else
  fail "pending timestamp: rewritten (expected '0xkeepts,$SEED_TS', got '$(cat "$PENDING")')"
fi

# --- Test 21 (ZER-13): the lock is HELD for the whole run, and not leaked ---
new_state
run_keeper STUB_FLUSH_TX=0xheld001 STUB_LOCK_FILE="$STATE_DIR/lock"
case "$(claim_lines)" in
  *"LOCK=held"*) ok "lock lifetime: still held while the relay step runs" ;;
  *) fail "lock lifetime: not held during the relay step ($(claim_lines))" ;;
esac
case "$(claim_lines)" in
  *"FD9=closed"*) ok "lock fd: closed in children, so it cannot outlive the run" ;;
  *) fail "lock fd: inherited by the child -- an outliving process would keep the lock ($(claim_lines))" ;;
esac

# --- Test 22 (ZER-13): a corrupt pending line cannot derail the relay step --
# pending-flush outlives upgrades and the header invites an operator to read
# and edit it during manual recovery. The leading-zero stamp is the dangerous
# shape: bash reads it as OCTAL, an invalid octal literal is a FATAL
# arithmetic error, and that aborts the whole relay block -- skipping
# write_pending and every summary line, so the run reports "all steps ok" with
# exit 0 while relaying nothing, on this run and every run after it. Each
# shape below must land on the "unknown age -> expired" path instead.
for BAD in '0xoct001,0123456789' '0xbig002,99999999999999999999999' '0xtwo003,123,456' '0xnots004,' '0xjunk005,not-a-number'; do
  new_state
  printf '%s\n' "$BAD" > "$PENDING"
  run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
  BADHASH="${BAD%%,*}"
  if summary_has "relay:"; then ok "corrupt '$BAD': the relay step still reports a summary line"; else fail "corrupt '$BAD': the relay step vanished from the summary: $OUTPUT"; fi
  if pending_has "$BADHASH"; then fail "corrupt '$BAD': the poisoned line survived in $PENDING"; else ok "corrupt '$BAD': poisoned line dropped"; fi
  if [ -z "$(claim_args)" ]; then ok "corrupt '$BAD': never retried"; else fail "corrupt '$BAD': retried anyway ($(claim_args))"; fi
  if [ "$STATUS" -eq 0 ]; then ok "corrupt '$BAD': exit 0 (an expiry is not a step failure)"; else fail "corrupt '$BAD': exit was $STATUS"; fi
done

# --- Test 23 (ZER-13): a stamp in the future is clock skew, not freshness ---
# A clock that steps backwards must not make an entry immortal -- but must not
# throw away value that is still perfectly claimable either.
new_state
printf '%s,%s\n' 0xfuture001 "$(( $(date +%s) + 60 ))" > "$PENDING"
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
case "$(claim_args)" in
  *"--tx 0xfuture001"*) ok "future stamp (small skew): still retried, value not discarded" ;;
  *) fail "future stamp (small skew): dropped instead of retried ($(claim_args))" ;;
esac
if summary_has "WARNING"; then ok "future stamp (small skew): the clock skew is reported"; else fail "future stamp (small skew): skew not reported: $OUTPUT"; fi

new_state
printf '%s,%s\n' 0xfuture002 "$(( $(date +%s) + 100000 ))" > "$PENDING"
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
if pending_has 0xfuture002; then fail "future stamp (absurd): kept, so it would never expire"; else ok "future stamp (absurd): dropped as untrustworthy"; fi
if [ -z "$(claim_args)" ]; then ok "future stamp (absurd): never retried"; else fail "future stamp (absurd): retried anyway ($(claim_args))"; fi

# --- Test 24 (ZER-13): the claim wait never outlives the proof window ------
# Waiting the full 5400 s for a proof that stops being served in ~200 s is
# exactly the wasted wait tracking an age was meant to bound.
new_state
pending_seed 0xclamp001 7000
run_keeper STUB_FLUSH_TX="" STUB_CLAIM_EXIT=1
WAITVAL=$(claim_lines | sed -n 's/.*WAIT=\([0-9]*\) .*/\1/p' | head -n 1)
if [ -n "$WAITVAL" ] && [ "$WAITVAL" -ge 150 ] && [ "$WAITVAL" -le 200 ]; then
  ok "claim wait: clamped to the ~200s left in the proof window (got ${WAITVAL}s)"
else
  fail "claim wait: not clamped to the remaining window (got '${WAITVAL:-none}', expected ~200)"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "run-keeper.test.sh: $FAILURES assertion(s) FAILED"
  exit 1
fi
echo "run-keeper.test.sh: all assertions ok"
