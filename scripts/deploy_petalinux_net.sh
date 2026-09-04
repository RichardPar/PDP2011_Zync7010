#!/bin/bash
# deploy_petalinux_net.sh - live deploy of the customized PetaLinux build to the
# running board over the network (no card removal):
#   * FAT partition: back up & replace image.ub + boot.scr  (BOOT.BIN left as-is
#     - the working bootgen-repackaged one is already on the card)
#   * running rootfs: install pdp11_reset.sh to /usr/bin
# The rootfs PARTITION is not re-extracted (can't, it's the live root) - only the
# one helper script is added.
set -e
D=/home/richard/Xilinx/Projects/PDP2011_Zync7010/deploy
RESET=/home/richard/Xilinx/Projects/PDP2011_Zync7010/scripts/pdp11_reset.sh
BOARD=petalinux@192.168.10.192
PW=123456
B=/run/media/BOOT-mmcblk0p1
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

for f in "$D/image.ub" "$D/boot.scr" "$RESET"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done
UB_MD5=$(md5sum "$D/image.ub" | awk '{print $1}')
echo "local image.ub md5=$UB_MD5 size=$(stat -c%s "$D/image.ub")"

echo "### copying files to board /tmp ..."
sshpass -p "$PW" scp $SSHOPT "$D/image.ub" "$D/boot.scr" "$RESET" "$BOARD:/tmp/"

echo "### backup + replace on FAT, install reset script (sudo) ..."
sshpass -p "$PW" ssh $SSHOPT "$BOARD" "echo $PW | sudo -S sh -c '
  cp -f $B/image.ub  $B/image.ub.bak  2>/dev/null || true
  cp -f $B/boot.scr  $B/boot.scr.bak  2>/dev/null || true
  cp -f /tmp/image.ub $B/image.ub
  cp -f /tmp/boot.scr $B/boot.scr
  cp -f /tmp/pdp11_reset.sh /usr/bin/pdp11_reset.sh && chmod 755 /usr/bin/pdp11_reset.sh
  sync
  echo ---- FAT after ----; ls -la $B
  echo ---- on-card image.ub md5 ----; md5sum $B/image.ub
  echo ---- reset helper ----; ls -l /usr/bin/pdp11_reset.sh
'" 2>&1 | grep -v "Warning: Permanently"

echo "### expected image.ub md5 = $UB_MD5"
echo "Done. Reboot the board to boot the customized image (reserved-memory + EXT4 SD rootfs)."
