#!/bin/bash
# =============================================================================
# Flash Radxa Cubie A7A Image to SD Card
#
# Usage: sudo ./flash-image.sh /dev/sdX
#
# Downloads and flashes:
#   1. Boot sectors (boot0 + U-Boot)
#   2. Creates partition table (16MB config + 300MB EFI + rootfs)
#   3. Extracts Debian 13 rootfs with custom 6.6.98+ kernel
# =============================================================================
set -euo pipefail

DEVICE="${1:-}"

if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
    echo "Usage: sudo $0 /dev/sdX"
    echo ""
    echo "Available removable devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "usb|mmc" || echo "  (none found)"
    exit 1
fi

# Safety
if [[ "$DEVICE" == "/dev/sda" ]] && [ ! -e "/dev/sdb" ]; then
    echo "ERROR: /dev/sda might be your system drive. Please verify."
    exit 1
fi

if [[ "$DEVICE" == "/dev/nvme"* ]]; then
    echo "ERROR: Refusing to write to NVMe drive."
    exit 1
fi

echo "=== Radxa Cubie A7A Image Flasher ==="
echo "Target: $DEVICE ($(lsblk -d -o SIZE $DEVICE | tail -1))"
echo ""
echo "WARNING: This will ERASE all data on $DEVICE!"
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}/../release"

# Check for required files
BOOT_IMG="${RELEASE_DIR}/radxa-a7a-boot-sectors.img"
ROOTFS="${RELEASE_DIR}/radxa-a7a-debian13-6.6.98-rootfs.tar.gz"

if [ ! -f "$BOOT_IMG" ] || [ ! -f "$ROOTFS" ]; then
    echo "ERROR: Missing image files in $RELEASE_DIR"
    echo "Required:"
    echo "  - radxa-a7a-boot-sectors.img"
    echo "  - radxa-a7a-debian13-6.6.98-rootfs.tar.gz"
    exit 1
fi

echo ""
echo "[1/5] Writing boot sectors..."
dd if="$BOOT_IMG" of="$DEVICE" bs=1M conv=notrunc status=progress

echo ""
echo "[2/5] Creating partition table..."
# Recreate the GPT partition table
sgdisk --zap-all "$DEVICE" > /dev/null 2>&1
sgdisk -n 1:32768:65535 -t 1:8300 -c 1:"config" "$DEVICE"
sgdisk -n 2:65536:679935 -t 2:EF00 -c 2:"boot" "$DEVICE"
sgdisk -n 3:679936:0 -t 3:8300 -c 3:"rootfs" "$DEVICE"
partprobe "$DEVICE"
sleep 2

echo ""
echo "[3/5] Formatting partitions..."
# Determine partition naming
if [[ "$DEVICE" == *"mmcblk"* ]]; then
    P1="${DEVICE}p1"
    P2="${DEVICE}p2"
    P3="${DEVICE}p3"
else
    P1="${DEVICE}1"
    P2="${DEVICE}2"
    P3="${DEVICE}3"
fi

mkfs.ext4 -q -L config "$P1"
mkfs.vfat -F 32 -n BOOT "$P2"
mkfs.ext4 -q -L rootfs "$P3"

echo ""
echo "[4/5] Extracting rootfs (this takes a few minutes)..."
MOUNT_DIR=$(mktemp -d)
mount "$P3" "$MOUNT_DIR"
tar xzf "$ROOTFS" -C "$MOUNT_DIR"

# Create missing dirs
mkdir -p "$MOUNT_DIR"/{proc,sys,dev,run,tmp,mnt,media}

echo ""
echo "[5/5] Finalizing..."
# Fix fstab for the new partition UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$P3")
sed -i "s|root=UUID=[^ ]*|root=UUID=$ROOT_UUID|g" "$MOUNT_DIR/boot/extlinux/extlinux.conf" 2>/dev/null || true
sed -i "s|root=/dev/mmcblk0p3|root=UUID=$ROOT_UUID|g" "$MOUNT_DIR/boot/extlinux/extlinux.conf" 2>/dev/null || true

sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo ""
echo "=== Flash complete! ==="
echo "Insert SD card into Radxa Cubie A7A and power on."
echo ""
echo "Default login: radxa / radxa"
echo "SSH starts automatically on WiFi."
echo "Serial console: 115200 baud"
