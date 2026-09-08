# pdp11-hostd

Serves every PS-facing PDP-11 device bridge from one process: the RL and
RH/RP06 disks from image files on the ARM side (a fake SD card in Linux),
and the XU (DEUNA) network bridge as a Linux tap device bridged with eth0.
All three PL bridges (`sddisk.vhd` x2, `xuaxi.vhd`) now share one AXI-Lite
expansion bus in the FPGA fabric (`vivado/scripts/02_create_bd.tcl`); this
daemon is the PS-side match - one binary, one init service, replacing the
earlier separate `pdp11-diskd`/`pdp11-espd` pair.

The recipe ships three things: the daemon (`/usr/bin/pdp11-hostd`), its
SysV init script, and `dlctl` (`/usr/bin/dlctl`), the client for the
runtime disk image-swap API. It `RDEPENDS` on `curl`, which `dlctl` uses.

The daemon also serves a **web front panel** on the same port - point a
browser at `http://<board>:8080/` and you get the drives and the DEUNA
drawn as the real peripherals, lamps and all. See "Web front panel" below.

Each served device is independently optional at runtime: RL is required
(fatal if its UIO device isn't found), RH and the network bridge are both
"disabled this run" if their UIO devices aren't present - e.g. a bitstream
built with `have_xu_net=0` (see `zynq_top.vhd`) still serves disks normally.

## Disks: how they talk to the PL

Each disk bus is its own AXI-Lite `sddisk.vhd` instance + UIO interrupt.
The UIO region is a handful of registers:

| Offset | Meaning |
|---|---|
| `0x000`-`0x3FC` | sector buffer |
| `0x800` | STATUS: bit0 = request pending, bit1 = is_write |
| `0x804` | BLOCK: 24-bit linear sector index |
| `0x808` | DONE: daemon writes here when finished (bit0 = error) |

RL02 sectors are 256 bytes (low 128 words of the buffer); RP06 sectors are
a full 512 bytes/256 words, no padding needed. `BLOCK` is linear across all
units on a bus with more than one (RL only), so the daemon splits it:
`unit = BLOCK / unit_sectors`, `local = BLOCK % unit_sectors`.

## Network: how it talks to the PL

See `docs/xu-networking-plan.md` for the full protocol writeup (register
map, wire framing, the microcode MAC-bootstrap subtlety). In short: one
AXI-Lite `xuaxi.vhd` bridge presents a buffer window (write -> the frame
the guest is about to receive, read -> the frame it just sent) plus
STATUS/LEN/DONE registers; this daemon drains outgoing frames to a tap
device and refreshes incoming frames from it, reimplementing the real
ESP32 reference firmware's exact wire framing against Linux networking
instead of Wi-Fi.

| Offset | Meaning |
|---|---|
| `0x0000`-`0x0C7F` | frame buffer window (write -> rx_buf, read -> tx_buf) |
| `0x1000` | STATUS: bit0 = a run is pending |
| `0x1004` | LEN: run length in bytes |
| `0x1008` | DONE: daemon writes when tx drained and rx refreshed |
| `0x100C` | HEARTBEAT (diagnostic) |
| `0x1010` | DEBUG1: DMA state + srdy (diagnostic) |
| `0x1014` | RUNSTATS: run start/done counts (diagnostic) |
| `0x1018` | DEBUG2: PCSR0/1 + npr/npg (diagnostic) |
| `0x101C` | DEBUG3: ifetch + guest-memory access counts (diagnostic) |

The diagnostic registers are read-only and surfaced in `/status`. They are
what localised the two bring-up bugs; the networking doc explains how to
triage with them.

### Threading

`serve_net()` owes the core a prompt DONE, so it never touches the tap
device: it only moves frames between the buffer window and two queues.
`rx_thread` poll()s the (non-blocking) tap and drains to EAGAIN; `tx_thread`
owns all injection. Both queues drop when full rather than adding unbounded
delay, matching what a real overloaded interface does.

### Receive filter

A real DEUNA passes all broadcast; on a modern LAN that buries the guest's
6-entry receive ring in ARP-for-other-hosts, mDNS and SSDP. So: unicast to us
always; broadcast only for ARP targeting the guest's own IP, which is learned
by snooping the guest's transmits (fail-open until known, so the guest can
always be resolved in the first place). `/status` reports `rx_acc_unicast`,
`rx_acc_bcast`, `rx_drop_bcast`, `rx_drop_other`, `rx_drop_qfull`, `tx_enq`,
`tx_written`, `tx_drop_qfull` and the learned `guest_ip`.

## Web front panel

`http://<board>:8080/` - the peripherals as they actually look, driven by
the counters the daemon already keeps:

* **RL11 / RL02** - a drive front per configured unit. Each has the pack turning
  behind its smoked window (stopped and greyed when nothing is mounted), a
  head-positioner rail whose carriage sits on the cylinder the last request
  landed on, and the drive's own four legend switches: **LOAD** (lit = no
  pack), **READY**, **FAULT** (lit for a couple of seconds after an I/O
  error), **WRITE PROT** (lit when the image could only be opened
  read-only). Under each: the image path and size, the cylinder, the last
  block in octal, and read/write/error counts.
* **RH11 / RP06** - the same, one drive (DB0), on RP06 geometry (418
  sectors/cylinder, 815 cylinders) instead of RL02's.
* **TU58 / DECtape II** - only when `tu58fs` is running; see below.
* **DEUNA / XU0** - RUN, DMA, XMIT, RECV, CARRIER and DROP lamps, log-scaled
  frame-rate meters, the station-address plate (MAC, tap device, the guest
  IP learned by snooping, PCSR0 in octal) and the frame/byte/drop counters.

  **RUN means the guest is driving the device**, not that xu0 is powered.
  It follows `run_start` (RUNSTATS), which only advances when the microcode
  runs a DMA cycle for a driver - and `run_idle_ms`, how long since it last
  moved. It deliberately does *not* follow the heartbeat: HEARTBEAT
  free-runs in xu0's own clock domain whenever the fabric is up, so a lamp
  driven from it sits lit next to `run_start = 0`, which is precisely the
  state worth seeing. The rack header spells the same thing out - `no driver
  started`, `driver quiet`, or `driver active`.

  This matters for reading `RX Q FULL`. Nothing pops the receive ring except
  `serve_net()`, which only runs when the core raises a request. With no
  guest driver the 32-entry queue fills once and stays full, and every frame
  the filter admits after that lands on `rx_drop_qfull` - so a steadily
  climbing count there, alongside `no driver started`, means frames are
  arriving for a guest that isn't listening, not that anything is broken.
  (The filter admits broadcast at all in that state because `guest_ip` is
  only learned by snooping the guest's own transmits, and it fails open
  until it knows - see the receive-filter section above.)
* **Console strip** - a 16-lamp register showing the last sector address in
  octal, plus LINK/DISK/NET/ERR.
* **Event log** - mounts, unmounts, resets and I/O errors as they happen.

There is also a **RESET** key on the console plate. It pulses the PDP-11-only
reset - the same thing the init script's `-r` does at boot and the U15 button
does in hardware, so only the PDP-11 core and its DDR bridge restart; Linux,
this daemon and the mounted disks are untouched and the machine reboots from
whatever is in DL0/DB0 right now. It is guarded by an arm/fire pair (press
once to arm, again within 5s to fire, and it disarms itself) rather than a
dialog, because anything that can reach this page can reboot the PDP-11 with
it. The daemon rate-limits it to one reset per 3s, so a double-click can't
interrupt the boot it just started, and reports a real error if `/dev/mem`
isn't reachable rather than claiming success.

Lamps aren't CSS transitions: each carries an intensity that rises fast and
decays slowly, so a lamp lit by one sector transfer flickers the way a
filament does rather than snapping on and off.

### Which drives get a front

The RL11 core addresses four units, but a real installation here runs two, and
a panel padded out with drives that were never wired up is just noise. So the
daemon marks a unit `show` in the panel JSON when it is below the bus's
`min_units` (2 for RL, 1 for RH) **or** when the persistent config actually put
an image in it - mount DL2 and its front appears, unmount it and the front goes
away. To mount into a unit that has no front, the rack head offers a **+ DL2**
button that reveals the next one.

Change `min_units` in the `bus_t` initialisers in `pdp11-hostd.c` if the
installation grows a third and fourth RL drive.

Every drive has a **MOUNT / UNMOUNT** control with a dropdown of the images
in the daemon's image directory (`-D`, default `/srv/pdp11`) - the same
`/load` and `/unload` calls `dlctl` makes, so a swap made in the browser is
persisted to `diskd.conf` and survives a reboot exactly as one made from the
command line. The RT-11 caveat applies just as much here: don't swap DL0/DB0
out from under a running system.

### TU58 (tu58fs)

The DECtape II is the odd one out: `tu58fs` is a **separate process** driving a
real serial line to the PDP-11 (a `ttyUL*`), not one of our AXI bridges, and it
carries its own HTTP control API (`--api`, default `:8081`). See the top-level
README, "Serial consoles and TU58".

So the daemon polls it (once a second - tape state changes at human speed) and
passes its `/status` body through **verbatim** as the `tu58` member of
`/api/state`. No JSON parser on this side, and any field a later `tu58fs` adds
arrives for free. `/tu58/status`, `/tu58/images`, `/tu58/load`, `/tu58/unload`,
`/tu58/save` and `/tu58/offline` proxy the control routes, so the page stays
same-origin and no second port has to be exposed. `-T <port>` picks the port,
`-T 0` disables both the poll and the proxy.

`tu58fs` is started by hand on whichever port the tape is wired to, so **"not
running" is a normal state, not an error**: `tu58` comes back `null` and the
panel hides the whole TU58 rack rather than showing dead hardware. Start
`tu58fs --api` and the rack appears on its own within a second.

The tiles are cartridges: reels, a paper label carrying the DEC filesystem
(or `TU58` for a raw image), and LOAD / READY / WRITE PROT / MODIFIED lamps.
MODIFIED is `tu58fs`'s `changed` - the image in memory differs from the file,
and **SAVE** writes it back. MOUNT takes a file, or a directory, which is
mounted as a shared drive (`shared=1`) with the filesystem from the picker
beside it. **TAKE OFFLINE** is `tu58fs`'s own offline mode, which lifts every
cartridge so they can be swapped safely.

One honest limitation: `tu58fs` keeps no per-block transfer counters, so
there is nothing to flicker a lamp per read the way the disks do. READY blips
when a poll shows the drive's state moved, and MODIFIED covers the write side;
per-transfer activity would need counters added upstream.

### How it's served

`libhttpd` (`files/httpd.c`, built as `libhttpd.a`) is a small embedded
HTTP/1.1 + WebSocket server written for this: no external dependencies (its
own SHA-1 and base64 for the RFC 6455 handshake, so nothing new enters the
rootfs), one thread per connection, keep-alive, and a broadcast call any
thread can make. It replaced the previous hand-rolled request loop; the REST
endpoints below are byte-for-byte the same, so `dlctl` and the scripts in
`scripts/` are unaffected.

| Endpoint | What |
|---|---|
| `GET /` | the front panel |
| `GET /api/state` | the panel's snapshot (per-unit counters, net counters) |
| `GET /ws` | WebSocket: the same snapshot ~10x/s, plus event lines |
| `GET /status`, `/images`, `/load`, `/unload` | the original REST API, unchanged |
| `POST /reset` | pulse the PDP-11-only reset (GET works too) |
| `GET /tu58/*` | proxied to `tu58fs`'s control API (see above) |

The panel pushes nothing when no browser is connected, and every action goes
through the REST endpoints - the socket carries no commands.

The page (`files/www/`) is compiled into the binary by `mkwww.sh` at build
time, because `scripts/deploy_pdp11_hostd.sh` installs the daemon by copying
a single ARM ELF to the board: assets under `/usr/share` would silently go
stale behind every quick redeploy. `-W <dir>` serves them from a directory
instead when you want to iterate on the CSS without a cross-compile.

## Running it

```
pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <dir>] [-c <config>] \
            [-R <rh0.img>] [-i <tap-ifname>] [-W <wwwdir>] [-T <tu58-port>] \
            [-l <log>] [<dl0.img> [<dl1.img> ...]]
```
