#!/usr/bin/env bash
# TDD RED/GREEN coverage for lib/keeper/run-keeper.sh (D-b, Db-10). Puts stub
# yarn/node binaries on PATH and drives run-keeper.sh through:
#   - the step order (sweep -> flush -> claim -> convert -> cushion)
#   - a missing KEEPER_L1_PRIVATE_KEY exiting non-zero before any step runs
#   - idle steps (no FLUSH_TX) still giving an overall exit 0
#   - one failing step giving exit 1 while every later step still runs
#   - FLUSH_TX printed by flush reaching the claim step's --tx argument
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RUN_KEEPER="$HERE/../keeper/run-keeper.sh"
STUB_BIN=$(mktemp -d)
STUB_LOG=$(mktemp)
export STUB_LOG # the stub yarn/node binaries below run as SEPARATE processes
                # (found via PATH from inside run-keeper.sh) and need this
                # in their own environment, not just this script's shell.
trap 'rm -rf "$STUB_BIN" "$STUB_LOG"' EXIT

# --- stub yarn: records "STEP=<name> ARGS=<argv>" for every invocation it
# recognizes, and fakes each script's exit code / stdout via STUB_* env vars
# the test sets per-scenario. Recognizes invocations by substring so it does
# not need to track flag order.
cat > "$STUB_BIN/yarn" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
LINE="yarn $*"
case "$LINE" in
  *"tsx scripts/sweep-fees.ts"*)
    echo "STEP=sweep ARGS=$*" >> "$STUB_LOG"
    exit "${STUB_SWEEP_EXIT:-0}"
    ;;
  *"tsx scripts/flush-fees.ts"*)
    echo "STEP=flush ARGS=$*" >> "$STUB_LOG"
    if [ -n "${STUB_FLUSH_TX:-}" ]; then
      echo "FLUSH_TX=${STUB_FLUSH_TX}"
      echo "FLUSH_BLOCK=42"
    else
      echo "nothing to flush"
    fi
    exit "${STUB_FLUSH_EXIT:-0}"
    ;;
  *"claim:fees"*)
    echo "STEP=claim ARGS=$*" >> "$STUB_LOG"
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

# claim_args: the ARGS=... tail of the (single) STEP=claim log line, or "".
claim_args() {
  local line
  while IFS= read -r line; do
    case "$line" in
      STEP=claim*) echo "${line#*ARGS=}"; return ;;
    esac
  done < "$STUB_LOG"
  echo ""
}

# --- Test 1: missing KEEPER_L1_PRIVATE_KEY exits non-zero, no step runs -----
: > "$STUB_LOG"
set +e
OUTPUT=$(env -u KEEPER_L1_PRIVATE_KEY PATH="$STUB_BIN:$PATH" V1_L2_DIR=/fake/v1-l2 \
  bash "$RUN_KEEPER" 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then ok "missing KEEPER_L1_PRIVATE_KEY: exit non-zero"; else fail "missing KEEPER_L1_PRIVATE_KEY: exit was 0"; fi
if [ ! -s "$STUB_LOG" ]; then ok "missing KEEPER_L1_PRIVATE_KEY: no step ran"; else fail "missing KEEPER_L1_PRIVATE_KEY: a step ran anyway ($(cat "$STUB_LOG"))"; fi
case "$OUTPUT" in
  *KEEPER_L1_PRIVATE_KEY*) ok "missing KEEPER_L1_PRIVATE_KEY: error message names the var" ;;
  *) fail "missing KEEPER_L1_PRIVATE_KEY: error message doesn't name the var: $OUTPUT" ;;
esac

# --- Test 2: idle scenario (no FLUSH_TX) -> claim skipped, overall exit 0 ---
: > "$STUB_LOG"
set +e
env PATH="$STUB_BIN:$PATH" V1_L2_DIR=/fake/v1-l2 KEEPER_L1_PRIVATE_KEY=0xkeeper \
  STUB_FLUSH_TX="" \
  bash "$RUN_KEEPER" > /dev/null 2>&1
STATUS=$?
set -e
if [ "$STATUS" -eq 0 ]; then ok "idle run: exit 0"; else fail "idle run: exit was $STATUS"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,convert,cushion," ]; then
  ok "idle run: claim skipped, remaining steps in order ($SEQ)"
else
  fail "idle run: unexpected step sequence ($SEQ)"
fi

# --- Test 3: full run (FLUSH_TX present) -> step order + FLUSH_TX in claim's args
: > "$STUB_LOG"
set +e
env PATH="$STUB_BIN:$PATH" V1_L2_DIR=/fake/v1-l2 KEEPER_L1_PRIVATE_KEY=0xkeeper \
  STUB_FLUSH_TX=0xabc123flushtx \
  bash "$RUN_KEEPER" > /dev/null 2>&1
STATUS=$?
set -e
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

# --- Test 4: one failing step (convert) -> exit 1, later step (cushion) still runs
: > "$STUB_LOG"
set +e
env PATH="$STUB_BIN:$PATH" V1_L2_DIR=/fake/v1-l2 KEEPER_L1_PRIVATE_KEY=0xkeeper \
  STUB_FLUSH_TX=0xabc123flushtx STUB_CONVERT_EXIT=1 \
  bash "$RUN_KEEPER" > /dev/null 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then ok "one failing step: overall exit non-zero"; else fail "one failing step: overall exit was 0"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,claim,convert,cushion," ]; then
  ok "one failing step: every step still ran, in order ($SEQ)"
else
  fail "one failing step: unexpected step sequence ($SEQ)"
fi

# --- Test 5: an earlier failure (sweep) does not stop later steps either ---
: > "$STUB_LOG"
set +e
env PATH="$STUB_BIN:$PATH" V1_L2_DIR=/fake/v1-l2 KEEPER_L1_PRIVATE_KEY=0xkeeper \
  STUB_SWEEP_EXIT=1 STUB_FLUSH_TX="" \
  bash "$RUN_KEEPER" > /dev/null 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then ok "sweep fails: overall exit non-zero"; else fail "sweep fails: overall exit was 0"; fi
SEQ=$(steps_seen)
if [ "$SEQ" = "sweep,flush,convert,cushion," ]; then
  ok "sweep fails: later steps still ran ($SEQ)"
else
  fail "sweep fails: unexpected step sequence ($SEQ)"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "run-keeper.test.sh: $FAILURES assertion(s) FAILED"
  exit 1
fi
echo "run-keeper.test.sh: all assertions ok"
