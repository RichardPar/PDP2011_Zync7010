--
-- bringup_diag.vhd - bring-up diagnostics GPIO + LED. Extracted out of
-- zynq_top.vhd's architecture (2026-09-04) so the top level isn't one giant
-- file; logic is unchanged from what was proven on real hardware, just
-- moved and wrapped in its own entity.
--
-- Added 2026-08 when the first real hardware test had a dead console:
-- clk50mhz/cpuclk/ifetch liveness, plus unibus.vhd's own pre-existing
-- dev_rd/dev_wr/dma_wr debug taps, all brought into aclk via a plain 2-FF
-- synchronizer (status bits sampled by software, not control signals - a
-- synchronizer is sufficient, no need for the stricter dati/cpuclk
-- edge-alignment ddr_mem.vhd's own read path requires) and exposed as a
-- devmem-readable GPIO: [0]=clk50mhz alive [1]=cpuclk alive [2]=ifetch
-- [3]=aresetn [4]=dev_rd(I/O-page read) [5]=dev_wr(I/O-page write)
-- [6]=dma_wr(RL11 OR RH11 DMA write, ORed via seen_dmawr).
--
-- seen_devrd/seen_devwr/seen_dmawr come from front_panel.vhd (it already
-- computes the same activity bits for its own status row, once per ~250ms
-- display period - no need to duplicate that detection here).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity bringup_diag is
   port(
      clk50mhz : in std_logic;
      cpuclk   : in std_logic;
      aclk     : in std_logic;
      aresetn  : in std_logic;                       -- active-low, from PS reset
      ifetch   : in std_logic;

      -- activity bits from front_panel.vhd, already latched once per its
      -- own ~250ms display period
      seen_devrd : in std_logic;
      seen_devwr : in std_logic;
      seen_dmawr : in std_logic;

      led_n      : out std_logic;                    -- H17, active-low, ~0.75Hz blink driven by clk50mhz
      dbg_status : out std_logic_vector(6 downto 0)
   );
end bringup_diag;

architecture implementation of bringup_diag is

   signal clk50_toggle : std_logic := '0';
   signal cpuclk_toggle : std_logic := '0';
   signal led_counter : std_logic_vector(25 downto 0) := (others => '0');

   signal sync50  : std_logic_vector(1 downto 0) := (others => '0');
   signal synccpu : std_logic_vector(1 downto 0) := (others => '0');
   signal syncife : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdevrd : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdevwr : std_logic_vector(1 downto 0) := (others => '0');
   signal syncdmawr : std_logic_vector(1 downto 0) := (others => '0');

begin

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
         -- seen_* only change once per ~250ms period (front_panel.vhd's own
         -- display tick) - a plain 2-FF sync is more than sufficient, no
         -- edge-detect needed here
         syncdevrd <= syncdevrd(0) & seen_devrd;
         syncdevwr <= syncdevwr(0) & seen_devwr;
         syncdmawr <= syncdmawr(0) & seen_dmawr;
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

end implementation;
