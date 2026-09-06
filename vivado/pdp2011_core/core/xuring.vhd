--
-- xuring.vhd - AXI-Lite + UIO bridge for xu.vhd's DEUNA descriptor-ring
-- packet engine.
--
-- Rebuilt (2026-09-06, see [[xu-ethernet-bridge]] memory for the full
-- history) after TWO different FPGA-side ring-walk designs both caused a
-- real, reproducible board hang, and both times xu.vhd's own debug state
-- showed the engine sitting idle at the moment of the freeze - evidence
-- the bug was never in the ring-walk logic itself. Rather than build a
-- third hardware state machine to debug blind, the ENTIRE descriptor-ring
-- algorithm (parsing the 4-word descriptor, the OWN-bit check, frame
-- assembly, ring-position bookkeeping) moved into pdp11-netd.c, where it
-- can be logged and fixed in seconds instead of guessed at through a
-- hardware debug register. All this bridge does now is expose ONE
-- generic "read or write a single PDP-11 memory word" primitive plus a
-- handful of small registers - the same DMA primitive Phase A's PCB/UDB
-- fetch in xu.vhd already uses reliably, just parameterized from the PS
-- side instead of driven by a fixed hardware sequence.
--
-- Every cross-domain signal here is a plain LEVEL with an explicit
-- 4-phase handshake (never a toggle/edge-detect): requester sets a level
-- and holds it; the other side acks with its own level once done;
-- requester drops its level once it sees the ack; the other side drops
-- its ack once it sees the request drop. This is provably glitch-free
-- regardless of relative clock speeds, and is the one part of this
-- effort that has NOT been implicated in either hang - keep using it.
--
-- AXI-Lite register map (32-bit, byte addresses, only the low bits of
-- each register are meaningful):
--   0x00  MEMADDR  (r/w) PDP-11 word address for the next single-word
--                  access (18 bits)
--   0x04  MEMDATA  (r/w) write the value before a WRITE op; read the
--                  result after a READ op completes
--   0x08  MEMCTL   write: bit0=req, bit1=is_write - set together to
--                  start an op; write 0 to acknowledge/clear once done
--                  (this is what lets the NEXT op start). read: bit0 =
--                  req echo, bit1 = done.
--   0x0C  TDRB     (read-only) TX ring base address, latched by WRF
--   0x10  TRLEN    (read-only) TX ring length, entries
--   0x14  RDRB     (read-only) RX ring base address, latched by WRF
--   0x18  RRLEN    (read-only) RX ring length, entries
--   0x1C  TXNEXT   (r/w) current TX ring position - software reads,
--                  advances, writes back; persists across a pdp11-netd
--                  restart since xu.vhd, not the daemon, owns the value
--   0x20  RXNEXT   (r/w) same, RX ring position
--   0x24  PCSR1STATE (read-only, low 4 bits) so software knows RUNNING
--   0x28  SET_TXI  write: any value requests a TXI strobe (4-phase,
--                  same pattern as MEMCTL); read: bit0=req echo
--   0x2C  SET_RXI  same, for RXI
--   0x30  DEBUG    (read-only) xucmd_state/pcsr1_state/etc, see xu.vhd's
--                  xu_debug_word comment, plus a free-running heartbeat
--   0x34  LASTCMD  (read-only) xu.vhd's xu_cmd_trace - last PCB function
--                  code / last port command / a rolling counter - see
--                  xu.vhd's xu_cmd_trace comment. Added to trace exactly
--                  which port commands actually arrive, after WRF
--                  appeared to never configure the ring despite START
--                  succeeding (see [[xu-ethernet-bridge]]).
--   0x38-0x54 HIST0-7 (read-only) 8-entry command history, xu.vhd's
--                  xu_cmd_hist - the real fix for LASTCMD's blind spot
--                  (a single snapshot can miss commands entirely during
--                  the driver's fast init burst)
--   0x58  HIST_WPTR (read-only, low 3 bits) current write pointer into
--                  HIST0-7 - software diffs this against its own last-
--                  seen value to find which entries are new
--   0x5C  IRQTRACE (read-only) xu.vhd's xu_irq_trace - br/bg/
--                  interrupt_trigger/pcsr0_inte/txi/rxi/dni/pcei/
--                  interrupt_state, see xu.vhd's xu_irq_trace comment.
--                  Manual-devmem-only diagnostic (not read by
--                  pdp11-netd) - added to check whether a real CPU
--                  interrupt is actually being delivered/serviced after
--                  the first successful TX/RX, since the driver's TX
--                  ring only frees up (destart() gets re-invoked) via
--                  deintr(), the real interrupt handler.
--                  in the high bits so a genuinely frozen system is
--                  distinguishable from one still ticking
--   0x60  PCTRACE (read-only) xu.vhd's xu_pc_trace - bit17 diag_cpu_ifetch
--                  (this bus cycle is an instruction fetch, not data -
--                  cpu_addr_v carries both), bit16 diag_cpu_iwait (the
--                  CPU's real 'iwait' output, set while executing the
--                  WAIT instruction), bits15:0 diag_cpu_addr_v (the
--                  CPU's live virtual address bus). Added to test
--                  whether the guest is wedged in WAIT after a stuck
--                  BR5 grant - turned out NOT to be (see
--                  [[xu-ethernet-bridge]]): iwait reads 0 and the
--                  address keeps moving, so diag_cpu_ifetch narrows
--                  down whether that's a genuine tight instruction loop
--                  or just data references from one fixed loop body.
--
-- irq <= mem_op_done or txi_ack or rxi_ack (anything the daemon needs to
-- react to - mirrors xuenc.vhd/sddisk.vhd's convention).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity xuring is
   port(
      clk   : in std_logic;      -- same clock as xu.vhd's command engine (nclk)
      reset : in std_logic;

      -- xu.vhd side (clk domain)
      mem_op_req_sync  : out std_logic;                     -- level, synced from s_axi: a request is pending
      mem_op_is_write  : out std_logic;
      mem_op_addr      : out std_logic_vector(17 downto 0);
      mem_op_wdata     : out std_logic_vector(15 downto 0);
      mem_op_rdata     : in  std_logic_vector(15 downto 0);  -- xu.vhd writes the read result here
      mem_op_rdata_we  : in  std_logic;                      -- one-cycle strobe: latch mem_op_rdata now
      mem_op_done      : in  std_logic;                      -- level: xu.vhd finished the current op

      -- ring geometry, latched by WRF in xu.vhd's own nclk-domain
      -- dispatch process - read-only here, plain combinational
      -- passthrough into the AXI read path. These change only once (at
      -- WRF, a rare event) and then stay perfectly stable for the rest
      -- of the session, same tolerance already relied on for debug_word
      -- below - not on any correctness-critical path.
      tdrb   : in std_logic_vector(17 downto 0);
      trlen  : in std_logic_vector(15 downto 0);
      rdrb   : in std_logic_vector(17 downto 0);
      rrlen  : in std_logic_vector(15 downto 0);

      -- TXNEXT/RXNEXT (current ring position) are OWNED entirely by this
      -- module now, not xu.vhd - software reads, advances, and writes
      -- them back over AXI, and xu.vhd's own state machine never needs
      -- to see them at all in the software-driven ring-walk design (see
      -- [[xu-ethernet-bridge]]). No cross-domain signal needed for them.

      pcsr1_state : in std_logic_vector(3 downto 0);

      txi_req_sync : out std_logic;                          -- level, synced from s_axi
      txi_ack      : in  std_logic;                          -- level, from xu.vhd
      rxi_req_sync : out std_logic;
      rxi_ack      : in  std_logic;

      debug_word : in std_logic_vector(15 downto 0);
      cmd_trace  : in std_logic_vector(15 downto 0);

      -- 8-entry command history, see xu.vhd's xu_cmd_hist comment -
      -- individual ports rather than an array, to avoid needing a shared
      -- type declaration across entity boundaries.
      hist0 : in std_logic_vector(15 downto 0);
      hist1 : in std_logic_vector(15 downto 0);
      hist2 : in std_logic_vector(15 downto 0);
      hist3 : in std_logic_vector(15 downto 0);
      hist4 : in std_logic_vector(15 downto 0);
      hist5 : in std_logic_vector(15 downto 0);
      hist6 : in std_logic_vector(15 downto 0);
      hist7 : in std_logic_vector(15 downto 0);
      hist_wptr : in std_logic_vector(2 downto 0);

      irq_trace : in std_logic_vector(31 downto 0);
      pc_trace  : in std_logic_vector(31 downto 0);

      -- AXI-Lite slave (PS / pdp11-netd side)
      s_axi_aclk    : in  std_logic;
      s_axi_aresetn : in  std_logic;
      s_axi_awaddr  : in  std_logic_vector(16 downto 0);
      s_axi_awvalid : in  std_logic;
      s_axi_awready : out std_logic;
      s_axi_wdata   : in  std_logic_vector(31 downto 0);
      s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      s_axi_wvalid  : in  std_logic;
      s_axi_wready  : out std_logic;
      s_axi_bresp   : out std_logic_vector(1 downto 0);
      s_axi_bvalid  : out std_logic;
      s_axi_bready  : in  std_logic;
      s_axi_araddr  : in  std_logic_vector(16 downto 0);
      s_axi_arvalid : in  std_logic;
      s_axi_arready : out std_logic;
      s_axi_rdata   : out std_logic_vector(31 downto 0);
      s_axi_rresp   : out std_logic_vector(1 downto 0);
      s_axi_rvalid  : out std_logic;
      s_axi_rready  : in  std_logic;

      irq : out std_logic
   );
end xuring;

architecture implementation of xuring is

   -- s_axi domain - software-facing register values
   signal r_memaddr  : std_logic_vector(17 downto 0) := (others => '0');
   signal r_memdata  : std_logic_vector(15 downto 0) := (others => '0');
   signal r_mem_req  : std_logic := '0';
   signal r_mem_wr   : std_logic := '0';
   signal r_txnext   : std_logic_vector(15 downto 0) := (others => '0');
   signal r_rxnext   : std_logic_vector(15 downto 0) := (others => '0');
   signal r_txi_req  : std_logic := '0';
   signal r_rxi_req  : std_logic := '0';

   -- clk-domain values synced INTO s_axi domain (2-flop level sync)
   signal mem_done_sync : std_logic_vector(1 downto 0) := "00";
   signal txi_ack_sync  : std_logic_vector(1 downto 0) := "00";
   signal rxi_ack_sync  : std_logic_vector(1 downto 0) := "00";

   -- s_axi-domain values synced INTO clk domain
   signal mem_req_sync2 : std_logic_vector(1 downto 0) := "00";
   signal txi_req_sync2 : std_logic_vector(1 downto 0) := "00";
   signal rxi_req_sync2 : std_logic_vector(1 downto 0) := "00";

   signal axi_awready : std_logic := '0';
   signal axi_wready  : std_logic := '0';
   signal axi_bvalid  : std_logic := '0';
   signal axi_arready : std_logic := '0';
   signal axi_rvalid  : std_logic := '0';
   signal axi_rdata   : std_logic_vector(31 downto 0) := (others => '0');

   signal heartbeat : std_logic_vector(3 downto 0) := (others => '0');

begin

   s_axi_awready <= axi_awready;
   s_axi_wready  <= axi_wready;
   s_axi_bvalid  <= axi_bvalid;
   s_axi_bresp   <= "00";
   s_axi_arready <= axi_arready;
   s_axi_rvalid  <= axi_rvalid;
   s_axi_rdata   <= axi_rdata;
   s_axi_rresp   <= "00";

   irq <= '1' when mem_done_sync(1) = '1' or txi_ack_sync(1) = '1' or rxi_ack_sync(1) = '1' else '0';

   -- ============ clk-domain side: sync s_axi-owned request levels in,
   -- present them combinationally to xu.vhd ============
   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            mem_req_sync2 <= "00";
            txi_req_sync2 <= "00";
            rxi_req_sync2 <= "00";
         else
            mem_req_sync2 <= mem_req_sync2(0) & r_mem_req;
            txi_req_sync2 <= txi_req_sync2(0) & r_txi_req;
            rxi_req_sync2 <= rxi_req_sync2(0) & r_rxi_req;
         end if;
      end if;
   end process;

   mem_op_req_sync <= mem_req_sync2(1);
   mem_op_is_write <= r_mem_wr;
   mem_op_addr     <= r_memaddr;
   mem_op_wdata    <= r_memdata;
   txi_req_sync    <= txi_req_sync2(1);
   rxi_req_sync    <= rxi_req_sync2(1);

   -- ============ AXI-Lite slave (s_axi_aclk domain) ============
   process(s_axi_aclk)
   begin
      if rising_edge(s_axi_aclk) then
         if s_axi_aresetn = '0' then
            axi_awready   <= '0';
            axi_wready    <= '0';
            axi_bvalid    <= '0';
            axi_arready   <= '0';
            axi_rvalid    <= '0';
            mem_done_sync <= "00";
            txi_ack_sync  <= "00";
            rxi_ack_sync  <= "00";
            r_memaddr     <= (others => '0');
            r_memdata     <= (others => '0');
            r_mem_req     <= '0';
            r_mem_wr      <= '0';
            r_txnext      <= (others => '0');
            r_rxnext      <= (others => '0');
            r_txi_req     <= '0';
            r_rxi_req     <= '0';
            heartbeat     <= (others => '0');
         else
            heartbeat     <= heartbeat + 1;
            mem_done_sync <= mem_done_sync(0) & mem_op_done;
            txi_ack_sync  <= txi_ack_sync(0) & txi_ack;
            rxi_ack_sync  <= rxi_ack_sync(0) & rxi_ack;

            -- latch xu.vhd's read result / current ring position whenever
            -- it strobes a write - plain synchronous capture, xu.vhd
            -- holds these stable, same tolerance already relied on
            -- elsewhere in this design
            if mem_op_rdata_we = '1' then
               r_memdata <= mem_op_rdata;
            end if;

            -- ---- AXI-Lite write channel ----
            if axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' and axi_bvalid = '0' then
               axi_awready <= '1';
               axi_wready  <= '1';
               case s_axi_awaddr(7 downto 2) is
                  when "000000" =>                        -- 0x00 MEMADDR
                     r_memaddr <= s_axi_wdata(17 downto 0);
                  when "000001" =>                        -- 0x04 MEMDATA
                     r_memdata <= s_axi_wdata(15 downto 0);
                  when "000010" =>                        -- 0x08 MEMCTL
                     r_mem_req <= s_axi_wdata(0);
                     r_mem_wr  <= s_axi_wdata(1);
                  when "000111" =>                        -- 0x1C TXNEXT
                     r_txnext <= s_axi_wdata(15 downto 0);
                  when "001000" =>                        -- 0x20 RXNEXT
                     r_rxnext <= s_axi_wdata(15 downto 0);
                  when "001010" =>                        -- 0x28 SET_TXI
                     r_txi_req <= '1';
                  when "001011" =>                        -- 0x2C SET_RXI
                     r_rxi_req <= '1';
                  when others =>
                     null;
               end case;
               axi_bvalid <= '1';
            else
               axi_awready <= '0';
               axi_wready  <= '0';
               if axi_bvalid = '1' and s_axi_bready = '1' then
                  axi_bvalid <= '0';
               end if;
            end if;

            -- clear TXI/RXI request once xu.vhd acks (background, level-
            -- only, mirrors the mem_op req/done pair)
            if txi_ack_sync(1) = '1' and r_txi_req = '1' then
               r_txi_req <= '0';
            end if;
            if rxi_ack_sync(1) = '1' and r_rxi_req = '1' then
               r_rxi_req <= '0';
            end if;

            -- ---- AXI-Lite read channel ----
            if axi_arready = '0' and s_axi_arvalid = '1' and axi_rvalid = '0' then
               axi_arready <= '1';
               case s_axi_araddr(7 downto 2) is
                  when "000000" => axi_rdata <= "00000000000000" & r_memaddr;                        -- 0x00 MEMADDR
                  when "000001" => axi_rdata <= x"0000" & r_memdata;                                 -- 0x04 MEMDATA
                  when "000010" => axi_rdata <= x"000000" & "000000" & mem_done_sync(1) & r_mem_req;  -- 0x08 MEMCTL
                  when "000011" => axi_rdata <= "00000000000000" & tdrb;                              -- 0x0C TDRB
                  when "000100" => axi_rdata <= x"0000" & trlen;                                      -- 0x10 TRLEN
                  when "000101" => axi_rdata <= "00000000000000" & rdrb;                              -- 0x14 RDRB
                  when "000110" => axi_rdata <= x"0000" & rrlen;                                      -- 0x18 RRLEN
                  when "000111" => axi_rdata <= x"0000" & r_txnext;                                   -- 0x1C TXNEXT
                  when "001000" => axi_rdata <= x"0000" & r_rxnext;                                   -- 0x20 RXNEXT
                  when "001001" => axi_rdata <= x"0000000" & pcsr1_state;                             -- 0x24 PCSR1STATE
                  when "001010" => axi_rdata <= x"000000" & "0000000" & r_txi_req;                    -- 0x28 SET_TXI
                  when "001011" => axi_rdata <= x"000000" & "0000000" & r_rxi_req;                    -- 0x2C SET_RXI
                  when "001100" => axi_rdata <= x"000" & heartbeat & debug_word;                      -- 0x30 DEBUG
                  when "001101" => axi_rdata <= x"0000" & cmd_trace;                                  -- 0x34 LASTCMD
                  when "001110" => axi_rdata <= x"0000" & hist0;                                      -- 0x38 HIST0
                  when "001111" => axi_rdata <= x"0000" & hist1;                                      -- 0x3C HIST1
                  when "010000" => axi_rdata <= x"0000" & hist2;                                      -- 0x40 HIST2
                  when "010001" => axi_rdata <= x"0000" & hist3;                                      -- 0x44 HIST3
                  when "010010" => axi_rdata <= x"0000" & hist4;                                      -- 0x48 HIST4
                  when "010011" => axi_rdata <= x"0000" & hist5;                                      -- 0x4C HIST5
                  when "010100" => axi_rdata <= x"0000" & hist6;                                      -- 0x50 HIST6
                  when "010101" => axi_rdata <= x"0000" & hist7;                                      -- 0x54 HIST7
                  when "010110" => axi_rdata <= x"0000000" & "0" & hist_wptr;                         -- 0x58 HIST_WPTR
                  when "010111" => axi_rdata <= irq_trace;                                            -- 0x5C IRQTRACE
                  when "011000" => axi_rdata <= pc_trace;                                             -- 0x60 PCTRACE
                  when others   => axi_rdata <= (others => '0');
               end case;
               axi_rvalid <= '1';
            else
               axi_arready <= '0';
               if axi_rvalid = '1' and s_axi_rready = '1' then
                  axi_rvalid <= '0';
               end if;
            end if;
         end if;
      end if;
   end process;

end implementation;
