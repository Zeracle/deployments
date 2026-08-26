#!/usr/bin/env bash
# Unit test for lib/env-defaults.sh — run: bash sandbox-local/test/env-defaults.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-defaults.sh
. "$HERE/../lib/env-defaults.sh"

fails=0
check() { # $1 label, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'EOF'
# comment line

UNSET_IN_CALLER=from_file
EMPTY_IN_CALLER=from_file
SET_IN_CALLER=from_file
export EXPORTED_FORM=from_file
QUOTED="quoted value"
SINGLE='single value'
NOT_A_VAR-BAD=ignored
TRAILING_COMMENT=val # note
EOF
printf 'CRLF_VAL=abc\r\n' >>"$tmp"

unset UNSET_IN_CALLER EXPORTED_FORM QUOTED SINGLE TRAILING_COMMENT CRLF_VAL
export EMPTY_IN_CALLER=""
export SET_IN_CALLER=from_caller

load_env_defaults "$tmp"

check "unset var takes the file value"            "from_file"     "${UNSET_IN_CALLER-<unset>}"
check "exported-but-empty var stays empty"        ""              "${EMPTY_IN_CALLER-<unset>}"
check "exported non-empty var wins"               "from_caller"   "$SET_IN_CALLER"
check "'export KEY=VAL' form accepted"            "from_file"     "${EXPORTED_FORM-<unset>}"
check "double-quoted value is unquoted"           "quoted value"  "${QUOTED-<unset>}"
check "single-quoted value is unquoted"           "single value"  "${SINGLE-<unset>}"
check "trailing comment stripped (unquoted)"      "val"           "${TRAILING_COMMENT-<unset>}"
check "trailing CR stripped (CRLF file)"          "abc"           "${CRLF_VAL-<unset>}"
check "file values are exported to children"      "from_file"     "$(bash -c 'printf %s "${UNSET_IN_CALLER-<unset>}"')"
check "missing file is a no-op (exit 0)"          "0"             "$(load_env_defaults /nonexistent/.env; echo $?)"

if [ "$fails" -ne 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all env-defaults checks passed"
