/*
 * pdp11-netd - bridges the PDP-11's xu DEUNA network device to Linux
 * networking (tap0, bridged with eth0), so RSX/2.11BSD's stock DEUNA
 * drivers reach the physical network transparently.
 *
 * Rebuilt (2026-09-06, see [[xu-ethernet-bridge]] memory for the full
 * history) after two different FPGA-side descriptor-ring-walk engines
 * both caused a real, reproducible board hang, and both times xu.vhd's
 * own debug state showed the engine sitting idle at the moment of the
 * freeze - evidence the ring-walk logic itself was never the problem,
 * and that debugging it blind inside the FPGA wasn't working. The ENTIRE
 * descriptor-ring algorithm now lives HERE instead: this daemon reads
 * and writes individual PDP-11 memory words directly (the one primitive
 * xu.vhd still provides in hardware - the same request/capture DMA
 * xu.vhd's own port-command dispatch already uses reliably), parses the
 * 4-word descriptor format itself, and drives the OWN-bit/ring-position
 * bookkeeping in C, where every step can be logged.
 *
 * Descriptor format - ground truth is the GUEST's own `struct de_ring`
 * (2.11BSD if_dereg.h), NOT a generic 4-word layout. TX and RX identical
 * shape, 5 words / 10 bytes (see DESC_STRIDE below - assuming 8 here was
 * the multi-day "board hang" bug):
 *   word0  slen   buffer length in bytes            (r_slen)
 *   word1  addr low 16 bits                         (r_segbl)
 *   word2  bit15 OWN, bits1:0 addr extension (bits 17:16), bit9 STF,
 *          bit8 ENF (start/end of frame - only single-descriptor frames
 *          are handled here, logged, not silently misprocessed, if
 *          violated). This word is r_segbh (low byte) + r_flags (high
 *          byte) packed, which is why XFLG_OWN's byte value 0x80 lands
 *          at word bit15, XFLG_STP 0x02 at bit9, XFLG_ENP 0x01 at bit8.
 *   word3  RX: MLEN (received length). TX: status   (r_tdrerr)
 *   word4  r_rid - never inspected by 2.11BSD's driver; we don't touch
 *          it, but it IS part of the stride.
 *
 * xuring.vhd register map (byte offsets from the UIO mmap base):
 *   0x00  MEMADDR   (r/w) PDP-11 byte address for the next word access
 *   0x04  MEMDATA   (r/w) write value before a WRITE op / read result
 *                   after a READ op completes
 *   0x08  MEMCTL    write: bit0=req, bit1=is_write - set together to
 *                   start an op; write 0 to acknowledge once done.
 *                   read: bit0=req echo, bit1=done
 *   0x0C  TDRB      (read-only) TX ring base address
 *   0x10  TRLEN     (read-only) TX ring length, entries
 *   0x14  RDRB      (read-only) RX ring base address
 *   0x18  RRLEN     (read-only) RX ring length, entries
 *   0x1C  TXNEXT    (r/w) current TX ring position - WE own this now,
 *                   not xu.vhd; read, advance, write back
 *   0x20  RXNEXT    (r/w) same, RX ring position
 *   0x24  PCSR1STATE (read-only, low 4 bits) - 0x3 = RUNNING
 *   0x28  SET_TXI   write: any value requests a TXI interrupt strobe
 *   0x2C  SET_RXI   same, for RXI
 *   0x30  DEBUG     (read-only) xucmd_state/pcsr1_state + a free-running
 *                   heartbeat - kept for whatever needs debugging next
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <dirent.h>

#define RING_UIO_NAME  "pdp11net-ring"
#define RING_MAP_SIZE  0x1000

#define REG_MEMADDR    (0x00 / 4)
#define REG_MEMDATA    (0x04 / 4)
#define REG_MEMCTL     (0x08 / 4)
#define REG_TDRB       (0x0C / 4)
#define REG_TRLEN      (0x10 / 4)
#define REG_RDRB       (0x14 / 4)
#define REG_RRLEN      (0x18 / 4)
#define REG_TXNEXT     (0x1C / 4)
#define REG_RXNEXT     (0x20 / 4)
#define REG_PCSR1STATE (0x24 / 4)
#define REG_SET_TXI    (0x28 / 4)
#define REG_SET_RXI    (0x2C / 4)
#define REG_DEBUG      (0x30 / 4)
#define REG_LASTCMD    (0x34 / 4)
#define REG_HIST0      (0x38 / 4)
#define REG_HIST_WPTR  (0x58 / 4)

#define MEMCTL_REQ      (1u << 0)
#define MEMCTL_ISWRITE  (1u << 1)
#define MEMCTL_DONE     (1u << 1)  /* read-side meaning, same bit position */

#define PCSR1_RUNNING  0x3

/* Bytes per descriptor. This is sizeof(struct de_ring) in the GUEST's own
 * driver, NOT a 4-word simplification: 2.11BSD's struct de_ring is
 *   short r_slen; short r_segbl; char r_segbh; u_char r_flags;
 *   u_short r_tdrerr; short r_rid;
 * = 10 bytes / 5 words, with no padding (every multi-byte field already
 * lands on an even offset under pdp11 pcc). deinit() hands exactly this to
 * the device: `b_telen = sizeof(struct de_ring)/sizeof(short)` == 5
 * (if_de.c:315, and b_relen likewise at :320).
 *
 * This was 8 for a long time and was THE bug behind the multi-day "board
 * hang" (see [[xu-ethernet-bridge]]): slot 0 sits at offset 0 under either
 * stride, so the first TX always worked, but every later slot was read 2
 * bytes early per slot (cumulative), so the OWN check landed on r_segbl
 * instead of the flags word and always read false. TXNEXT then froze
 * forever while the guest still had owned descriptors queued, and the
 * guest's own deintr()->destart()->PDMD retry loop became self-sustaining,
 * pinning it at IPL 5 and starving the console (BR4) - which is what made
 * it look like a CPU/interrupt hang. Deterministic, never a race. */
#define DESC_STRIDE     10
#define OWN_BIT         0x8000
#define STF_BIT         0x0200
#define ENF_BIT         0x0100
#define RING_MAX_FRAME  2048
/* The FCS a real board appends and includes in MLEN; the guest driver
 * subtracts it back off (if_de.c's CRC_LEN). tap0 never gives us one. */
#define RX_CRC_LEN      4
/* sizeof(struct de_buf) - what deinit() posts as each RX buffer's r_slen:
 * an ether header plus ETHERMTU, rounded as the driver lays it out. */
#define DE_BUF_SIZE     1514

#define MEM_OP_TIMEOUT_ITERS 200000

static volatile uint32_t *ring_regs = NULL;
static int tap_fd = -1;
static FILE *logf = NULL;
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;
static struct timespec start_ts;

static void log_msg(const char *fmt, ...)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	long elapsed_ms = (now.tv_sec - start_ts.tv_sec) * 1000
		+ (now.tv_nsec - start_ts.tv_nsec) / 1000000;

	time_t wall = time(NULL);
	struct tm tmv;
	localtime_r(&wall, &tmv);

	char prefix[64];
	snprintf(prefix, sizeof(prefix), "[%02d:%02d:%02d +%ldms] NET: ",
		tmv.tm_hour, tmv.tm_min, tmv.tm_sec, elapsed_ms);

	va_list ap;
	va_start(ap, fmt);
	fprintf(logf, "%s", prefix);
	vfprintf(logf, fmt, ap);
	fprintf(logf, "\n");
	fflush(logf);
	va_end(ap);
}

/* ============ single-word PDP-11 memory access primitive ============ */

/* Complete the 4-phase handshake: after acking with MEMCTL=0 we MUST wait
 * for xu.vhd to drop DONE before the next request, otherwise the next
 * call's "wait for DONE" sees this transaction's still-set DONE, reads
 * MEMDATA before the new word has landed, and returns the PREVIOUS word.
 * That produced visibly duplicated word pairs in real transmitted frames
 * (e.g. an ARP whose sender-IP low half appeared twice, and frames full
 * of repeated garbage) - see [[xu-ethernet-bridge]]. DONE clears through
 * the cross-domain synchronizers, so it is several cycles late, which is
 * exactly long enough for a tight software loop to race it. */
static int mem_wait_idle(void)
{
	int timeout = MEM_OP_TIMEOUT_ITERS;
	while ((ring_regs[REG_MEMCTL] & MEMCTL_DONE) && --timeout)
		;
	return timeout ? 0 : -1;
}

static int mem_read_word(uint32_t addr, uint16_t *out)
{
	pthread_mutex_lock(&ring_lock);
	if (mem_wait_idle() < 0) {
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_read_word(0x%05x): TIMEOUT waiting for prior op to clear", addr);
		return -1;
	}
	ring_regs[REG_MEMADDR] = addr;
	ring_regs[REG_MEMCTL] = MEMCTL_REQ;
	int timeout = MEM_OP_TIMEOUT_ITERS;
	while (!(ring_regs[REG_MEMCTL] & MEMCTL_DONE) && --timeout)
		;
	if (timeout == 0) {
		ring_regs[REG_MEMCTL] = 0;
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_read_word(0x%05x): TIMEOUT waiting for done", addr);
		return -1;
	}
	*out = ring_regs[REG_MEMDATA] & 0xFFFF;
	ring_regs[REG_MEMCTL] = 0;
	if (mem_wait_idle() < 0) {
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_read_word(0x%05x): TIMEOUT waiting for done to clear", addr);
		return -1;
	}
	pthread_mutex_unlock(&ring_lock);
	return 0;
}

static int mem_write_word(uint32_t addr, uint16_t val)
{
	pthread_mutex_lock(&ring_lock);
	if (mem_wait_idle() < 0) {
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_write_word(0x%05x, 0x%04x): TIMEOUT waiting for prior op to clear", addr, val);
		return -1;
	}
	ring_regs[REG_MEMADDR] = addr;
	ring_regs[REG_MEMDATA] = val;
	ring_regs[REG_MEMCTL] = MEMCTL_REQ | MEMCTL_ISWRITE;
	int timeout = MEM_OP_TIMEOUT_ITERS;
	while (!(ring_regs[REG_MEMCTL] & MEMCTL_DONE) && --timeout)
		;
	if (timeout == 0) {
		ring_regs[REG_MEMCTL] = 0;
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_write_word(0x%05x, 0x%04x): TIMEOUT waiting for done", addr, val);
		return -1;
	}
	ring_regs[REG_MEMCTL] = 0;
	if (mem_wait_idle() < 0) {
		pthread_mutex_unlock(&ring_lock);
		log_msg("mem_write_word(0x%05x, 0x%04x): TIMEOUT waiting for done to clear", addr, val);
		return -1;
	}
	pthread_mutex_unlock(&ring_lock);
	return 0;
}

static int read_desc(uint32_t base, uint16_t d[4])
{
	for (int i = 0; i < 4; i++)
		if (mem_read_word(base + i * 2, &d[i]) < 0)
			return -1;
	return 0;
}

static int write_desc(uint32_t base, const uint16_t d[4])
{
	for (int i = 0; i < 4; i++)
		if (mem_write_word(base + i * 2, d[i]) < 0)
			return -1;
	return 0;
}

static void strobe_interrupt(int reg)
{
	pthread_mutex_lock(&ring_lock);
	ring_regs[reg] = 1;
	int timeout = MEM_OP_TIMEOUT_ITERS;
	while ((ring_regs[reg] & 1) && --timeout)
		;
	pthread_mutex_unlock(&ring_lock);
	if (timeout == 0)
		log_msg("strobe_interrupt(reg offset %d): TIMEOUT waiting for xu.vhd to ack", reg * 4);
}

/* ============ ring-walk (all logic lives here now - see file header) ============ */

static void poll_tx(void)
{
	uint32_t tdrb  = ring_regs[REG_TDRB] & 0x3FFFF;
	uint32_t trlen = ring_regs[REG_TRLEN] & 0xFFFF;
	uint32_t txnext = ring_regs[REG_TXNEXT] & 0xFFFF;
	if (trlen == 0)
		return;  /* WRF hasn't run yet - ring not configured */
	if (txnext >= trlen)
		txnext = 0;  /* defensive - shouldn't happen, but don't compute a bogus address if it does */

	uint32_t ba = tdrb + DESC_STRIDE * txnext;
	uint16_t d[4];
	if (read_desc(ba, d) < 0)
		return;

	if (!(d[2] & OWN_BIT))
		return;  /* nothing to send - normal, not an error */

	uint32_t addr = ((uint32_t)(d[2] & 0x3) << 16) | d[1];
	uint32_t slen = d[0];

	if (slen == 0 || slen > RING_MAX_FRAME) {
		log_msg("TX: implausible descriptor length %u at txnext=%u (addr 0x%05x), skipping",
			slen, txnext, ba);
	} else {
		uint8_t frame[RING_MAX_FRAME];
		uint32_t nwords = (slen + 1) / 2;
		int ok = 1;
		for (uint32_t i = 0; i < nwords; i++) {
			uint16_t w;
			if (mem_read_word(addr + i * 2, &w) < 0) {
				ok = 0;
				break;
			}
			frame[i * 2] = w & 0xFF;
			if (i * 2 + 1 < slen)
				frame[i * 2 + 1] = (w >> 8) & 0xFF;
		}
		if (ok) {
			ssize_t n = write(tap_fd, frame, slen);
			if (n < 0)
				log_msg("TX: write to tap0 failed: %s", strerror(errno));
			else
				log_msg("TX: %zd bytes forwarded to tap0 (txnext=%u)", n, txnext);
		} else {
			log_msg("TX: frame-data read failed at txnext=%u, descriptor left owned - will retry", txnext);
			return;
		}
	}

	/* writeback: clear OWN, clear status */
	uint16_t wb[4] = { d[0], d[1], (uint16_t)(d[2] & 0x7FFF), 0 };
	if (write_desc(ba, wb) < 0) {
		log_msg("TX: descriptor writeback failed at txnext=%u", txnext);
		return;
	}

	uint32_t newnext = (txnext + 1 >= trlen) ? 0 : txnext + 1;
	ring_regs[REG_TXNEXT] = newnext;

	strobe_interrupt(REG_SET_TXI);
}

static void deliver_rx_frame(const uint8_t *buf, int len)
{
	uint32_t state = ring_regs[REG_PCSR1STATE] & 0xF;
	if (state != PCSR1_RUNNING) {
		log_msg("RX: guest not RUNNING yet (pcsr1_state=0x%x), dropping %d-byte frame", state, len);
		return;
	}

	uint32_t rdrb  = ring_regs[REG_RDRB] & 0x3FFFF;
	uint32_t rrlen = ring_regs[REG_RRLEN] & 0xFFFF;
	uint32_t rxnext = ring_regs[REG_RXNEXT] & 0xFFFF;
	if (rrlen == 0) {
		log_msg("RX: ring not configured yet, dropping %d-byte frame", len);
		return;
	}
	if (rxnext >= rrlen)
		rxnext = 0;

	if (len <= 0 || len > RING_MAX_FRAME) {
		log_msg("RX: implausible %d-byte frame from tap0, dropping", len);
		return;
	}

	uint32_t ba = rdrb + DESC_STRIDE * rxnext;
	uint16_t d[4];
	if (read_desc(ba, d) < 0)
		return;

	if (!(d[2] & OWN_BIT)) {
		log_msg("RX: descriptor at rxnext=%u not owned, dropping %d-byte frame", rxnext, len);
		return;
	}

	/* Present the frame the way real DEUNA hardware would, or the guest
	 * throws it away (see [[xu-ethernet-bridge]]):
	 *
	 *  - PAD to the 60-byte Ethernet minimum. A real NIC only ever sees
	 *    wire-padded frames; tap0 hands us the unpadded 42 bytes for a
	 *    locally generated ARP.
	 *  - Report MLEN INCLUDING the 4-byte CRC, because derecv() does
	 *    `len = (r_lenerr & RERR_MLEN) - sizeof(ether_header) - CRC_LEN`
	 *    (if_de.c:571) - the board is expected to have appended an FCS.
	 *
	 * Getting either wrong makes derecv()'s `len < ETHERMIN` test fail
	 * and the frame is counted as an ierror and DISCARDED. With a raw
	 * 42-byte ARP reply the driver computed 42-14-4 = 24 < 46 and threw
	 * away every single ARP reply, so ARP could never resolve and ping
	 * only ever emitted requests. Padded+CRC it computes 64-14-4 = 46,
	 * exactly ETHERMIN, and the frame is accepted. */
	uint32_t plen = (len < 60) ? 60 : (uint32_t)len;

	/* NEVER write past the buffer the guest actually provided. d[0]
	 * (r_slen) is the receive buffer's size, set by the driver in
	 * deinit(); writing more than that corrupts whatever kernel memory
	 * follows it - that caused a real "panic: trap" (trap type 3) once
	 * the ring finally started delivering full-size LAN traffic. */
	/* r_slen is written ONCE by deinit() (if_de.c:348) and deliberately
	 * NOT restored when derecv() re-arms (it only clears r_lenerr and
	 * sets RFLG_OWN, :601), so it must survive for the life of the ring.
	 * If it reads back implausible the descriptor was corrupted - which
	 * really happened here: before the stale-read fix in mem_read_word()
	 * our own writeback stored garbage into it, and a zero r_slen then
	 * made this clamp drop 100% of inbound traffic. Fall back to the
	 * driver's real buffer size rather than dropping everything; the
	 * ring only truly recovers on the next deinit (ifconfig down/up or
	 * reboot). See [[xu-ethernet-bridge]]. */
	uint32_t bufsz = d[0];
	if (bufsz == 0 || bufsz > RING_MAX_FRAME) {
		static int warned;
		if (!warned) {
			warned = 1;
			log_msg("RX: descriptor at rxnext=%u has implausible r_slen=%u "
				"(ring corrupted by an earlier bug?); assuming %d bytes. "
				"ifconfig de0 down/up on the guest to rebuild the ring.",
				rxnext, d[0], DE_BUF_SIZE);
		}
		bufsz = DE_BUF_SIZE;
	}
	if (plen > bufsz) {
		log_msg("RX: %d-byte frame (padded %u) exceeds descriptor buffer (%u bytes) at rxnext=%u, dropping",
			len, plen, bufsz, rxnext);
		return;
	}

	uint32_t addr = ((uint32_t)(d[2] & 0x3) << 16) | d[1];
	uint32_t nwords = (plen + 1) / 2;
	for (uint32_t i = 0; i < nwords; i++) {
		uint32_t lo = (i * 2 < (uint32_t)len) ? buf[i * 2] : 0;
		uint32_t hi = (i * 2 + 1 < (uint32_t)len) ? buf[i * 2 + 1] : 0;
		if (mem_write_word(addr + i * 2, (uint16_t)(lo | (hi << 8))) < 0) {
			log_msg("RX: frame-data write failed at rxnext=%u, aborting this delivery", rxnext);
			return;
		}
	}

	uint16_t wb[4] = {
		d[0], d[1],
		(uint16_t)((d[2] & 0x7FFF) | STF_BIT | ENF_BIT),
		(uint16_t)(plen + RX_CRC_LEN)
	};
	if (write_desc(ba, wb) < 0) {
		log_msg("RX: descriptor writeback failed at rxnext=%u", rxnext);
		return;
	}

	uint32_t newnext = (rxnext + 1 >= rrlen) ? 0 : rxnext + 1;
	ring_regs[REG_RXNEXT] = newnext;

	strobe_interrupt(REG_SET_RXI);
	log_msg("RX: %d bytes delivered to descriptor at rxnext=%u", len, rxnext);
}

static const char *port_cmd_name(uint32_t cmd)
{
	switch (cmd) {
	case 0x0: return "NOOP";
	case 0x1: return "GETPCBB";
	case 0x2: return "GETCMD";
	case 0x3: return "SELFTEST";
	case 0x4: return "START";
	case 0xE: return "HALT";
	case 0xF: return "STOP";
	default:  return "BOOT/PDMD/other";
	}
}

/* Diagnostic trace (LASTCMD register, see xuring.vhd) - added after START
 * reached RUNNING but WRF never latched TDRB/TRLEN. Logs every port
 * command actually dispatched, in order, plus the PCB function code for
 * GETCMD - the ONLY way to see this without guessing, since xu.vhd's own
 * state always looks idle again by the time anything can be polled. */
static void poll_cmd_trace(void)
{
	static int have_last = 0;
	static uint32_t last_counter = 0;

	uint32_t trace = ring_regs[REG_LASTCMD];
	uint32_t counter = trace & 0xF;
	uint32_t last_cmd = (trace >> 4) & 0xF;
	uint32_t fnc = (trace >> 8) & 0xFF;

	if (!have_last) {
		have_last = 1;
		last_counter = counter;
		return;
	}
	if (counter != last_counter) {
		last_counter = counter;
		if (last_cmd == 0x2)  /* GETCMD - fnc is meaningful */
			log_msg("TRACE: dispatched %s, PCB function code 0x%02x", port_cmd_name(last_cmd), fnc);
		else
			log_msg("TRACE: dispatched %s", port_cmd_name(last_cmd));
	}
}

/* 8-entry command history (HIST0-7 + HIST_WPTR, see xu.vhd's xu_cmd_hist
 * comment) - the real fix for poll_cmd_trace()'s blind spot: a single
 * snapshot register can miss commands entirely during the driver's fast
 * init burst, but every completed dispatch gets recorded here, so this
 * reads back the FULL sequence after the fact instead of gambling on
 * catching each one at exactly the right poll instant. Known limit: if
 * more than 8 commands complete between two polls (unlikely for a normal
 * driver init, but possible), the oldest ones in that burst are silently
 * overwritten - same tradeoff any small ring history buffer has. */
static void poll_cmd_history(void)
{
	static int have_last = 0;
	static uint32_t last_wptr = 0;

	uint32_t wptr = ring_regs[REG_HIST_WPTR] & 0x7;
	if (!have_last) {
		have_last = 1;
		last_wptr = wptr;
		return;
	}
	if (wptr == last_wptr)
		return;

	uint32_t entries[8];
	for (int i = 0; i < 8; i++)
		entries[i] = ring_regs[REG_HIST0 + i] & 0xFFFF;

	uint32_t num_new = (wptr + 8 - last_wptr) % 8;
	for (uint32_t k = 0; k < num_new; k++) {
		uint32_t idx = (last_wptr + k) % 8;
		uint32_t e = entries[idx];
		uint32_t fnc = (e >> 8) & 0xFF;
		uint32_t cmd = (e >> 4) & 0xF;
		uint32_t seq = e & 0xF;
		if (cmd == 0x2)
			log_msg("HIST[seq=%u]: dispatched %s, PCB function code 0x%02x", seq, port_cmd_name(cmd), fnc);
		else
			log_msg("HIST[seq=%u]: dispatched %s", seq, port_cmd_name(cmd));
	}
	last_wptr = wptr;
}

static void *poll_thread_fn(void *arg)
{
	(void)arg;
	for (;;) {
		poll_cmd_trace();
		poll_cmd_history();
		uint32_t state = ring_regs[REG_PCSR1STATE] & 0xF;
		if (state == PCSR1_RUNNING)
			poll_tx();
		/* short interval regardless of state - the driver's init
		 * sequence (SELFTEST/GETPCBB/GETCMD/START) can happen faster
		 * than a slow idle poll would catch, and missing one of those
		 * defeats the whole point of this trace. (Tried 100us while
		 * chasing the hang; timing was never the variable - the real
		 * bug was DESC_STRIDE, see its comment - so this is back at
		 * 2ms rather than needlessly busy-polling the ARM side.) */
		usleep(2000);
	}
	return NULL;
}

/* ============ UIO / tap / bridge setup ============ */

static int find_uio_by_name(const char *name)
{
	DIR *d = opendir("/sys/class/uio");
	if (!d)
		return -1;

	struct dirent *e;
	int found = -1;
	while ((e = readdir(d)) != NULL) {
		if (strncmp(e->d_name, "uio", 3) != 0)
			continue;
		char path[256];
		snprintf(path, sizeof(path), "/sys/class/uio/%.200s/name", e->d_name);
		FILE *f = fopen(path, "r");
		if (!f)
			continue;
		char namebuf[128] = {0};
		if (fgets(namebuf, sizeof(namebuf), f)) {
			namebuf[strcspn(namebuf, "\n")] = 0;
			if (strcmp(namebuf, name) == 0)
				found = atoi(e->d_name + 3);
		}
		fclose(f);
		if (found >= 0)
			break;
	}
	closedir(d);
	return found;
}

static int open_ring_uio(void)
{
	int num = find_uio_by_name(RING_UIO_NAME);
	if (num < 0) {
		log_msg("no uio device named '%s' found", RING_UIO_NAME);
		return -1;
	}

	char devpath[32];
	snprintf(devpath, sizeof(devpath), "/dev/uio%d", num);
	int fd = open(devpath, O_RDWR);
	if (fd < 0) {
		log_msg("open %s failed: %s", devpath, strerror(errno));
		return -1;
	}

	void *m = mmap(NULL, RING_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) {
		log_msg("mmap %s failed: %s", devpath, strerror(errno));
		close(fd);
		return -1;
	}

	ring_regs = (volatile uint32_t *)m;
	log_msg("using %s for the ring bridge, mapped %d bytes", devpath, RING_MAP_SIZE);
	return 0;
}

static int open_tap(const char *ifname)
{
	int fd = open("/dev/net/tun", O_RDWR);
	if (fd < 0) {
		log_msg("open /dev/net/tun failed: %s", strerror(errno));
		return -1;
	}

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

	if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
		log_msg("TUNSETIFF %s failed: %s", ifname, strerror(errno));
		close(fd);
		return -1;
	}

	log_msg("opened tap device %s (fd %d)", ifname, fd);
	return fd;
}

/* Best-effort: bring tap0 up and join it to br0 alongside eth0. Logged,
 * not fatal, if any step fails - a re-run after the bridge already
 * exists should be a harmless no-op. */
static void setup_bridge(const char *ifname)
{
	char cmd[256];

	snprintf(cmd, sizeof(cmd), "ip link set %s up", ifname);
	system(cmd);

	if (system("brctl show br0 >/dev/null 2>&1") != 0) {
		/* Moving eth0 into the bridge drops whatever DHCP lease the
		 * system's own boot-time network scripts already obtained on
		 * it (br0, not eth0, is the interface that should carry the
		 * IP from here on) - re-acquire one explicitly on br0, or the
		 * board goes silently unreachable over IPv4 the moment this
		 * daemon starts at boot. This only ever worked untested
		 * before because it was manually re-run against a system
		 * whose network was already up and never needed re-DHCPing -
		 * a fresh boot via the init script hits this every time. See
		 * [[xu-ethernet-bridge]] memory. */
		log_msg("creating br0 and moving eth0 into it");
		system("pkill -f 'udhcpc.*-i eth0' 2>/dev/null");  /* stop the system's own eth0 lease client - it's about to become pointless */
		system("brctl addbr br0");
		system("ip link set eth0 down");
		system("brctl addif br0 eth0");
		system("ip link set eth0 up");
		system("ip link set br0 up");
		system("udhcpc -i br0 -b >/dev/null 2>&1");
		log_msg("requested a fresh DHCP lease on br0");
	} else {
		log_msg("br0 already exists - not rebuilding");
	}

	snprintf(cmd, sizeof(cmd), "brctl addif br0 %s 2>/dev/null", ifname);
	system(cmd);
}

int main(int argc, char **argv)
{
	const char *logpath = "/var/log/pdp11-netd.log";
	const char *ifname = "tap0";

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-l") == 0 && i + 1 < argc)
			logpath = argv[++i];
		else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc)
			ifname = argv[++i];
	}

	logf = fopen(logpath, "a");
	if (!logf)
		logf = stderr;

	clock_gettime(CLOCK_MONOTONIC, &start_ts);
	log_msg("=== pdp11-netd starting (pid %d) ===", getpid());

	if (open_ring_uio() < 0) {
		log_msg("FATAL: could not open the ring UIO device, exiting");
		return 1;
	}

	tap_fd = open_tap(ifname);
	if (tap_fd < 0) {
		log_msg("FATAL: could not open tap device, exiting");
		return 1;
	}

	setup_bridge(ifname);

	pthread_t poll_thr;
	if (pthread_create(&poll_thr, NULL, poll_thread_fn, NULL) != 0) {
		log_msg("FATAL: could not start poll thread: %s", strerror(errno));
		return 1;
	}

	uint8_t buf[RING_MAX_FRAME];
	for (;;) {
		ssize_t n = read(tap_fd, buf, sizeof(buf));
		if (n < 0) {
			log_msg("tap read failed: %s", strerror(errno));
			continue;
		}
		deliver_rx_frame(buf, (int)n);
	}

	return 0;
}
