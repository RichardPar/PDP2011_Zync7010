--
-- xuaxi.vhd - AXI-Lite "virtual ESP32" backend for xu.vhd's embedded DEUNA
-- microcode, a drop-in replacement for xubf.vhd's physical bit-banged SPI
-- link to a real ESP32.
--
-- xu.vhd already contains a complete, proven implementation of the DEUNA
-- (a second, embedded PDP-11 core running real upstream microcode,
-- xubw.mac, from pdp2011.sytse.net) - all PCSR0-3 / GETPCBB / GETCMD / WRF /
-- PDMD / descriptor-ring handling lives there, unmodified. That microcode's
-- own hardware interface (xubf.vhd) is deliberately tiny: 3 host registers
-- (XF xmit-from address, RT receive-to address - writing this arms/starts a
-- transfer -, RL run length in bytes) plus an SRDY status bit, all on xu's
-- private local unibus (invisible to the guest). One "run" moves RL bytes
-- of PDP-11 memory at XF out, and RL bytes in to RT, as one full-duplex
-- unit - originally by bit-banging real SPI to a physical ESP32.
--
-- This module keeps that exact XF/RT/RL/SRDY register contract (so the
-- already-assembled xubw.mac needs zero changes) but replaces the SPI shift
-- state machine with a small pair of buffers exposed over AXI-Lite to a
-- Linux daemon (pdp11-hostd) on the Zynq PS, which reimplements the real
-- ESP32 firmware's exact framing (xuesp/main/app_spitask.c: hdrlen=12,
-- receive-direction magic 0xaa 0x55, transmit-direction magic 0xa0 0xa0,
-- confirmed against xubw.mac's own rfmgk1/rfmgk2/tfmgk constants) against a
-- real Linux network interface instead of Wi-Fi.
--
-- Wire/byte-order convention (matches every other bridge in this project,
-- e.g. sddisk.vhd, and confirmed against xubw.mac's rfmgk1/rfmgk2 byte
-- layout): PDP-11 memory address N maps to wire byte N - i.e. a 16-bit
-- bus_master_dati/dato word's bits(7:0) is the byte at the even address,
-- bits(15:8) is the byte at the odd address. tx_buf/rx_buf are therefore
-- plain word arrays, one entry per PDP-11 word, no byte-swapping needed
-- anywhere in this file.
--
-- Design deliberately mirrors sddisk.vhd throughout (buffer-window + STATUS/
-- LEN/DONE register AXI-Lite slave, level-triggered irq <= req_pending,
-- daemon unmasks via uio_pdrv_genirq's standard write(1)-then-blocking-
-- read() protocol, and a 4-phase start/ack handshake crossing clock
-- domains) rather than the more elaborate toggle/CDC scheme the abandoned
-- xu-ethernet-bridge attempt had to invent from scratch - sddisk's simpler
-- pattern is already proven working on this exact board for the RL/RH disk
-- bridges.
--
-- One deliberate simplification vs. a real SPI full-duplex transaction: TX
-- and RX are sequenced (tx_buf is filled and handed to the daemon; only
-- once the daemon's DONE write confirms both "txbuf consumed" and "rxbuf
-- refreshed" does rx_buf get DMA'd into PDP-11 memory) rather than
-- happening in the same atomic transfer. This does not change behaviour
-- the microcode can observe (rx_buf's content was always independent of
-- tx_buf's content on the real ESP32 too - the daemon, like the firmware's
-- spislave_handler_task, just serves whatever is next in its own receive
-- queue) - it only adds one AXI round-trip of latency per run, negligible
-- against the guest's own multi-millisecond polling cadence.
--
-- Every port pulsed by the FPGA-side DMA engine (npr, run, the bus_master_*
-- outputs, state) is driven by exactly ONE process below - a direct lesson
-- from this project's own history of multi-driver-net synthesis errors on
-- earlier hand-written DEUNA logic (see docs/xu-networking-plan.md).
--
-- AXI-Lite register map (32-bit data, byte addresses, low 16 bits used).
-- Same "one address range, direction picks the buffer" convention as
-- sddisk.vhd's buffer window (there: write->rsector, read->wsector) - and
-- for the same reason: each buffer must stay exactly 2 ports (one writer
-- domain, one reader domain) for Vivado to infer real block RAM instead of
-- distributed-RAM/LUTs. tx_buf is therefore write-only from the clk-domain
-- DMA engine and read-only from the daemon; rx_buf is the other way round
-- - the daemon never reads back what it wrote:
--   0x0000..0x0C7F  buffer window, one 16-bit PDP-11 word per 32-bit AXI
--                   location (low half), index = addr(11:2). A WRITE here
--                   stores into rx_buf (daemon -> core); a READ returns
--                   tx_buf (core -> daemon). Valid for 0..(LEN+1)/2-1; the
--                   rest of the fixed window is stale left-over content,
--                   exactly like the real ESP32's fixed-size sendbuf/
--                   recvbuf.
--   0x1000  STATUS    (read)   bit0 = tx_pending (a fresh run is waiting)
--   0x1004  LEN       (read)   RL for the pending run, in bytes
--   0x1008  DONE      (write)  daemon writes here once txbuf is drained AND
--                               rxbuf has been refreshed - de-asserts irq
--   0x100C  HEARTBEAT (read)   free-running counter, incremented every clk
--                               (xu0's own clock) cycle - independent of
--                               run/state/guest traffic. A daemon polling
--                               this and seeing it change proves xu0's
--                               clock/logic domain is alive even when idle;
--                               a stuck value means xu0 itself is wedged
--                               (as opposed to the guest simply being quiet).
--                               NOTE: this only proves clk is toggling and
--                               reset isn't held - it does NOT prove the
--                               embedded microcode is making useful
--                               progress (it would keep ticking even if
--                               cpu0 were spinning forever in its own
--                               software wait-loop). See DEBUG1/RUNSTATS
--                               below for that.
--   0x1010  DEBUG1    (read)   bit0-2 = current DMA FSM state (0=s_idle,
--                               1=s_tx_req, 2=s_tx_cap, 3=s_wait_daemon,
--                               4=s_rx_wait_grant, 5=s_rx_req, 6=s_rx_cap,
--                               7=s_done), bit3 = srdy (ACTIVE LOW - 0
--                               means idle/ready, see the srdy assignment)
--   0x1014  RUNSTATS  (read)   bits(15:0) = run_start_count (incremented
--                               each time the local register interface
--                               triggers a run, i.e. RT gets written),
--                               bits(31:16) = run_done_count (incremented
--                               each time a run reaches s_done). Stuck at
--                               start==done==0 across an attempted transmit
--                               means the embedded microcode never wrote RT
--                               at all; start advancing but done not means
--                               a run is stuck in the DMA/daemon round trip
--                               (check DEBUG1's state); both advancing
--                               together but the guest still hangs points
--                               at the completion notification back to the
--                               OUTER guest CPU, entirely outside this file.
--   0x1018  DEBUG2    (read)   bits(15:0) = PCSR0 (the guest-visible DEUNA
--                               control/status register - same bit layout
--                               the guest driver itself reads: seri pcei
--                               rxi txi dni rcbi 0 usci intr inte rset pcmw
--                               port_command(4)); bits(19:16) = PCSR1's
--                               port-state nibble (the DEUNA port-command
--                               state machine - what step of GETPCBB/
--                               GETCMD/etc the guest<->microcode handshake
--                               is on); bit20 = xu0's own OUTER (main-
--                               unibus-facing, via xubm0) npr request; bit21
--                               = the matching outer npg grant. If npr=1 and
--                               npg=0 is stuck, xu0 is waiting on the SAME
--                               outer NPR arbiter RH/RL also use for their
--                               own DMA - a different instance of the class
--                               of bug fixed in the local-unibus arbiter
--                               above, on a bus this module has no fix for.
--                               bit22 = xubm0's LOCAL (xu0-internal) bus
--                               request, bit23 = its grant; bit24 = cpu0's
--                               own npr, bit25 = its npg.
--   0x101C  DEBUG3    (read)   bits(15:0) = ifetch_count - counts instruction
--                               fetches by xu0's embedded cpu0, so a STUCK
--                               value means the microcode has trapped or
--                               halted (HEARTBEAT deliberately cannot tell
--                               us this: it ticks off the raw clock and
--                               keeps counting even if cpu0 is dead or
--                               spinning). bits(31:16) = xubm_run_count -
--                               counts each time xubm0 asks for xu0's local
--                               bus, i.e. each attempt by the microcode to
--                               move data to/from GUEST memory. If the
--                               guest is retrying PDMD forever and this
--                               never advances, the microcode is not even
--                               attempting the transmit-ring/PCB fetch.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity xuaxi is
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
      -- facing) npr/npg - see the DEBUG2 register comment above.
      dbg_pcsr0 : in std_logic_vector(15 downto 0) := (others => '0');
      dbg_pcsr1_state : in std_logic_vector(3 downto 0) := (others => '0');
      dbg_outer_npr : in std_logic := '0';
      dbg_outer_npg : in std_logic := '0';

      -- xu0-internal taps: is the embedded cpu0 actually executing, and is
      -- xubm0 (the microcode's guest-memory mover) ever being asked to run
      -- and ever being granted xu0's own local bus? See DEBUG3 below.
      dbg_ifetch : in std_logic := '0';
      dbg_xubm_npr : in std_logic := '0';
      dbg_xubm_npg : in std_logic := '0';
      dbg_cpu_npr : in std_logic := '0';
      dbg_cpu_npg : in std_logic := '0';

      -- AXI-Lite slave (PS / pdp11-hostd side)
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
end xuaxi;

architecture implementation of xuaxi is

   constant buf_words : integer := 800;              -- >= (hdrlen+maxpay+slack)/2 = (12+1518+32)/2 = 781

   type buffer_type is array(0 to buf_words-1) of std_logic_vector(15 downto 0);
   signal tx_buf : buffer_type;                       -- core -> daemon (frame to send)
   signal rx_buf : buffer_type;                       -- daemon -> core (frame received)

   -- A standalone out-of-context synth check (see docs/xu-networking-plan.md)
   -- confirmed rx_buf infers as a single real RAMB18E1 (its read side -
   -- bus_master_dato in the DMA process - is a dedicated register with
   -- exactly one source, the RAM read, which is what Vivado's block-RAM
   -- template matcher wants). tx_buf's read side instead lands in axi_rdata,
   -- which is shared/muxed with the STATUS/LEN register reads below (the
   -- same pattern sddisk.vhd's own wsector/STATUS/BLOCK sharing uses) - a
   -- `ram_style = "block"` attribute here was tried and confirmed
   -- ("Infeasible attribute... trying to implement using LUTRAM" in the
   -- synth log) NOT to override that, so tx_buf falls back to ~65 RAM64M
   -- distributed-RAM primitives. Left as-is deliberately: the measured cost
   -- is small (474 LUTs / 2.7% of the xc7z010 for this whole module,
   -- nowhere near the LUT-budget problems earlier hand-written DEUNA logic
   -- hit) and not worth a read-pipeline rework to chase a marginal area
   -- gain. rx_buf's attribute is kept as a documented pin even though
   -- inference already gets it right unaided.
   attribute ram_style : string;
   attribute ram_style of rx_buf : signal is "block";

-- regular (local unibus) host register interface - driven only by the
-- register process below.

   signal base_addr_match : std_logic;

   signal xf : std_logic_vector(15 downto 0);         -- xmit-from address
   signal rt : std_logic_vector(15 downto 0);         -- receive-to address
   signal rl : std_logic_vector(10 downto 0);         -- run length, in bytes (lsb should be 0)

   signal run : std_logic := '0';                     -- one-cycle pulse: "start a run"

-- core-side (clk) DMA / run FSM - state, npr, the bus_master_* outputs and
-- run_req below are driven only by this process.

   type state_t is (
      s_idle,
      s_tx_req, s_tx_wait, s_tx_cap,
      s_wait_daemon,
      s_rx_wait_grant, s_rx_req, s_rx_cap,
      s_done
   );
   signal state : state_t := s_idle;

   signal widx : std_logic_vector(9 downto 0);        -- word index within the current run
   signal nwords : std_logic_vector(9 downto 0);      -- RL/2, latched at run start

   -- handshake into the s_axi_aclk domain: held high for the whole time
   -- this side is waiting on the daemon (2-FF synchronised on the far end,
   -- exactly like sddisk.vhd's read_start/write_start).
   signal run_req : std_logic := '0';
   -- ...and the matching synchronised return trip: the daemon's DONE,
   -- levelled and held by the AXI process until run_req is seen to drop -
   -- exactly like sddisk.vhd's read_done/write_done.
   signal run_done_s : std_logic_vector(1 downto 0) := "00";

   signal srdy : std_logic;                            -- ACTIVE LOW: '0' = idle/ready for the next run

   -- run-lifecycle counters (clk domain, driven only by the DMA process
   -- below) - diagnostic only, mirrors heartbeat_ctr's reasoning. A hang
   -- with run_start_count stuck means the embedded microcode never even
   -- wrote RT to trigger a transfer; run_start_count advancing but
   -- run_done_count not means a run got stuck somewhere in the DMA/daemon
   -- round trip (most likely candidate: npr/npg never granted); both
   -- advancing together but the guest still wedged points at the completion
   -- notification back to the OUTER guest CPU (xu.vhd's own PCSR/interrupt
   -- logic), entirely outside this module.
   signal run_start_count : std_logic_vector(15 downto 0) := (others => '0');
   signal run_done_count  : std_logic_vector(15 downto 0) := (others => '0');

   -- xu0-internal activity counters (clk domain, own tiny process below).
   -- ifetch_count rising means xu0's embedded cpu0 is genuinely executing
   -- instructions (a stuck value means it has trapped/halted, which the
   -- free-running HEARTBEAT above deliberately cannot tell us).
   -- xubm_run_count counts each time xubm0 asserts its local-bus request,
   -- i.e. each time the microcode asks to move data to/from GUEST memory -
   -- if this never moves while the guest is retrying PDMD, the microcode is
   -- never even attempting the ring/PCB fetch.
   signal ifetch_count : std_logic_vector(15 downto 0) := (others => '0');
   signal xubm_run_count : std_logic_vector(15 downto 0) := (others => '0');
   signal dbg_ifetch_d : std_logic := '0';
   signal dbg_xubm_npr_d : std_logic := '0';

   -- free-running heartbeat, incremented every clk (xu0's own local-unibus
   -- clock) cycle whenever this frontend is selected - completely
   -- independent of run/state/guest traffic, so a daemon polling HEARTBEAT
   -- and seeing it change proves xu0's clock/logic domain is alive even
   -- when the guest has sent nothing and no run is in progress. Deliberately
   -- kept out of the DMA/run FSM above (own signal, own tiny process) so it
   -- can never interact with or mask the npr/npg arbitration path.
   signal heartbeat_ctr : std_logic_vector(31 downto 0) := (others => '0');

-- s_axi_aclk domain - req_pending, req_len, run_done_lvl and the AXI slave
-- signals below are driven only by the AXI process.

   signal run_req_s : std_logic_vector(1 downto 0) := "00";
   signal run_done_lvl : std_logic := '0';
   signal req_pending : std_logic := '0';               -- also drives irq
   signal req_len : std_logic_vector(10 downto 0) := (others => '0');
   signal done_pulse : std_logic := '0';

   signal axi_awready : std_logic := '0';
   signal axi_wready  : std_logic := '0';
   signal axi_bvalid  : std_logic := '0';
   signal axi_arready : std_logic := '0';
   signal axi_rvalid  : std_logic := '0';
   signal axi_rdata   : std_logic_vector(31 downto 0) := (others => '0');

   -- heartbeat_ctr double-registered into the s_axi_aclk domain. This is a
   -- multi-bit value crossing clock domains without per-bit gray-coding or
   -- handshake, which would normally risk sampling a torn/transient value -
   -- acceptable here specifically because HEARTBEAT is read-only, advisory,
   -- and only ever used by the daemon to check "did this change since my
   -- last poll", never for an exact count or as a control input. Any single
   -- torn sample still reads as "some value near the real one" and the next
   -- poll (milliseconds later, ctr having advanced by thousands/millions)
   -- will unambiguously show movement either way.
   signal heartbeat_sync1 : std_logic_vector(31 downto 0) := (others => '0');
   signal heartbeat_sync2 : std_logic_vector(31 downto 0) := (others => '0');

   -- state/srdy and the two run counters, double-registered the same way -
   -- see the comment above heartbeat_sync1 for why this relaxed treatment
   -- is fine for read-only diagnostics.
   signal state_code : std_logic_vector(2 downto 0);   -- current DMA FSM state, encoded
   signal debug1_sync1   : std_logic_vector(3 downto 0) := (others => '0');
   signal debug1_sync2   : std_logic_vector(3 downto 0) := (others => '0');
   signal runstats_sync1 : std_logic_vector(31 downto 0) := (others => '0');
   signal runstats_sync2 : std_logic_vector(31 downto 0) := (others => '0');

   signal debug2_sync1 : std_logic_vector(25 downto 0) := (others => '0');
   signal debug2_sync2 : std_logic_vector(25 downto 0) := (others => '0');

   signal debug3_sync1 : std_logic_vector(31 downto 0) := (others => '0');
   signal debug3_sync2 : std_logic_vector(31 downto 0) := (others => '0');

begin

   base_addr_match <= '1' when have_xu_esp = 1 and base_addr(17 downto 4) = bus_addr(17 downto 4) else '0';
   bus_addr_match <= base_addr_match;

   s_axi_awready <= axi_awready;
   s_axi_wready  <= axi_wready;
   s_axi_bvalid  <= axi_bvalid;
   s_axi_bresp   <= "00";
   s_axi_arready <= axi_arready;
   s_axi_rvalid  <= axi_rvalid;
   s_axi_rdata   <= axi_rdata;
   s_axi_rresp   <= "00";

   irq <= req_pending;

   -- SRDY is ACTIVE LOW, exactly as in the xubf.vhd this module replaces:
   -- there it comes straight off the physical ESP32's xubf_srdy pin, is reset
   -- to '1', and xubf's own DMA engine only proceeds `if npg = '1' and
   -- srdy = '0'`. The microcode agrees - xubw.mac's main loop does `xubfc`
   -- (read this status word) then `bmi 30$`, i.e. if bit15 is SET it treats
   -- the frontend as NOT ready and branches past ALL payload processing,
   -- including the `20$` block that is the only place the transmit ring is
   -- ever polled.
   --
   -- Getting this backwards self-deadlocks: idle would report "busy", the
   -- microcode would skip the xubf transaction that is the only thing that
   -- starts a run, so the engine would never leave s_idle - which is exactly
   -- the hang this cost us (guest wedged, run_start_count stuck at 0, while
   -- PCSR commands kept being serviced because 30$ is precisely where the
   -- microcode was branching to).
   srdy <= '0' when state = s_idle else '1';

   -- s_tx_wait shares s_tx_req's code: both just mean "fetching a word from
   -- guest memory", and folding them keeps this a 3-bit field so DEBUG1's
   -- layout (and the daemon's decode of it) stays unchanged.
   state_code <= "000" when state = s_idle
      else "001" when state = s_tx_req
      else "001" when state = s_tx_wait
      else "010" when state = s_tx_cap
      else "011" when state = s_wait_daemon
      else "100" when state = s_rx_wait_grant
      else "101" when state = s_rx_req
      else "110" when state = s_rx_cap
      else "111";                                       -- s_done

   -- ============ host register interface (local unibus, clk domain) ============
   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            if have_xu_esp = 1 then
               xf <= (others => '0');
               rt <= (others => '0');
               rl <= (others => '0');
               run <= '0';
            end if;

         else
            if have_xu_esp = 1 then

               run <= '0';                             -- default: one-cycle pulse

               if base_addr_match = '1' and bus_control_dati = '1' then
                  case bus_addr(2 downto 1) is
                     when "00" =>
                        bus_dati <= srdy & "0000000" & srdy & "0000000";
                     when others =>
                        bus_dati <= (others => '0');
                  end case;
               end if;

               if base_addr_match = '1' and bus_control_dato = '1' then
                  case bus_addr(2 downto 1) is
                     when "00" =>
                        xf <= bus_dato;
                     when "01" =>
                        rt <= bus_dato;
                        run <= '1';
                     when "10" =>
                        rl <= bus_dato(10 downto 0);
                     when others =>
                        null;
                  end case;
               end if;

            end if;
         end if;
      end if;
   end process;

   -- ============ DMA / run engine (clk domain) ============
   process(clk, reset)
      variable txaddr : std_logic_vector(15 downto 0);
      variable rxaddr : std_logic_vector(15 downto 0);
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            if have_xu_esp = 1 then
               state <= s_idle;
               npr <= '0';
               bus_master_control_dati <= '0';
               bus_master_control_dato <= '0';
               widx <= (others => '0');
               nwords <= (others => '0');
               run_req <= '0';
               run_done_s <= "00";
               run_start_count <= (others => '0');
               run_done_count <= (others => '0');
            end if;

         else
            if have_xu_esp = 1 then

               run_done_s <= run_done_s(0) & run_done_lvl;

               case state is

                  when s_idle =>
                     bus_master_control_dati <= '0';
                     bus_master_control_dato <= '0';
                     if run = '1' then
                        widx <= (others => '0');
                        -- RL/2, per xubf's own "lsb should be 0" - clamped
                        -- to the buffer size as a safety net (the real
                        -- microcode's max frame is hdrlen+maxpay = 1530
                        -- bytes / 765 words, comfortably under buf_words,
                        -- but this guards conv_integer(widx) below against
                        -- any out-of-range RL regardless).
                        if rl(10 downto 1) > conv_std_logic_vector(buf_words-1, 10) then
                           nwords <= conv_std_logic_vector(buf_words-1, 10);
                        else
                           nwords <= rl(10 downto 1);
                        end if;
                        npr <= '1';
                        state <= s_tx_req;
                        run_start_count <= run_start_count + 1;
                     end if;

                  -- ---- phase 1: PDP-11 mem[XF..] -> tx_buf ----
                  when s_tx_req =>
                     if npg = '1' then
                        if widx = nwords then
                           npr <= '0';                   -- release the bus while the
                           run_req <= '1';                -- daemon does its round trip
                           widx <= (others => '0');
                           state <= s_wait_daemon;
                        else
                           txaddr := xf + ("00000" & widx & '0');
                           bus_master_addr <= "00" & txaddr;
                           bus_master_control_dati <= '1';
                           state <= s_tx_wait;
                        end if;
                     end if;

                  -- One extra cycle with the address and dati still asserted
                  -- before latching. Capturing in the cycle immediately after
                  -- asserting dati (which is what rh11.vhd and the original
                  -- xubf.vhd both do against MAIN memory) latches one word
                  -- too early here: measured on hardware, tx_buf(k) came back
                  -- holding the word for address k-1, so the frame reached the
                  -- daemon shifted 2 bytes and its 0xa0a0 magic landed at
                  -- bytes 2-3. xu0's local unibus - RAM behind its own mmu0 -
                  -- evidently needs the extra cycle that main memory doesn't.
                  -- (xubf.vhd very likely shares this bug; its DMA has never
                  -- run on real hardware, have_xu was 0 in every build until
                  -- this session.)
                  when s_tx_wait =>
                     state <= s_tx_cap;

                  when s_tx_cap =>
                     bus_master_control_dati <= '0';
                     tx_buf(conv_integer(widx)) <= bus_master_dati;
                     widx <= widx + 1;
                     state <= s_tx_req;

                  when s_wait_daemon =>
                     if run_done_s(1) = '1' then
                        run_req <= '0';
                        npr <= '1';
                        state <= s_rx_wait_grant;
                     end if;

                  -- ---- phase 2: rx_buf -> PDP-11 mem[RT..] ----
                  when s_rx_wait_grant =>
                     if npg = '1' then
                        state <= s_rx_req;
                     end if;

                  when s_rx_req =>
                     if widx = nwords then
                        npr <= '0';
                        state <= s_done;
                        run_done_count <= run_done_count + 1;
                     else
                        rxaddr := rt + ("00000" & widx & '0');
                        bus_master_addr <= "00" & rxaddr;
                        bus_master_dato <= rx_buf(conv_integer(widx));
                        bus_master_control_dato <= '1';
                        state <= s_rx_cap;
                     end if;

                  when s_rx_cap =>
                     bus_master_control_dato <= '0';
                     widx <= widx + 1;
                     state <= s_rx_req;

                  when s_done =>
                     state <= s_idle;

               end case;
            end if;
         end if;
      end if;
   end process;

   -- ============ heartbeat counter (clk domain) ============
   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            heartbeat_ctr <= (others => '0');
         elsif have_xu_esp = 1 then
            heartbeat_ctr <= heartbeat_ctr + 1;
         end if;
      end if;
   end process;

   -- ============ xu0-internal activity counters (clk domain) ============
   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            ifetch_count <= (others => '0');
            xubm_run_count <= (others => '0');
            dbg_ifetch_d <= '0';
            dbg_xubm_npr_d <= '0';
         elsif have_xu_esp = 1 then
            dbg_ifetch_d <= dbg_ifetch;
            dbg_xubm_npr_d <= dbg_xubm_npr;
            if dbg_ifetch = '1' and dbg_ifetch_d = '0' then
               ifetch_count <= ifetch_count + 1;
            end if;
            if dbg_xubm_npr = '1' and dbg_xubm_npr_d = '0' then
               xubm_run_count <= xubm_run_count + 1;
            end if;
         end if;
      end if;
   end process;

   -- ============ AXI-Lite slave + daemon-request backend (s_axi_aclk) ============
   process(s_axi_aclk)
      variable widx_ax : integer range 0 to buf_words-1;
      variable ridx_ax : integer range 0 to buf_words-1;
   begin
      if rising_edge(s_axi_aclk) then
         done_pulse <= '0';

         if s_axi_aresetn = '0' then
            axi_awready <= '0';
            axi_wready  <= '0';
            axi_bvalid  <= '0';
            axi_arready <= '0';
            axi_rvalid  <= '0';
            run_req_s <= "00";
            run_done_lvl <= '0';
            req_pending <= '0';
            heartbeat_sync1 <= (others => '0');
            heartbeat_sync2 <= (others => '0');
            debug1_sync1 <= (others => '0');
            debug1_sync2 <= (others => '0');
            runstats_sync1 <= (others => '0');
            runstats_sync2 <= (others => '0');
            debug2_sync1 <= (others => '0');
            debug2_sync2 <= (others => '0');
            debug3_sync1 <= (others => '0');
            debug3_sync2 <= (others => '0');
         else
            -- ---- AXI-Lite write channel ----
            if axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' and axi_bvalid = '0' then
               axi_awready <= '1';
               axi_wready  <= '1';
               if s_axi_awaddr(12) = '0' then
                  -- buffer window: a WRITE always targets rx_buf (daemon ->
                  -- core). tx_buf is never written from AXI at all - it has
                  -- exactly one writer (the clk-domain DMA engine) and one
                  -- reader (the read channel below), and rx_buf is the
                  -- mirror image (one writer here, one reader in the
                  -- clk-domain DMA engine) - each buffer stays a clean
                  -- 2-port shape so Vivado infers real block RAM instead of
                  -- distributed RAM/LUTs (see the file header note).
                  widx_ax := conv_integer(s_axi_awaddr(11 downto 2));
                  if widx_ax < buf_words then
                     rx_buf(widx_ax) <= s_axi_wdata(15 downto 0);
                  end if;
               else
                  if s_axi_awaddr(4 downto 2) = "010" then      -- 0x1008 DONE
                     done_pulse <= '1';
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
               if s_axi_araddr(12) = '0' then
                  -- buffer window: a READ always returns tx_buf (core ->
                  -- daemon) - see the write-channel comment above.
                  ridx_ax := conv_integer(s_axi_araddr(11 downto 2));
                  if ridx_ax < buf_words then
                     axi_rdata <= x"0000" & tx_buf(ridx_ax);
                  else
                     axi_rdata <= (others => '0');
                  end if;
               else
                  case s_axi_araddr(4 downto 2) is
                     when "000" =>                       -- 0x1000 STATUS
                        axi_rdata <= (others => '0');
                        axi_rdata(0) <= req_pending;
                     when "001" =>                        -- 0x1004 LEN
                        axi_rdata <= x"00000" & "0" & req_len;
                     when "011" =>                        -- 0x100C HEARTBEAT
                        axi_rdata <= heartbeat_sync2;
                     when "100" =>                        -- 0x1010 DEBUG1: srdy & state(2:0)
                        axi_rdata <= x"0000000" & debug1_sync2;
                     when "101" =>                        -- 0x1014 RUNSTATS: done<<16 | start
                        axi_rdata <= runstats_sync2;
                     when "110" =>                        -- 0x1018 DEBUG2
                        axi_rdata <= "000000" & debug2_sync2;
                     when "111" =>                        -- 0x101C DEBUG3
                        axi_rdata <= debug3_sync2;
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

            -- ---- request/done handshake with the clk domain ----
            run_req_s <= run_req_s(0) & run_req;

            if run_req_s(1) = '1' and req_pending = '0' and run_done_lvl = '0' then
               req_pending <= '1';
               req_len <= rl;                            -- stable throughout the run
            end if;

            if done_pulse = '1' then
               req_pending <= '0';
               run_done_lvl <= '1';
            elsif run_req_s(1) = '0' then
               run_done_lvl <= '0';
            end if;

            -- ---- heartbeat: double-register into this domain ----
            heartbeat_sync1 <= heartbeat_ctr;
            heartbeat_sync2 <= heartbeat_sync1;
            debug1_sync1 <= srdy & state_code;
            debug1_sync2 <= debug1_sync1;
            runstats_sync1 <= run_done_count & run_start_count;
            runstats_sync2 <= runstats_sync1;
            debug2_sync1 <= dbg_cpu_npg & dbg_cpu_npr & dbg_xubm_npg & dbg_xubm_npr
               & dbg_outer_npg & dbg_outer_npr & dbg_pcsr1_state & dbg_pcsr0;
            debug2_sync2 <= debug2_sync1;
            debug3_sync1 <= xubm_run_count & ifetch_count;
            debug3_sync2 <= debug3_sync1;
         end if;
      end if;
   end process;

end implementation;
