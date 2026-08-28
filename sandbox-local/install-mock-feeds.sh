#!/usr/bin/env bash
# Install mock Chainlink price feeds on the local/sandbox anvil.
#
# WHY: The production sandbox anvil runs WITHOUT a mainnet fork (forking breaks
# the Aztec L2 sandbox — the L1 archiver falls out of sync and crash-loops). On
# an unforked anvil the real Chainlink feed addresses have no code, so
# ChainlinkOracleWrapper.getPrice reverts and every LiquidityPool deposit
# reverts on the price read. This installs a minimal fixed-price aggregator
# (v1-l1/contracts/mocks/MockPriceFeed.sol) at each mainnet feed address via
# `anvil_setCode`, so the pool (and the frontend, which reads the same feeds)
# get sensible prices with no fork.
#
# The price + decimals are `immutable`, so they bake into the deployed runtime
# bytecode: we deploy one throwaway instance per price to the running anvil,
# read its code, then `anvil_setCode` that code at the real feed address.
#
# Decides by PROBING THE CHAIN (G17): if the LUSD/USD feed address already has
# code — a forked anvil — nothing is installed. The old MAINNET_RPC_URL check
# trusted an env var that could disagree with the running anvil.
#
# Env:
#   ETH_RPC_URL             (default http://localhost:8545)
#   DEPLOYER_PRIVATE_KEY    (default anvil account 0)
#   FORCE_MOCK_FEEDS=1      install even if the feed address has code
set -euo pipefail

RPC="${ETH_RPC_URL:-http://localhost:8545}"
KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
L1_DIR="${L1_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../v1-l1" && pwd)}"

command -v cast >/dev/null 2>&1 || { echo "install-mock-feeds: cast not found on PATH" >&2; exit 1; }
command -v forge >/dev/null 2>&1 || { echo "install-mock-feeds: forge not found on PATH" >&2; exit 1; }

PROBE_FEED=0x3D7aE7E594f2f2091Ad8798313450130d0Aba3a0 # LUSD/USD — first row of FEEDS below
existing=$(cast code --rpc-url "$RPC" "$PROBE_FEED")
if [ "${FORCE_MOCK_FEEDS:-0}" != 1 ] && [ -n "$existing" ] && [ "$existing" != "0x" ]; then
  echo "install-mock-feeds: $PROBE_FEED already has code (forked anvil or feeds installed) — skipping."
  exit 0
fi

# Chainlink USD feeds are all 8-decimal. Prices chosen to match the frontend's
# sandbox fallback table (interfaces/apps/web/src/services/oracle/priceOracle.ts)
# so the on-chain deposit value matches the UI quote.
#   feed_address : answer(8dp) : label
FEEDS="
0x3D7aE7E594f2f2091Ad8798313450130d0Aba3a0:100000000:LUSD/USD=\$1
0x3E7d1eAB13ad0104d2750B8863b489D65364e32D:100000000:USDT/USD=\$1
0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9:100000000:DAI/USD=\$1
0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6:200000000000:XAU/USD=\$2000
0x379589227b15F1a12195D3f2d90bBc9F31f95235:2500000000:XAG/USD=\$25
0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c:6000000000000:BTC/USD=\$60000
"

echo "install-mock-feeds: unforked anvil → installing MockPriceFeed at mainnet feed addresses ($RPC)"
CREATION=$(cd "$L1_DIR" && forge inspect contracts/mocks/MockPriceFeed.sol:MockPriceFeed bytecode)

# Here-string (not a pipe) keeps the loop in the main shell so `exit 1` on a
# failed verification actually aborts the deploy.
while IFS=: read -r addr answer label; do
  [ -z "$addr" ] && continue
  # Deploy a throwaway instance so the immutable price+decimals bake into its
  # runtime code, then install that code at the real feed address.
  inst=$(cast send --rpc-url "$RPC" --private-key "$KEY" --create "$CREATION" \
           "constructor(int256,uint8)" "$answer" 8 --json | jq -r '.contractAddress')
  code=$(cast code --rpc-url "$RPC" "$inst")
  cast rpc anvil_setCode "$addr" "$code" --rpc-url "$RPC" >/dev/null
  got=$(cast call "$addr" 'latestAnswer()(int256)' --rpc-url "$RPC" | awk '{print $1}')
  if [ "$got" != "$answer" ]; then
    echo "  FAIL $label @ $addr — expected $answer, got $got" >&2
    exit 1
  fi
  echo "  ok  $label @ $addr"
done <<< "$(printf '%s\n' "$FEEDS" | grep -v '^[[:space:]]*$')"

echo "install-mock-feeds: done."
