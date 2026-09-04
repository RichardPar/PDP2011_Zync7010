#!/bin/bash
# deploy_to_board.sh - push freshly-built boot artifacts to a running
# PetaLinux board over SSH/SCP, from a Linux host (uses scp/ssh directly -
# no sshpass required if you set up an SSH key; falls back to interactive
# password prompts otherwise).
#
# IMPORTANT: this updates the *actual* FAT32 boot partition
# (/dev/mmcblk0p1, mounted at /run/media/BOOT-mmcblk0p1 on the board as
# observed 2026-08-09) - NOT the /boot directory on the rootfs itself, which
# is just a local copy baked into the image and is NOT what u-boot reads at
# boot. Confirm the mount point below still matches your board (`mount |
# grep vfat` on the target) before relying on this script blindly - it can
# differ across PetaLinux builds/board revisions.
#
# Does NOT touch the rootfs (no rootfs.tar.gz redeploy - that would mean
# overwriting a live, running root filesystem over the network, which is
# far riskier than updating the boot partition and rebooting). If you need
# rootfs changes (e.g. picking up a new pdp11-scripts build), copy the
# individual changed file(s) by hand or re-flash the SD card physically.
#
# Usage:
#   ./deploy_to_board.sh [user@]host [boot-partition-mountpoint]
#
# Example:
#   ./deploy_to_board.sh petalinux@192.168.10.192

set -euo pipefail

TARGET="${1:?Usage: $0 [user@]host [boot-partition-mountpoint]}"
BOOT_MNT="${2:-/run/media/BOOT-mmcblk0p1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../deploy" && pwd)"

for f in BOOT.BIN image.ub boot.scr; do
   if [ ! -f "$DEPLOY_DIR/$f" ]; then
      echo "Missing $DEPLOY_DIR/$f - build it first (vivado/scripts/04_build.tcl + PetaLinux build)" >&2
      exit 1
   fi
done

echo "== Confirming $BOOT_MNT is actually a mounted vfat partition on $TARGET =="
ssh "$TARGET" "mount | grep -q \"on $BOOT_MNT type vfat\"" || {
   echo "$BOOT_MNT is not a mounted vfat partition on $TARGET - aborting." >&2
   echo "Run 'mount | grep vfat' on the target to find the real mount point," >&2
   echo "then pass it as the second argument to this script." >&2
   exit 1
}

echo "== Copying BOOT.BIN, image.ub, boot.scr to $TARGET:$BOOT_MNT =="
scp "$DEPLOY_DIR/BOOT.BIN" "$DEPLOY_DIR/image.ub" "$DEPLOY_DIR/boot.scr" "$TARGET:$BOOT_MNT/"

echo "== Syncing filesystem on target =="
ssh "$TARGET" "sync"

echo
echo "Done. Boot partition updated. Reboot the board to load the new"
echo "bitstream/kernel/device-tree (this does NOT reboot it for you):"
echo "  ssh $TARGET reboot"
