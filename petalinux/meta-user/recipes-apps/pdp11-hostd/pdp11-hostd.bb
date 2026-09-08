SUMMARY = "pdp11-hostd - serve the PDP-11's RL/RH disks and XU network bridge over UIO"
DESCRIPTION = "Userspace daemon that backs every PS-facing PDP-11 device \
bridge from one process: the PL's sddisk AXI-Lite disk backends (RL11 and \
RH11/RP06, image files on the PS) and the xuaxi AXI-Lite XU (DEUNA) \
network bridge (a Linux tap device bridged with eth0) - see \
docs/xu-networking-plan.md. Replaces the earlier separate pdp11-diskd/ \
pdp11-espd pair now that all three device bridges share one AXI-Lite \
expansion bus in the FPGA fabric. Auto-started at boot (SysV init) with -r \
so it resets the PDP-11 and serves its boot; remembers which disk image is \
loaded in which unit in a persistent config file (see -c) and restores it \
across a reboot. Also serves a web front panel on the same port: DEC-styled \
RL02/RP06 drive fronts and a DEUNA panel whose lamps follow the real \
counters, live over a WebSocket, with mount/unmount controls per drive. The \
page is built into the binary (see mkwww.sh) so deploying the daemon is \
still a single file copy; libhttpd (httpd.c) serves it with no new runtime \
dependency."
LICENSE = "CLOSED"

SRC_URI = "file://Makefile \
           file://pdp11-hostd.c \
           file://httpd.c \
           file://httpd.h \
           file://mkwww.sh \
           file://www \
           file://pdp11-hostd.init \
           file://dlctl.sh"
S = "${WORKDIR}"

# dlctl (the runtime disk image-swap client) shells out to curl against the
# daemon's REST API
RDEPENDS:${PN} += "curl"

inherit update-rc.d
INITSCRIPT_NAME = "pdp11-hostd"
# start late (after filesystems), stop early
INITSCRIPT_PARAMS = "defaults 90 10"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} bindir=${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${S}/pdp11-hostd.init ${D}${sysconfdir}/init.d/pdp11-hostd
    install -m 0755 ${S}/dlctl.sh ${D}${bindir}/dlctl
    install -d ${D}/srv/pdp11
}

FILES:${PN} += "${sysconfdir}/init.d/pdp11-hostd ${bindir}/dlctl /srv/pdp11"
