#!/bin/bash
# dlctl.sh - drive the board's pdp11-diskd REST API from the dev host, and push
# images over to it. Mirror of the on-board `dlctl`, plus upload helpers.
# Covers both busses: RL11 (DL0..DL3) and RH11/RP06 (DB0, one drive only).
#
#   ./scripts/dlctl.sh status
#   ./scripts/dlctl.sh list
#   ./scripts/dlctl.sh load   <unit> <img-on-board>   # path, or bare name in /srv/pdp11
#   ./scripts/dlctl.sh unload <unit>
#   ./scripts/dlctl.sh push   <local.img> [name]      # copy a local image to /srv/pdp11
#   ./scripts/dlctl.sh swap   <unit> <local.img>      # push then load, in one go
#
# <unit> is "rl0".."rl3" or "rh0" - or a bare number ("0", "1", ...), which
# means RL for backward compatibility. The daemon persists whichever images
# are loaded (both busses) and restores them across a reboot.
#
# Env: BOARD_IP (default 192.168.10.192), BOARD_PW (default 123456).
# RT-11: don't swap DL0/DB0 (system devices); swap a unit only when it's idle.

set -euo pipefail
BOARD_IP=${BOARD_IP:-192.168.10.192}
BOARD_PW=${BOARD_PW:-123456}
API="http://$BOARD_IP:8080"
IMGDIR=/srv/pdp11
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# push a local file to /srv/pdp11/<name> on the board (via /tmp + sudo)
push() {
    local local_img=$1 name=${2:-$(basename "$1")}
    [ -f "$local_img" ] || { echo "no such file: $local_img" >&2; exit 1; }
    echo "### pushing $local_img -> $BOARD_IP:$IMGDIR/$name"
    sshpass -p "$BOARD_PW" scp -O $SSHOPT "$local_img" "petalinux@$BOARD_IP:/tmp/$name"
    sshpass -p "$BOARD_PW" ssh $SSHOPT "petalinux@$BOARD_IP" \
        "echo $BOARD_PW | sudo -S sh -c 'mkdir -p $IMGDIR && mv -f /tmp/$name $IMGDIR/$name && sync'" \
        2>&1 | grep -v 'Warning: Permanently' || true
    echo "pushed as $IMGDIR/$name"
}

cmd=${1:-}; [ -n "$cmd" ] || usage; shift || true

case "$cmd" in
  status) curl -s "$API/status"; echo ;;
  list)   curl -s "$API/images"; echo ;;
  load)
    unit=${1:-}; img=${2:-}
    [ -n "$unit" ] && [ -n "$img" ] || usage
    case "$img" in */*) path=$img ;; *) path=$IMGDIR/$img ;; esac
    curl -s "$API/load?unit=$unit&path=$path"; echo ;;
  unload)
    unit=${1:-}; [ -n "$unit" ] || usage
    curl -s "$API/unload?unit=$unit"; echo ;;
  push)
    [ -n "${1:-}" ] || usage
    push "$1" "${2:-}" ;;
  swap)
    unit=${1:-}; local_img=${2:-}
    [ -n "$unit" ] && [ -n "$local_img" ] || usage
    name=$(basename "$local_img")
    push "$local_img" "$name"
    echo "### loading $IMGDIR/$name into DL$unit"
    curl -s "$API/load?unit=$unit&path=$IMGDIR/$name"; echo ;;
  *) usage ;;
esac
