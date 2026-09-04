#!/bin/sh
# dlctl - swap PDP-11 disk images at runtime through pdp11-diskd's REST API.
# Covers both busses: RL11 (DL0..DL3) and RH11/RP06 (DB0, one drive only).
#
#   dlctl status              what's loaded in each unit, on both busses
#   dlctl list                available *.img files (in the daemon's image dir)
#   dlctl load <unit> <img>   load an image into <unit>
#   dlctl unload <unit>       unload <unit>
#
# <unit> is "rl0".."rl3" or "rh0" - or a bare number ("0", "1", ...), which
# means RL for backward compatibility (so "dlctl load 1 foo.img" still means
# DL1). <img> may be a full path or just a filename (resolved under $IMGDIR
# on the board). Override the target with DLCTL_API (default the local
# daemon) or the image dir with DLCTL_IMGDIR.
#
# The daemon remembers whichever set of images is currently loaded (both
# busses) in a persistent config file, and restores it on its next start/
# reboot - so a swap made here survives a power cycle.
#
# RT-11 notes: don't swap DL0/DB0 (the system devices), and only swap a unit
# when nothing has a file open on it.

API=${DLCTL_API:-http://127.0.0.1:8080}
IMGDIR=${DLCTL_IMGDIR:-/srv/pdp11}

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

cmd=$1
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  status) curl -s "$API/status"; echo ;;
  list)   curl -s "$API/images"; echo ;;
  load)
    unit=$1; img=$2
    [ -n "$unit" ] && [ -n "$img" ] || usage
    case "$img" in
      */*) path=$img ;;          # already a path
      *)   path=$IMGDIR/$img ;;  # bare name -> under the image dir
    esac
    curl -s "$API/load?unit=$unit&path=$path"; echo ;;
  unload)
    unit=$1
    [ -n "$unit" ] || usage
    curl -s "$API/unload?unit=$unit"; echo ;;
  *) usage ;;
esac
