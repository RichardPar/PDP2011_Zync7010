#!/bin/bash
# deploy_pdp11_diskd.sh - deploy a freshly built pdp11-diskd binary to the
# running board and restart it via the normal init script, so it comes back
# up exactly the way a real boot would: reading /srv/pdp11/diskd.conf for
# which images are loaded on which unit (RL0..RL3, RH0), falling back to the
# init script's seed images only if that config doesn't exist yet. See
# README "Swapping disks without a reboot" for what diskd.conf is.
#
# Requires: build_pdp11_diskd.sh already run (deploy/pdp11-diskd present).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/deploy/pdp11-diskd"
LOG=/var/log/pdp11-diskd.log

BOARD=petalinux@192.168.10.192
PW=123456
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

[ -f "$BIN" ] || { echo "ERROR: missing $BIN - run build_pdp11_diskd.sh first"; exit 1; }

echo "### copying $BIN to board (scp -O; plain scp/sftp is broken on the board)"
sshpass -p "$PW" scp -O $SSHOPT "$BIN" "$BOARD:/tmp/pdp11-diskd.new"

echo "### install binary, restart via the init script"
sshpass -p "$PW" ssh $SSHOPT "$BOARD" "echo $PW | sudo -S bash -c '
  cp -f /tmp/pdp11-diskd.new /usr/bin/pdp11-diskd
  chmod 755 /usr/bin/pdp11-diskd
  rm -f $LOG

  # stop any running daemon. SIGTERM first, then SIGKILL - a daemon blocked in
  # the UIO read() ignores SIGTERM until an interrupt arrives, so -9 is needed
  # to guarantee it is gone before the init script starts a second one (double
  # -r = double reset + dueling daemons corrupt the image).
  kill \$(pidof pdp11-diskd) 2>/dev/null || true
  sleep 1
  kill -9 \$(pidof pdp11-diskd) 2>/dev/null || true
  sleep 1

  /etc/init.d/pdp11-diskd start
  sleep 2
  echo --- running: ---
  ps w | grep [p]dp11-diskd | grep -v grep
  echo --- initial log: ---
  head -20 $LOG
  echo --- done ---
'" 2>&1 | grep -v 'Warning: Permanently'

echo
echo "Tail the log with:  tail -f /var/log/pdp11-diskd.log  (sudo)"
echo "PDP-11 console:     /dev/ttyUSB1 at 9600"
