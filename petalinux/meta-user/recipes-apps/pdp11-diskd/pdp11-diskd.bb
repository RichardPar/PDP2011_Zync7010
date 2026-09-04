SUMMARY = "pdp11-diskd - serve the PDP-11's RL and RH/RP06 disks from image files over UIO"
DESCRIPTION = "Userspace daemon that backs the PL's sddisk AXI-Lite block \
devices (RL11 and RH11/RP06, one bridge + UIO interrupt each) with image \
files on the PS. Auto-started at boot (SysV init) with -r so it resets the \
PDP-11 and serves its boot; remembers which image is loaded in which unit \
in a persistent config file (see -c) and restores it across a reboot."
LICENSE = "CLOSED"

SRC_URI = "file://Makefile \
           file://pdp11-diskd.c \
           file://pdp11-diskd.init \
           file://dlctl.sh"
S = "${WORKDIR}"

# dlctl (the runtime image-swap client) shells out to curl against the daemon's
# REST API
RDEPENDS:${PN} += "curl"

inherit update-rc.d
INITSCRIPT_NAME = "pdp11-diskd"
# start late (after filesystems), stop early
INITSCRIPT_PARAMS = "defaults 90 10"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} bindir=${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${S}/pdp11-diskd.init ${D}${sysconfdir}/init.d/pdp11-diskd
    install -m 0755 ${S}/dlctl.sh ${D}${bindir}/dlctl
    install -d ${D}/srv/pdp11
}

FILES:${PN} += "${sysconfdir}/init.d/pdp11-diskd ${bindir}/dlctl /srv/pdp11"
