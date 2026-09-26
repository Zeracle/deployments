#!/usr/bin/env bash
# D-b keeper: sweep -> flush -> relay (claim+retire) -> convert -> cushion.
#
# Runs on its own low-value L1 key (KEEPER_L1_PRIVATE_KEY), OUTSIDE
# chain-server (chain-server is not part of testnet — see
# feedback_chain_server_not_on_testnet). Installed on a schedule via the
# zeracle-keeper.service/.timer units in this directory; this script
# itself is invoked directly and is never gated on any network flag.
#
# Sequence (Db-10): sweep (operator mode, everything) -> flush (parses
# FLUSH_TX) -> relay every pending flush tx (claim+retire) -> convert ->
# cushion. Every step runs regardless of an earlier step's outcome — the
# summary at the end is what tells the operator (or the systemd unit's exit
# code) whether anything genuinely failed.
#
# skim() is deliberately NOT a step (ZER-18, owner decision 2026-09-24).
# LiquidityPool.skim() sells the most-overweight leg for the fee token and
# sends the proceeds to the CollateralReserve when NAV is ABOVE its high-water
# mark — the opposite of cushion(). When ZER-18 was decided it could not
# succeed anywhere, for three independent reasons (v1-l1):
#   1. No router was whitelisted (skim() reverts RouterNotWhitelisted).
#   2. The high-water mark was never armed (hwmPerShare == 0), so excessUsd()
#      is always 0 and skim() reverts BelowSkimFloor even with a router.
#   3. setSkimParams was never called, so skimMaxSlippageBps is 0 and any swap
#      with fees or price impact reverts SkimSlippageTooHigh.
# ZER-31 closes all three on a FRESH deploy: DeployLocal.s.sol calls
# initialiseHwm(), setSkimRouter(MockDexAggregator, true) and
# setSkimParams(1 days, 100e18, 100). A chain deployed before that (the Pi,
# measured 2026-09-26: hwmPerShare 0, all skim params 0,
# skimRouters(MockDexAggregator) false) stays unarmed until the owner runs
# v1-l1 `make arm-capped-nav`, which goes through GovernanceAuthority.execute
# (a timelock batch once the admin phase has ended).
# Adding skim() here is still an owner call: revisit ZER-18, together with
# FeeConverter's router, which ZER-18 deferred for the same reason. MockDexAggregator's
# swap() (pull tokenIn from caller, mint tokenOut to caller) is compatible with
# skim()'s balance-delta check, provided swapData calls its
# swap(address,address,uint256,uint256,bytes) selector directly (its fallback
# re-enters as itself, so the pool gets nothing).
#
# Pending relays (final review Important 2): a flush's L2->L1 messages can
# only be relayed once its epoch is proven on L1, which on testnet often
# takes longer than one claim wait. So every FLUSH_TX is appended to
# $KEEPER_STATE_DIR/pending-flush BEFORE the relay runs, and every run
# retries each pending hash with `claim:fees --tx <hash>`, removing a hash
# only once its claim exits 0. A failed claim keeps the hash and fails the
# relay step. ZER-13 assumed the node serves message proofs for roughly 2 h
# only, so that the in-run wait (KEEPER_CLAIM_WAIT_SECS) is what covers slow
# proving and the cross-run retry only helps inside that window. Measured on
# Aztec 5.2.0 that window does not exist (see MEASURED below).
#
# Expiry (ZER-13): under that assumed ~2 h window, a hash whose epoch has
# been pruned from the node's world state could NEVER be claimed again. Retrying
# it forever costs a full KEEPER_CLAIM_WAIT_SECS per run and reports the relay
# step FAILED every time, which buries any genuinely new failure. So each
# pending line carries the epoch second it was recorded
# ("<l2 flush tx hash>,<unix epoch seconds>"), and a line older than
# PENDING_FLUSH_MAX_AGE_SECS is dropped with an EXPIRED log line instead of
# being retried. Expiry is NOT counted as a relay failure.
#
# MEASURED 2026-09-25 (ZER-16, see README.md in this directory): on Aztec
# 5.2.0 the ~2 h window above does NOT hold. The node builds the witness from
# the archiver's blocks plus the L1 Outbox roots, not from pruned world state,
# and served one for a 14.7 h-old message on the Pi. The Pi therefore raises
# PENDING_FLUSH_MAX_AGE_SECS to 30 days. The 7200 default stays until ZER-19
# checks a public node, whose archiver may be configured differently.
#
# An EXPIRED hash needs MANUAL, OWNER-SIDE RECOVERY — this script cannot fix
# it and does not pretend to. The L2->L1 message itself still sits unconsumed
# in the L1 Outbox, but the merkle proof a claim needs is derived from node
# state that has been pruned, so re-deriving it means replaying the relevant
# L2 history on an archive node. That work is deliberately out of scope here;
# the log line exists so the value is never silently written off.
#
# UPGRADING to this version: a pending-flush written by an older keeper has no
# timestamps at all, so the FIRST run after the upgrade expires every line in
# it — including one flushed minutes ago that is still perfectly claimable.
# Before upgrading a box, read $KEEPER_STATE_DIR/pending-flush and relay
# anything in it by hand (`yarn --cwd <v1-l2> claim:fees --tx <hash>`). An
# empty or absent file needs nothing. This is deliberate: the alternative,
# assuming an undated hash is fresh, is what keeps an unclaimable hash being
# retried forever, and that is the bug this change exists to kill.
#
# Concurrency (ZER-13, Db-R19): the pending file is read once up front and
# rewritten after the relay, so two overlapping runs (say a manual run during
# a timer-triggered one) would each read the same list and the last `mv -f`
# would silently drop the other's update — including an in-flight relay's
# hash. Every run therefore takes an exclusive, NON-BLOCKING flock on
# $KEEPER_STATE_DIR/lock and aborts immediately if another run holds it.
# Non-blocking on purpose: a queued run could sit behind a relay holding the
# lock for KEEPER_CLAIM_WAIT_SECS and only fire after the timer's next
# interval, so failing fast and loud is the better operator experience.
#
# The lock lives on the open file descriptor (fd 9), not on this process, so
# any child that inherited fd 9 would keep holding it after this script exits
# — and the next run would report a live overlap that does not exist. Every
# child is therefore started with fd 9 closed (`9>&-`).
#
# Env (required):
#   KEEPER_L1_PRIVATE_KEY  - a SEPARATE, low-value L1 key. NEVER the
#                            deployer key: this script refuses to start if it
#                            equals DEPLOYER_PRIVATE_KEY or
#                            L1_DEPLOYER_PRIVATE_KEY (when either is set;
#                            compared without echoing either value). There is
#                            no fallback to any deployer key anywhere —
#                            L1_CLAIMER_PRIVATE_KEY is set from this var
#                            explicitly, only for the relay, so
#                            claim-fees-l1.ts's own deployer-key fallback
#                            chain is never reached.
#   V1_L2_DIR              - path to the v1-l2 checkout. Every script runs
#                            with it as cwd (`yarn --cwd` for the package
#                            scripts; `cd` + `npx tsx` for sweep and flush,
#                            see v1l2_tsx below), so the default
#                            deployment.json is $V1_L2_DIR/deployment.json and
#                            the default L1 deployment files live in
#                            $V1_L2_DIR/../v1-l1/deployments/.
#                            Under the zeracle-keeper.service unit, `npx`
#                            must ALSO resolve on the unit's Environment=PATH=
#                            line, same as `yarn` -- sweep and flush now run
#                            through `npx tsx` (v1l2_tsx below), not `yarn
#                            tsx`, since v1-l2 has no `tsx` dependency of its
#                            own.
#   ZRCL_ADDRESS           - the deployed ZeracleToken. Required: without it
#                            sweep-fees.ts and flush-fees.ts silently fall
#                            into FIXTURE mode (test/fixtures/*).
#
# Env (optional, keeper):
#   KEEPER_STATE_DIR       - default /var/lib/zeracle-keeper (created if
#                            missing; the service unit's StateDirectory=
#                            creates it too). Holds `pending-flush` — one
#                            "<l2 flush tx hash>,<unix epoch seconds>" line per
#                            pending relay — and `lock`, the flock file that
#                            keeps two runs from overlapping.
#   KEEPER_CLAIM_WAIT_SECS - default 5400 (90 min, inside the assumed ~2 h
#                            proof window; the Pi sets 1800). Passed to claim-fees-l1.ts as
#                            CLAIM_WITNESS_TIMEOUT_SECS, per pending hash.
#   PENDING_FLUSH_MAX_AGE_SECS
#                          - default 7200 (the ~2 h ZER-13 assumed the node
#                            serves L2->L1 proofs for; the Pi sets 30 days). A pending line older than
#                            this is EXPIRED and dropped, not retried. This
#                            tracks the NODE's world-state retention
#                            (WS_NUM_HISTORIC_CHECKPOINTS, default 64), which
#                            is infra config — hence an override rather than a
#                            constant. Raise it only if the node you relay
#                            against genuinely keeps more history.
#
# Env contract (final review Important 3), passed through unmodified to the
# v1-l2 scripts — see each script's header for the full defaults:
#   L2 side (sweep, flush, relay):
#     AZTEC_RPC_HOST              - Aztec node RPC (default http://localhost:8080)
#     FEE_DISTRIBUTION_ADDRESS    - default: deployment.json contracts.feeDistribution
#     FEE_CUSTODIAN_ACCOUNT_FILE  - testnet: a copy of the custodian key file
#                                   deploy.ts wrote (deployments/testnet/
#                                   fee-custodian-account.json); deployment.json
#                                   must record the matching `feeCustodian`.
#                                   Unset on the sandbox (genesis test account
#                                   [1]). The custodian needs NO on-chain
#                                   deployment: it is an initializerless
#                                   account, so sweep sends from it directly
#                                   and pays through the sponsored FPC.
#     L1_TOKEN_PORTAL             - relay; default deployment.json l1.tokenPortal
#   L1 side (relay, convert, cushion):
#     L1_RPC_URL (or ETH_RPC_URL) - default http://localhost:8545
#     ETH_CHAIN_ID                - convert and cushion build their chain from
#                                   the RPC's own chain id and only refuse an
#                                   ETH_CHAIN_ID that disagrees with it. The
#                                   relay (claim-fees-l1.ts) does the same ONLY
#                                   from ZER-13 onwards — the matching v1-l2
#                                   change ships with this one. Against an
#                                   OLDER v1-l2 checkout the relay still signs
#                                   for foundry (31337) when ETH_CHAIN_ID is
#                                   unset, so keep setting 11155111 on testnet:
#                                   it costs nothing, it is required with an
#                                   older v1-l2, and it catches an RPC pointed
#                                   at the wrong network either way.
#     L1_LIQUIDITY_POOL           - convert + cushion; default `liquidityPoolProxy`
#                                   from ../v1-l1/deployments/local.json (31337)
#                                   or local-testnet.json (11155111), chosen by
#                                   the RPC's chain id
#     L1_MOCK_DEX_AGGREGATOR      - convert; default `mockDexAggregator` from the
#                                   same file
#     L1_TREASURY, L1_COLLATERAL_RESERVE, L1_NETWORK_FUND
#                                 - convert; default deployment.json l1.*
#   No fee-token, quoter or deposit-adapter address is configured: convert
#   reads FeeFund.token() and MockDexAggregator.quoter()/pool() on-chain.
#
# Testnet env block (placeholders; fill in from v1-l2/deployment.json and
# v1-l1/deployments/local-testnet.json):
#   KEEPER_L1_PRIVATE_KEY=<separate, funded, low-value Sepolia key>
#   V1_L2_DIR=/opt/zeracle/v1-l2
#   ZRCL_ADDRESS=<deployment.json contracts.zeracleToken>
#   AZTEC_RPC_HOST=<Aztec testnet node URL>
#   L1_RPC_URL=<Sepolia RPC URL>
#   ETH_CHAIN_ID=11155111
#   FEE_CUSTODIAN_ACCOUNT_FILE=<path to the fee-custodian-account.json copy>
#   KEEPER_STATE_DIR=/var/lib/zeracle-keeper
#   KEEPER_CLAIM_WAIT_SECS=5400
# The L1_* address overrides are optional there when both deployment files
# sit where the defaults expect them.
#
# Sandbox example keeper key (anvil #4 — never #0, the sequencer's key, and
# never #1/#2/#3, the deployer/guardian/governance keys):
#   KEEPER_L1_PRIVATE_KEY=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
#
# This script never echoes KEEPER_L1_PRIVATE_KEY or any other key value.
set -uo pipefail  # NOT -e: every step must run even if an earlier one failed.

if [ -z "${KEEPER_L1_PRIVATE_KEY:-}" ]; then
  echo "KEEPER_L1_PRIVATE_KEY is required (a separate, low-value L1 key —" >&2
  echo "NEVER the deployer key). Aborting before any step runs." >&2
  exit 1
fi

V1_L2_DIR="${V1_L2_DIR:?V1_L2_DIR is required (path to the v1-l2 checkout)}"
: "${ZRCL_ADDRESS:?ZRCL_ADDRESS is required (the deployed ZeracleToken) — without it sweep-fees.ts and flush-fees.ts silently run in FIXTURE mode. Aborting before any step runs.}"

# Final review Minor 8: refuse to run on a deployer key. Keys are compared
# with any 0x prefix and case normalised away, and never printed.
normalize_key() {
  local k="${1#0x}"
  k="${k#0X}"
  printf '%s' "${k,,}"
}
KEEPER_KEY_NORM=$(normalize_key "$KEEPER_L1_PRIVATE_KEY")
for DEPLOYER_KEY_VAR in DEPLOYER_PRIVATE_KEY L1_DEPLOYER_PRIVATE_KEY; do
  if [ -n "${!DEPLOYER_KEY_VAR:-}" ] &&
     [ "$(normalize_key "${!DEPLOYER_KEY_VAR}")" = "$KEEPER_KEY_NORM" ]; then
    echo "KEEPER_L1_PRIVATE_KEY is the same key as $DEPLOYER_KEY_VAR. The keeper must run on its" >&2
    echo "own low-value key, never a deployer key. Aborting before any step runs." >&2
    exit 1
  fi
done
unset KEEPER_KEY_NORM DEPLOYER_KEY_VAR

KEEPER_STATE_DIR="${KEEPER_STATE_DIR:-/var/lib/zeracle-keeper}"
KEEPER_CLAIM_WAIT_SECS="${KEEPER_CLAIM_WAIT_SECS:-5400}"
# ZER-13: how long a pending flush hash can still be claimed — see the
# "Expiry" paragraph in the header for why this tracks node infra config.
PENDING_FLUSH_MAX_AGE_SECS="${PENDING_FLUSH_MAX_AGE_SECS:-7200}"
PENDING_FLUSH_FILE="$KEEPER_STATE_DIR/pending-flush"
if ! mkdir -p "$KEEPER_STATE_DIR"; then
  echo "Cannot create KEEPER_STATE_DIR=$KEEPER_STATE_DIR (pending flush relays live there)." >&2
  echo "Set KEEPER_STATE_DIR to a writable directory. Aborting before any step runs." >&2
  exit 1
fi

# ZER-13 / Db-R19: exactly one keeper run at a time (see "Concurrency" in the
# header). fd 9 stays open for the whole run, and every child below closes it
# (`9>&-`) so the lock cannot outlive this process.
#
# A failure to LOCK and a failure to SET UP the lock are reported differently
# on purpose: telling an operator that "another run holds the lock" when the
# real problem is an unwritable state dir or a missing flock sends them
# hunting a run that does not exist.
if ! command -v flock >/dev/null 2>&1; then
  echo "flock (util-linux) is required to serialise keeper runs, but it is not on PATH." >&2
  echo "Install util-linux, or add its directory to the unit's Environment=PATH=." >&2
  echo "Aborting before any step runs." >&2
  exit 1
fi
if ! exec 9>"$KEEPER_STATE_DIR/lock"; then
  echo "Cannot open the keeper lock file $KEEPER_STATE_DIR/lock for writing." >&2
  echo "Check the owner and mode of KEEPER_STATE_DIR ($KEEPER_STATE_DIR) — systemd's" >&2
  echo "StateDirectory= creates it owned by User=. Aborting before any step runs." >&2
  exit 1
fi
flock -n 9
LOCK_STATUS=$?
if [ "$LOCK_STATUS" -eq 1 ]; then
  echo "Another keeper run holds the lock ($KEEPER_STATE_DIR/lock). Aborting." >&2
  echo "This run has changed nothing. Wait for the running keeper to finish." >&2
  exit 1
elif [ "$LOCK_STATUS" -ne 0 ]; then
  echo "Could not take the keeper lock ($KEEPER_STATE_DIR/lock): flock exited $LOCK_STATUS." >&2
  echo "That is a setup problem, not a second keeper run. Aborting before any step runs." >&2
  exit 1
fi

FAILS=0
SUMMARY=()

step() { echo; echo "=== $* ==="; }
# Summary lines are always "<step>: <status>".
record()      { SUMMARY+=("$1: $2"); }
record_fail() { SUMMARY+=("$1: FAILED${2:+ ($2)}"); FAILS=$((FAILS + 1)); }

# v1l2_tsx <script> [args...]: run a v1-l2 TypeScript script from V1_L2_DIR.
# v1-l2 has no tsx dependency, so `yarn tsx …` fails with 'Command "tsx" not
# found' before the script ever runs (T12 batch C, the first real keeper run).
# Every v1-l2 package script runs through `npx tsx` instead (claim:fees,
# keeper:*), so this does the same. The scripts resolve deployment.json
# against their cwd, hence the cd. The caller's environment passes through.
v1l2_tsx() { (cd "$V1_L2_DIR" && NODE_NO_WARNINGS=1 npx tsx "$@" 9>&-); }

# write_pending <entry>...: atomically replace the pending file's contents.
# Each entry is "<l2 flush tx hash>,<unix epoch seconds>" (ZER-13).
write_pending() {
  local tmp="$PENDING_FLUSH_FILE.tmp"
  if [ "$#" -eq 0 ]; then : > "$tmp"; else printf '%s\n' "$@" > "$tmp"; fi
  mv -f "$tmp" "$PENDING_FLUSH_FILE"
}

# pending_hash <entry>: the tx hash of one pending line.
pending_hash() { printf '%s' "${1%%,*}"; }

# pending_ts <entry>: the epoch seconds of one pending line, or '' when the age
# is UNKNOWN — a pre-ZER-13 line with no comma, or a malformed stamp. Unknown
# age is treated as expired rather than fresh: assuming an unclaimable hash is
# still good is what kept it being retried forever.
#
# This parses UNTRUSTED input. pending-flush survives upgrades and an operator
# is invited to read (and edit) it during manual recovery, so a stamp is
# rejected unless it is a plain decimal epoch:
#   - a LEADING ZERO would be read as OCTAL by the arithmetic below, and an
#     invalid octal literal ("0123456789") is a fatal arithmetic error that
#     aborts the whole relay block — skipping write_pending and every summary
#     line, so the run would report "all steps ok" with exit 0 while silently
#     relaying nothing, on this run and every run after it;
#   - more than 11 digits can overflow the signed 64-bit arithmetic and come
#     back NEGATIVE, which would read as "not yet expired" forever.
pending_ts() {
  local ts
  case "$1" in
    *,*) ts="${1##*,}" ;;
    *) ts="" ;;
  esac
  case "$ts" in
    '' | *[!0-9]* | 0*) ts="" ;;
  esac
  [ "${#ts}" -gt 11 ] && ts=""
  printf '%s' "$ts"
}

# --- 1. sweep (operator mode: ZRCL_ADDRESS from env, sweep everything) ------
step "sweep"
if v1l2_tsx scripts/sweep-fees.ts --all; then
  record "sweep" "ok"
else
  record_fail "sweep"
fi

# --- 2. flush ----------------------------------------------------------------
# Captured (not streamed) so FLUSH_TX can be parsed, then echoed verbatim so
# the operator/journal still sees the full output. pipefail is suspended
# around the capture itself: we want FLUSH_STATUS to be flush-fees.ts's own
# exit code, not a pipeline's.
step "flush"
set +o pipefail
FLUSH_OUTPUT="$(v1l2_tsx scripts/flush-fees.ts 2>&1)"
FLUSH_STATUS=$?
set -o pipefail
echo "$FLUSH_OUTPUT"

FLUSH_TX=""
while IFS= read -r line; do
  case "$line" in
    FLUSH_TX=*) FLUSH_TX="${line#FLUSH_TX=}" ;;
  esac
done <<< "$FLUSH_OUTPUT"

if [ "$FLUSH_STATUS" -eq 0 ]; then
  record "flush" "ok"
else
  record_fail "flush"
fi

# Every pending hash, oldest first; this run's FLUSH_TX is appended (once)
# and persisted BEFORE the relay, so a crash mid-claim still leaves it pending.
PENDING=()
if [ -f "$PENDING_FLUSH_FILE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && PENDING+=("$line")
  done < "$PENDING_FLUSH_FILE"
fi
if [ -n "$FLUSH_TX" ]; then
  ALREADY_PENDING=0
  for entry in ${PENDING[@]+"${PENDING[@]}"}; do
    [ "$(pending_hash "$entry")" = "$FLUSH_TX" ] && ALREADY_PENDING=1
  done
  # Stamped once, when first seen: the age this run measures is the age of the
  # FLUSH, not of the last rewrite (re-stamping would push the expiry window
  # permanently out of reach).
  [ "$ALREADY_PENDING" -eq 0 ] && PENDING+=("$FLUSH_TX,$(date +%s)")
  write_pending "${PENDING[@]}"
fi

# --- 3. relay: claim + retire every pending flush tx --------------------------
# Db-9: each hash goes through claim-fees-l1.ts's real --tx flag (its default
# is "scan only the latest L2 block", which would miss an earlier flush).
# L1_CLAIMER_PRIVATE_KEY is set ONLY for this step, ONLY from
# KEEPER_L1_PRIVATE_KEY — claim-fees-l1.ts's own fallback chain
# (L1_CLAIMER_PRIVATE_KEY -> L1_DEPLOYER_PRIVATE_KEY -> DEPLOYER_PRIVATE_KEY)
# stays as-is, but setting it explicitly here means the keeper never falls
# through to a deployer key.
step "relay (claim + retire)"
if [ "${#PENDING[@]}" -eq 0 ]; then
  if [ "$FLUSH_STATUS" -ne 0 ]; then
    echo "flush failed and nothing is pending -- skipping claim:fees."
    record "relay" "skipped (flush failed)"
  else
    echo "nothing flushed and nothing pending -- nothing to relay."
    record "relay" "ok (idle: nothing to relay)"
  fi
else
  STILL_PENDING=()
  RELAYED=0
  EXPIRED=0
  for entry in "${PENDING[@]}"; do
    hash=$(pending_hash "$entry")
    ts=$(pending_ts "$entry")
    # Re-read the clock per entry: one claim can wait KEEPER_CLAIM_WAIT_SECS
    # (default 90 min), so a reading taken before the loop would judge later
    # entries against an hour-and-a-half-stale "now".
    NOW=$(date +%s)
    # ZER-13: past the proof window this can never succeed — drop it rather
    # than burn a full claim wait on it every run from here on.
    if [ -z "$ts" ]; then
      echo "EXPIRED: flush tx $hash has no usable timestamp (a pre-ZER-13 line, or a malformed one), so" >&2
      echo "         its age cannot be established and it may be past the ~${PENDING_FLUSH_MAX_AGE_SECS}s proof window." >&2
      echo "         Dropping it; recovering its value is a manual, owner-side job — see this script's header." >&2
      EXPIRED=$((EXPIRED + 1))
      continue
    fi
    # 10# forces base 10 belt-and-braces; pending_ts has already rejected the
    # leading-zero shape that would otherwise be read as octal.
    AGE=$((NOW - 10#$ts))
    if [ "$AGE" -lt 0 ]; then
      # The stamp is in the FUTURE: the clock moved backwards (this deployment
      # has a documented history of chain/host clock skew in both directions).
      if [ "$AGE" -lt "-$PENDING_FLUSH_MAX_AGE_SECS" ]; then
        echo "EXPIRED: flush tx $hash is stamped $((-AGE))s in the future — further ahead than the whole" >&2
        echo "         ${PENDING_FLUSH_MAX_AGE_SECS}s proof window, so the stamp cannot be trusted at all. Dropping it;" >&2
        echo "         recovering its value is a manual, owner-side job — see this script's header." >&2
        EXPIRED=$((EXPIRED + 1))
        continue
      fi
      echo "WARNING: flush tx $hash is stamped $((-AGE))s in the future — this host's clock has moved" >&2
      echo "         backwards. Treating it as brand new; it ages out normally once the clock catches up." >&2
      AGE=0
    fi
    if [ "$AGE" -gt "$PENDING_FLUSH_MAX_AGE_SECS" ]; then
      echo "EXPIRED: flush tx $hash is ${AGE}s old, past PENDING_FLUSH_MAX_AGE_SECS (${PENDING_FLUSH_MAX_AGE_SECS}s), the" >&2
      echo "         age after which this keeper treats a flush as unclaimable. Dropping it;" >&2
      echo "         recovering its value is a manual, owner-side job — see this script's header." >&2
      EXPIRED=$((EXPIRED + 1))
      continue
    fi
    # Never wait longer than this hash can still be claimed for: bounding the
    # wasted wait is the whole point of tracking an age. Floored at 1s because
    # claim-fees-l1.ts rejects a non-positive CLAIM_WITNESS_TIMEOUT_SECS.
    CLAIM_WAIT=$((PENDING_FLUSH_MAX_AGE_SECS - AGE))
    [ "$CLAIM_WAIT" -gt "$KEEPER_CLAIM_WAIT_SECS" ] && CLAIM_WAIT="$KEEPER_CLAIM_WAIT_SECS"
    [ "$CLAIM_WAIT" -lt 1 ] && CLAIM_WAIT=1
    echo "relaying flush tx $hash (age ${AGE}s, claim wait up to ${CLAIM_WAIT}s)..."
    if L1_CLAIMER_PRIVATE_KEY="$KEEPER_L1_PRIVATE_KEY" \
        CLAIM_WITNESS_TIMEOUT_SECS="$CLAIM_WAIT" \
        yarn --cwd "$V1_L2_DIR" claim:fees --tx "$hash" 9>&-; then
      RELAYED=$((RELAYED + 1))
    else
      # Kept verbatim, so the entry keeps its ORIGINAL timestamp and does
      # eventually age out instead of being retried forever.
      STILL_PENDING+=("$entry")
    fi
  done
  write_pending ${STILL_PENDING[@]+"${STILL_PENDING[@]}"}
  # Expiry is reported separately and never counted as a relay failure: it is
  # a known dead end, not a step that went wrong this run (and the exit code
  # stays 0 for it). But the word "ok" is never printed on a line that reports
  # permanently lost value — that status reads "attention".
  RETRIED=$((${#PENDING[@]} - EXPIRED))
  EXPIRED_NOTE=""
  if [ "$EXPIRED" -gt 0 ]; then
    EXPIRED_NOTE=", $EXPIRED EXPIRED past the ${PENDING_FLUSH_MAX_AGE_SECS}s proof window (unclaimable; manual recovery)"
  fi
  FLUSH_NOTE=""
  [ "$FLUSH_STATUS" -ne 0 ] && FLUSH_NOTE="; flush failed"
  if [ "${#STILL_PENDING[@]}" -gt 0 ]; then
    record_fail "relay" "${#STILL_PENDING[@]} of $RETRIED still pending in $PENDING_FLUSH_FILE, retried next run$EXPIRED_NOTE"
  elif [ "$EXPIRED" -gt 0 ]; then
    record "relay" "attention ($RELAYED relayed$EXPIRED_NOTE$FLUSH_NOTE)"
  else
    record "relay" "ok ($RELAYED relayed$FLUSH_NOTE)"
  fi
fi

# --- 4. convert ----------------------------------------------------------------
# convert-fees.ts (keeper:convert) takes its chain and deployment file from
# the RPC's chain id and requires KEEPER_L1_PRIVATE_KEY itself — already in
# this script's environment, so it is passed through unmodified rather than
# renamed.
step "convert"
if yarn --cwd "$V1_L2_DIR" keeper:convert 9>&-; then
  record "convert" "ok"
else
  record_fail "convert"
fi

# --- 5. cushion ----------------------------------------------------------------
step "cushion"
if yarn --cwd "$V1_L2_DIR" keeper:cushion 9>&-; then
  record "cushion" "ok"
else
  record_fail "cushion"
fi

echo
echo "=== summary ==="
for line in "${SUMMARY[@]}"; do
  echo "  $line"
done

if [ "$FAILS" -gt 0 ]; then
  echo "keeper run: $FAILS step(s) failed."
  exit 1
fi
echo "keeper run: all steps ok (some may have been idle -- see the step logs above)."
