#!/usr/bin/env bash
# One-time, idempotent host setup for the Pi chain host. Runs ON the Pi.
#
# Run convention: run this script AS the admin user (not `sudo bash`), so
# nvm/Foundry install into the admin's $HOME as intended. Privileged steps
# (swap, fstab, docker, systemd) are prefixed with `sudo` inline below.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pi.env disable=SC1091
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
  sudo swapon "$SWAP_FILE"
  ok "swap on ($SWAP_GIB GiB)"
fi
# Persist across reboot; nofail so a missing swapfile never blocks boot.
grep -q "^${SWAP_FILE} " /etc/fstab || echo "$SWAP_FILE none swap sw,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
ok "swap in fstab"

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
  # shellcheck disable=SC1090,SC1091
  . "$HOME/.bashrc" 2>/dev/null || true
  "$HOME/.foundry/bin/foundryup"
fi
export PATH="$HOME/.foundry/bin:$PATH"
# -L: foundryup symlinks bin/anvil -> versions/.../anvil, so follow to the real ELF.
file -L "$(command -v anvil)" | grep -q aarch64 || fail "anvil is not a native aarch64 binary"
ok "$(forge --version | head -1)"

# Ruling: symlink into /usr/local/bin so the systemd units (base + drop-ins),
# which hard-code /usr/local/bin/anvil, resolve regardless of $HOME. `ln -sf`
# is idempotent — re-running never duplicates or breaks the link.
sudo ln -sf "$HOME/.foundry/bin/anvil" /usr/local/bin/anvil
sudo ln -sf "$HOME/.foundry/bin/cast" /usr/local/bin/cast
sudo ln -sf "$HOME/.foundry/bin/forge" /usr/local/bin/forge
ok "symlinked anvil/cast/forge into /usr/local/bin"
# Node toolchain lives under nvm ($HOME); the chain-server/block-producer units
# run as root with a minimal PATH that includes /usr/local/bin but not nvm.
# Symlink node/npm/npx/yarn there so the units resolve them. Resolve absolute
# paths via `command -v` (nvm.sh is already sourced above) so no version is baked in.
for b in node npm npx yarn; do
  p="$(command -v "$b" || true)"
  [ -n "$p" ] && sudo ln -sf "$p" "/usr/local/bin/$b" || echo "  ! $b not found on PATH; unit may fail"
done
ok "symlinked node/npm/npx/yarn into /usr/local/bin"

step "Pinned solc"
SOLC_VERSION="$SOLC_VERSION" bash "$SCRIPT_DIR/toolchain/install-solc.sh"

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
