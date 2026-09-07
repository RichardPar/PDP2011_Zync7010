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

## Running it

```
pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <dir>] [-c <config>] \
            [-R <rh0.img>] [-i <tap-ifname>] [-l <log>] \
            [<dl0.img> [<dl1.img> ...]]
```
