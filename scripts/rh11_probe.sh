#!/bin/bash
# rh11_probe.sh - probe RH11/RP06 registers one at a time via ODT's L/E
# (load address / examine), instead of running the full boot bootstrap.
# Use this when rp06_boot.sh hangs, to isolate WHERE: a bad bus/address
# decode (examining CS1 alone hangs) vs. a trap into garbage DDR memory
# (trap vector 4 looks wrong) vs. something only wrong in the actual
# read-data command path (registers examine fine, only the full boot hangs).
#
# Prereq: the PDP-11 sitting at the ODT '@' prompt (reset it if not).
#
# Usage:  scripts/rh11_probe.sh [PORT]
#   PORT  serial device (default /dev/ttyUSB0 = PDP-11 ODT console)
#
# NOTE: nothing else may hold the port (close any screen/putty on it first).
# Each step prints the board's raw response - read the echoed octal value
# yourself, this script doesn't try to parse/interpret it.

PORT="${1:-/dev/ttyUSB0}"

# label:address pairs, examined in order. Stops and reports immediately if
# any single L/E pair itself seems to hang (no response within its window) -
# that's the answer: this is the first register access that doesn't come back.
declare -a PROBES=(
  "trap vector 4 (bus/addressing error):4"
  "trap vector 10 (illegal instruction):10"
  "RH11 CS1 (control/status 1):176700"
  "RH11 CS2 (control/status 2):176710"
  "RH11 DS  (drive status):176712"
  "RH11 ER1 (error status 1):176714"
)

if [ ! -e "$PORT" ]; then echo "ERROR: $PORT not found"; exit 1; fi
if command -v fuser >/dev/null && fuser "$PORT" >/dev/null 2>&1; then
  echo "ERROR: $PORT is in use by another program - close it first"; exit 1
fi

stty -F "$PORT" 9600 cs8 -cstopb -parenb -echo -icrnl -ixon -opost -crtscts raw 2>/dev/null
exec 3<>"$PORT" || { echo "ERROR: cannot open $PORT"; exit 1; }

set -m
LOG=$(mktemp)
( stdbuf -o0 cat <&3 | stdbuf -o0 sed -u 's/^/<- /' | tee -a "$LOG" ) &
CATPID=$!
cleanup(){ kill -- "-$CATPID" 2>/dev/null; exec 3>&-; rm -f "$LOG"; }
trap cleanup EXIT

wait_quiet(){
  local quiet_ms="${1:-150}" max_ms="${2:-800}"
  local last_size size stable_ms=0 waited_ms=0
  last_size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  while [ "$waited_ms" -lt "$max_ms" ]; do
    sleep 0.03
    waited_ms=$((waited_ms + 30))
    size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" != "$last_size" ]; then
      last_size=$size
      stable_ms=0
    else
      stable_ms=$((stable_ms + 30))
      [ "$stable_ms" -ge "$quiet_ms" ] && return 0
    fi
  done
  return 1   # timed out without going quiet - the board is still "talking"
             # (or genuinely stuck) when we gave up waiting
}

CHAR_DELAY=0.015
CR_DELAY=0.15
send_char(){ printf '%s' "$1" >&3; sleep "$CHAR_DELAY"; }
send_cr(){ printf '\r' >&3; sleep "$CR_DELAY"; }
send(){
  echo "-> $1"
  local s="$1" i c
  for (( i=0; i<${#s}; i++ )); do c="${s:$i:1}"; send_char "$c"; done
  send_cr
  wait_quiet "${2:-150}" "${3:-800}"
}

# 1. make sure ODT is alive ('@' prompt)
got_prompt=0
for i in 1 2 3 4; do
  : > "$LOG"
  echo "-> <CR> (probe $i/4)"
  send_cr
  wait_quiet 150 700
  grep -q '@' "$LOG" && { got_prompt=1; break; }
done
if [ "$got_prompt" != 1 ]; then
  echo "No '@' prompt on $PORT - is the board at ODT? (reset the PDP-11 and retry)"; exit 1
fi
echo "ODT is up. Probing registers one at a time - watch for where it stops responding."
echo

for entry in "${PROBES[@]}"; do
  label="${entry%%:*}"
  addr="${entry##*:}"
  echo "===== $label (address $addr) ====="
  : > "$LOG"
  send "L $addr" 150 800
  : > "$LOG"
  if send "E " 150 800; then
    echo "  (responded)"
  else
    echo "  *** NO RESPONSE within timeout - this is likely where it hangs. ***"
    echo "  Reset the board before trying anything else; ODT may be stuck."
    exit 1
  fi
  echo
done

echo "All probes responded. If rp06_boot.sh still hangs, the problem is specific"
echo "to the read-data command path (GO bit / the sddisk AXI bridge + pdp11-hostd),"
echo "not basic register access."
