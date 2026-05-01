#!/bin/bash
# =============================================================================
# Radxa Cubie A7A Kernel Deploy Script
# Deploy built kernel to SD card or over SSH to the board
# =============================================================================
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${WORKSPACE}/kernel"
OUTPUT_DIR="${WORKSPACE}/output"
PKG_DIR="${OUTPUT_DIR}/package"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DEPLOY]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# -----------------------------------------------------------------------------
# Deploy to SD card (mounted on host)
# -----------------------------------------------------------------------------
deploy_sd() {
    local DEVICE="${1:-}"
    if [ -z "${DEVICE}" ]; then
        echo "Usage: $0 sd /dev/sdX"
        echo ""
        echo "Available block devices:"
        lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "sd|mmcblk"
        exit 1
    fi

    if [ ! -d "${PKG_DIR}" ]; then
        err "No package found. Run './build.sh build && ./build.sh package' first."
        exit 1
    fi

    # Safety checks
    if [[ "${DEVICE}" == "/dev/sda" ]] || [[ "${DEVICE}" == "/dev/nvme0n1" ]]; then
        err "Refusing to write to ${DEVICE} — this looks like your system drive!"
        exit 1
    fi

    if [ ! -b "${DEVICE}" ]; then
        err "${DEVICE} is not a block device"
        exit 1
    fi

    warn "This will write kernel files to ${DEVICE}"
    warn "Make sure this is your A7A's SD card!"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Aborted."
        exit 0
    fi

    # Mount the boot partition
    local MOUNT_POINT=$(mktemp -d /tmp/a7a-boot-XXXXX)
    local BOOT_PART="${DEVICE}1"

    # Try partition naming for mmcblk devices
    if [[ "${DEVICE}" == *"mmcblk"* ]]; then
        BOOT_PART="${DEVICE}p1"
    fi

    log "Mounting ${BOOT_PART} at ${MOUNT_POINT}..."
    sudo mount "${BOOT_PART}" "${MOUNT_POINT}"

    # Backup existing kernel
    if [ -f "${MOUNT_POINT}/Image" ]; then
        log "Backing up existing kernel..."
        sudo cp "${MOUNT_POINT}/Image" "${MOUNT_POINT}/Image.bak"
    fi
    if [ -f "${MOUNT_POINT}/sun60i-a733-cubie-a7a.dtb" ]; then
        sudo cp "${MOUNT_POINT}/sun60i-a733-cubie-a7a.dtb" "${MOUNT_POINT}/sun60i-a733-cubie-a7a.dtb.bak"
    fi

    # Deploy
    log "Copying kernel Image..."
    sudo cp "${PKG_DIR}/boot/Image" "${MOUNT_POINT}/"
    log "Copying DTB..."
    sudo cp "${PKG_DIR}/boot/sun60i-a733-cubie-a7a.dtb" "${MOUNT_POINT}/" 2>/dev/null || warn "No DTB to copy"

    sudo sync
    sudo umount "${MOUNT_POINT}"
    rmdir "${MOUNT_POINT}"

    log "SD card boot partition updated. Now deploy modules to rootfs:"
    info "  sudo mount ${DEVICE}2 /mnt  # or wherever rootfs is"
    info "  sudo cp -r ${PKG_DIR}/lib/modules/* /mnt/lib/modules/"
    info "  sudo umount /mnt"
}

# -----------------------------------------------------------------------------
# Deploy over SSH to running board
# -----------------------------------------------------------------------------
deploy_ssh() {
    local TARGET="${1:-}"
    if [ -z "${TARGET}" ]; then
        echo "Usage: $0 ssh user@host"
        echo "  Example: $0 ssh radxa@192.168.1.100"
        echo "  Example: $0 ssh radxa@radxa-a7a.local"
        exit 1
    fi

    if [ ! -d "${PKG_DIR}" ]; then
        err "No package found. Run './build.sh build && ./build.sh package' first."
        exit 1
    fi

    local KVER=$(cat "${PKG_DIR}/boot/kernel-version.txt" 2>/dev/null || echo "unknown")
    log "Deploying kernel ${KVER} to ${TARGET}..."

    # Upload kernel Image
    log "Uploading kernel Image..."
    scp "${PKG_DIR}/boot/Image" "${TARGET}:/tmp/Image.new"

    # Upload DTB
    if [ -f "${PKG_DIR}/boot/sun60i-a733-cubie-a7a.dtb" ]; then
        log "Uploading DTB..."
        scp "${PKG_DIR}/boot/sun60i-a733-cubie-a7a.dtb" "${TARGET}:/tmp/sun60i-a733-cubie-a7a.dtb.new"
    fi

    # Upload modules
    log "Uploading modules..."
    cd "${PKG_DIR}"
    tar czf /tmp/a7a-modules.tar.gz lib/modules/
    scp /tmp/a7a-modules.tar.gz "${TARGET}:/tmp/"

    # Install on target
    log "Installing on target..."
    ssh "${TARGET}" bash -s <<'REMOTE_SCRIPT'
set -e
echo "[REMOTE] Backing up current kernel..."
sudo cp /boot/Image /boot/Image.bak 2>/dev/null || true
sudo cp /boot/*.dtb /boot/dtb.bak 2>/dev/null || true

echo "[REMOTE] Installing new kernel..."
sudo cp /tmp/Image.new /boot/Image
if [ -f /tmp/sun60i-a733-cubie-a7a.dtb.new ]; then
    sudo cp /tmp/sun60i-a733-cubie-a7a.dtb.new /boot/sun60i-a733-cubie-a7a.dtb
fi

echo "[REMOTE] Installing modules..."
cd / && sudo tar xzf /tmp/a7a-modules.tar.gz

echo "[REMOTE] Cleaning up..."
rm -f /tmp/Image.new /tmp/sun60i-a733-cubie-a7a.dtb.new /tmp/a7a-modules.tar.gz

echo "[REMOTE] Done! Reboot to use new kernel."
REMOTE_SCRIPT

    rm -f /tmp/a7a-modules.tar.gz
    log "Deploy complete! Reboot the board to use the new kernel."
    info "  ssh ${TARGET} sudo reboot"
}

# -----------------------------------------------------------------------------
# Deploy DTB only (fast iteration)
# -----------------------------------------------------------------------------
deploy_dtb_ssh() {
    local TARGET="${1:-}"
    if [ -z "${TARGET}" ]; then
        echo "Usage: $0 dtb-ssh user@host"
        exit 1
    fi

    local DTB="${OUTPUT_DIR}/sun60i-a733-cubie-a7a.dtb"
    if [ ! -f "${DTB}" ]; then
        err "No DTB found. Run './build.sh dtb' first."
        exit 1
    fi

    log "Deploying DTB only to ${TARGET}..."
    scp "${DTB}" "${TARGET}:/tmp/sun60i-a733-cubie-a7a.dtb.new"
    ssh "${TARGET}" "sudo cp /boot/*.dtb /boot/dtb.bak 2>/dev/null; sudo cp /tmp/sun60i-a733-cubie-a7a.dtb.new /boot/sun60i-a733-cubie-a7a.dtb && rm /tmp/sun60i-a733-cubie-a7a.dtb.new"
    log "DTB deployed! Reboot to apply."
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  sd <device>      - Deploy to SD card (e.g., /dev/sdb)"
    echo "  ssh <user@host>  - Deploy kernel+modules over SSH"
    echo "  dtb-ssh <u@host> - Deploy DTB only over SSH (fast iteration)"
    echo ""
    echo "Examples:"
    echo "  $0 sd /dev/sdb"
    echo "  $0 ssh radxa@192.168.1.100"
    echo "  $0 dtb-ssh radxa@192.168.1.100"
}

case "${1:-}" in
    sd)       deploy_sd "${2:-}" ;;
    ssh)      deploy_ssh "${2:-}" ;;
    dtb-ssh)  deploy_dtb_ssh "${2:-}" ;;
    *)        usage ;;
esac
