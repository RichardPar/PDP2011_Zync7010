--
-- front_panel.vhd - 8x8 WS2812 ("NeoPixel") front panel, a PDP-11
-- "blinkenlights" console. Extracted out of zynq_top.vhd's architecture
-- (2026-09-04) so the top level isn't one giant file; logic is unchanged
-- from what was proven on real hardware, just moved and wrapped in its own
-- entity. Port names match the CPU-bus signal names zynq_top already used
-- internally (addr/dati/dato/control_dati/control_dato/cpureset/ifetch/
-- dbg_dev_rd/dbg_dev_wr/dbg_dma_wr/dbg_dma_rh_wr), so the body below is a
-- verbatim copy of the original process/generate logic.
--
-- Single data wire (neo_dout). Logical layout (row 0 = top): row 0 = 8
-- status lights (RUN, cpuclk, ifetch, mem-read, mem-write, I/O-page, DMA,
-- panel-heartbeat) - DMA is colour-coded, amber for RL11/RL02 vs magenta for
-- RH11/RP06; rows 1-3 = the 22-bit unibus ADDRESS register (amber, flickers
-- as the CPU runs); rows 4-5 = 16-bit DATA register (green); rows 6-7 = the
-- PC (blue, the bus address latched at each ifetch). Replaced the earlier
-- 7-LED bring-up ring (rainbow test + cpuclk/ifetch/reset lights) once the
-- port was proven. Wiring is for a CJMCU-64 (chain runs down columns,
-- left->right, top-left start) - see chain_to_logical in the body.
--
-- seen_devrd/seen_devwr/seen_dmawr are the same activity bits the panel's
-- own status row uses, exposed as outputs too so zynq_top can still feed the
-- bring-up dbg_status GPIO from them (see bringup_diag.vhd) without
-- duplicating the CPU-bus activity detection.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity front_panel is
   port(
      clk50mhz : in std_logic;                              -- ~50 MHz, all panel logic runs here
      cpuclk   : in std_logic;                              -- for the "cpuclk alive" status light

      -- CPU-bus taps (cpuclk/nclk domain signals, single-FF captured below -
      -- this is a display, so transient tearing is invisible)
      cpureset      : in std_logic;
      ifetch        : in std_logic;
      addr          : in std_logic_vector(21 downto 0);
      dati          : in std_logic_vector(15 downto 0);
      dato          : in std_logic_vector(15 downto 0);
      control_dati  : in std_logic;
      control_dato  : in std_logic;
      dbg_dev_rd    : in std_logic;
      dbg_dev_wr    : in std_logic;
      dbg_dma_wr    : in std_logic;
      dbg_dma_rh_wr : in std_logic;

      neo_dout : out std_logic;                              -- T11

      -- activity bits, latched once per ~250ms display period - same ones
      -- the status row itself lights up from. bringup_diag.vhd 2-FF
      -- synchronizes these into aclk for the dbg_status GPIO.
      seen_devrd : out std_logic;
      seen_devwr : out std_logic;
      seen_dmawr : out std_logic
   );
end front_panel;

architecture implementation of front_panel is

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

   -- free-running toggle in the cpuclk domain, synchronized into clk50mhz
   -- below - a true "is cpuclk physically toggling" liveness check for the
   -- status row, independent of whether the bus is doing anything (this is
   -- the same diagnostic that caught the CPU-never-actually-reset bug during
   -- bring-up - see README "Bring-up notes" / ddr_mem.vhd - so it stays a
   -- real clock-domain toggle, not bus activity).
   signal cpuclk_toggle : std_logic := '0';

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

   process(cpuclk)
   begin
      if rising_edge(cpuclk) then
         cpuclk_toggle <= not cpuclk_toggle;
      end if;
   end process;

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
            seen_devrd <= neo_activity_devrd;
            seen_devwr <= neo_activity_devwr;
            seen_dmawr <= neo_activity_dmawr or neo_activity_dmawr_rh;

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
