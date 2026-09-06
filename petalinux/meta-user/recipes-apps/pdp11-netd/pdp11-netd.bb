SUMMARY = "pdp11-netd - bridge the PDP-11's xu DEUNA ethernet to the LAN via tap0/br0/eth0"
DESCRIPTION = "Userspace daemon that bridges the PL's xu DEUNA (xu.vhd, \
have_xu=1 - UNIBUS 774510, vector 120) to the physical network through a \
tap device bridged with eth0, so RSX/2.11BSD's stock DEUNA drivers reach \
the real LAN. The ENTIRE descriptor-ring walk (2.11BSD struct de_ring \
parsing, OWN-bit handling, ring-position bookkeeping, TXI/RXI strobes) \
lives in this daemon - xuring.vhd only provides the single-word PDP-11 \
memory access primitive, the WRF-latched ring geometry, and a \
command-completed event over AXI-Lite + UIO. Auto-started at boot (SysV \
init); re-DHCPs on br0 after moving eth0 into the bridge."
LICENSE = "CLOSED"

SRC_URI = "file://Makefile \
           file://pdp11-netd.c \
           file://pdp11-netd.init"
S = "${WORKDIR}"

# tap/bridge setup shells out to `ip` (busybox, already present) and brctl
RDEPENDS:${PN} += "bridge-utils"

inherit update-rc.d
INITSCRIPT_NAME = "pdp11-netd"
INITSCRIPT_PARAMS = "defaults 91 9"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} bindir=${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${S}/pdp11-netd.init ${D}${sysconfdir}/init.d/pdp11-netd
}

FILES:${PN} += "${sysconfdir}/init.d/pdp11-netd"
