--
-- neopixel_driver.vhd - WS2812B ("NeoPixel") single-wire RGB LED driver.
--
-- Free-running: continuously re-sends grb_data (whatever it currently is)
-- followed by a reset/latch gap, forever - no start/trigger handshake
-- needed. Anything driving grb_data can just change it asynchronously
-- (synchronous to clk) and the new colors show up on the next frame,
-- ~every (num_leds*24*63 + reset_cycles) clk cycles - at clk=50MHz and
-- num_leds=7, that's ~(7*24*63+4000)/50e6 ~= 0.29ms per frame, far faster
-- than anything a human needs to see.
--
-- Bit layout of grb_data: LED 0 in bits (23 downto 0), LED 1 in
-- (47 downto 24), etc. - each 24-bit slice is 8 bits green, 8 bits red,
-- 8 bits blue (WS2812's native GRB order), MSB-first per byte, per the
-- WS2812B datasheet's serial protocol.
--
-- Timing (for clk = 50 MHz, 20ns/cycle - see generics if driven from a
-- different clock): T0H=20cyc(0.4us) T0L=43cyc(0.86us), T1H=40cyc(0.8us)
-- T1L=23cyc(0.46us) - both bit periods land on 63 cycles (1.26us),
-- comfortably inside the WS2812B datasheet's +-150ns tolerance. Reset gap
-- default 4000 cycles (80us), well over the >=50us the datasheet requires.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity neopixel_driver is
   generic(
      num_leds      : integer := 7;
      t0h_cycles    : integer := 20;
      t0l_cycles    : integer := 43;
      t1h_cycles    : integer := 40;
      t1l_cycles    : integer := 23;
      reset_cycles  : integer := 4000
   );
   port(
      clk      : in  std_logic;
      grb_data : in  std_logic_vector(num_leds * 24 - 1 downto 0);
      dout     : out std_logic
   );
end neopixel_driver;

architecture implementation of neopixel_driver is

   type state_type is (st_bit_high, st_bit_low, st_reset_gap);
   signal state : state_type := st_bit_high;

   signal led_i  : integer range 0 to num_leds - 1 := 0;
   signal bit_i  : integer range 0 to 23 := 23;
   signal cycle_cnt : integer range 0 to reset_cycles - 1 := 0;

   signal cur_bit : std_logic;
   signal dout_i  : std_logic := '0';

begin

   dout <= dout_i;

   cur_bit <= grb_data(led_i * 24 + bit_i);

   process(clk)
   begin
      if rising_edge(clk) then
         case state is

            when st_bit_high =>
               dout_i <= '1';
               if (cur_bit = '0' and cycle_cnt = t0h_cycles - 1) or
                  (cur_bit = '1' and cycle_cnt = t1h_cycles - 1) then
                  cycle_cnt <= 0;
                  state     <= st_bit_low;
               else
                  cycle_cnt <= cycle_cnt + 1;
               end if;

            when st_bit_low =>
               dout_i <= '0';
               if (cur_bit = '0' and cycle_cnt = t0l_cycles - 1) or
                  (cur_bit = '1' and cycle_cnt = t1l_cycles - 1) then
                  cycle_cnt <= 0;
                  if bit_i = 0 then
                     bit_i <= 23;
                     if led_i = num_leds - 1 then
                        led_i <= 0;
                        state <= st_reset_gap;
                     else
                        led_i <= led_i + 1;
                        state <= st_bit_high;
                     end if;
                  else
                     bit_i <= bit_i - 1;
                     state <= st_bit_high;
                  end if;
               else
                  cycle_cnt <= cycle_cnt + 1;
               end if;

            when st_reset_gap =>
               dout_i <= '0';
               if cycle_cnt = reset_cycles - 1 then
                  cycle_cnt <= 0;
                  bit_i     <= 23;
                  state     <= st_bit_high;
               else
                  cycle_cnt <= cycle_cnt + 1;
               end if;

         end case;
      end if;
   end process;

end implementation;
