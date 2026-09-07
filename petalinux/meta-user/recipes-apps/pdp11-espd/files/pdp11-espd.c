/*
 * pdp11-espd - serve the PDP-11's XU (DEUNA) networking as a "virtual
 * ESP32": the PL side (xuaxi.vhd) exposes the exact same XF/RT/RL/SRDY
 * frame-buffer contract xu.vhd's embedded DEUNA microcode (xubw.mac, the
 * real upstream firmware) already speaks to a physical ESP32 over SPI -
 * this daemon reimplements the ESP32 firmware's own SPI-slave framing
 * (xuesp/main/app_spitask.c: hdrlen=12, receive-direction magic 0xaa 0x55,
 * transmit-direction magic 0xa0 0xa0) against a real Linux network
 * interface (a tap device bridged with eth0) instead of Wi-Fi.
 *
 * Unlike the two earlier from-scratch networking attempts (see memory
 * [[xu-ethernet-bridge]]), this daemon does NOT walk any descriptor ring or
 * implement any DEUNA port command - all of that already works, unmodified,
 * inside xu.vhd's embedded microcode. This daemon's only job is: move one
 * whole frame's worth of bytes each direction per "run", exactly like the
 * real ESP32 firmware does.
 *
 * xuaxi.vhd's AXI-Lite register map (32-bit words, byte addresses):
 *   [0x0000..0x0C7F] buffer window, one 16-bit PDP-11 word per 32-bit
 *                     location (low half), index = addr(11:2). A WRITE
 *                     here stores into rx_buf (this daemon -> core, i.e.
 *                     the frame the guest is about to receive); a READ
 *                     returns tx_buf (core -> this daemon, i.e. the frame
 *                     the guest just transmitted).
 *   [0x1000] STATUS (read)  bit0 = a fresh tx_buf is waiting
 *   [0x1004] LEN    (read)  the pending run's length, in bytes
 *   [0x1008] DONE   (write) tell the core tx_buf has been drained AND
 *                           rx_buf has been refreshed - de-asserts the irq
 *
 * Wire frame format inside each buffer (identical both directions except
 * for the header fields, ported byte-for-byte from app_spitask.c):
 *   byte 0-1   magic: 0xaa 0x55 (rx_buf, daemon->core) / 0xa0 0xa0
 *              (tx_buf, core->daemon)
 *   byte 2     rx_buf only: a free-running sequence counter
 *   byte 3     rx_buf only: queued-frame count (capped at 255)
 *   byte 4-5   big-endian frame length in bytes. rx_buf: 0 if nothing
 *              pending, else the real frame length + 4 (a fixed "as if
 *              there were a 4-byte FCS trailer" convention xubw.mac
 *              itself uses - the trailing 4 bytes' content is never
 *              actually checked by the microcode, confirmed by reading
 *              xubw.mac, so this daemon fills them with a real CRC32
 *              purely for protocol fidelity, not because anything
 *              enforces it). tx_buf: the real frame length, no +4 (the
 *              real ESP32 firmware appends its own 4-byte trailer only
 *              because esp_wifi_internal_tx() needs one - a Linux tap
 *              write() does not, so this daemon writes the tx_buf frame
 *              bytes straight to the tap device, no trailer).
 *   byte 6-11  rx_buf only: this daemon's chosen MAC address. xubw.mac's
 *              receive-handling code (see the comment on XU_MAC below)
 *              LATCHES this into its own "default physical address" the
 *              very first time it's seen (dbia is zero-initialized in
 *              ROM) - the guest driver adopts this as the interface's own
 *              MAC via its own FC_RDPHYAD probe. Written every single
 *              cycle (matching app_spitask.c exactly), not just once.
 *   byte 12..  the raw Ethernet frame, when length > 0
 *
 * Usage: pdp11-espd [-v] [-l <logfile>] [-i <tap-ifname>]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <signal.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/if.h>
#include <linux/if_tun.h>

/* Must cover the register block at 0x1000-0x1008, not just the buffer
 * window below it (0x0000-0x0C7F) - a bare 0x1000 would map bytes
 * [0, 0x1000) only, one byte short of REG_STATUS itself. */
#define MAP_SIZE       0x2000

#define REG_STATUS     (0x1000/4)
#define REG_LEN        (0x1004/4)
#define REG_DONE       (0x1008/4)
#define BUF_WORDS_MAX  800                /* must match xuaxi.vhd's buf_words */

#define PHYS_BASE      0x43020000UL
#define UIO_NAME       "pdp11net"

#define HDRLEN         12
#define MAXPAY         1518
#define MINRECVFRAME   128                /* app_spitask.c's own minimum, ported verbatim */

/* The station address xu.vhd's embedded microcode (xubw.mac) latches from
 * the first rx_buf header it ever sees (dbia/dlaa start zeroed in ROM, see
 * the "tst dbia" bootstrap around xubw.mac line 125) and the guest driver
 * then adopts via its own FC_RDPHYAD probe. 08-00-2b is DEC's real
 * registered IEEE OUI - a fitting, non-colliding choice for a virtual
 * DEUNA, and the same convention the earlier from-scratch attempt used
 * (see memory [[xu-ethernet-bridge]]) before this rewrite. */
static const uint8_t xu_mac[6] = { 0x08, 0x00, 0x2b, 0x11, 0x22, 0x33 };

static int verbose = 0;
static FILE *logfp = NULL;
static volatile sig_atomic_t g_stop = 0;

static uint64_t start_ms;

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void log_msg(const char *fmt, ...)
{
    struct timespec ts;
    va_list ap;
    char tbuf[32];

    if (!logfp) logfp = stderr;
    clock_gettime(CLOCK_REALTIME, &ts);
    strftime(tbuf, sizeof(tbuf), "%H:%M:%S", localtime(&ts.tv_sec));
    fprintf(logfp, "[%s +%llums] ", tbuf,
            (unsigned long long)(now_ms() - start_ms));
    va_start(ap, fmt);
    vfprintf(logfp, fmt, ap);
    va_end(ap);
    fputc('\n', logfp);
    fflush(logfp);
}

static void on_term(int sig) { (void)sig; g_stop = 1; }

/* CRC32 (standard poly 0xEDB88320), ported verbatim from app_spitask.c -
 * see the header comment above on why this daemon still computes one even
 * though xubw.mac never validates it. */
static uint32_t crc32(const uint8_t *s, size_t n)
{
    uint32_t crc = 0xFFFFFFFF;
    size_t i, j;
    for (i = 0; i < n; i++) {
        uint32_t b;
        uint8_t ch = s[i];
        for (j = 0; j < 8; j++) {
            b = (ch ^ crc) & 1;
            crc >>= 1;
            if (b) crc ^= 0xEDB88320;
            ch >>= 1;
        }
    }
    return ~crc;
}

/* read a small sysfs text file into buf (NUL-terminated, newline stripped) */
static int read_sysfs(const char *path, char *buf, size_t n)
{
    int fd = open(path, O_RDONLY), len;
    if (fd < 0) return -1;
    len = read(fd, buf, n - 1);
    close(fd);
    if (len <= 0) return -1;
    buf[len] = 0;
    if (buf[len-1] == '\n') buf[len-1] = 0;
    return 0;
}

/* find /dev/uioN by map0 physical address (primary), falling back to name -
 * same approach as pdp11-diskd's find_uio(). */
static int find_uio(uint32_t phys, const char *name, char *devpath, size_t n)
{
    DIR *d = opendir("/sys/class/uio");
    struct dirent *e;
    char p[300], val[64];
    int found = -1;

    if (!d) { log_msg("no /sys/class/uio"); return -1; }
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "uio", 3) != 0) continue;

        snprintf(p, sizeof(p), "/sys/class/uio/%s/maps/map0/addr", e->d_name);
        if (read_sysfs(p, val, sizeof(val)) == 0) {
            log_msg("uio %s map0 addr = 0x%s", e->d_name, val);
            if (strtoul(val, NULL, 0) == phys) {
                snprintf(devpath, n, "/dev/%s", e->d_name);
                found = 0;
                break;
            }
        }
        snprintf(p, sizeof(p), "/sys/class/uio/%s/name", e->d_name);
        if (read_sysfs(p, val, sizeof(val)) == 0 && strcmp(val, name) == 0) {
            snprintf(devpath, n, "/dev/%s", e->d_name);
            found = 0;
            break;
        }
    }
    closedir(d);
    if (found < 0) log_msg("no uio matching phys 0x%x or name '%s'",
                            (unsigned)phys, name);
    return found;
}

/* ------------------------------------------------------------------ *
 * tap device + bridge setup - ported verbatim from the earlier
 * from-scratch attempt's pdp11-netd.c (backup/deuna-swring-attempt-
 * 2026-09-06), including the DHCP-on-br0-not-eth0 fix documented there.
 * ------------------------------------------------------------------ */

static int open_tap(const char *ifname)
{
    int fd = open("/dev/net/tun", O_RDWR);
    struct ifreq ifr;

    if (fd < 0) {
        log_msg("open /dev/net/tun failed: %s", strerror(errno));
        return -1;
    }

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

/* Best-effort: bring tap0 up and join it to br0 alongside eth0. Logged, not
 * fatal, if any step fails - a re-run after the bridge already exists
 * should be a harmless no-op. */
static void setup_bridge(const char *ifname)
{
    char cmd[256];

    snprintf(cmd, sizeof(cmd), "ip link set %s up", ifname);
    system(cmd);

    if (system("brctl show br0 >/dev/null 2>&1") != 0) {
        /* Moving eth0 into the bridge drops whatever DHCP lease the
         * system's own boot-time network scripts already obtained on it
         * (br0, not eth0, is the interface that should carry the IP from
         * here on) - re-acquire one explicitly on br0, or the board goes
         * silently unreachable over IPv4 the moment this daemon starts at
         * boot. See memory [[xu-ethernet-bridge]]. */
        log_msg("creating br0 and moving eth0 into it");
        system("pkill -f 'udhcpc.*-i eth0' 2>/dev/null");
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

/* ------------------------------------------------------------------ *
 * RX queue - frames read off tap0 by a dedicated thread (mirrors the real
 * ESP32 firmware's own architecture: a WiFi-driver receive callback fills
 * a FreeRTOS queue, decoupled from the SPI-transaction cadence that drains
 * it - see app_wifi.c's wlan_sta_rx_callback / recv_queue). A small fixed
 * ring buffer is enough; PDMD-driven "runs" happen far faster than real
 * LAN traffic arrives.
 * ------------------------------------------------------------------ */

#define RXQ_DEPTH 20

typedef struct {
    uint8_t buf[MAXPAY];
    int     len;
} rxframe_t;

static rxframe_t rxq[RXQ_DEPTH];
static int rxq_head = 0, rxq_tail = 0, rxq_count = 0;
static pthread_mutex_t rxq_lock = PTHREAD_MUTEX_INITIALIZER;

/* Do the address filtering a real DEUNA does in hardware - and the exact
 * scope validated in the earlier from-scratch attempt (see memory
 * [[xu-ethernet-bridge]]): our own address or broadcast ONLY, nothing
 * protocol-specific. tap0 is a bridge member, so it still sees broadcast/
 * multicast LAN chatter (ARP for other hosts, mDNS, SSDP, ...) regardless
 * of MAC learning - faithfully matching real hardware means dropping all
 * of that here rather than forwarding it into one of the guest's few
 * receive descriptors. */
static int rx_addressed_to_us(const uint8_t *buf, int len)
{
    if (len < 6) return 0;
    if (memcmp(buf, xu_mac, 6) == 0) return 1;
    if (memcmp(buf, "\xff\xff\xff\xff\xff\xff", 6) == 0) return 1;
    return 0;
}

static void *rx_thread(void *arg)
{
    int fd = *(int *)arg;
    uint8_t buf[MAXPAY];

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) { if (g_stop) break; continue; }
            log_msg("rx_thread: read(tap) failed: %s", strerror(errno));
            break;
        }
        if (n < 1) continue;
        if (!rx_addressed_to_us(buf, (int)n)) continue;

        pthread_mutex_lock(&rxq_lock);
        if (rxq_count < RXQ_DEPTH) {
            memcpy(rxq[rxq_head].buf, buf, (size_t)n);
            rxq[rxq_head].len = (int)n;
            rxq_head = (rxq_head + 1) % RXQ_DEPTH;
            rxq_count++;
        } /* else: queue full, drop - matches a real NIC's ring-full behaviour */
        pthread_mutex_unlock(&rxq_lock);
    }
    return NULL;
}

/* Pop one queued frame into `out` (caller-supplied, >= MAXPAY bytes).
 * Returns the frame length, or -1 if the queue is empty. `remaining` (may
 * be NULL) gets the queue depth AFTER the pop, for the header's queued-
 * count field. */
static int rxq_pop(uint8_t *out, int *remaining)
{
    int len = -1;
    pthread_mutex_lock(&rxq_lock);
    if (rxq_count > 0) {
        len = rxq[rxq_tail].len;
        memcpy(out, rxq[rxq_tail].buf, (size_t)len);
        rxq_tail = (rxq_tail + 1) % RXQ_DEPTH;
        rxq_count--;
    }
    if (remaining) *remaining = rxq_count;
    pthread_mutex_unlock(&rxq_lock);
    return len;
}

/* ------------------------------------------------------------------ *
 * Buffer-window word <-> byte helpers. Wire/byte-order convention (see
 * xuaxi.vhd's header): PDP-11 memory address N = wire byte N, i.e. word i
 * holds byte 2i in bits(7:0) and byte 2i+1 in bits(15:8).
 * ------------------------------------------------------------------ */

static void bytes_to_words(const uint8_t *b, int nbytes, volatile uint32_t *regs)
{
    int i;
    for (i = 0; i < (nbytes + 1) / 2; i++) {
        uint16_t lo = (uint16_t)b[2 * i];
        uint16_t hi = (2 * i + 1 < nbytes) ? (uint16_t)b[2 * i + 1] : 0;
        regs[i] = (uint32_t)(lo | (hi << 8));
    }
}

static void words_to_bytes(volatile uint32_t *regs, int nbytes, uint8_t *b)
{
    int i;
    for (i = 0; i < (nbytes + 1) / 2; i++) {
        uint32_t w = regs[i];
        b[2 * i] = (uint8_t)(w & 0xff);
        if (2 * i + 1 < nbytes) b[2 * i + 1] = (uint8_t)((w >> 8) & 0xff);
    }
}

int main(int argc, char **argv)
{
    const char *logpath = NULL;
    const char *ifname = "tap0";
    char uiodev[64];
    int uiofd, tapfd;
    volatile uint32_t *regs;
    pthread_t rxtid;
    uint8_t rxseq = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) verbose = 1;
        else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) logpath = argv[++i];
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) ifname = argv[++i];
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            fprintf(stderr, "usage: pdp11-espd [-v] [-l <logfile>] [-i <tap-ifname>]\n");
            return 1;
        }
    }

    start_ms = now_ms();
    if (!logpath) logpath = "/var/log/pdp11-espd.log";
    logfp = fopen(logpath, "a");
    if (!logfp) { logfp = stderr; log_msg("cannot open %s (%s), logging to stderr",
                                          logpath, strerror(errno)); }
    setvbuf(logfp, NULL, _IOLBF, 0);
    log_msg("=== pdp11-espd starting (pid %d) ===", (int)getpid());

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    if (find_uio(PHYS_BASE, UIO_NAME, uiodev, sizeof(uiodev)) < 0) {
        log_msg("FATAL: no UIO device found (phys 0x%lx, name '%s')",
                (unsigned long)PHYS_BASE, UIO_NAME);
        return 1;
    }
    log_msg("using %s", uiodev);
    uiofd = open(uiodev, O_RDWR);
    if (uiofd < 0) {
        log_msg("FATAL: open %s: %s", uiodev, strerror(errno));
        return 1;
    }
    regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, uiofd, 0);
    if (regs == MAP_FAILED) {
        log_msg("FATAL: mmap: %s", strerror(errno));
        return 1;
    }
    log_msg("mapped %d bytes (phys 0x%lx)", MAP_SIZE, (unsigned long)PHYS_BASE);

    tapfd = open_tap(ifname);
    if (tapfd < 0) {
        log_msg("FATAL: could not open tap device %s", ifname);
        return 1;
    }
    setup_bridge(ifname);

    if (pthread_create(&rxtid, NULL, rx_thread, &tapfd) != 0) {
        log_msg("FATAL: pthread_create(rx_thread) failed: %s", strerror(errno));
        return 1;
    }

    log_msg("serving XU network bridge: MAC %02x:%02x:%02x:%02x:%02x:%02x, "
            "tap=%s", xu_mac[0], xu_mac[1], xu_mac[2], xu_mac[3], xu_mac[4],
            xu_mac[5], ifname);

    for (;;) {
        uint8_t txbytes[HDRLEN + MAXPAY];
        uint8_t rxbytes[HDRLEN + MAXPAY];
        rxframe_t popped;
        int txlen, rxlen, rxremaining;
        int have_rx;

        if (g_stop) break;

        /* Same "check STATUS before blocking" idiom as pdp11-diskd's
         * serve_bus() - a request already latched before we opened the
         * UIO device (e.g. very early guest polling) would otherwise be
         * missed. */
        if (!(regs[REG_STATUS] & 1)) {
            uint32_t one = 1, cnt;
            ssize_t r;
            if (write(uiofd, &one, sizeof(one)) < 0)
                log_msg("write(uio, enable) failed: %s", strerror(errno));
            r = read(uiofd, &cnt, sizeof(cnt));
            if (r < 0) {
                if (errno == EINTR) { if (g_stop) break; continue; }
                log_msg("read(uio) failed: %s", strerror(errno));
                break;
            }
        }

        if (!(regs[REG_STATUS] & 1)) continue;   /* spurious wake */

        /* ---- drain tx_buf: the frame the guest just transmitted ---- */
        txlen = (int)(regs[REG_LEN] & 0x7ff);   /* bytes, matches xuaxi's 11-bit RL */
        if (txlen > (int)sizeof(txbytes)) txlen = sizeof(txbytes);
        words_to_bytes(regs, txlen, txbytes);

        if (txlen >= HDRLEN && txbytes[0] == 0xa0 && txbytes[1] == 0xa0) {
            int framelen = (txbytes[4] << 8) | txbytes[5];
            if (framelen > 0 && framelen <= txlen - HDRLEN && framelen <= MAXPAY) {
                ssize_t wr = write(tapfd, txbytes + HDRLEN, (size_t)framelen);
                if (wr < 0)
                    log_msg("write(tap) failed: %s", strerror(errno));
                else if (verbose)
                    log_msg("TX: %d bytes forwarded to %s", framelen, ifname);
            } else if (framelen > 0) {
                log_msg("TX: bad/oversized frame length %d (txlen=%d) - dropped",
                         framelen, txlen);
            }
        }

        /* ---- refresh rx_buf: the next frame (if any) for the guest ---- */
        have_rx = (rxlen = rxq_pop(popped.buf, &rxremaining)) >= 0;

        memset(rxbytes, 0, sizeof(rxbytes));
        rxbytes[0] = 0xaa;
        rxbytes[1] = 0x55;
        rxbytes[2] = rxseq++;
        rxbytes[3] = (uint8_t)(rxremaining > 255 ? 255 : rxremaining);
        memcpy(rxbytes + 6, xu_mac, 6);   /* every cycle - see the header comment */

        if (have_rx) {
            int framelen = rxlen;
            int wirelen = framelen;
            uint32_t crc;
            if (wirelen < MINRECVFRAME) wirelen = MINRECVFRAME;
            memcpy(rxbytes + HDRLEN, popped.buf, (size_t)framelen);
            if (wirelen > framelen)
                memset(rxbytes + HDRLEN + framelen, 0, (size_t)(wirelen - framelen));
            crc = crc32(rxbytes + HDRLEN, (size_t)wirelen);
            /* trailer content is never checked by xubw.mac - written anyway
             * for wire-format fidelity, see the file header comment */
            if (HDRLEN + wirelen + 4 <= (int)sizeof(rxbytes)) {
                rxbytes[HDRLEN + wirelen + 0] = (uint8_t)(crc & 0xff);
                rxbytes[HDRLEN + wirelen + 1] = (uint8_t)((crc >> 8) & 0xff);
                rxbytes[HDRLEN + wirelen + 2] = (uint8_t)((crc >> 16) & 0xff);
                rxbytes[HDRLEN + wirelen + 3] = (uint8_t)((crc >> 24) & 0xff);
            }
            wirelen += 4;   /* "as if a 4-byte FCS trailer", per xubw.mac's own convention */
            rxbytes[4] = (uint8_t)((wirelen >> 8) & 0xff);
            rxbytes[5] = (uint8_t)(wirelen & 0xff);
            if (verbose)
                log_msg("RX: %d bytes delivered from queue (remaining=%d)",
                         framelen, rxremaining);
            rxlen = HDRLEN + wirelen;
        } else {
            rxlen = HDRLEN;
        }

        if (rxlen > (int)sizeof(rxbytes)) rxlen = (int)sizeof(rxbytes);
        if (rxlen > BUF_WORDS_MAX * 2) rxlen = BUF_WORDS_MAX * 2;
        bytes_to_words(rxbytes, rxlen, regs);

        /* tell the core: tx_buf drained, rx_buf refreshed */
        regs[REG_DONE] = 0;
    }

    log_msg("=== pdp11-espd exiting ===");
    if (logfp != stderr) fclose(logfp);
    return 0;
}
