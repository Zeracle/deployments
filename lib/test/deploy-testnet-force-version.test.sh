#!/usr/bin/env bash
# deployments/lib/test/deploy-testnet-force-version.test.sh
#
# ZER-71: what `deploy-testnet.sh --force-version` does and does NOT relax.
#
# The owner decided on 2026-09-26 to deploy the 5.2.0 stack against Aztec's
# public testnet node, which still reports 5.0.0, by passing --force-version.
# That flag must relax exactly ONE gate: the node/SDK version comparison. The
# two contract checks behind it have their own verdicts and stay fatal:
#
#   - the canonical SponsoredFPC preflight (ZER-28). Its only override is the
#     separate, explicit --allow-unverified-fpc, which is also the only thing
#     that exports ZERACLE_ALLOW_UNVERIFIED_FPC=1 into Stage 2.
#   - the HandshakeRegistry preflight (ZER-29). No flag relaxes it.
#
# This test EXECUTES the --preflight-only path, so it builds a throwaway root
# (deployments/, v1-l2/, interfaces/apps/web/) in a temp dir and runs a COPY of
# the script there. Everything the preflight talks to is local:
#
#   - the Aztec node is a python JSON-RPC stub on 127.0.0.1 (a free port picked
#     by the OS) that answers node_getNodeInfo and aztec_getNodeInfo with
#     nodeVersion 5.0.0 on l1ChainId 11155111. It answers batched requests
#     too, because the real @aztec/aztec.js client batches.
#   - v1-l2's @aztec/aztec.js is a stub package reporting version 5.2.0 whose
#     createAztecNodeClient makes a real HTTP JSON-RPC call to that stub node.
#     Set ZER71_REAL_V1L2=<path to v1-l2> to use that checkout's real
#     node_modules instead (still only talks to the loopback stub).
#   - forge, cast, yarn and npx are PATH stubs. cast answers the Sepolia chain
#     id and canned balances/code; npx impersonates v1-l2's two check scripts
#     (check-canonical-fpc.ts, check-handshake-registry.ts), passing or failing
#     as each case asks.
#
# --preflight-only exits before the confirmation prompt, and the stubs make no
# outbound connection, so nothing here can broadcast. The .env holds a dummy
# key that controls no funds on any network.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-$HERE/../../testnet/deploy-testnet.sh}"
PUBLIC_MANIFEST="$HERE/../public-manifest.sh"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: deploy-testnet.sh is not syntactically valid"; exit 1; }
for tool in python3 node jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required to run this test"; exit 1; }
done

T=$(mktemp -d)
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# --- the fake root -----------------------------------------------------------
mkdir -p "$T/deployments/testnet" "$T/deployments/lib" "$T/bin" \
  "$T/v1-l2/artifacts" "$T/v1-l2/target" "$T/interfaces/apps/web"
cp "$SCRIPT" "$T/deployments/testnet/deploy-testnet.sh"
cp "$PUBLIC_MANIFEST" "$T/deployments/lib/public-manifest.sh"
: > "$T/v1-l2/artifacts/index.ts"
echo '{}' > "$T/v1-l2/target/stub.json"
: > "$T/interfaces/apps/web/.env.testnet"

if [ -n "${ZER71_REAL_V1L2:-}" ]; then
  [ -d "$ZER71_REAL_V1L2/node_modules/@aztec/aztec.js" ] \
    || { echo "FAIL: ZER71_REAL_V1L2=$ZER71_REAL_V1L2 has no node_modules/@aztec/aztec.js"; exit 1; }
  ln -s "$ZER71_REAL_V1L2/node_modules" "$T/v1-l2/node_modules"
  SDK_VERSION=$(jq -r .version "$ZER71_REAL_V1L2/node_modules/@aztec/aztec.js/package.json")
else
  SDK_VERSION=5.2.0
  mkdir -p "$T/v1-l2/node_modules/@aztec/aztec.js"
  cat > "$T/v1-l2/node_modules/@aztec/aztec.js/package.json" <<JSON
{ "name": "@aztec/aztec.js", "version": "$SDK_VERSION", "type": "module",
  "exports": { "./node": "./node.js" } }
JSON
  cat > "$T/v1-l2/node_modules/@aztec/aztec.js/node.js" <<'JS'
// Test stub: a real JSON-RPC round trip to the loopback node, nothing else.
export function createAztecNodeClient(url) {
  return {
    async getNodeInfo() {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'node_getNodeInfo', params: [] }),
      });
      const body = await res.json();
      if (body.error) throw new Error(body.error.message);
      return body.result;
    },
  };
}
JS
fi

# --- the loopback Aztec node -------------------------------------------------
cat > "$T/node-stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

NODE_INFO = {
    "nodeVersion": "5.0.0",
    "l1ChainId": 11155111,
    "rollupVersion": 1821665230,
    "l1ContractAddresses": {k: "0x" + c * 40 for k, c in [
        ("rollupAddress", "a"), ("registryAddress", "b"), ("inboxAddress", "c"),
        ("outboxAddress", "d"), ("feeJuiceAddress", "e"), ("feeJuicePortalAddress", "f"),
        ("coinIssuerAddress", "1"), ("rewardDistributorAddress", "2"),
        ("governanceProposerAddress", "3"), ("governanceAddress", "4"),
        ("stakingAssetAddress", "5"), ("feeAssetHandlerAddress", "6"), ("gseAddress", "7"),
    ]},
    "protocolContractAddresses": {
        "classRegistry": "0x" + "0" * 63 + "1",
        "instanceRegistry": "0x" + "0" * 63 + "2",
        "feeJuice": "0x" + "0" * 63 + "3",
        "multiCallEntrypoint": "0x" + "0" * 63 + "4",
    },
    "realProofs": True,
    "txsLimits": {"gas": {"daGas": 1, "l2Gas": 1}},
}

def answer(req):
    if req.get("method") in ("node_getNodeInfo", "aztec_getNodeInfo"):
        return {"jsonrpc": "2.0", "id": req.get("id"), "result": NODE_INFO}
    return {"jsonrpc": "2.0", "id": req.get("id"),
            "error": {"code": -32601, "message": "not mocked: %s" % req.get("method")}}

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        out = json.dumps([answer(r) for r in body] if isinstance(body, list) else answer(body)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$T/node-stub.py" > "$T/port" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "FAIL: the loopback node stub did not start"; exit 1; }
NODE_URL="http://127.0.0.1:$(cat "$T/port")"

# --- PATH stubs --------------------------------------------------------------
DEPLOYER=0x1111111111111111111111111111111111111111
cat > "$T/bin/cast" <<SH
#!/usr/bin/env bash
case "\$1" in
  chain-id) echo 11155111 ;;
  wallet)   echo $DEPLOYER ;;
  balance)  echo 1.0 ;;
  code)     echo 0x6080 ;;
  call)     echo "1000000000000000000000 [1e21]" ;;
  *)        echo "cast stub: unexpected \$*" >&2; exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\necho "forge stub: must not run in preflight" >&2; exit 1\n' > "$T/bin/forge"
printf '#!/usr/bin/env bash\necho "yarn stub: must not run in preflight" >&2; exit 1\n' > "$T/bin/yarn"
# npx impersonates the two v1-l2 check scripts. STUB_FPC / STUB_HANDSHAKE pick
# pass or fail; the JSON mirrors what those scripts print.
# Each call also records what ZERACLE_ALLOW_UNVERIFIED_FPC looks like in the
# script's environment at that moment ($ENV_PROBE_DIR/<check>). The handshake
# check runs AFTER the FPC branch and inherits exactly what `yarn deploy:clean`
# would inherit in Stage 2, so its record is the runtime answer to "does Stage 2
# get the FPC override?", which --preflight-only cannot otherwise show.
cat > "$T/bin/npx" <<'SH'
#!/usr/bin/env bash
probe() { [ -n "${ENV_PROBE_DIR:-}" ] && printf '%s' "${ZERACLE_ALLOW_UNVERIFIED_FPC-unset}" > "$ENV_PROBE_DIR/$1"; return 0; }
case "$*" in
  *check-canonical-fpc.ts*)
    probe fpc
    if [ "${STUB_FPC:-pass}" = pass ]; then
      echo '{"address":"0x2ece","exists":true,"balance":"1500000","ok":true,"reason":null,"message":null}'
    else
      echo '{"address":"0x2ece","exists":false,"balance":"0","ok":false,"reason":"missing","message":"STUB: no contract at the derived canonical SponsoredFPC address"}'
      exit 1
    fi ;;
  *check-handshake-registry.ts*)
    probe handshake
    if [ "${STUB_HANDSHAKE:-pass}" = pass ]; then
      echo '{"address":"0x0612","exists":true,"ok":true,"message":null}'
    else
      echo '{"address":"0x0612","exists":false,"ok":false,"message":"STUB: no HandshakeRegistry published"}'
      exit 1
    fi ;;
  *) echo "npx stub: unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$T/bin/"*

# Dummy values only. The key controls nothing on any network.
cat > "$T/deployments/testnet/.env" <<ENV
TESTNET_L1_RPC_URL=http://127.0.0.1:9/unused
PUBLIC_L1_RPC=http://127.0.0.1:9/public
DEPLOYER_PRIVATE_KEY=0x2222222222222222222222222222222222222222222222222222222222222222
AZTEC_NODE_URL=$NODE_URL
GOV_PROPOSER=0x3333333333333333333333333333333333333333
GOV_PROPOSER_2=0x4444444444444444444444444444444444444444
GOV_GUARDIAN=0x5555555555555555555555555555555555555555
ENV

# --- cases -------------------------------------------------------------------
FAILS=0
OUT="$T/out"

# run <expected exit: 0|1> <label> [VAR=val ...] -- [script args ...]
run() {
  local want="$1" label="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  local got=0
  rm -rf "$T/probe" && mkdir -p "$T/probe"
  # env -u: an ambient ZERACLE_ALLOW_UNVERIFIED_FPC in the caller's shell must
  # not leak into cases that do not set it.
  env -u ZERACLE_ALLOW_UNVERIFIED_FPC PATH="$T/bin:$PATH" ENV_PROBE_DIR="$T/probe" "${envs[@]}" \
    bash "$T/deployments/testnet/deploy-testnet.sh" --preflight-only "$@" > "$OUT" 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" != "$want" ]; then
    echo "FAIL [$label]: expected exit $want, got $got. Output tail:"
    tail -15 "$OUT" | sed 's/^/        /'
    FAILS=$((FAILS + 1))
    return 1
  fi
  return 0
}
expect() {  # expect <label> <fixed string>
  grep -qF -- "$2" "$OUT" || { echo "FAIL [$1]: output lacks: $2"; FAILS=$((FAILS + 1)); }
}
# stage2_env <label> <expected: unset|1>: what ZERACLE_ALLOW_UNVERIFIED_FPC was
# when the handshake check (the last subprocess before Stage 2) ran.
stage2_env() {
  local got
  got=$(cat "$T/probe/handshake" 2>/dev/null || echo "<handshake check never ran>")
  [ "$got" = "$2" ] || { echo "FAIL [$1]: Stage 2 would see ZERACLE_ALLOW_UNVERIFIED_FPC=$got, expected $2"; FAILS=$((FAILS + 1)); }
}
reject() {  # reject <label> <fixed string>
  if grep -qF -- "$2" "$OUT"; then echo "FAIL [$1]: output unexpectedly contains: $2"; FAILS=$((FAILS + 1)); fi
}

# 1. No flag: the version gate is fatal, and it fires BEFORE the contract checks.
if run 1 "no flag"; then
  expect "no flag" "Aztec node version (5.0.0) does not match the local SDK version ($SDK_VERSION)"
  reject "no flag" "PREFLIGHT PASS"
  reject "no flag" "Preflight: canonical SponsoredFPC"
fi

# 2. --force-version, both contract checks pass: warning, then PREFLIGHT PASS.
if run 0 "force, checks pass" -- --force-version; then
  expect "force, checks pass" "Node version (5.0.0) != local SDK version ($SDK_VERSION) — continuing anyway due to --force-version."
  expect "force, checks pass" "Canonical SponsoredFPC: 0x2ece"
  expect "force, checks pass" "HandshakeRegistry published at 0x0612"
  expect "force, checks pass" "Version gate:                 FORCED (node 5.0.0, SDK $SDK_VERSION; --force-version)"
  expect "force, checks pass" "Canonical SponsoredFPC:       verified"
  expect "force, checks pass" "PREFLIGHT PASS"
  stage2_env "force, checks pass" unset
fi

# 3. --force-version does NOT relax a failed FPC preflight (the ZER-71 narrowing).
if run 1 "force, FPC fails" STUB_FPC=fail -- --force-version; then
  expect "force, FPC fails" "STUB: no contract at the derived canonical SponsoredFPC address"
  expect "force, FPC fails" "--force-version relaxes only the node/SDK version gate"
  reject "force, FPC fails" "PREFLIGHT PASS"
fi

# 4. --force-version does NOT relax a failed HandshakeRegistry preflight.
if run 1 "force, handshake fails" STUB_HANDSHAKE=fail -- --force-version; then
  expect "force, handshake fails" "STUB: no HandshakeRegistry published"
  reject "force, handshake fails" "PREFLIGHT PASS"
fi

# 5. The explicit FPC override: warns, passes, and says it will reach Stage 2.
if run 0 "force + allow-unverified-fpc, FPC fails" STUB_FPC=fail -- --force-version --allow-unverified-fpc; then
  expect "force + allow-unverified-fpc, FPC fails" "Canonical SponsoredFPC preflight FAILED — continuing anyway due to --allow-unverified-fpc."
  expect "force + allow-unverified-fpc, FPC fails" "Canonical SponsoredFPC:       UNVERIFIED (--allow-unverified-fpc; Stage 2 gets ZERACLE_ALLOW_UNVERIFIED_FPC=1)"
  expect "force + allow-unverified-fpc, FPC fails" "PREFLIGHT PASS"
  stage2_env "force + allow-unverified-fpc, FPC fails" 1
fi

# 6. --allow-unverified-fpc does not relax the version gate.
if run 1 "allow-unverified-fpc alone" -- --allow-unverified-fpc; then
  expect "allow-unverified-fpc alone" "Aztec node version (5.0.0) does not match"
fi

# 7. --allow-unverified-fpc does not relax the HandshakeRegistry preflight either.
run 1 "all flags, handshake fails" STUB_HANDSHAKE=fail -- --force-version --allow-unverified-fpc \
  && expect "all flags, handshake fails" "STUB: no HandshakeRegistry published"

# 8. An ambient ZERACLE_ALLOW_UNVERIFIED_FPC=1 (shell or .env) is not an
#    override: only the flag grants it. With the FPC check PASSING, so the run
#    reaches the handshake probe and the assertion is about the unset alone,
#    not about which FPC branch fired.
if run 0 "ambient env var" ZERACLE_ALLOW_UNVERIFIED_FPC=1 -- --force-version; then
  stage2_env "ambient env var" unset
fi
echo "ZERACLE_ALLOW_UNVERIFIED_FPC=1" >> "$T/deployments/testnet/.env"
if run 0 "override in .env" -- --force-version; then
  stage2_env "override in .env" unset
fi
#    ...and with the FPC check failing, neither source turns it into a pass.
if run 1 "override in .env + shell, FPC fails" STUB_FPC=fail ZERACLE_ALLOW_UNVERIFIED_FPC=1 -- --force-version; then
  reject "override in .env + shell, FPC fails" "PREFLIGHT PASS"
fi
sed -i '/^ZERACLE_ALLOW_UNVERIFIED_FPC=/d' "$T/deployments/testnet/.env"

# 9. Unknown flags are still refused, and the message lists the new one.
if run 1 "unknown flag" -- --force-versions; then
  expect "unknown flag" "--allow-unverified-fpc"
fi

# 10. STATIC backstop: ZERACLE_ALLOW_UNVERIFIED_FPC is exported in exactly one place,
#     and only under --allow-unverified-fpc. Stage 2 (yarn deploy:clean)
#     inherits the environment, so any other export would re-couple the FPC
#     override to something else. --preflight-only exits before Stage 2, so this
#     half cannot be shown at runtime.
EXPORTS=$(grep -nE '(^|[;&|[:space:]])export[[:space:]]+([^#]*[[:space:]])?ZERACLE_ALLOW_UNVERIFIED_FPC(=|[[:space:]]|$)' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ "$(printf '%s' "$EXPORTS" | grep -c .)" != 1 ]; then
  echo "FAIL [static export]: expected exactly one export of ZERACLE_ALLOW_UNVERIFIED_FPC, found:"
  printf '%s\n' "${EXPORTS:-<none>}" | sed 's/^/        /'
  FAILS=$((FAILS + 1))
else
  EXPORT_LINE=${EXPORTS%%:*}
  # The branch that ENCLOSES the export: walk up, tracking if/fi nesting, to
  # the nearest if/elif/else at the export's own depth.
  GUARD=$(awk -v n="$EXPORT_LINE" '
    { l[NR] = $0 }
    END {
      depth = 0
      for (i = n - 1; i >= 1; i--) {
        line = l[i]
        if (line ~ /^[[:space:]]*fi([[:space:]]|;|$)/) { depth++; continue }
        if (line ~ /^[[:space:]]*if[[:space:]]/) { if (depth == 0) { print line; exit } depth--; continue }
        if (depth == 0 && line ~ /^[[:space:]]*(elif[[:space:]]|else([[:space:]]|$))/) { print line; exit }
      }
    }' "$SCRIPT")
  case "$GUARD" in
    *'if [ "$ALLOW_UNVERIFIED_FPC" = true ]'*) ;;
    *) echo "FAIL [static export]: the export at line $EXPORT_LINE sits in branch '$GUARD', not in 'if [ \"\$ALLOW_UNVERIFIED_FPC\" = true ]'"
       FAILS=$((FAILS + 1)) ;;
  esac
fi

if [ "$FAILS" -ne 0 ]; then
  echo "deploy-testnet --force-version scope test: $FAILS failure(s)"
  exit 1
fi
echo "deploy-testnet --force-version scope test: ok (node 5.0.0 vs SDK $SDK_VERSION; $([ -n "${ZER71_REAL_V1L2:-}" ] && echo "real SDK" || echo "stub SDK"))"
