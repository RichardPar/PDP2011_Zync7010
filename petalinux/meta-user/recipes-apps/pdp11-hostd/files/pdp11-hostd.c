/*
 * pdp11-hostd - serve every PS-facing PDP-11 device bridge from one process:
 * the RL and RH/RP06 disks (sddisk.vhd, image files on the PS) and the XU
 * (DEUNA) network bridge (xuaxi.vhd, a "virtual ESP32" - see
 * docs/xu-networking-plan.md). All three now share one AXI-Lite expansion
 * bus in the FPGA fabric (vivado/scripts/02_create_bd.tcl); this merge
 * makes the PS side match: one daemon, one binary, one init service,
 * instead of the earlier pdp11-diskd (disks only) + pdp11-espd (network
 * only) pair.
 *
 * Two independent kinds of served device, each generalized over its own
 * struct + serving thread - not squeezed into one shape, since they share
 * nothing but the find_uio()/arm-then-block-on-UIO-read idiom:
 *
 *   DISKS (bus_t, serve_bus()) - RL11 (RL01/RL02), up to 4 units (DL0..3),
 *   and RH11/RP06 (one unit, DB0). Register map: [0x000..0x3FC] sector
 *   buffer, [0x800] STATUS, [0x804] BLOCK, [0x808] DONE. Unchanged from
 *   pdp11-diskd.c - see that history in memory [[rp06-axi-bridge-diskd]].
 *
 *   NETWORK (net_t, serve_net()) - the XU bridge, one instance. Register
 *   map: [0x0000..0x0C7F] buffer window (write->rx_buf, read->tx_buf),
 *   [0x1000] STATUS, [0x1004] LEN, [0x1008] DONE. Unchanged from
 *   pdp11-espd.c - see docs/xu-networking-plan.md for the full wire-format
 *   writeup (this file keeps that comment trimmed to just what's needed
 *   here).
 *
 * Each served device is independently optional at runtime: RL is required
 * (fatal if its UIO device isn't found), RH and network are both "disabled
 * this run" if their UIO devices aren't present - e.g. a bitstream built
 * with have_xu_net=0 (see zynq_top.vhd) still serves disks normally.
 *
 * Usage: pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <imgdir>]
 *                    [-c <configfile>] [-R <rh0-image>] [-i <tap-ifname>]
 *                    [-l <logfile>] [<dl0-image> [<dl1-image> ...]]
 *   positional image files map to RL DL0, DL1, ... in order (initial seed
 *                only - see persistent config below)
 *   -R <img>     initial image for the RH0 (RP06/DB0) drive (seed only)
 *   -i <ifname>  tap device name for the network bridge (default tap0)
 *   -v           log every disk block request with a hex dump of the
 *                first words, and every network TX/RX with byte counts
 *   -p <port>    REST API port (default 8080, 0 disables) - swap disk
 *                images live
 *   -D <dir>     directory that GET /images lists (default /srv/pdp11)
 *   -c <file>    persistent disk config file (default /srv/pdp11/diskd.conf)
 *   -l <file>    write the log to <file> (default /var/log/pdp11-hostd.log;
 *                falls back to stderr)
 *
 * PERSISTENT CONFIG: which image is loaded into which disk unit, on both
 * busses, is written to the config file on every successful load/unload,
 * and read back at startup - the daemon always comes back up serving the
 * same set of disks it was serving when it last changed, across a reboot.
 *
 * REST API (swap disk images on a running system, no reboot) - disk-only,
 * network has no REST surface (nothing to swap live):
 *   GET  /status                    per-bus, per-unit loaded state + counters
 *   GET  /images                    *.img files available in <imgdir> (JSON)
 *   POST /load?unit=<spec>&path=P   load image P into <spec> (GET also works)
 *   POST /unload?unit=<spec>        unload <spec>
 *   POST /reset                     pulse the PDP-11-only reset
 *   <spec> is a bus+unit like "rl0", "rl1", "rh0" - or a bare number ("0",
 *   "1", ...), which means RL for backward compatibility with the original
 *   RL-only API. An explicit dev=rl|rh query param also selects the bus.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <ctype.h>
#include <dirent.h>
#include <signal.h>
#include <poll.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/if.h>
#include <linux/if_tun.h>

#include "httpd.h"
#include "www_data.h"

#define RESET_PHYS   0x41200000UL    /* axi_gpio_reset: PDP-11-only reset GPIO */
#define DISK_MAP_SIZE 0x1000

/* disk register word offsets (byte offset / 4) - identical on both busses */
#define REG_STATUS   (0x800/4)
#define REG_BLOCK    (0x804/4)
#define REG_DONE     (0x808/4)

#define MAX_UNITS    4                /* RL: DL0..DL3. RH uses only unit 0 */
#define MAX_BUF_WORDS 256             /* largest sector buffer of any bus (RH) */

/* network: must cover the register block at 0x1000-0x1008, not just the
 * buffer window below it (0x0000-0x0C7F) - a bare 0x1000 would map bytes
 * [0, 0x1000) only, one byte short of NET_REG_STATUS itself. */
#define NET_MAP_SIZE    0x2000
#define NET_REG_STATUS    (0x1000/4)
#define NET_REG_LEN       (0x1004/4)
#define NET_REG_DONE      (0x1008/4)
#define NET_REG_HEARTBEAT (0x100c/4)   /* free-running, xu0 clk domain - see xuaxi.vhd */
#define NET_REG_DEBUG1    (0x1010/4)   /* bit0-2 = DMA FSM state, bit3 = srdy */
#define NET_REG_RUNSTATS  (0x1014/4)   /* [15:0]=run_start_count [31:16]=run_done_count */
#define NET_REG_DEBUG2    (0x1018/4)   /* [15:0]=PCSR0 [19:16]=PCSR1 state [20]=outer npr [21]=outer npg
                                        * [22]=xubm npr [23]=xubm npg [24]=cpu0 npr [25]=cpu0 npg */
#define NET_REG_DEBUG3    (0x101c/4)   /* [15:0]=ifetch_count [31:16]=xubm_run_count */

/* how long HEARTBEAT can go unchanged before we call xu0 wedged, not idle */
#define NET_HEARTBEAT_STALE_MS 5000
#define NET_BUF_WORDS_MAX 800          /* must match xuaxi.vhd's buf_words */
#define NET_PHYS_BASE   0x43020000UL
#define NET_UIO_NAME    "pdp11net"

#define HDRLEN         12
#define MAXPAY         1518
#define MINRECVFRAME   128            /* app_spitask.c's own minimum, ported verbatim */

static int verbose = 0;
static int swap = 0;              /* -s: byte-swap each disk word (default off = correct order) */
static int do_reset = 0;         /* -r: pulse the PDP-11-only reset once we are ready */
static FILE *logfp = NULL;
static volatile sig_atomic_t g_stop = 0;

/*
 * One AXI-Lite "sddisk" bridge + the drive(s) it serves. RL and RH are two
 * independent instances of this; a serving thread runs serve_bus() against
 * each present one. img_lock guards every bus's imgfd/imgpath arrays and the
 * served/last_req_ms counters below: each serving thread holds it across a
 * request's file I/O (so a swap can never land mid-transfer) and while
 * updating its stats, do_load/do_unload hold it while swapping an fd, and
 * config save/load are consistent across busses.
 */
typedef struct {
   const char *name;               /* "RL" / "RH" - log prefix, JSON key, config prefix */
   const char *unit_prefix;        /* "DL" / "DB" - per-unit drive letter for logging */
   uint32_t    phys_base;          /* AXI-Lite base addr - matches the UIO map0 addr */
   const char *uio_name;           /* fallback uio name match (device-tree linux,uio-name) */
   int         buf_words;          /* sector buffer words actually moved */
   int         sector_bytes;       /* bytes per sector on this bus (buf_words * 2, or less) */
   int         max_units;          /* 4 for RL, 1 for RH (the core supports one RH drive) */
   int         min_units;          /* units the web panel always draws, mounted or not;
                                    * above this a drive only appears once something is
                                    * actually configured into it (see "show" in the
                                    * panel JSON). The RL11 core addresses four, but a
                                    * real installation here runs two. */
   int         unit_sectors;       /* linear BLOCK stride per unit; unused when max_units==1 */
   int         dlfix;              /* RL-only DL$UN workaround, see -d */
   int         required;           /* FATAL if its UIO device isn't found (RL only) */

   /* real drive geometry - only the web panel uses it, to turn a linear
    * sector number back into the cylinder the heads would be sitting on */
   const char *ctrl;               /* "RL11" / "RH11" - controller nameplate */
   const char *model;              /* "RL02" / "RP06" - drive nameplate      */
   int         sectors_per_cyl;
   int         cyls;

   int    imgfd[MAX_UNITS];
   char  *imgpath[MAX_UNITS];
   int    imgro[MAX_UNITS];        /* image opened read-only -> WRITE PROT   */

   /* Per-unit live counters for the panel. Written in serve_bus() while it
    * holds img_lock (which it already takes around the request's file I/O),
    * read by the panel snapshot under the same lock - so the 64-bit values
    * can't tear on this 32-bit target. */
   volatile uint64_t u_reads[MAX_UNITS], u_writes[MAX_UNITS], u_errors[MAX_UNITS];
   volatile uint32_t u_block[MAX_UNITS];       /* last sector within the unit */
   volatile uint64_t u_last_ms[MAX_UNITS], u_err_ms[MAX_UNITS];

   volatile uint32_t *regs;
   int uiofd;
   int present;                    /* uio found + mmap'd, thread should run */

   volatile uint64_t served;
   volatile uint64_t last_req_ms;
} bus_t;

static pthread_mutex_t img_lock = PTHREAD_MUTEX_INITIALIZER;

static bus_t g_rl = {
   .name = "RL", .unit_prefix = "DL",
   .phys_base = 0x43000000UL, .uio_name = "pdp11disk",
   .buf_words = 128, .sector_bytes = 256, .max_units = 4,
   .min_units = 2,
   .unit_sectors = 40960, .required = 1,
   /* RL02: 2 surfaces x 40 sectors = 80 sectors/cylinder, 512 cylinders */
   .ctrl = "RL11", .model = "RL02", .sectors_per_cyl = 80, .cyls = 512,
};
static bus_t g_rh = {
   .name = "RH", .unit_prefix = "DB",
   .phys_base = 0x43010000UL, .uio_name = "pdp11disk-rh",
   .buf_words = 256, .sector_bytes = 512, .max_units = 1,
   .min_units = 1,
   .unit_sectors = 0, .required = 0,
   /* RP06: 19 tracks x 22 sectors = 418 sectors/cylinder, 815 cylinders */
   .ctrl = "RH11", .model = "RP06", .sectors_per_cyl = 418, .cyls = 815,
};
static bus_t *g_buses[2] = { &g_rl, &g_rh };
#define NBUSES 2

/* The XU (DEUNA) network bridge - one instance, no image file, a
 * completely different register map/wire protocol from the disks above
 * (see the file header) so it gets its own struct rather than being
 * shoehorned into bus_t. */
typedef struct {
   const char *uio_name;
   uint32_t    phys_base;
   const char *ifname;             /* tap device name, -i to override */

   volatile uint32_t *regs;
   int uiofd;
   int tapfd;
   int present;

   /* heartbeat tracking, written only by heartbeat_thread() */
   uint32_t heartbeat_last;
   uint64_t heartbeat_last_change_ms;
   int      heartbeat_alive;

   /*
    * Whether the GUEST is actually driving the device, which is a different
    * question from whether xu0 is alive. HEARTBEAT free-runs in xu0's clock
    * domain whenever the fabric is powered, so it says nothing about the
    * PDP-11 side; RUNSTATS' start counter only advances when the microcode
    * runs a DMA cycle for a driver. Tracked here so the panel can tell
    * "no driver has ever touched this" from "driver present but quiet".
    */
   uint32_t run_start_last;
   uint64_t run_last_change_ms;     /* 0 = never seen it move */
} net_t;

static net_t g_net = {
   .uio_name = NET_UIO_NAME, .phys_base = NET_PHYS_BASE, .ifname = "tap0",
   .uiofd = -1, .tapfd = -1,
};

/* Used by the RX filter further down, but reported by build_status_json()
 * which sits above it, so they are defined here.
 *
 * guest_ip: the guest's own IPv4 address, learned by snooping what it
 * transmits (it is configured inside the guest with ifconfig, so we are
 * never told it). Big-endian exactly as it appears on the wire; 0 = not
 * yet known. Written only by serve_net's thread, read only by rx_thread;
 * a 32-bit aligned load/store is atomic on this target, and the worst case
 * of a stale read is one extra frame accepted or dropped. */
static volatile uint32_t guest_ip = 0;

/* RX filter/queue stats, for judging whether the guest is being buried in
 * noise and whether we are ever having to drop on our own side. */
static volatile unsigned long rx_acc_unicast, rx_acc_bcast,
                              rx_drop_bcast, rx_drop_other, rx_drop_qfull;

/* TX queue stats (defined here for build_status_json above the queue). */
static volatile unsigned long tx_enq, tx_written, tx_drop_qfull;

/* Byte counts and last-activity timestamps - the panel's XMIT/RECV lamps and
 * rate meters need "how much, how recently", which the frame counters above
 * don't carry. Same relaxed-atomicity argument as guest_ip: worst case is one
 * stale sample in a display refreshed 10x a second. */
static volatile unsigned long long net_tx_bytes, net_rx_bytes;
static volatile unsigned long      net_rx_deliv;    /* frames handed to the guest */
static volatile uint64_t           net_last_tx_ms, net_last_rx_ms;

/* The station address xu.vhd's embedded microcode (xubw.mac) latches from
 * the first rx_buf header it ever sees (dbia/dlaa start zeroed in ROM, see
 * the "tst dbia" bootstrap around xubw.mac line 125) and the guest driver
 * then adopts via its own FC_RDPHYAD probe. 08-00-2b is DEC's real
 * registered IEEE OUI - a fitting, non-colliding choice for a virtual
 * DEUNA, and the same convention the earlier from-scratch attempt used
 * (see memory [[xu-ethernet-bridge]]) before pdp11-espd. */
static const uint8_t xu_mac[6] = { 0x08, 0x00, 0x2b, 0x11, 0x22, 0x33 };

static const char *img_dir = "/srv/pdp11";   /* GET /images lists *.img here    */
static int    http_port = 8080;          /* HTTP/WS port; -p N, -p 0 disables   */
static const char *config_path = "/srv/pdp11/diskd.conf";
static const char *www_dir = NULL;       /* -W dir: serve the UI from disk      */
static httpd_t *g_httpd = NULL;

/* monotonic ms since boot */
static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static uint64_t start_ms;

/* log a line with timestamp and monotonic offset */
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

/* pulse the PDP-11-only reset GPIO (axi_gpio_reset) via /dev/mem: 1 then 0.
 * Used at startup so a cold boot re-runs the PDP-11 boot ROM with this daemon
 * already serving, instead of the PDP-11 stalling on its power-on block-0 read
 * until Linux is up. Needs the ddr_mem reset-drain fix for a clean restart. */
/* when the PDP-11 was last reset, so the panel can show it. 0 = not since
 * this daemon started. */
static uint64_t g_last_reset_ms;

/*
 * Pulse the PDP-11-only reset GPIO. Returns 0, or -errno if the register
 * couldn't be reached - the REST caller needs to be told the difference,
 * so this reports rather than only logging (it used to be void, called
 * once from main under -r).
 */
static int pulse_reset(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *gpio;
    unsigned long page = RESET_PHYS & ~0xFFFUL;
    int err;
    if (fd < 0) {
        err = errno;
        log_msg("reset: open /dev/mem: %s", strerror(err));
        return -err;
    }
    gpio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                (off_t)page);
    if (gpio == MAP_FAILED) {
        err = errno;
        log_msg("reset: mmap: %s", strerror(err));
        close(fd);
        return -err;
    }
    gpio[(RESET_PHYS - page) / 4] = 1;
    usleep(300000);
    gpio[(RESET_PHYS - page) / 4] = 0;
    munmap((void*)gpio, 0x1000);
    close(fd);
    g_last_reset_ms = now_ms();
    log_msg("pulsed PDP-11-only reset (0x%lx)", (unsigned long)RESET_PHYS);
    return 0;
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

/* find /dev/uioN by map0 physical address (primary match), falling back to name */
static int find_uio(uint32_t phys, const char *name, char *devpath, size_t n)
{
    DIR *d = opendir("/sys/class/uio");
    struct dirent *e;
    char p[300], val[64];
    int found = -1;

    if (!d) { log_msg("no /sys/class/uio"); return -1; }
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "uio", 3) != 0) continue;

        /* primary: match the mapped physical address */
        snprintf(p, sizeof(p), "/sys/class/uio/%s/maps/map0/addr", e->d_name);
        if (read_sysfs(p, val, sizeof(val)) == 0) {
            log_msg("uio %s map0 addr = 0x%s", e->d_name, val);
            if (strtoul(val, NULL, 0) == phys) {
                snprintf(devpath, n, "/dev/%s", e->d_name);
                found = 0;
                break;
            }
        }
        /* fallback: match the uio name */
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

/* open + mmap a bus's UIO device. 0 = ok, -1 = not found/failed (non-fatal
 * for a bus with required==0: RP06 support just stays disabled this run). */
static int setup_bus(bus_t *b)
{
    char uiodev[64];
    if (find_uio(b->phys_base, b->uio_name, uiodev, sizeof(uiodev)) < 0) {
        log_msg("%s: no UIO device found (phys 0x%x) - %s", b->name,
                (unsigned)b->phys_base,
                b->required ? "FATAL" : "disabled this run");
        return -1;
    }
    log_msg("%s: using %s", b->name, uiodev);
    b->uiofd = open(uiodev, O_RDWR);
    if (b->uiofd < 0) {
        log_msg("%s: open %s: %s", b->name, uiodev, strerror(errno));
        return -1;
    }
    b->regs = mmap(NULL, DISK_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, b->uiofd, 0);
    if (b->regs == MAP_FAILED) {
        log_msg("%s: mmap: %s", b->name, strerror(errno));
        close(b->uiofd);
        b->uiofd = -1;
        return -1;
    }
    log_msg("%s: mapped %d bytes at %p (phys 0x%x)", b->name, DISK_MAP_SIZE,
            (void*)b->regs, (unsigned)b->phys_base);
    log_msg("%s: initial STATUS = 0x%08x BLOCK = 0x%08x", b->name,
            b->regs[REG_STATUS], b->regs[REG_BLOCK]);
    b->present = 1;
    return 0;
}

/* open + mmap the network bridge's UIO device. 0 = ok, -1 = not
 * found/failed (non-fatal - a bitstream built with have_xu_net=0 has no
 * network bridge at all, so the daemon just serves disks). */
static int setup_net(net_t *n)
{
    char uiodev[64];
    if (find_uio(n->phys_base, n->uio_name, uiodev, sizeof(uiodev)) < 0) {
        log_msg("NET: no UIO device found (phys 0x%x) - disabled this run",
                (unsigned)n->phys_base);
        return -1;
    }
    log_msg("NET: using %s", uiodev);
    n->uiofd = open(uiodev, O_RDWR);
    if (n->uiofd < 0) {
        log_msg("NET: open %s: %s", uiodev, strerror(errno));
        return -1;
    }
    n->regs = mmap(NULL, NET_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, n->uiofd, 0);
    if (n->regs == MAP_FAILED) {
        log_msg("NET: mmap: %s", strerror(errno));
        close(n->uiofd);
        n->uiofd = -1;
        return -1;
    }
    log_msg("NET: mapped %d bytes at %p (phys 0x%x)", NET_MAP_SIZE,
            (void*)n->regs, (unsigned)n->phys_base);
    n->present = 1;
    return 0;
}

/* ------------------------------------------------------------------ *
 * Disk load/unload + persistent config
 * ------------------------------------------------------------------ */

static void save_config(void);

/* Raw loader: open `path` and install it as bus `b` unit `unit`'s image,
 * under img_lock. No logging, no config save - callers do that themselves
 * (do_load logs "API:" + saves; load_config logs "config:" and doesn't save,
 * since it's just replaying what's already on disk). 0 = ok, -errno on
 * failure. */
static int load_image(bus_t *b, int unit, const char *path)
{
    int nf, ro = 0;
    if (unit < 0 || unit >= b->max_units) return -EINVAL;
    /* O_SYNC: every pwrite() in serve_bus() blocks until the sector is on the
     * SD card. Without it, the page cache can reorder/delay writes across a
     * reset or power loss, corrupting the image; sector I/O is already
     * serialized one-at-a-time by img_lock, so the added latency is a single
     * write's worth, not a pipeline stall. */
    nf = open(path, O_RDWR | O_SYNC);
    if (nf < 0) {
        /* An image we may only read is a write-protected pack, not a failed
         * mount - a real drive spins one up happily with WRITE PROT lit. The
         * guest's writes then fail per-sector exactly as they do on a unit
         * whose file went away (see the pwrite branch in serve_bus). */
        nf = open(path, O_RDONLY);
        if (nf < 0) return -errno;
        ro = 1;
    }
    pthread_mutex_lock(&img_lock);
    if (b->imgfd[unit] >= 0) close(b->imgfd[unit]);
    free(b->imgpath[unit]);
    b->imgfd[unit]   = nf;
    b->imgro[unit]   = ro;
    b->imgpath[unit] = strdup(path);
    pthread_mutex_unlock(&img_lock);
    if (ro) log_msg("%s%d: %s is read-only - mounted WRITE PROTECTED",
                    b->name, unit, path);
    return 0;
}

/* load image `path` into bus `b` unit `unit`, via the REST API or the CLI
 * seed - logs and persists the change. 0 = ok, -errno on failure. */
static int do_load(bus_t *b, int unit, const char *path)
{
    int rc = load_image(b, unit, path);
    if (rc < 0) return rc;
    log_msg("API: loaded %s%d = %s", b->name, unit, path);
    save_config();
    return 0;
}

/* unload bus `b` unit `unit`. 0 = ok, -ENOENT if it was already empty. */
static int do_unload(bus_t *b, int unit)
{
    int had;
    if (unit < 0 || unit >= b->max_units) return -EINVAL;
    pthread_mutex_lock(&img_lock);
    had = b->imgfd[unit] >= 0;
    if (had) { close(b->imgfd[unit]); b->imgfd[unit] = -1; }
    free(b->imgpath[unit]);
    b->imgpath[unit] = NULL;
    b->imgro[unit]   = 0;
    pthread_mutex_unlock(&img_lock);
    log_msg("API: unloaded %s%d%s", b->name, unit, had ? "" : " (was empty)");
    if (had) save_config();
    return had ? 0 : -ENOENT;
}

/* find a bus by name ("RL"/"RH", case-insensitive) */
static bus_t *find_bus(const char *name)
{
    int i;
    for (i = 0; i < NBUSES; i++)
        if (strcasecmp(g_buses[i]->name, name) == 0) return g_buses[i];
    return NULL;
}

/* Parse a <spec> like "rl0", "rh0", or a bare "0"/"1" (bare = RL, for
 * backward compatibility with the original RL-only API) into (bus, unit).
 * An explicit `dev` overrides the bus prefix in spec / provides it for a
 * bare number. Returns 0 and fills out_bus/out_unit on success. */
static int parse_unit_spec(const char *spec, const char *dev, bus_t **out_bus, int *out_unit)
{
    const char *p = spec;
    char busname[8];
    size_t bl = 0;

    if (!spec || !*spec) return -1;

    while (*p && !isdigit((unsigned char)*p) && bl < sizeof(busname) - 1)
        busname[bl++] = *p++;
    busname[bl] = 0;

    if (bl == 0) {
        /* bare number: dev param if given, else RL */
        *out_bus = dev && *dev ? find_bus(dev) : &g_rl;
    } else {
        *out_bus = find_bus(busname);
    }
    if (!*out_bus) return -1;
    if (!isdigit((unsigned char)*p)) return -1;
    *out_unit = atoi(p);
    return 0;
}

/* Persist the currently loaded image per bus/unit to config_path, so a
 * restart (or reboot) comes back up serving the same disks. Atomic via a
 * temp file + rename, so a kill -9 mid-save can't leave a torn config. */
static void save_config(void)
{
    char tmp[512];
    FILE *f;
    int i, u;

    snprintf(tmp, sizeof(tmp), "%s.tmp", config_path);
    f = fopen(tmp, "w");
    if (!f) { log_msg("save_config: open %s: %s", tmp, strerror(errno)); return; }

    fprintf(f, "# pdp11-hostd persistent disk config - autogenerated, do not "
               "hand-edit while the daemon is running\n");
    pthread_mutex_lock(&img_lock);
    for (i = 0; i < NBUSES; i++) {
        bus_t *b = g_buses[i];
        for (u = 0; u < b->max_units; u++)
            if (b->imgpath[u])
                fprintf(f, "%s%d=%s\n", b->name, u, b->imgpath[u]);
    }
    pthread_mutex_unlock(&img_lock);

    fclose(f);
    if (rename(tmp, config_path) < 0)
        log_msg("save_config: rename %s -> %s: %s", tmp, config_path, strerror(errno));
}

/* Load config_path (if it exists) and open the listed images. Returns 1 if
 * the file existed (whether or not every entry loaded cleanly), 0 if it
 * didn't (caller should seed from CLI args and save_config() to create it). */
static int load_config(void)
{
    FILE *f = fopen(config_path, "r");
    char line[600];

    if (!f) return 0;
    log_msg("loading persistent config %s", config_path);
    while (fgets(line, sizeof(line), f)) {
        char *nl, *eq, *spec, *path;
        bus_t *b;
        int unit, rc;

        nl = strchr(line, '\n'); if (nl) *nl = 0;
        if (line[0] == '#' || line[0] == 0) continue;
        eq = strchr(line, '=');
        if (!eq) { log_msg("  config: skipping malformed line '%s'", line); continue; }
        *eq = 0;
        spec = line;
        path = eq + 1;
        if (!*path) continue;

        if (parse_unit_spec(spec, NULL, &b, &unit) < 0) {
            log_msg("  config: skipping unrecognized unit '%s'", spec);
            continue;
        }
        rc = load_image(b, unit, path);
        if (rc < 0)
            log_msg("  config: %s%d = %s: %s (skipped, unit stays unloaded)",
                     b->name, unit, path, strerror(-rc));
        else
            log_msg("  config: %s%d = %s", b->name, unit, path);
    }
    fclose(f);
    return 1;
}

/* ------------------------------------------------------------------ *
 * REST API - swap disk images on a running system, no reboot.
 *
 *   GET  /status            JSON: per-bus, per-unit loaded state + counters
 *   GET  /images             JSON: *.img files available in img_dir
 *   POST /load?unit=<spec>&path=P   load image P into <spec> (GET also ok)
 *   POST /unload?unit=<spec>        unload <spec>
 *
 * Served by libhttpd (httpd.c) on http_port, alongside the web front panel
 * (/, /api/state, /ws) further down. The load/unload helpers take img_lock
 * so a swap is atomic against a serving thread's file I/O.
 * ------------------------------------------------------------------ */

/* {"RL":{"unit_sectors":..,"sector_bytes":..,"units":[...]},"RH":{...}} */
static void build_status_json(char *b, size_t n)
{
    size_t o = 0;
    int i, u;

    o += snprintf(b + o, n - o, "{");
    pthread_mutex_lock(&img_lock);
    for (i = 0; i < NBUSES; i++) {
        bus_t *bus = g_buses[i];
        o += snprintf(b + o, n - o,
            "%s\"%s\":{\"present\":%s,\"served\":%llu,\"idle_ms\":%llu,"
            "\"unit_sectors\":%d,\"sector_bytes\":%d,\"units\":[",
            i ? "," : "", bus->name, bus->present ? "true" : "false",
            (unsigned long long)bus->served,
            (unsigned long long)(bus->last_req_ms ? now_ms() - bus->last_req_ms : 0),
            bus->unit_sectors, bus->sector_bytes);
        for (u = 0; u < bus->max_units; u++) {
            long long sz = (bus->imgfd[u] >= 0) ? (long long)lseek(bus->imgfd[u], 0, SEEK_END) : -1;
            if (bus->imgpath[u])
                o += snprintf(b + o, n - o,
                    "%s{\"unit\":%d,\"loaded\":true,\"path\":\"%s\",\"size\":%lld}",
                    u ? "," : "", u, bus->imgpath[u], sz);
            else
                o += snprintf(b + o, n - o,
                    "%s{\"unit\":%d,\"loaded\":false,\"path\":null,\"size\":-1}",
                    u ? "," : "", u);
        }
        o += snprintf(b + o, n - o, "]}");
    }
    pthread_mutex_unlock(&img_lock);
    {
        uint32_t debug1 = 0, runstats = 0, debug2 = 0, debug3 = 0;
        if (g_net.present && g_net.regs) {
            debug1 = g_net.regs[NET_REG_DEBUG1];
            runstats = g_net.regs[NET_REG_RUNSTATS];
            debug2 = g_net.regs[NET_REG_DEBUG2];
            debug3 = g_net.regs[NET_REG_DEBUG3];
        }
        o += snprintf(b + o, n - o,
            ",\"NET\":{\"present\":%s,\"tap\":\"%s\",\"heartbeat\":%u,"
            "\"heartbeat_alive\":%s,\"heartbeat_age_ms\":%llu,"
            "\"dma_state\":%u,\"dma_srdy\":%s,"
            "\"run_start_count\":%u,\"run_done_count\":%u,"
            "\"pcsr0\":%u,\"pcsr1_state\":%u,"
            "\"outer_npr\":%s,\"outer_npg\":%s,"
            "\"xubm_npr\":%s,\"xubm_npg\":%s,"
            "\"cpu_npr\":%s,\"cpu_npg\":%s,"
            "\"ifetch_count\":%u,\"xubm_run_count\":%u,"
            "\"guest_ip\":\"%u.%u.%u.%u\","
            "\"rx_acc_unicast\":%lu,\"rx_acc_bcast\":%lu,"
            "\"rx_drop_bcast\":%lu,\"rx_drop_other\":%lu,"
            "\"rx_drop_qfull\":%lu,"
            "\"tx_enq\":%lu,\"tx_written\":%lu,\"tx_drop_qfull\":%lu}",
            g_net.present ? "true" : "false", g_net.ifname, g_net.heartbeat_last,
            g_net.heartbeat_alive ? "true" : "false",
            (unsigned long long)(g_net.heartbeat_last_change_ms ?
                now_ms() - g_net.heartbeat_last_change_ms : 0),
            debug1 & 0x7, (debug1 & 0x8) ? "true" : "false",
            runstats & 0xffff, (runstats >> 16) & 0xffff,
            debug2 & 0xffff, (debug2 >> 16) & 0xf,
            (debug2 & 0x100000) ? "true" : "false",
            (debug2 & 0x200000) ? "true" : "false",
            (debug2 & 0x400000) ? "true" : "false",
            (debug2 & 0x800000) ? "true" : "false",
            (debug2 & 0x1000000) ? "true" : "false",
            (debug2 & 0x2000000) ? "true" : "false",
            debug3 & 0xffff, (debug3 >> 16) & 0xffff,
            (guest_ip >> 24) & 0xff, (guest_ip >> 16) & 0xff,
            (guest_ip >> 8) & 0xff, guest_ip & 0xff,
            rx_acc_unicast, rx_acc_bcast, rx_drop_bcast, rx_drop_other,
            rx_drop_qfull, tx_enq, tx_written, tx_drop_qfull);
    }
    snprintf(b + o, n - o, "}\n");
}

/* {"dir":"..","images":[{"name":..,"path":..,"size":..}, ...]} */
static void build_images_json(char *b, size_t n)
{
    size_t o = 0;
    DIR *d = opendir(img_dir);
    int first = 1;
    o += snprintf(b + o, n - o, "{\"dir\":\"%s\",\"images\":[", img_dir);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) && o < n - 256) {
            size_t l = strlen(e->d_name);
            char full[512];
            struct stat st;
            long long sz;
            if (l < 4 || strcmp(e->d_name + l - 4, ".img") != 0) continue;
            snprintf(full, sizeof(full), "%s/%s", img_dir, e->d_name);
            sz = (stat(full, &st) == 0) ? (long long)st.st_size : -1;
            o += snprintf(b + o, n - o,
                "%s{\"name\":\"%s\",\"path\":\"%s\",\"size\":%lld}",
                first ? "" : ",", e->d_name, full, sz);
            first = 0;
        }
        closedir(d);
    }
    snprintf(b + o, n - o, "]}\n");
}

/* ------------------------------------------------------------------ *
 * TU58 (tu58fs) - unlike everything else here, the DECtape II emulator
 * is a separate process: tu58fs drives a real serial port to the PDP-11
 * (an axi_uartlite / ttyUL*), not one of our AXI bridges, and carries its
 * own HTTP control API (--api, default :8081). See README "Serial
 * consoles and TU58".
 *
 * So the panel can't read it the way it reads our own state. This proxies
 * it instead: a poller keeps the last /status body, which build_panel_json
 * embeds verbatim as the "tu58" member (no JSON parser needed on this side
 * - the browser already speaks JSON, and every field tu58fs adds later
 * arrives for free), and /tu58/* forwards the control routes so the page
 * stays same-origin and needs no second port opened to it.
 *
 * tu58fs is started by hand on whichever ttyUL the tape is wired to, so
 * "not running" is a normal state, not an error: the rack greys out.
 * ------------------------------------------------------------------ */

#define TU58_STATUS_MAX  4096
#define TU58_POLL_MS     1000    /* tape state changes at human speed */

static int  tu58_port = 8081;                     /* -T N, 0 disables */
static pthread_mutex_t tu58_lock = PTHREAD_MUTEX_INITIALIZER;
static char tu58_status[TU58_STATUS_MAX];         /* last good /status body */
static int  tu58_ok;                              /* is it answering? */
static int  tu58_logged_state = -1;               /* so the log says it once */

/*
 * One HTTP/1.0 GET to 127.0.0.1:tu58_port. tu58fs answers Connection:
 * close, so reading to EOF is the whole body - no chunked/keep-alive case
 * to handle. Short timeouts throughout: a wedged tu58fs must never stall
 * the panel, let alone a request thread.
 */
static int tu58_get(const char *path, char *out, size_t outn, int *code_out)
{
    int fd, code = 0;
    struct sockaddr_in sa;
    struct timeval tv;
    char req[1400], buf[TU58_STATUS_MAX + 1024];
    char *body, *end;
    size_t got = 0;
    ssize_t r;

    if (tu58_port <= 0) return -1;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    /* setup_bridge() runs udhcpc -b, which backgrounds itself; an inherited
     * socket would outlive us (the same trap the listen fd fell into) */
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { /* not fatal */ }
    tv.tv_sec = 2; tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons((uint16_t)tu58_port);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }

    snprintf(req, sizeof(req),
             "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n"
             "User-Agent: pdp11-hostd\r\nConnection: close\r\n\r\n", path);
    if (write(fd, req, strlen(req)) < 0) { close(fd); return -1; }

    while (got + 1 < sizeof(buf)) {
        r = read(fd, buf + got, sizeof(buf) - 1 - got);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) break;
        got += (size_t)r;
    }
    close(fd);
    buf[got] = 0;

    if (sscanf(buf, "HTTP/1.%*d %d", &code) != 1) return -1;
    body = strstr(buf, "\r\n\r\n");
    if (!body) return -1;
    body += 4;
    /* tu58fs terminates its JSON with a newline; strip trailing whitespace
     * so the body can be embedded straight into ours */
    end = body + strlen(body);
    while (end > body && (end[-1] == '\n' || end[-1] == '\r' || end[-1] == ' ')) *--end = 0;

    snprintf(out, outn, "%s", body);
    if (code_out) *code_out = code;
    return 0;
}

/* Refresh the cached status once. Called on the poll tick and immediately
 * after anything that changes tu58fs's state, so the panel doesn't show a
 * second of stale tape after a mount. */
static void tu58_poll_once(void)
{
    char body[TU58_STATUS_MAX];
    int code = 0, ok;

    ok = (tu58_get("/status", body, sizeof(body), &code) == 0 &&
          code == 200 && body[0] == '{');

    pthread_mutex_lock(&tu58_lock);
    tu58_ok = ok;
    if (ok) snprintf(tu58_status, sizeof(tu58_status), "%s", body);
    pthread_mutex_unlock(&tu58_lock);

    if (ok != tu58_logged_state) {
        tu58_logged_state = ok;
        log_msg("TU58: tu58fs API on 127.0.0.1:%d is %s", tu58_port,
                ok ? "up" : "not answering (tape panel disabled)");
    }
}

static void *tu58_thread(void *arg)
{
    (void)arg;
    while (!g_stop) {
        tu58_poll_once();
        usleep(TU58_POLL_MS * 1000);
    }
    return NULL;
}

/* ------------------------------------------------------------------ *
 * Web front panel - the state the browser draws, and the transport.
 *
 * The panel wants a different shape from /status: per-unit counters and
 * timestamps rather than the flat diagnostic dump, and it wants them ten
 * times a second. So /api/state is its own snapshot, pushed over the
 * WebSocket by panel_thread() and also fetchable on its own for the
 * no-WebSocket fallback path.
 * ------------------------------------------------------------------ */

/* rates, recomputed once a second by panel_thread() from frame deltas */
static double g_tx_pps, g_rx_pps;

/* copy `in` into `out` with the two characters JSON forbids escaped. Image
 * paths are the only untrusted-ish text that reaches the JSON. */
static void json_str(char *out, size_t n, const char *in)
{
    size_t o = 0;
    if (!in) { if (n) out[0] = 0; return; }
    for (; *in && o + 2 < n; in++) {
        if (*in == '"' || *in == '\\') out[o++] = '\\';
        else if ((unsigned char)*in < 0x20) { out[o++] = '?'; continue; }
        out[o++] = *in;
    }
    out[o] = 0;
}

/* ms since a timestamp, or -1 if it never happened (the panel treats a
 * negative age as "no such event yet" rather than "infinitely long ago") */
static long long age_ms(uint64_t stamp)
{
    return stamp ? (long long)(now_ms() - stamp) : -1;
}

/* snprintf into b at offset o, clamping o so a long image path can never
 * push it past n (where `n - o` would underflow into a huge size_t). */
#define PJ(...) do {                                        \
        int _r = snprintf(b + o, n - o, __VA_ARGS__);       \
        if (_r > 0) o += (size_t)_r;                        \
        if (o >= n) o = n - 1;                              \
    } while (0)

static void build_panel_json(char *b, size_t n)
{
    size_t o = 0;
    int i, u;
    char host[64];

    if (n < 2) { if (n) b[0] = 0; return; }

    if (gethostname(host, sizeof(host)) != 0) snprintf(host, sizeof(host), "pdp11");
    host[sizeof(host) - 1] = 0;

    PJ(
        "{\"type\":\"state\",\"t\":%llu,\"uptime_s\":%llu,\"clients\":%d,"
        "\"host\":\"%s\",\"pid\":%d,\"reset_ms\":%lld,\"buses\":[",
        (unsigned long long)now_ms(),
        (unsigned long long)((now_ms() - start_ms) / 1000),
        httpd_ws_clients(g_httpd), host, (int)getpid(),
        age_ms(g_last_reset_ms));

    pthread_mutex_lock(&img_lock);
    for (i = 0; i < NBUSES; i++) {
        bus_t *bus = g_buses[i];
        PJ(
            "%s{\"name\":\"%s\",\"ctrl\":\"%s\",\"model\":\"%s\",\"present\":%s,"
            "\"sector_bytes\":%d,\"unit_sectors\":%d,\"sectors_per_cyl\":%d,"
            "\"cyls\":%d,\"min_units\":%d,\"served\":%llu,\"units\":[",
            i ? "," : "", bus->name, bus->ctrl, bus->model,
            bus->present ? "true" : "false", bus->sector_bytes,
            bus->unit_sectors, bus->sectors_per_cyl, bus->cyls,
            bus->min_units, (unsigned long long)bus->served);
        for (u = 0; u < bus->max_units; u++) {
            char esc[512];
            long long sz = (bus->imgfd[u] >= 0) ?
                (long long)lseek(bus->imgfd[u], 0, SEEK_END) : -1;
            json_str(esc, sizeof(esc), bus->imgpath[u]);
            /* "show": the panel draws this drive. Below min_units always;
             * above it only once the persistent config actually put an
             * image there, so a two-drive installation isn't padded out
             * with DL2/DL3 fronts that were never wired up. */
            PJ(
                "%s{\"n\":%d,\"tag\":\"%s%d\",\"show\":%s,\"loaded\":%s,"
                "\"path\":\"%s\","
                "\"size\":%lld,\"ro\":%s,\"reads\":%llu,\"writes\":%llu,"
                "\"errors\":%llu,\"block\":%u,\"idle_ms\":%lld,\"err_ms\":%lld}",
                u ? "," : "", u, bus->unit_prefix, u,
                (u < bus->min_units || bus->imgpath[u]) ? "true" : "false",
                bus->imgpath[u] ? "true" : "false", esc, sz,
                bus->imgro[u] ? "true" : "false",
                (unsigned long long)bus->u_reads[u],
                (unsigned long long)bus->u_writes[u],
                (unsigned long long)bus->u_errors[u],
                bus->u_block[u], age_ms(bus->u_last_ms[u]), age_ms(bus->u_err_ms[u]));
        }
        PJ( "]}");
    }
    pthread_mutex_unlock(&img_lock);

    {
        uint32_t debug1 = 0, runstats = 0, debug2 = 0, debug3 = 0;
        if (g_net.present && g_net.regs) {
            debug1   = g_net.regs[NET_REG_DEBUG1];
            runstats = g_net.regs[NET_REG_RUNSTATS];
            debug2   = g_net.regs[NET_REG_DEBUG2];
            debug3   = g_net.regs[NET_REG_DEBUG3];
        }
        PJ(
            "],\"net\":{\"present\":%s,\"if\":\"%s\","
            "\"mac\":\"%02x:%02x:%02x:%02x:%02x:%02x\",\"ip\":\"%u.%u.%u.%u\","
            "\"hb\":%u,\"hb_alive\":%s,\"hb_age_ms\":%lld,"
            "\"dma_state\":%u,\"run_start\":%u,\"run_done\":%u,"
            "\"run_idle_ms\":%lld,"
            "\"pcsr0\":%u,\"ifetch\":%u,"
            "\"tx_frames\":%lu,\"tx_bytes\":%llu,\"tx_pps\":%.1f,\"tx_idle_ms\":%lld,"
            "\"rx_frames\":%lu,\"rx_bytes\":%llu,\"rx_pps\":%.1f,\"rx_idle_ms\":%lld,"
            "\"drops\":{\"bcast\":%lu,\"other\":%lu,\"rxq\":%lu,\"txq\":%lu}}",
            g_net.present ? "true" : "false", g_net.ifname,
            xu_mac[0], xu_mac[1], xu_mac[2], xu_mac[3], xu_mac[4], xu_mac[5],
            (guest_ip >> 24) & 0xff, (guest_ip >> 16) & 0xff,
            (guest_ip >> 8) & 0xff, guest_ip & 0xff,
            g_net.heartbeat_last, g_net.heartbeat_alive ? "true" : "false",
            age_ms(g_net.heartbeat_last_change_ms),
            debug1 & 0x7, runstats & 0xffff, (runstats >> 16) & 0xffff,
            age_ms(g_net.run_last_change_ms),
            debug2 & 0xffff, debug3 & 0xffff,
            tx_written, (unsigned long long)net_tx_bytes, g_tx_pps,
            age_ms(net_last_tx_ms),
            net_rx_deliv, (unsigned long long)net_rx_bytes, g_rx_pps,
            age_ms(net_last_rx_ms),
            rx_drop_bcast, rx_drop_other, rx_drop_qfull, tx_drop_qfull);
    }

    /* tu58fs's own status object, passed through untouched - see the TU58
     * section above for why this side never parses it. null when tu58fs
     * isn't running, which is how the panel knows to hide the tape rack. */
    pthread_mutex_lock(&tu58_lock);
    if (tu58_ok && tu58_status[0] == '{') PJ(",\"tu58\":%s", tu58_status);
    else                                  PJ(",\"tu58\":null");
    pthread_mutex_unlock(&tu58_lock);

    PJ("}\n");
    b[o] = 0;
}
#undef PJ

/* Push one line to every open panel and mirror it into the daemon log, so
 * the browser's event paper and /var/log tell the same story. level is one
 * of "", "ok", "warn", "err" (the panel colours the line by it). */
static void ui_event(const char *level, const char *fmt, ...)
{
    char msg[512], esc[600], json[800];
    va_list ap;
    int n;

    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    log_msg("%s", msg);
    if (!g_httpd) return;
    json_str(esc, sizeof(esc), msg);
    n = snprintf(json, sizeof(json),
                 "{\"type\":\"event\",\"t\":%llu,\"level\":\"%s\",\"msg\":\"%s\"}",
                 (unsigned long long)now_ms(), level, esc);
    httpd_ws_broadcast(g_httpd, json, (size_t)n);
}

/* ------------------------------------------------------------------ *
 * HTTP handlers. The REST surface (/status, /images, /load, /unload) is
 * unchanged from the hand-rolled server it replaces - dlctl and the
 * scripts in scripts/ still work verbatim - with the panel's own
 * /api/state, /ws and the static assets added alongside.
 * ------------------------------------------------------------------ */

static void h_status(const httpd_req_t *r, void *u)
{
    char body[8192];
    (void)u;
    build_status_json(body, sizeof(body));
    httpd_reply_str(r, 200, "application/json", body);
}

static void h_images(const httpd_req_t *r, void *u)
{
    char body[8192];
    (void)u;
    build_images_json(body, sizeof(body));
    httpd_reply_str(r, 200, "application/json", body);
}

static void h_state(const httpd_req_t *r, void *u)
{
    char body[8192];
    (void)u;
    build_panel_json(body, sizeof(body));
    httpd_reply_str(r, 200, "application/json", body);
}

static void h_load(const httpd_req_t *r, void *u)
{
    char us[16], ps[1024], devs[8] = {0}, body[8192];
    bus_t *bus;
    int unit, rc;
    (void)u;

    httpd_param(r, "dev", devs, sizeof(devs));
    if (httpd_param(r, "unit", us, sizeof(us)) ||
        httpd_param(r, "path", ps, sizeof(ps))) {
        httpd_reply_str(r, 400, "application/json",
                        "{\"error\":\"need unit and path\"}\n");
        return;
    }
    if (parse_unit_spec(us, devs, &bus, &unit) < 0) {
        httpd_reply_str(r, 400, "application/json",
                        "{\"error\":\"bad unit (want e.g. rl0, rh0, or a bare number)\"}\n");
        return;
    }
    rc = do_load(bus, unit, ps);
    if (rc == 0) {
        ui_event("ok", "PANEL: mounted %s%d = %s%s", bus->name, unit, ps,
                 bus->imgro[unit] ? " (WRITE PROTECTED)" : "");
        build_status_json(body, sizeof(body));
        httpd_reply_str(r, 200, "application/json", body);
    } else {
        ui_event("err", "PANEL: mount %s%d = %s failed: %s", bus->name, unit, ps,
                 strerror(-rc));
        snprintf(body, sizeof(body), "{\"error\":\"load failed: %s\"}\n", strerror(-rc));
        httpd_reply_str(r, 400, "application/json", body);
    }
}

static void h_unload(const httpd_req_t *r, void *u)
{
    char us[16], devs[8] = {0}, body[8192];
    bus_t *bus;
    int unit;
    (void)u;

    httpd_param(r, "dev", devs, sizeof(devs));
    if (httpd_param(r, "unit", us, sizeof(us))) {
        httpd_reply_str(r, 400, "application/json", "{\"error\":\"need unit\"}\n");
        return;
    }
    if (parse_unit_spec(us, devs, &bus, &unit) < 0) {
        httpd_reply_str(r, 400, "application/json",
                        "{\"error\":\"bad unit (want e.g. rl0, rh0, or a bare number)\"}\n");
        return;
    }
    /* an empty-slot unmount is not an error here, same as before */
    if (do_unload(bus, unit) == 0)
        ui_event("ok", "PANEL: unmounted %s%d", bus->name, unit);
    build_status_json(body, sizeof(body));
    httpd_reply_str(r, 200, "application/json", body);
}

/*
 * POST /reset (GET works too, like the rest of this API) - pulse the
 * PDP-11-only reset, exactly what the init script's -r does at boot and
 * what the U15 button does in hardware. Only the PDP-11 core and its DDR
 * bridge are reset; the AXI fabric, this daemon and Linux are untouched,
 * and the disks stay mounted, so the machine reboots from whatever is in
 * DL0/DB0 right now.
 *
 * Rate-limited: the reset is a 300ms pulse and a double-click would
 * otherwise interrupt the boot it just started.
 */
#define RESET_MIN_GAP_MS 3000

static void h_reset(const httpd_req_t *r, void *u)
{
    char body[256];
    uint64_t since;
    int rc;
    (void)u;

    since = g_last_reset_ms ? now_ms() - g_last_reset_ms : (uint64_t)-1;
    if (since < RESET_MIN_GAP_MS) {
        snprintf(body, sizeof(body),
                 "{\"ok\":false,\"message\":\"reset %llums ago - wait %llums\"}\n",
                 (unsigned long long)since,
                 (unsigned long long)(RESET_MIN_GAP_MS - since));
        httpd_reply_str(r, 429, "application/json", body);
        return;
    }

    ui_event("warn", "PANEL: RESET requested - pulsing the PDP-11 reset");
    rc = pulse_reset();
    if (rc == 0) {
        ui_event("ok", "PANEL: PDP-11 reset; it is rebooting from the mounted disks");
        httpd_reply_str(r, 200, "application/json",
                        "{\"ok\":true,\"message\":\"PDP-11 reset\"}\n");
    } else {
        ui_event("err", "PANEL: reset FAILED: %s", strerror(-rc));
        snprintf(body, sizeof(body),
                 "{\"ok\":false,\"message\":\"reset failed: %s\"}\n", strerror(-rc));
        httpd_reply_str(r, 500, "application/json", body);
    }
}

/*
 * /tu58/<route> -> tu58fs's own <route>, query string forwarded verbatim
 * (it is still percent-encoded here, which is exactly what a proxy wants).
 * Only the routes registered in start_httpd() can reach this, so there is
 * no way to aim it at an arbitrary upstream path.
 */
static void h_tu58(const httpd_req_t *r, void *u)
{
    const char *sub = r->path + 5;          /* "/tu58/load" -> "/load" */
    char upstream[1200], body[TU58_STATUS_MAX];
    int code = 0;
    (void)u;

    if (tu58_port <= 0) {
        httpd_reply_str(r, 503, "application/json",
                        "{\"ok\":false,\"message\":\"tu58 proxy disabled (-T 0)\"}\n");
        return;
    }
    if (r->query && *r->query)
        snprintf(upstream, sizeof(upstream), "%s?%s", sub, r->query);
    else
        snprintf(upstream, sizeof(upstream), "%s", sub);

    if (tu58_get(upstream, body, sizeof(body), &code) < 0) {
        httpd_reply_str(r, 503, "application/json",
                        "{\"ok\":false,\"message\":\"tu58fs is not answering on "
                        "127.0.0.1 - is it running with --api?\"}\n");
        return;
    }
    /* anything but a plain read changed the tape state: refresh the cache
     * now so the next panel push already shows it */
    if (strcmp(sub, "/status") && strcmp(sub, "/images")) {
        tu58_poll_once();
        ui_event(code == 200 ? "ok" : "err", "PANEL: tu58%s -> %d", upstream, code);
    }
    httpd_reply_str(r, code, "application/json", body);
}

/* ---- static assets: the front panel itself ---- */

/*
 * Asset ETags, one per embedded file, from a hash of its bytes.
 *
 * These exist because of a real failure: the assets were served with
 * `Cache-Control: max-age=60` and NO validator, so a browser had nothing to
 * revalidate against and happily kept showing the previous panel after a
 * redeploy - the page looked unchanged even though the daemon was serving
 * new bytes. With an ETag and `no-cache` the browser revalidates every time,
 * pays only a 304 when nothing moved, and picks up a redeploy on the next
 * ordinary reload. The assets are tens of KB on a LAN, so revalidating is
 * far cheaper than a stale panel.
 */
static char www_etag[WWW_NFILES][24];

static void www_etags_init(void)
{
    int i;
    unsigned j;
    for (i = 0; i < WWW_NFILES; i++) {
        uint32_t h = 2166136261u;                 /* FNV-1a */
        for (j = 0; j < www_files[i].len; j++) {
            h ^= www_files[i].data[j];
            h *= 16777619u;
        }
        snprintf(www_etag[i], sizeof(www_etag[i]), "\"%08x-%x\"", h, www_files[i].len);
    }
}

static const char *ctype_for(const char *path)
{
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (!strcmp(dot, ".html")) return "text/html; charset=utf-8";
    if (!strcmp(dot, ".css"))  return "text/css; charset=utf-8";
    if (!strcmp(dot, ".js"))   return "application/javascript; charset=utf-8";
    if (!strcmp(dot, ".svg"))  return "image/svg+xml";
    if (!strcmp(dot, ".json")) return "application/json";
    if (!strcmp(dot, ".png"))  return "image/png";
    return "application/octet-stream";
}

/*
 * -W <dir>: serve the assets off the filesystem instead of the copy built
 * into the binary, so the CSS can be iterated on with scp + reload instead
 * of a full cross-compile. Only a bare filename is accepted (no directory
 * component at all), which is all the panel ever asks for and leaves no
 * room for traversal.
 */
static int try_disk_asset(const httpd_req_t *r, const char *name)
{
    char full[600];
    struct stat st;
    char *buf;
    int fd;
    ssize_t got;

    if (!www_dir || strchr(name, '/') || !strcmp(name, "..")) return -1;
    snprintf(full, sizeof(full), "%s/%s", www_dir, name);
    fd = open(full, O_RDONLY);
    if (fd < 0) return -1;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_size > 4 * 1024 * 1024) {
        close(fd);
        return -1;
    }
    buf = (char *)malloc((size_t)st.st_size);
    if (!buf) { close(fd); return -1; }
    got = read(fd, buf, (size_t)st.st_size);
    close(fd);
    if (got != st.st_size) { free(buf); return -1; }
    {
        /* size+mtime is validator enough for a file being edited in place */
        char etag[64], hdrs[128];
        const char *inm;
        snprintf(etag, sizeof(etag), "\"%llx-%llx\"",
                 (unsigned long long)st.st_size, (unsigned long long)st.st_mtime);
        snprintf(hdrs, sizeof(hdrs), "Cache-Control: no-cache\r\nETag: %s\r\n", etag);
        inm = httpd_header(r, "If-None-Match");
        if (inm && strcmp(inm, etag) == 0) {
            httpd_reply_notmodified(r, hdrs);
            free(buf);
            return 0;
        }
        httpd_reply_full(r, 200, ctype_for(name), hdrs, buf, (size_t)got);
    }
    free(buf);
    return 0;
}

static void h_static(const httpd_req_t *r, void *u)
{
    const char *path = r->path;
    int i;
    (void)u;

    if (!strcmp(path, "/")) path = "/index.html";

    if (try_disk_asset(r, path + 1) == 0) return;

    for (i = 0; i < WWW_NFILES; i++) {
        if (!strcmp(path, www_files[i].path)) {
            char hdrs[128];
            const char *inm;
            snprintf(hdrs, sizeof(hdrs),
                     "Cache-Control: no-cache\r\nETag: %s\r\n", www_etag[i]);
            inm = httpd_header(r, "If-None-Match");
            if (inm && strcmp(inm, www_etag[i]) == 0) {
                httpd_reply_notmodified(r, hdrs);
                return;
            }
            httpd_reply_full(r, 200, www_files[i].ctype, hdrs,
                             www_files[i].data, www_files[i].len);
            return;
        }
    }
    httpd_reply_str(r, 404, "text/plain", "not found\n");
}

/* ---- WebSocket ---- */

static void ws_opened(httpd_conn_t *c, void *u)
{
    char body[8192];
    (void)u;
    /* paint immediately rather than making the browser wait for the next
     * broadcast tick */
    build_panel_json(body, sizeof(body));
    httpd_ws_send(c, body, strlen(body));
}

static void ws_message(httpd_conn_t *c, const char *msg, size_t len, void *u)
{
    /* The panel drives every action through the REST endpoints; nothing is
     * accepted over the socket. Kept so a stray client frame is dropped
     * deliberately rather than by omission. */
    (void)c; (void)msg; (void)len; (void)u;
}

/*
 * Broadcast a snapshot ~10x a second - fast enough that a lamp lit by a
 * single sector transfer is actually seen, cheap enough to be invisible
 * next to the disk and network paths. Nothing is built when nobody is
 * watching.
 */
static void *panel_thread(void *arg)
{
    char body[8192];
    unsigned long last_tx = 0, last_rx = 0;
    uint64_t last_rate_ms = now_ms();
    (void)arg;

    while (!g_stop) {
        uint64_t t;
        usleep(100000);
        t = now_ms();

        if (t - last_rate_ms >= 1000) {
            double dt = (double)(t - last_rate_ms) / 1000.0;
            g_tx_pps = (double)(tx_written - last_tx) / dt;
            g_rx_pps = (double)(net_rx_deliv - last_rx) / dt;
            last_tx = tx_written;
            last_rx = net_rx_deliv;
            last_rate_ms = t;
        }

        if (httpd_ws_clients(g_httpd) == 0) continue;
        build_panel_json(body, sizeof(body));
        httpd_ws_broadcast(g_httpd, body, strlen(body));
    }
    return NULL;
}

static void httpd_log_sink(const char *line) { log_msg("%s", line); }

/* Bring up the web server: REST (unchanged), the panel snapshot, the
 * WebSocket and the embedded assets, all on http_port. */
static int start_httpd(void)
{
    www_etags_init();
    g_httpd = httpd_new(http_port);
    if (!g_httpd) { log_msg("API: httpd_new failed - web server disabled"); return -1; }
    httpd_set_log(g_httpd, httpd_log_sink);

    httpd_route(g_httpd, "/status",    h_status, NULL);
    httpd_route(g_httpd, "/images",    h_images, NULL);
    httpd_route(g_httpd, "/load",      h_load,   NULL);
    httpd_route(g_httpd, "/unload",    h_unload, NULL);
    httpd_route(g_httpd, "/api/state", h_state,  NULL);
    httpd_route(g_httpd, "/reset",     h_reset,  NULL);
    httpd_route(g_httpd, "/tu58/status",  h_tu58, NULL);
    httpd_route(g_httpd, "/tu58/images",  h_tu58, NULL);
    httpd_route(g_httpd, "/tu58/load",    h_tu58, NULL);
    httpd_route(g_httpd, "/tu58/unload",  h_tu58, NULL);
    httpd_route(g_httpd, "/tu58/save",    h_tu58, NULL);
    httpd_route(g_httpd, "/tu58/offline", h_tu58, NULL);
    httpd_ws_route(g_httpd, "/ws", ws_opened, ws_message, NULL);
    httpd_default(g_httpd, h_static, NULL);

    if (httpd_start(g_httpd) < 0) { g_httpd = NULL; return -1; }
    log_msg("API: front panel on http://0.0.0.0:%d/ , REST on the same port "
            "(status,images,load,unload), live push on /ws%s",
            http_port, www_dir ? " [assets from disk]" : "");
    return 0;
}

/* ------------------------------------------------------------------ *
 * Per-bus disk serving loop - one of these threads runs per present bus
 * (RL always; RH only if its UIO device was found). Generalized from the
 * original RL-only loop: everything bus-specific comes from the bus_t.
 * ------------------------------------------------------------------ */
static void *serve_bus(void *arg)
{
    bus_t *b = (bus_t *)arg;
    uint16_t sector[MAX_BUF_WORDS];
    uint64_t seq = 0;
    uint64_t last_req_ms = 0;
    uint64_t last_hb_ms = 0;
    int arm_result = 0;
    /* spin suppression: a stuck client (e.g. an unloaded unit) can hammer the
     * same block over and over; log the first few in full, then collapse to
     * a periodic summary instead of flooding the log file. */
    uint32_t spin_unit = (uint32_t)-1, spin_block = (uint32_t)-1;
    uint32_t spin_is_write = (uint32_t)-1;
    uint64_t spin_count = 0;
    uint64_t spin_start_ms = 0;
    uint64_t spin_last_summary_ms = 0;
    int      spin_quiet = 0;
    int i;
#define SPIN_BURST      3       /* log the first few repeats in full        */
#define SPIN_SUMMARY_MS 2000    /* then just a summary line every ~2s       */

    log_msg("%s: serving thread started (buf_words=%d sector_bytes=%d max_units=%d)",
            b->name, b->buf_words, b->sector_bytes, b->max_units);

    for (;;) {
        uint32_t status, block, is_write;
        unsigned unit, local;
        off_t off;
        int fd, err = 0;
        uint64_t t0 = now_ms();
        char tag[16];            /* e.g. "DL2" / "DB0" - the actual drive, for logging */

        if (g_stop) break;

        /*
         * Only block on the interrupt when nothing is pending. A request
         * that arrived before we opened the UIO device (e.g. the PDP-11's
         * power-on boot read, issued while Linux was still coming up) is
         * already latched, and its interrupt fired before we could arm
         * read() - so we would miss it if we always blocked first. Checking
         * STATUS up front serves that case, and re-arming the (masked)
         * interrupt here handles every subsequent one.
         */
        if (!(b->regs[REG_STATUS] & 1)) {
            uint32_t one = 1, cnt;
            ssize_t r;
            arm_result = 0;
            if (write(b->uiofd, &one, sizeof(one)) < 0) {
                log_msg("%s: write(uio, enable) failed: %s", b->name, strerror(errno));
            } else {
                arm_result = 1;
            }
            r = read(b->uiofd, &cnt, sizeof(cnt));
            if (r < 0) {
                if (errno == EINTR) { if (g_stop) break; continue; }
                log_msg("%s: read(uio) failed: %s", b->name, strerror(errno));
                break;
            }
            if (!spin_quiet)
                log_msg("%s: uio read() woke, irq count = %u, elapsed %llums since arm",
                        b->name, (unsigned)cnt, (unsigned long long)(now_ms() - t0));
        }

        status = b->regs[REG_STATUS];
        if (!(status & 1)) {
            if (!spin_quiet)
                log_msg("%s: spurious wake: STATUS = 0x%08x", b->name, status);
            continue;
        }
        is_write = (status >> 1) & 1;
        block = b->regs[REG_BLOCK] & 0xFFFFFF;

        seq++;
        if (b->max_units > 1) {
            unit  = block / (unsigned)b->unit_sectors;   /* which image file  */
            local = block % (unsigned)b->unit_sectors;    /* sector within it */
        } else {
            unit  = 0;                                    /* one drive, no split */
            local = block;
        }
        off = (off_t)local * b->sector_bytes;
        fd  = -1;                                          /* fetched under img_lock below */
        snprintf(tag, sizeof(tag), "%s%u", b->unit_prefix, unit);

        if (unit == spin_unit && block == spin_block && is_write == spin_is_write) {
            spin_count++;
        } else {
            if (spin_quiet)
                log_msg("%s:   ...spin ended: unit %u block %u repeated %llu times over %llums",
                        tag, spin_unit, spin_block, (unsigned long long)spin_count,
                        (unsigned long long)(t0 - spin_start_ms));
            spin_unit = unit; spin_block = block; spin_is_write = is_write;
            spin_count = 1; spin_start_ms = t0; spin_last_summary_ms = t0;
        }
        spin_quiet = spin_count > SPIN_BURST;
        if (spin_quiet && t0 - spin_last_summary_ms >= SPIN_SUMMARY_MS) {
            log_msg("%s:   ...spinning: unit %u block %u repeated %llu times so far"
                    " (suppressing per-request logs)",
                    tag, unit, block, (unsigned long long)spin_count);
            spin_last_summary_ms = t0;
        }

        if (!spin_quiet) {
            log_msg("%s: REQ#%llu %s block %u (unit %u sec %u, offset %llu), STATUS=0x%08x%s",
                    tag, (unsigned long long)seq, is_write ? "WRITE" : "READ", block,
                    unit, local, (unsigned long long)off, status,
                    last_req_ms ? "" : ", first request");
            if (last_req_ms)
                log_msg("%s:   elapsed since last request: %llums",
                        tag, (unsigned long long)(t0 - last_req_ms));
        }
        last_req_ms = t0;

        if (b->dlfix && !is_write) {
            uint32_t sblk = (uint32_t)(seq - 1);
            if (sblk != block)
                log_msg("%s:   DLFIX: latched block %u, serving block %u (seq-1) instead",
                        tag, block, sblk);
            block = sblk;
            if (b->max_units > 1) {
                unit  = block / (unsigned)b->unit_sectors;
                local = block % (unsigned)b->unit_sectors;
            } else {
                unit  = 0;
                local = block;
            }
            off   = (off_t)local * b->sector_bytes;
            snprintf(tag, sizeof(tag), "%s%u", b->unit_prefix, unit);
        }

        /* hold img_lock across the whole request I/O so a runtime load/unload
         * (REST API) can't swap this unit's fd mid-transfer. served/last_req_ms
         * are updated in here too, not just imgfd/imgpath - build_status_json()
         * reads all of them under the same lock, and served/last_req_ms are
         * 64-bit values on a 32-bit target, so an unlocked write here could
         * tear against that read. */
        pthread_mutex_lock(&img_lock);
        b->served = seq;
        b->last_req_ms = t0;
        fd = (unit < (unsigned)b->max_units) ? b->imgfd[unit] : -1;

        if (fd < 0) {
            /* no file for this unit: fail the request cleanly (RT-11 sees an
             * error / empty read) rather than touching the wrong drive */
            if (!spin_quiet)
                log_msg("%s:   ERROR: no image for unit %u (block %u) - %s", tag, unit, block,
                        unit < (unsigned)b->max_units ? "unit file not provided" : "unit out of range");
            if (!is_write) for (i = 0; i < b->buf_words; i++) b->regs[i] = 0;
            err = 1;
        } else if (is_write && b->imgro[unit]) {
            /* mounted from a read-only file: fail the write here with a
             * legible reason rather than letting pwrite() come back EBADF */
            if (!spin_quiet)
                log_msg("%s:   WRITE PROTECTED: refusing write to block %u", tag, block);
            err = 1;
        } else if (is_write) {
            /* pull the sector out of the PL buffer, write to file */
            for (i = 0; i < b->buf_words; i++)
                sector[i] = (uint16_t)(b->regs[i] & 0xFFFF);
            if (verbose) {
                log_msg("%s:   wsector words 0-7: %04x %04x %04x %04x %04x %04x %04x %04x",
                        tag, sector[0], sector[1], sector[2], sector[3],
                        sector[4], sector[5], sector[6], sector[7]);
            }
            if (pwrite(fd, sector, (size_t)b->sector_bytes, off) != (ssize_t)b->sector_bytes) {
                if (!spin_quiet)
                    log_msg("%s:   ERROR: pwrite offset %llu: %s",
                            tag, (unsigned long long)off, strerror(errno));
                err = 1;
            } else if (!spin_quiet) {
                log_msg("%s:   pwrite %d bytes @ %llu OK", tag, b->sector_bytes,
                        (unsigned long long)off);
            }
        } else {
            /* read one sector from the file, push into the PL buffer */
            ssize_t got = pread(fd, sector, (size_t)b->sector_bytes, off);
            if (got < 0) {
                if (!spin_quiet)
                    log_msg("%s:   ERROR: pread offset %llu: %s",
                            tag, (unsigned long long)off, strerror(errno));
                err = 1; got = 0;
            }
            /* zero-fill any short read (past EOF) */
            for (i = (int)(got / 2); i < b->buf_words; i++) sector[i] = 0;
            if (!spin_quiet && (verbose || seq <= 8)) {
                log_msg("%s:   sector words 0-7: %04x %04x %04x %04x %04x %04x %04x %04x",
                        tag, sector[0], sector[1], sector[2], sector[3],
                        sector[4], sector[5], sector[6], sector[7]);
            }
            if (!spin_quiet) {
                if (got < (ssize_t)b->sector_bytes)
                    log_msg("%s:   short read: got %zd of %d (block past EOF?)",
                            tag, got, b->sector_bytes);
                else
                    log_msg("%s:   pread %d bytes @ %llu OK", tag, b->sector_bytes,
                            (unsigned long long)off);
            }
            if (swap)
                for (i = 0; i < b->buf_words; i++)
                    sector[i] = (uint16_t)((sector[i] << 8) | (sector[i] >> 8));
            if (!spin_quiet && (verbose || seq <= 8))
                log_msg("%s:   served words 0-7 (swap=%d): %04x %04x %04x %04x %04x %04x %04x %04x",
                        tag, swap, sector[0], sector[1], sector[2], sector[3],
                        sector[4], sector[5], sector[6], sector[7]);
            for (i = 0; i < b->buf_words; i++)
                b->regs[i] = sector[i];
            if (!spin_quiet)
                log_msg("%s:   pushed %d words into PL buffer", tag, b->buf_words);
        }

        /* per-unit counters for the web panel - still under img_lock, same
         * reason served/last_req_ms are (64-bit values on a 32-bit target,
         * read by the snapshot builder under the same lock) */
        if (unit < (unsigned)b->max_units) {
            b->u_block[unit]   = local;
            b->u_last_ms[unit] = t0;
            if (err)                b->u_errors[unit]++, b->u_err_ms[unit] = t0;
            else if (is_write)      b->u_writes[unit]++;
            else                    b->u_reads[unit]++;
        }
        pthread_mutex_unlock(&img_lock);

        /* signal completion (bit0 = error) - this drops the request/interrupt.
         * The interrupt is re-armed at the top of the loop when nothing is
         * pending, so we don't re-enable it here. */
        b->regs[REG_DONE] = err ? 1 : 0;
        if (!spin_quiet) {
            uint32_t after = b->regs[REG_STATUS];
            log_msg("%s:   DONE written (err=%d), STATUS after = 0x%08x", tag, err, after);
        }

        /* idle heartbeat: every ~10 s of no new requests, show we're alive */
        if (last_hb_ms == 0 || now_ms() - last_hb_ms >= 10000) {
            log_msg("%s: HEARTBEAT: served %llu requests, last %llums ago, irq-arm=%d",
                    b->name, (unsigned long long)seq,
                    (unsigned long long)(now_ms() - last_req_ms), arm_result);
            last_hb_ms = now_ms();
        }
    }

    log_msg("%s: serving thread exiting (served %llu requests)", b->name, (unsigned long long)seq);
    return NULL;
}

/* ------------------------------------------------------------------ *
 * Network bridge - tap device/bridge setup, receive queue + thread, wire
 * framing, and the serving loop. Ported verbatim from pdp11-espd.c; see
 * docs/xu-networking-plan.md for the full protocol writeup.
 * ------------------------------------------------------------------ */

/* CRC32 (standard poly 0xEDB88320), ported verbatim from the real ESP32
 * firmware's app_spitask.c - xubw.mac never actually validates it, this is
 * purely for wire-format fidelity (see the header comment in
 * docs/xu-networking-plan.md). */
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

static int open_tap(const char *ifname)
{
    int fd = open("/dev/net/tun", O_RDWR);
    struct ifreq ifr;

    if (fd < 0) {
        log_msg("NET: open /dev/net/tun failed: %s", strerror(errno));
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        log_msg("NET: TUNSETIFF %s failed: %s", ifname, strerror(errno));
        close(fd);
        return -1;
    }

    /* Without this, every system() call below (setup_bridge()'s udhcpc/
     * brctl/ip invocations) forks+execs a child that INHERITS this fd,
     * since it isn't marked close-on-exec. udhcpc's "-b" backgrounds
     * itself into a long-running process, so that child ends up
     * permanently holding tap0 open - confirmed on real hardware: a
     * restarted daemon's own open_tap() then fails with "Device or
     * resource busy" against a tap0 that's still alive only because a
     * leaked udhcpc child (not any pdp11-hostd process) still references
     * it. */
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0)
        log_msg("NET: warning: fcntl(FD_CLOEXEC) on tap fd failed: %s", strerror(errno));

    /* Non-blocking: rx_thread poll()s and then drains until EAGAIN, and
     * tx_thread must never park inside write() holding up queued frames.
     * Neither of them is on the critical path of serve_net(), which is what
     * actually has to answer the core's interrupt promptly. */
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) < 0)
        log_msg("NET: warning: fcntl(O_NONBLOCK) on tap fd failed: %s", strerror(errno));

    log_msg("NET: opened tap device %s (fd %d, non-blocking)", ifname, fd);
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
        log_msg("NET: creating br0 and moving eth0 into it");
        system("pkill -f 'udhcpc.*-i eth0' 2>/dev/null");
        /* killing the udhcpc client does NOT remove the address it already
         * assigned to eth0 - without this flush, eth0 keeps its old IP
         * forever alongside br0's new one, two local interfaces answering
         * for the same address, which reliably breaks return-path routing
         * for anyone talking to the board (confirmed on real hardware:
         * intermittent/one-way SSH once both interfaces held the same
         * address). */
        system("ip addr flush dev eth0");
        system("brctl addbr br0");
        system("ip link set eth0 down");
        system("brctl addif br0 eth0");
        system("ip link set eth0 up");
        system("ip link set br0 up");
        system("udhcpc -i br0 -b >/dev/null 2>&1");
        log_msg("NET: requested a fresh DHCP lease on br0");
    } else {
        log_msg("NET: br0 already exists - not rebuilding");
    }

    snprintf(cmd, sizeof(cmd), "brctl addif br0 %s 2>/dev/null", ifname);
    system(cmd);
}

/* RX queue - frames read off tap0 by a dedicated thread (mirrors the real
 * ESP32 firmware's own architecture: a WiFi-driver receive callback fills
 * a FreeRTOS queue, decoupled from the SPI-transaction cadence that drains
 * it). A small fixed ring buffer is enough; PDMD-driven "runs" happen far
 * faster than real LAN traffic arrives. */
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
static uint32_t rd_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

/* Learn the guest's IP from a frame it just sent: ARP sender-protocol-address
 * (offset 28) or IPv4 source address (offset 26). */
static void learn_guest_ip(const uint8_t *buf, int len)
{
    uint32_t ip = 0;
    if (len >= 14 && buf[12] == 0x08 && buf[13] == 0x06) {          /* ARP  */
        if (len >= 32) ip = rd_be32(buf + 28);
    } else if (len >= 14 && buf[12] == 0x08 && buf[13] == 0x00) {   /* IPv4 */
        if (len >= 30) ip = rd_be32(buf + 26);
    }
    if (ip == 0 || ip == 0xffffffffu) return;
    if (ip != guest_ip) {
        log_msg("NET: learned guest IP %u.%u.%u.%u (from its own traffic)",
                (ip >> 24) & 0xff, (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff);
        guest_ip = ip;
    }
}

/* Address filtering, as a real DEUNA does in hardware - our own address or
 * broadcast - but TIGHTENED for a modern LAN. tap0 is a bridge member, so it
 * sees the full broadcast/multicast racket (ARP for every other host, mDNS,
 * SSDP, ...). A real 10base-T segment carried far less of it, and every one
 * of those frames costs the guest one of its handful of receive descriptors
 * plus an interrupt its slow handler must service - measured on hardware
 * dropping genuine ICMP replies that had already been handed to the core.
 *
 * So: unicast to us is always accepted; broadcast is accepted only when it
 * is an ARP actually asking about the guest's own IP. Until we have learned
 * that IP we accept all ARP (fail open), otherwise the guest could never be
 * resolved in the first place. Non-ARP broadcast is dropped outright. */
static int rx_addressed_to_us(const uint8_t *buf, int len)
{
    if (len < 6) return 0;
    if (memcmp(buf, xu_mac, 6) == 0) { rx_acc_unicast++; return 1; }

    if (memcmp(buf, "\xff\xff\xff\xff\xff\xff", 6) == 0) {
        if (len >= 14 && buf[12] == 0x08 && buf[13] == 0x06) {      /* ARP */
            uint32_t gip = guest_ip;
            /* target protocol address sits at offset 38 */
            if (gip == 0 || len < 42 || rd_be32(buf + 38) == gip) {
                rx_acc_bcast++;
                return 1;
            }
        }
        rx_drop_bcast++;
        return 0;
    }

    rx_drop_other++;
    return 0;
}

static void *rx_thread(void *arg)
{
    int fd = *(int *)arg;
    uint8_t buf[MAXPAY];

    for (;;) {
        struct pollfd pfd;
        int pr;

        if (g_stop) break;

        /* Wait with a timeout rather than parking in read() forever, so
         * g_stop is honoured promptly on shutdown. */
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        pr = poll(&pfd, 1, 200);
        if (pr < 0) {
            if (errno == EINTR) continue;
            log_msg("NET: rx_thread: poll(tap) failed: %s", strerror(errno));
            break;
        }
        if (pr == 0) continue;                      /* idle tick */

        /* Drain everything currently readable - one poll() wakeup can cover
         * several queued frames, and leaving them sitting in the kernel's
         * tap queue just delays them. */
        for (;;) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n < 0) {
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                log_msg("NET: rx_thread: read(tap) failed: %s", strerror(errno));
                return NULL;
            }
            if (n < 1) break;
            if (!rx_addressed_to_us(buf, (int)n)) continue;

            pthread_mutex_lock(&rxq_lock);
            if (rxq_count < RXQ_DEPTH) {
                memcpy(rxq[rxq_head].buf, buf, (size_t)n);
                rxq[rxq_head].len = (int)n;
                rxq_head = (rxq_head + 1) % RXQ_DEPTH;
                rxq_count++;
            } else {
                rx_drop_qfull++;   /* full: drop, as a real NIC's ring does */
            }
            pthread_mutex_unlock(&rxq_lock);
        }
    }
    return NULL;
}

/* ---- outbound (guest -> LAN) queue -------------------------------------
 * serve_net() must answer the core's interrupt and hand back rx_buf as fast
 * as it can; it has no business sitting in a write() to tap0 while the run
 * engine waits on it. So it only enqueues here, and tx_thread does the
 * actual (non-blocking) write. Same drop-when-full policy as RX: a real
 * overloaded interface drops rather than adding unbounded delay. */
typedef struct {
    uint8_t buf[MAXPAY];
    int     len;
} txframe_t;

#define TXQ_DEPTH 32
static txframe_t txq[TXQ_DEPTH];
static int txq_head = 0, txq_tail = 0, txq_count = 0;
static pthread_mutex_t txq_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  txq_cv   = PTHREAD_COND_INITIALIZER;

static void txq_push(const uint8_t *b, int len)
{
    if (len < 1 || len > MAXPAY) return;
    pthread_mutex_lock(&txq_lock);
    if (txq_count < TXQ_DEPTH) {
        memcpy(txq[txq_head].buf, b, (size_t)len);
        txq[txq_head].len = len;
        txq_head = (txq_head + 1) % TXQ_DEPTH;
        txq_count++;
        tx_enq++;
        pthread_cond_signal(&txq_cv);
    } else {
        tx_drop_qfull++;
    }
    pthread_mutex_unlock(&txq_lock);
}

static void *tx_thread(void *arg)
{
    net_t *n = (net_t *)arg;

    for (;;) {
        txframe_t f;

        pthread_mutex_lock(&txq_lock);
        while (txq_count == 0 && !g_stop) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += 1;
            pthread_cond_timedwait(&txq_cv, &txq_lock, &ts);
        }
        if (txq_count == 0) {           /* woken only by g_stop */
            pthread_mutex_unlock(&txq_lock);
            if (g_stop) break;
            continue;
        }
        f = txq[txq_tail];
        txq_tail = (txq_tail + 1) % TXQ_DEPTH;
        txq_count--;
        pthread_mutex_unlock(&txq_lock);

        for (;;) {
            ssize_t w = write(n->tapfd, f.buf, (size_t)f.len);
            if (w >= 0) {
                tx_written++;
                net_tx_bytes += (unsigned long long)f.len;
                net_last_tx_ms = now_ms();
                break;
            }
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd;
                pfd.fd = n->tapfd;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                poll(&pfd, 1, 100);     /* tap0 backed up - wait briefly */
                if (g_stop) break;
                continue;
            }
            log_msg("NET: write(tap) failed: %s", strerror(errno));
            break;
        }
    }
    log_msg("NET: tx thread exiting");
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

/* Buffer-window word <-> byte helpers. Wire/byte-order convention (see
 * xuaxi.vhd's header): PDP-11 memory address N = wire byte N, i.e. word i
 * holds byte 2i in bits(7:0) and byte 2i+1 in bits(15:8). */
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

/* Independent liveness check for the embedded XU CPU (xu.vhd's cpu0), via
 * xuaxi.vhd's free-running HEARTBEAT register. serve_net() below blocks on
 * the UIO interrupt and only ever wakes for real guest traffic, so it can't
 * double as a liveness poll when the guest is idle or hung - this is a
 * separate thread that just samples the register directly (a plain memory
 * read, no interrupt involved) every second and logs a state change. Purely
 * diagnostic: never touches STATUS/LEN/DONE or any of the real frame path. */
static void *heartbeat_thread(void *arg)
{
    net_t *n = (net_t *)arg;

    for (;;) {
        uint32_t hb;
        uint64_t now;
        int was_alive;

        if (g_stop) break;
        sleep(1);
        if (g_stop) break;

        hb = n->regs[NET_REG_HEARTBEAT];
        now = now_ms();
        was_alive = n->heartbeat_alive;

        {
            uint32_t rs = n->regs[NET_REG_RUNSTATS] & 0xffff;
            if (rs != n->run_start_last) {
                n->run_start_last = rs;
                n->run_last_change_ms = now;
            }
        }

        if (hb != n->heartbeat_last) {
            n->heartbeat_last = hb;
            n->heartbeat_last_change_ms = now;
            n->heartbeat_alive = 1;
            if (!was_alive)
                log_msg("NET: heartbeat resumed (xu0 alive, HEARTBEAT=%u)", hb);
        } else if (n->heartbeat_last_change_ms &&
                   now - n->heartbeat_last_change_ms > NET_HEARTBEAT_STALE_MS) {
            n->heartbeat_alive = 0;
            if (was_alive)
                log_msg("NET: heartbeat STALLED - HEARTBEAT stuck at %u for >%dms "
                         "(xu0's clock/logic domain appears wedged)",
                         hb, NET_HEARTBEAT_STALE_MS);
        }
    }
    return NULL;
}

/* Network serving loop - mirrors serve_bus()'s arm-then-block-on-UIO-read
 * shape, adapted for the buffer-window/STATUS/LEN/DONE register map and
 * the tx_buf-drain/rx_buf-refresh wire protocol (see the file header). */
static void *serve_net(void *arg)
{
    net_t *n = (net_t *)arg;
    uint8_t rxseq = 0;

    log_msg("NET: serving XU network bridge: MAC %02x:%02x:%02x:%02x:%02x:%02x, "
            "tap=%s", xu_mac[0], xu_mac[1], xu_mac[2], xu_mac[3], xu_mac[4],
            xu_mac[5], n->ifname);

    for (;;) {
        uint8_t txbytes[HDRLEN + MAXPAY];
        uint8_t rxbytes[HDRLEN + MAXPAY];
        rxframe_t popped;
        int txlen, rxlen, rxremaining;
        int have_rx;

        if (g_stop) break;

        /* Same "check STATUS before blocking" idiom as serve_bus() above -
         * a request already latched before we opened the UIO device would
         * otherwise be missed. */
        if (!(n->regs[NET_REG_STATUS] & 1)) {
            uint32_t one = 1, cnt;
            ssize_t r;
            if (write(n->uiofd, &one, sizeof(one)) < 0)
                log_msg("NET: write(uio, enable) failed: %s", strerror(errno));
            r = read(n->uiofd, &cnt, sizeof(cnt));
            if (r < 0) {
                if (errno == EINTR) { if (g_stop) break; continue; }
                log_msg("NET: read(uio) failed: %s", strerror(errno));
                break;
            }
        }

        if (!(n->regs[NET_REG_STATUS] & 1)) continue;   /* spurious wake */

        /* ---- drain tx_buf: the frame the guest just transmitted ---- */
        txlen = (int)(n->regs[NET_REG_LEN] & 0x7ff);   /* bytes, matches xuaxi's 11-bit RL */
        if (txlen > (int)sizeof(txbytes)) txlen = sizeof(txbytes);
        words_to_bytes(n->regs, txlen, txbytes);

        /* Rate-limited raw header dump. The buffer turns over ~2000x/sec, so
         * sampling it from outside with devmem races hopelessly; this shows
         * exactly what the daemon itself decodes, once a second, including
         * the cases the magic check below silently swallows. */
        if (verbose) {
            static uint64_t last_hdr_dump_ms = 0;
            uint64_t nowms = now_ms();
            if (nowms - last_hdr_dump_ms >= 1000) {
                last_hdr_dump_ms = nowms;
                log_msg("NET: txbuf hdr %02x %02x %02x %02x %02x %02x %02x %02x "
                        "%02x %02x %02x %02x (txlen=%d len@4=%d)",
                        txbytes[0], txbytes[1], txbytes[2], txbytes[3],
                        txbytes[4], txbytes[5], txbytes[6], txbytes[7],
                        txbytes[8], txbytes[9], txbytes[10], txbytes[11],
                        txlen, (txbytes[4] << 8) | txbytes[5]);
            }
        }

        if (txlen >= HDRLEN && txbytes[0] == 0xa0 && txbytes[1] == 0xa0) {
            int framelen = (txbytes[4] << 8) | txbytes[5];
            if (framelen > 0 && framelen <= txlen - HDRLEN && framelen <= MAXPAY) {
                /* Hand off to tx_thread rather than writing here: this
                 * thread owes the core a prompt DONE, and tap0 must never
                 * be allowed to stall the run engine. */
                txq_push(txbytes + HDRLEN, framelen);
                learn_guest_ip(txbytes + HDRLEN, framelen);
                if (verbose)
                    log_msg("NET: TX: %d bytes queued for %s", framelen, n->ifname);
            } else if (framelen > 0) {
                log_msg("NET: TX: bad/oversized frame length %d (txlen=%d) - dropped",
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
             * for wire-format fidelity */
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
                log_msg("NET: RX: %d bytes delivered from queue (remaining=%d)",
                         framelen, rxremaining);
            net_rx_deliv++;
            net_rx_bytes += (unsigned long long)framelen;
            net_last_rx_ms = now_ms();
            rxlen = HDRLEN + wirelen;
        } else {
            rxlen = HDRLEN;
        }

        if (rxlen > (int)sizeof(rxbytes)) rxlen = (int)sizeof(rxbytes);
        if (rxlen > NET_BUF_WORDS_MAX * 2) rxlen = NET_BUF_WORDS_MAX * 2;
        bytes_to_words(rxbytes, rxlen, n->regs);

        /* tell the core: tx_buf drained, rx_buf refreshed */
        n->regs[NET_REG_DONE] = 0;
    }

    log_msg("NET: serving thread exiting");
    return NULL;
}

int main(int argc, char **argv)
{
    const char *logpath = NULL;
    const char *rh_seed_img = NULL;          /* -R */
    char *rl_seed[MAX_UNITS] = { NULL };
    int rl_seed_n = 0;
    int have_config;
    int i;
    pthread_t panel_tid, tu58_tid, rl_tid, rh_tid, net_tid, rxtid, hbtid, txtid;
    int panel_thread_started = 0, tu58_thread_started = 0;
    int rh_thread_started = 0;
    int net_thread_started = 0;
    int hb_thread_started = 0;
    int tx_thread_started = 0;
    static const char *usage =
        "usage: pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <imgdir>] "
        "[-c <configfile>] [-R <rh0-image>] [-i <tap-ifname>] [-W <wwwdir>] "
        "[-T <tu58-port>] "
        "[-l <logfile>] [<dl0-image> [<dl1-image> ...]]\n"
        "  -R <img>    initial image for the RH0 (RP06) drive (seed only)\n"
        "  -i <ifn>    tap device name for the network bridge (default tap0)\n"
        "  -p <port>   web panel + REST API port (default 8080; 0 to disable)\n"
        "  -D <dir>    directory that GET /images lists (default /srv/pdp11)\n"
        "  -W <dir>    serve the panel's assets from <dir> instead of the\n"
        "              copy built into the binary (for iterating on the UI)\n"
        "  -T <port>   tu58fs control-API port to poll and proxy for the\n"
        "              TU58 tape panel (default 8081; 0 disables)\n"
        "  -c <file>   persistent disk config (default /srv/pdp11/diskd.conf)\n";

    for (i = 0; i < NBUSES; i++) {
        bus_t *b = g_buses[i];
        int u;
        for (u = 0; u < MAX_UNITS; u++) b->imgfd[u] = -1;
        b->uiofd = -1;
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) verbose = 1;
        else if (strcmp(argv[i], "-s") == 0) swap = 1;
        else if (strcmp(argv[i], "-r") == 0) do_reset = 1;
        else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) logpath = argv[++i];
        else if (strcmp(argv[i], "-d") == 0) g_rl.dlfix = 1;
        else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) http_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "-D") == 0 && i + 1 < argc) img_dir = argv[++i];
        else if (strcmp(argv[i], "-W") == 0 && i + 1 < argc) www_dir = argv[++i];
        else if (strcmp(argv[i], "-T") == 0 && i + 1 < argc) tu58_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) config_path = argv[++i];
        else if (strcmp(argv[i], "-R") == 0 && i + 1 < argc) rh_seed_img = argv[++i];
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) g_net.ifname = argv[++i];
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            fprintf(stderr, "%s", usage);
            return 1;
        }
        else if (rl_seed_n < g_rl.max_units) rl_seed[rl_seed_n++] = argv[i];
        else { fprintf(stderr, "too many RL image files (max %d)\n", g_rl.max_units); return 1; }
    }

    start_ms = now_ms();

    if (!logpath) logpath = "/var/log/pdp11-hostd.log";
    logfp = fopen(logpath, "a");
    if (!logfp) { logfp = stderr; log_msg("cannot open %s (%s), logging to stderr",
                                          logpath, strerror(errno)); }
    setvbuf(logfp, NULL, _IOLBF, 0);
    log_msg("=== pdp11-hostd starting (pid %d) ===", (int)getpid());
    log_msg("verbose = %d, log = %s, config = %s", verbose, logpath, config_path);

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    /* Persistent config wins if present ("last config used"); otherwise the
     * CLI images seed the initial state and get written out as the config. */
    have_config = load_config();
    if (!have_config) {
        log_msg("no persistent config at %s - seeding from CLI args", config_path);
        for (i = 0; i < rl_seed_n; i++) {
            int rc = load_image(&g_rl, i, rl_seed[i]);
            if (rc < 0) {
                log_msg("FATAL: open RL%d image %s: %s", i, rl_seed[i], strerror(-rc));
                return 1;
            }
            log_msg("seed: RL%d = %s", i, rl_seed[i]);
        }
        if (rh_seed_img) {
            int rc = load_image(&g_rh, 0, rh_seed_img);
            if (rc < 0)
                log_msg("seed: RH0 image %s: %s (skipped)", rh_seed_img, strerror(-rc));
            else
                log_msg("seed: RH0 = %s", rh_seed_img);
        }
        save_config();
    } else if (rl_seed_n || rh_seed_img) {
        log_msg("persistent config %s exists - CLI image args ignored "
                 "(last config used wins)", config_path);
    }

    /* No "RL0 must be loaded" check here on purpose: unloading RL0 (and RL1)
     * so the PDP-11's rk->rl->rp auto-boot fallover reaches RH0/RP06 instead
     * is a real, intentional, PERSISTED operating mode (see README "Auto-boot
     * ROM"), not a misconfiguration - the daemon must still start and serve
     * whatever's actually configured, even if that's nothing on RL at all.
     * An unloaded unit already degrades gracefully at the protocol level
     * (logged error + empty read, no core touch) - see the "no image for
     * unit" branch in serve_bus(). */

    if (setup_bus(&g_rl) < 0) {
        log_msg("FATAL: RL bus UIO setup failed");
        return 1;
    }
    setup_bus(&g_rh);   /* non-fatal: RP06 support just stays disabled this run */
    setup_net(&g_net);  /* non-fatal: networking stays disabled this run (e.g. have_xu_net=0) */

    /* Web front panel + REST API (swap images at runtime). -p 0 disables
     * both. The panel thread only pushes when a browser is actually
     * connected, so it costs nothing on a headless boot. */
    if (http_port > 0 && start_httpd() == 0) {
        if (pthread_create(&panel_tid, NULL, panel_thread, NULL) != 0)
            log_msg("API: pthread_create(panel) failed (%s) - live push disabled",
                    strerror(errno));
        else
            panel_thread_started = 1;

        /* tu58fs is a separate process started by hand on whichever ttyUL
         * the tape is wired to, so polling it is always optional and never
         * fatal - "not running" just hides the tape rack. */
        if (tu58_port > 0) {
            if (pthread_create(&tu58_tid, NULL, tu58_thread, NULL) != 0)
                log_msg("TU58: pthread_create failed (%s) - tape panel disabled",
                        strerror(errno));
            else
                tu58_thread_started = 1;
        } else {
            log_msg("TU58: polling disabled (-T 0)");
        }
    }

    /* both present busses are set up and about to serve - kick the PDP-11 so
     * it (re)boots now with us serving, rather than sitting on its power-on
     * boot read */
    if (do_reset)
        pulse_reset();

    if (pthread_create(&rl_tid, NULL, serve_bus, &g_rl) != 0) {
        log_msg("FATAL: pthread_create(RL) failed: %s", strerror(errno));
        return 1;
    }
    if (g_rh.present) {
        if (pthread_create(&rh_tid, NULL, serve_bus, &g_rh) != 0)
            log_msg("RH: pthread_create failed (%s) - RP06 support disabled this run",
                    strerror(errno));
        else
            rh_thread_started = 1;
    }

    if (g_net.present) {
        g_net.tapfd = open_tap(g_net.ifname);
        if (g_net.tapfd < 0) {
            log_msg("NET: could not open tap device %s - networking disabled this run",
                    g_net.ifname);
        } else {
            setup_bridge(g_net.ifname);
            if (pthread_create(&rxtid, NULL, rx_thread, &g_net.tapfd) != 0) {
                log_msg("NET: pthread_create(rx_thread) failed (%s) - networking disabled "
                        "this run", strerror(errno));
            } else if (pthread_create(&txtid, NULL, tx_thread, &g_net) != 0) {
                log_msg("NET: pthread_create(tx_thread) failed (%s) - networking disabled "
                        "this run", strerror(errno));
            } else if (pthread_create(&net_tid, NULL, serve_net, &g_net) != 0) {
                log_msg("NET: pthread_create(serve_net) failed (%s) - networking disabled "
                        "this run", strerror(errno));
            } else {
                tx_thread_started = 1;
                net_thread_started = 1;
                if (pthread_create(&hbtid, NULL, heartbeat_thread, &g_net) != 0)
                    log_msg("NET: pthread_create(heartbeat_thread) failed (%s) - "
                            "heartbeat monitoring disabled this run", strerror(errno));
                else
                    hb_thread_started = 1;
            }
        }
    }

    ui_event("ok", "pdp11-hostd ready: %s %s, %s %s, XU network %s",
             g_rl.ctrl, g_rl.present ? "online" : "ABSENT",
             g_rh.ctrl, g_rh.present ? "online" : "absent",
             g_net.present ? "online" : "absent");

    pthread_join(rl_tid, NULL);
    if (rh_thread_started) pthread_join(rh_tid, NULL);
    if (net_thread_started) pthread_join(net_tid, NULL);
    if (tx_thread_started) {
        pthread_cond_broadcast(&txq_cv);   /* wake it so it sees g_stop */
        pthread_join(txtid, NULL);
    }
    if (hb_thread_started) pthread_join(hbtid, NULL);
    if (panel_thread_started) pthread_join(panel_tid, NULL);
    if (tu58_thread_started) pthread_join(tu58_tid, NULL);
    if (g_httpd) httpd_stop(g_httpd);

    log_msg("=== pdp11-hostd exiting ===");
    if (logfp != stderr) fclose(logfp);
    return 0;
}
