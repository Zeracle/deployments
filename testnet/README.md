# testnet deployment

Deployment configuration and pipeline for the **OFFICIAL Aztec testnet**
(real sequencing, proving, and fee infrastructure) with L1 contracts on
Sepolia. "Testnet" here NEVER means the EC2-hosted sandbox in
`../sandbox-ec2/` or the local sandbox in `../sandbox-local/`. Sepolia's
chain id is `11155111`; the local sandbox L1 is `31337`. Nothing
sandbox-shaped may be copied in here — see
`docs/versions/260709/existing-limitations.md` (repo root) for the
capability gaps (chain-server sandbox-only infra: block production, account
deployment, account-address directory) that remain even after this pipeline
runs successfully.

`deploy-testnet.sh` is a real, config-gated pipeline (preflight → L1 →
L2 → manifest/env sync). It sends real transactions and spends real Sepolia
ETH when run past preflight — read this whole file before running it.

## Prerequisites

- A Sepolia L1 RPC endpoint (Alchemy/Infura/etc.) that answers chain id
  `11155111`.
- An L1 private key funded with real Sepolia ETH (get some from a faucet).
  This key pays for every L1 contract deploy, the mock token/feed setup, the
  TokenPortal bridge deploy, and the L2 fee-juice bootstrap. **Never** the
  well-known anvil dev key — that key is public and sandbox-only.
- A running Aztec node/sequencer on the **official Aztec testnet** (not a
  local sandbox PXE) — ask the Aztec testnet operators/docs for a current
  endpoint.
- The local `v1-l2` SDK version (`v1-l2/node_modules/@aztec/aztec.js`) must
  match the testnet node's reported version, or the deploy is likely to hit
  contract/RPC incompatibilities. The preflight checks this and fails loud
  on a mismatch (`--force-version` overrides only that comparison, at your
  own risk; see "Deploying across a node/SDK version skew" below).
- `v1-l2/artifacts/` and `v1-l2/target/` must already be built
  (`cd v1-l2 && yarn build`) and present on disk. Testnet deploys never
  compile Noir on the fly — same rule `deploy-sandbox.sh` uses in its
  headless/EC2 branch.
- Tools on `PATH`: `forge`, `cast`, `jq`, `node`, `yarn`, `python3`.

## Config setup

```sh
cp deployments/testnet/.env.example deployments/testnet/.env
# fill in TESTNET_L1_RPC_URL, DEPLOYER_PRIVATE_KEY, AZTEC_NODE_URL
```

`deployments/testnet/.env` holds a real, funded Sepolia private key.
**Never commit it, never ship it in a release tarball** (it's already in
`make-release-tarball.sh`'s exclude list — verify that hasn't regressed
before shipping).

## Running

**Always run `--preflight-only` first.** It only reads state — checks
tools, env vars, the L1 RPC's chain id, deployer balance, and the Aztec
node's reachability/version — and never broadcasts a transaction:

```sh
cd deployments/testnet
./deploy-testnet.sh --preflight-only
```

Fix anything it flags before going further. Once preflight passes cleanly,
run the full pipeline from the `deployments/` Makefile:

```sh
make -C deployments deploy-testnet
```

This re-runs preflight, prints a summary, and then asks for an interactive
`Type 'deploy' to continue` confirmation before it broadcasts anything (set
`SKIP_CONFIRM=1` in `.env` only for scripted/CI runs — it removes the last
safety net before real funds move). After confirmation it runs, in order:

1. **L1 (Sepolia):** core contracts (`make deploy-testnet-l1`) → mock
   tokens (`make deploy-mocks-testnet`, which also deploys fresh
   MockPriceFeeds on Sepolia — T2; `install-mock-feeds.sh` is 31337-only
   and does not run here) → the TokenPortal bridge
   (`make deploy-bridge-testnet`, using the Inbox/Rollup addresses the
   preflight already fetched from the testnet node). Outputs land in
   `v1-l1/deployments/{local,tokens,bridge}-testnet.json` — the sandbox's
   `local.json`/`tokens.json`/`bridge.json` are never touched.
2. **L2 (Aztec testnet):** `yarn deploy:clean` from `v1-l2`, using the
   prebuilt artifacts and the L1 endpoint/key/portal address from step 1.
   Deploys ZeracleToken, TokenBridge, FeeDistribution and PaymentEscrow. It
   deploys no SponsoredFPC: user fees go through Aztec's canonical instance
   (ZER-28), whose address is derived and recorded in `deployment.json`.
   It runs with `ZERACLE_COMPLIANCE=off`: compliance
   verification (attestor + zkPassport + the bridge's exit enforcement) is not
   part of the testnet release, so no Compliance contract is deployed and the
   bridge's exit check is disabled — the stage asserts `complianceEnabled:
   false` in `deployment.json`. It also passes the FeeDistribution flush
   minimum explicitly — `ZERACLE_ENFORCE_FLUSH_MINIMUM=1` and
   `ZERACLE_FLUSH_MINIMUM=10000000000000000000` (10 ZRCL across the four fee
   buckets combined; owner decision 2026-09-26, ZER-32) — and, before wiring
   the bridge, asserts that `deployment.json` records the deployed
   FeeDistribution reporting that minimum as enforced
   (`feeDistributionFlushMinimumEnforced: true`,
   `feeDistributionFlushMinimum: "10000000000000000000"`; `deploy.ts` reads
   both back from the contract). Output: `v1-l2/deployment.json`. The deployer
   account itself comes from `deployments/testnet/deployer-account.json`
   (see "Deployer account" below) rather than the sandbox's canonical test
   account. Once the L2 contracts are up, this stage also wires the L1
   TokenPortal to the freshly deployed L2 TokenBridge via
   `make -C v1-l1 wire-bridge-testnet` and asserts `TokenPortal.l2Bridge()`
   matches before continuing — bridge deposits are wired end-to-end by the
   time this stage returns.

   Two L1 stages run between this and the manifest, both of which the numbered
   list above predates:

   - **Stage 2b — governance handover:** `make deploy-governance-testnet`
     deploys the GovernanceAuthority / ZeracleTimelock / UpgradeValidator and
     moves every admin-bearing L1 contract to the authority. Output:
     `v1-l1/deployments/governance-testnet.json`.
   - **Stage 2c — BasketManager:** `make deploy-basket-manager-testnet` deploys
     the `BasketManager` (the pool's only composition writer) and wires it in.
     It must run AFTER 2b, because the manager's constructor takes the
     GovernanceAuthority address and 2b deploys the authority and hands over in
     a single broadcast — so `pool.setBasketManager`, which is owner-gated and
     **one-shot**, is routed through `authority.execute(...)` while the deployer
     is still the authority's `currentAuthority()` (the whole
     `GOV_TRANSITION_SECONDS` admin phase). The stage asserts
     `LiquidityPool.basketManager()` matches before continuing; there is no
     second chance at that call. Output:
     `v1-l1/deployments/basket-testnet.json`.

     The voting window / execution delay and their **immutable** floors come
     from `BASKET_VOTING_WINDOW`, `BASKET_EXECUTION_DELAY`,
     `BASKET_VOTING_WINDOW_FLOOR` and `BASKET_EXECUTION_DELAY_FLOOR`
     (defaults: 5 d / 48 h, floors 3 d / 24 h) and are preflight-checked.
     No swap router is allow-listed by default — on the sandbox the pipeline
     allow-lists a mock aggregator because a local chain has no other venue,
     but on a real network choosing the venue a migration tranche routes
     through is a governance decision. Set `BASKET_ROUTER` only once that
     decision is made. `setBasketVote` stays unset: the L2 `BasketVote`
     contract is Phase 2.

     Verifying the **LiquidityPool implementation** on Etherscan additionally
     needs the linked library:
     `--libraries contracts/libraries/BasketCompositionLib.sol:BasketCompositionLib:<addr>`,
     recorded as `basketCompositionLib` in `local-testnet.json` and in the
     manifest. The link is per-implementation, so a UUPS upgrade may relink it
     and the recorded value must be refreshed from the upgrade's output.

3. **Manifest + web env sync:** writes
   `deployments/testnet/deployment-manifest.json` (same shape as the
   sandbox's generated manifest, minus `rpc.accountServer` — there is no
   chain-server on testnet), then syncs every `*_ADDRESS` var into
   `interfaces/apps/web/.env.testnet` via
   `devops/production/ec2/scripts/sync-env-addresses.py`, then fills in the
   endpoint vars that script deliberately leaves alone
   (`VITE_AZTEC_PXE_URL`, `VITE_AZTEC_NODE_URL`, `VITE_ETH_RPC_URL`,
   `VITE_ETH_CHAIN_ID`), and pins `VITE_COMPLIANCE_ENABLED=false` to match the
   L2 deploy.

   `VITE_ETH_RPC_URL` is filled from **`PUBLIC_L1_RPC`, never
   `TESTNET_L1_RPC_URL`** (ZER-29/R18). Vite inlines every `VITE_*` var into
   the client bundle at build time, so the keyed broadcasting URL would
   otherwise be readable by every browser that loads the app — and
   `.env.testnet` is tracked in the `interfaces` repo, so it would also be one
   `git add -A` from being committed. The stage asserts after writing that the
   value equals `PUBLIC_L1_RPC` and carries no credentials, and blanks the line
   if that ever fails.

## Deploying across a node/SDK version skew (ZER-71)

**Decided route (owner, 2026-09-26):** Zeracle stays on the latest v5 stable
(`@aztec/*` 5.2.0 today, 5.3.0 once it is stable) and does not wait for v6. It
does not pin or downgrade to the testnet node's version. The first testnet
deploy runs against Aztec's public node, which still reports **5.0.0**, with
`--force-version`. The decision and the measured versions are in
`planning/versions/260913/owner-decisions.md` (item 3, 2026-09-26 entries),
which also carries the full ZER-73 findings this section summarises.

Measured read-only on 2026-09-26 (`node_getNodeInfo` on
`https://v5.testnet.rpc.aztec-labs.com`): `nodeVersion 5.0.0`,
`l1ChainId 11155111`, `rollupVersion 1821665230`, `realProofs true`, ENR
protocol segment `00-11155111-d73a91bd-1821665230-2c075866-2b3b6ea4`.

### What `--force-version` relaxes, gate by gate

`--force-version` turns **one** Stage 0 check into a warning, and nothing else.

| Gate | Without the flag | With `--force-version` |
|---|---|---|
| Tools, env vars, credential-free public URLs, sed-safe URLs | fatal | fatal (unchanged) |
| L1 RPC is Sepolia (11155111), deployer ETH balance | fatal | fatal (unchanged) |
| Governance and basket parameters, resume addresses | fatal | fatal (unchanged) |
| Aztec node reachable and settling on Sepolia | fatal | fatal (unchanged) |
| **Node `nodeVersion` == `v1-l2` `@aztec/aztec.js` version** | **fatal** | **warning** |
| Canonical SponsoredFPC exists and holds fee juice (ZER-28) | fatal | **fatal**. Only `--allow-unverified-fpc` relaxes it |
| Standard HandshakeRegistry published (ZER-29) | fatal | fatal. No flag relaxes it |
| Deployer L1 fee-asset balance, prebuilt artifacts, web env template | fatal | fatal (unchanged) |
| Stage 2's own FPC re-check in `v1-l2/scripts/deploy.ts` | fatal | fatal. Relaxed only when Stage 0 exports `ZERACLE_ALLOW_UNVERIFIED_FPC=1`, which only `--allow-unverified-fpc` does |
| Stages 1, 2b, 2c, 3 | not affected by either flag | not affected by either flag |

Before ZER-71, `--force-version` also downgraded the SponsoredFPC preflight
and exported `ZERACLE_ALLOW_UNVERIFIED_FPC=1` into Stage 2. That coupling is
gone. The FPC check passes against the 5.0.0 node, and that pass is part of
the evidence this route rests on. If it stops passing, the skew has most likely
moved the derived FPC address, and a deploy past it is dead on arrival. The
script also clears any `ZERACLE_ALLOW_UNVERIFIED_FPC` inherited from `.env` or
the shell: only the flag can grant it.

The preflight summary prints what was relaxed: `Version gate: FORCED (node
5.0.0, SDK 5.2.0; --force-version)` and `Canonical SponsoredFPC: verified
(<address>)`.

Under the flag, the version gate accepts **any** node version. It does not
check that the node is still on 5.0.0. That is why the first pre-deploy check
below re-measures the node by hand.

### Pre-deploy checks (by hand, every run)

`--force-version` makes the version comparison non-fatal, so confirm by hand
that nothing else has moved. All four are read-only.

1. **The node is still the node this decision was made against.**
   ```sh
   curl -s -X POST -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"node_getNodeInfo","params":[]}' \
     https://v5.testnet.rpc.aztec-labs.com \
     | jq '{nodeVersion: .result.nodeVersion, l1ChainId: .result.l1ChainId, rollupVersion: .result.rollupVersion, rollup: .result.l1ContractAddresses.rollupAddress}'
   ```
   Expect `5.0.0`, `11155111`, `1821665230`, rollup
   `0xd73a91bdcf6891c7642f3e460036e1ef2cc23178`. To check the ENR protocol
   segment too:
   ```sh
   curl -s -X POST -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"node_getNodeInfo","params":[]}' \
     https://v5.testnet.rpc.aztec-labs.com | jq -r .result.enr \
     | python3 -c 'import sys,base64,re; e=sys.stdin.read().strip().removeprefix("enr:"); b=base64.urlsafe_b64decode(e+"="*(-len(e)%4)); m=re.search(rb"\d{2}-\d+-[0-9a-f]{8}-\d+-[0-9a-f]{8}-[0-9a-f]{8}",b); print(m.group().decode() if m else "no aztec segment")'
   ```
   Expect `00-11155111-d73a91bd-1821665230-2c075866-2b3b6ea4`. The last two
   segments are the protocol-contracts hash and the VK root; ZER-73 matched
   them to 5.2.0's.
   - If `nodeVersion` now equals `v1-l2`'s `@aztec/aztec.js` version, drop
     `--force-version`.
   - If only `nodeVersion` changed, and the rollup address, `rollupVersion`
     and the last two ENR segments did not, it is a plain version bump.
     Re-run checks 2 to 4. If they pass, the route still holds.
   - If the rollup address, `rollupVersion` or the last two ENR segments
     changed, the network or protocol changed, and addresses may have moved.
     **Stop.** This decision no longer covers it; re-plan with the owner
     (ZER-34).
2. **Canonical SponsoredFPC** (ZER-28), from `v1-l2`:
   ```sh
   cd v1-l2 && AZTEC_RPC_HOST=https://v5.testnet.rpc.aztec-labs.com yarn check:canonical-fpc
   ```
   Expect exit 0 and `"ok":true`, `"exists":true`, a non-zero `balance`, at
   `0x2ece607a8dba690c9aa4ee1d53a55286fa815543a27f9364bbaf65eb68e7315b`
   (ZER-71 measured this passing against the 5.0.0 node).
3. **HandshakeRegistry** (ZER-29), from `v1-l2`:
   ```sh
   cd v1-l2 && AZTEC_RPC_HOST=https://v5.testnet.rpc.aztec-labs.com yarn check:handshake
   ```
   Expect exit 0 and `"exists":true` at
   `0x06127814dca78709650de6629637194f7381d2e05b35eb9d53a4746636c9aa9d`
   (also measured passing by ZER-71).
4. **The whole Stage 0**, with the flag:
   ```sh
   cd deployments/testnet && ./deploy-testnet.sh --preflight-only --force-version
   ```
   Expect `PREFLIGHT PASS`. The flag adds three warnings, all from the version
   gate: the mismatch, "relaxes ONLY the version comparison", and a pointer to
   this section. Any warnings you would see without the flag, such as the
   missing `ETHERSCAN_API_KEY` or a reused fee-juice claim, still appear too.
   Any **failure** is a real one: fix it. Do not reach for another flag.

### The command

```sh
cd deployments/testnet
./deploy-testnet.sh --force-version
```

Run the script directly: `make -C deployments deploy-testnet` passes it no
arguments, so it cannot carry the flag. Do **not** add `--allow-unverified-fpc`
on this route. Check 2 passes, so it is not needed, and adding it would only
hide the one failure that means the skew has bitten.

### Residual risk accepted

What can break when a 5.2.0 SDK talks to the 5.0.0 node. The full table,
with evidence, is ZER-73's "Residual risk: a 5.2.0 SDK against the 5.0.0 node"
in the decision log.

| # | Risk | Assessment | Signal that it went wrong |
|---|---|---|---|
| R1 | Protocol, circuit or VK mismatch rejects proofs | Ruled out by ZER-73: the ENR's protocol hash and VK root match 5.2.0 | `sendTx` rejected with proof, vk-tree or protocol-hash errors; the first L2 account deploy in Stage 2 fails |
| R2 | RPC schema mismatch between client and node | Low: the 55 node methods are identical, and 5.0.0→5.2.0 wire changes only add upper bounds. On 2026-09-26 ZER-71 captured the live node's `node_getNodeInfo` reply (read-only) and served it from a loopback stub to the real 5.2.0 client (`createAztecNodeClient(...).getNodeInfo()`, the call Stage 0 makes), which parsed it cleanly. That covers this one method, not the other 54 | Zod parse errors on node calls in the deploy log or the browser console |
| R3 | Spurious "message does not exist" on an L2→L1 witness (the node lacks aztec-packages #24754) | Possible, transient | A keeper flush or withdraw-finalize fails once, then succeeds on retry. Repeats are the alert |
| R4 | `block_not_available` or "Could not find tx effect" after a reorg (#25206, #24765) | Possible, transient | Receipt-polling or deposit-claim errors that clear on retry. Persistent ones are a node problem: report upstream |
| R5 | Fee-quote rejection (#25344) | Likely when fees move | `maxFeesPerGas … must be ≥ gasFees` despite `withFeeHeadroom`: raise the padding |
| R6 | Missing `result` on JSON-RPC (#24840) | Certain for `undefined` results; the TS client, chain-view and `jq` handle it | A raw-RPC script treats a missing contract as a malformed reply |
| R7 | Canonical SponsoredFPC or HandshakeRegistry missing | Verified present by ZER-71; Stage 0 still checks both, fatally | Stage 0 fails; after deploy, account deploys fail on fee payment, or a fresh recipient never discovers notes |
| R8 | Handshake forgery protection (5.0.1) differs between clients | Client-to-client only. Every Zeracle user runs the 5.2.0 web client | Only a third-party 5.0.0 wallet would fail note discovery with Zeracle. Out of scope |
| R9 | Real-proof latency and memory in the browser | Unknown until ZER-39 measures it on this node | ZER-39 timings; browser OOM or tab crash; account deploys far slower than the sandbox |
| R10 | Proving lag delays exits (~40 min proven lag measured) | Certain | Exits pending 40 min or more. The keeper's proof-age budget must allow for it |

Not a risk from the skew, but it comes with this route: the version gate cannot
tell a 5.0.0 node from any other version while the flag is set. Pre-deploy
check 1 is the only thing that notices the node moving.

### If it goes wrong

- **Stage 0 fails on anything other than the version gate.** Nothing has been
  broadcast. Fix the cause and re-run `--preflight-only --force-version`.
  - If the FPC or HandshakeRegistry check fails, re-run pre-deploy checks 1
    to 3. A changed ENR protocol segment means stop and re-plan.
  - A missing HandshakeRegistry on an unchanged node is published with
    `cd v1-l2 && AZTEC_RPC_HOST=<node url> yarn deploy:handshake`.
- **Stage 1 fails.** Stage 1 is L1-only and uses nothing from the skew except
  the Inbox and Rollup addresses the node reported. See "Re-run semantics"
  below.
- **Stage 2 fails with a proof, VK or protocol-hash error (R1), or a Zod parse
  error (R2).** This is the skew biting. Stop: do not retry, and do not add
  flags.
  - Keep `deployer-account.json`, any `deployer-account.json.pending-claim.json`,
    and the full log. The pending claim holds bridged fee-asset that only that
    file can recover.
  - Re-measure the node (check 1), then take it back to ZER-34. The
    alternatives on record are waiting for the node to reach 5.2.0, or pinning
    to the node's version. The owner rejected the pin on 2026-09-26.
- **Stage 2 fails with a transient node error (R3, R4) or a fee-quote rejection
  (R5).** Re-run Stage 2 alone, as "Re-run semantics" describes (make sure
  `ZERACLE_ALLOW_UNVERIFIED_FPC` is not set in your shell: that command runs
  outside the script, which is what clears it). The reused
  `DEPLOYER_ACCOUNT_FILE` and pending claim make it safe. For R5, raise the fee
  padding first.
- **After deploy, user account deploys fail on fee payment.** Re-run
  `yarn check:canonical-fpc` against the node. Unfunded is an Aztec-side
  issue; missing means the node moved.
- **After deploy, a recipient never sees a transfer.** Re-run
  `yarn check:handshake`.
- **The node reports 5.2.0 or later.** Re-run Stage 0 without the flag. If it
  passes, drop `--force-version` from every later run.

## Deployer account

Unlike the sandbox (which uses a canonical, pre-deployed test account already
present in genesis), the testnet L2 deployer is a **real account with its own
keys** that must itself be deployed on-chain. `deploy-testnet.sh` exports
`DEPLOYER_ACCOUNT_FILE=deployments/testnet/deployer-account.json` before
calling `yarn deploy:clean`; `v1-l2/scripts/deploy.ts` reads it:

- **First run** (file doesn't exist): generates a fresh random Schnorr
  keypair, deploys it on-chain (paid atomically by the same
  `FeeJuicePaymentMethodWithClaim` fee-juice bootstrap that funds the FPC on
  sandbox), and writes the keys to `deployer-account.json` with `chmod 600`.
  The script logs LOUDLY when it does this.
- **Re-run** (file exists): reloads the same secret/salt/signing key and
  reconstructs the same account address instead of generating a new one —
  this is what makes `deploy-testnet.sh` safe to re-run after a mid-pipeline
  failure (see below) without losing control of contracts already deployed
  as the previous run's deployer.

**`deployments/testnet/deployer-account.json` holds real Sepolia-testnet
deployer private keys — back it up immediately after the first run, and
never commit it or ship it in a release tarball** (it's already in
`make-release-tarball.sh`'s exclude list — verify that hasn't regressed
before shipping, same as `.env`).

## Re-run semantics after a mid-pipeline failure

Every stage fails loud and stops immediately — nothing retries silently, with
one deliberate exception (ZER-29): if a forge target exits non-zero but the
contracts it records are all on-chain **and** `ETHERSCAN_API_KEY` was set, the
script treats it as an Etherscan verification failure, `warn`s with a retry
hint, and continues. Without the key, `--verify` is never attempted, so a
non-zero exit is always treated as a real failure. The deploy itself is never
assumed: Stage 1 re-reads every address it records, and for the bridge it also
reads back all four wirings, before tolerating anything.

Each `make` target is safe to re-run on its own once you've fixed the
underlying problem:

- If **Stage 1** fails partway (say, mock tokens deploy but the bridge
  deploy reverts), re-running `./deploy-testnet.sh` re-runs
  `deploy-testnet-l1`/`deploy-mocks-testnet` too — they aren't idempotent
  no-ops, so expect a fresh `local-testnet.json`/`tokens-testnet.json` (new
  addresses) each time you cross that point. If you only need to retry the
  bridge step, run `make -C v1-l1 deploy-bridge-testnet` directly with
  `ETH_RPC_URL`/`DEPLOYER_PRIVATE_KEY`/`INBOX_ADDRESS`/`ROLLUP_ADDRESS`
  exported yourself instead of re-running the whole script.
- If **Stage 2** fails, `v1-l1`'s outputs from Stage 1 are untouched;
  re-running the full script re-does Stage 1 too (see above) unless you
  invoke `stage_l2_deploy`'s underlying command directly:
  `cd v1-l2 && DEPLOYER_ACCOUNT_FILE=../deployments/testnet/deployer-account.json FEE_CUSTODIAN_ACCOUNT_FILE=../deployments/testnet/fee-custodian-account.json AZTEC_RPC_HOST=... L1_RPC_URL=... L1_DEPLOYER_PRIVATE_KEY=... L1_FEE_JUICE_PORTAL_ADDRESS=... L1_TOKEN_PORTAL=... L1_TREASURY=... L1_COLLATERAL_RESERVE=... L1_NETWORK_FUND=... DEPLOY_TX_TIMEOUT_SECS=600 ETH_CHAIN_ID=11155111 ZERACLE_COMPLIANCE=off ZERACLE_ENFORCE_FLUSH_MINIMUM=1 ZERACLE_FLUSH_MINIMUM=10000000000000000000 yarn deploy:clean`
  (the same variables `stage_l2_deploy` passes; take the L1 addresses from
  Stage 1's `v1-l1/deployments/*-testnet.json`). Run it from a shell where
  `ZERACLE_ALLOW_UNVERIFIED_FPC` is unset: outside the script nothing clears
  it, and set to `1` it skips `deploy.ts`'s own canonical-FPC abort (see "Deployer account" above — reusing the same `DEPLOYER_ACCOUNT_FILE`
  is what makes this safe to repeat). Run by hand, this skips the script's
  post-deploy checks, so before wiring check `deployment.json` yourself:
  `jq '{feeDistributionFlushMinimumEnforced, feeDistributionFlushMinimum}' v1-l2/deployment.json`
  must show `true` and `"10000000000000000000"` (ZER-32). If deploy succeeds but the bridge
  wiring assertion fails afterward, retry just that step with
  `ETH_RPC_URL=... DEPLOYER_PRIVATE_KEY=... make -C v1-l1 wire-bridge-testnet`.
- If **Stage 3** fails (e.g. `.env.testnet` missing), Stages 1-2's on-chain
  work already happened and does not need to be redone — just fix the
  problem and re-run `deploy-testnet.sh`; Stage 3 only reads existing JSON
  files and is safe to repeat as many times as needed (it overwrites the
  manifest and syncs the env file idempotently).

There is no dry-run/`DRY_RUN=1` flag by design — `--preflight-only` is the
supported way to check everything short of broadcasting.

## What "done" looks like

- `v1-l1/deployments/{local,tokens,bridge}-testnet.json` all exist and
  `jq` cleanly.
- `v1-l2/deployment.json` exists with all five L2 contract addresses, and
  `cast call <tokenPortal> "l2Bridge()(bytes32)"` on Sepolia returns the
  same `tokenBridge` address — i.e. the bridge is wired, not just deployed.
- `deployments/testnet/deployer-account.json` exists and has been backed up
  somewhere safe outside the repo.
- `deployments/testnet/deployment-manifest.json` exists and
  `interfaces/apps/web/.env.testnet` has every `VITE_*` var filled in (no
  blank values).
- From `interfaces/apps/web`, `yarn build:testnet` produces a bootable
  build — `src/config/env.ts` refuses to start with any empty endpoint, so
  a clean `build:testnet` is the concrete signal that the sync step
  actually worked.
- User transactions pay their L2 fees through **Aztec's canonical
  SponsoredFPC**, which Aztec deploys and funds (ZER-28). Zeracle deploys no
  FPC on testnet and there is no top-up step: the chain-view admin panel and
  `yarn fund:fpc` are both sandbox-only. The web app checks the sponsor's
  fee-juice balance at boot and fails with an explicit "fee sponsor has no
  funds" message if Aztec's instance is ever empty — that is an Aztec-side
  operational issue, not something a Zeracle deploy can fix.
- The canonical FPC's address is **derived, not configured**, and the
  derivation includes the contract class id — which changes between aztec
  versions. **Stage 0** preflights it, before any Sepolia broadcast, and
  aborts if no contract exists at the derived address; Stage 2 repeats the
  check as a second guard before it bridges. If either fires, check the
  node's aztec version against the `@aztec/*` versions in
  `v1-l2/package.json` first: it means the two disagree, not that anything
  needs funding. `--force-version` does **not** relax either check (ZER-71).
  The only override is `--allow-unverified-fpc`, which downgrades both to
  warnings; the deploy will then record an address that may have no contract
  behind it.
- To check it by hand against any node:
  `cd v1-l2 && AZTEC_RPC_HOST=<node url> yarn check:canonical-fpc`
- Stage 0 also preflights the standard **HandshakeRegistry** (ZER-29/T11).
  Cross-account private note discovery needs it published at the canonical
  address baked into the circuits, and its absence is **silent** — transfers
  land and the recipient simply never sees them. Whether Aztec's testnet has it
  at genesis is unverified, which is why this is checked rather than assumed.
  If it fires, publish it first and re-run:
  `cd v1-l2 && AZTEC_RPC_HOST=<node url> yarn deploy:handshake` — that script
  defaults to `http://localhost:8080`, so setting `AZTEC_RPC_HOST` explicitly
  is what stops you publishing against a local sandbox instead. It is a
  constructor-less universal deploy and is idempotent.
  To check by hand: `cd v1-l2 && AZTEC_RPC_HOST=<node url> yarn check:handshake`
- Read `docs/versions/260709/existing-limitations.md` §§1-2 before treating
  any of the above as feature-complete: the chain-server's sandbox-only
  infrastructure (on-demand block production, server-side account
  deployment, the account-address directory used for private-transfer
  discovery) has no testnet replacement yet, and the app has only ever been
  exercised against the sandbox's instant, on-demand blocks.
