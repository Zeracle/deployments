#!/usr/bin/env bash
# load_env_defaults FILE
#
# Source KEY=VALUE lines from FILE as exported DEFAULTS: a variable that is
# already set in the caller's environment — even set to the empty string —
# is left alone. This is the opposite of `set -a; . FILE; set +a`, which lets
# the file silently overwrite whatever the operator exported (G17: an
# exported empty MAINNET_RPC_URL could never win over sandbox-local/.env, so
# mock feeds were skipped on an unforked anvil while the deploy printed
# success).
#
# Accepts blank lines, `#` comments, an optional leading `export `, and
# single- or double-quoted values. Lines that are not a plain KEY=VALUE are
# ignored. FILE is trusted config (same trust level as sourcing it).
load_env_defaults() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"       # ltrim
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%$'\r'}"                          # strip trailing CR (CRLF files)
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ -z "${!key+x}" ]; then                    # unset in caller → take the file's value
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
        *) value="${value%%[[:space:]]#*}" ;;       # unquoted only: strip trailing ` # comment`
      esac
      export "$key=$value"
    fi
  done <"$file"
}
