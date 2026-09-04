#!/bin/bash
# rp06_boot.sh - boot from the RP06 image on RH11/DB0 via ODT. RH11/DB0 is
# now served by pdp11-diskd from a PS image file over its own AXI bridge
# (see rh_disk_s_axi_* in zynq_top.vhd) - this script only pokes RH11's
# registers over the console, so it works the same regardless of backend.
#
# Same idea as rl0_boot.sh but for the RH11/RP06 controller instead of RL11:
# talks to the PDP-11 M9312 ODT console emulator (the '@' prompt), deposits a
# bootstrap at 1000 that reads cylinder/track/sector 0 of RH unit 0 into
# memory 0 and JMPs to it; the disk's own boot chain takes over from there.
#
# Register map (rh11.vhd, base 0176700 per zynq_top.vhd have_rh/rh_type=6):
#   CS1 0176700  WC 0176702  BA 0176704  DA 0176706  CS2 0176710  DC 0176734
# Only unit 0 is implemented in this core (rh11.vhd: "elsif rmcs2_u /= "000"
# then -- nothing - there is one drive only"), so there's no unit argument.
# After reset rmds_dry/rmds_vv are already '1' (rh11.vhd ~line 1152-1153) so,
# unlike a real drive, no read-in-preset/pack-acknowledge is needed first -
# straight to a read data command works.
#
# Prereq: an RP06 image (815 cyl x 19 head x 22 sector, 512B/sector) loaded
# into RH0/DB0 via pdp11-diskd (dlctl load rh0 <img>, or the -R seed flag -
# see pdp11-diskd.c), and the PDP-11 sitting at the ODT '@' prompt (needs a
# bitstream built with bootrom => boot_odt, see zynq_top.vhd).
#
# Usage:  scripts/rp06_boot.sh [PORT]
#   PORT  serial device (default /dev/ttyUSB0 = PDP-11 ODT console)
#
# NOTE: nothing else may hold the port (close any screen/putty on it first).
# This is a first-contact test of real RH11/RP06 hardware - if it hangs
# instead of erroring cleanly, that's itself useful data, not just a script
# bug (see rmer1/rmer2 in rh11.vhd for what an error would look like on DS/ER1).

PORT="${1:-/dev/ttyUSB0}"
WATCH_SECS=25

# RH11 "read data" command word for CS1: function 11100 (28. = 034 octal),
# shifted left 1 for the GO bit's position, plus GO=1: (034<<1)|1 = 000071 octal.
RHCS1_READ=000071

# RH bootstrap @ 1000 (octal words, deposited in order, D auto-increments):
boot=(
  012737 000000 176710   # MOV #0,@#176710      RH CS2 = 0 (select unit 0)
  012737 000000 176706   # MOV #0,@#176706      RH DA = 0 (track/sector 0)
  012737 000000 176734   # MOV #0,@#176734      RH DC = 0 (cylinder 0)
  012737 000000 176704   # MOV #0,@#176704      RH BA = 0 (dest address)
  012737 177400 176702   # MOV #-256.,@#176702  RH WC = -256 words (1 sector)
  012737 "$RHCS1_READ" 176700   # MOV #71,@#176700   RH CS1 = read data + go
  105737 176700          # TSTB @#176700        wait for controller ready
  100375                 # BPL .-2
  000137 000000          # JMP @#0               enter the loaded boot block
)

if [ ! -e "$PORT" ]; then echo "ERROR: $PORT not found"; exit 1; fi
if command -v fuser >/dev/null && fuser "$PORT" >/dev/null 2>&1; then
  echo "ERROR: $PORT is in use by another program - close it first"; exit 1
fi

# 9600 8N1, raw, no echo/flow control
stty -F "$PORT" 9600 cs8 -cstopb -parenb -echo -icrnl -ixon -opost -crtscts raw 2>/dev/null

exec 3<>"$PORT" || { echo "ERROR: cannot open $PORT"; exit 1; }

# enable job control so the backgrounded pipeline below gets its own process
# group - needed so cleanup can kill the whole group (cat+sed+tee), not just
# the subshell's own pid. Without this, killing $CATPID alone leaves cat/sed/tee
# as orphans still holding $PORT open, and the NEXT run fails with "in use".
set -m

# background reader: capture everything the board sends AND echo it live,
# byte-for-byte, prefixed so it's visually distinct from what we send.
# stdbuf -o0 keeps cat from block-buffering so bytes show up as they arrive,
# not in a big lump at the end.
LOG=$(mktemp)
( stdbuf -o0 cat <&3 | stdbuf -o0 sed -u 's/^/<- /' | tee -a "$LOG" ) &
CATPID=$!
cleanup(){ kill -- "-$CATPID" 2>/dev/null; exec 3>&-; rm -f "$LOG"; }
trap cleanup EXIT

# adaptive settle: wait until the board has gone quiet for quiet_ms, rather
# than a fixed blind sleep.
wait_quiet(){
  local quiet_ms="${1:-100}" max_ms="${2:-800}"
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
}

# the ODT console can't take a burst write - it's a polled receiver with no
# FIFO, so a whole string written in one syscall drops characters. Pace them
# out one at a time, with a bit more air after the CR (that's when ODT
# actually processes/echoes the line).
CHAR_DELAY=0.015
CR_DELAY=0.15

send_char(){ printf '%s' "$1" >&3; sleep "$CHAR_DELAY"; }
send_cr(){ printf '\r' >&3; sleep "$CR_DELAY"; }

send(){
  echo "-> $1"
  local s="$1" i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    send_char "$c"
  done
  send_cr
  wait_quiet "${2:-100}" "${3:-800}"
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
echo "ODT is up. Depositing RH11/RP06 bootstrap and booting..."

# 2. load start address, deposit the bootstrap words
send "L 1000" 100 600
for w in "${boot[@]}"; do send "D $w" 80 500; done

# 3. reload start address, reset + start
send "L 1000" 100 600
: > "$LOG"
echo "-> S <CR> (start)"
send_char "S"
send_cr

# 4. watch the console (output streams live above as it arrives)
echo "----- console after boot (watching ${WATCH_SECS}s, live above) -----"
sleep "$WATCH_SECS"
echo "----------------------------------------------------------"
if grep -qiE 'unix|bsd|CR>|boot|#[[:space:]]*$' "$LOG"; then
  echo "Looks like the boot block ran. Open a terminal on $PORT (9600 8N1) for the interactive prompt."
else
  echo "No clear banner yet. This is a first-contact test of real RH11/RP06 hardware -"
  echo "check DS (0176712) and ER1 (0176714) at the ODT '@' prompt for error bits if it"
  echo "just sits there, rather than assuming it's only a script issue."
fi
