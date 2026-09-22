# Raspberry Pi Chain Host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision the Raspberry Pi 5 as the Zeracle chain host (anvil + Aztec sandbox + block-producer + chain-server) and build host (`forge build`/`forge test`), as a thin platform layer over the existing `sandbox-local` deploy logic.

**Architecture:** New `deployments/pi/` scripts run *on* the Pi. `provision-pi.sh` does idempotent host setup (swap, Docker/Node/Yarn, Foundry, pinned solc, systemd units + Pi drop-ins). `deploy-pi.sh` mirrors EC2 `bootstrap.sh` steps 5–6 (deploy-once/resume orchestration) and hands the actual contract work to the untouched `sandbox-local/deploy-sandbox.sh` run headless (`CHAIN_HOST_HEADLESS=1`). The four EC2 systemd units are reused via the same `@REPO@/@DATA@/@AZTEC_TAG@/@MAINNET@` `sed` substitution, plus Pi-specific drop-in overrides for resource limits and bind address.

**Tech Stack:** Bash (`set -euo pipefail`), systemd (system units + `.d` drop-ins), Docker, Node/Yarn, Foundry (native arm64), solc 0.8.37 (official aarch64 GitHub asset), Aztec `aztecprotocol/aztec:5.2.0` (linux/arm64).

**Spec:** `deployments/docs/superpowers/specs/2026-09-21-pi-chain-host-design.md`

## Global Constraints

- **Arch:** `aarch64` only — fatal preflight. Verified: Pi 5 Model B, `aarch64`.
- **solc pinned `0.8.37`** — must equal `v1-l1/foundry.toml`'s `solc_version` (verified `= "0.8.37"`). Assert equality; fail loudly on drift. Wire via `FOUNDRY_SOLC` env var — do **not** edit `v1-l1`.
- **solc source:** official aarch64 asset `solc-static-linux-arm` from the Solidity GitHub release; upstream `ethereum/solidity` now redirects to **`argotorg/solidity`**. Install to `/opt/zeracle/toolchain/solc-0.8.37`. Verify SHA-256 against a value committed in this repo.
- **`REPO=/opt/zeracle`** — the whole zeracle tree lives here on the Pi, including an `ops/` dir staged from `devops/production/ec2/files/ops/`.
- **`DATA_MOUNT=/data`** — **OWNER DECISION (2026-09-22): a directory on the NVMe root, not a separate mount.** Preflight asserts `/data` exists and its backing device is NVMe (`nvme*`), *not* the SD card (`mmcblk*`). Do **not** partition/format/mount. No fstab data-volume entry (root already covers `/data`).
- **8 GB RAM + swapfile on `/data`** — **OWNER DECISION (2026-09-22): proceed on this 8 GB unit** (spec Objective says 16 GB; actual is 7.8 GiB). Swapfile is the OOM guard for the `via_ir` compile; size generously (see Task 3).
- **Private access only** (spec Decision 3): no Caddy, no public TLS, no tunnel. Services bind loopback + the Tailscale interface. Public `*.$DOMAIN` endpoints are intentionally not served (separate ticket).
- **Unforked anvil:** `@MAINNET@` substitutes to empty; mock Chainlink feeds are installed by `anvil.service` `ExecStartPost` (`ops/anvil-mock-feeds.sh`). No `MAINNET_RPC_URL` needed.
- **Fresh chain** (spec Decision 5): EC2's persisted `/data` is **not** migrated.
- **Do not modify** `deploy-sandbox.sh` (spec Decision 1).
- **Style:** every script `set -euo pipefail`, idempotent (a second run changes nothing), `step`/`ok`/`fail` helpers matching `deploy-ec2.sh`, failures loud and specific.
- **Aztec image tag:** `5.2.0` (arm64 manifest verified in spec).

## Pi ground truth (verified 2026-09-22, do not re-verify)

| Fact | Value |
|---|---|
| Model / arch | Pi 5 Model B Rev 1.0 / `aarch64` |
| RAM | 7.8 GiB (8 GB unit) |
| Disk | single `nvme0n1p2` 931 GB at `/`; no `/data` yet; SD not in use |
| `get_throttled` | `0x0` (clean) |
| Swap | none |
| Toolchain | docker/node/yarn/forge/cast/anvil/solc all **absent**; no `/opt/zeracle`; no zeracle units |
| SSH | `ssh pi` (admin@192.168.31.37, key `~/.ssh/raspberry`) — configured this session |
| Tailscale | up; this Pi is a tailnet node under `mauricetjmurphy@` |

---

## Task 0: Stage the repo onto the Pi at `/opt/zeracle`

Not in the spec — the spec assumes the tree is already at `/opt/zeracle`. It is not. This task delivers it and is a prerequisite for every other task on the Pi.

**Files:**
- Create: `deployments/pi/sync-to-pi.sh` (laptop-side helper; rsync the tree)

**Interfaces:**
- Produces: `/opt/zeracle/` on the Pi containing `v1-l1/`, `v1-l2/`, `chain-server/`, `deployments/`, `interfaces/apps/web/`, and `ops/` (staged from `devops/production/ec2/files/ops/`). `REPO=/opt/zeracle` everywhere downstream.

- [ ] **Step 1: Write `sync-to-pi.sh`**

Rsync from the laptop zeracle root to the Pi. Excludes build artifacts and secrets; stages `ops/` from the EC2 files dir so the units' `@REPO@/ops/...` paths resolve.

```bash
#!/usr/bin/env bash
# Push the zeracle tree to the Pi at /opt/zeracle. Run from the laptop.
set -euo pipefail
PI="${PI_HOST:-pi}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # zeracle root (deployments/pi -> ../..)
REMOTE=/opt/zeracle
ssh "$PI" "sudo mkdir -p $REMOTE && sudo chown \$(id -u):\$(id -g) $REMOTE"
# Main tree. --delete keeps the Pi in sync; excludes keep it lean and safe.
rsync -a --delete \
  --exclude '.git' --exclude 'node_modules' --exclude 'artifacts' --exclude 'cache' \
  --exclude 'dist' --exclude 'out' --exclude '**/.env' --exclude '**/.env.local' \
  --exclude 'deployments/pi/toolchain/solc-*' \
  "$ROOT/v1-l1" "$ROOT/v1-l2" "$ROOT/chain-server" "$ROOT/deployments" \
  "$ROOT/interfaces" "$PI:$REMOTE/"
# Stage ops/ (systemd units + helpers) from the EC2 files dir.
rsync -a --delete "$ROOT/devops/production/ec2/files/ops/" "$PI:$REMOTE/ops/"
echo "Synced to $PI:$REMOTE"
```

- [ ] **Step 2: shellcheck it** — `shellcheck deployments/pi/sync-to-pi.sh` → no errors.
- [ ] **Step 3: Run it** — `bash deployments/pi/sync-to-pi.sh`.
- [ ] **Step 4: Verify on the Pi**

Run: `ssh pi 'ls -d /opt/zeracle/{v1-l1,v1-l2,chain-server,deployments,ops,ops/systemd,ops/anvil-mock-feeds.sh,ops/gen-chain-server-env.sh}'`
Expected: all present, no "No such file".

- [ ] **Step 5: Commit** — `git add deployments/pi/sync-to-pi.sh && git commit -m "feat(pi): add repo sync helper for the Pi chain host"`

> **Note on Node/Yarn deps:** `deploy-sandbox.sh` needs `v1-l2`/`chain-server`/`web` dependencies installed. `node_modules` is rsync-excluded (arch-specific, huge). Task 4 installs Node/Yarn; the deploy step (Task 6) runs `yarn install` on the Pi as needed, or `sync-to-pi.sh` is re-run without the `node_modules` exclude for the JS packages. Decide during Task 6; default is install-on-Pi.

---

## Task 1: `pi/pi.env` — host config defaults

**Files:**
- Create: `deployments/pi/pi.env`

**Interfaces:**
- Produces: env vars sourced by `provision-pi.sh` and `deploy-pi.sh`: `REPO`, `DATA_MOUNT`, `SWAP_SIZE_GIB`, `AZTEC_IMAGE_TAG`, `SOLC_VERSION`, `ANVIL_BIND`, `MAINNET_RPC_URL` (empty), `DOMAIN` (cosmetic only).

- [ ] **Step 1: Write `pi.env`**

```bash
# Pi chain-host config. Sourced by provision-pi.sh and deploy-pi.sh.
REPO=/opt/zeracle
DATA_MOUNT=/data
# 8 GB RAM, via_ir @ 10000 runs. 12 GiB matches EC2's ZER-47 default; NVMe swap
# is fast enough to absorb the first-run compile spike.
SWAP_SIZE_GIB=12
AZTEC_IMAGE_TAG=5.2.0
SOLC_VERSION=0.8.37
# Private access (spec Decision 3): loopback + Tailscale interface. Resolved at
# service start (systemd ExecStartPre) to the current `tailscale ip -4`; empty
# here means "loopback only" if Tailscale is down.
ANVIL_BIND=tailscale
# Unforked anvil (mock feeds instead of a mainnet fork).
MAINNET_RPC_URL=
# Cosmetic only on the Pi (no public endpoints are served).
DOMAIN=pi.local
```

- [ ] **Step 2: Verify it sources cleanly** — `bash -c 'set -euo pipefail; . deployments/pi/pi.env; echo "$REPO $DATA_MOUNT $SWAP_SIZE_GIB $AZTEC_IMAGE_TAG $SOLC_VERSION"'` → prints the values.
- [ ] **Step 3: Commit** — `git commit -am "feat(pi): host config defaults (pi.env)"`

---

## Task 2: `toolchain/install-solc.sh` — pinned aarch64 solc

**Files:**
- Create: `deployments/pi/toolchain/install-solc.sh`
- Create: `deployments/pi/toolchain/solc-0.8.37.sha256` (checksum, recorded on first fetch)

**Interfaces:**
- Consumes: `SOLC_VERSION` (from `pi.env`; default `0.8.37`).
- Produces: `/opt/zeracle/toolchain/solc-0.8.37` (native AArch64 ELF, `+x`). Callers set `FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-<version>`.

- [ ] **Step 1: Fetch + record the checksum once (manual, produces the committed value)**

Run on the Pi (or any aarch64 host):
```bash
V=0.8.37
curl -fL -o /tmp/solc "https://github.com/argotorg/solidity/releases/download/v${V}/solc-static-linux-arm"
sha256sum /tmp/solc | awk '{print $1}'   # copy this value
file /tmp/solc                            # must say ELF 64-bit ... ARM aarch64
```
Write the hash into `deployments/pi/toolchain/solc-0.8.37.sha256` as `<hash>  solc-static-linux-arm`.
> If the `argotorg` asset name/path 404s, fall back to `ethereum/solidity` (redirects) and record whichever URL resolved. Do not invent the hash — it must come from the real download.

- [ ] **Step 2: Write `install-solc.sh`**

```bash
#!/usr/bin/env bash
# Install the pinned, official aarch64 solc for the Pi chain host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${SOLC_VERSION:-0.8.37}"
DEST_DIR=/opt/zeracle/toolchain
DEST="$DEST_DIR/solc-$VERSION"
SUMFILE="$SCRIPT_DIR/solc-$VERSION.sha256"
ASSET="solc-static-linux-arm"
URL="https://github.com/argotorg/solidity/releases/download/v$VERSION/$ASSET"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "\n${BLUE}==>${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
fail(){ echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

# Pin must match v1-l1/foundry.toml, or CI and the deploy use different compilers.
CFG_SOLC="$(grep -E '^\s*solc_version' /opt/zeracle/v1-l1/foundry.toml | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/')"
[ "$CFG_SOLC" = "$VERSION" ] || fail "solc pin $VERSION != v1-l1/foundry.toml solc_version $CFG_SOLC"
[ -f "$SUMFILE" ] || fail "missing committed checksum $SUMFILE"

if [ -x "$DEST" ] && (cd "$DEST_DIR" && sha256sum -c <(sed "s#$ASSET#solc-$VERSION#" "$SUMFILE") >/dev/null 2>&1); then
  ok "solc $VERSION already installed and checksum-valid ($DEST)"
else
  step "Downloading solc $VERSION ($ASSET)"
  mkdir -p "$DEST_DIR"
  tmp="$(mktemp)"; curl -fL -o "$tmp" "$URL" || fail "download failed: $URL"
  echo "$(awk '{print $1}' "$SUMFILE")  $tmp" | sha256sum -c - >/dev/null 2>&1 \
    || fail "SHA-256 mismatch for downloaded solc — refusing to install"
  install -m 0755 "$tmp" "$DEST"; rm -f "$tmp"
  ok "installed $DEST"
fi

step "Verify native + runnable"
file "$DEST" | grep -q 'aarch64' || fail "$DEST is not an AArch64 binary"
"$DEST" --version >/dev/null || fail "$DEST failed to run"
ok "$("$DEST" --version | tail -1)"
```

- [ ] **Step 3: shellcheck** → no errors.
- [ ] **Step 4: Run on the Pi** — `ssh pi 'SOLC_VERSION=0.8.37 bash /opt/zeracle/deployments/pi/toolchain/install-solc.sh'`
Expected: installs, `file` reports AArch64, prints `Version: 0.8.37...`.
- [ ] **Step 5: Idempotency** — run again → "already installed and checksum-valid", no re-download.
- [ ] **Step 6: `FOUNDRY_SOLC` smoke build** (after Foundry exists — may defer to Task 4/8)
Run: `ssh pi 'cd /opt/zeracle/v1-l1 && FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-0.8.37 forge build --use /opt/zeracle/toolchain/solc-0.8.37 contracts/... --sizes'` on one contract → compiles.
- [ ] **Step 7: Commit** — `git add deployments/pi/toolchain && git commit -m "feat(pi): install pinned aarch64 solc 0.8.37 with checksum verify"`

---

## Task 3: `provision-pi.sh` part A — preflight + swapfile

**Files:**
- Create: `deployments/pi/provision-pi.sh` (preflight + swap; installers added in Task 4)

**Interfaces:**
- Consumes: `pi.env`.
- Produces: fatal-on-failure preflight; a `$DATA_MOUNT/swapfile` active + in `/etc/fstab` (`nofail`); `$DATA_MOUNT/{docker,anvil,aztec,chain-server}` created.

- [ ] **Step 1: Write the header, helpers, and preflight**

```bash
#!/usr/bin/env bash
# One-time, idempotent host setup for the Pi chain host. Runs ON the Pi.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pi.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "\n${BLUE}==>${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
fail(){ echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

step "Preflight (all fatal)"
[ "$(uname -m)" = "aarch64" ] || fail "arch is $(uname -m), not aarch64 — wrong toolchain host"
ok "arch aarch64"

# /data: OWNER DECISION — a directory on the NVMe root, not a separate mount.
# Assert it exists and its backing device is NVMe, never the SD card.
[ -d "$DATA_MOUNT" ] || fail "$DATA_MOUNT does not exist — create it on the NVMe first (mkdir /data)"
DATA_SRC="$(findmnt -no SOURCE -T "$DATA_MOUNT")"
case "$DATA_SRC" in
  /dev/nvme*) ok "$DATA_MOUNT backed by NVMe ($DATA_SRC)";;
  /dev/mmcblk*) fail "$DATA_MOUNT is on the SD card ($DATA_SRC) — refuse (SD is slow and the thing we escaped)";;
  *) fail "$DATA_MOUNT backing device $DATA_SRC is not NVMe";;
esac

# RAM >= 8 GB nominal. An 8 GB Pi reports ~7.8 GiB (GPU/reserved), so assert
# >= 7.5 GiB rather than a literal 8.0.
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
[ "$MEM_KB" -ge 7500000 ] || fail "RAM ${MEM_KB}kB < 7.5 GiB floor — via_ir compiles will thrash"
ok "RAM $((MEM_KB/1024)) MiB"

# Pi-specific and load-bearing: undervoltage/thermal throttle reproduces the
# exact 'up but too starved to finish SSH' failure being escaped.
if command -v vcgencmd >/dev/null; then
  T="$(vcgencmd get_throttled)"; [ "$T" = "throttled=0x0" ] || fail "$T — fix power/cooling before provisioning"
  ok "throttle clean"
else
  echo -e "${YELLOW}  ! vcgencmd absent; cannot verify throttle${NC}"
fi
```

- [ ] **Step 2: Add the swapfile block (idempotent, adapted from `bootstrap.sh` §1b)**

```bash
step "Swapfile on $DATA_MOUNT (OOM guard for the via_ir compile)"
mkdir -p "$DATA_MOUNT"/{docker,anvil,aztec,chain-server}
SWAP_FILE="$DATA_MOUNT/swapfile"; SWAP_GIB="${SWAP_SIZE_GIB:-12}"
if swapon --show=NAME --noheadings | grep -qx "$SWAP_FILE"; then
  ok "swap already active ($SWAP_FILE)"
else
  if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l "${SWAP_GIB}G" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GIB*1024))
    chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE"
  ok "swap on ($SWAP_GIB GiB)"
fi
# Persist across reboot; nofail so a missing swapfile never blocks boot.
grep -q "^${SWAP_FILE} " /etc/fstab || echo "$SWAP_FILE none swap sw,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
ok "swap in fstab"
```

> `fallocate`/`swapon`/`tee /etc/fstab` need root. Run `provision-pi.sh` under `sudo`, or guard privileged lines with `sudo`. Decide one convention (recommended: run the whole script with `sudo -E` so `pi.env` and `$HOME` for Foundry are handled explicitly in Task 4). Document in README.

- [ ] **Step 3: shellcheck** → no errors.
- [ ] **Step 4: Create `/data` on the Pi (owner-approved directory-on-NVMe)** — `ssh pi 'sudo mkdir -p /data && sudo chown admin:admin /data'`
- [ ] **Step 5: Run preflight+swap** — `ssh pi 'sudo -E bash /opt/zeracle/deployments/pi/provision-pi.sh'` (will stop after swap until Task 4 adds installers).
Expected: all preflight ✓; swap active; `ssh pi 'swapon --show && free -h'` shows 12 GiB swap.
- [ ] **Step 6: Idempotency** — run again → "swap already active", fstab not duplicated.
- [ ] **Step 7: Commit** — `git commit -am "feat(pi): provision preflight + swapfile"`

---

## Task 4: `provision-pi.sh` part B — Docker, Node, Yarn, Foundry, solc

**Files:**
- Modify: `deployments/pi/provision-pi.sh` (append installer section)

**Interfaces:**
- Consumes: preflight/swap from Task 3; `install-solc.sh` from Task 2.
- Produces: `docker`, `node`, `yarn`, `forge`/`cast`/`anvil` on PATH; solc at `/opt/zeracle/toolchain/solc-0.8.37`; `admin` in the `docker` group.

- [ ] **Step 1: Append installers (each idempotent)**

```bash
step "Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "${SUDO_USER:-$USER}"
  ok "docker installed (re-login for group, or use sudo docker until then)"
else ok "docker present ($(docker --version))"; fi
sudo systemctl enable --now docker
# Point Docker's data-root at NVMe /data (keeps images off any small partition).
sudo mkdir -p "$DATA_MOUNT/docker"
if [ ! -f /etc/docker/daemon.json ]; then
  echo "{\"data-root\": \"$DATA_MOUNT/docker\"}" | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
fi

step "Node + Yarn (via nvm for the invoking user)"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install 20 >/dev/null; nvm alias default 20 >/dev/null
corepack enable >/dev/null 2>&1 || npm i -g yarn >/dev/null
ok "node $(node -v), yarn $(yarn -v 2>/dev/null || echo '?')"

step "Foundry (native arm64)"
if ! command -v forge >/dev/null; then
  curl -fsSL https://foundry.paradigm.xyz | bash
  # shellcheck disable=SC1090
  . "$HOME/.bashrc" 2>/dev/null || true
  "$HOME/.foundry/bin/foundryup"
fi
export PATH="$HOME/.foundry/bin:$PATH"
file "$(command -v anvil)" | grep -q aarch64 || fail "anvil is not a native aarch64 binary"
ok "$(forge --version | head -1)"

step "Pinned solc"
SOLC_VERSION="$SOLC_VERSION" bash "$SCRIPT_DIR/toolchain/install-solc.sh"
```

> **nvm-vs-sudo caveat:** nvm/Foundry install into the invoking user's `$HOME`. Under `sudo -E`, `$HOME` may be root's. Recommended convention: run privileged steps (swap, docker, fstab, systemd) with explicit `sudo` inside the script, but run the script itself as the `admin` user (not `sudo bash`). Adjust Task 3's run command to match once decided; keep it consistent and documented in the README.

- [ ] **Step 2: shellcheck** → no errors (allow the SC1090/SC1091 source disables).
- [ ] **Step 3: Run full provision** — `ssh pi 'bash /opt/zeracle/deployments/pi/provision-pi.sh'`
Expected: docker enabled, node 20, yarn, native arm64 forge/anvil, solc 0.8.37 installed.
- [ ] **Step 4: Idempotency** — run again → everything "present", no reinstalls, no fstab/daemon.json duplication.
- [ ] **Step 5: Verify** — `ssh pi 'docker run --rm hello-world >/dev/null && echo docker-ok; file $(which anvil); /opt/zeracle/toolchain/solc-0.8.37 --version | tail -1'`
- [ ] **Step 6: Commit** — `git commit -am "feat(pi): install docker/node/yarn/foundry/solc"`

---

## Task 5: systemd units + Pi drop-ins

**Files:**
- Create: `deployments/pi/systemd/anvil.service.d/pi.conf` (template: bind + limits)
- Create: `deployments/pi/systemd/aztec-sandbox.service.d/pi.conf` (limits)
- Create: `deployments/pi/systemd/chain-server.service.d/pi.conf` (bind + limits)
- Create: `deployments/pi/systemd/block-producer.service.d/pi.conf` (limits)
- Create: `deployments/pi/systemd/anvil-bind.sh` (ExecStartPre: resolve Tailscale IP → env file)
- Modify: `deployments/pi/provision-pi.sh` (append: substitute + install units and drop-ins)

**Interfaces:**
- Consumes: `/opt/zeracle/ops/systemd/*.service` (from Task 0), `pi.env` (`ANVIL_BIND`, `AZTEC_IMAGE_TAG`, `DATA_MOUNT`, `REPO`).
- Produces: four enabled system units in `/etc/systemd/system/` with `@`-placeholders substituted, plus `.d/pi.conf` drop-ins. Units **enabled**, not started (Task 6 orchestrates start).

- [ ] **Step 1: `anvil-bind.sh` — resolve the private bind address at start**

```bash
#!/usr/bin/env bash
# ExecStartPre for anvil: write the extra --host flag for the Tailscale iface.
# Loopback is always bound; this adds the tailnet IP when ANVIL_BIND=tailscale.
set -euo pipefail
OUT=/run/zeracle/anvil-bind.env
mkdir -p /run/zeracle
BIND=""
if [ "${ANVIL_BIND:-tailscale}" = "tailscale" ] && command -v tailscale >/dev/null; then
  IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$IP" ] && BIND="--host $IP"
fi
echo "ANVIL_EXTRA_HOST=$BIND" > "$OUT"
```

- [ ] **Step 2: `anvil.service.d/pi.conf` (template — provision seds `@DATA@`/`@MAINNET@`)**

Drop-in overrides `ExecStart` to bind loopback + Tailscale and caps memory. `ExecStart=` (empty) first clears the unit's value, per systemd.

```ini
[Service]
EnvironmentFile=-/run/zeracle/anvil-bind.env
Environment=ANVIL_BIND=@ANVIL_BIND@
ExecStartPre=/opt/zeracle/deployments/pi/systemd/anvil-bind.sh
ExecStart=
ExecStart=/usr/local/bin/anvil --host 127.0.0.1 $ANVIL_EXTRA_HOST --allow-origin * --accounts 5 --chain-id 31337 --state @DATA@/anvil/state.json @MAINNET@
MemoryHigh=1G
MemoryMax=1536M
```
> `/usr/local/bin/anvil`: the base unit's path. Foundry (Task 4) installs to `$HOME/.foundry/bin`. Reconcile: either symlink `/usr/local/bin/anvil -> ~/.foundry/bin/anvil` in provision (recommended, keeps the base unit valid) or override the full path here. Pick the symlink; add it to Task 4.

- [ ] **Step 3: `aztec-sandbox.service.d/pi.conf` (memory cap — the heaviest service)**

```ini
[Service]
MemoryHigh=4G
MemoryMax=5G
```

- [ ] **Step 4: `chain-server.service.d/pi.conf` (bind private + cap)**

```ini
[Service]
Environment=HOST=0.0.0.0
MemoryHigh=768M
MemoryMax=1G
```
> Confirm `chain-server` honors `HOST`; if it binds all interfaces already, drop the `Environment=HOST`. Private LAN only (Decision 3) — acceptable behind the router.

- [ ] **Step 5: `block-producer.service.d/pi.conf` (small cap)**

```ini
[Service]
MemoryHigh=384M
MemoryMax=512M
```

- [ ] **Step 6: Append unit-install to `provision-pi.sh` (mirror `bootstrap.sh` §5, add drop-ins)**

```bash
step "systemd units + Pi drop-ins"
FORK_FLAGS="${MAINNET_RPC_URL:+--fork-url $MAINNET_RPC_URL}"   # empty -> unforked
sudo sed "s|@REPO@|$REPO|g; s|@DATA@|$DATA_MOUNT|g; s|@AZTEC_TAG@|$AZTEC_IMAGE_TAG|g; s|@MAINNET@|$FORK_FLAGS|g" \
  "$REPO/ops/systemd/anvil.service" | sudo tee /etc/systemd/system/anvil.service >/dev/null
sudo sed "s|@DATA@|$DATA_MOUNT|g; s|@AZTEC_TAG@|$AZTEC_IMAGE_TAG|g" \
  "$REPO/ops/systemd/aztec-sandbox.service" | sudo tee /etc/systemd/system/aztec-sandbox.service >/dev/null
sudo sed "s|@REPO@|$REPO|g; s|@DATA@|$DATA_MOUNT|g" \
  "$REPO/ops/systemd/chain-server.service" | sudo tee /etc/systemd/system/chain-server.service >/dev/null
sudo sed "s|@REPO@|$REPO|g" \
  "$REPO/ops/systemd/block-producer.service" | sudo tee /etc/systemd/system/block-producer.service >/dev/null
# Drop-ins (templated ones get the same substitution).
for u in anvil aztec-sandbox chain-server block-producer; do
  sudo mkdir -p "/etc/systemd/system/$u.service.d"
  sudo sed "s|@DATA@|$DATA_MOUNT|g; s|@MAINNET@|$FORK_FLAGS|g; s|@ANVIL_BIND@|${ANVIL_BIND:-tailscale}|g" \
    "$SCRIPT_DIR/systemd/$u.service.d/pi.conf" | sudo tee "/etc/systemd/system/$u.service.d/pi.conf" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable anvil aztec-sandbox chain-server block-producer
ok "units installed + enabled (not started)"
```

- [ ] **Step 7: shellcheck** the script + `systemd-analyze verify` each unit on the Pi → no errors.
- [ ] **Step 8: Run provision; verify** — `ssh pi 'systemctl cat anvil | sed -n "1,40p"'` shows substituted `ExecStart`, drop-in bind + `MemoryMax`.
- [ ] **Step 9: Idempotency** — re-run; `systemctl is-enabled` unchanged, no duplicate drop-ins.
- [ ] **Step 10: Commit** — `git commit -am "feat(pi): systemd units + Pi resource/bind drop-ins"`

---

## Task 6: `deploy-pi.sh` — orchestrate deploy-once/resume

Mirrors `bootstrap.sh` steps 5–6 (platform-layer orchestration; contract logic stays in the untouched `deploy-sandbox.sh`).

**Files:**
- Create: `deployments/pi/deploy-pi.sh`

**Interfaces:**
- Consumes: `pi.env`; provisioned host; enabled units; `$REPO/deployments/sandbox-local/deploy-sandbox.sh`, `$REPO/ops/gen-chain-server-env.sh`.
- Produces: a deployed chain — `$DATA_MOUNT/deployment-manifest.json` (+ `public-manifest.json`), all four services running.

- [ ] **Step 1: Write preflight + JS deps**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pi.env"
# ... step/ok/fail helpers (same block as provision-pi.sh) ...
step "Preflight"
[ -d "$REPO/deployments/sandbox-local" ] || fail "repo not staged at $REPO (run sync-to-pi.sh)"
for b in docker anvil forge node yarn jq; do command -v "$b" >/dev/null || fail "$b missing — run provision-pi.sh"; done
ok "tools present"
step "JS deps (node_modules excluded from sync)"
( cd "$REPO/v1-l2" && yarn install --frozen-lockfile ) || fail "v1-l2 yarn install failed"
( cd "$REPO/chain-server" && yarn install --frozen-lockfile ) || fail "chain-server yarn install failed"
ok "deps installed"
```

- [ ] **Step 2: Deploy-once / resume block (ported from `bootstrap.sh` §6, `sudo` for `systemctl`)**

```bash
step "Bring up chain + deploy (once) or resume"
sudo systemctl reset-failed anvil aztec-sandbox chain-server block-producer 2>/dev/null || true
if [ -f "$DATA_MOUNT/deployment-manifest.json" ]; then
  echo "Manifest present: resuming persisted chain (no redeploy)."
  sudo systemctl start anvil || fail "anvil failed (mock-feed install fails the start; see journalctl -u anvil)"
  bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start aztec-sandbox chain-server block-producer
else
  echo "First run: deploying contracts."
  sudo systemctl start anvil
  timeout 120 bash -c 'until curl -fsS -X POST -H "content-type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}" http://127.0.0.1:8545 >/dev/null; do sleep 3; done' || fail "anvil RPC never came up"
  sudo systemctl start aztec-sandbox
  timeout 300 bash -c 'until curl -fsS http://127.0.0.1:8080/status >/dev/null 2>&1 || curl -fsS http://127.0.0.1:8080 >/dev/null 2>&1; do sleep 5; done' || fail "aztec PXE never came up"
  DEPLOY_STATUS=0
  ( cd "$REPO" && CHAIN_HOST_HEADLESS=1 DOMAIN="$DOMAIN" MAINNET_RPC_URL="${MAINNET_RPC_URL:-}" \
      FOUNDRY_SOLC="/opt/zeracle/toolchain/solc-$SOLC_VERSION" \
      bash deployments/sandbox-local/deploy-sandbox.sh ) || DEPLOY_STATUS=$?
  for m in deployment-manifest.json public-manifest.json; do
    [ -f "$REPO/deployments/sandbox-local/$m" ] && cp "$REPO/deployments/sandbox-local/$m" "$DATA_MOUNT/$m" || true
  done
  [ "$DEPLOY_STATUS" -eq 0 ] || fail "deploy-sandbox.sh failed (exit $DEPLOY_STATUS); manifest persisted if produced"
  bash "$REPO/ops/gen-chain-server-env.sh" "$DATA_MOUNT/deployment-manifest.json"
  sudo systemctl start chain-server block-producer
  ok "first-run deploy complete; manifest at $DATA_MOUNT"
fi
step "Status"; systemctl --no-pager --failed || true
ok "deploy-pi complete"
```

- [ ] **Step 3: shellcheck** → no errors.
- [ ] **Step 4: Run** — `ssh pi 'bash /opt/zeracle/deployments/pi/deploy-pi.sh'`
Expected: anvil→aztec→deploy→chain-server+block-producer; `systemctl --failed` empty; manifest at `/data`.
- [ ] **Step 5: Resume path** — re-run → "resuming persisted chain (no redeploy)", services healthy.
- [ ] **Step 6: Reachability** — from the laptop: `cast chain-id --rpc-url http://<pi-tailscale-ip>:8545` → `31337`.
- [ ] **Step 7: Commit** — `git commit -am "feat(pi): deploy-pi orchestration (deploy-once/resume)"`

---

## Task 7: `README.md` runbook

**Files:**
- Create: `deployments/pi/README.md`

- [ ] **Step 1: Write the runbook** covering, each as a real section (no placeholders):
  - **Hardware prereqs:** Pi 5, 8 GB (spec noted 16 GB; 8 GB accepted 2026-09-22), NVMe, genuine 5 V/5 A supply + active cooling (throttle guard), `/data` is a directory on the NVMe root.
  - **First run:** `sync-to-pi.sh` → `mkdir /data` → `provision-pi.sh` (run convention + `sudo` notes from Tasks 3–4) → `deploy-pi.sh`.
  - **Day-2 ops:** `journalctl -u anvil|aztec-sandbox|chain-server|block-producer`; restart order (`Requires`/`After`); where state lives (`/data`); how resume works; how to force a fresh chain (remove `/data/deployment-manifest.json` + `/data/anvil/state.json`).
  - **Access:** loopback + Tailscale; RPC `:8545`, PXE `:8080`, chain-server `:3001`; no public endpoints (Decision 3), re-homing browser PXE is a separate ticket.
  - **Build host:** `FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-0.8.37`; use a 200-run profile for routine `forge test`, default 10 000-run only for size/gas; judge compile progress by output-file growth, not the process tree.
- [ ] **Step 2: Commit** — `git commit -am "docs(pi): chain-host runbook"`

---

## Task 8: Verification gate (spec Testing table)

**Files:** none (verification only). Uses `superpowers:verification-before-completion`.

- [ ] **Step 1: shellcheck all** — `shellcheck deployments/pi/*.sh deployments/pi/toolchain/*.sh deployments/pi/systemd/*.sh` → no errors. (Laptop lacks shellcheck: `sudo apt-get install -y shellcheck`, or run on the Pi.)
- [ ] **Step 2: Idempotency** — `provision-pi.sh` twice; second run reports no changes (no reinstall, no fstab/daemon.json/drop-in duplication).
- [ ] **Step 3: Toolchain native** — `ssh pi 'file $(which forge) $(which anvil) /opt/zeracle/toolchain/solc-0.8.37'` → all AArch64.
- [ ] **Step 4: Compiler matches config** — installed solc `--version` == `v1-l1/foundry.toml` `solc_version` (`0.8.37`).
- [ ] **Step 5: Build within EIP-170** — `ssh pi 'cd /opt/zeracle/v1-l1 && FOUNDRY_PROFILE=deploy FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-0.8.37 forge build --sizes'` → no contract over the limit.
- [ ] **Step 6: THE GATE — `forge test` 721/721** — `ssh pi 'cd /opt/zeracle/v1-l1 && FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-0.8.37 forge test'` → **721/721**. Anything less must be explained before the host is trusted (x86 scores 721 at solc 0.8.37).
- [ ] **Step 7: Final commit / branch** — per `superpowers:finishing-a-development-branch`.

---

## Self-review

**Spec coverage:** provision (Tasks 3–5), install-solc (Task 2), deploy-pi (Task 6), systemd reuse + drop-ins (Task 5), README (Task 7), all preflight assertions (Task 3), swap-on-`/data` (Task 3), error handling / `set -euo pipefail` / loud mountpoint-style assertion (Tasks 3, 6), full Testing table (Task 8). **Added beyond spec:** Task 0 (repo→Pi delivery — spec gap) and Task 1 (`pi.env` — the env source the EC2 layer got from `ec2.env`).

**Owner-decision deviations from spec (recorded, not re-litigated):** `/data` is a directory on NVMe (not a mount) → preflight asserts NVMe-backing, no fstab data entry; 8 GB (not 16 GB) → proceed + 12 GiB swap.

**Open items flagged inline for the executor to resolve on first run (not placeholders — each has a concrete default):**
1. sudo/nvm `$HOME` convention (Tasks 3–4) — default: run script as `admin`, `sudo` privileged lines.
2. `/usr/local/bin/anvil` symlink vs full-path override (Task 5 Step 2) — default: symlink in Task 4.
3. `chain-server` `HOST` env honored? (Task 5 Step 4) — default: keep, drop if it already binds all ifaces.
4. JS deps: install-on-Pi vs sync `node_modules` (Task 0 note / Task 6) — default: install-on-Pi.
5. solc `argotorg` asset path/hash (Task 2 Step 1) — must be fetched, not invented.

**Type/name consistency:** `REPO`/`DATA_MOUNT`/`SWAP_SIZE_GIB`/`AZTEC_IMAGE_TAG`/`SOLC_VERSION`/`ANVIL_BIND`/`MAINNET_RPC_URL`/`DOMAIN` are defined once in `pi.env` (Task 1) and consumed unchanged in Tasks 2–6. `FOUNDRY_SOLC=/opt/zeracle/toolchain/solc-$SOLC_VERSION` identical in Tasks 2, 6, 8.
