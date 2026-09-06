SUMMARY = "pdp11-netd - bridge the PDP-11's xu DEUNA ring engine to Linux networking"
DESCRIPTION = "Userspace daemon that backs xuring.vhd's AXI-Lite + UIO frame \
handoff for xu.vhd's DEUNA descriptor-ring packet engine. Reads/writes raw \
frame bytes only - the PDP-11 ring format itself is entirely xu.vhd's \
concern. Bridges a tap device with eth0 so RSX/2.11BSD's stock DEUNA \
drivers reach the physical network. Auto-started at boot (SysV init)."
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
