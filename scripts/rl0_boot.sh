#!/bin/bash
# rl0_boot.sh - boot from the RL02 image on the board's microSD via ODT.
#
# Linux port of fpga_project_1/tools/rt11_boot.ps1. Talks to the PDP-11 M9312
# ODT console emulator (the '@' prompt) on a serial port, deposits a standard
# RL bootstrap at 1000 that reads block 0 (the OS boot block) of RL unit 0 into
# memory 0 and JMPs to it; the disk's own boot chain takes over from there.
#
# Prereq: an RL02 image (e.g. disks/rtv53_sd.img) written raw to the microSD in
# the board's SD slot, and the PDP-11 sitting at the ODT '@' prompt.
#
# Usage:  scripts/rl0_boot.sh [PORT] [UNIT]
#   PORT  serial device (default /dev/ttyUSB0 = PDP-11 ODT console)
#   UNIT  RL drive number 0..3 (default 0)
#
# NOTE: nothing else may hold the port (close any screen/putty on it first).

PORT="${1:-/dev/ttyUSB0}"
UNIT="${2:-0}"
WATCH_SECS=25

# RLCS read+go for the chosen unit: base 014 (func 6 = read data, unit 0),
# with the unit number in bits 8-9 (unit1=0414, unit2=01014, unit3=01414).
RLCS=$(printf '%06o' $(( 014 | (UNIT << 8) )))

# RL bootstrap @ 1000 (octal words, deposited in order, D auto-increments):
boot=(
  012737 000000 172516   # MOV #0,@#172516   MMR3=0: disable Unibus map
  012737 000000 174402   # MOV #0,@#174402   RLBA = 0
  012737 000000 174404   # MOV #0,@#174404   RLDA = 0 (cyl/head/sector 0)
  012737 177400 174406   # MOV #-256.,@#174406  RLMP = -256 words (1 sector)
  012737 "$RLCS" 174400  # MOV #RLCS,@#174400   read data + go, unit UNIT
  105737 174400          # TSTB @#174400     wait for controller ready
  100375                 # BPL .-2
  000137 000000          # JMP @#0           enter the loaded boot block
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
# than a fixed blind sleep - fixed sleeps are what made this unreliable
# (some runs the board answers slower than the guessed delay, so the next
# command lands mid-response and gets dropped/misread).
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
CHAR_DELAY=0.03
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
echo "ODT is up. Depositing RL bootstrap and booting RL${UNIT}..."

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
if grep -qiE 'RT-11|V05|\.[[:space:]]*$' "$LOG"; then
  echo "Looks booted. Open a terminal on $PORT (9600 8N1) for the interactive prompt."
else
  echo "No clear banner yet. Open a terminal on $PORT (9600 8N1), press Enter;"
  echo "if you get a prompt it booted. Otherwise check the RL image on the SD card."
fi
