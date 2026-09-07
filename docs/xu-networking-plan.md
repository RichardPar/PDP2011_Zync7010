# Bring up XU networking via a PS-side "virtual ESP32" bridge

## Context

The project has twice attempted PDP-11 Ethernet by hand-writing a brand-new
DEUNA command-dispatch FSM and descriptor-ring walker directly in `xu.vhd`
(see memory `xu-ethernet-bridge`). Both attempts were abandoned after a long
chain of RAM-inference/synthesis bugs, an LUT-budget overrun, and finally a
guest-CPU IPL/PSW hang that was never root-caused; the repo is currently
reset back to `b5b2c27` with none of that code present.

Investigating the **unmodified, currently-checked-in** `xu.vhd` found that it
already contains a complete, working, upstream implementation of the DEUNA
that was never used: a *second, embedded* PDP-11 core (`cpu0`/`mmu0`, its own
`kl0` console + `kw0` line clock on a private local unibus) that runs real,
pre-assembled DEUNA microcode (`xubr.mac` for the ENC424J600 variant,
`xubw.mac` for the **ESP32** variant) from the upstream `pdp2011.sytse.net`
distribution. That microcode is what actually implements PCSR0-3,
GETPCBB/GETCMD/WRF/PDMD, and the descriptor rings — i.e. exactly the
protocol the hand-written FSM was trying (and struggling) to reimplement
from SIMH source. It has never been enabled (`have_xu`/`have_xu_esp` are
unset in `zynq_top.vhd`) or wired to real pins.

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

## Architecture

## Status: source-complete, standalone-synth-verified, NOT YET full-built or hardware-tested

Everything below is implemented, not just planned. What's left before it can
actually be tried on the board: a full `./build.sh` (bitstream + PetaLinux,
needed for `CONFIG_TUN` and the new BD slave/UIO node), then a live `dtc`
dump to fix the dtsi interrupt-cell placeholder (see below), then real
guest testing.

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
  needed. **Its `interrupts` cell (`<0 0x22 4>`) is an UNVERIFIED
  PLACEHOLDER** — computed the same way `rh_disk_uio`'s `0x21` was derived
  (concat port index → `IRQ_F2P[index]` → GIC SPI 61+index → DT cell
  SPI-32; this is concat index 5, so 61+5-32=0x22) but not yet checked
  against a live `dtc` dump — same gotcha every AXI bridge in this project
  has hit, not resolved differently this time.

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
    truncation warning) — not yet cross-compiled or run.

## Verification

1. **Done**: standalone out-of-context synth checks (`xuaxi` alone, `xu`
   with all real submodules, `unibus` with all real submodules) — 0 errors
   in all three; see the FPGA-side notes above for LUT/BRAM numbers.
2. **Done**: host-compile check of `pdp11-espd.c` — 0 errors.
3. **Not yet done** (needs real hardware): full `./build.sh` (bitstream +
   PetaLinux); confirm `have_xu=>1` took effect via the M9312 boot ROM
   device table (`174516 - 174510  xu`), as previously confirmed for the
   abandoned attempt.
4. Fix the dtsi interrupt-cell placeholder against a live `dtc` dump
   (see the system-user.dtsi note above for the exact command).
5. Confirm the *embedded* microcode CPU actually boots/runs — its `kl0`
   console is wired to a debug tx pin (`xu_debug_tx` in `unibus.vhd`);
   worth capturing during bring-up.
6. Confirm `pdp11-espd` sees IRQ-driven (not polled) activity from first
   boot.
7. Same end-to-end test as the abandoned attempt used: boot 2.11BSD's
   `disks/211bsd-rp06.img`, `ifconfig de0`, `ping`, with `tcpdump -i tap0`/
   `-i br0` on the PS side. RSX-11M-PLUS DECnet (`NCP SET EXE STA ON` on
   `UNA-0`) is worth a second try once basic IP works, since this is the
   real DEUNA microcode rather than the earlier Phase-A-only hand-written
   dispatch.

## Known open risks (not resolved by standalone synth checks alone)

- The dtsi interrupt-cell placeholder (`0x22`) — see above.
- LUT/timing budget on the xc7z010 with the embedded second CPU/MMU/UART
  now active alongside the RH11/RL11 disk bridges: standalone checks put
  the whole `xu` entity at 2798 LUTs (15.9%) and the whole `unibus` entity
  (which also includes the *outer* cpu/mmu, RL/RH/RK, and every other
  local-bus device) at 14227 LUTs (80.8%) — but that second number isn't
  directly comparable to a real full-chip percentage (no BD-level modules
  like `front_panel.vhd`, no cross-module optimization a real build gets,
  and a couple of pre-existing black-box stubs like `cr11`/`m9312h*`
  weren't resolvable standalone). The real number can only come from an
  actual `./build.sh bitstream` run — not done yet.
