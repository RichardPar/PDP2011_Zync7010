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

   signal clk50_toggle : std_logic := '0';
   signal cpuclk_toggle : std_logic := '0';
   signal led_counter : std_logic_vector(25 downto 0) := (others => '0');

   signal sync50  : std_logic_vector(1 downto 0) := (others => '0');
   signal synccpu : std_logic_vector(1 downto 0) := (others => '0');
   signal syncife : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdevrd : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdevwr : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdmawr : std_logic_vector(1 downto 0) := (others => '0');

   -- latched once per ~84ms period below; still consumed by the dbg_status
   -- GPIO (aclk process further down), so kept even though the NeoPixel panel
   -- now derives its own status lights
   signal neo_seen_devrd : std_logic := '0';
   signal neo_seen_devwr : std_logic := '0';
   signal neo_seen_dmawr : std_logic := '0';

   -- ============ 8x8 WS2812 front panel ("blinkenlights"), on neo_dout ============
   -- 64-LED matrix, all logic in the clk50mhz domain. Logical layout
   -- (row 0 = TOP, col 0 = left):
   --   row 0     : 8 status lights (RUN, cpuclk, ifetch, read, write, I/O, DMA, hb)
   --               DMA light: amber = RL11/RL02 access, magenta = RH11/RP06
   --   rows 1-3  : 22-bit unibus ADDRESS register (amber) - the classic console
   --               shimmer as the CPU runs
   --   rows 4-5  : 16-bit DATA register (green) - last bus write, else last read
   --   rows 6-7  : 16-bit PC (blue) - bus address latched at each ifetch
   -- Only set bits light; keep per-channel values low (~0x18/255) for power.

   constant c_off   : std_logic_vector(23 downto 0) := x"000000";
   constant c_red   : std_logic_vector(23 downto 0) := x"001800";  -- GRB order
   constant c_green : std_logic_vector(23 downto 0) := x"180000";
   constant c_blue  : std_logic_vector(23 downto 0) := x"000018";
   constant c_amber   : std_logic_vector(23 downto 0) := x"101800";
   constant c_cyan    : std_logic_vector(23 downto 0) := x"180018";
   constant c_white   : std_logic_vector(23 downto 0) := x"0c0c0c";
   constant c_magenta : std_logic_vector(23 downto 0) := x"001818";  -- RP06/RH11 DMA (vs RL02's amber)

   type panel_t is array(0 to 63) of std_logic_vector(23 downto 0);

   -- lit bit -> colour, else off
   function bitcol(b : std_logic; c : std_logic_vector(23 downto 0))
      return std_logic_vector is
   begin
      if b = '1' then return c; else return c_off; end if;
   end function;

   -- CJMCU-64 wiring (confirmed via the LED-7 heartbeat reference): ROW-MAJOR
   -- progressive - chain index i = row*8 + col, row 0 = top, col 0 = left, each
   -- row left->right. That's exactly the logical row-major pixel index, so the
   -- chain->logical mapping is the identity. (heartbeat = logical 7 -> chain 7,
   -- the top-right of the status row.)
   function chain_to_logical(i : integer) return integer is
   begin
      return i;
   end function;

   -- colour for the power-up walking-dot test, one per group of 8 chain LEDs
   function grp_row_color(g : integer) return std_logic_vector is
   begin
      case g is
         when 0      => return c_red;
         when 1      => return c_green;
         when 2      => return c_blue;
         when 3      => return c_amber;
         when 4      => return c_cyan;
         when 5      => return c_magenta;
         when 6      => return c_white;
         when others => return x"181800";  -- yellow
      end case;
   end function;

   signal panel : panel_t := (others => c_off);

   -- power-up "walking dot" panel-mapping test: lights one RAW WS2812 chain
   -- index at a time 0->63 (~120ms each), colour changing every 8 so the
   -- physical wiring order can be read off by eye. Runs once at FPGA config,
   -- then hands over to the normal panel.
   constant boot_step_cyc : integer := 6_000_000;  -- ~120ms at 50MHz
   signal boot_active : std_logic := '1';
   signal boot_step   : integer range 0 to 63 := 0;
   signal boot_div    : integer range 0 to boot_step_cyc - 1 := 0;
   signal grp_color   : std_logic_vector(23 downto 0) := c_off;
   signal neo_grb_normal : std_logic_vector(64 * 24 - 1 downto 0);
   signal neo_grb_boot   : std_logic_vector(64 * 24 - 1 downto 0);

   -- clk50mhz-domain capture of the CPU-domain buses/strobes (single-FF capture
   -- of the buses is fine for a display - transient tearing is invisible)
   signal addr_s : std_logic_vector(21 downto 0) := (others => '0');
   signal dati_s : std_logic_vector(15 downto 0) := (others => '0');
   signal dato_s : std_logic_vector(15 downto 0) := (others => '0');
   signal sync50_rst : std_logic_vector(1 downto 0) := (others => '1');
   signal sync50_rd  : std_logic_vector(2 downto 0) := (others => '0'); -- control_dati
   signal sync50_wr  : std_logic_vector(2 downto 0) := (others => '0'); -- control_dato

   -- fast-captured values (updated continuously), snapshotted into the *_disp
   -- registers once per slow display tick so the panel reads calmly instead of
   -- strobing at CPU speed
   signal data_cap : std_logic_vector(15 downto 0) := (others => '0');
   signal pc_cap   : std_logic_vector(15 downto 0) := (others => '0');

   -- displayed (snapshotted) register values
   signal addr_disp : std_logic_vector(21 downto 0) := (others => '0');
   signal data_disp : std_logic_vector(15 downto 0) := (others => '0');
   signal pc_disp   : std_logic_vector(15 downto 0) := (others => '0');
   signal addr24    : std_logic_vector(23 downto 0);

   -- activity accumulators for the status row (reused + new rd/wr)
   signal sync50_cpu : std_logic_vector(2 downto 0) := (others => '0');
   signal sync50_ife : std_logic_vector(2 downto 0) := (others => '0');
   signal sync50_devrd : std_logic_vector(2 downto 0) := (others => '0');
   signal sync50_devwr : std_logic_vector(2 downto 0) := (others => '0');
   signal sync50_dmawr : std_logic_vector(2 downto 0) := (others => '0');
   signal sync50_dmawr_rh : std_logic_vector(2 downto 0) := (others => '0');
   signal neo_activity_cpu : std_logic := '0';
   signal neo_activity_ife : std_logic := '0';
   signal neo_activity_rd  : std_logic := '0';
   signal neo_activity_wr  : std_logic := '0';
   signal neo_activity_devrd : std_logic := '0';
   signal neo_activity_devwr : std_logic := '0';
   signal neo_activity_dmawr : std_logic := '0';
   signal neo_activity_dmawr_rh : std_logic := '0';   -- RH11/RP06 DMA, kept
                                                        -- separate from RL's
                                                        -- above so the panel
                                                        -- can colour-code them
   -- display tick: 0.25s at 50MHz -> panel refreshes 4Hz. The heartbeat is
   -- divided down from that to 1Hz (toggles every 2 ticks) via hb_phase.
   constant disp_div : integer := 12_500_000;
   signal neo_period_cnt : integer range 0 to disp_div - 1 := 0;
   signal neo_period_tick : std_logic;
   signal hb50 : std_logic := '0';   -- heartbeat level, 1Hz blink
   signal hb_phase : std_logic := '0';

   -- status-row colours, latched once per period
   signal st_cpu : std_logic_vector(23 downto 0) := c_off;
   signal st_ife : std_logic_vector(23 downto 0) := c_off;
   signal st_rd  : std_logic_vector(23 downto 0) := c_off;
   signal st_wr  : std_logic_vector(23 downto 0) := c_off;
   signal st_io  : std_logic_vector(23 downto 0) := c_off;
   signal st_dma : std_logic_vector(23 downto 0) := c_off;

   signal neo_grb : std_logic_vector(64 * 24 - 1 downto 0);

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

   -- diagnostics: free-running toggle/counter in each clock's own domain,
   -- brought into aclk via a plain 2-FF synchronizer before use (these are
   -- status bits sampled by software, not control signals - a synchronizer
   -- is sufficient, no need for the stricter dati/cpuclk edge-alignment
   -- ddr_mem.vhd's own read path requires)
   process(clk50mhz)
   begin
      if rising_edge(clk50mhz) then
         clk50_toggle <= not clk50_toggle;
         led_counter  <= led_counter + 1;
      end if;
   end process;

   process(cpuclk)
   begin
      if rising_edge(cpuclk) then
         cpuclk_toggle <= not cpuclk_toggle;
      end if;
   end process;

   process(aclk)
   begin
      if rising_edge(aclk) then
         sync50  <= sync50(0) & clk50_toggle;
         synccpu <= synccpu(0) & cpuclk_toggle;
         syncife <= syncife(0) & ifetch;
         -- neo_seen_* only change once per ~84ms period - a plain 2-FF
         -- sync is more than sufficient, no edge-detect needed here
         syncdevrd <= syncdevrd(0) & neo_seen_devrd;
         syncdevwr <= syncdevwr(0) & neo_seen_devwr;
         syncdmawr <= syncdmawr(0) & neo_seen_dmawr;
      end if;
   end process;

   dbg_status(0) <= sync50(1);
   dbg_status(1) <= synccpu(1);
   dbg_status(2) <= syncife(1);
   dbg_status(3) <= aresetn;  -- already aclk-synchronous (proc_sys_reset0 output)
   dbg_status(4) <= syncdevrd(1);
   dbg_status(5) <= syncdevwr(1);
   dbg_status(6) <= syncdmawr(1);

   led_n <= not led_counter(25);  -- ~50MHz/2^26 = ~0.75Hz blink if clk50mhz is alive

   -- 8x8 front panel: continuously capture the CPU buses/strobes, but only
   -- SNAPSHOT them onto the display once per tick (0.25s) so the panel reads
   -- calmly (4Hz) instead of strobing at CPU speed; heartbeat blinks at 1Hz.
   neo_period_tick <= '1' when neo_period_cnt = disp_div - 1 else '0';

   process(clk50mhz)
   begin
      if rising_edge(clk50mhz) then
         if neo_period_cnt = disp_div - 1 then
            neo_period_cnt <= 0;
         else
            neo_period_cnt <= neo_period_cnt + 1;
         end if;

         -- capture buses (single-FF; display, so any tearing is invisible)
         addr_s <= addr;
         dati_s <= dati;
         dato_s <= dato;

         -- sync shifts for edge detection
         sync50_cpu   <= sync50_cpu(1 downto 0)   & cpuclk_toggle;
         sync50_ife   <= sync50_ife(1 downto 0)   & ifetch;
         sync50_rd    <= sync50_rd(1 downto 0)    & control_dati;
         sync50_wr    <= sync50_wr(1 downto 0)    & control_dato;
         sync50_devrd <= sync50_devrd(1 downto 0) & dbg_dev_rd;
         sync50_devwr <= sync50_devwr(1 downto 0) & dbg_dev_wr;
         sync50_dmawr <= sync50_dmawr(1 downto 0) & dbg_dma_wr;
         sync50_dmawr_rh <= sync50_dmawr_rh(1 downto 0) & dbg_dma_rh_wr;
         sync50_rst   <= sync50_rst(0) & cpureset;

         -- fast capture (continuous): last bus DATA (write else read), and the
         -- PC = bus address latched at each ifetch rising edge
         if sync50_wr(1) = '1' then
            data_cap <= dato_s;
         elsif sync50_rd(1) = '1' then
            data_cap <= dati_s;
         end if;
         if sync50_ife(2) = '0' and sync50_ife(1) = '1' then
            pc_cap <= addr_s(15 downto 0);
         end if;

         -- accumulate sticky activity for the status row
         if sync50_cpu(2)   /= sync50_cpu(1)   then neo_activity_cpu   <= '1'; end if;
         if sync50_ife(2)   /= sync50_ife(1)   then neo_activity_ife   <= '1'; end if;
         if sync50_rd(2)    /= sync50_rd(1)    then neo_activity_rd    <= '1'; end if;
         if sync50_wr(2)    /= sync50_wr(1)    then neo_activity_wr    <= '1'; end if;
         if sync50_devrd(2) /= sync50_devrd(1) then neo_activity_devrd <= '1'; end if;
         if sync50_devwr(2) /= sync50_devwr(1) then neo_activity_devwr <= '1'; end if;
         if sync50_dmawr(2) /= sync50_dmawr(1) then neo_activity_dmawr <= '1'; end if;
         if sync50_dmawr_rh(2) /= sync50_dmawr_rh(1) then neo_activity_dmawr_rh <= '1'; end if;

         if neo_period_tick = '1' then
            -- snapshot the register displays once per slow tick (calm refresh)
            addr_disp <= addr_s;
            data_disp <= data_cap;
            pc_disp   <= pc_cap;

            if neo_activity_cpu = '1' then st_cpu <= c_green; else st_cpu <= c_red; end if;
            if neo_activity_ife = '1' then st_ife <= c_blue;  else st_ife <= c_off; end if;
            if neo_activity_rd  = '1' then st_rd  <= c_green; else st_rd  <= c_off; end if;
            if neo_activity_wr  = '1' then st_wr  <= c_red;   else st_wr  <= c_off; end if;
            if (neo_activity_devrd = '1') or (neo_activity_devwr = '1') then
               st_io <= c_cyan;
            else
               st_io <= c_off;
            end if;
            -- disk DMA light: colour-coded by controller so RP06 (RH11)
            -- accesses read visibly different from RL02 (RL11) ones on the
            -- panel, instead of just one generic "disk" colour. If both
            -- happened inside the same ~250ms display period, RH wins the
            -- colour (arbitrary but deterministic - a real simultaneous
            -- RL+RH transfer is not possible on this core, RH being the
            -- newer/rarer path is the more useful one to surface).
            if neo_activity_dmawr_rh = '1' then
               st_dma <= c_magenta;
            elsif neo_activity_dmawr = '1' then
               st_dma <= c_amber;
            else
               st_dma <= c_off;
            end if;

            -- keep the dbg_status GPIO fed (either controller counts as "DMA")
            neo_seen_devrd <= neo_activity_devrd;
            neo_seen_devwr <= neo_activity_devwr;
            neo_seen_dmawr <= neo_activity_dmawr or neo_activity_dmawr_rh;

            neo_activity_cpu   <= '0';
            neo_activity_ife   <= '0';
            neo_activity_rd    <= '0';
            neo_activity_wr    <= '0';
            neo_activity_devrd <= '0';
            neo_activity_devwr <= '0';
            neo_activity_dmawr <= '0';
            neo_activity_dmawr_rh <= '0';

            -- heartbeat: toggle every 2nd tick (0.5s) -> 1Hz blink
            if hb_phase = '1' then
               hb50 <= not hb50;
               hb_phase <= '0';
            else
               hb_phase <= '1';
            end if;
         end if;
      end if;
   end process;

   -- ---- logical panel (row 0 = top, col 0 = left) ----
   addr24 <= "00" & addr_disp;

   -- row 0: status lights
   panel(0) <= c_green when sync50_rst(1) = '0' else c_red;  -- RUN vs in-reset
   panel(1) <= st_cpu;                                       -- cpuclk alive
   panel(2) <= st_ife;                                       -- ifetch
   panel(3) <= st_rd;                                        -- memory read
   panel(4) <= st_wr;                                        -- memory write
   panel(5) <= st_io;                                        -- I/O-page access
   panel(6) <= st_dma;                                       -- DMA / disk
   panel(7) <= c_white when hb50 = '1' else c_off;           -- panel heartbeat

   -- rows 1-3 address (amber), 4-5 data (green), 6-7 pc (blue); col0 = MSB
   gen_panel: for c in 0 to 7 generate
      panel(8  + c) <= bitcol(addr24(23 - c), c_amber);
      panel(16 + c) <= bitcol(addr24(15 - c), c_amber);
      panel(24 + c) <= bitcol(addr24(7  - c), c_amber);
      panel(32 + c) <= bitcol(data_disp(15 - c), c_green);
      panel(40 + c) <= bitcol(data_disp(7  - c), c_green);
      panel(48 + c) <= bitcol(pc_disp(15 - c), c_blue);
      panel(56 + c) <= bitcol(pc_disp(7  - c), c_blue);
   end generate;

   -- power-up walking-dot counter (clk50mhz domain), runs once then clears
   process(clk50mhz)
   begin
      if rising_edge(clk50mhz) then
         if boot_active = '1' then
            if boot_div = boot_step_cyc - 1 then
               boot_div <= 0;
               if boot_step = 63 then
                  boot_active <= '0';
               else
                  boot_step <= boot_step + 1;
               end if;
            else
               boot_div <= boot_div + 1;
            end if;
         end if;
      end if;
   end process;

   grp_color <= grp_row_color(boot_step / 8);

   -- normal frame: logical panel -> physical chain (serpentine).
   -- boot frame: one RAW chain LED lit at boot_step, group-coloured.
   gen_chain: for i in 0 to 63 generate
      neo_grb_normal((i + 1) * 24 - 1 downto i * 24) <= panel(chain_to_logical(i));
      neo_grb_boot((i + 1) * 24 - 1 downto i * 24) <=
         grp_color when i = boot_step else c_off;
   end generate;

   neo_grb <= neo_grb_boot when boot_active = '1' else neo_grb_normal;

   -- Timing slowed for a long data run (degraded edges): ~1.5us bit period
   -- (was ~1.26us) with longer low/settle times. High times stay the 0/1
   -- discriminators and within the WS2812B tolerance (T0H 0.44us, T1H 0.86us).
   neopixel : entity work.neopixel_driver
      generic map(
         num_leds     => 64,
         t0h_cycles   => 22,   -- 0.44us  '0' high
         t0l_cycles   => 53,   -- 1.06us  '0' low  (period 1.50us)
         t1h_cycles   => 43,   -- 0.86us  '1' high
         t1l_cycles   => 32,   -- 0.64us  '1' low  (period 1.50us)
         reset_cycles => 5000  -- 100us latch gap
      )
      port map(
         clk      => clk50mhz,
         grb_data => neo_grb,
         dout     => neo_dout
      );

end implementation;
