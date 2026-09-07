
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

-- AXI-Lite "virtual ESP32" backend (xuaxi.vhd) - active when have_xu_esp=1,
-- talks to pdp11-hostd on the Zynq PS instead of a physical ESP32 over SPI
      net_s_axi_aclk    : in  std_logic := '0';
      net_s_axi_aresetn : in  std_logic := '1';
      net_s_axi_awaddr  : in  std_logic_vector(15 downto 0) := (others => '0');
      net_s_axi_awvalid : in  std_logic := '0';
      net_s_axi_awready : out std_logic;
      net_s_axi_wdata   : in  std_logic_vector(31 downto 0) := (others => '0');
      net_s_axi_wstrb   : in  std_logic_vector(3 downto 0) := (others => '0');
      net_s_axi_wvalid  : in  std_logic := '0';
      net_s_axi_wready  : out std_logic;
      net_s_axi_bresp   : out std_logic_vector(1 downto 0);
      net_s_axi_bvalid  : out std_logic;
      net_s_axi_bready  : in  std_logic := '0';
      net_s_axi_araddr  : in  std_logic_vector(15 downto 0) := (others => '0');
      net_s_axi_arvalid : in  std_logic := '0';
      net_s_axi_arready : out std_logic;
      net_s_axi_rdata   : out std_logic_vector(31 downto 0);
      net_s_axi_rresp   : out std_logic_vector(1 downto 0);
      net_s_axi_rvalid  : out std_logic;
      net_s_axi_rready  : in  std_logic := '0';
      net_irq           : out std_logic;

-- flags
      have_xu : in integer range 0 to 1 := 0;
      have_xu_debug : in integer range 0 to 1 := 1;
      have_xu_enc : in integer range 0 to 1 := 0;
      have_xu_esp : in integer range 0 to 1 := 0;

-- debug & blinkenlights
      tx : out std_logic;
      ifetch : out std_logic;
      iwait : out std_logic;

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

-- xuaxi: AXI-Lite "virtual ESP32" backend, a drop-in replacement for the
-- upstream xubf.vhd (physical bit-banged SPI to a real ESP32 - no longer
-- instantiated here, see docs/xu-networking-plan.md). Same XF/RT/RL/SRDY
-- register contract on the local unibus, but the SPI pins are replaced by
-- an AXI-Lite slave + irq to a Linux daemon (pdp11-hostd) on the Zynq PS.
component xuaxi is
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

      have_xu_esp : in integer range 0 to 1 := 0;

      -- diagnostic-only taps into xu.vhd's PCSR0/PCSR1 (the guest-visible
      -- DEUNA control/status registers) and its own OUTER (main-unibus-
      -- facing) npr/npg - see the DEBUG2 register comment below.
      dbg_pcsr0 : in std_logic_vector(15 downto 0) := (others => '0');
      dbg_pcsr1_state : in std_logic_vector(3 downto 0) := (others => '0');
      dbg_outer_npr : in std_logic := '0';
      dbg_outer_npg : in std_logic := '0';
      dbg_ifetch : in std_logic := '0';
      dbg_xubm_npr : in std_logic := '0';
      dbg_xubm_npg : in std_logic := '0';
      dbg_cpu_npr : in std_logic := '0';
      dbg_cpu_npg : in std_logic := '0';

      s_axi_aclk    : in  std_logic;
      s_axi_aresetn : in  std_logic;
      s_axi_awaddr  : in  std_logic_vector(15 downto 0);
      s_axi_awvalid : in  std_logic;
      s_axi_awready : out std_logic;
      s_axi_wdata   : in  std_logic_vector(31 downto 0);
      s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      s_axi_wvalid  : in  std_logic;
      s_axi_wready  : out std_logic;
      s_axi_bresp   : out std_logic_vector(1 downto 0);
      s_axi_bvalid  : out std_logic;
      s_axi_bready  : in  std_logic;
      s_axi_araddr  : in  std_logic_vector(15 downto 0);
      s_axi_arvalid : in  std_logic;
      s_axi_arready : out std_logic;
      s_axi_rdata   : out std_logic_vector(31 downto 0);
      s_axi_rresp   : out std_logic_vector(1 downto 0);
      s_axi_rvalid  : out std_logic;
      s_axi_rready  : in  std_logic;

      irq : out std_logic;

      reset : in std_logic;
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
signal xubl_npg : std_logic;

signal localunibus_busmaster_xubl_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_xubl_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_xubl_control_dati : std_logic;
signal localunibus_busmaster_xubl_control_dato : std_logic;

-- xuaxi (AXI-Lite "virtual ESP32" backend) replaces xubf's physical SPI
-- pins (xubf_cs/mosi/sclk/miso/srdy - no longer needed) but keeps the same
-- local-unibus addr_match/dati/npr + bus-master shape every other frontend
-- here uses.
signal xuaxi_addr_match : std_logic;
signal xuaxi_dati : std_logic_vector(15 downto 0);
signal xuaxi_npr : std_logic;
signal xuaxi_npg : std_logic;

signal localunibus_busmaster_xuaxi_addr : std_logic_vector(17 downto 0);
signal localunibus_busmaster_xuaxi_dato : std_logic_vector(15 downto 0);
signal localunibus_busmaster_xuaxi_control_dati : std_logic;
signal localunibus_busmaster_xuaxi_control_dato : std_logic;

signal xubm_addr_match : std_logic;
-- shadow of the top-level 'npr' OUTPUT port, needed only because VHDL
-- forbids reading back an out-mode port from within its own architecture -
-- xubm0 still drives the real npr output directly (see 'npr <= xubm_outer_npr'
-- below); this exists solely so the DEBUG2 diagnostic tap can see the same
-- value.
signal xubm_outer_npr : std_logic;
signal xubm_dati : std_logic_vector(15 downto 0);
signal xubm_npr : std_logic;
signal xubm_npg : std_logic;

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
      npg => xubl_npg,

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


   xuaxi0: xuaxi port map(
      base_addr => o"777000",

      npr => xuaxi_npr,
      npg => xuaxi_npg,

      bus_addr_match => xuaxi_addr_match,
      bus_addr => localunibus_addr,
      bus_dati => xuaxi_dati,
      bus_dato => localunibus_dato,
      bus_control_dati => localunibus_control_dati,
      bus_control_dato => localunibus_control_dato,
      bus_control_datob => localunibus_control_datob,

      bus_master_addr => localunibus_busmaster_xuaxi_addr,
      bus_master_dati => localunibus_busmaster_dati,
      bus_master_dato => localunibus_busmaster_xuaxi_dato,
      bus_master_control_dati => localunibus_busmaster_xuaxi_control_dati,
      bus_master_control_dato => localunibus_busmaster_xuaxi_control_dato,
      bus_master_nxm => localbusmaster_nxmabort,

      have_xu_esp => have_xu_esp,

      -- diagnostic-only taps, straight off the existing pcsr0/pcsr1 signals
      -- and xu.vhd's own OUTER (main-unibus-facing) npr/npg entity ports -
      -- see the DEBUG2 register comment in xuaxi.vhd for why these were
      -- added and what each field means.
      dbg_pcsr0 => pcsr0_seri & pcsr0_pcei & pcsr0_rxi & pcsr0_txi & pcsr0_dni & pcsr0_rcbi & "0" & pcsr0_usci
         & pcsr0_intr & pcsr0_inte & pcsr0_rset & pcsr0_pcmw & pcsr0_port_command,
      dbg_pcsr1_state => pcsr1_state,
      dbg_outer_npr => xubm_outer_npr,
      dbg_outer_npg => npg,
      dbg_ifetch => ifetchcopy,
      dbg_xubm_npr => xubm_npr,
      dbg_xubm_npg => xubm_npg,
      dbg_cpu_npr => cpu_npr,
      dbg_cpu_npg => cpu_npg,

      s_axi_aclk    => net_s_axi_aclk,
      s_axi_aresetn => net_s_axi_aresetn,
      s_axi_awaddr  => net_s_axi_awaddr,
      s_axi_awvalid => net_s_axi_awvalid,
      s_axi_awready => net_s_axi_awready,
      s_axi_wdata   => net_s_axi_wdata,
      s_axi_wstrb   => net_s_axi_wstrb,
      s_axi_wvalid  => net_s_axi_wvalid,
      s_axi_wready  => net_s_axi_wready,
      s_axi_bresp   => net_s_axi_bresp,
      s_axi_bvalid  => net_s_axi_bvalid,
      s_axi_bready  => net_s_axi_bready,
      s_axi_araddr  => net_s_axi_araddr,
      s_axi_arvalid => net_s_axi_arvalid,
      s_axi_arready => net_s_axi_arready,
      s_axi_rdata   => net_s_axi_rdata,
      s_axi_rresp   => net_s_axi_rresp,
      s_axi_rvalid  => net_s_axi_rvalid,
      s_axi_rready  => net_s_axi_rready,

      irq => net_irq,

      reset => xureset,
      clk => nclk
   );
   -- have_xu_esp now drives xuaxi (AXI-Lite/PS), not a physical SPI pin -
   -- xu_cs/sclk/mosi only ever reflect xubl (the ENC424J600 option) now.
   xu_cs <= xubl_cs when have_xu_enc = 1
      else '0';
   xu_sclk <= xubl_sclk when have_xu_enc = 1
      else '0';
   xu_mosi <= xubl_mosi when have_xu_enc = 1
      else '0';

   xubm0: xubm port map(
      base_addr => o"777100",

      npr => xubm_outer_npr,
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
      localbus_npg => xubm_npg,

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
      else xuaxi_dati when xuaxi_addr_match = '1'
      else xubm_dati when xubm_addr_match = '1'
      else xu_dati when local_addr_match = '1'
      else "0000000000000000";

   localunibus_addr_match <= '1'
      when cr_addr_match = '1'
      or kl0_addr_match = '1'
      or kw0_addr_match = '1'
      or xubl_addr_match = '1'
      or xuaxi_addr_match = '1'
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
      else localunibus_busmaster_xuaxi_addr when cpu_npg = '1' and xuaxi_npr = '1'
      else localunibus_busmaster_xubm_addr when cpu_npg = '1' and xubm_npr = '1'
      else "000000000000000000";
   localunibus_busmaster_dato <= localunibus_busmaster_xubl_dato when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xuaxi_dato when cpu_npg = '1' and xuaxi_npr = '1'
      else localunibus_busmaster_xubm_dato when cpu_npg = '1' and xubm_npr = '1'
      else "0000000000000000";
   localunibus_busmaster_control_dati <= localunibus_busmaster_xubl_control_dati when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xuaxi_control_dati when cpu_npg = '1' and xuaxi_npr = '1'
      else localunibus_busmaster_xubm_control_dati when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_dato <= localunibus_busmaster_xubl_control_dato when cpu_npg = '1' and xubl_npr = '1'
      else localunibus_busmaster_xuaxi_control_dato when cpu_npg = '1' and xuaxi_npr = '1'
      else localunibus_busmaster_xubm_control_dato when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_datob <= '0' when cpu_npg = '1' and xubl_npr = '1'
      else '0' when cpu_npg = '1' and xuaxi_npr = '1'
      else '0' when cpu_npg = '1' and xubm_npr = '1'
      else '0';
   localunibus_busmaster_control_npg <= '1' when cpu_npg = '1' and xubl_npr = '1'
      else '1' when cpu_npg = '1' and xuaxi_npr = '1'
      else '1' when cpu_npg = '1' and xubm_npr = '1'
      else '0';

   cpu_npr <= '1' when xubl_npr = '1' or xuaxi_npr = '1' or xubm_npr = '1' else '0';

   -- Per-master grant, mirroring the priority mux above exactly (xubl >
   -- xuaxi > xubm). cpu_npg alone is a SHARED, undifferentiated grant line -
   -- feeding it raw into every requester's own npg port (as this file did
   -- originally) means a lower-priority master whose npr happens to overlap
   -- a higher-priority master's npr sees npg='1' on its own port and
   -- believes it has been granted the bus, even though the mux above is
   -- actually routing a DIFFERENT master's address/data onto the shared
   -- local bus that cycle - silently corrupting/desyncing the loser's
   -- transfer with no abort, no error, nothing observable from the PS side.
   -- This was latent and never exercised before this session (have_xu was
   -- always 0), and only became reachable once xuaxi0 introduced a second
   -- real local-bus master alongside xubm0's own outer<->inner bridging.
   xubl_npg  <= '1' when cpu_npg = '1' and xubl_npr = '1' else '0';
   xuaxi_npg <= '1' when cpu_npg = '1' and xubl_npr = '0' and xuaxi_npr = '1' else '0';
   xubm_npg  <= '1' when cpu_npg = '1' and xubl_npr = '0' and xuaxi_npr = '0' and xubm_npr = '1' else '0';

   bus_master_addr <= xubm_addr;
   bus_master_dato <= xubm_dato;
   bus_master_control_dati <= xubm_control_dati;
   bus_master_control_dato <= xubm_control_dato;
   npr <= xubm_outer_npr;

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

            br <= '0';
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

         else
            if have_xu = 1 then

               case interrupt_state is

                  when i_idle =>

                     br <= '0';
                     if pcsr0_inte = '1' and pcsr0_intr = '1' then
                        if interrupt_trigger = '0' then
                           interrupt_state <= i_req;
                           br <= '1';
                           interrupt_trigger <= '1';
                        end if;
                     else
                        interrupt_trigger <= '0';
                     end if;

                  when i_req =>
                     if bg = '1' then
                        int_vector <= ivec;
                        br <= '0';
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
               br <= '0';
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

