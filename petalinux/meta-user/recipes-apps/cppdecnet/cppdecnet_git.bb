SUMMARY = "cppdecnet - DECnet Phase II/III/IV stack (C++ port of PyDECnet)"
DESCRIPTION = "Paul Koning's PyDECnet ported to C++: routing (endnode, level 1 \
and level 2 router), NSP, session control, MOP and event logging, with \
Multinet (TCP/UDP) and Ethernet (UDP frames, TAP, pcap) data links. Gives the \
PS its own DECnet node on the same LAN the PDP-11 reaches through the XU \
bridge (see docs/xu-networking-plan.md), so the guest can talk DECnet to \
something without a second machine. Configuration files use PyDECnet's syntax \
unchanged; samples land in ${sysconfdir}/decnet/samples. Ships the daemon \
(decnetd) and dnping. Not auto-started - a DECnet node needs an area/node \
address assigned first, so write ${sysconfdir}/decnet/node.conf and run \
'decnetd /etc/decnet/node.conf' by hand."
HOMEPAGE = "https://github.com/RichardPar/cppdecnet"

# BSD-3-Clause both ways: the port author's own copyright and terms, with
# PyDECnet's original copyright and licence retained below them as its terms
# require. The checksum tracks that combined file - "License text changes"
# (9e741f5) is what added the first half, and moved this md5.
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=e18f311f9d6c52732ea76452acd01040"

SRC_URI = "git://github.com/RichardPar/cppdecnet.git;protocol=https;branch=main \
           file://0001-logging-fall-back-to-fmtlib-when-libstdc-has-no-forma.patch \
           file://decnetd.init \
           file://decnetd.service"
# 3a79cfd: "ddcmp over serial"
SRCREV = "3a79cfd0a6f98bdc502b1b0f17fe0792663bfb24"
PV = "0.1.0+git${SRCPV}"
S = "${WORKDIR}/git"

# fmt: stands in for <format>, which GCC 12.2 (langdale) does not ship - see
# the patch. libpcap: the Ethernet data link that runs on a real segment
# rather than a simulated one; without it the pcap circuit type is compiled
# out, so it is a hard dependency here rather than a probe result.
DEPENDS = "fmt libpcap"

# The upstream default is BUILD=debug, which is -O0 plus ASan and UBSan.
# The feature probes are pinned rather than left to compile-and-see: the
# probe in mk/config.mk runs $(CXX) against the sysroot, so an unpopulated
# sysroot would silently produce a daemon with no pcap in it and no error.
EXTRA_OEMAKE = "BUILD=release V=1 \
                HAVE_PCAP=yes HAVE_EPOLL=yes HAVE_KQUEUE=no \
                'LDLIBS=-lfmt'"

# Auto-start. This image is SysV: PID 1 is busybox init and there is no
# systemctl (the /lib/systemd and /etc/systemd directories on the board are
# udev's compat leftovers, not systemd).
#
# Deliberately NOT 'inherit systemd', even though a unit is shipped below.
# Both sysvinit AND systemd are in this distro's DISTRO_FEATURES while the
# actual init manager is sysvinit, and in that combination the systemd class
# replaces the sysv postinst with a `systemctl enable`. On this board that
# test is simply false, so the init script would be installed and its rc links
# never created - nothing would auto-start. Confirmed by diffing the generated
# pkg_postinst against pdp11-hostd's, which does get its update-rc.d call.
#
# So: update-rc.d owns the wiring, and decnetd.service ships as a plain file -
# ready if this image ever moves to systemd, inert until it does. To make that
# move, add `inherit systemd` and SYSTEMD_SERVICE:${PN} = "decnetd.service".
inherit update-rc.d

INITSCRIPT_NAME = "decnetd"
# Start after pdp11-hostd (90): it is what creates br0, bridging eth0 with the
# PDP-11's tap0, so a pcap circuit on br0 has nothing to open before it runs.
# Stop before it (9 < 10) so the circuit closes while the bridge still exists.
# No leading zero on the stop level: this image's update-rc.d evaluates it
# numerically, and "09" comes out as K00 rather than K09.
INITSCRIPT_PARAMS = "defaults 91 9"

# 'all' would also build the 24 unit-test binaries, which cannot run on the
# build host anyway.
do_compile() {
    oe_runmake lib daemon tools
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/build/release/bin/decnetd ${D}${bindir}/decnetd
    install -m 0755 ${S}/build/release/bin/dnping  ${D}${bindir}/dnping

    # The stack as a library, for anything built against it later. Yocto
    # files these into -staticdev/-dev, so they cost the image nothing.
    install -d ${D}${libdir}
    install -m 0644 ${S}/build/release/lib/libdecnet.a ${D}${libdir}/libdecnet.a
    install -d ${D}${includedir}
    (cd ${S}/include && find decnet -name '*.h' \
        -exec install -D -m 0644 {} ${D}${includedir}/{} \;)

    # Reference configurations, kept beside the empty directory the real one
    # goes in so the two cannot be confused.
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/decnetd.init ${D}${sysconfdir}/init.d/decnetd

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/decnetd.service ${D}${systemd_system_unitdir}/decnetd.service

    install -d ${D}${sysconfdir}/decnet/samples
    install -m 0644 ${S}/samples/*.conf         ${D}${sysconfdir}/decnet/samples/
    install -m 0644 ${S}/samples/nodenames.dat  ${D}${sysconfdir}/decnet/samples/
}

# systemd.bbclass is not inherited (see above), so the unit needs naming here.
FILES:${PN} += "${systemd_system_unitdir}/decnetd.service"
