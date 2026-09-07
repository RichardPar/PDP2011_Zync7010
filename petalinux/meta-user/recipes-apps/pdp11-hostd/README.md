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

## Running it

```
pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <dir>] [-c <config>] \
            [-R <rh0.img>] [-i <tap-ifname>] [-l <log>] \
            [<dl0.img> [<dl1.img> ...]]
```
