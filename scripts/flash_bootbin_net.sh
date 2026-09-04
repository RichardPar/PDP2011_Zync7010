#!/bin/bash
# flash_bootbin_net.sh - push the freshly built BOOT.BIN.new to the running
# board's SD FAT partition over the network (no card removal). Backs up the
# existing on-card BOOT.BIN to BOOT.BIN.bak first, then verifies by md5.
set -e
NEW=/home/richard/Xilinx/Projects/PDP2011_Zync7010/deploy/BOOT.BIN.new
BOARD=petalinux@192.168.10.192
PW=123456
B=/run/media/BOOT-mmcblk0p1
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

[ -f "$NEW" ] || { echo "ERROR: $NEW not built yet"; exit 1; }
LOCAL_MD5=$(md5sum "$NEW" | awk '{print $1}')
echo "local BOOT.BIN.new: size=$(stat -c%s "$NEW") md5=$LOCAL_MD5"

echo "### copying to board /tmp ..."
sshpass -p "$PW" scp $SSHOPT "$NEW" "$BOARD:/tmp/BOOT.BIN.new"

echo "### backup + replace on SD FAT (sudo) ..."
sshpass -p "$PW" ssh $SSHOPT "$BOARD" "echo $PW | sudo -S sh -c '
  cp -f $B/BOOT.BIN $B/BOOT.BIN.bak &&
  cp -f /tmp/BOOT.BIN.new $B/BOOT.BIN &&
  sync &&
  echo ---- on-card after ---- &&
  ls -la $B &&
  md5sum $B/BOOT.BIN'" 2>&1 | grep -v "Warning: Permanently"

echo "### expected md5 = $LOCAL_MD5  (compare with on-card BOOT.BIN above)"
echo "Done. Power-cycle the board to boot the fixed bitstream from SD."
