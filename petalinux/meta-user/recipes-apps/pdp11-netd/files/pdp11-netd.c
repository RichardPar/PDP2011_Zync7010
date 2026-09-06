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
#include <poll.h>

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
#define REG_CMDEVT     (0x64 / 4)

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

/* The real DEUNA/DELUA is a 10base-T (10 Mbit) part, and a real PDP-11's
 * practical throughput ceiling - UNIBUS DMA plus the CPU's own frame
 * processing - sits well below even that nominal wire rate; 1 Mbit/s is
 * a reasonable estimate of what a real deployment could ever actually
 * sustain. eth0 on this board is Gigabit, so tap0 hands us frames at
 * whatever rate the real, modern, noisy LAN produces them - potentially
 * 1000x faster than anything this design was ever built to receive.
 * On real 10base-T hardware, each frame's own transmission takes real,
 * physical serialization time (preamble+frame+minimum interframe gap) -
 * an inherent, natural rate limiter that means bursts arrive spread out
 * over time, giving the guest's slow interrupt handler room to keep up
 * between frames. Bridging straight from Gigabit removes that limiter
 * entirely: a burst that a real 10base-T segment would serialize over
 * several milliseconds instead lands in well under one - measured on
 * hardware wrapping the guest's 6-descriptor RX ring twice in under a
 * second, with some arrivals only 64-350us apart, fast enough that a
 * genuine ARP/ICMP reply can be overwritten before the guest looks at
 * that slot (see [[xu-ethernet-bridge]]). Pacing RX delivery to emulate
 * the real link's serialization delay restores that natural throttle. */
/* NOTE (2026-09-06): set to 0 to DISABLE pacing entirely while isolating
 * a reply-delivery regression. The rate-limit idea is sound - the real
 * 10base-T wire genuinely serialized frames and gave the slow guest room
 * between them - but this implementation DELAYS without ever DROPPING,
 * so a burst of broadcast junk consumes the virtual-wire budget and a
 * latency-critical ICMP reply queues up behind it (and tap0's own queue
 * backs up while the main thread sits in nanosleep). A real overloaded
 * receiver drops instead of queueing. If re-enabled, add a bound: if the
 * virtual wire is already backed up beyond a few ms, drop the frame
 * rather than delaying it. See [[xu-ethernet-bridge]]. */
#define RX_LINK_RATE_BPS  0
/* preamble(7) + SFD(1) + minimum interframe gap - real per-frame
 * overhead that consumes wire time even though it never appears in the
 * captured frame length */
#define RX_FRAME_OVERHEAD_BYTES 20

static volatile uint32_t *ring_regs = NULL;
static int ring_uio_fd = -1;
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

/* The station address xu.vhd reports via FC_RDPHYAD. Must match
 * xu_phyad_w0/w1/w2 in xu.vhd. */
static const uint8_t xu_mac[6] = { 0x08, 0x00, 0x2b, 0x11, 0x22, 0x33 };

/* Do the address filtering a real DEUNA does in hardware. tap0 is on a
 * bridge, so it hands us every frame on the LAN - including unicast for
 * OTHER hosts and a steady drip of IPv6/mDNS/STP multicast. Each one we
 * forward costs hundreds of slow single-word DMA writes and, worse,
 * consumes one of only NRCV(=6) receive descriptors, which is how real
 * replies ended up dropped ("not owned") or delayed. The driver enables
 * no multicast addresses, so faithful behaviour is: our own address and
 * broadcast only. */
static int rx_addressed_to_us(const uint8_t *buf, int len)
{
	if (len < 6)
		return 0;
	if (memcmp(buf, xu_mac, 6) == 0)
		return 1;
	if (memcmp(buf, "\xff\xff\xff\xff\xff\xff", 6) == 0)
		return 1;
	return 0;
}

/* Returns 0 delivered, RX_BUSY if the guest has not re-armed the next
 * descriptor yet (caller should keep the frame queued and retry), or
 * RX_DROP for a frame that can never be delivered. */
#define RX_OK    0
#define RX_BUSY  1
#define RX_DROP  2

static int try_deliver_rx_frame(const uint8_t *buf, int len)
{
	uint32_t state = ring_regs[REG_PCSR1STATE] & 0xF;
	if (state != PCSR1_RUNNING)
		return RX_DROP;   /* guest isn't up yet - nothing to hold it for */

	uint32_t rdrb  = ring_regs[REG_RDRB] & 0x3FFFF;
	uint32_t rrlen = ring_regs[REG_RRLEN] & 0xFFFF;
	uint32_t rxnext = ring_regs[REG_RXNEXT] & 0xFFFF;
	if (rrlen == 0)
		return RX_DROP;   /* ring not configured yet */
	if (rxnext >= rrlen)
		rxnext = 0;

	if (len <= 0 || len > RING_MAX_FRAME) {
		log_msg("RX: implausible %d-byte frame from tap0, dropping", len);
		return RX_DROP;
	}

	uint32_t ba = rdrb + DESC_STRIDE * rxnext;
	uint16_t d[4];
	if (read_desc(ba, d) < 0)
		return RX_BUSY;   /* transient - try again shortly */

	if (!(d[2] & OWN_BIT))
		return RX_BUSY;   /* guest hasn't re-armed this slot - KEEP the frame */

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
		return RX_DROP;
	}

	uint32_t addr = ((uint32_t)(d[2] & 0x3) << 16) | d[1];
	uint32_t nwords = (plen + 1) / 2;
	for (uint32_t i = 0; i < nwords; i++) {
		uint32_t lo = (i * 2 < (uint32_t)len) ? buf[i * 2] : 0;
		uint32_t hi = (i * 2 + 1 < (uint32_t)len) ? buf[i * 2 + 1] : 0;
		if (mem_write_word(addr + i * 2, (uint16_t)(lo | (hi << 8))) < 0) {
			log_msg("RX: frame-data write failed at rxnext=%u, aborting this delivery", rxnext);
			return RX_DROP;
		}
	}

	uint16_t wb[4] = {
		d[0], d[1],
		(uint16_t)((d[2] & 0x7FFF) | STF_BIT | ENF_BIT),
		(uint16_t)(plen + RX_CRC_LEN)
	};
	if (write_desc(ba, wb) < 0) {
		log_msg("RX: descriptor writeback failed at rxnext=%u", rxnext);
		return RX_DROP;
	}

	uint32_t newnext = (rxnext + 1 >= rrlen) ? 0 : rxnext + 1;
	ring_regs[REG_RXNEXT] = newnext;

	strobe_interrupt(REG_SET_RXI);
	return RX_OK;
}

/* ============ pre-RX buffer ============
 *
 * eth0 here is Gigabit; the guest has NRCV=6 receive descriptors and a
 * real PDP-11's speed to drain them. Measured on hardware, ordinary
 * modern-LAN broadcast chatter wraps all 6 slots in well under a second
 * (some arrivals only 64-350us apart) - far faster than the guest's
 * interrupt handler can re-arm them. Previously a frame arriving with no
 * free descriptor was simply DROPPED on the spot, which is how genuine
 * ARP/ICMP replies went missing even though the wire showed them
 * arriving correctly within ~300us.
 *
 * This queue is the elastic buffer between the two rates: frames are
 * held here and fed into the ring only as the guest actually frees
 * descriptors, so a burst is absorbed instead of overwriting replies.
 * It is deliberately much deeper than the hardware ring - the whole
 * point is to ride out bursts the 6-slot ring cannot. Only a sustained
 * overload (queue genuinely full) drops, which is the correct place for
 * loss to happen. See [[xu-ethernet-bridge]]. */
#define RX_QUEUE_DEPTH 256

struct rx_qent {
	int len;
	uint8_t buf[RING_MAX_FRAME];
};
static struct rx_qent rx_q[RX_QUEUE_DEPTH];
static int rx_q_head;          /* next slot to write */
static int rx_q_tail;          /* next slot to read  */
static int rx_q_count;
static unsigned long rx_q_dropped;
static unsigned long rx_q_delivered;
static int rx_q_high_water;
static pthread_mutex_t rx_q_lock = PTHREAD_MUTEX_INITIALIZER;

/* Feed queued frames into the ring for as long as the guest has
 * descriptors free. Safe to call from either thread. Lock order is
 * always rx_q_lock -> ring_lock (mem_*_word takes the latter). */
/* Deliver at most this many frames per drain call. Without a bound, a
 * backlog gets dumped into the 6-slot ring in one tight loop with a
 * SET_RXI strobe per frame - an interrupt avalanche at exactly the
 * moment the guest is least able to cope. Real hardware is paced by the
 * wire; this stands in for that. */
#define RX_DRAIN_BURST 4

static void rx_queue_drain(void)
{
	int budget = RX_DRAIN_BURST;
	pthread_mutex_lock(&rx_q_lock);
	while (rx_q_count > 0 && budget-- > 0) {
		struct rx_qent *e = &rx_q[rx_q_tail];
		int rc = try_deliver_rx_frame(e->buf, e->len);
		if (rc == RX_BUSY)
			break;         /* no free descriptor - keep it queued */
		if (rc == RX_OK)
			rx_q_delivered++;
		rx_q_tail = (rx_q_tail + 1) % RX_QUEUE_DEPTH;
		rx_q_count--;
	}
	pthread_mutex_unlock(&rx_q_lock);
}

static void rx_queue_push(const uint8_t *buf, int len)
{
	if (len <= 0 || len > RING_MAX_FRAME)
		return;
	/* address filtering happens here, before the frame ever takes up
	 * queue space - exactly what a real DEUNA's address filter does */
	if (!rx_addressed_to_us(buf, len))
		return;

	pthread_mutex_lock(&rx_q_lock);
	if (rx_q_count >= RX_QUEUE_DEPTH) {
		rx_q_dropped++;
		if ((rx_q_dropped % 100) == 1)
			log_msg("RX: pre-RX queue full (%d frames), dropped %lu so far - "
				"guest cannot drain the ring fast enough",
				RX_QUEUE_DEPTH, rx_q_dropped);
		pthread_mutex_unlock(&rx_q_lock);
		return;
	}
	struct rx_qent *e = &rx_q[rx_q_head];
	memcpy(e->buf, buf, (size_t)len);
	e->len = len;
	rx_q_head = (rx_q_head + 1) % RX_QUEUE_DEPTH;
	rx_q_count++;
	if (rx_q_count > rx_q_high_water) {
		rx_q_high_water = rx_q_count;
		/* only at a few thresholds - this must not become a log storm */
		if (rx_q_high_water == 4 || rx_q_high_water == 16 ||
		    rx_q_high_water == 64 || rx_q_high_water == 192)
			log_msg("RX: pre-RX queue high-water %d frames (delivered %lu, dropped %lu)",
				rx_q_high_water, rx_q_delivered, rx_q_dropped);
	}
	pthread_mutex_unlock(&rx_q_lock);

	rx_queue_drain();
}

/* Measure what one word of PDP-11 memory access actually costs over the
 * AXI-Lite bridge. Every frame byte moves through this path - a 1500-byte
 * frame is 750 of these - so if a single word op is expensive, the whole
 * word-at-a-time design is the bottleneck and no amount of buffering or
 * interrupt tuning on either side will fix it. Reading is side-effect
 * free, so this is safe to run at startup before the guest is up. */
static void benchmark_mem_op(void)
{
	const int N = 2000;
	struct timespec t0, t1;
	int failures = 0;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 0; i < N; i++) {
		uint16_t w;
		if (mem_read_word(0, &w) < 0)
			failures++;
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);

	long long ns = (long long)(t1.tv_sec - t0.tv_sec) * 1000000000LL
		     + (t1.tv_nsec - t0.tv_nsec);
	long long per_op = ns / N;

	log_msg("BENCH: %d mem_read_word ops in %lld us => %lld ns/word "
		"(%d failures). A 98-byte frame = 49 words ~= %lld us; "
		"a 1500-byte frame = 750 words ~= %lld us.",
		N, ns / 1000, per_op, failures,
		(per_op * 49) / 1000, (per_op * 750) / 1000);
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

/* Do one round of the work that used to run on a bare 2ms timer. Common
 * to both the interrupt-driven wake and the timeout fallback below. */
static void poll_thread_work(void)
{
	poll_cmd_trace();
	poll_cmd_history();
	uint32_t state = ring_regs[REG_PCSR1STATE] & 0xF;
	if (state == PCSR1_RUNNING) {
		poll_tx();
		/* the guest re-arms RX descriptors from deintr(), so every wake
		 * is a chance to push more of the pre-RX queue into the ring */
		rx_queue_drain();
	}
}

/* 2026-09-06: this loop used to be `usleep(2000)` around the work above
 * with NOTHING event-driven at all - pdp11-netd opened the ring's UIO
 * device but never once called read() on it. Every guest-initiated event
 * (a new PDMD, a completed port command) had to wait for the next 2ms
 * tick to even be noticed, and measured on hardware this compounded into
 * TX bursts separated by 100+ SECOND gaps and ping RTTs up to 9 seconds -
 * see [[xu-ethernet-bridge]]. xu.vhd/xuring.vhd now toggle CMDEVT (0x64)
 * on every completed guest port command and fold that into `irq`, so we
 * block on the UIO fd and wake immediately instead.
 *
 * uio_pdrv_genirq masks the interrupt after it fires until userspace
 * writes a 4-byte "1" back to re-enable it - done once at open time in
 * open_ring_uio() and again after every wake here.
 *
 * poll() with a bounded timeout, not a bare blocking read(): if the IRQ
 * wiring ever turns out wrong (this project has been burned by exactly
 * that kind of device-tree/IRQ_F2P assumption before), this degrades to
 * the old ~10ms polling behaviour instead of hanging the daemon outright. */
#define POLL_FALLBACK_MS 10
/* NAPI-style burst drain. One UIO wake costs a full kernel round-trip
 * (read() to consume, write() to re-enable, plus the context switches);
 * paying that per EVENT is fine when idle but is far more overhead than
 * the old fixed timer once the guest is issuing commands rapidly. First
 * attempt did exactly that and regressed badly on hardware: 4030
 * mem_wait_idle timeouts, a renewed PDMD storm and a hung console,
 * because this thread spun through syscalls fast enough to starve the
 * main tap0 thread of `ring_lock`. So: once woken, keep draining while
 * CMDEVT still reports work pending, and only then re-arm and sleep -
 * bounded so a genuinely runaway guest can't starve the RX thread
 * either. See [[xu-ethernet-bridge]]. */
#define IRQ_DRAIN_MAX 32

static void *poll_thread_fn(void *arg)
{
	(void)arg;
	for (;;) {
		struct pollfd pfd = { .fd = ring_uio_fd, .events = POLLIN };
		int rc = poll(&pfd, 1, POLL_FALLBACK_MS);

		if (rc > 0 && (pfd.revents & POLLIN)) {
			uint32_t icount;
			ssize_t n = read(ring_uio_fd, &icount, sizeof(icount));
			if (n == (ssize_t)sizeof(icount)) {
				/* Drain the burst in-loop rather than taking another
				 * interrupt round-trip per event. Ack CMDEVT first
				 * each time so a still-asserted level doesn't just
				 * re-trigger the moment we re-enable. */
				for (int i = 0; i < IRQ_DRAIN_MAX; i++) {
					ring_regs[REG_CMDEVT] = 1;
					poll_thread_work();
					if (!(ring_regs[REG_CMDEVT] & 1))
						break;   /* nothing further pending */
				}
				uint32_t one = 1;
				if (write(ring_uio_fd, &one, sizeof(one)) != (ssize_t)sizeof(one))
					log_msg("warning: could not re-enable ring uio interrupt: %s",
						strerror(errno));
				continue;
			}
		}
		/* timeout, or a poll()/read() error - fall back to plain
		 * polling this round rather than getting stuck */
		poll_thread_work();
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
	ring_uio_fd = fd;
	log_msg("using %s for the ring bridge, mapped %d bytes", devpath, RING_MAP_SIZE);

	/* uio_pdrv_genirq (matches this device's "generic-uio" compatible
	 * string) starts with the IRQ line masked until userspace explicitly
	 * enables it by writing a 4-byte "1" - without this, read() below
	 * would block forever even once xu.vhd asserts irq. */
	uint32_t one = 1;
	if (write(fd, &one, sizeof(one)) != (ssize_t)sizeof(one))
		log_msg("warning: could not enable %s interrupt: %s", devpath, strerror(errno));

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

	benchmark_mem_op();

	setup_bridge(ifname);

	pthread_t poll_thr;
	if (pthread_create(&poll_thr, NULL, poll_thread_fn, NULL) != 0) {
		log_msg("FATAL: could not start poll thread: %s", strerror(errno));
		return 1;
	}

	/* virtual-wire-time model: the monotonic time at which a real
	 * 10base-T link running at RX_LINK_RATE_BPS would have finished
	 * serializing everything received so far. Initialised lazily on
	 * the first frame so idle time before it doesn't count against
	 * the budget. */
	struct timespec next_free = { 0, 0 };

	uint8_t buf[RING_MAX_FRAME];
	for (;;) {
		ssize_t n = read(tap_fd, buf, sizeof(buf));
		if (n < 0) {
			log_msg("tap read failed: %s", strerror(errno));
			continue;
		}

		if (RX_LINK_RATE_BPS > 0) {
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (next_free.tv_sec == 0 && next_free.tv_nsec == 0)
			next_free = now;
		if (now.tv_sec > next_free.tv_sec ||
		    (now.tv_sec == next_free.tv_sec && now.tv_nsec > next_free.tv_nsec))
			next_free = now;   /* link was idle - don't bank unused capacity */
		else {
			struct timespec delay = {
				.tv_sec  = next_free.tv_sec - now.tv_sec,
				.tv_nsec = next_free.tv_nsec - now.tv_nsec,
			};
			if (delay.tv_nsec < 0) {
				delay.tv_nsec += 1000000000L;
				delay.tv_sec  -= 1;
			}
			nanosleep(&delay, NULL);
		}

		long long bits = ((long long)n + RX_FRAME_OVERHEAD_BYTES) * 8;
		long long frame_ns = bits * 1000000000LL / RX_LINK_RATE_BPS;
		next_free.tv_nsec += frame_ns % 1000000000LL;
		next_free.tv_sec  += frame_ns / 1000000000LL;
		if (next_free.tv_nsec >= 1000000000L) {
			next_free.tv_nsec -= 1000000000L;
			next_free.tv_sec  += 1;
		}
		}

		rx_queue_push(buf, (int)n);
	}

	return 0;
}
