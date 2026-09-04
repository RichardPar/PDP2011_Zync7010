--
-- ddr_mem.vhd - PDP-11 bus to Zynq PS DDR3 bridge, via S_AXI_HP0
--
-- Fresh design (not a copy of the earlier, now-deleted Zynq attempt), but it
-- deliberately encodes lessons from that attempt's post-mortem:
--
--   * Same contract as psram_bridge.vhd (Tang Nano) / sdram.vhd (upstream):
--     this module OWNS cpuclk and cpureset for the unibus core. It generates
--     a clean, generated cpuclk with no fixed frequency requirement anywhere
--     else in the core (the KL11 UART baud generator and sdspi bit clock are
--     driven from the separate, free-running clk50mhz input, NOT cpuclk -
--     only the CPU/bus logic itself rides this gated clock).
--
--   * UNLIKE psram_bridge, the memory op latency here is NOT fixed (AXI
--     handshake to DDR3 through the PS varies with arbitration/refresh), so
--     this is a handshake-driven FSM, not a fixed counter with a generous
--     fixed window.
--
--   * Known bug class from the earlier attempt, avoided here from the start:
--     do not let the read data (dati) and the rising edge of the generated
--     cpuclk (which the CPU samples dati on) transition on the same clock
--     edge of the underlying AXI-domain clock. There must be a full settle
--     cycle where dati is already stable BEFORE cpuclk rises. (Found the
--     hard way via ILA + independent devmem cross-check in the earlier
--     project: without this settle cycle, CPU-issued reads intermittently
--     see the previous read's value - "one-behind" - while DMA/devmem paths,
--     which don't share this generated-clock race, read correctly.)
--
-- Address mapping: unibus's addr is a 22-bit BYTE address (4 MB physical
-- space - the pdp2011 core's real ceiling, see mmu.vhd). S_AXI_HP0 here is
-- configured 32 bits wide, so two 16-bit PDP-11 words share each AXI word;
-- axi_addr = ddr_base + addr(21 downto 2)&"00", and addr(1) selects which
-- 16-bit half of the 32-bit AXI word is in play. Byte ops (control_datob)
-- further select which byte of that half via addr(0) and WSTRB.
--
-- ddr_base is a generic (see zynq_top.vhd) - the whole 4 MB PDP-11 space is
-- placed at the bottom of an 8 MB no-map carve-out at the top of DDR3, so
-- Linux/the device tree reserve 8 MB but this core only ever touches the
-- bottom 4 MB of that window (headroom for later growth without redoing the
-- reserved-memory node).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity ddr_mem is
   generic(
      ddr_base : std_logic_vector(31 downto 0) := x"1F800000";

      -- minimum high/low hold, in aclk cycles, for the generated cpuclk when
      -- no memory op is pending this bus cycle (keeps a clean, bounded-
      -- frequency clock for the CPU's non-memory cycles; stretched further
      -- automatically whenever a real AXI transaction is in flight)
      min_half_cycles : integer := 4
   );
   port(
      -- PDP-11 memory bus (unibus.vhd side)
      addr          : in  std_logic_vector(21 downto 0);
      dati          : out std_logic_vector(15 downto 0);
      dato          : in  std_logic_vector(15 downto 0);
      control_dati  : in  std_logic;
      control_dato  : in  std_logic;
      control_datob : in  std_logic;
      addr_match    : in  std_logic;

      cpureset      : out std_logic;    -- -> unibus.reset (active '1')
      cpuclk        : out std_logic;    -- -> unibus.clk

      -- debug
      o_ready       : out std_logic;
      o_attempt     : out std_logic;

      -- AXI-domain clock/reset
      aclk          : in  std_logic;    -- e.g. FCLK0, 100 MHz
      aresetn       : in  std_logic;

      -- AXI4 master, single-beat only (AxLEN tied to 0) - routed through an
      -- AXI4->AXI3 protocol converter to S_AXI_HP0 at the BD level, since
      -- Zynq-7000 HP ports are AXI3-only
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
end ddr_mem;

architecture implementation of ddr_mem is

   type state_type is (
      st_reset,
      st_idle,       -- cpuclk low, minimum-low counter running
      st_sample,     -- decide: plain cycle, or start an AXI op
      st_raddr,      -- ARVALID asserted, waiting ARREADY
      st_rdata,      -- waiting RVALID
      st_read_settle,-- one full aclk cycle: dati already latched, cpuclk still low
      st_waddr,      -- AWVALID/WVALID asserted, waiting AWREADY/WREADY (independently)
      st_wresp,      -- waiting BVALID
      st_rise,       -- cpuclk <= '1'
      st_high        -- minimum-high counter running
   );
   signal state : state_type := st_idle;

   signal half_cnt   : integer range 0 to min_half_cycles - 1 := 0;
   signal rstcnt     : integer range 0 to 63 := 63;

   signal cpuclk_i   : std_logic := '0';
   signal cpureset_i : std_logic := '1';
   signal dati_i     : std_logic_vector(15 downto 0) := (others => '0');

   signal awready_seen : std_logic;
   signal wready_seen  : std_logic;

   signal attempt : std_logic := '0';

   signal axi_word_addr : std_logic_vector(31 downto 0);

begin

   cpuclk   <= cpuclk_i;
   cpureset <= cpureset_i;
   dati     <= dati_i;
   o_attempt <= attempt;

   axi_word_addr <= ddr_base + ("0000000000" & addr(21 downto 2) & "00");

   -- fixed AXI4 master boilerplate for a 4-byte, single-beat, non-cacheable
   -- transfer - identical on every op, so tie once outside the FSM
   m_axi_awlen   <= (others => '0');
   m_axi_awsize  <= "010";
   m_axi_awburst <= "01";
   m_axi_awprot  <= (others => '0');
   m_axi_awcache <= "0011";
   m_axi_arlen   <= (others => '0');
   m_axi_arsize  <= "010";
   m_axi_arburst <= "01";
   m_axi_arprot  <= (others => '0');
   m_axi_arcache <= "0011";
   m_axi_wlast   <= '1';

   process(aclk)
   begin
      if rising_edge(aclk) then

         if aresetn = '0' then
            state         <= st_idle;
            cpuclk_i      <= '0';
            cpureset_i    <= '1';
            rstcnt        <= 63;
            half_cnt      <= 0;
            o_ready       <= '0';
            attempt       <= '0';
            m_axi_awvalid <= '0';
            m_axi_wvalid  <= '0';
            m_axi_arvalid <= '0';
            -- Hold bready/rready HIGH during reset so any write/read response
            -- left in flight on S_AXI_HP0 gets drained. HP0 is on the PS reset
            -- domain and does NOT reset with this (scoped PDP-11-only) reset, so
            -- if we dropped bready/rready an un-acked response would desync HP0
            -- and the next memory access would hang - freezing the CPU on the
            -- re-boot (the "scoped reset only reads a few blocks then halts"
            -- bug). Draining here lets the PDP-11-only reset restart cleanly.
            m_axi_bready  <= '1';
            m_axi_rready  <= '1';

         else
            case state is

               -- kept only so the enum's choice is covered; the free-running
               -- clock loop below now owns power-on reset (see st_idle/st_high)
               when st_reset =>
                  state <= st_idle;

               -- minimum low-hold so cpuclk always has a clean, bounded-
               -- width low phase even on a plain (non-memory) bus cycle.
               -- cpuclk is low here, so this is also the only place power-on
               -- reset is released: the pdp2011 core's reset is SYNCHRONOUS to
               -- cpuclk (cpu.vhd loads r7<=init_r7 etc. only on a rising cpuclk
               -- edge while reset='1'), so cpuclk MUST free-run and reset MUST
               -- stay asserted across many rising edges before it drops.
               -- Dropping it here (cpuclk low) also means it never races an
               -- edge. Earlier this file held cpuclk static-low through reset
               -- and released it before the first edge, so the CPU was never
               -- actually reset and never fetched - the "no serial" bug.
               when st_idle =>
                  if cpureset_i = '1' and rstcnt = 0 then
                     cpureset_i <= '0';
                     o_ready    <= '1';
                  end if;
                  if half_cnt = min_half_cycles - 1 then
                     state <= st_sample;
                  else
                     half_cnt <= half_cnt + 1;
                  end if;

               when st_sample =>
                  if cpureset_i = '0' and addr_match = '1' and control_dati = '1' then
                     attempt       <= '1';
                     m_axi_araddr  <= axi_word_addr;
                     m_axi_arvalid <= '1';
                     state         <= st_raddr;
                  elsif cpureset_i = '0' and addr_match = '1' and control_dato = '1' then
                     attempt <= '1';
                     if addr(1) = '0' then
                        m_axi_wdata(15 downto 0) <= dato;
                        m_axi_wdata(31 downto 16) <= (others => '0');
                        if control_datob = '1' then
                           if addr(0) = '0' then
                              m_axi_wstrb <= "0001";
                           else
                              m_axi_wstrb <= "0010";
                           end if;
                        else
                           m_axi_wstrb <= "0011";
                        end if;
                     else
                        m_axi_wdata(31 downto 16) <= dato;
                        m_axi_wdata(15 downto 0) <= (others => '0');
                        if control_datob = '1' then
                           if addr(0) = '0' then
                              m_axi_wstrb <= "0100";
                           else
                              m_axi_wstrb <= "1000";
                           end if;
                        else
                           m_axi_wstrb <= "1100";
                        end if;
                     end if;
                     m_axi_awaddr  <= axi_word_addr;
                     m_axi_awvalid <= '1';
                     m_axi_wvalid  <= '1';
                     awready_seen  <= '0';
                     wready_seen   <= '0';
                     state         <= st_waddr;
                  else
                     state <= st_rise;
                  end if;

               -- read address phase
               when st_raddr =>
                  if m_axi_arready = '1' then
                     m_axi_arvalid <= '0';
                     m_axi_rready  <= '1';
                     state         <= st_rdata;
                  end if;

               when st_rdata =>
                  if m_axi_rvalid = '1' then
                     m_axi_rready <= '0';
                     if addr(1) = '0' then
                        dati_i <= m_axi_rdata(15 downto 0);
                     else
                        dati_i <= m_axi_rdata(31 downto 16);
                     end if;
                     state <= st_read_settle;
                  end if;

               -- dati_i is now stable; let a full aclk cycle pass before
               -- cpuclk rises, so the CPU's sampling edge never races the
               -- data becoming valid (the bug class this file's header
               -- warns about)
               when st_read_settle =>
                  state <= st_rise;

               -- write address/data phase - AWREADY and WREADY can arrive
               -- on different cycles, so latch each independently and only
               -- proceed once both have been seen
               when st_waddr =>
                  if m_axi_awready = '1' then
                     m_axi_awvalid <= '0';
                     awready_seen  <= '1';
                  end if;
                  if m_axi_wready = '1' then
                     m_axi_wvalid <= '0';
                     wready_seen  <= '1';
                  end if;
                  if (m_axi_awready = '1' or awready_seen = '1') and
                     (m_axi_wready = '1' or wready_seen = '1') then
                     m_axi_bready <= '1';
                     state        <= st_wresp;
                  end if;

               when st_wresp =>
                  if m_axi_bvalid = '1' then
                     m_axi_bready <= '0';
                     state        <= st_rise;
                  end if;

               when st_rise =>
                  cpuclk_i <= '1';
                  half_cnt <= 0;
                  state    <= st_high;

               when st_high =>
                  if half_cnt = min_half_cycles - 1 then
                     cpuclk_i <= '0';
                     half_cnt <= 0;
                     -- one rising cpuclk edge just completed; count it down
                     -- while still in reset so the CPU sees ~63 clean reset
                     -- edges before st_idle releases cpureset
                     if cpureset_i = '1' and rstcnt /= 0 then
                        rstcnt <= rstcnt - 1;
                     end if;
                     state    <= st_idle;
                  else
                     half_cnt <= half_cnt + 1;
                  end if;

            end case;
         end if;
      end if;
   end process;

end implementation;
