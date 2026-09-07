SUMMARY = "pdp11-espd - PDP-11 XU network bridge, a 'virtual ESP32' over AXI"
DESCRIPTION = "Userspace daemon that serves the PL's xuaxi AXI-Lite backend \
(a drop-in replacement for the upstream xu.vhd/xubf.vhd's physical SPI link \
to a real ESP32) by reimplementing the real ESP32 firmware's own SPI-slave \
framing against a real Linux tap device bridged with eth0. Auto-started at \
boot (SysV init) after pdp11-diskd."
LICENSE = "CLOSED"

SRC_URI = "file://Makefile \
           file://pdp11-espd.c \
           file://pdp11-espd.init"
S = "${WORKDIR}"

inherit update-rc.d
INITSCRIPT_NAME = "pdp11-espd"
# start after pdp11-diskd (90/10), stop early
INITSCRIPT_PARAMS = "defaults 91 9"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} bindir=${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${S}/pdp11-espd.init ${D}${sysconfdir}/init.d/pdp11-espd
}

FILES:${PN} += "${sysconfdir}/init.d/pdp11-espd"
