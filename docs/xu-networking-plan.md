# XU networking via a PS-side "virtual ESP32" bridge

*Design, bring-up, and the two bugs that had to be found. Working on hardware.*

## Context

The project has twice attempted PDP-11 Ethernet by hand-writing a brand-new
DEUNA command-dispatch FSM and descriptor-ring walker directly in `xu.vhd`
(see memory `xu-ethernet-bridge`). Both attempts were abandoned after a long
chain of RAM-inference/synthesis bugs, an LUT-budget overrun, and finally a
guest-CPU IPL/PSW hang that was never root-caused; at the time of writing
the repo had been reset back to `b5b2c27` with none of that code present.

Investigating the **unmodified, currently-checked-in** `xu.vhd` found that it
already contains a complete, working, upstream implementation of the DEUNA
that was never used: a *second, embedded* PDP-11 core (`cpu0`/`mmu0`, its own
`kl0` console + `kw0` line clock on a private local unibus) that runs real,
pre-assembled DEUNA microcode (`xubr.mac` for the ENC424J600 variant,
`xubw.mac` for the **ESP32** variant) from the upstream `pdp2011.sytse.net`
distribution. That microcode is what actually implements PCSR0-3,
GETPCBB/GETCMD/WRF/PDMD, and the descriptor rings — i.e. exactly the
protocol the hand-written FSM was trying (and struggling) to reimplement
from SIMH source. It had never been enabled (`have_xu`/`have_xu_esp` were
unset in `zynq_top.vhd`) or wired to real pins — which is why both of the
bugs found during bring-up had survived in the tree undetected.

The ESP32 variant's own hardware interface (`xubf.vhd`) is deliberately
tiny: 3 host registers (**XF** xmit-from address, **RT** receive-to
address — writing this arms/starts a transfer —, **RL** run length in
bytes) plus an **SRDY** status bit, all local to `xu.vhd`'s private
unibus (base `o"777000"`, invisible to the guest). One "run" DMAs `RL`
bytes from PDP-11 memory at `XF` out, and simultaneously DMAs `RL` bytes
in to `RT` — a full-duplex, fixed-shape byte shuttle, not a smart
protocol engine. Confirmed directly in `xubw.mac` (`hdrlen=12`, magic
`0xaa`/`0x55` on receive frames, `0xa0a0` on transmit frames — an exact
match to the real ESP32 firmware's `app_spitask.c`).

**The plan**: reuse the proven microcode and the `xubf` register contract
completely unmodified, and replace only the *physical SPI-to-a-real-ESP32*
half with a new AXI-Lite bridge exposing the identical XF/RT/RL/SRDY
contract to a new Linux daemon on the Zynq PS, which reimplements
`app_spitask.c`'s exact framing logic against a real Linux network
interface (tap/bridge) instead of Wi-Fi. This is a much smaller, lower-risk
surface than either previous attempt: no DEUNA protocol/ring-walk logic to
get right in hardware or software — that already works, unmodified, inside
the microcode — only a byte-buffer shuttle plus a header format we already
know exactly (down to the CRC32).

## Status: WORKING on hardware — 0% packet loss

2.11BSD on the guest does `ifconfig de0 <ip> up` and pings across the
bridge with **0% loss** (41/41). Disks are unaffected. See
"[What it took: two bugs](#what-it-took-two-bugs)" below for the two real
defects that had to be found first, and "[Diagnostic registers]
(#diagnostic-registers)" for the instrumentation that found them — that
instrumentation is still in the design and is the first thing to reach for
if this ever regresses.

The rest of this document is the original design writeup, and it held up:
the architecture below was implemented exactly as described and did not need
rethinking. Both bugs were in the *implementation* of it, not the design.

The build/test steps this section used to list as outstanding (full
`./build.sh` for `CONFIG_TUN` and the new BD slave/UIO node, a live `dtc`
dump to fix the dtsi interrupt-cell placeholder, then guest testing) are all
done — the interrupt cell was verified against a real `dtc` dump and is
correct.

## Architecture

**FPGA side**
- `vivado/pdp2011_core/core/xuaxi.vhd` (new): same local-unibus host
  register interface as `xubf.vhd` (base_addr, npr/npg, bus_*,
  bus_master_*, `have_xu_esp`, XF/RT/RL/SRDY semantics) but with a plain
  clk-domain DMA/run FSM instead of `xubf.vhd`'s dual-clock bit-banged SPI
  shifter — no physical bit clock to match any more, so the whole transfer
  is just word-at-a-time bus-master reads/writes into two buffers.
  - **Actual AXI-Lite register map** (ended up simpler than first sketched
    — one shared buffer-window address, direction picks the buffer, exactly
    `sddisk.vhd`'s own `rsector`/`wsector` convention):
    `0x0000-0x0C7F` buffer window (WRITE → `rx_buf`, READ → `tx_buf`,
    index = `addr(11:2)`), `0x1000` STATUS, `0x1004` LEN, `0x1008` DONE.
  - Two 800-word buffers (`tx_buf`/`rx_buf`), each strictly single-writer/
    single-reader across the clock-domain boundary (the multi-driver and
    RAM-inference lessons from `xu-ethernet-bridge` applied directly this
    time, not rediscovered). Confirmed by a standalone out-of-context synth
    check: `rx_buf` infers a real `RAMB18E1` unaided; `tx_buf` — same
    2-port shape, but its read lands in `axi_rdata`, a register shared/
    muxed with the STATUS/LEN reads (the same pattern `sddisk.vhd` itself
    uses) — falls back to ~65 `RAM64M` distributed-RAM primitives instead.
    A `ram_style="block"` attribute was tried and confirmed genuinely
    infeasible for that specific shape ("trying to implement using
    LUTRAM" in the synth log), not just unused. Left as distributed RAM
    deliberately: measured cost is 474 LUTs / 2.7% of the xc7z010 for the
    whole module — not worth a read-pipeline rework to chase.
  - A proper 4-phase start/ack handshake for the daemon round-trip
    (`run_req`/`run_done_lvl`, each 2-FF synchronised across the clock
    domain) — the same shape as `sddisk.vhd`'s `read_start`/`read_done`,
    *not* the toggle/`CMDEVT` scheme the abandoned attempt had to invent
    from scratch (unnecessary here since this design started from the
    already-proven disk-bridge idiom instead of bolting interrupts on
    after the fact).
  - One deliberate protocol simplification vs. a real SPI transaction: TX
    and RX are sequenced (fill `tx_buf`, hand off, wait for the daemon's
    DONE, only then DMA `rx_buf` into PDP-11 memory) rather than
    simultaneous — invisible to the microcode, since `rx_buf`'s content was
    always independent of `tx_buf`'s on the real ESP32 too. Costs one AXI
    round-trip of latency per run.
- `xu.vhd`: `xubf0: xubf port map(...)` replaced with `xuaxi0: xuaxi port
  map(...)`. Nothing else inside `xu.vhd` changed — `cpu0`, `mmu0`, `kl0`,
  `kw0`, `xubw0` (the microcode ROM/RAM) are exactly as they were.
  `net_s_axi_*`/`net_irq` threaded up through `xu.vhd` → `unibus.vhd` →
  `zynq_top.vhd`, mirroring `rl_disk_s_axi_*`/`rh_disk_s_axi_*`. Confirmed
  via a standalone synth check of the whole `xu` entity (real `cpu`/`mmu`/
  `kl11`/`kw11l`/`xubr`/`xubw`/`xubl`/`xubm`/`xuaxi` submodules, not black
  boxes): 0 errors, 2798 LUTs (15.9%), 6.5 block RAM tiles (10.8%). A
  second check of the whole `unibus` entity (adding real `rl11`/`rh11`/
  `rk11`/`csdr`/`dr11c`/`ibv11`/`mnc*`/`sddisk`/`cpuregs`) also came back 0
  errors (the only critical warnings are pre-existing black-box stubs —
  `cr11`, `m9312h*` — for files this project has never had, unrelated to
  this change).
- `zynq_top.vhd`: `constant have_xu_net : integer := 1;` drives
  `have_xu => have_xu_net, have_xu_esp => have_xu_net` (leaves
  `have_xu_enc` at 0) — flip to `0` and rebuild to cleanly fall back to no
  networking without touching any wiring.
- `vivado/scripts/02_create_bd.tcl`: `axi_interconn_gp0` NUM_MI 7→8 (new
  M07), `uart_irq_concat` NUM_PORTS 5→6 (new In5), `zynq_top_0/net_s_axi`
  wired to M07 + `net_irq` to concat In5, address assigned at
  `0x43020000`/64K (next free slot after the disk bridges).
- `system-user.dtsi`: new `net_uio@43020000` node (`linux,uio-name =
  "pdp11net"`), same node-splitting requirement the RH11 bridge already
  needed. Its `interrupts` cell (`<0 0x22 4>`) was computed the same way
  `rh_disk_uio`'s `0x21` was derived (concat port index → `IRQ_F2P[index]` →
  GIC SPI 61+index → DT cell SPI-32; this is concat index 5, so
  61+5-32=0x22), and has since been **verified correct against a live `dtc`
  dump on the board** (`interrupts = <0x00 0x22 0x04>`) — the one gotcha
  every AXI bridge in this project has hit, checked rather than assumed.

**PS side**
- **Update**: the standalone `pdp11-espd` daemon described below was
  subsequently merged into `pdp11-hostd` (which also absorbed
  `pdp11-diskd`) once RL/RH/net were consolidated behind one shared AXI-Lite
  expansion bus - one process/binary/init-service for every PS-facing
  device now, instead of two. The logic itself (register map, wire
  framing, MAC bootstrap, tap/bridge setup) carried over unchanged into
  `serve_net()`/`net_t` in `pdp11-hostd.c`; only the surrounding process
  structure changed. The rest of this section is kept as originally
  written (describing the code when it was still its own daemon) since the
  protocol details are still accurate - just mentally substitute
  `pdp11-hostd` for `pdp11-espd` throughout.
- `petalinux/meta-user/recipes-apps/pdp11-espd/` (now removed, merged into
  `pdp11-hostd/` - see above) originally mirrored `pdp11-diskd`'s Makefile/
  init-script/`.bb` layout - no REST API or persistent config needed for
  network. `pdp11-espd.c` ported `xuesp/main/app_spitask.c`'s exact wire
  framing (fetched from the
  upstream `pdp2011.sytse.net` distribution, extracted to a scratch dir):
  `hdrlen=12`, RX-direction magic `0xaa 0x55` + sequence byte + queued-
  count + big-endian length + 6-byte MAC, TX-direction magic `0xa0 0xa0` +
  big-endian length (no MAC field, no +4 padding — that convention is
  RX-only, confirmed by reading both `app_spitask.c` and `xubw.mac`), CRC32
  appended to RX frames only (TX needs none — a Linux tap `write()` wants a
  bare Ethernet frame, no FCS trailer, unlike `esp_wifi_internal_tx()`).
  - **A subtlety only found by reading `xubw.mac` directly**: the
    microcode's own "default physical address" (`dbia`/`dlaa`) is
    zero-initialized in ROM and gets *latched from the RX header's MAC
    field the first time it's ever non-zero* (`tst dbia` / `mov
    #dlaa,r0` around line 125) — exactly mirroring `curr_wifi_mac` in
    `app_spitask.c`. The guest driver then adopts this via its own
    `FC_RDPHYAD` probe. So `pdp11-espd` must write a chosen MAC into
    every RX header, every cycle, unconditionally — it's how the guest's
    interface address gets set at all, not just informational. Uses
    `08:00:2b:11:22:33` (DEC's real registered OUI), matching the earlier
    from-scratch attempt's own choice.
  - `open_tap()`/`setup_bridge()` reused verbatim from the abandoned
    `pdp11-netd.c` (`backup/deuna-swring-attempt-2026-09-06`), DHCP-on-
    `br0`-not-`eth0` fix included.
  - The same MAC-address RX filter (own MAC or exact broadcast only,
    nothing protocol-specific) the earlier attempt validated as correctly
    scoped, ported verbatim with the same rationale.
  - Interrupt-driven via the exact `write(uio,1)` + blocking `read(uio)`
    idiom already proven in `pdp11-diskd.c`'s `serve_bus()` — deliberately
    *not* the NAPI-style bounded-drain loop the earlier attempt needed,
    since that was a fix for a specific regression (a fixed-timer-then-
    interrupt-storm bug) that doesn't apply here; this design was
    interrupt-driven from its first line.
  - A second thread (`rx_thread`) blocks on `read(tap0)` and feeds a small
    mutex-protected ring queue (depth 20, matching the real firmware's own
    `xQueueCreate(20, ...)`) — mirrors the real ESP32 firmware's own
    architecture (a receive callback filling a queue, decoupled from the
    request-driven drain loop) rather than an inline non-blocking read.
  - Registered in `petalinuxbsp.conf` (`IMAGE_INSTALL:append`), and
    `CONFIG_TUN=y` added to `bsp.cfg` (missing by default — confirmed the
    same failure the earlier attempt hit: `open /dev/net/tun: No such file
    or directory`).
  - Compiles cleanly with the host `gcc -Wall -Wextra -pthread` (only the
    same class of benign warnings `pdp11-diskd.c` itself already has:
    unchecked `system()` return values, a conservative `snprintf`
    truncation warning). Since cross-compiled, deployed and run on the
    board — see the status section at the top.

## What it took: two bugs

Both were in the new bridge (`xuaxi.vhd`), not in the microcode, the
daemon, or the AXI fabric. Neither could have been caught by synthesis —
both needed hardware.

### 1. SRDY polarity was inverted (the "guest hang")

**Symptom**: `ifconfig de0` worked, then `ping` froze the guest completely —
console dead, and *all* other guest activity stopped too (RH disk I/O went
silent). Linux and the daemon stayed perfectly healthy. It looked exactly
like a guest CPU or bus-arbitration fault, and a lot of time went into
chasing it as one.

**Cause**: **SRDY is active LOW.** `xuaxi.vhd` had
`srdy <= '1' when state = s_idle else '0'` — reporting "busy" precisely when
it was idle and ready.

Three independent sources agree on the polarity, and any one of them would
have settled it:

- `xubf.vhd` (the module `xuaxi.vhd` replaces, still in the tree): `srdy`
  comes straight off the physical ESP32's `xubf_srdy` pin, is **reset to
  `'1'`**, and its DMA engine proceeds only `if npg = '1' and srdy = '0'`.
  Its status-word assignment is byte-identical to ours.
- `xubw.mac`'s main loop: `xubfc` (read that status word) then `bmi 30$` —
  if **bit 15 is SET** it treats the frontend as *not* ready.
- `30$` is nothing but `pcsrsrv` (host command servicing). The `20$` block
  it skips is the **only** place the transmit ring is ever polled.

So: idle → reported busy → the microcode branched past all payload
processing forever → it never executed `xubf` → no run ever started → the
engine stayed in `s_idle`. A self-sustaining deadlock.

Every observed symptom follows from it, including the confusing ones:
`run_start_count` stuck at 0, the transmit ring never polled, `ifetch_count`
racing (it was spinning the main loop at full speed), and PCSR port commands
*still being serviced* — because `30$`, the label it kept branching to, is
exactly where command servicing lives. The guest wedge on top is 2.11BSD's
`deintr()` → `destart()` → PDMD → DNI → BR5 loop livelocking at BR5, which
starves the KL11 console at BR4 and stops all base-level work — hence disk
I/O going quiet too.

### 2. TX DMA captured one cycle too early (100% of transmits dropped)

**Symptom**: after fixing SRDY, the guest transmitted and `ping` ran without
hanging, but with **100% packet loss** and not a single error logged
anywhere.

**Cause**: `s_tx_req` asserted the address and `bus_master_control_dati`,
then `s_tx_cap` latched `bus_master_dati` on the very next cycle. On xu0's
local unibus — RAM behind its own `mmu0` — the data is not valid that soon,
so `tx_buf(k)` received the word for address `k-1`. Every frame reached the
daemon shifted two bytes, putting the `0xa0a0` magic at bytes 2-3 instead of
0-1, so the daemon's magic check failed and it silently discarded
everything.

Proved directly from the daemon's own header dump:

```
NET: txbuf hdr 00 00 a0 a0 b0 00 ...   (before: magic at bytes 2-3)
NET: txbuf hdr a0 a0 be 00 00 00 ...   (after:  magic at bytes 0-1)
```

**Fix**: an `s_tx_wait` state between request and capture. Note that
`rh11.vhd` (production, works daily) and `xubf.vhd` both capture one cycle
after asserting and are fine against *main* memory — so this is specific to
the local unibus. `xubf.vhd` very likely carries the same latent bug; its
DMA has never run on hardware either, since `have_xu` was 0 in every build
before this work.

RX was unaffected throughout, because writes are fire-and-forget (address,
data and `dato` all asserted together).

## Diagnostic registers

Added to `xuaxi.vhd` to find the above, and deliberately kept — they cost
about 130 flip-flops and roughly 80 LUTs, and each one eliminates a whole
class of cause. All are also surfaced in `pdp11-hostd`'s `/status` JSON.

| Offset | Name | Use |
|---|---|---|
| `0x100C` | HEARTBEAT | free-running counter in xu0's clock domain. Proves the clock is alive and reset isn't asserted — but **not** that the microcode is making progress (it ticks even if cpu0 is spinning or dead). |
| `0x1010` | DEBUG1 | DMA FSM state + `srdy` (active low). |
| `0x1014` | RUNSTATS | `run_start_count` / `run_done_count`. Stuck at 0 during an attempted transmit ⇒ the microcode never wrote RT at all. |
| `0x1018` | DEBUG2 | PCSR0, PCSR1 port state, and outer/xubm/cpu0 npr+npg. |
| `0x101C` | DEBUG3 | `ifetch_count` (cpu0 instruction fetches — distinguishes "microcode trapped" from "microcode spinning", which HEARTBEAT cannot) and `xubm_run_count` (guest-memory accesses). |

The decisive triage is a single `/status` read: `ifetch_count` frozen ⇒
microcode trapped or halted; `xubm_npr` high with `xubm_npg` low ⇒ waiting
on a local bus grant; `ifetch_count` climbing but `run_start_count` stuck ⇒
microcode running but never attempting a transfer (which is what pointed at
SRDY).

## Theories that were wrong

Recorded because each cost real time, and re-deriving them would cost it
again:

- **`xubm.vhd` clock-domain crossing.** Its two processes run on `clk` and
  `xubmclk`, which looked like an unsynchronised async crossing. It is not:
  `nclk <= not clk` (`unibus.vhd:2593`), so they are the same net on
  opposite edges, and `rh11.vhd` uses the identical idiom in production.
- **BR5 interrupt starvation by RH.** Tested directly with RH idle; the
  guest still hung.
- **Descriptor `ERRS`/`BUFL` flagging.** Predicted `Ierrs` would track the
  losses; measured `Ierrs` = 6 lifetime against 6000+ packets. Refuted.
- **Payload corruption in the RX path.** Predicted ICMP bad-checksums would
  climb with the losses; measured **+0** across a run with 7 losses.
  Refuted.

## The 1-in-6 receive loss (resolved)

For a while the guest lost exactly every 6th inbound frame — `NRCV` is 6
(`if_de.h`), one slot per ring revolution. The frames died silently in
`xubw.mac`'s `pktin`, at `bit #100000,rdre+4 / beq 80$` ("descriptor not
owned by the port"), which discards with **no error flag and no counter** —
which is why nothing in `netstat` accounted for them.

The measurement that localised it: daemon delivered 198/198 with zero queue
drops; guest ping 42 sent / 35 received; `ip: total packets received` +35;
`icmp: echo reply` +35; `icmp: bad checksums` +0. So the missing frames
never reached IP, weren't corrupt, and weren't error-counted.

**A clean reboot cleared it entirely (41/41, 0% loss)**, so it is not a
standing defect. The cause was a persistent one-slot phase offset between
the microcode's `rcurr` and the driver's `ds_rindex` — a fixed offset makes
the port hit an un-recycled descriptor exactly once per lap, at any traffic
rate, which is why it looked so structural. It was most likely self-inflicted
by repeatedly restarting the daemon under a live guest during debugging;
each restart can lose an in-flight run and shift the phase by one, and
nothing resyncs the cursors short of a re-init.

**If it recurs**, try `ifconfig de0 down` then `ifconfig de0 <ip> up` before
rebooting: `deinit()` re-hangs all `NRCV` descriptors and issues `CMD_START`,
whose microcode handler does `mov rdrbh,rcurrh / mov rdrbl,rcurrl`, resetting
`rcurr` to the ring base. (Untested — a reboot is what actually fixed it.)

## Round-trip time: why the guest always says 16.667 ms

It is not transit time. On the wire, Linux answers in **90 µs**, and the
bridge adds well under a millisecond. Three things stack up:

- **~7.1 ms** is the guest itself — a PDP-11/44-class CPU running the
  2.11BSD IP stack. This is the irreducible floor.
- **0–16.7 ms** waiting for the next 60 Hz tick, because BSD defers
  received-packet processing to software-interrupt level, which runs in step
  with the KW11-L line clock (`kw11l_hz => 60`).
- **Display quantisation**: 2.11BSD measures RTT in whole ticks, and a tick
  *is* 16.667 ms, so any sub-tick round trip prints as exactly one tick.

`ping` sends once per second, and 1 s is *exactly* 60 ticks, so the tick wait
is the same every time — which is why the guest's own figure is always
precisely 16.667. Measured from Linux (µs resolution), a 1.0 s interval gives
a tightly phase-locked 7.302/7.718/8.446 ms, while a 0.37 s interval (22.2
ticks, so the phase drifts) spreads to 7.144/15.783/22.960 — one full tick
period, exactly as the explanation predicts.
