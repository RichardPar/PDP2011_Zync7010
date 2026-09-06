#!/bin/bash
# deploy_pdp11_netd.sh - deploy a freshly built pdp11-netd binary to the
# running board and restart it via its init script. Mirrors
# deploy_pdp11_diskd.sh.
#
# NOTE: this only updates the userspace daemon binary. If xu.vhd/xuring.vhd
# themselves changed, or this is the first deploy after enabling have_xu,
# you need a full bitstream + BOOT.BIN rebuild and reflash first (see
# build.sh) - and the device-tree's ring_uio interrupt cell (currently a
# placeholder in system-user.dtsi) needs resolving against a live dtc dump,
# same as the RH disk bridge's first bring-up.
#
# Requires: build_pdp11_netd.sh already run (deploy/pdp11-netd present).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/deploy/pdp11-netd"
LOG=/var/log/pdp11-netd.log

BOARD=petalinux@192.168.10.185
PW=123456
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

[ -f "$BIN" ] || { echo "ERROR: missing $BIN - run build_pdp11_netd.sh first"; exit 1; }

echo "### copying $BIN to board (scp -O; plain scp/sftp is broken on the board)"
sshpass -p "$PW" scp -O $SSHOPT "$BIN" "$BOARD:/tmp/pdp11-netd.new"

echo "### install binary, restart via the init script (this rebuilds the"
echo "### br0 bridge - the SSH session below may need a reconnect if it was"
echo "### using eth0's OLD address)"
sshpass -p "$PW" ssh $SSHOPT "$BOARD" "echo $PW | sudo -S bash -c '
  cp -f /tmp/pdp11-netd.new /usr/bin/pdp11-netd
  chmod 755 /usr/bin/pdp11-netd
  rm -f $LOG

  /etc/init.d/pdp11-netd stop
  sleep 1
  kill -9 \$(pidof pdp11-netd) 2>/dev/null || true
  sleep 1

  /etc/init.d/pdp11-netd start
  sleep 3
  echo --- running: ---
  ps w | grep [p]dp11-netd | grep -v grep
  echo --- link state: ---
  ip -o link show
  echo --- initial log: ---
  head -30 $LOG
  echo --- done ---
'" 2>&1 | grep -v 'Warning: Permanently'

echo
echo "Tail the log with:  tail -f /var/log/pdp11-netd.log  (sudo)"
