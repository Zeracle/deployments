# Pi Chain Host

Runbook for the Raspberry Pi 5 chain host: anvil (L1) + Aztec sandbox (L2) +
block-producer + chain-server, provisioned and deployed by the scripts in
this directory. See the design spec at
`docs/superpowers/specs/2026-09-21-pi-chain-host-design.md` and the build
plan at `docs/superpowers/plans/2026-09-22-pi-chain-host-build.md` for the
full rationale and owner decisions referenced below.

## Hardware prereqs

- **Raspberry Pi 5, 8 GB RAM.** The design spec originally called for 16 GB;
  the owner accepted the 8 GB unit on 2026-09-22 (an 8 GB Pi reports ~7.8 GiB
  to the kernel — preflight floors at 7.5 GiB, not a literal 8.0). The 12 GiB
  swapfile (below) is the OOM guard for the `via_ir` compile on this smaller
  unit.
- **NVMe SSD as the boot/root disk.** `/data` is a **directory on the NVMe
  root**, not a separate mount or partition — do not format or fstab a data
  volume. Provisioning refuses to run if `/data`'s backing device is the SD
  card (`mmcblk*`) instead of NVMe (`nvme*`); that is the exact failure mode
  this design escapes.
- **A genuine 5V/5A USB-C supply and active cooling.** The Pi 5 undervolts or
  thermally throttles silently on marginal power/cooling — the resulting
  "up but too starved to finish SSH" state is what the throttle preflight
  (`vcgencmd get_throttled`) is there to catch before it happens under load.

## First run

Run from the laptop unless noted otherwise:

1. `bash deployments/pi/sync-to-pi.sh` — rsyncs the zeracle tree (`v1-l1`,
   `v1-l2`, `chain-server`, `deployments`, `interfaces`) to
   `pi:/opt/zeracle`, and stages `ops/` (systemd units + helper scripts) from
   `devops/production/ec2/files/ops/`. Re-run any time the laptop tree
   changes — it is `rsync --delete`, safe to repeat.
2. `ssh pi 'sudo mkdir -p /data && sudo chown admin:admin /data'` — create
   the data directory on the NVMe root. One-time; provisioning's preflight
   fails loudly if this is skipped or if `/data` resolves to the SD card.
3. `ssh pi 'bash /opt/zeracle/deployments/pi/provision-pi.sh'` — idempotent
   host setup: preflight, swapfile, Docker, Node/Yarn, Foundry, pinned solc,
   systemd units + Pi drop-ins (enabled, not started). Safe to re-run; a
   second run changes nothing (no reinstalls, no duplicated fstab/
   daemon.json/drop-in entries).
4. `ssh pi 'bash /opt/zeracle/deployments/pi/deploy-pi.sh'` — brings up
   anvil, waits for RPC, brings up the Aztec sandbox, waits for the PXE, then
   deploys contracts (first run) or resumes the persisted chain (later
   runs), and starts chain-server + block-producer.

**sudo/nvm convention:** run `provision-pi.sh` and `deploy-pi.sh` as the
`admin` user directly — **not** `sudo bash provision-pi.sh`. nvm and Foundry
install into the invoking user's `$HOME`; running the whole script under
`sudo` would install them into root's `$HOME` instead, which the systemd
units (and the `/usr/local/bin/{anvil,cast,forge}` symlinks provision
creates) do not expect. Each privileged step inside the scripts (swapfile,
`/etc/fstab`, Docker, `/etc/docker`, `/etc/systemd`, `systemctl`) is
individually prefixed with `sudo`, so the admin user only needs passwordless
(or interactive) `sudo` rights, not a root shell.

## Known limitation: an Aztec restart destroys the L2 chain

`aztec-sandbox` runs `start --local-network`, which is a **bootstrap** mode: it
re-bootstraps a fresh L2 chain on every start. `DATA_DIRECTORY` makes the node
write to `/data/aztec`, but it does **not** make it resume from there.

Verified 2026-09-22: with `/data/aztec` at 15 MB, `systemctl restart
aztec-sandbox` took the chain from height 38 to genesis (height 4) and every
deployed L2 contract was gone.

**Consequences**
- A reboot loses the L2 chain. L1 survives — anvil's `--state` genuinely persists.
- Recovery: remove `/data/deployment-manifest.json` and re-run `deploy-pi.sh`
  so it takes the first-run branch (~30 min). If L1 has sat idle for hours
  (nothing mined while L2 was down), the sandbox refuses to start with
  `Ethereum node is out of sync (last block synced N at T vs current time …)`;
  seen 2026-09-24. Then use "Force a fresh chain" below, which also resets L1.
- Do not restart `aztec-sandbox` casually. Treat it as destroying L2.

Real persistence needs the node run in a resuming mode rather than
`--local-network`, with the L1 rollup contracts deployed once and the node
syncing from L1. That is a separate piece of work.

## Running the fee round-trip e2e (ZER-17)

`make -C deployments e2e-pi` (or `make e2e-pi` from v1-l2) runs
`pi/e2e-pi.sh` on the box:

1. **Chain up.** No `/data/deployment-manifest.json`, or anvil/aztec-sandbox
   inactive → `deploy-pi.sh` (resume, or a ~30–35 min first-run deploy).
   Only chain-server/block-producer inactive → just starts them. Then waits
   for the L2 node to answer.
2. **Chain matches the manifest.** Every address the suite reads
   (`v1-l2/deployment.json`, `v1-l1/deployments/{bridge,local}.json`) must
   equal the manifest's, the FeeDistribution must exist on the L2 node, and
   the TokenPortal must have code on anvil. An L2 reset (see "Known limitation"
   below) is **reported, not repaired**: the fix is a fresh chain, which
   changes every address.
3. **Portal collateralised.** `scripts/bridge-deposit.ts --if-needed`
   deposits only when the portal is short of the shares the suite consumes.
4. **The suite**, with `ZERACLE_E2E_REQUIRE_SANDBOX=1` and any
   `ZERACLE_E2E_ALLOW_UNCOLLATERALISED` stripped, so green means it ran.

It prints per-step timings, on failure too. Measured 2026-09-24 on a live, collateralised
chain: chain-up 0 s, verify 0 s, collateral 15 s, suite 70 s, **total 85 s**.
It runs whatever code is on the box: `make -C deployments sync-pi` first to
test a branch (syncing contract changes does not redeploy them).

## Fee keeper (ZER-16)

The fee keeper (`lib/keeper/run-keeper.sh`) runs daily from `zeracle-keeper.timer` as `admin`, signing with anvil key #4. `provision-pi.sh` installs and enables the units.

`deploy-pi.sh` does four things for the keeper:
- stops the timer, and any run in flight, for the duration of the deploy;
- on a fresh chain, clears `/var/lib/zeracle-keeper/pending-flush`;
- regenerates `/etc/zeracle/keeper.env` from the manifest (`gen-keeper-env.sh`);
- starts the timer again.

`e2e-pi.sh` pauses the keeper during its fee round-trip.

The decision record, the measurement showing there's no ~2 h proof window on Aztec 5.2.0, and the day-2 commands are in `lib/keeper/README.md`. Alerting is an open gap: no channel exists, so check `systemctl list-units --failed` and `journalctl -u zeracle-keeper`.

## Day-2 ops

- **Logs:** `journalctl -u anvil`, `journalctl -u aztec-sandbox`,
  `journalctl -u chain-server`, `journalctl -u block-producer`,
  `journalctl -u zeracle-keeper` (add `-f` to
  follow, `-b` to scope to the current boot).
- **Restart order:** the units encode their own dependency chain via
  `Requires=`/`After=` — `aztec-sandbox` requires `docker.service` and
  `anvil.service`; `chain-server` requires `aztec-sandbox.service`;
  `block-producer` requires `chain-server.service`. Restarting a lower-level
  unit (e.g. `sudo systemctl restart anvil`) does **not** automatically
  restart the units above it — restart the chain top-down
  (`anvil` → `aztec-sandbox` → `chain-server` → `block-producer`) after any
  change that affects more than one layer.
- **Where state lives:** everything persistent is under `/data` (the NVMe
  root directory): `/data/anvil/state.json` (L1 chain state),
  `/data/aztec` (L2 sandbox state), `/data/chain-server` (account roster),
  `/data/docker` (Docker data-root), `/data/swapfile`,
  `/data/deployment-manifest.json` and `/data/public-manifest.json` (contract
  addresses from the last successful deploy).
- **How resume works:** `deploy-pi.sh` checks for
  `/data/deployment-manifest.json`. If present, it starts anvil (which
  reloads `/data/anvil/state.json`), regenerates `chain-server`'s env from
  the existing manifest, and starts the remaining services — no redeploy, no
  new contract addresses.
- **Force a fresh chain:** stop the services
  (`sudo systemctl stop zeracle-keeper.timer zeracle-keeper block-producer chain-server aztec-sandbox anvil`),
  then remove `/data/deployment-manifest.json`, `/data/public-manifest.json`,
  and `/data/anvil/state.json`, and re-run `deploy-pi.sh` — it will take the
  "first run" branch and deploy a fresh set of contracts. If `pi.env` or a
  drop-in changed, run `make -C deployments sync-pi provision-pi` first: the
  units are rendered from them only at provision time. Every address changes,
  so regenerate `.env.pi` afterwards (`make -C deployments web-env-pi`).

## Access

Private access only (spec Decision 3) — there is no Caddy, no public TLS,
and no tunnel in front of this host. Services bind loopback plus the
Tailscale interface (resolved at anvil start by `anvil-bind.sh`; other
services bind `0.0.0.0` behind the router/tailnet, which is acceptable for a
LAN-only host). Reach the host over Tailscale or the local network at:

- **Anvil RPC:** `<pi-tailscale-or-lan-ip>:8545`
- **Aztec PXE:** `<pi-tailscale-or-lan-ip>:8080`
- **chain-server:** `<pi-tailscale-or-lan-ip>:3001`

No `*.$DOMAIN` public endpoint is served from this host; `DOMAIN` in
`pi.env` is cosmetic only (used for parity with the EC2 deploy flow's env
shape). Re-homing the browser-facing PXE endpoint behind a public domain is
tracked as a separate ticket, not part of this build.

## Build host

- Compile with the pinned solc, not any solc `forge` finds on `PATH`:
  `FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-0.8.37`. This must equal
  `v1-l1/foundry.toml`'s `solc_version` (`0.8.37`); `install-solc.sh`
  asserts this directly and fails loudly on drift. `provision-pi.sh`
  gets the same protection transitively — it calls `install-solc.sh`
  as its last installer step.
- For routine `forge test` runs, use a 200-run optimizer profile — the
  default 10,000-run profile is reserved for size/gas-sensitive checks
  (`FOUNDRY_PROFILE=deploy forge build --sizes`), where the extra
  optimization time is worth it for EIP-170 headroom.
- The Pi is materially slower than a laptop/CI x86 box for `via_ir` compiles.
  Judge compile progress by growth of the `cache/`/`out/` build artifacts,
  not by watching the process tree — `forge`/`solc` can look idle for
  extended stretches while still working; killing and restarting on
  apparent hangs just restarts the clock.
