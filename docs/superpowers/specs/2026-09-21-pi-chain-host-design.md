# Raspberry Pi chain host — design and build spec

**Status:** approved 2026-09-21 · revised 2026-09-22 (solc source build removed) · **Repo:** deployments
**Audience:** an implementing agent with physical or SSH access to the Pi.

## Objective

Stand up a Raspberry Pi 5 (16 GB RAM, 1 TB NVMe) as the Zeracle chain host, replacing the retired EC2 box. It runs **both** roles EC2 ran:

- **Chain services** — anvil, Aztec sandbox, block producer, chain-server
- **Build host** — `forge build` / `forge test`

## Why EC2 was retired

It was a `t3.large` — burstable. Running the chain services continuously kept it in permanent CPU-credit deficit. On 2026-09-20 its credit balance sat at **0.0** while utilisation held at 90–95%, throttling it to baseline (~0.6 of a vCPU) under a `via_ir` compile. `sshd` could not complete a banner exchange. Credits only accrue *below* baseline, so it deadlocks: the compile needs credits, and credits need the compile to stop.

Structural, not a bad day. A separate 2026-09-18 rebuild hit the same symptom for a different reason — no swapfile — which `devops/production/ec2/files/ops/bootstrap.sh` documents as "sshd could not complete a banner exchange for 2.5 h".

The Pi removes both ceilings: 4 cores at full speed indefinitely, 16 GB instead of 8, NVMe instead of network-attached EBS.

## Feasibility — verified, do not re-litigate

| Component | arm64 status | How it was verified |
|---|---|---|
| Aztec `5.2.0` image | **published** | `linux/arm64` present in the Docker manifest list |
| Foundry (forge/cast/anvil) | **native arm64** | upstream ships aarch64 builds |
| `solc` **≥ 0.8.31** | **official binary** | `solc-static-linux-arm` GitHub asset; ELF header `e_machine 0xB7` = AArch64 |
| `solc` **≤ 0.8.30** | **none** | `binaries.soliditylang.org/linux-aarch64/list.json` → 404 (amd64 → 200) |
| `ethereum/solc:0.8.22` image | **amd64 only** | single-arch manifest, `architecture: amd64` |

**This is why `v1-l1` was upgraded to solc 0.8.37** (commit `c79c96b`, verified 721/721 with contract sizes inside EIP-170). That upgrade removes the need to build solc on ARM at all.

> **Revision note.** The 2026-09-21 version of this spec specified building solc 0.8.22 from source inside Docker, because no aarch64 binary exists for that version. The upgrade makes that unnecessary. `Dockerfile.solc`, the source build and the bytecode-equivalence check are **deleted from this design** — better provenance (an official binary, not one we built) and one less subsystem.

## Decisions

1. **The Pi is a platform layer, not a third copy of the deploy logic.** `deployments/sandbox-ec2/deploy-ec2.sh` is 82 lines because the real work lives in `deployments/sandbox-local/deploy-sandbox.sh` (886 lines) and runs *on* the host. Its header states the rule: *"One copy of the sandbox deploy logic serves both environments so they cannot drift."* The Pi is a second platform layer under that rule. **Do not modify `deploy-sandbox.sh`.**

2. **solc comes from the official GitHub release asset.** Pinned version, checksum recorded on first install. No source build, no Docker in the compile path.

3. **Private access only.** No Caddy, no public TLS, no tunnel. Services bind to loopback and the Tailscale/LAN interface.

   *Accepted consequence:* the public sandbox endpoints (`anvil.$DOMAIN`, `aztec.$DOMAIN`, `api.$DOMAIN`) stop being served, so `sandbox.zeracle.com`'s browser PXE has nothing to talk to. Re-homing that is a **separate ticket** — do not solve it here. Security-wise this is an improvement: a publicly reachable anvil with unlocked accounts was a standing exposure.

4. **Systemd units are reused, not forked.** `devops/production/ec2/files/ops/systemd/` defines `anvil`, `aztec-sandbox`, `block-producer` and `chain-server`. Install them with drop-in overrides for paths, bind addresses and resource limits.

5. **The Pi provisions a fresh chain.** EC2's persisted `/data` state is not migrated.

## Files to create

```
deployments/pi/
  README.md                 runbook: hardware prereqs, first run, day-2 ops
  provision-pi.sh           one-time host setup; idempotent; runs ON the Pi
  deploy-pi.sh              thin wrapper -> sandbox-local/{install-mock-feeds,deploy-sandbox}.sh
  toolchain/
    install-solc.sh         download + verify the official aarch64 binary
  systemd/
    *.conf                  drop-in overrides for the shared unit files
```

### `provision-pi.sh`

Idempotent — a second run must make no changes. Use the `step`/`ok`/`fail` helpers from `deploy-ec2.sh` so output matches the other platform layer, and `set -euo pipefail`.

**Preflight, all fatal, before anything is installed:**

| Assertion | Why |
|---|---|
| `uname -m` is `aarch64` | The whole toolchain choice depends on it |
| `/data` **already mounted**, backed by NVMe, not the SD card | Assert only — do **not** partition, format or mount. Disk layout is a human decision |
| RAM ≥ 8 GB | Below that, `via_ir` compiles thrash |
| `vcgencmd get_throttled` reports clean | See below |

The throttle check is the Pi-specific one and it is load-bearing. Undervoltage and thermal throttling reproduce **exactly** the symptom being escaped — a host that is up, accepting TCP, and too starved to finish an SSH handshake. An NVMe HAT plus four cores under sustained compile needs a genuine 5 V/5 A supply and active cooling; without them the migration buys nothing.

**Then, in order:**

1. **Swapfile on `/data`, never root.** Carries ZER-47's lesson forward — that guard existed only in notes that were never written, so it was lost on every instance replacement.
2. Docker, Node, Yarn.
3. Foundry (native arm64).
4. `toolchain/install-solc.sh`.
5. Systemd units plus drop-ins.

It does **not** deploy contracts. That is `deploy-sandbox.sh`'s job.

### `toolchain/install-solc.sh`

Downloads `solc-static-linux-arm` for the pinned version from the Solidity GitHub release, verifies its SHA-256 against a value committed in this repo, and installs it to `/opt/zeracle/toolchain/solc-<version>`.

- **Pinned version: `0.8.37`** — must match `v1-l1/foundry.toml`'s `solc_version`. If they drift, builds silently use a different compiler than CI and the deploy scripts expect. Assert equality and fail loudly if not.
- Wire it in with the **`FOUNDRY_SOLC`** environment variable so `v1-l1` needs no change.
- Upstream note: `ethereum/solidity` now redirects to **`argotorg/solidity`**; release assets download from there.
- **Verify after install:** `forge build --use <path>` on one contract, and confirm `forge --version` and the solc binary both run natively (`file` reports AArch64, not an interpreter).

### `deploy-pi.sh`

Mirrors `deploy-ec2.sh`: preflight, then hand off to `sandbox-local/install-mock-feeds.sh` followed by `sandbox-local/deploy-sandbox.sh` headless. No contract logic of its own.

## Error handling

`set -euo pipefail` throughout. Failures loud and specific, following `bootstrap.sh`'s precedent of asserting a mountpoint rather than trusting `mount -a`'s exit code: a wrong or missing `/data` must abort rather than silently fill the SD card — the Pi's equivalent of the root-volume exhaustion that hit EC2 twice.

## Testing

| Check | How | Pass condition |
|---|---|---|
| Shell correctness | `shellcheck` on every script | no errors |
| Idempotency | run `provision-pi.sh` twice | second run changes nothing |
| Toolchain | `forge --version`; `file $(which solc)` | both native AArch64 |
| Compiler matches config | installed solc vs `foundry.toml` | identical versions |
| Build | `FOUNDRY_PROFILE=deploy forge build --sizes` in `v1-l1` | no contract over EIP-170 |
| End to end | `forge test` in `v1-l1` | **721/721** |

That last figure is the number to beat: it is what the same suite scores on x86 at solc 0.8.37. Anything less means something about the ARM toolchain differs and must be explained before the host is trusted.

## Guidance for whoever implements this

- **The suite runs in seconds; compiling is what costs minutes.** On the retired host every painful wait was compilation. Set `FOUNDRY_PROFILE` to a 200-run profile for routine test runs and reserve the default 10,000-run profile for size and gas measurement.
- **`forge test` spawns no `solc` children once compilation finishes.** "No solc processes, low CPU" therefore looks identical to a stall. Judge progress by whether the output file is *growing*, not by the process tree. Misreading this cost a full compile cycle during the migration.
- **When a test fails on an event or log mismatch, read the trace before theorising.** The mismatch is often downstream of a revert that the trace names outright.
- **Never read `block.timestamp` across a `vm.warp`** in any test you touch — use `vm.getBlockTimestamp()`, including inside `_warp` helpers. Newer solc hoists the read. See commit `c79c96b` in `v1-l1`.

## Out of scope

- Re-homing the public sandbox endpoints (Decision 3)
- Secrets handling beyond what `gen-chain-server-env.sh` already does
- Migrating EC2's persisted `/data` state

## Open question for the owner

`optimizer_runs = 10000` with `via_ir` is `v1-l1`'s default profile, and it is what made every EC2 compile expensive. Profiles at `200` already exist. Routine test runs need neither size nor gas fidelity. Whether the default should change is a `v1-l1` decision, so it is noted here rather than made.
