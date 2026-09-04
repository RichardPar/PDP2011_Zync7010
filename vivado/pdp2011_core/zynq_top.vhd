--
-- zynq_top.vhd - PDP-11/70 on the Zynq-7010, DDR3-backed main memory shared
-- with PetaLinux, physical console UART, physical SD/SPI RL11 disk.
-- modelcode was 44 through 2026-09-03; switched to 70 on 2026-09-04 to match
-- the 2.11BSD kernel's own PDP11=70 assumption (its VERNON-derived config
-- never actually matched the core's real identity before this). Also flips
-- have_rh70 on in rh11.vhd/unibus.vhd (real RH70 DMA/bus-master register
-- behavior, not just the model-code readout) - re-verify the RP06 boot path
-- (see README "Auto-boot ROM") after this change.
--
-- RH11/RP06 moved off the physical SD/SPI card onto its own AXI file-backed
-- bridge (rh_disk_s_axi_* below) on 2026-09-04, mirroring the RL11's
-- disk_s_axi_* bridge - see [[file-backed-rl-disk]] in memory. The physical
-- SD pins (sd_cs/mosi/sclk/miso) are now idle/unused (see their port comment
-- below); pdp11-diskd serves both drives from PS image files.
--
-- Refactored 2026-09-04: the NeoPixel front panel and the bring-up
-- diagnostics GPIO used to be inline processes/functions in this file's own
-- architecture; they're now their own entities, front_panel.vhd and
-- bringup_diag.vhd, instantiated below (panel0/diag0) - logic unchanged,
-- just moved. This file is now just the PDP-11 core + DDR bridge + the two
-- module instances + a handful of trivial passthroughs.
--
-- Ported from fpga_project_1's top_c8.vhd (Tang Nano 9K, proven on real
-- hardware: 11/44 + 2 MB HyperRAM + RL11-on-SD + boots RT-11). Differences
-- from top_c8.vhd:
--   * Main memory is ddr_mem.vhd (PS DDR3 via S_AXI_HP0) instead of
--     psram_bridge.vhd (in-package HyperRAM) - see that file's header.
--   * addr_match is tied '1' always: the unibus 22-bit address bus is
--     exactly 4 MB, the pdp2011 core's own physical ceiling, so there is no
--     need to gate on a high address bit the way top_c8.vhd's 2 MB HyperRAM
--     config did (addr(21)='0').
--   * Only kl0 (the primary console) is wired to a physical UART this round
--     - have_kl11=>1. top_c8.vhd's kl1 second-console pattern still applies
--     if a second physical console is wanted later (bump have_kl11, wire
--     tx1/rx1, add a pin constraint).
--   * No on-package HyperRAM / PLL IP - clocking comes from the Zynq PS
--     (FCLK0 for the AXI/ddr_mem FSM, FCLK1 for clk50mhz/KL11+sdspi baud),
--     configured at the block-design level, not in this file.
--
-- Physical pins (Bajie Zynq-7010 board, user-supplied, unverified against
-- any vendor pinout doc - see README):
--   console tx = P20, console rx = T19
--   SD (direct SPI): MISO=N20, CLK=R19, MOSI=T20, CS=V20
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.pdp2011.all;

entity zynq_top is
   port(
      aclk      : in  std_logic;                      -- FCLK0, e.g. 100 MHz - AXI/ddr_mem FSM clock
      aresetn   : in  std_logic;                       -- active-low, from PS reset

      clk50mhz  : in  std_logic;                       -- FCLK1, ~50 MHz - KL11 baud + sdspi bit clock

      -- physical PDP-11 console UART (KL11 kl0, 9600 - Serial0, stays on pins)
      uart_tx   : out std_logic;
      uart_rx   : in  std_logic;

      -- three extra PDP-11 consoles (KL11 kl1/kl2/kl3 = RT-11 TT1:/TT2:/TT3:),
      -- NOT brought to physical pins - each wired back-to-back with an
      -- axi_uartlite in the fabric (see 02_create_bd.tcl) so Linux reaches them
      -- as /dev/ttyUL*. tx is core->uartlite, rx is uartlite->core; the link is
      -- a real async serial line so each baud must match its uartlite:
      -- ser1 = 19200, ser2 = 9600, ser3 = 9600.
      ser1_tx   : out std_logic;
      ser1_rx   : in  std_logic;
      ser2_tx   : out std_logic;
      ser2_rx   : in  std_logic;
      ser3_tx   : out std_logic;
      ser3_rx   : in  std_logic;

      -- bring-up diagnostics (2026-08 - console produced no output on
      -- first real hardware test; physical link independently confirmed
      -- good via wozmon on these same pins in an earlier project, so the
      -- prime suspect is clk50mhz/FCLK1, new and unproven in this design -
      -- these let it be checked without another blind rebuild cycle)
      led_n      : out std_logic;                     -- H17, active-low, ~0.75Hz blink driven by clk50mhz
      -- devmem-readable: [0]=clk50mhz alive [1]=cpuclk alive [2]=ifetch
      -- [3]=aresetn [4]=dbg_dev_rd(I/O-page read) [5]=dbg_dev_wr(I/O-page
      -- write) [6]=dbg_dma_wr(RL11 OR RH11 DMA write, ORed) - the last three
      -- tap unibus.vhd's own pre-existing debug ports (same ones the earlier project's
      -- wozmon used), added 2026-08 to see whether the CPU reaches ANY
      -- memory reference at all (ifetch specifically never toggles - is it
      -- stuck before even that, e.g. looping in NPR/DMA arbitration?)
      dbg_status : out std_logic_vector(6 downto 0);

      -- 8x8 WS2812 ("NeoPixel") front panel - a PDP-11 "blinkenlights" console.
      -- Single data wire; all drive logic is in the architecture. Logical
      -- layout (row 0 = top): row 0 = 8 status lights (RUN, cpuclk, ifetch,
      -- mem-read, mem-write, I/O-page, DMA, panel-heartbeat) - DMA is
      -- colour-coded, amber for RL11/RL02 vs magenta for RH11/RP06; rows 1-3 = the
      -- 22-bit unibus ADDRESS register (amber, flickers as the CPU runs);
      -- rows 4-5 = 16-bit DATA register (green); rows 6-7 = the PC (blue, the
      -- bus address latched at each ifetch). Replaced the earlier 7-LED
      -- bring-up ring (rainbow test + cpuclk/ifetch/reset lights) once the
      -- port was proven. Wiring is for a CJMCU-64 (chain runs down columns,
      -- left->right, top-left start) - see chain_to_logical in the body.
      neo_dout   : out std_logic;                      -- T11

      -- physical microSD, SPI mode. UNUSED as of the RH disk bridge below:
      -- both RL11 and RH11/RP06 are now served from PS image files over their
      -- own AXI-Lite bridges, so nothing drives real SPI on these pins any
      -- more. Kept in the port list (idle: CS/MOSI high, SCLK low, MISO
      -- ignored) rather than ripped out, so the BD/constraints don't need to
      -- change - free for a future physical-disk use if ever wanted.
      sd_cs     : out std_logic;
      sd_mosi   : out std_logic;
      sd_sclk   : out std_logic;
      sd_miso   : in  std_logic;

      -- RL disk AXI-Lite slave (served by pdp11-diskd) + interrupt, to the BD
      disk_s_axi_aclk    : in  std_logic;
      disk_s_axi_aresetn : in  std_logic;
      disk_s_axi_awaddr  : in  std_logic_vector(11 downto 0);
      disk_s_axi_awvalid : in  std_logic;
      disk_s_axi_awready : out std_logic;
      disk_s_axi_wdata   : in  std_logic_vector(31 downto 0);
      disk_s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      disk_s_axi_wvalid  : in  std_logic;
      disk_s_axi_wready  : out std_logic;
      disk_s_axi_bresp   : out std_logic_vector(1 downto 0);
      disk_s_axi_bvalid  : out std_logic;
      disk_s_axi_bready  : in  std_logic;
      disk_s_axi_araddr  : in  std_logic_vector(11 downto 0);
      disk_s_axi_arvalid : in  std_logic;
      disk_s_axi_arready : out std_logic;
      disk_s_axi_rdata   : out std_logic_vector(31 downto 0);
      disk_s_axi_rresp   : out std_logic_vector(1 downto 0);
      disk_s_axi_rvalid  : out std_logic;
      disk_s_axi_rready  : in  std_logic;
      disk_irq           : out std_logic;

      -- RH disk (RP06) AXI-Lite slave (served by pdp11-diskd) + interrupt, to
      -- the BD - same bridge pattern as the RL disk_s_axi_* above
      rh_disk_s_axi_aclk    : in  std_logic;
      rh_disk_s_axi_aresetn : in  std_logic;
      rh_disk_s_axi_awaddr  : in  std_logic_vector(11 downto 0);
      rh_disk_s_axi_awvalid : in  std_logic;
      rh_disk_s_axi_awready : out std_logic;
      rh_disk_s_axi_wdata   : in  std_logic_vector(31 downto 0);
      rh_disk_s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      rh_disk_s_axi_wvalid  : in  std_logic;
      rh_disk_s_axi_wready  : out std_logic;
      rh_disk_s_axi_bresp   : out std_logic_vector(1 downto 0);
      rh_disk_s_axi_bvalid  : out std_logic;
      rh_disk_s_axi_bready  : in  std_logic;
      rh_disk_s_axi_araddr  : in  std_logic_vector(11 downto 0);
      rh_disk_s_axi_arvalid : in  std_logic;
      rh_disk_s_axi_arready : out std_logic;
      rh_disk_s_axi_rdata   : out std_logic_vector(31 downto 0);
      rh_disk_s_axi_rresp   : out std_logic_vector(1 downto 0);
      rh_disk_s_axi_rvalid  : out std_logic;
      rh_disk_s_axi_rready  : in  std_logic;
      rh_disk_irq           : out std_logic;

      -- AXI4 master to PS DDR3 (through an AXI4->AXI3 protocol converter to
      -- S_AXI_HP0 at the BD level)
      m_axi_awaddr  : out std_logic_vector(31 downto 0);
      m_axi_awvalid : out std_logic;
      m_axi_awready : in  std_logic;
      m_axi_awlen   : out std_logic_vector(7 downto 0);
      m_axi_awsize  : out std_logic_vector(2 downto 0);
      m_axi_awburst : out std_logic_vector(1 downto 0);
      m_axi_awprot  : out std_logic_vector(2 downto 0);
      m_axi_awcache : out std_logic_vector(3 downto 0);

      m_axi_wdata   : out std_logic_vector(31 downto 0);
      m_axi_wstrb   : out std_logic_vector(3 downto 0);
      m_axi_wvalid  : out std_logic;
      m_axi_wready  : in  std_logic;
      m_axi_wlast   : out std_logic;

      m_axi_bvalid  : in  std_logic;
      m_axi_bready  : out std_logic;
      m_axi_bresp   : in  std_logic_vector(1 downto 0);

      m_axi_araddr  : out std_logic_vector(31 downto 0);
      m_axi_arvalid : out std_logic;
      m_axi_arready : in  std_logic;
      m_axi_arlen   : out std_logic_vector(7 downto 0);
      m_axi_arsize  : out std_logic_vector(2 downto 0);
      m_axi_arburst : out std_logic_vector(1 downto 0);
      m_axi_arprot  : out std_logic_vector(2 downto 0);
      m_axi_arcache : out std_logic_vector(3 downto 0);

      m_axi_rdata   : in  std_logic_vector(31 downto 0);
      m_axi_rvalid  : in  std_logic;
      m_axi_rready  : out std_logic;
      m_axi_rresp   : in  std_logic_vector(1 downto 0);
      m_axi_rlast   : in  std_logic
   );
end zynq_top;

architecture implementation of zynq_top is

   signal addr          : std_logic_vector(21 downto 0);
   signal dati          : std_logic_vector(15 downto 0);
   signal dato          : std_logic_vector(15 downto 0);
   signal control_dati  : std_logic;
   signal control_dato  : std_logic;
   signal control_datob : std_logic;
   signal addr_match    : std_logic;

   signal ifetch : std_logic;
   signal txtx   : std_logic;
   signal rxrx   : std_logic;

   signal dbg_dev_rd : std_logic;
   signal dbg_dev_wr : std_logic;
   signal dbg_dma_wr : std_logic;
   signal dbg_dma_rh_wr : std_logic;

   signal cpuclk   : std_logic;
   signal cpureset : std_logic;

   signal brg_ready   : std_logic;
   signal brg_attempt : std_logic;

   -- front_panel.vhd's activity bits, fed into bringup_diag.vhd's dbg_status
   -- GPIO - see both files' headers
   signal seen_devrd : std_logic;
   signal seen_devwr : std_logic;
   signal seen_dmawr : std_logic;

begin

   -- unibus's 22-bit address bus is exactly 4 MB, the whole physical space -
   -- always RAM- or I/O-page-decoded internally, nothing to gate here
   addr_match <= '1';

   pdp11 : entity work.unibus
      port map(
         modelcode => 70,
         have_fp   => 1,   -- FP11 floating point enabled (1 = force on; the
                           -- 11/44 supports it by default). Was forced off on
                           -- the earlier build for space; the 7010 has room
                           -- (~34% LUTs).
         have_eis  => 2,
         have_fis  => 0,

         have_kl11     => 4,
         tx0           => txtx,
         rx0           => rxrx,
         kl0_bps       => 9600,
         kl0_force7bit => 1,

         -- Serial1: kl1 @ 776500/vec300 (TT1:), 19200, 8-bit clean
         tx1           => ser1_tx,
         rx1           => ser1_rx,
         kl1_bps       => 19200,
         kl1_force7bit => 0,

         -- Serial2: kl2 @ 776510/vec310 (TT2:), 9600, 8-bit clean
         tx2           => ser2_tx,
         rx2           => ser2_rx,
         kl2_bps       => 9600,
         kl2_force7bit => 0,

         -- Serial3: kl3 @ 776520/vec320 (TT3:), 9600, 8-bit clean
         tx3           => ser3_tx,
         rx3           => ser3_rx,
         kl3_bps       => 9600,
         kl3_force7bit => 0,

         have_rl         => 1,
         -- RL11 is backed by the AXI file-backed disk (rl_disk_s_axi_* below),
         -- so its direct-SPI SD port is unused - left open here.

         -- RP06 on the RH11 (@ 776700 / vec 254, RT-11 "DB:"), now backed by
         -- its own AXI file-backed disk (rh_disk_s_axi_* below) instead of
         -- the physical SD/SPI card that proved it out - rh_sdcard_* is
         -- unused, left open here (mirrors rl_sdcard_* above).
         have_rh         => 1,
         rh_type         => 6,   -- RP06 (815 cyl x 19 head x 22 sector)

         -- RL disk backed by a PS file via pdp11-diskd (AXI-Lite + irq)
         rl_disk_s_axi_aclk    => disk_s_axi_aclk,
         rl_disk_s_axi_aresetn => disk_s_axi_aresetn,
         rl_disk_s_axi_awaddr  => disk_s_axi_awaddr,
         rl_disk_s_axi_awvalid => disk_s_axi_awvalid,
         rl_disk_s_axi_awready => disk_s_axi_awready,
         rl_disk_s_axi_wdata   => disk_s_axi_wdata,
         rl_disk_s_axi_wstrb   => disk_s_axi_wstrb,
         rl_disk_s_axi_wvalid  => disk_s_axi_wvalid,
         rl_disk_s_axi_wready  => disk_s_axi_wready,
         rl_disk_s_axi_bresp   => disk_s_axi_bresp,
         rl_disk_s_axi_bvalid  => disk_s_axi_bvalid,
         rl_disk_s_axi_bready  => disk_s_axi_bready,
         rl_disk_s_axi_araddr  => disk_s_axi_araddr,
         rl_disk_s_axi_arvalid => disk_s_axi_arvalid,
         rl_disk_s_axi_arready => disk_s_axi_arready,
         rl_disk_s_axi_rdata   => disk_s_axi_rdata,
         rl_disk_s_axi_rresp   => disk_s_axi_rresp,
         rl_disk_s_axi_rvalid  => disk_s_axi_rvalid,
         rl_disk_s_axi_rready  => disk_s_axi_rready,
         rl_disk_irq           => disk_irq,

         -- RP06 disk backed by a PS file via pdp11-diskd (AXI-Lite + irq)
         rh_disk_s_axi_aclk    => rh_disk_s_axi_aclk,
         rh_disk_s_axi_aresetn => rh_disk_s_axi_aresetn,
         rh_disk_s_axi_awaddr  => rh_disk_s_axi_awaddr,
         rh_disk_s_axi_awvalid => rh_disk_s_axi_awvalid,
         rh_disk_s_axi_awready => rh_disk_s_axi_awready,
         rh_disk_s_axi_wdata   => rh_disk_s_axi_wdata,
         rh_disk_s_axi_wstrb   => rh_disk_s_axi_wstrb,
         rh_disk_s_axi_wvalid  => rh_disk_s_axi_wvalid,
         rh_disk_s_axi_wready  => rh_disk_s_axi_wready,
         rh_disk_s_axi_bresp   => rh_disk_s_axi_bresp,
         rh_disk_s_axi_bvalid  => rh_disk_s_axi_bvalid,
         rh_disk_s_axi_bready  => rh_disk_s_axi_bready,
         rh_disk_s_axi_araddr  => rh_disk_s_axi_araddr,
         rh_disk_s_axi_arvalid => rh_disk_s_axi_arvalid,
         rh_disk_s_axi_arready => rh_disk_s_axi_arready,
         rh_disk_s_axi_rdata   => rh_disk_s_axi_rdata,
         rh_disk_s_axi_rresp   => rh_disk_s_axi_rresp,
         rh_disk_s_axi_rvalid  => rh_disk_s_axi_rvalid,
         rh_disk_s_axi_rready  => rh_disk_s_axi_rready,
         rh_disk_irq           => rh_disk_irq,

         bootrom => boot_pdp2011,  -- auto-boot: tries rk, rl, rp in that order.
                                -- Was a known bug up to 2026-08-14: if RL0 wasn't
                                -- loaded, it just spun re-reading the unloaded
                                -- unit instead of moving on. Fixed 2026-09-03 by
                                -- patching m9312h-pdp2011.mac/.vhd so a real read
                                -- error falls through to the next device
                                -- (rk->rl->rp->rk...) instead of retrying forever.
                                -- Use boot_odt instead to drop into the '@'
                                -- console for hand-depositing a bootstrap.

         addr          => addr,
         dati          => dati,
         dato          => dato,
         control_dati  => control_dati,
         control_dato  => control_dato,
         control_datob => control_datob,
         addr_match    => addr_match,

         ifetch => ifetch,

         dbg_dev_rd => dbg_dev_rd,
         dbg_dev_wr => dbg_dev_wr,
         dbg_dma_wr => dbg_dma_wr,
         dbg_dma_rh_wr => dbg_dma_rh_wr,

         clk      => cpuclk,
         clk50mhz => clk50mhz,
         reset    => cpureset
      );

   mem : entity work.ddr_mem
      generic map(
         ddr_base => x"1F800000"
      )
      port map(
         addr          => addr,
         dati          => dati,
         dato          => dato,
         control_dati  => control_dati,
         control_dato  => control_dato,
         control_datob => control_datob,
         addr_match    => addr_match,

         cpureset => cpureset,
         cpuclk   => cpuclk,

         o_ready   => brg_ready,
         o_attempt => brg_attempt,

         aclk    => aclk,
         aresetn => aresetn,

         m_axi_awaddr  => m_axi_awaddr,
         m_axi_awvalid => m_axi_awvalid,
         m_axi_awready => m_axi_awready,
         m_axi_awlen   => m_axi_awlen,
         m_axi_awsize  => m_axi_awsize,
         m_axi_awburst => m_axi_awburst,
         m_axi_awprot  => m_axi_awprot,
         m_axi_awcache => m_axi_awcache,

         m_axi_wdata  => m_axi_wdata,
         m_axi_wstrb  => m_axi_wstrb,
         m_axi_wvalid => m_axi_wvalid,
         m_axi_wready => m_axi_wready,
         m_axi_wlast  => m_axi_wlast,

         m_axi_bvalid => m_axi_bvalid,
         m_axi_bready => m_axi_bready,
         m_axi_bresp  => m_axi_bresp,

         m_axi_araddr  => m_axi_araddr,
         m_axi_arvalid => m_axi_arvalid,
         m_axi_arready => m_axi_arready,
         m_axi_arlen   => m_axi_arlen,
         m_axi_arsize  => m_axi_arsize,
         m_axi_arburst => m_axi_arburst,
         m_axi_arprot  => m_axi_arprot,
         m_axi_arcache => m_axi_arcache,

         m_axi_rdata  => m_axi_rdata,
         m_axi_rvalid => m_axi_rvalid,
         m_axi_rready => m_axi_rready,
         m_axi_rresp  => m_axi_rresp,
         m_axi_rlast  => m_axi_rlast
      );

   uart_tx <= txtx;
   rxrx    <= uart_rx;

   -- physical SD/SPI pins: idle. Neither RL11 nor RH11 drives real SPI any
   -- more (both moved to their own AXI file-backed disk bridge) - see the
   -- port comment above. sd_miso is simply left unread.
   sd_cs   <= '1';
   sd_mosi <= '1';
   sd_sclk <= '0';

   -- 8x8 WS2812 front panel - see front_panel.vhd
   panel0 : entity work.front_panel
      port map(
         clk50mhz      => clk50mhz,
         cpuclk        => cpuclk,
         cpureset      => cpureset,
         ifetch        => ifetch,
         addr          => addr,
         dati          => dati,
         dato          => dato,
         control_dati  => control_dati,
         control_dato  => control_dato,
         dbg_dev_rd    => dbg_dev_rd,
         dbg_dev_wr    => dbg_dev_wr,
         dbg_dma_wr    => dbg_dma_wr,
         dbg_dma_rh_wr => dbg_dma_rh_wr,

         neo_dout   => neo_dout,

         seen_devrd => seen_devrd,
         seen_devwr => seen_devwr,
         seen_dmawr => seen_dmawr
      );

   -- bring-up diagnostics GPIO + LED - see bringup_diag.vhd
   diag0 : entity work.bringup_diag
      port map(
         clk50mhz => clk50mhz,
         cpuclk   => cpuclk,
         aclk     => aclk,
         aresetn  => aresetn,
         ifetch   => ifetch,

         seen_devrd => seen_devrd,
         seen_devwr => seen_devwr,
         seen_dmawr => seen_dmawr,

         led_n      => led_n,
         dbg_status => dbg_status
      );

end implementation;
