# pdp11-netd

Bridges the PDP-11's xu DEUNA (`xu.vhd`, `have_xu => 1` — UNIBUS 774510,
vector 120, BR5 + NPR) to the physical network: a tap device bridged with
eth0 on `br0`, so RSX/2.11BSD's stock DEUNA drivers reach the real LAN
transparently, `de0` and all. The station address is fixed at
08:00:2b:11:22:33 (`xu_phyad_w*` in `xu.vhd`).

The recipe ships two things: the daemon (`/usr/bin/pdp11-netd`) and its
SysV init script. It `RDEPENDS` on `bridge-utils`, which the daemon's br0
setup uses.

## The ring walk lives HERE, not in the FPGA

Two different FPGA-side descriptor-ring-walk engines each caused a real,
reproducible board hang, and both times xu.vhd's own debug state showed the
engine sitting idle at the moment of the freeze. Rather than debug a third
hardware state machine blind, the entire descriptor-ring algorithm moved
into this daemon: parsing descriptors, checking OWN, assembling frames,
advancing TXNEXT/RXNEXT, strobing TXI/RXI. All `xuring.vhd` provides in
hardware is the one DMA primitive that already worked reliably — a
single-word PDP-11 memory read/write over AXI-Lite — plus the ring
geometry, and a "command completed" event so the daemon can block on the
UIO fd instead of polling on a timer.

Descriptor format is the guest's own `struct de_ring` (2.11BSD
`if_dereg.h`) — TX and RX identical, **5 words / 10 bytes**, not a 4-word
layout:

| Word | Meaning |
|---|---|
| 0 | `r_slen` — buffer length in bytes |
| 1 | `r_segbl` — buffer address, low 16 bits |
| 2 | bit15 OWN, bits1:0 addr extension (bits 17:16), bit9 STF, bit8 ENF (`r_segbh` + `r_flags` packed) |
| 3 | RX: MLEN (received length). TX: status (`r_tdrerr`) |
| 4 | `r_rid` — never inspected by 2.11BSD's driver; untouched, but part of the stride |

Assuming 8 bytes here was the multi-day "board hang" bug: slot 0 sits at
offset 0 under either stride so the first TX always worked, but every
later slot's OWN check landed on the wrong word, TXNEXT froze forever, and
the guest's own retry loop pinned it at IPL 5 — which looked exactly like
a CPU/interrupt hang. Deterministic, never a race.

## How it talks to the PL

UIO device `pdp11net-ring` (node `ring_uio@43020000` in `system-user.dtsi`,
SPI 0x22 into IRQ_F2P — same hand-added-node workaround as the RH disk
bridge). Register map (byte offsets from the UIO mmap base):

| Offset | Meaning |
|---|---|
| `0x00` | MEMADDR (r/w) — PDP-11 byte address for the next word access |
| `0x04` | MEMDATA (r/w) — write value before a WRITE op / read result after a READ |
| `0x08` | MEMCTL — write: bit0=req, bit1=is_write; read: bit0=req echo, bit1=done |
| `0x0C`/`0x10` | TDRB / TRLEN (ro) — TX ring base + length, latched by the guest's WRF |
| `0x14`/`0x18` | RDRB / RRLEN (ro) — RX ring base + length |
| `0x1C`/`0x20` | TXNEXT / RXNEXT (r/w) — ring positions, owned by this daemon |
| `0x24` | PCSR1STATE (ro) — 0x3 = RUNNING |
| `0x28`/`0x2C` | SET_TXI / SET_RXI — write any value to strobe that interrupt |
| `0x30`–`0x60` | DEBUG / LASTCMD / HIST0-7 / HIST_WPTR / IRQTRACE / PCTRACE diagnostics |
| `0x64` | CMDEVT — set once per completed guest port command, folded into `irq` |

Two handshake subtleties, both of which corrupted real traffic before they
were understood:

- After acking an op with MEMCTL=0 you must wait for DONE to **drop**
  before the next request, or the next read returns the *previous* word
  (frames went out with visibly duplicated word pairs).
- A wake-up burst must be bounded (NAPI-style, max 32), or the poll thread
  spins through syscalls fast enough to starve the tap thread of
  `ring_lock` and re-creates a PDMD storm.

## RX path

tap0 sits on a bridge with Gigabit eth0, so the daemon — not the wire —
has to do the filtering and pacing a real DEUNA's 10base-T link did for
free:

- **Address filter** — own MAC and broadcast only (the guest enables no
  multicast addresses). Every frame forwarded costs hundreds of
  single-word DMA writes plus one of only 6 RX descriptors, so LAN chatter
  for other hosts must not get through.
- **Pre-RX queue** (256 frames) — frames are held here and fed into the
  6-slot guest ring only as the guest actually re-arms descriptors (max 4
  per drain), so a modern-LAN burst is absorbed instead of overwriting a
  pending ARP/ICMP reply.
- **Pacing is currently OFF** (`RX_LINK_RATE_BPS 0`) — the virtual-wire
  model delays without ever dropping, so broadcast junk can queue up ahead
  of a latency-critical reply. Re-enable only with a drop bound; see the
  note in `pdp11-netd.c`.
- **Framing faithfulness** — pad to the 60-byte Ethernet minimum and
  report MLEN including a 4-byte FCS, or 2.11BSD's `derecv()` computes
  `len < ETHERMIN` and silently discards the frame (this threw away every
  ARP reply at first). Never write past the guest's `r_slen` buffer size —
  that once panicked the guest with a trap type 3.

## Running it

```
pdp11-netd [-l <log>] [-i <tapname>]
```

- `-l` log file (default `/var/log/pdp11-netd.log`); `-i` tap interface
  (default `tap0`)
- auto-starts at boot (SysV init): brings tap0 up, creates `br0`, moves
  eth0 into it, and re-acquires the DHCP lease on br0 — eth0's own lease
  dies when it joins the bridge, and without the explicit re-DHCP the
  board goes silently unreachable over IPv4
- it only does something once the guest enables the interface
  (`ifconfig de0 up` on 2.11BSD, which runs the SELFTEST/START/WRF port
  commands); until then it just drops tap frames

## Building

Part of the PetaLinux image (`IMAGE_INSTALL:append` in
`meta-user/conf/petalinuxbsp.conf`), so a normal `./build.sh` (or
`docker/plnx.sh build`) picks it up; `CONFIG_TUN` is on in `bsp.cfg` for
its tap device. For a fast iteration on just this recipe,
`scripts/build_pdp11_netd.sh` cross-compiles it in the container and drops
the ARM binary in `deploy/`; `scripts/deploy_pdp11_netd.sh` pushes it to a
running board and restarts it. HDL changes (`xu.vhd`/`xuring.vhd`, or the
first deploy after enabling `have_xu`) still need `./build.sh bitstream` +
a BOOT.BIN reflash first — the scripts only update userspace.

The source is single-file C with a Makefile; `-pthread` is on the Makefile
rule itself so it survives bitbake's `CFLAGS` override. Every frame byte
moves through the single-word access path, so the `BENCH:` line the daemon
logs at startup (ns per word) is the number that bounds throughput.
