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
  on a mismatch (`--force-version` overrides it, at your own risk).
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
   tokens (`make deploy-mocks-testnet`) → mock Chainlink price feeds
   (`install-mock-feeds.sh`, RPC-parameterized) → the TokenPortal bridge
   (`make deploy-bridge-testnet`, using the Inbox/Rollup addresses the
   preflight already fetched from the testnet node). Outputs land in
   `v1-l1/deployments/{local,tokens,bridge}-testnet.json` — the sandbox's
   `local.json`/`tokens.json`/`bridge.json` are never touched.
2. **L2 (Aztec testnet):** `yarn deploy:clean` from `v1-l2`, using the
   prebuilt artifacts and the L1 endpoint/key/portal address from step 1.
   Deploys ZeracleToken, TokenBridge, FeeDistribution, PaymentEscrow, and an
   (unfunded) SponsoredFPC. Output: `v1-l2/deployment.json`. The deployer
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
   `VITE_ETH_CHAIN_ID`).

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

Every stage fails loud and stops immediately — nothing retries silently.
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
  `cd v1-l2 && DEPLOYER_ACCOUNT_FILE=../deployments/testnet/deployer-account.json AZTEC_RPC_HOST=... L1_RPC_URL=... L1_DEPLOYER_PRIVATE_KEY=... L1_FEE_JUICE_PORTAL_ADDRESS=... DEPLOY_TX_TIMEOUT_SECS=600 yarn deploy:clean`
  (see "Deployer account" above — reusing the same `DEPLOYER_ACCOUNT_FILE`
  is what makes this safe to repeat). If deploy succeeds but the bridge
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
- The SponsoredFPC is deployed but **unfunded** — top it up via the
  chain-view admin panel before any sponsored user tx will go through.
- Read `docs/versions/260709/existing-limitations.md` §§1-2 before treating
  any of the above as feature-complete: the chain-server's sandbox-only
  infrastructure (on-demand block production, server-side account
  deployment, the account-address directory used for private-transfer
  discovery) has no testnet replacement yet, and the app has only ever been
  exercised against the sandbox's instant, on-demand blocks.
