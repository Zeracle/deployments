#!/usr/bin/env bash
# deployments/lib/anvil-accounts.sh
#
# The dev accounts anvil derives from its default mnemonic ("test test ... junk"),
# and the one place that decides how many of them a sandbox publishes.
#
# ZER-50: deploy-sandbox.sh used to start anvil with `--accounts 5` while writing
# all TEN of these into the manifest, private keys included. The node refused to
# sign for 5-9, so any walletless flow using one failed with
# `-32602 No Signer available` — which viem shows as "Invalid parameters were
# provided to the RPC method", pointing the reader at the wrong thing entirely.
# The count and the list are now one variable: see ANVIL_ACCOUNT_COUNT.
#
# These keys are public by construction — identical on every anvil, worth
# nothing. The defect was advertising them as usable HERE when they were not.

# The full table, in anvil's derivation order. Index 0 is the deployer; the
# Aztec sandbox sequencer also broadcasts L1 rollup txs from it, which is why
# other senders must prefer a later account (a competing nonce breaks deploys).
_ANVIL_ACCOUNTS_ALL='[
  {"index":0,"address":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","privateKey":"0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80","role":"deployer"},
  {"index":1,"address":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","privateKey":"0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d","role":"user"},
  {"index":2,"address":"0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC","privateKey":"0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a","role":"user"},
  {"index":3,"address":"0x90F79bf6EB2c4f870365E785982E1f101E93b906","privateKey":"0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6","role":"user"},
  {"index":4,"address":"0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65","privateKey":"0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a","role":"user"},
  {"index":5,"address":"0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc","privateKey":"0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba","role":"user"},
  {"index":6,"address":"0x976EA74026E726554dB657fA54763abd0C3a0aa9","privateKey":"0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e","role":"user"},
  {"index":7,"address":"0x14dC79964da2C08dA15Fd353d30d9CBd31045D41","privateKey":"0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356","role":"user"},
  {"index":8,"address":"0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f","privateKey":"0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97","role":"user"},
  {"index":9,"address":"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720","privateKey":"0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6","role":"user"}
]'

# How many accounts anvil unlocks, and therefore how many the manifest may
# advertise. Five is plenty (deployer + test users) and keeps genesis RPC calls
# down so a public mainnet RPC is less likely to 429 while forking.
# Pass this SAME variable to `anvil --accounts` and to anvil_accounts_json.
: "${ANVIL_ACCOUNT_COUNT:=5}"

# anvil_accounts_json <count> -> the first <count> accounts as a JSON array.
# Refuses a count it cannot honour rather than truncating silently, because a
# short manifest is the very failure this exists to prevent.
anvil_accounts_json() {
  local count="${1:-}" total
  total=$(printf '%s' "$_ANVIL_ACCOUNTS_ALL" | jq 'length')
  case "$count" in
    ''|*[!0-9]*) echo "anvil_accounts_json: count must be a positive integer, got '${count}'" >&2; return 1 ;;
  esac
  if [ "$count" -lt 1 ] || [ "$count" -gt "$total" ]; then
    echo "anvil_accounts_json: count ${count} out of range (1..${total} known anvil keys)" >&2
    return 1
  fi
  printf '%s' "$_ANVIL_ACCOUNTS_ALL" | jq --argjson n "$count" '.[:$n]'
}

# anvil_assert_unlocked_matches <rpc-url> <count> — belt and braces: ask the
# running node how many accounts it actually holds and refuse to publish a
# manifest that disagrees. Catches a drift the static wiring cannot, e.g. anvil
# started by something other than this script.
anvil_assert_unlocked_matches() {
  local rpc="$1" expected="$2" actual
  actual=$(curl -sS --max-time 10 -X POST "$rpc" -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_accounts","params":[]}' | jq '.result | length')
  if [ "$actual" != "$expected" ]; then
    echo "anvil holds ${actual} unlocked accounts but the manifest would advertise ${expected}." >&2
    echo "Publishing accounts the node will not sign for causes '-32602 No Signer available' (ZER-50)." >&2
    return 1
  fi
}
