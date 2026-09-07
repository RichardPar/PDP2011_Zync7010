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
   int         unit_sectors;       /* linear BLOCK stride per unit; unused when max_units==1 */
   int         dlfix;              /* RL-only DL$UN workaround, see -d */
   int         required;           /* FATAL if its UIO device isn't found (RL only) */

   int    imgfd[MAX_UNITS];
   char  *imgpath[MAX_UNITS];

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
   .unit_sectors = 40960, .required = 1,
};
static bus_t g_rh = {
   .name = "RH", .unit_prefix = "DB",
   .phys_base = 0x43010000UL, .uio_name = "pdp11disk-rh",
   .buf_words = 256, .sector_bytes = 512, .max_units = 1,
   .unit_sectors = 0, .required = 0,
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

/* RX filter stats, for judging whether the guest is being buried in noise. */
static volatile unsigned long rx_acc_unicast, rx_acc_bcast,
                              rx_drop_bcast, rx_drop_other;

/* The station address xu.vhd's embedded microcode (xubw.mac) latches from
 * the first rx_buf header it ever sees (dbia/dlaa start zeroed in ROM, see
 * the "tst dbia" bootstrap around xubw.mac line 125) and the guest driver
 * then adopts via its own FC_RDPHYAD probe. 08-00-2b is DEC's real
 * registered IEEE OUI - a fitting, non-colliding choice for a virtual
 * DEUNA, and the same convention the earlier from-scratch attempt used
 * (see memory [[xu-ethernet-bridge]]) before pdp11-espd. */
static const uint8_t xu_mac[6] = { 0x08, 0x00, 0x2b, 0x11, 0x22, 0x33 };

static const char *img_dir = "/srv/pdp11";   /* GET /images lists *.img here    */
static int    http_port = 8080;          /* -p N to change, -p 0 to disable     */
static const char *config_path = "/srv/pdp11/diskd.conf";

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
static void pulse_reset(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *gpio;
    unsigned long page = RESET_PHYS & ~0xFFFUL;
    if (fd < 0) { log_msg("reset: open /dev/mem: %s", strerror(errno)); return; }
    gpio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                (off_t)page);
    if (gpio == MAP_FAILED) { log_msg("reset: mmap: %s", strerror(errno)); close(fd); return; }
    gpio[(RESET_PHYS - page) / 4] = 1;
    usleep(300000);
    gpio[(RESET_PHYS - page) / 4] = 0;
    munmap((void*)gpio, 0x1000);
    close(fd);
    log_msg("pulsed PDP-11-only reset (0x%lx)", (unsigned long)RESET_PHYS);
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
    int nf;
    if (unit < 0 || unit >= b->max_units) return -EINVAL;
    /* O_SYNC: every pwrite() in serve_bus() blocks until the sector is on the
     * SD card. Without it, the page cache can reorder/delay writes across a
     * reset or power loss, corrupting the image; sector I/O is already
     * serialized one-at-a-time by img_lock, so the added latency is a single
     * write's worth, not a pipeline stall. */
    nf = open(path, O_RDWR | O_SYNC);
    if (nf < 0) return -errno;
    pthread_mutex_lock(&img_lock);
    if (b->imgfd[unit] >= 0) close(b->imgfd[unit]);
    free(b->imgpath[unit]);
    b->imgfd[unit]   = nf;
    b->imgpath[unit] = strdup(path);
    pthread_mutex_unlock(&img_lock);
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
 * Tiny hand-rolled HTTP/1.1 server on http_port, one request per connection.
 * Runs in its own thread; the load/unload helpers take img_lock so a swap is
 * atomic against a serving thread's file I/O.
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
            "\"rx_drop_bcast\":%lu,\"rx_drop_other\":%lu}",
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
            rx_acc_unicast, rx_acc_bcast, rx_drop_bcast, rx_drop_other);
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

static void http_send(int cfd, int code, const char *ctype, const char *body)
{
    const char *st = code == 200 ? "OK" : code == 400 ? "Bad Request" :
                     code == 404 ? "Not Found" : code == 500 ?
                     "Internal Server Error" : "OK";
    char hdr[256];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        code, st, ctype, strlen(body));
    if (write(cfd, hdr, hn) < 0 || write(cfd, body, strlen(body)) < 0) {
        /* client hung up mid-write; nothing to do */
    }
}

/* pull key=value out of a query string ("unit=1&path=/x"). 0 = found. */
static int get_param(const char *q, const char *key, char *out, size_t outn)
{
    size_t kl = strlen(key);
    while (q && *q) {
        if (strncmp(q, key, kl) == 0 && q[kl] == '=') {
            const char *v = q + kl + 1;
            const char *end = strchr(v, '&');
            size_t vl = end ? (size_t)(end - v) : strlen(v);
            if (vl >= outn) vl = outn - 1;
            memcpy(out, v, vl);
            out[vl] = 0;
            return 0;
        }
        q = strchr(q, '&');
        if (q) q++;
    }
    return -1;
}

static void *http_thread(void *arg)
{
    int lfd, one = 1;
    struct sockaddr_in sa;
    (void)arg;

    lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { log_msg("API: socket: %s", strerror(errno)); return NULL; }
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = htons((uint16_t)http_port);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        log_msg("API: bind :%d failed (%s) - REST API disabled", http_port, strerror(errno));
        close(lfd);
        return NULL;
    }
    listen(lfd, 4);
    log_msg("API: REST server on http://0.0.0.0:%d/ (status,images,load,unload)", http_port);

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        char req[2048], method[8] = {0}, uri[1024] = {0}, body[8192];
        char *query;
        ssize_t r;
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        r = read(cfd, req, sizeof(req) - 1);
        if (r <= 0) { close(cfd); continue; }
        req[r] = 0;
        if (sscanf(req, "%7s %1023s", method, uri) != 2) {
            http_send(cfd, 400, "application/json", "{\"error\":\"bad request\"}\n");
            close(cfd); continue;
        }
        query = strchr(uri, '?');
        if (query) *query++ = 0; else query = (char *)"";

        if (!strcmp(uri, "/status") || !strcmp(uri, "/")) {
            build_status_json(body, sizeof(body));
            http_send(cfd, 200, "application/json", body);
        } else if (!strcmp(uri, "/images")) {
            build_images_json(body, sizeof(body));
            http_send(cfd, 200, "application/json", body);
        } else if (!strcmp(uri, "/load")) {
            char us[16], ps[1024], devs[8] = {0};
            bus_t *bus; int unit;
            get_param(query, "dev", devs, sizeof(devs));
            if (get_param(query, "unit", us, sizeof(us)) ||
                get_param(query, "path", ps, sizeof(ps))) {
                http_send(cfd, 400, "application/json",
                          "{\"error\":\"need unit and path\"}\n");
            } else if (parse_unit_spec(us, devs, &bus, &unit) < 0) {
                http_send(cfd, 400, "application/json",
                          "{\"error\":\"bad unit (want e.g. rl0, rh0, or a bare number)\"}\n");
            } else {
                int rc = do_load(bus, unit, ps);
                if (rc == 0) {
                    build_status_json(body, sizeof(body));
                    http_send(cfd, 200, "application/json", body);
                } else {
                    snprintf(body, sizeof(body),
                             "{\"error\":\"load failed: %s\"}\n", strerror(-rc));
                    http_send(cfd, 400, "application/json", body);
                }
            }
        } else if (!strcmp(uri, "/unload")) {
            char us[16], devs[8] = {0};
            bus_t *bus; int unit;
            get_param(query, "dev", devs, sizeof(devs));
            if (get_param(query, "unit", us, sizeof(us))) {
                http_send(cfd, 400, "application/json", "{\"error\":\"need unit\"}\n");
            } else if (parse_unit_spec(us, devs, &bus, &unit) < 0) {
                http_send(cfd, 400, "application/json",
                          "{\"error\":\"bad unit (want e.g. rl0, rh0, or a bare number)\"}\n");
            } else {
                do_unload(bus, unit);       /* empty-slot unload is not an error here */
                build_status_json(body, sizeof(body));
                http_send(cfd, 200, "application/json", body);
            }
        } else {
            http_send(cfd, 404, "application/json", "{\"error\":\"not found\"}\n");
        }
        close(cfd);
    }
    close(lfd);
    return NULL;
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

    log_msg("NET: opened tap device %s (fd %d)", ifname, fd);
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
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) { if (g_stop) break; continue; }
            log_msg("NET: rx_thread: read(tap) failed: %s", strerror(errno));
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
                ssize_t wr = write(n->tapfd, txbytes + HDRLEN, (size_t)framelen);
                if (wr < 0)
                    log_msg("NET: write(tap) failed: %s", strerror(errno));
                else {
                    learn_guest_ip(txbytes + HDRLEN, framelen);
                    if (verbose)
                        log_msg("NET: TX: %d bytes forwarded to %s", framelen, n->ifname);
                }
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
    pthread_t http_tid, rl_tid, rh_tid, net_tid, rxtid, hbtid;
    int rh_thread_started = 0;
    int net_thread_started = 0;
    int hb_thread_started = 0;
    static const char *usage =
        "usage: pdp11-hostd [-v] [-s] [-r] [-d] [-p <port>] [-D <imgdir>] "
        "[-c <configfile>] [-R <rh0-image>] [-i <tap-ifname>] [-l <logfile>] "
        "[<dl0-image> [<dl1-image> ...]]\n"
        "  -R <img>    initial image for the RH0 (RP06) drive (seed only)\n"
        "  -i <ifn>    tap device name for the network bridge (default tap0)\n"
        "  -p <port>   REST API port (default 8080; 0 to disable)\n"
        "  -D <dir>    directory that GET /images lists (default /srv/pdp11)\n"
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

    /* start the REST API thread (swap images at runtime). -p 0 disables it. */
    if (http_port > 0) {
        if (pthread_create(&http_tid, NULL, http_thread, NULL) != 0)
            log_msg("API: pthread_create failed (%s) - REST API disabled", strerror(errno));
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
            } else if (pthread_create(&net_tid, NULL, serve_net, &g_net) != 0) {
                log_msg("NET: pthread_create(serve_net) failed (%s) - networking disabled "
                        "this run", strerror(errno));
            } else {
                net_thread_started = 1;
                if (pthread_create(&hbtid, NULL, heartbeat_thread, &g_net) != 0)
                    log_msg("NET: pthread_create(heartbeat_thread) failed (%s) - "
                            "heartbeat monitoring disabled this run", strerror(errno));
                else
                    hb_thread_started = 1;
            }
        }
    }

    pthread_join(rl_tid, NULL);
    if (rh_thread_started) pthread_join(rh_tid, NULL);
    if (net_thread_started) pthread_join(net_tid, NULL);
    if (hb_thread_started) pthread_join(hbtid, NULL);

    log_msg("=== pdp11-hostd exiting ===");
    if (logfp != stderr) fclose(logfp);
    return 0;
}
