# Raspberry Pi chain host (design)

**Status:** approved 2026-09-21 · **Repos:** deployments · **Supersedes:** the EC2 chain host for local use

## Objective

Replace the EC2 chain host with a Raspberry Pi 5 (16 GB RAM, 1 TB NVMe) that runs **both** roles the EC2 box ran: the chain services (anvil, Aztec sandbox, block producer, chain-server) and the build toolchain (`forge build` / `forge test`).

### Why the EC2 host is being retired

It is a `t3.large` — burstable. Running anvil, Aztec and chain-server continuously kept it in permanent CPU-credit deficit. On 2026-09-20 the credit balance sat at **0.0** while utilisation held at 90–95%, throttling the box to baseline (~0.6 of a vCPU) under a `via_ir` compile at `optimizer_runs = 10000`. `sshd` could not complete a banner exchange. Credits only accrue *below* baseline, so it deadlocks: the compile needs credits, and credits need the compile to stop.

This is structural, not a bad day. The 2026-09-18 rebuild hit the same class of failure for a different reason (no swapfile; `bootstrap.sh` documents "sshd could not complete a banner exchange for 2.5 h"). The Pi removes both the credit ceiling and the memory ceiling: 4 cores at full speed indefinitely, 16 GB instead of 8, NVMe instead of network-attached EBS.

## Feasibility, verified 2026-09-20

| Component | arm64 status | Consequence |
|---|---|---|
| Aztec `5.2.0` image | **published** (`linux/arm64` in the manifest list) | No change needed |
| Foundry (forge/cast/anvil) | **native arm64 builds** | No change needed |
| `solc 0.8.22` | **no official aarch64 binary** — `binaries.soliditylang.org/linux-aarch64/list.json` returns 404 (amd64 returns 200) | Must be built; see below |
| `ethereum/solc:0.8.22` image | **amd64 only** — single-arch manifest, `architecture: amd64` | Usable only under emulation; rejected |

solc is the one tool whose output *is* the product — it produces the bytecode that holds reserves — so its provenance matters more than any other component here.

## Decisions

1. **The Pi is a platform layer, not a third copy of the deploy logic.** `deployments/sandbox-ec2/deploy-ec2.sh` is 82 lines because the real work lives in `deployments/sandbox-local/deploy-sandbox.sh` (886 lines) and runs *on* the host. Its header states the rule: *"One copy of the sandbox deploy logic serves both environments so they cannot drift."* The Pi becomes a second platform layer under the same rule. `deploy-sandbox.sh` is not modified.

2. **solc is built from official source, natively, inside Docker.** A `Dockerfile.solc` fetches the published 0.8.22 source tarball, verifies its checksum, and builds for arm64. The resulting binary is extracted to `/opt/zeracle/toolchain/` and invoked directly — **no container in the hot path**. Docker is the build environment only.

   Rejected: a third-party prebuilt aarch64 binary (unvetted provenance for the one tool where it matters most); emulated amd64 solc under qemu (2–10× penalty on the expensive path, plausibly leaving the Pi slower than the box being retired); building on the host (leaves a full C++ toolchain permanently installed on a machine that is also the chain host).

3. **`v1-l1` is not modified.** The compiler is wired in through the `FOUNDRY_SOLC` environment variable. `foundry.toml` keeps `solc_version = "0.8.22"` and the change stays contained to `deployments/`.

4. **Private access only.** No Caddy, no public TLS, no tunnel. Services bind to loopback and the Tailscale/LAN interface. The Pi sits behind a residential connection whose address rotated twice within one hour on 2026-09-20, so public DNS would be unreliable regardless.

   *Consequence, accepted by the owner:* the public sandbox endpoints (`anvil.$DOMAIN`, `aztec.$DOMAIN`, `api.$DOMAIN`) stop being served, so `sandbox.zeracle.com`'s browser PXE has nothing to talk to. Re-homing the public sandbox is a separate ticket. Security-wise this is a net improvement: a publicly reachable anvil with unlocked accounts was a standing exposure.

5. **Systemd units are reused, not forked.** `devops/production/ec2/files/ops/systemd/` already defines `anvil`, `aztec-sandbox`, `block-producer` and `chain-server`. These are platform-neutral; the Pi installs them with drop-in overrides for paths, bind addresses and resource limits.

## Architecture

```
deployments/pi/
  README.md                 runbook: hardware prereqs, first run, day-2 ops
  provision-pi.sh           one-time host setup; idempotent; runs ON the Pi
  deploy-pi.sh              thin wrapper -> sandbox-local/{install-mock-feeds,deploy-sandbox}.sh
  verify-toolchain.sh       bytecode-equivalence check against official x86 solc
  toolchain/
    Dockerfile.solc         official source -> native aarch64 solc
    build-solc.sh           build, extract to /opt/zeracle/toolchain, idempotent
  systemd/
    *.conf                  drop-in overrides for the shared unit files
```

### `provision-pi.sh`

Idempotent, and asserts before it acts. Preflight, all fatal:

- `uname -m` is `aarch64`
- `/data` is **already mounted** and backed by an NVMe device, not the SD card — the script asserts this and aborts; it does not partition, format or mount anything. Disk layout is a human decision made once, and a script that formats storage on a machine it has just met is not a trade worth making
- RAM ≥ 8 GB
- `vcgencmd get_throttled` reports clean

That last check is the Pi-specific one and it matters: undervoltage and thermal throttling reproduce *exactly* the symptom being escaped — a box that is up, accepting TCP, and too starved to finish an SSH handshake. An NVMe HAT plus four cores under sustained compile needs a genuine 5 V/5 A supply and active cooling; without them the migration buys nothing.

Then, in order: swapfile **on `/data`, never root** (carrying ZER-47's lesson forward, where the guard existed only in notes that were never written and was lost on every instance replacement); Docker; Node and Yarn; native-arm64 Foundry; `toolchain/build-solc.sh`; systemd units and drop-ins.

It does **not** deploy contracts. That is `deploy-sandbox.sh`'s job, unchanged.

### `verify-toolchain.sh`

Compiles a canonical contract with the self-built solc and diffs the **runtime bytecode** against a committed reference produced by the official amd64 binary.

solc output should be platform-independent for a given version and settings, but "should be" is not sufficient for a compiler that produces deployed contracts. If a from-source arm64 build ever diverges, this fails during provisioning rather than when a deployed contract fails source verification. Run as the last step of `provision-pi.sh` and available standalone.

### `deploy-pi.sh`

Mirrors `deploy-ec2.sh`: preflight, then hand off to `sandbox-local/install-mock-feeds.sh` followed by `sandbox-local/deploy-sandbox.sh` in headless mode. No contract logic of its own.

## Error handling

`set -euo pipefail` throughout, with the `step`/`ok`/`fail` helpers already used by `deploy-ec2.sh` so output is consistent across platform layers.

Failures are loud and specific, following `bootstrap.sh`'s precedent of asserting a mountpoint rather than trusting `mount -a`'s exit code: a wrong or missing `/data` must abort rather than silently fill the SD card, which is the Pi's equivalent of the root-volume exhaustion that hit EC2 twice.

## Testing

| Check | How |
|---|---|
| Shell correctness | `shellcheck` on every script |
| Idempotency | `provision-pi.sh` run twice; the second run makes no changes |
| Compiler provenance | `verify-toolchain.sh` bytecode diff against the committed x86 reference |
| End to end | `forge test --match-path test/unit/BasketManagerTranche.t.sol` |

The last one is also the fastest signal that the migration worked: that suite executes in **938 ms** once compiled. Every bit of the pain on EC2 was compilation, not testing.

## Out of scope

- Re-homing the public sandbox endpoints (separate ticket; see Decision 4)
- Secrets handling beyond what `gen-chain-server-env.sh` already does
- Migrating EC2's persisted `/data` state; the Pi provisions a fresh chain

## Open question

`optimizer_runs = 10000` with `via_ir` is the default profile and is what made every EC2 compile expensive. Profiles at `200` already exist in `foundry.toml`. Routine test runs do not need size or gas fidelity, only the deploy and size-measurement paths do. Worth deciding whether the Pi's default should be the cheap profile — it is a `v1-l1` change, so it is noted here rather than made.
