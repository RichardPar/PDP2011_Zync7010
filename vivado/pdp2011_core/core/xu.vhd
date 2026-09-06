
--
-- Copyright (c) 2008-2023 Sytse van Slooten
--
-- Permission is hereby granted to any person obtaining a copy of these VHDL source files and
-- other language source files and associated documentation files ("the materials") to use
-- these materials solely for personal, non-commercial purposes.
-- You are also granted permission to make changes to the materials, on the condition that this
-- copyright notice is retained unchanged.
--
-- The materials are distributed in the hope that they will be useful, but WITHOUT ANY WARRANTY;
-- without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--

-- $Revision$

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.pdp2011.all;

entity xu is
   port(
-- standard bus master interface
      base_addr : in std_logic_vector(17 downto 0);
      ivec : in std_logic_vector(8 downto 0);

      br : out std_logic;
      bg : in std_logic;
      int_vector : out std_logic_vector(8 downto 0);

      npr : out std_logic;
      npg : in std_logic;

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      bus_master_addr : out std_logic_vector(17 downto 0);
      bus_master_dati : in std_logic_vector(15 downto 0) := (others => '0');
      bus_master_dato : out std_logic_vector(15 downto 0);
      bus_master_control_dati : out std_logic;
      bus_master_control_dato : out std_logic;
      bus_master_nxm : in std_logic := '0';

-- esp32 or enc424j600 frontend interface
      xu_cs : out std_logic;
      xu_mosi : out std_logic;
      xu_sclk : out std_logic;
      xu_miso : in std_logic;
      xu_srdy : in std_logic;

-- flags
      have_xu : in integer range 0 to 1 := 0;
      have_xu_debug : in integer range 0 to 1 := 1;
      have_xu_enc : in integer range 0 to 1 := 0;
      have_xu_esp : in integer range 0 to 1 := 0;

-- DEUNA <-> Linux frame bridge (xuring.vhd, instantiated below) - AXI-Lite
-- + irq to the PS, serviced by pdp11-netd. See xuring.vhd's header for the
-- register map and [[xu-ethernet-bridge]] memory for why this replaced an
-- earlier toggle-handshake design that caused a real board hang.
      ring_s_axi_aclk    : in  std_logic;
      ring_s_axi_aresetn : in  std_logic;
      ring_s_axi_awaddr  : in  std_logic_vector(16 downto 0);
      ring_s_axi_awvalid : in  std_logic;
      ring_s_axi_awready : out std_logic;
      ring_s_axi_wdata   : in  std_logic_vector(31 downto 0);
      ring_s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      ring_s_axi_wvalid  : in  std_logic;
      ring_s_axi_wready  : out std_logic;
      ring_s_axi_bresp   : out std_logic_vector(1 downto 0);
      ring_s_axi_bvalid  : out std_logic;
      ring_s_axi_bready  : in  std_logic;
      ring_s_axi_araddr  : in  std_logic_vector(16 downto 0);
      ring_s_axi_arvalid : in  std_logic;
      ring_s_axi_arready : out std_logic;
      ring_s_axi_rdata   : out std_logic_vector(31 downto 0);
      ring_s_axi_rresp   : out std_logic_vector(1 downto 0);
      ring_s_axi_rvalid  : out std_logic;
      ring_s_axi_rready  : in  std_logic;
      ring_irq           : out std_logic;

-- debug & blinkenlights
      tx : out std_logic;
      ifetch : out std_logic;
      iwait : out std_logic;

-- BR5 arbitration diagnostics (unibus.vhd instantiates xu directly, so
-- these come straight from its own br5_state arbiter signals - added
-- 2026-09-06 to test whether rh0 (RH11/RP06, have_rh=1 but no guest
-- driver ever touches it) is starving xu0's BR5 interrupt request; see
-- [[xu-ethernet-bridge]]).
      diag_rh0_br : in std_logic := '0';
      diag_br5_state : in std_logic_vector(2 downto 0) := "000";
      diag_cpu_psw_pri : in std_logic_vector(2 downto 0) := "000";
      diag_cpu_bg5 : in std_logic := '0';
      diag_cpu_addr_v : in std_logic_vector(15 downto 0) := (others => '0');
      diag_cpu_iwait : in std_logic := '0';
      diag_cpu_ifetch : in std_logic := '0';

-- clock & reset
      cpuclk : in std_logic;
      nclk : in std_logic;
      clk50mhz : in std_logic;
      reset : in std_logic
   );
end xu;

architecture implementation of xu is

component kw11l is
   port(
      base_addr : in std_logic_vector(17 downto 0);
      ivec : in std_logic_vector(8 downto 0);

      br : out std_logic;
      bg : in std_logic;
      int_vector : out std_logic_vector(8 downto 0);

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      have_kw11l : in integer range 0 to 1;
      kw11l_hz : in integer range 50 to 800;

      reset : in std_logic;
      clk50mhz : in std_logic;
      clk : in std_logic
   );
end component;

component kl11 is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      br : out std_logic;
      bg : in std_logic;
      int_vector : out std_logic_vector(8 downto 0);

      ivec : in std_logic_vector(8 downto 0);
      ovec : in std_logic_vector(8 downto 0);

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      tx : out std_logic;
      rx : in std_logic;
      rts : out std_logic;
      cts : in std_logic;

      have_kl11 : in integer range 0 to 1;
      have_kl11_force7bit : in integer range 0 to 1;
      have_kl11_rtscts : in integer range 0 to 1;
      have_kl11_bps : in integer range 1200 to 230400;

      reset : in std_logic;

      clk50mhz : in std_logic;

      clk : in std_logic
   );
end component;

component xubr is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      have_xu_enc : in integer range 0 to 1 := 0;

      reset : in std_logic;
      clk : in std_logic
   );
end component;

component xubw is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      have_xu_esp : in integer range 0 to 1 := 0;

      reset : in std_logic;
      clk : in std_logic
   );
end component;

component xubl is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      npr : out std_logic;
      npg : in std_logic;

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      bus_master_addr : out std_logic_vector(17 downto 0);
      bus_master_dati : in std_logic_vector(15 downto 0);
      bus_master_dato : out std_logic_vector(15 downto 0);
      bus_master_control_dati : out std_logic;
      bus_master_control_dato : out std_logic;
      bus_master_nxm : in std_logic;

      xubl_cs : out std_logic;
      xubl_mosi : out std_logic;
      xubl_sclk : out std_logic;
      xubl_miso : in std_logic;

      have_xu_enc : in integer range 0 to 1 := 0;

      reset : in std_logic;
      xublclk : in std_logic;
      clk : in std_logic
   );
end component;

component xubf is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      npr : out std_logic;
      npg : in std_logic;

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      bus_master_addr : out std_logic_vector(17 downto 0);
      bus_master_dati : in std_logic_vector(15 downto 0);
      bus_master_dato : out std_logic_vector(15 downto 0);
      bus_master_control_dati : out std_logic;
      bus_master_control_dato : out std_logic;
      bus_master_nxm : in std_logic;

      xubf_cs : out std_logic;
      xubf_mosi : out std_logic;
      xubf_sclk : out std_logic;
      xubf_miso : in std_logic;
      xubf_srdy : in std_logic;

      have_xu_esp : in integer range 0 to 1 := 0;

      reset : in std_logic;
      xubfclk : in std_logic;
      clk : in std_logic
   );
end component;

component xubm is
   port(
      base_addr : in std_logic_vector(17 downto 0);

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      npr : out std_logic;
      npg : in std_logic;

      bus_master_addr : out std_logic_vector(17 downto 0);
      bus_master_dati : in std_logic_vector(15 downto 0);
      bus_master_dato : out std_logic_vector(15 downto 0);
      bus_master_control_dati : out std_logic;
      bus_master_control_dato : out std_logic;
      bus_master_nxm : in std_logic;

      localbus_npr : out std_logic;
      localbus_npg : in std_logic;

      localbus_master_addr : out std_logic_vector(17 downto 0);
      localbus_master_dati : in std_logic_vector(15 downto 0);
      localbus_master_dato : out std_logic_vector(15 downto 0);
      localbus_master_control_dati : out std_logic;
      localbus_master_control_dato : out std_logic;
      localbus_master_nxm : in std_logic;

      reset : in std_logic;
      xubmclk : in std_logic;
      clk : in std_logic
   );
end component;

-- constants for the cpu
constant modelcode : integer := 20;
constant init_r7 : std_logic_vector(15 downto 0) := x"0200";         -- start address after reset = o'173000' = m9312 hi rom
constant init_psw : std_logic_vector(15 downto 0) := x"00e0";        -- initial psw for kernel mode, primary register set, priority 7

-- cpu
signal cpu_addr : std_logic_vector(15 downto 0);
signal cpu_datain : std_logic_vector(15 downto 0);
signal cpu_dataout : std_logic_vector(15 downto 0);
signal cpu_wr : std_logic;
signal cpu_rd : std_logic;
signal cpu_psw : std_logic_vector(15 downto 0);
signal cpu_psw_in : std_logic_vector(15 downto 0);
signal cpu_psw_we_even : std_logic;
signal cpu_psw_we_odd : std_logic;
signal cpu_pir_in : std_logic_vector(15 downto 0);
signal cpu_dw8 : std_logic;
signal cpu_cp : std_logic;
signal cpu_id : std_logic;
signal cpu_addr_match : std_logic;
signal cpu_sr0_ic : std_logic;
signal cpu_sr1 : std_logic_vector(15 downto 0);
signal cpu_sr2 : std_logic_vector(15 downto 0);
signal cpu_dstfreference : std_logic;
signal cpu_sr3csmenable : std_logic;

signal cpu_br6 : std_logic;
signal cpu_bg6 : std_logic;
signal cpu_int_vector6 : std_logic_vector(8 downto 0);

signal mmu_trap : std_logic;
signal mmu_abort : std_logic;
signal mmu_oddabort : std_logic;
signal cpu_ack_mmuabort : std_logic;
signal cpu_ack_mmutrap : std_logic;

signal cpu_npr : std_logic;
signal cpu_npg : std_logic;

signal nxmabort : std_logic;
signal oddabort : std_logic;
signal illhalt : std_logic;
signal ysv : std_logic;
signal rsv : std_logic;
signal ifetchcopy : std_logic;

-- local unibus and local bus stuff
signal localbus_unibus_mapped : std_logic;
signal localbus_addr : std_logic_vector(21 downto 0);
signal localbus_dati : std_logic_vector(15 downto 0);
signal localbus_dato : std_logic_vector(15 downto 0);
signal localbus_control_dati : std_logic;
signal localbus_control_dato : std_logic;
signal localbus_control_datob : std_logic;
signal localbusmaster_nxmabort : std_logic := '0';
signal localunibus_addr_match : std_logic;
signal localunibus_addr : std_logic_vector(17 downto 0);
signal localunibus_dati : std_logic_vector(15 downto 0);
signal localunibus_dato : std_logic_vector(15 downto 0);
signal localunibus_control_dati : std_logic;
signal localunibus_control_dato : std_logic;
signal localunibus_control_datob : std_logic;

signal localunibus_busmaster_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_dati : std_logic_vector(15 downto 0);
signal localunibus_busmaster_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_control_dati : std_logic;
signal localunibus_busmaster_control_dato : std_logic;
signal localunibus_busmaster_control_datob : std_logic;
signal localunibus_busmaster_control_npg : std_logic;

-- local bus peripherals
signal local_addr_match : std_logic;
constant local_base_addr : std_logic_vector(17 downto 0) := o"774510";
signal xu_dati : std_logic_vector(15 downto 0);

signal kl0_addr_match : std_logic;
signal kl0_dati : std_logic_vector(15 downto 0);

signal kw0_addr_match : std_logic;
signal kw0_dati : std_logic_vector(15 downto 0);
signal kw0_bg : std_logic;
signal kw0_br : std_logic;
signal kw0_ivec : std_logic_vector(8 downto 0);

signal xubr_addr_match : std_logic;
signal xubr_dati : std_logic_vector(15 downto 0);
signal xubw_addr_match : std_logic;
signal xubw_dati : std_logic_vector(15 downto 0);

signal cer_nxmabort : std_logic;
signal cer_ioabort : std_logic;

signal cpu_stack_limit : std_logic_vector(15 downto 0);
signal cpu_kmillhalt : std_logic;

signal cr_addr_match : std_logic;
signal cr_dati : std_logic_vector(15 downto 0);

signal xubl_cs : std_logic;
signal xubl_sclk : std_logic;
signal xubl_miso : std_logic;
signal xubl_mosi : std_logic;
signal xubl_addr_match : std_logic;
signal xubl_dati : std_logic_vector(15 downto 0);
signal xubl_npr : std_logic;

signal localunibus_busmaster_xubl_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_xubl_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_xubl_control_dati : std_logic;
signal localunibus_busmaster_xubl_control_dato : std_logic;

signal xubf_cs : std_logic;
signal xubf_sclk : std_logic;
signal xubf_miso : std_logic;
signal xubf_mosi : std_logic;
signal xubf_srdy : std_logic;
signal xubf_addr_match : std_logic;
signal xubf_dati : std_logic_vector(15 downto 0);
signal xubf_npr : std_logic;

signal localunibus_busmaster_xubf_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_xubf_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_xubf_control_dati : std_logic;
signal localunibus_busmaster_xubf_control_dato : std_logic;

signal xubm_addr_match : std_logic;
signal xubm_dati : std_logic_vector(15 downto 0);
signal xubm_npr : std_logic;

signal xubm_addr : std_logic_vector(17 downto 0);
signal xubm_dato : std_logic_vector(15 downto 0);
signal xubm_control_dati : std_logic;
signal xubm_control_dato : std_logic;

signal localunibus_busmaster_xubm_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_xubm_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_xubm_control_dati : std_logic;
signal localunibus_busmaster_xubm_control_dato : std_logic;


signal xureset : std_logic;

-- regular bus interface
signal base_addr_match : std_logic;
signal interrupt_trigger : std_logic := '0';
-- shadow of the `br` OUTPUT port - VHDL can't read back an `out` mode
-- port, needed here only so xu_irq_trace (a diagnostic) can see its
-- value; `br` itself still gets driven from this exactly as before.
signal br_i : std_logic := '0';
type interrupt_state_type is (
   i_idle,
   i_req,
   i_wait
);
signal interrupt_state : interrupt_state_type := i_idle;

-- xu data
signal pcsr0_seri : std_logic := '0';
signal pcsr0_pcei : std_logic := '0';
signal pcsr0_rxi : std_logic := '0';
signal pcsr0_txi : std_logic := '0';
signal pcsr0_dni : std_logic := '0';
signal pcsr0_rcbi : std_logic := '0';
signal pcsr0_usci : std_logic := '0';
signal pcsr0_intr : std_logic := '0';
signal pcsr0_inte : std_logic := '0';
signal pcsr0_rset : std_logic := '0';
signal pcsr0_pcmw : std_logic := '0';
signal pcsr0_port_command : std_logic_vector(3 downto 0) := "0000";

signal pcsr1_xpwr : std_logic := '0';
signal pcsr1_icab : std_logic := '0';
signal pcsr1_self_test : std_logic_vector(13 downto 8);
signal pcsr1_pcto : std_logic := '0';
signal pcsr1_state : std_logic_vector(3 downto 0) := "0000";

signal pcsr2_pcbb : std_logic_vector(15 downto 1) := "000000000000000";

signal pcsr3_pcbb : std_logic_vector(17 downto 16) := "00";

-- ============================================================
-- Real DEUNA port-command protocol + descriptor-ring packet engine.
-- Ground truth (command/state/PCB-function values, ring descriptor
-- format): SIMH's pdp11_xu.c/.h, a mature DEUNA/DELUA emulator - not
-- guessed. See [[xu-ethernet-bridge]] memory for the full history: an
-- earlier attempt got this command dispatch working reliably on
-- hardware, but its packet-ring engine (toggle-based handshake with
-- Linux, naive bus-master priority mux) caused a real board hang and was
-- reverted. This rebuild keeps the dispatch logic as-is and replaces the
-- packet engine with something modeled on xubf.vhd's simpler, proven
-- shape: a real grant-based bus-master arbiter (not a priority mux that
-- ignores grant timing) and a level-based 4-phase handshake with
-- xuring.vhd (not toggle-edge-detection).
-- ============================================================

type xucmd_state_t is (
   xc_idle,
   xc_pcb_req, xc_pcb_cap,          -- DMA-read the 4-word PCB (GETCMD)
   xc_decode,                       -- pcb(0) low byte selects the function
   xc_udb_req, xc_udb_cap,          -- DMA-read the 12-word UDB (WRF only)
   xc_finish,                       -- set dni/pcei, clear pcmw, drop npr

   -- generic single-word PDP-11 memory access, triggered by pdp11-netd
   -- over xuring.vhd instead of a port command. This REPLACES an earlier
   -- from-scratch hardware descriptor-ring-walk engine (two attempts,
   -- both caused a real board hang with xu.vhd itself showing idle at
   -- the moment of the freeze - see [[xu-ethernet-bridge]]) - the ENTIRE
   -- ring-walk algorithm now lives in pdp11-netd.c, which only needs
   -- this one generic primitive (the exact same request/capture DMA
   -- shape GETCMD/WRF above already use, just parameterized from the PS
   -- side instead of a fixed sequence) plus a few small state registers
   -- (xu_tdrb/xu_trlen/xu_rdrb/xu_rrlen below).
   xr_wait_grant,                      -- waiting for the bus-master arbiter to grant us the shared interface
   xm_req, xm_cap,                     -- one word, read or write per mem_op_is_write

   -- FC_RDPHYAD (0x04): DMA-WRITE our station address into the PCB so
   -- the driver can read it back. Added 2026-09-06 - without it the
   -- driver's bcopy(&pcbb2, ds_addr, 6) (if_de.c:237) picked up whatever
   -- was in memory (zeros), so the guest believed its own MAC was
   -- 00:00:00:00:00:00. deoutput() uses ds_addr as the SOURCE MAC of
   -- every frame (if_de.c:874) and derecv() matches inbound ether_dhost
   -- against it (if_de.c:595), so with a zero address the Linux bridge
   -- refused to learn the port (an all-zero source is invalid), ARP
   -- replies had nowhere to come back to, and ARP never resolved - ping
   -- sent only ARP requests forever. See [[xu-ethernet-bridge]].
   xc_pa_req, xc_pa_cap
);
signal xucmd_state : xucmd_state_t := xc_idle;
signal xucmd_next_state : xucmd_state_t := xc_idle;  -- where xr_wait_grant should go once granted
signal xucmd_err : std_logic := '0';
signal xucmd_dma_idx : integer range 0 to 15 := 0;

-- shared 4-word scratch for PCB (never more than one dispatch active)
type xu_word4_t is array(0 to 3) of std_logic_vector(15 downto 0);
signal xu_pcb : xu_word4_t := (others => (others => '0'));
signal xu_fnc : std_logic_vector(7 downto 0) := (others => '0');

-- Station address reported by FC_RDPHYAD, as the three PDP-11 words the
-- driver copies out of the PCB (little-endian byte pairs, so word N holds
-- ds_addr[2N] in its low byte). 08:00:2B is DEC's real OUI, which is what
-- a genuine DEUNA would present. Must be a valid unicast address: a
-- broadcast/multicast or all-zero source would not be learned by the
-- Linux bridge on the other side of tap0.
constant xu_phyad_w0 : std_logic_vector(15 downto 0) := x"0008";   -- 08:00
constant xu_phyad_w1 : std_logic_vector(15 downto 0) := x"112b";   -- 2b:11
constant xu_phyad_w2 : std_logic_vector(15 downto 0) := x"3322";   -- 22:33

-- diagnostic trace (LASTCMD register in xuring.vhd) - added 2026-09-06:
-- START was reaching RUNNING but TDRB/TRLEN never got latched, meaning
-- WRF apparently never arrived (opcode/PCB-layout/UDB-math all checked
-- correct against SIMH's actual source - see [[xu-ethernet-bridge]]).
-- This exposes exactly which port commands actually dispatch, in order,
-- so pdp11-netd can log the real sequence instead of guessing at it.
signal xu_last_port_cmd : std_logic_vector(3 downto 0) := (others => '0');
signal xu_cmd_counter   : std_logic_vector(3 downto 0) := (others => '0');

-- 8-entry command history (added 2026-09-06): a single "latest value"
-- trace register turned out too coarse to catch every command in the
-- driver's fast init burst (SELFTEST/GETPCBB/GETCMD/.../START can
-- complete within microseconds - far faster than software can poll a
-- snapshot register) - this records EVERY completed dispatch so
-- pdp11-netd can read back the full sequence after the fact, not just
-- whatever happened to be current at one poll instant. Each entry:
-- bits15:8 xu_fnc, bits7:4 port command, bits3:0 the xu_cmd_counter
-- value at that entry (so software can spot gaps/wraps).
type xu_hist_t is array(0 to 7) of std_logic_vector(15 downto 0);
signal xu_cmd_hist : xu_hist_t := (others => (others => '0'));
signal xu_hist_wptr : integer range 0 to 7 := 0;

-- UDB (12-word ring-format block, WRF only)
type xu_word12_t is array(0 to 11) of std_logic_vector(15 downto 0);
signal xu_udb : xu_word12_t := (others => (others => '0'));
signal xu_udbb : std_logic_vector(17 downto 0) := (others => '0');

-- PCB base address, LATCHED by GETPCBB (real hardware semantics - see the
-- GETPCBB dispatch comment) and reused by every later GETCMD until the
-- driver calls GETPCBB again. NOT a live read of pcsr2/pcsr3.
signal xu_pcbb : std_logic_vector(17 downto 0) := (others => '0');

-- ring configuration, latched by WRF - exposed read-only to pdp11-netd
-- via xuring0 (TDRB/TRLEN/RDRB/RRLEN). The ring POSITION (txnext/rxnext)
-- is NOT stored here - xuring.vhd owns those registers directly now,
-- since xu.vhd's own state machine never needs to see them in the
-- software-driven ring-walk design (see [[xu-ethernet-bridge]]).
signal xu_tdrb, xu_rdrb : std_logic_vector(17 downto 0) := (others => '0');  -- ring base addr
signal xu_trlen, xu_rrlen : std_logic_vector(15 downto 0) := (others => '0'); -- ring length, entries

-- ---- real grant-based bus-master arbiter between xubm0's pre-existing
-- (dormant) o"777100" DMA path and this single-word memory bridge.
-- Replaces the earlier "priority mux regardless of grant timing" that
-- was flagged (but never fixed) as a known risk - see
-- [[xu-ethernet-bridge]]. Both clients live in the nclk domain, so this
-- is a same-clock-domain latch, no CDC needed.
signal xubm_pri_npr : std_logic;
signal ring_npr : std_logic := '0';
signal ring_granted : std_logic := '0';
signal arb_owner_ring : std_logic := '0';
signal ring_addr : std_logic_vector(17 downto 0) := (others => '0');
signal ring_dato : std_logic_vector(15 downto 0) := (others => '0');
signal ring_control_dati : std_logic := '0';
signal ring_control_dato : std_logic := '0';

-- ---- xuring0 interface (see xuring.vhd) - level-based 4-phase
-- handshake throughout, not toggle/edge-detection (see xuring.vhd's
-- header for why) - the one part of this whole effort never implicated
-- in either hang, kept unchanged in spirit for the smaller register set.
signal mem_op_req_sync : std_logic;                     -- level, from xuring (a PS-side request is pending)
signal mem_op_is_write : std_logic;
signal mem_op_addr     : std_logic_vector(17 downto 0);
signal mem_op_wdata    : std_logic_vector(15 downto 0);
signal mem_op_rdata    : std_logic_vector(15 downto 0) := (others => '0');
signal mem_op_rdata_we : std_logic := '0';
signal mem_op_done     : std_logic := '0';              -- level: this engine finished the current op

signal txi_req_sync : std_logic;                        -- level, from xuring
signal txi_ack      : std_logic := '0';
signal rxi_req_sync : std_logic;
signal rxi_ack      : std_logic := '0';

-- debug readback (xuring.vhd's DEBUG register) - lets `devmem` on the PS
-- side see live engine state. bit15 xucmd_err, bit14 ring_npr, bit13
-- mem_op_req_sync, bit12 mem_op_done, bit11 txi_req_sync, bit10
-- rxi_req_sync, bit9 pcsr0_pcmw, bits8:5 pcsr1_state, bits4:0
-- xucmd_state. xuring.vhd adds a free-running heartbeat in the high bits
-- so a genuinely frozen system is distinguishable from one still ticking.
signal xu_debug_word : std_logic_vector(15 downto 0);

-- LASTCMD trace register (xuring.vhd) - bits15:8 xu_fnc (last-decoded PCB
-- function code, only meaningful after a GETCMD), bits7:4
-- xu_last_port_cmd (last dispatched port command), bits3:0 xu_cmd_counter
-- (increments on every completed dispatch - lets software tell a genuinely
-- new command apart from re-reading a stale value).
signal xu_cmd_trace : std_logic_vector(15 downto 0);

-- interrupt-path trace (added 2026-09-06, chasing why a second TX/RX
-- never seems to complete from the driver's perspective after the first
-- one works correctly - see [[xu-ethernet-bridge]]). bit15 br, bit14 bg,
-- bit13 interrupt_trigger, bit12 pcsr0_inte, bit11 pcsr0_txi, bit10
-- pcsr0_rxi, bit9 pcsr0_dni, bit8 pcsr0_pcei, bits7:6 interrupt_state
-- (00=i_idle,01=i_req,10=i_wait), bits5:0 unused. Widened to 32 bits
-- 2026-09-06: bit16 = diag_rh0_br, bits19:17 = diag_br5_state (br5_states
-- pos: 0=rh0,1=xu0,2=rl0,3=rk0,4=dr11c0,5=idle) - ruled out rh0 starving
-- xu0's BR5 slot (arbiter correctly reaches br5_xu0, rh0 idle). bit20 =
-- diag_cpu_bg5 (the REAL cpu_bg5 grant signal, before arbiter muxing),
-- bits23:21 = diag_cpu_psw_pri (CPU's current PSW<7:5>) - added to test
-- whether the CPU itself just never completes the bg5 handshake once
-- the arbiter has selected xu0 (see [[xu-ethernet-bridge]]).
signal xu_irq_trace : std_logic_vector(31 downto 0);

-- IRQCOUNT (xuring.vhd, added 2026-09-06) - free-running counts of
-- br_i rising edges (bits15:0, BR5 requests actually made) and bg
-- rising edges while br_i is asserted (bits31:16, grants actually
-- received). A slow external devmem poll cannot tell "fires and
-- clears within microseconds" apart from "never fires" - this counts
-- every occurrence in hardware so pdp11-netd can sample it before and
-- after an operation and get an exact number, not a maybe. See
-- [[xu-ethernet-bridge]] - added after speculating about a "lost
-- interrupt" from PC/IRQTRACE snapshots alone turned out to be
-- unverifiable and led to a bad fix (a naive re-arm watchdog that
-- made packet loss worse, 12%->90%).
-- Single-bit toggle, flipped every xc_finish (every completed guest port
-- command - GETCMD/PDMD included). This is the "guest did something, go
-- check the ring" event pdp11-netd was missing entirely: it opened the
-- UIO device but never called read() on it, so poll_tx() only ever ran
-- on a 2ms timer with no actual notification that a PDMD had happened.
-- A single toggle bit is the standard safe CDC pattern for "an event
-- occurred" across clock domains (unlike a multi-bit counter, one bit
-- can't be caught mid-transition) - xuring.vhd 2-flop-synchronizes it
-- and ORs "changed since software last acked" into ring_irq.
signal xu_cmd_toggle : std_logic := '0';

-- PCTRACE (xuring.vhd, added 2026-09-06) - bit17 diag_cpu_ifetch (the
-- CPU's 'ifetch' output - this specific bus cycle is an instruction
-- fetch, not a data access; cpu_addr_v carries BOTH so this bit is
-- needed to tell a stuck PC apart from a busy loop's varying data
-- references), bit16 diag_cpu_iwait (the real CPU 'iwait' output, set
-- while executing the WAIT instruction), bits15:0 diag_cpu_addr_v (the
-- CPU's live virtual address bus, cpu_addr_v in unibus.vhd). Turned out
-- NOT stuck in WAIT (see [[xu-ethernet-bridge]] for the correction) -
-- the CPU is actively cycling through a mix of addresses with iwait=0;
-- this bit narrows down whether that's a tight instruction loop or just
-- varying data references from one fixed loop body.
signal xu_pc_trace : std_logic_vector(31 downto 0);

begin

   cpu0: cpu port map(
      addr_v => cpu_addr,
      datain => cpu_datain,
      dataout => cpu_dataout,
      wr => cpu_wr,
      rd => cpu_rd,
      dw8 => cpu_dw8,
      cp => cpu_cp,
      ifetch => ifetchcopy,
      iwait => iwait,
      id => cpu_id,
      br7 => '0',
      int_vector7 => o"000",
      br6 => cpu_br6,
      bg6 => cpu_bg6,
      int_vector6 => cpu_int_vector6,
      br5 => '0',
      int_vector5 => o"000",
      br4 => '0',
      int_vector4 => o"000",
      mmutrap => mmu_trap,
      ack_mmutrap => cpu_ack_mmutrap,
      mmuabort => mmu_abort,
      ack_mmuabort => cpu_ack_mmuabort,
      npr => cpu_npr,
      npg => cpu_npg,
      nxmabort => nxmabort,
      oddabort => oddabort,
      illhalt => illhalt,
      ysv => ysv,
      rsv => rsv,
      cpu_stack_limit => cpu_stack_limit,
      cpu_kmillhalt => cpu_kmillhalt,
      sr0_ic => cpu_sr0_ic,
      sr1 => cpu_sr1,
      sr2 => cpu_sr2,
      dstfreference => cpu_dstfreference,
      sr3csmenable => cpu_sr3csmenable,
      psw_in => cpu_psw_in,
      psw_out => cpu_psw,
      psw_in_we_even => cpu_psw_we_even,
      psw_in_we_odd => cpu_psw_we_odd,
      pir_in => cpu_pir_in,
      modelcode => modelcode,
      init_r7 => init_r7,
      init_psw => init_psw,
      clk => cpuclk,
      reset => xureset
   );

   mmu0: mmu port map(
      cpu_addr_v => cpu_addr,
      cpu_datain => cpu_datain,
      cpu_dataout => cpu_dataout,
      cpu_rd => cpu_rd,
      cpu_wr => cpu_wr,
      cpu_dw8 => cpu_dw8,
      cpu_cp => cpu_cp,
      sr0_ic => cpu_sr0_ic,
      sr1_in => cpu_sr1,
      sr2_in => cpu_sr2,
      dstfreference => cpu_dstfreference,
      sr3csmenable => cpu_sr3csmenable,
      ifetch => ifetchcopy,
      mmutrap => mmu_trap,
      ack_mmutrap => cpu_ack_mmutrap,
      mmuabort => mmu_abort,
      ack_mmuabort => cpu_ack_mmuabort,

      mmuoddabort => mmu_oddabort,

      bus_unibus_mapped => localbus_unibus_mapped,

      bus_addr => localbus_addr,
      bus_dati => localbus_dati,
      bus_dato => localbus_dato,
      bus_control_dati => localbus_control_dati,
      bus_control_dato => localbus_control_dato,
      bus_control_datob => localbus_control_datob,

      unibus_addr => localunibus_addr,
      unibus_dati => localunibus_dati,
      unibus_dato => localunibus_dato,
      unibus_control_dati => localunibus_control_dati,
      unibus_control_dato => localunibus_control_dato,
      unibus_control_datob => localunibus_control_datob,

      unibus_busmaster_addr => localunibus_busmaster_addr,
      unibus_busmaster_dati => localunibus_busmaster_dati,
      unibus_busmaster_dato => localunibus_busmaster_dato,
      unibus_busmaster_control_dati => localunibus_busmaster_control_dati,
      unibus_busmaster_control_dato => localunibus_busmaster_control_dato,
      unibus_busmaster_control_datob => localunibus_busmaster_control_datob,
      unibus_busmaster_control_npg => localunibus_busmaster_control_npg,

      modelcode => modelcode,

      psw => cpu_psw,
      id => cpu_id,
      reset => xureset,
      clk => nclk
   );

   cr0: cr11 port map(
      bus_addr_match => cr_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => cr_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      psw_in => cpu_psw_in,
      psw_in_we_even => cpu_psw_we_even,
      psw_in_we_odd => cpu_psw_we_odd,
      psw_out => cpu_psw,

      cpu_stack_limit => cpu_stack_limit,

      pir_in => cpu_pir_in,

      cpu_illegal_halt => illhalt,
      cpu_address_error => oddabort,
      cpu_nxm => cer_nxmabort,
      cpu_iobus_timeout => cer_ioabort,
      cpu_ysv => ysv,
      cpu_rsv => rsv,

      cpu_kmillhalt => cpu_kmillhalt,

      modelcode => modelcode,

      reset => xureset,
      clk => nclk
   );

   kl0: kl11 port map(
      base_addr => o"777560",
      ivec => o"060",
      ovec => o"064",

      bg => '0',              -- polled i/o only

      bus_addr_match => kl0_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => kl0_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      tx => tx,
      rx => '1',
      cts => '0',
      have_kl11 => 1,
      have_kl11_bps => 115200,
      have_kl11_force7bit => 1,
      have_kl11_rtscts => 0,
      clk50mhz => clk50mhz,
      reset => xureset,
      clk => nclk
   );

   kw0: kw11l port map(
      base_addr => o"777546",
      ivec => o"100",

      br => kw0_br,
      bg => kw0_bg,
      int_vector => kw0_ivec,

      bus_addr_match => kw0_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => kw0_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      have_kw11l => 1,
      kw11l_hz => 60,
      reset => xureset,
      clk50mhz => clk50mhz,
      clk => nclk
   );

   xubr0: xubr port map(
      base_addr => o"000000",

      bus_addr_match => xubr_addr_match,
      bus_addr => localbus_addr(17 downto 0),
      bus_dati => xubr_dati,
      bus_dato => localbus_dato,
      bus_control_dati => localbus_control_dati,
      bus_control_dato => localbus_control_dato,
      bus_control_datob => localbus_control_datob,

      have_xu_enc => have_xu_enc,

      reset => xureset,
      clk => nclk
   );

   xubw0: xubw port map(
      base_addr => o"000000",

      bus_addr_match => xubw_addr_match,
      bus_addr => localbus_addr(17 downto 0),
      bus_dati => xubw_dati,
      bus_dato => localbus_dato,
      bus_control_dati => localbus_control_dati,
      bus_control_dato => localbus_control_dato,
      bus_control_datob => localbus_control_datob,

      have_xu_esp => have_xu_esp,

      reset => xureset,
      clk => nclk
   );

   xubl0: xubl port map(
      base_addr => o"777000",

      npr => xubl_npr,
      npg => cpu_npg,

      bus_addr_match => xubl_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => xubl_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      bus_master_addr => localunibus_busmaster_xubl_addr,
      bus_master_dati => localunibus_busmaster_dati,
      bus_master_dato => localunibus_busmaster_xubl_dato,
      bus_master_control_dati => localunibus_busmaster_xubl_control_dati,
      bus_master_control_dato => localunibus_busmaster_xubl_control_dato,
      bus_master_nxm => localbusmaster_nxmabort,

      xubl_cs => xubl_cs,
      xubl_mosi => xubl_mosi,
      xubl_sclk => xubl_sclk,
      xubl_miso => xubl_miso,

      have_xu_enc => have_xu_enc,

      reset => xureset,
      xublclk => cpuclk,
      clk => nclk
   );
   xubl_miso <= xu_miso;


   xubf0: xubf port map(
      base_addr => o"777000",

      npr => xubf_npr,
      npg => cpu_npg,

      bus_addr_match => xubf_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => xubf_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      bus_master_addr => localunibus_busmaster_xubf_addr,
      bus_master_dati => localunibus_busmaster_dati,
      bus_master_dato => localunibus_busmaster_xubf_dato,
      bus_master_control_dati => localunibus_busmaster_xubf_control_dati,
      bus_master_control_dato => localunibus_busmaster_xubf_control_dato,
      bus_master_nxm => localbusmaster_nxmabort,

      xubf_cs => xubf_cs,
      xubf_mosi => xubf_mosi,
      xubf_sclk => xubf_sclk,
      xubf_miso => xubf_miso,
      xubf_srdy => xubf_srdy,

      have_xu_esp => have_xu_esp,

      reset => xureset,
      xubfclk => cpuclk,
      clk => nclk
   );
   xubf_miso <= xu_miso;
   xubf_srdy <= xu_srdy;
   xu_cs <= xubl_cs when have_xu_enc = 1
      else xubf_cs when have_xu_esp = 1
      else '0';
   xu_sclk <= xubl_sclk when have_xu_enc = 1
      else xubf_sclk when have_xu_esp = 1
      else '0';
   xu_mosi <= xubl_mosi when have_xu_enc = 1
      else xubf_mosi when have_xu_esp = 1
      else '0';

   xubm0: xubm port map(
      base_addr => o"777100",

      npr => xubm_pri_npr,
      npg => npg,

      bus_addr_match => xubm_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => xubm_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      bus_master_addr => xubm_addr,
      bus_master_dati => bus_master_dati,
      bus_master_dato => xubm_dato,
      bus_master_control_dati => xubm_control_dati,
      bus_master_control_dato => xubm_control_dato,
      bus_master_nxm => bus_master_nxm,

      localbus_npr => xubm_npr,
      localbus_npg => cpu_npg,

      localbus_master_addr => localunibus_busmaster_xubm_addr,
      localbus_master_dati => localunibus_busmaster_dati,
      localbus_master_dato => localunibus_busmaster_xubm_dato,
      localbus_master_control_dati => localunibus_busmaster_xubm_control_dati,
      localbus_master_control_dato => localunibus_busmaster_xubm_control_dato,
      localbus_master_nxm => localbusmaster_nxmabort,

      reset => xureset,
      xubmclk => cpuclk,
      clk => nclk
   );

   -- Linux frame bridge - see xuring.vhd's header. Only its AXI-Lite +
   -- irq reach the PS (entity-level ring_s_axi_*/ring_irq); the
   -- xu.vhd-facing signals stay entirely internal to this entity. Direct
   -- entity instantiation (not a `component` declaration) deliberately -
   -- a stale hand-maintained component decl elsewhere caused a real
   -- build failure earlier in this project (see [[xu-ethernet-bridge]]),
   -- this sidesteps that whole bug class.
   xuring0 : entity work.xuring
      port map(
         clk   => nclk,
         reset => xureset,

         mem_op_req_sync => mem_op_req_sync,
         mem_op_is_write => mem_op_is_write,
         mem_op_addr     => mem_op_addr,
         mem_op_wdata    => mem_op_wdata,
         mem_op_rdata    => mem_op_rdata,
         mem_op_rdata_we => mem_op_rdata_we,
         mem_op_done     => mem_op_done,

         tdrb  => xu_tdrb,
         trlen => xu_trlen,
         rdrb  => xu_rdrb,
         rrlen => xu_rrlen,

         pcsr1_state => pcsr1_state,

         txi_req_sync => txi_req_sync,
         txi_ack      => txi_ack,
         rxi_req_sync => rxi_req_sync,
         rxi_ack      => rxi_ack,

         debug_word => xu_debug_word,
         cmd_trace  => xu_cmd_trace,

         hist0 => xu_cmd_hist(0),
         hist1 => xu_cmd_hist(1),
         hist2 => xu_cmd_hist(2),
         hist3 => xu_cmd_hist(3),
         hist4 => xu_cmd_hist(4),
         hist5 => xu_cmd_hist(5),
         hist6 => xu_cmd_hist(6),
         hist7 => xu_cmd_hist(7),
         hist_wptr => conv_std_logic_vector(xu_hist_wptr, 3),
         irq_trace => xu_irq_trace,
         pc_trace  => xu_pc_trace,
         cmd_done_toggle => xu_cmd_toggle,

         s_axi_aclk    => ring_s_axi_aclk,
         s_axi_aresetn => ring_s_axi_aresetn,
         s_axi_awaddr  => ring_s_axi_awaddr,
         s_axi_awvalid => ring_s_axi_awvalid,
         s_axi_awready => ring_s_axi_awready,
         s_axi_wdata   => ring_s_axi_wdata,
         s_axi_wstrb   => ring_s_axi_wstrb,
         s_axi_wvalid  => ring_s_axi_wvalid,
         s_axi_wready  => ring_s_axi_wready,
         s_axi_bresp   => ring_s_axi_bresp,
         s_axi_bvalid  => ring_s_axi_bvalid,
         s_axi_bready  => ring_s_axi_bready,
         s_axi_araddr  => ring_s_axi_araddr,
         s_axi_arvalid => ring_s_axi_arvalid,
         s_axi_arready => ring_s_axi_arready,
         s_axi_rdata   => ring_s_axi_rdata,
         s_axi_rresp   => ring_s_axi_rresp,
         s_axi_rvalid  => ring_s_axi_rvalid,
         s_axi_rready  => ring_s_axi_rready,

         irq => ring_irq
      );

   ifetch <= ifetchcopy;

   cpu_br6 <= kw0_br;
   kw0_bg <= cpu_bg6;
   cpu_int_vector6 <= kw0_ivec;

   localbus_dati <=
      xubr_dati when xubr_addr_match = '1'
      else xubw_dati when xubw_addr_match = '1'
      else "0000000000000000";

   localunibus_dati <=
      cr_dati when cr_addr_match = '1'
      else kl0_dati when kl0_addr_match = '1'
      else kw0_dati when kw0_addr_match = '1'
      else xubl_dati when xubl_addr_match = '1'
      else xubf_dati when xubf_addr_match = '1'
      else xubm_dati when xubm_addr_match = '1'
      else xu_dati when local_addr_match = '1'
      else "0000000000000000";

   localunibus_addr_match <= '1'
      when cr_addr_match = '1'
      or kl0_addr_match = '1'
      or kw0_addr_match = '1'
      or xubl_addr_match = '1'
      or xubf_addr_match = '1'
      or xubm_addr_match = '1'
      or local_addr_match = '1'
      else '0';

   cer_nxmabort <= '1'
      when xubr_addr_match = '0' and xubw_addr_match = '0'
      and (localbus_control_dati = '1' or localbus_control_dato = '1')
      and localbus_unibus_mapped = '0'
      and cpu_npg = '0'
      else '0';

   cer_ioabort <=
      '1' when localunibus_addr_match = '0' and (localunibus_control_dati = '1' or localunibus_control_dato = '1') and localunibus_addr(17 downto 13) = "11111" and cpu_npg = '0'
      else '1' when xubr_addr_match = '0' and xubw_addr_match = '0' and localbus_unibus_mapped = '1' and (localbus_control_dati = '1' or localbus_control_dato = '1') and cpu_npg = '0'
      else '0';

   nxmabort <= '1' when cer_nxmabort = '1' or cer_ioabort = '1' else '0';

   oddabort <=
      '1' when localbus_control_dato = '1' and localbus_control_datob = '0' and localbus_addr(0) = '1'
      else '1' when mmu_oddabort = '1'
      else '0';

   localunibus_busmaster_addr <= localunibus_busmaster_xubl_addr when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xubf_addr when cpu_npg = '1' and xubf_npr = '1'
      else localunibus_busmaster_xubm_addr when cpu_npg = '1' and xubm_npr = '1'
      else "000000000000000000";
   localunibus_busmaster_dato <= localunibus_busmaster_xubl_dato when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xubf_dato when cpu_npg = '1' and xubf_npr = '1'
      else localunibus_busmaster_xubm_dato when cpu_npg = '1' and xubm_npr = '1'
      else "0000000000000000";
   localunibus_busmaster_control_dati <= localunibus_busmaster_xubl_control_dati when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xubf_control_dati when cpu_npg = '1' and xubf_npr = '1'
      else localunibus_busmaster_xubm_control_dati when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_dato <= localunibus_busmaster_xubl_control_dato when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xubf_control_dato when cpu_npg = '1' and xubf_npr = '1'
      else localunibus_busmaster_xubm_control_dato when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_datob <= '0' when cpu_npg = '1' and xubl_npr = '1'
      else '0' when cpu_npg = '1' and xubf_npr = '1'
      else '0' when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_npg <= '1' when cpu_npg = '1' and xubl_npr = '1'
      else '1' when cpu_npg = '1' and xubf_npr = '1'
      else '1' when cpu_npg = '1' and xubm_npr = '1'
      else '0';

   cpu_npr <= '1' when xubl_npr = '1' or xubf_npr = '1' or xubm_npr = '1' else '0';

   -- real grant-based arbiter (see the signal declarations above for why)
   -- between xubm0's dormant o"777100" DMA path and the ring engine below.
   -- Registered owner latch: switches only when the current owner's
   -- request has actually dropped, never mid-transaction, and never based
   -- purely on which side happens to be asking this cycle.
   process(nclk, reset)
   begin
      if nclk = '1' and nclk'event then
         if reset = '1' then
            arb_owner_ring <= '0';
         elsif xubm_pri_npr = '0' and ring_npr = '1' then
            arb_owner_ring <= '1';
         elsif ring_npr = '0' then
            arb_owner_ring <= '0';
         end if;
         -- else (both requesting): keep the current owner unchanged
      end if;
   end process;

   -- CRITICAL: also require the entity's own npg INPUT (the real grant
   -- from unibus.vhd's outer arbitration), not just arb_owner_ring (which
   -- only arbitrates internally between xu.vhd's two own clients for
   -- who drives the entity's output ports). Without this, xc_pcb_req/
   -- xc_udb_req/xm_req could assert control_dati and capture
   -- bus_master_dati a cycle later WITHOUT the unibus fabric having
   -- actually granted the bus yet - reading whatever happens to be on a
   -- shared signal nobody has driven for this transaction, which read
   -- back as all-zero every single time tonight (found via the command-
   -- history buffer: GETCMD's PCB function code always read 0 regardless
   -- of what the driver actually wrote, and WRF/UDB fields likewise
   -- always read 0 - this bug has been present since Phase A, just never
   -- checked before). xubm0 already does this correctly (see its own
   -- direct `npg => npg` port map) - this makes xucmd/ring do the same.
   -- See [[xu-ethernet-bridge]] memory.
   ring_granted <= '1' when arb_owner_ring = '1' and ring_npr = '1' and npg = '1' else '0';

   npr <= '1' when xubm_pri_npr = '1' or ring_npr = '1' else '0';
   bus_master_addr         <= ring_addr         when arb_owner_ring = '1' else xubm_addr;
   bus_master_dato         <= ring_dato         when arb_owner_ring = '1' else xubm_dato;
   bus_master_control_dati <= ring_control_dati when arb_owner_ring = '1' else xubm_control_dati;
   bus_master_control_dato <= ring_control_dato when arb_owner_ring = '1' else xubm_control_dato;

   -- (mem_op_req_sync/txi_req_sync/rxi_req_sync are already synced INSIDE
   -- xuring.vhd - it owns the s_axi_aclk-domain source signals, so the
   -- synchronizer lives there, not here.)

   xu_debug_word <= xucmd_err & ring_npr & mem_op_req_sync & mem_op_done & txi_req_sync & rxi_req_sync
      & pcsr0_pcmw & pcsr1_state & conv_std_logic_vector(xucmd_state_t'pos(xucmd_state), 5);

   xu_cmd_trace <= xu_fnc & xu_last_port_cmd & xu_cmd_counter;

   br <= br_i;

   xu_irq_trace <= "00000000" & diag_cpu_psw_pri & diag_cpu_bg5 & diag_br5_state & diag_rh0_br
      & br_i & bg & interrupt_trigger & pcsr0_inte & pcsr0_txi & pcsr0_rxi & pcsr0_dni & pcsr0_pcei
      & conv_std_logic_vector(interrupt_state_type'pos(interrupt_state), 2) & "000000";

   xu_pc_trace <= "00000000000000" & diag_cpu_ifetch & diag_cpu_iwait & diag_cpu_addr_v;

-- reset signal, force exclusion of components if xu is not configured

   xureset <= reset when have_xu = 1 else '1';

-- regular bus interface

   base_addr_match <= '1' when base_addr(17 downto 3) = bus_addr(17 downto 3) and have_xu = 1 else '0';
   local_addr_match <= '1' when localunibus_addr(17 downto 3) = local_base_addr(17 downto 3) and have_xu = 1 else '0';
   bus_addr_match <= base_addr_match;

   localbusmaster_nxmabort <= '0';
   
-- device logic

   pcsr0_intr <= '1' when pcsr0_seri = '1' or pcsr0_pcei = '1' or pcsr0_rxi = '1' or pcsr0_txi = '1' or pcsr0_dni = '1' or pcsr0_rcbi = '1' or pcsr0_usci = '1' else '0';

   process(nclk, reset)
   begin
      if nclk = '1' and nclk'event then
         if reset = '1' then

            br_i <= '0';
            interrupt_trigger <= '0';
            interrupt_state <= i_idle;

            pcsr0_seri <= '0';
            pcsr0_pcei <= '0';
            pcsr0_rxi <= '0';
            pcsr0_txi <= '0';
            pcsr0_dni <= '0';
            pcsr0_rcbi <= '0';
            pcsr0_usci <= '0';
            pcsr0_inte <= '0';
            pcsr0_rset <= '0';
            pcsr0_pcmw <= '0';
            pcsr0_port_command <= "0000";

            pcsr1_xpwr <= '0';
            pcsr1_icab <= '0';
            pcsr1_self_test <= "000000";
            pcsr1_pcto <= '0';
            pcsr1_state <= "0010"; -- ready
            pcsr2_pcbb <= "000000000000000";
            pcsr3_pcbb <= "00";

            xucmd_state <= xc_idle;
            xucmd_next_state <= xc_idle;
            xucmd_err <= '0';
            xucmd_dma_idx <= 0;
            xu_fnc <= (others => '0');
            xu_last_port_cmd <= (others => '0');
            xu_cmd_counter <= (others => '0');
            xu_cmd_toggle <= '0';
            xu_cmd_hist <= (others => (others => '0'));
            xu_hist_wptr <= 0;
            xu_udbb <= (others => '0');
            xu_pcbb <= (others => '0');
            xu_tdrb <= (others => '0');
            xu_rdrb <= (others => '0');
            xu_trlen <= (others => '0');
            xu_rrlen <= (others => '0');
            ring_npr <= '0';
            ring_addr <= (others => '0');
            ring_dato <= (others => '0');
            ring_control_dati <= '0';
            ring_control_dato <= '0';
            mem_op_rdata <= (others => '0');
            mem_op_rdata_we <= '0';
            mem_op_done <= '0';
            txi_ack <= '0';
            rxi_ack <= '0';

         else
            if have_xu = 1 then

               case interrupt_state is

                  when i_idle =>

                     br_i <= '0';
                     if pcsr0_inte = '1' and pcsr0_intr = '1' then
                        if interrupt_trigger = '0' then
                           interrupt_state <= i_req;
                           br_i <= '1';
                           interrupt_trigger <= '1';
                        end if;
                     else
                        interrupt_trigger <= '0';
                     end if;

                  when i_req =>
                     if bg = '1' then
                        int_vector <= ivec;
                        br_i <= '0';
                        interrupt_state <= i_wait;
                     end if;

                  when i_wait =>
                     if bg = '0' then
                        interrupt_state <= i_idle;
                     end if;

                  when others =>
                     interrupt_state <= i_idle;

               end case;
            else
               br_i <= '0';
            end if;

            if have_xu = 1 then

               -- background handshake completion with xuring (level, not
               -- toggle) - runs every cycle regardless of xucmd_state,
               -- mirroring xubf's own always-active "run='0' -> cs<='1'"
               -- idle check. Clear our own ack once the requester's level
               -- drops, completing each 4-phase handshake.
               if mem_op_req_sync = '0' and mem_op_done = '1' then
                  mem_op_done <= '0';
               end if;
               if txi_req_sync = '0' and txi_ack = '1' then
                  txi_ack <= '0';
               end if;
               if rxi_req_sync = '0' and rxi_ack = '1' then
                  rxi_ack <= '0';
               end if;

               case xucmd_state is

                  when xc_idle =>
                     xucmd_err <= '0';
                     if pcsr0_pcmw = '1' then
                        -- diagnostic trace only (see xu_debug_word/LASTCMD
                        -- comment) - added 2026-09-06 after WRF appeared to
                        -- never actually configure the ring despite START
                        -- succeeding; lets pdp11-netd see exactly which
                        -- port commands actually arrive, in what order.
                        xu_last_port_cmd <= pcsr0_port_command;
                        case pcsr0_port_command is
                           when "0000" =>                     -- NOOP
                              xucmd_state <= xc_finish;
                           when "0001" =>                      -- GETPCBB - LATCH pcbb now (real hardware
                              -- semantics, confirmed against SIMH's xu_port_command():
                              -- "xu->var->pcbb = (pcsr3<<16)|pcsr2" happens exactly
                              -- once, here, and persists across later GETCMD calls
                              -- regardless of what pcsr2/pcsr3 do afterward. The
                              -- previous "read live at GETCMD time" implementation
                              -- was a real bug - see [[xu-ethernet-bridge]] memory
                              -- for how a full command-history trace caught this
                              -- (WRF never appeared to fire; this is the likely
                              -- reason GETCMD kept fetching the wrong PCB content).
                              xu_pcbb <= pcsr3_pcbb & pcsr2_pcbb & "0";
                              xucmd_state <= xc_finish;
                           when "0010" =>                      -- GETCMD - fetch the 4-word PCB via DMA
                              xucmd_dma_idx <= 0;
                              ring_npr <= '1';
                              xucmd_next_state <= xc_pcb_req;
                              xucmd_state <= xr_wait_grant;
                           when "0011" =>                      -- SELFTEST
                              pcsr0_usci <= '0';
                              pcsr1_state <= "0010";            -- READY
                              xucmd_state <= xc_finish;
                           when "0100" =>                      -- START
                              if pcsr1_state = "0010" then      -- from READY only
                                 pcsr1_state <= "0011";         -- RUNNING
                                 -- txnext/rxnext reset to 0 is pdp11-netd's
                                 -- own job now (it owns those registers via
                                 -- xuring0) - nothing to do here.
                              else
                                 xucmd_err <= '1';
                              end if;
                              xucmd_state <= xc_finish;
                           when "1110" =>                      -- HALT (016 octal)
                              pcsr1_state <= "1000";            -- HALT
                              xucmd_state <= xc_finish;
                           when "1111" =>                      -- STOP (017 octal)
                              pcsr1_state <= "0000";            -- RESET
                              xucmd_state <= xc_finish;
                           when others =>                      -- BOOT(5), PDMD(010 octal) - ack only, not implemented
                              xucmd_state <= xc_finish;
                        end case;
                     elsif mem_op_req_sync = '1' and mem_op_done = '0' then
                        -- pdp11-netd wants one PDP-11 memory word read or
                        -- written - the entire descriptor-ring walk lives
                        -- in software now (see [[xu-ethernet-bridge]]);
                        -- this is the only primitive it needs from here.
                        ring_npr <= '1';
                        xucmd_next_state <= xm_req;
                        xucmd_state <= xr_wait_grant;
                     elsif txi_req_sync = '1' and txi_ack = '0' then
                        -- pdp11-netd finished a TX transfer - no DMA
                        -- needed, just pulse the interrupt flag.
                        pcsr0_txi <= '1';
                        txi_ack <= '1';
                     elsif rxi_req_sync = '1' and rxi_ack = '0' then
                        pcsr0_rxi <= '1';
                        rxi_ack <= '1';
                     end if;

                  -- real grant-based arbiter wait - see the arb_owner_ring
                  -- process below. Held here (re-asserting ring_npr every
                  -- cycle) until actually granted, rather than assuming
                  -- immediate ownership the way the reverted design's
                  -- naive priority mux did.
                  when xr_wait_grant =>
                     ring_npr <= '1';
                     if ring_granted = '1' then
                        xucmd_state <= xucmd_next_state;
                     end if;

                  -- GETCMD step 1: DMA-read the 4-word (8-byte) PCB from
                  -- xu_pcbb (latched by the most recent GETPCBB, NOT a
                  -- live pcsr2/pcsr3 read - see the GETPCBB dispatch
                  -- comment). Assert addr+control_dati one cycle, capture
                  -- bus_master_dati the cycle after - the same primitive
                  -- xubf.vhd's own bus-master reads use.
                  when xc_pcb_req =>
                     if xucmd_dma_idx = 0 then
                        ring_addr <= xu_pcbb;
                     else
                        ring_addr <= ring_addr + 2;
                     end if;
                     ring_control_dati <= '1';
                     xucmd_state <= xc_pcb_cap;

                  when xc_pcb_cap =>
                     ring_control_dati <= '0';
                     xu_pcb(xucmd_dma_idx) <= bus_master_dati;
                     if xucmd_dma_idx = 3 then
                        xucmd_state <= xc_decode;
                     else
                        xucmd_dma_idx <= xucmd_dma_idx + 1;
                        xucmd_state <= xc_pcb_req;
                     end if;

                  -- pcb(0) low byte selects the PCB function. Only WRF
                  -- (ring format) does anything beyond acknowledging;
                  -- every other function is a stub for now - an
                  -- unimplemented one can't hang the driver the way the
                  -- totally-unimplemented port-command dispatch used to.
                  when xc_decode =>
                     xu_fnc <= xu_pcb(0)(7 downto 0);
                     if xu_pcb(0)(7 downto 0) = x"09" then      -- WRF
                        xu_udbb <= xu_pcb(2)(1 downto 0) & xu_pcb(1);
                        xucmd_dma_idx <= 0;
                        xucmd_state <= xc_udb_req;
                     elsif xu_pcb(0)(7 downto 0) = x"04" then   -- RDPHYAD
                        -- write our station address back into pcbb2/4/6.
                        -- We still hold the bus here (ring_npr stays
                        -- asserted from GETCMD until xc_finish), so no
                        -- second xr_wait_grant round-trip is needed.
                        xucmd_dma_idx <= 0;
                        xucmd_state <= xc_pa_req;
                     else
                        xucmd_state <= xc_finish;
                     end if;

                  -- WRF: DMA-read the 12-word UDB (ring format block) and
                  -- latch the ring config (tdrb/telen/trlen/rdrb/relen/
                  -- rrlen, UDB words 0-5) - this is what makes the packet
                  -- engine below able to find the driver's descriptor
                  -- rings at all.
                  when xc_udb_req =>
                     if xucmd_dma_idx = 0 then
                        ring_addr <= xu_udbb;
                     else
                        ring_addr <= ring_addr + 2;
                     end if;
                     ring_control_dati <= '1';
                     xucmd_state <= xc_udb_cap;

                  when xc_udb_cap =>
                     ring_control_dati <= '0';
                     xu_udb(xucmd_dma_idx) <= bus_master_dati;
                     if xucmd_dma_idx = 11 then
                        -- entry-size fields (UDB words 1/4 high bytes,
                        -- b_telen/b_relen) are not latched here - the
                        -- ring-walk in pdp11-netd.c hardcodes the stride
                        -- instead. NOTE: that stride is 5 words / 10
                        -- bytes (sizeof 2.11BSD's struct de_ring), NOT
                        -- the "4-word/8-byte" this comment used to
                        -- claim - that false assumption, mirrored on
                        -- both sides of the interface, WAS the multi-day
                        -- board-hang bug (see [[xu-ethernet-bridge]]).
                        -- Worth latching/exposing b_telen/b_relen as
                        -- read-only registers if another guest OS with a
                        -- different entry size is ever used, so this
                        -- class of bug can't recur.
                        xu_tdrb   <= xu_udb(1)(1 downto 0) & xu_udb(0);
                        xu_trlen  <= xu_udb(2);
                        xu_rdrb   <= xu_udb(4)(1 downto 0) & xu_udb(3);
                        xu_rrlen  <= xu_udb(5);
                        -- txnext/rxnext reset to 0 is pdp11-netd's own job
                        -- now (it owns those registers via xuring0).
                        xucmd_state <= xc_finish;
                     else
                        xucmd_dma_idx <= xucmd_dma_idx + 1;
                        xucmd_state <= xc_udb_req;
                     end if;

                  when xc_finish =>
                     ring_npr <= '0';
                     pcsr0_pcmw <= '0';
                     xu_cmd_counter <= xu_cmd_counter + 1;
                     xu_cmd_toggle <= not xu_cmd_toggle;
                     xu_cmd_hist(xu_hist_wptr) <= xu_fnc & xu_last_port_cmd & xu_cmd_counter;
                     if xu_hist_wptr = 7 then
                        xu_hist_wptr <= 0;
                     else
                        xu_hist_wptr <= xu_hist_wptr + 1;
                     end if;
                     if xucmd_err = '1' then
                        pcsr0_pcei <= '1';
                     else
                        pcsr0_dni <= '1';
                     end if;
                     xucmd_state <= xc_idle;

                  -- ============ generic single-word PDP-11 memory
                  -- access, entirely parameterized by pdp11-netd over
                  -- xuring0 (mem_op_addr/mem_op_is_write/mem_op_wdata) -
                  -- see the type declaration's comment for why the
                  -- descriptor-ring walk itself no longer lives here.
                  -- ============

                  when xm_req =>
                     mem_op_rdata_we <= '0';
                     ring_addr <= mem_op_addr;
                     if mem_op_is_write = '1' then
                        ring_dato <= mem_op_wdata;
                        ring_control_dato <= '1';
                     else
                        ring_control_dati <= '1';
                     end if;
                     xucmd_state <= xm_cap;

                  when xm_cap =>
                     ring_control_dati <= '0';
                     ring_control_dato <= '0';
                     if mem_op_is_write = '0' then
                        mem_op_rdata <= bus_master_dati;
                        mem_op_rdata_we <= '1';
                     end if;
                     ring_npr <= '0';
                     mem_op_done <= '1';
                     xucmd_state <= xc_idle;

                  -- FC_RDPHYAD: DMA-write the 3 station-address words to
                  -- pcbb2/pcbb4/pcbb6 (PCB base + 2/4/6), which is where
                  -- if_de.c:237 bcopy()s its 6-byte ds_addr from. Same
                  -- request/capture shape as the PCB/UDB reads above,
                  -- just driving dato instead of dati.
                  when xc_pa_req =>
                     if xucmd_dma_idx = 0 then
                        ring_addr <= xu_pcbb + 2;
                     else
                        ring_addr <= ring_addr + 2;
                     end if;
                     case xucmd_dma_idx is
                        when 0      => ring_dato <= xu_phyad_w0;
                        when 1      => ring_dato <= xu_phyad_w1;
                        when others => ring_dato <= xu_phyad_w2;
                     end case;
                     ring_control_dato <= '1';
                     xucmd_state <= xc_pa_cap;

                  when xc_pa_cap =>
                     ring_control_dato <= '0';
                     if xucmd_dma_idx = 2 then
                        xucmd_state <= xc_finish;
                     else
                        xucmd_dma_idx <= xucmd_dma_idx + 1;
                        xucmd_state <= xc_pa_req;
                     end if;

                  when others =>
                     xucmd_state <= xc_idle;

               end case;
            end if;

            if have_xu = 1 then

-- register access from the main cpu to the xu as peripheral
               if base_addr_match = '1' and bus_control_dati = '1' then

                  case bus_addr(2 downto 1) is
                     when "00" =>
                        bus_dati <= pcsr0_seri & pcsr0_pcei & pcsr0_rxi & pcsr0_txi & pcsr0_dni & pcsr0_rcbi & "0" & pcsr0_usci
                           & pcsr0_intr & pcsr0_inte & "00" & pcsr0_port_command;

                     when "01" =>
                        bus_dati <= pcsr1_xpwr & pcsr1_icab & pcsr1_self_test & pcsr1_pcto & "001" & pcsr1_state;

                     when "10" =>
                        bus_dati <= pcsr2_pcbb & "0";

                     when "11" =>
                        bus_dati <= "00000000000000" & pcsr3_pcbb;

                     when others =>
                        bus_dati <= (others => '0');

                  end case;
               end if;

               if base_addr_match = '1' and bus_control_dato = '1' then

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '0') then

                     case bus_addr(2 downto 1) is
                        when "00" =>
                           if bus_dato(5) = '1' then
                              pcsr0_rset <= '1';
                           end if;

                           interrupt_trigger <= '0';

                           if pcsr0_inte /= bus_dato(6) then
                              pcsr0_inte <= bus_dato(6);
                           else
                              pcsr0_port_command <= bus_dato(3 downto 0);
                              pcsr0_dni <= '0';
                              pcsr0_pcmw <= '1';                               -- flag command written
                           end if;

                        when "10" =>
                           pcsr2_pcbb(7 downto 1) <= bus_dato(7 downto 1);

                        when "11" =>
                           pcsr3_pcbb <= bus_dato(1 downto 0);

                        when others =>
                           null;

                     end case;
                  end if;

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '1') then

                     case bus_addr(2 downto 1) is
                        when "00" =>

                           interrupt_trigger <= '0';

                           if bus_dato(15) = '1' then
                              pcsr0_seri <= '0';
                           end if;
                           if bus_dato(14) = '1' then
                              pcsr0_pcei <= '0';
                           end if;
                           if bus_dato(13) = '1' then
                              pcsr0_rxi <= '0';
                           end if;
                           if bus_dato(12) = '1' then
                              pcsr0_txi <= '0';
                           end if;
                           if bus_dato(11) = '1' then
                              pcsr0_dni <= '0';
                           end if;
                           if bus_dato(10) = '1' then
                              pcsr0_rcbi <= '0';
                           end if;
                           if bus_dato(8) = '1' then
                              pcsr0_usci <= '0';
                           end if;

                        when "10" =>
                           pcsr2_pcbb(15 downto 8) <= bus_dato(15 downto 8);

                        when others =>
                           null;

                     end case;
                  end if;

               end if;

-- register read access from the xu cpu to the xu registers
               if local_addr_match = '1' and localunibus_control_dati = '1' then

                  case localunibus_addr(2 downto 1) is
                     when "00" =>
                        xu_dati <= pcsr0_seri & pcsr0_pcei & pcsr0_rxi & pcsr0_txi & pcsr0_dni & pcsr0_rcbi & "0" & pcsr0_usci
                           & pcsr0_intr & pcsr0_inte & pcsr0_rset & pcsr0_pcmw & pcsr0_port_command;

                     when "01" =>
                        xu_dati <= pcsr1_xpwr & pcsr1_icab & pcsr1_self_test & pcsr1_pcto & "000" & pcsr1_state;

                     when "10" =>
                        xu_dati <= pcsr2_pcbb & "0";

                     when "11" =>
                        xu_dati <= "00000000000000" & pcsr3_pcbb;

                     when others =>
                        xu_dati <= (others => '0');

                  end case;
               end if;

-- register write access from the xu cpu to the xu registers
               if local_addr_match = '1' and localunibus_control_dato = '1' then

                  if localunibus_control_datob = '0' or (localunibus_control_datob = '1' and localunibus_addr(0) = '0') then

                     case localunibus_addr(2 downto 1) is
                        when "00" =>
                           if localunibus_control_datob = '1' then
                              pcsr0_pcmw <= '0';                     -- a byte write into the low byte resets the command written bit
                              pcsr0_rset <= '0';                     -- a byte write into the low byte resets the rset bit
                           end if;

                        when "01" =>
                           pcsr1_state <= localunibus_dato(3 downto 0);

                        when others =>
                           null;

                     end case;
                  end if;

                  if localunibus_control_datob = '0' or (localunibus_control_datob = '1' and localunibus_addr(0) = '1') then

                     case localunibus_addr(2 downto 1) is
                        when "00" =>
                           pcsr0_seri <= localunibus_dato(15);
                           pcsr0_pcei <= localunibus_dato(14);
                           pcsr0_rxi <= localunibus_dato(13);
                           pcsr0_txi <= localunibus_dato(12);
                           pcsr0_dni <= localunibus_dato(11);
                           pcsr0_rcbi <= localunibus_dato(10);
                           pcsr0_usci <= localunibus_dato(8);

                        when others =>
                           null;

                     end case;
                  end if;

               end if;
            end if;

         end if;
      end if;
   end process;

end implementation;

