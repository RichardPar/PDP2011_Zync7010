#!/bin/bash
# flash_bootbin_sd.sh - write the PS boot microSD card from deploy/, from a
# reader plugged into this dev host (no network needed - see
# flash_bootbin_net.sh for that). Two modes:
#
#   update mode (default): card is already partitioned (FAT32 boot +
#   ext4 rootfs, e.g. from a previous flash_sd_card.sh or this script's
#   --partition mode). Just overwrites BOOT.BIN/image.ub/boot.scr on the
#   existing boot partition, backing up what was there as *.bak. Leaves
#   rootfs untouched. This is what you want to recover a card after a
#   bad BOOT.BIN, or push a new bitstream/kernel.
#
#   --partition mode: DESTRUCTIVE, wipes the whole device. Mirrors
#   flash_sd_card.sh's scheme (FAT32 boot ~256MB + ext4 rootfs) and also
#   extracts rootfs.tar.gz. Use for a card that isn't partitioned yet, or
#   to start over from scratch.
#
# Usage:
#   sudo ./flash_bootbin_sd.sh [--partition] /dev/sdX [variant] [deploy-dir]
#
#   /dev/sdX    the PS boot card's whole-disk device
#   variant     optional suffix - e.g. "docker" uses BOOT.BIN.docker,
#               image.ub.docker, boot.scr.docker, rootfs.tar.gz.docker
#               instead of the plain names. Default: none.
#   deploy-dir  defaults to ../deploy relative to this script

set -euo pipefail

PARTITION=0
if [ "${1:-}" = "--partition" ]; then
    PARTITION=1
    shift
fi

DEV="${1:?Usage: sudo $0 [--partition] /dev/sdX [variant] [deploy-dir]}"
VARIANT="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${3:-}" ]; then
    DEPLOY_DIR="$(cd "$3" && pwd)"
else
    DEPLOY_DIR="$(cd "$SCRIPT_DIR/../deploy" && pwd)"
fi
SUFFIX=""
[ -n "$VARIANT" ] && SUFFIX=".$VARIANT"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root (needed for mount/parted/mkfs on a raw block device)." >&2
    exit 1
fi

[ -b "$DEV" ] || { echo "$DEV is not a block device." >&2; exit 1; }

if [[ "$DEV" == *mmcblk* ]]; then
    PART1="${DEV}p1"; PART2="${DEV}p2"
else
    PART1="${DEV}1"; PART2="${DEV}2"
fi

FILES=(BOOT.BIN image.ub boot.scr)

echo "== Target device =="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DEV"
echo

if [ "$PARTITION" -eq 1 ]; then
    echo "DESTRUCTIVE: this wipes the ENTIRE $DEV and recreates:"
    echo "  - partition 1: FAT32, ~256MB  <- BOOT.BIN, image.ub, boot.scr"
    echo "  - partition 2: ext4, rest of the card  <- rootfs.tar.gz$SUFFIX"
    [ -f "$DEPLOY_DIR/rootfs.tar.gz$SUFFIX" ] || { echo "ERROR: $DEPLOY_DIR/rootfs.tar.gz$SUFFIX not found (needed for --partition)." >&2; exit 1; }
else
    echo "Update mode: mounting $PART1 and overwriting boot files in place"
    echo "(rootfs on $PART2 is left untouched). Use --partition for a fresh card."
fi
echo "Copying from $DEPLOY_DIR (variant: ${VARIANT:-none}):"
for f in "${FILES[@]}"; do
    src="$DEPLOY_DIR/$f$SUFFIX"
    if [ -f "$src" ]; then
        echo "  $src  ($(stat -c%s "$src") bytes)  ->  $f"
    else
        echo "  $src  (missing, will skip)"
    fi
done
echo
read -r -p "Type the device path ($DEV) again to confirm, or anything else to abort: " CONFIRM
if [ "$CONFIRM" != "$DEV" ]; then
    echo "Aborted - confirmation did not match."
    exit 1
fi

# unmount any partitions already mounted from this device
for p in "${DEV}"?*; do
    mount | grep -q "^$p " && umount "$p"
done

if [ "$PARTITION" -eq 1 ]; then
    echo "== Partitioning $DEV =="
    parted "$DEV" --script mklabel msdos
    parted "$DEV" --script mkpart primary fat32 4MiB 260MiB
    parted "$DEV" --script mkpart primary ext4 260MiB 100%
    parted "$DEV" --script set 1 boot on
    partprobe "$DEV"
    sleep 1

    echo "== Formatting $PART1 (FAT32) and $PART2 (ext4) =="
    mkfs.vfat -F 32 -n BOOT "$PART1"
    mkfs.ext4 -F -L rootfs "$PART2"
fi

[ -b "$PART1" ] || { echo "$PART1 (expected FAT32 boot partition) not found." >&2; exit 1; }

MNT=$(mktemp -d)
MNT_ROOT=""
cleanup() {
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    if [ -n "$MNT_ROOT" ]; then
        umount "$MNT_ROOT" 2>/dev/null || true
        rmdir "$MNT_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mount "$PART1" "$MNT"

echo "== Boot partition before =="
ls -la "$MNT"

copied=0
for f in "${FILES[@]}"; do
    src="$DEPLOY_DIR/$f$SUFFIX"
    [ -f "$src" ] || continue
    if [ "$PARTITION" -eq 0 ] && [ -f "$MNT/$f" ]; then
        cp -f "$MNT/$f" "$MNT/$f.bak"
    fi
    cp -f "$src" "$MNT/$f"
    copied=$((copied + 1))
done

if [ "$PARTITION" -eq 1 ]; then
    MNT_ROOT=$(mktemp -d)
    mount "$PART2" "$MNT_ROOT"
    echo "== Extracting rootfs (this takes a while) =="
    tar -xzpf "$DEPLOY_DIR/rootfs.tar.gz$SUFFIX" -C "$MNT_ROOT" --numeric-owner

    # pdp11-hostd.init silently no-ops (no error) if DL0's image is missing,
    # so a from-scratch rootfs needs /srv/pdp11 seeded or the daemon never
    # starts on first boot - mirror what deploy_pdp11_hostd.sh does for an
    # already-running board.
    DISKS_DIR="$SCRIPT_DIR/../disks"
    mkdir -p "$MNT_ROOT/srv/pdp11"
    if [ -f "$DISKS_DIR/dl0.img" ]; then
        echo "== Seeding /srv/pdp11/dl0.img (DL0, required for hostd to start) =="
        cp -f "$DISKS_DIR/dl0.img" "$MNT_ROOT/srv/pdp11/dl0.img"
    else
        echo "WARNING: $DISKS_DIR/dl0.img not found - pdp11-hostd will not start" \
             "on first boot until you put a DL0 image at /srv/pdp11/dl0.img." >&2
    fi
    if [ -f "$DISKS_DIR/dl1.img" ]; then
        echo "== Seeding /srv/pdp11/dl1.img (DL1) =="
        cp -f "$DISKS_DIR/dl1.img" "$MNT_ROOT/srv/pdp11/dl1.img"
    fi
fi

sync

if [ "$copied" -eq 0 ]; then
    echo "ERROR: nothing copied - no boot files found." >&2
    exit 1
fi

echo
echo "== Boot partition after =="
ls -la "$MNT"
echo
for f in "${FILES[@]}"; do
    [ -f "$MNT/$f" ] || continue
    src="$DEPLOY_DIR/$f$SUFFIX"
    [ -f "$src" ] || continue
    echo "$(md5sum "$MNT/$f" | cut -d' ' -f1)  card:$f"
    echo "$(md5sum "$src" | cut -d' ' -f1)  local:$(basename "$src")"
done

echo
echo "Done ($copied boot file(s) updated$([ "$PARTITION" -eq 1 ] && echo ", rootfs extracted")." \
     "$([ "$PARTITION" -eq 0 ] && echo "Previous boot files saved as *.bak.")"
echo "Unmounting and syncing - safe to remove the card once this returns."
echo "(Separately, the PDP-11's OWN dedicated microSD card - RH11/RL11 SPI"
echo "pins - takes a raw disk image via plain dd, no partition table; see"
echo "disks/ and README.md. That card is unrelated to this one.)"
