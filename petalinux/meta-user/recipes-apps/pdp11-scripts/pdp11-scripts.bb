SUMMARY = "PDP-11-only reset helper (devmem poke of axi_gpio_reset)"
DESCRIPTION = "Installs pdp11_reset.sh to /usr/bin - pulses the PDP-11 core's \
scoped reset via a direct devmem write to axi_gpio_reset (0x41200000)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://pdp11_reset.sh"
S = "${WORKDIR}"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/pdp11_reset.sh ${D}${bindir}/pdp11_reset.sh
}

FILES:${PN} = "${bindir}/pdp11_reset.sh"
