#!/bin/bash
# flash_sd_card.sh - partition and flash a fresh microSD card for the PS
# boot (this is the card that boots PetaLinux - NOT the PDP-11's own
# dedicated microSD card on N20/R19/T20/V20, which just gets a raw RL02
# image dd'd to it with no partition table at all, see disks/README below).
#
# Run this ON A LINUX BOX with the target SD card inserted (e.g. via a USB
# reader). Two-partition layout: FAT32 boot (BOOT.BIN/image.ub/boot.scr) +
# ext4 rootfs, matching this project's CONFIG_SUBSYSTEM_ROOTFS_EXT4=y build.
#
# DESTRUCTIVE: this wipes the entire target device. Confirms the device
# size/model with you before touching anything, and requires typing the
# exact device path back to proceed.
#
# Usage:
#   sudo ./flash_sd_card.sh /dev/sdX [deploy-dir]
#
# deploy-dir defaults to ../deploy relative to this script (this project's
# own layout), but on a different machine than the one that built the
# images - e.g. a Linux box that only has the deploy/ files copied over,
# not the whole project - pass the actual directory containing BOOT.BIN/
# image.ub/boot.scr/rootfs.tar.gz as the second argument.

set -euo pipefail

DEVICE="${1:?Usage: sudo $0 /dev/sdX [deploy-dir]}"

if [ "$(id -u)" -ne 0 ]; then
   echo "Must run as root (needed for parted/mkfs/mount on a raw block device)." >&2
   exit 1
fi

if [ ! -b "$DEVICE" ]; then
   echo "$DEVICE is not a block device." >&2
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${2:-}" ]; then
   DEPLOY_DIR="$(cd "$2" && pwd)"
else
   DEPLOY_DIR="$(cd "$SCRIPT_DIR/../deploy" && pwd)"
fi

for f in BOOT.BIN image.ub boot.scr rootfs.tar.gz; do
   if [ ! -f "$DEPLOY_DIR/$f" ]; then
      echo "Missing $DEPLOY_DIR/$f - build it first (Vivado + PetaLinux build)," >&2
      echo "or pass the correct directory as the second argument." >&2
      exit 1
   fi
done

echo "Using deploy directory: $DEPLOY_DIR"

echo "== Target device info =="
lsblk "$DEVICE"
echo
echo "About to COMPLETELY ERASE $DEVICE and write:"
echo "  - partition 1: FAT32, ~256MB  <- BOOT.BIN, image.ub, boot.scr"
echo "  - partition 2: ext4, rest of the card  <- rootfs.tar.gz"
echo
read -r -p "Type the device path ($DEVICE) again to confirm, or anything else to abort: " CONFIRM
if [ "$CONFIRM" != "$DEVICE" ]; then
   echo "Aborted - confirmation did not match."
   exit 1
fi

# unmount any partitions already mounted from this device
for p in "${DEVICE}"?*; do
   if mount | grep -q "^$p "; then
      umount "$p"
   fi
done

echo "== Partitioning $DEVICE =="
parted "$DEVICE" --script mklabel msdos
parted "$DEVICE" --script mkpart primary fat32 4MiB 260MiB
parted "$DEVICE" --script mkpart primary ext4 260MiB 100%
parted "$DEVICE" --script set 1 boot on
partprobe "$DEVICE"
sleep 1

# device naming: /dev/sdX1/sdX2 for SCSI/USB, /dev/mmcblkYp1/p2 for native SD
if [[ "$DEVICE" == *mmcblk* ]]; then
   PART1="${DEVICE}p1"
   PART2="${DEVICE}p2"
else
   PART1="${DEVICE}1"
   PART2="${DEVICE}2"
fi

echo "== Formatting $PART1 (FAT32) and $PART2 (ext4) =="
mkfs.vfat -F 32 -n BOOT "$PART1"
mkfs.ext4 -F -L rootfs "$PART2"

MNT_BOOT=$(mktemp -d)
MNT_ROOT=$(mktemp -d)
mount "$PART1" "$MNT_BOOT"
mount "$PART2" "$MNT_ROOT"

echo "== Copying boot files =="
cp "$DEPLOY_DIR/BOOT.BIN" "$DEPLOY_DIR/image.ub" "$DEPLOY_DIR/boot.scr" "$MNT_BOOT/"

echo "== Extracting rootfs (this takes a while) =="
tar -xzpf "$DEPLOY_DIR/rootfs.tar.gz" -C "$MNT_ROOT" --numeric-owner

sync
umount "$MNT_BOOT" "$MNT_ROOT"
rmdir "$MNT_BOOT" "$MNT_ROOT"

echo
echo "Done. $DEVICE is ready - insert it into the board's PS boot SD slot."
echo "(Separately, write a raw RL02 image to the PDP-11's OWN dedicated"
echo "microSD card with plain dd - no partition table, see disks/ and"
echo "README.md's RL11 section - that card is unrelated to this one.)"
