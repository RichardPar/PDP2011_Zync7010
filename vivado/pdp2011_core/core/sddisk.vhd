--
-- sddisk.vhd - AXI-Lite disk backend, a drop-in replacement for sdspi.vhd.
--
-- Presents the SAME controller-facing block interface to the pdp2011 disk
-- controllers (rl11 etc.) that sdspi does: sdcard_addr, the read/write
-- start/ack/done handshake, and the 256-word (512-byte) rsector/wsector
-- buffers. Instead of bit-banging a physical SD card, the sector data is
-- served by a Linux daemon (pdp11-hostd) on the PS. This module is an AXI-Lite
-- slave with an interrupt:
--   * block read : the controller asserts read_start; this module latches the
--     block number, raises the interrupt, and waits. The daemon reads the block
--     from the image file, writes 512 bytes into rsector over AXI, then writes
--     the DONE register; this module then asserts read_done and the controller
--     reads the 256 words out of rsector.
--   * block write: the controller fills wsector (xfer) then asserts write_start;
--     this module latches the block number, raises the interrupt, and waits.
--     The daemon reads wsector over AXI, writes the block to the file, then
--     writes DONE; this module asserts write_done.
--
-- The controller-facing process (the cpuclk<->backend handshake with filters
-- and 2-FF synchronisers, and the rsector/wsector buffers) is kept identical to
-- sdspi.vhd; only the SPI state machine is replaced by the AXI/daemon backend,
-- which runs on s_axi_aclk. The unused SPI pins are kept on the entity so the
-- rl11/unibus plumbing above this module is unchanged.
--
-- AXI-Lite register map (32-bit data, byte addresses):
--   0x000..0x3FC  sector buffer, one 16-bit word per 32-bit location (low half,
--                 index = addr[9:2]). A WRITE stores into rsector (read-data
--                 staging, daemon->core); a READ returns wsector (write-data,
--                 core->daemon).
--   0x800  STATUS (read)  bit0 = request pending, bit1 = is_write (0=read)
--   0x804  BLOCK  (read)  24-bit block number of the pending request
--   0x808  DONE   (write) daemon writes here when the transfer is complete;
--                         bit0 = error. Also de-asserts the interrupt.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity sddisk is
   port(
      -- unused SPI stubs (kept so the rl11/unibus SPI plumbing is unchanged)
      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic := '0';
      sdcard_debug : out std_logic_vector(3 downto 0);

      sdcard_addr : in std_logic_vector(23 downto 0);

      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;

      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);

      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;
      clk50mhz : in std_logic;                         -- unused (kept for pin-compat)

      -- AXI-Lite slave (PS / pdp11-hostd side)
      s_axi_aclk    : in  std_logic;
      s_axi_aresetn : in  std_logic;
      s_axi_awaddr  : in  std_logic_vector(11 downto 0);
      s_axi_awvalid : in  std_logic;
      s_axi_awready : out std_logic;
      s_axi_wdata   : in  std_logic_vector(31 downto 0);
      s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      s_axi_wvalid  : in  std_logic;
      s_axi_wready  : out std_logic;
      s_axi_bresp   : out std_logic_vector(1 downto 0);
      s_axi_bvalid  : out std_logic;
      s_axi_bready  : in  std_logic;
      s_axi_araddr  : in  std_logic_vector(11 downto 0);
      s_axi_arvalid : in  std_logic;
      s_axi_arready : out std_logic;
      s_axi_rdata   : out std_logic_vector(31 downto 0);
      s_axi_rresp   : out std_logic_vector(1 downto 0);
      s_axi_rvalid  : out std_logic;
      s_axi_rready  : in  std_logic;

      irq : out std_logic
   );
end sddisk;

architecture implementation of sddisk is

   type buffer_type is array(0 to 255) of std_logic_vector(15 downto 0);
   signal rsector : buffer_type;                       -- daemon -> core (read data)
   signal wsector : buffer_type;                       -- core -> daemon (write data)

   -- controller-facing handshake (identical to sdspi.vhd)
   constant filter_in_size : integer := 4;
   subtype filter_in_t is std_logic_vector(filter_in_size-1 downto 0);
   constant filter_out_size : integer := 4;
   subtype filter_out_t is std_logic_vector(filter_out_size-1 downto 0);

   signal idle_filter : filter_out_t;
   signal read_start_filter : filter_in_t;
   signal read_ack_filter : filter_in_t;
   signal read_done_filter : filter_out_t;
   signal write_start_filter : filter_in_t;
   signal write_ack_filter : filter_in_t;
   signal write_done_filter : filter_out_t;
   signal card_error_filter : filter_out_t;

   signal idle : std_logic := '0';
   signal read_start : std_logic;
   signal read_ack : std_logic;
   signal read_done : std_logic := '0';
   signal write_start : std_logic;
   signal write_ack : std_logic;
   signal write_done : std_logic := '0';
   signal card_error : std_logic := '0';

   -- 2-FF synchronisers into the s_axi_aclk (backend) domain
   signal read_start_s  : std_logic_vector(1 downto 0) := "00";
   signal read_ack_s    : std_logic_vector(1 downto 0) := "00";
   signal write_start_s : std_logic_vector(1 downto 0) := "00";
   signal write_ack_s   : std_logic_vector(1 downto 0) := "00";

   -- backend / daemon-request FSM (s_axi_aclk domain)
   type bstate_t is (b_idle, b_read_wait, b_read_done, b_write_wait, b_write_done);
   signal bstate : bstate_t := b_idle;
   signal req_pending : std_logic := '0';
   signal req_is_write : std_logic := '0';
   signal req_block : std_logic_vector(23 downto 0) := (others => '0');

   -- AXI-Lite slave state
   signal axi_awready : std_logic := '0';
   signal axi_wready  : std_logic := '0';
   signal axi_bvalid  : std_logic := '0';
   signal axi_arready : std_logic := '0';
   signal axi_rvalid  : std_logic := '0';
   signal axi_rdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal done_pulse  : std_logic := '0';               -- daemon wrote DONE this cycle
   signal done_error  : std_logic := '0';

begin

   -- SPI pins are unused in this backend
   sdcard_cs   <= '1';
   sdcard_mosi <= '1';
   sdcard_sclk <= '0';
   sdcard_debug <= "1000";

   s_axi_awready <= axi_awready;
   s_axi_wready  <= axi_wready;
   s_axi_bvalid  <= axi_bvalid;
   s_axi_bresp   <= "00";
   s_axi_arready <= axi_arready;
   s_axi_rvalid  <= axi_rvalid;
   s_axi_rdata   <= axi_rdata;
   s_axi_rresp   <= "00";

   irq <= req_pending;

   -- ============ controller-facing handshake (verbatim from sdspi.vhd) ============
   process(controller_clk)
   begin
      if controller_clk = '1' and controller_clk'event then
         if enable = 1 then
            sdcard_xfer_out <= rsector(sdcard_xfer_addr);
            if sdcard_xfer_write = '1' then
               wsector(sdcard_xfer_addr) <= sdcard_xfer_in;
            end if;

            idle_filter <= idle_filter(filter_out_t'high-1 downto 0) & idle;
            read_start_filter <= read_start_filter(filter_in_t'high-1 downto 0) & sdcard_read_start;
            read_ack_filter <= read_ack_filter(filter_in_t'high-1 downto 0) & sdcard_read_ack;
            read_done_filter <= read_done_filter(filter_out_t'high-1 downto 0) & read_done;
            write_start_filter <= write_start_filter(filter_in_t'high-1 downto 0) & sdcard_write_start;
            write_ack_filter <= write_ack_filter(filter_in_t'high-1 downto 0) & sdcard_write_ack;
            write_done_filter <= write_done_filter(filter_out_t'high-1 downto 0) & write_done;
            card_error_filter <= card_error_filter(filter_out_t'high-1 downto 0) & card_error;

            if reset = '1' then
               sdcard_idle <= '0';
               read_start <= '0';
               read_ack <= '0';
               sdcard_read_done <= '0';
               write_start <= '0';
               write_ack <= '0';
               sdcard_write_done <= '0';
               sdcard_error <= '0';
            else
               if idle_filter = filter_out_t'(others => '0') then
                  sdcard_idle <= '0';
               elsif idle_filter = filter_out_t'(others => '1') then
                  sdcard_idle <= '1';
               end if;

               if read_start_filter = filter_in_t'(others => '0') then
                  read_start <= '0';
               elsif read_start_filter = filter_in_t'(others => '1') then
                  read_start <= '1';
               end if;

               if read_ack_filter = filter_in_t'(others => '0') then
                  read_ack <= '0';
               elsif read_ack_filter = filter_in_t'(others => '1') then
                  read_ack <= '1';
               end if;

               if read_done_filter = filter_out_t'(others => '0') then
                  sdcard_read_done <= '0';
               elsif read_done_filter = filter_out_t'(others => '1') then
                  sdcard_read_done <= '1';
               end if;

               if write_start_filter = filter_in_t'(others => '0') then
                  write_start <= '0';
               elsif write_start_filter = filter_in_t'(others => '1') then
                  write_start <= '1';
               end if;

               if write_ack_filter = filter_in_t'(others => '0') then
                  write_ack <= '0';
               elsif write_ack_filter = filter_in_t'(others => '1') then
                  write_ack <= '1';
               end if;

               if write_done_filter = filter_out_t'(others => '0') then
                  sdcard_write_done <= '0';
               elsif write_done_filter = filter_out_t'(others => '1') then
                  sdcard_write_done <= '1';
               end if;

               if card_error_filter = filter_out_t'(others => '0') then
                  sdcard_error <= '0';
               elsif card_error_filter = filter_out_t'(others => '1') then
                  sdcard_error <= '1';
               end if;
            end if;
         end if;
      end if;
   end process;

   -- ============ AXI-Lite slave + daemon-request backend (s_axi_aclk) ============
   process(s_axi_aclk)
      variable widx : integer range 0 to 255;
      variable ridx : integer range 0 to 255;
   begin
      if rising_edge(s_axi_aclk) then
         done_pulse <= '0';

         if s_axi_aresetn = '0' then
            axi_awready <= '0';
            axi_wready  <= '0';
            axi_bvalid  <= '0';
            axi_arready <= '0';
            axi_rvalid  <= '0';
         else
            -- ---- AXI-Lite write channel ----
            if axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' and axi_bvalid = '0' then
               axi_awready <= '1';
               axi_wready  <= '1';
               widx := conv_integer(s_axi_awaddr(9 downto 2));
               if s_axi_awaddr(11) = '0' then
                  -- buffer window: write into rsector (daemon staging read data)
                  rsector(widx) <= s_axi_wdata(15 downto 0);
               else
                  -- register window: 0x808 = DONE
                  if s_axi_awaddr(3 downto 2) = "10" then
                     done_pulse <= '1';
                     done_error <= s_axi_wdata(0);
                  end if;
               end if;
               axi_bvalid <= '1';
            else
               axi_awready <= '0';
               axi_wready  <= '0';
               if axi_bvalid = '1' and s_axi_bready = '1' then
                  axi_bvalid <= '0';
               end if;
            end if;

            -- ---- AXI-Lite read channel ----
            if axi_arready = '0' and s_axi_arvalid = '1' and axi_rvalid = '0' then
               axi_arready <= '1';
               ridx := conv_integer(s_axi_araddr(9 downto 2));
               if s_axi_araddr(11) = '0' then
                  -- buffer window: return wsector (write data for the daemon)
                  axi_rdata <= x"0000" & wsector(ridx);
               else
                  case s_axi_araddr(3 downto 2) is
                     when "00" =>                        -- 0x800 STATUS
                        axi_rdata <= (others => '0');
                        axi_rdata(0) <= req_pending;
                        axi_rdata(1) <= req_is_write;
                     when "01" =>                        -- 0x804 BLOCK
                        axi_rdata <= x"00" & req_block;
                     when others =>
                        axi_rdata <= (others => '0');
                  end case;
               end if;
               axi_rvalid <= '1';
            else
               axi_arready <= '0';
               if axi_rvalid = '1' and s_axi_rready = '1' then
                  axi_rvalid <= '0';
               end if;
            end if;

            -- ---- daemon-request FSM ----
            read_start_s  <= read_start_s(0)  & read_start;
            read_ack_s    <= read_ack_s(0)    & read_ack;
            write_start_s <= write_start_s(0) & write_start;
            write_ack_s   <= write_ack_s(0)   & write_ack;

            if reset = '1' then
               bstate <= b_idle;
               idle <= '0';
               read_done <= '0';
               write_done <= '0';
               req_pending <= '0';
               card_error <= '0';
            else
               case bstate is
                  when b_idle =>
                     idle <= '1';
                     read_done <= '0';
                     write_done <= '0';
                     req_pending <= '0';
                     -- Trigger only when start is asserted AND neither ack is
                     -- still asserted. The ack guard (mirrors sdspi's sd_idle)
                     -- stops a completed transfer from re-triggering while the
                     -- controller is still tearing down the handshake and
                     -- read_start hasn't dropped yet - that re-trigger caused
                     -- occasional DUPLICATE reads of the same block and a
                     -- corrupt boot load.
                     if read_start_s(1) = '1'
                        and read_ack_s(1) = '0' and write_ack_s(1) = '0' then
                        idle <= '0';
                        req_block <= sdcard_addr;
                        req_is_write <= '0';
                        req_pending <= '1';
                        card_error <= '0';
                        bstate <= b_read_wait;
                     elsif write_start_s(1) = '1'
                        and read_ack_s(1) = '0' and write_ack_s(1) = '0' then
                        idle <= '0';
                        req_block <= sdcard_addr;
                        req_is_write <= '1';
                        req_pending <= '1';
                        card_error <= '0';
                        bstate <= b_write_wait;
                     end if;

                  when b_read_wait =>                    -- daemon fills rsector, writes DONE
                     if done_pulse = '1' then
                        req_pending <= '0';
                        card_error <= done_error;
                        read_done <= '1';
                        bstate <= b_read_done;
                     end if;

                  when b_read_done =>                    -- wait for the controller's ack
                     if read_ack_s(1) = '1' then
                        read_done <= '0';
                        bstate <= b_idle;
                     end if;

                  when b_write_wait =>                   -- daemon reads wsector, writes DONE
                     if done_pulse = '1' then
                        req_pending <= '0';
                        card_error <= done_error;
                        write_done <= '1';
                        bstate <= b_write_done;
                     end if;

                  when b_write_done =>
                     if write_ack_s(1) = '1' then
                        write_done <= '0';
                        bstate <= b_idle;
                     end if;
               end case;
            end if;
         end if;
      end if;
   end process;

end implementation;
