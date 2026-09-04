SUMMARY = "tu58fs - TU58 DECtape II emulator (serial RSP) for the PDP-11"
DESCRIPTION = "Emulates a TU58 DECtape II over an RS-232/serial line so a PDP-11 \
can access DD: tapes and share files. Pairs with the extra KL11 consoles on \
/dev/ttyUL* (e.g. tu58fs on ttyUL2)."
HOMEPAGE = "https://github.com/RichardPar/tu58fs"
LICENSE = "CLOSED"

SRC_URI = "git://github.com/RichardPar/tu58fs.git;protocol=https;branch=master"
# a632a50: HTTP control API (--api), swaps tapes on a running emulator.
# NOTE: only fetchable once that commit is pushed to GitHub.
SRCREV = "a632a5079a78961cef9f286e0393c01a28a77933"
PV = "1.0+git${SRCPV}"
S = "${WORKDIR}/git"

# The upstream Makefile derives arch/objdir/-m64 from the BUILD host's `uname`,
# which breaks a Yocto cross-compile (it would pass x86-only -m64 to the ARM
# gcc). Override the pieces on the make command line (command-line assignments
# win over the makefile's, so OS_CCDEFS here drops the -m64), keep Yocto's ${CC}
# (carries --sysroot + -march tune) and ${LDFLAGS} (GNU_HASH etc. for QA).
EXTRA_OEMAKE = "'CC=${CC}' 'OBJDIR=bin' 'OS_CCDEFS=-std=c99 -U__STRICT_ANSI__' 'LDFLAGS=${LDFLAGS} -lpthread -lrt'"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/bin/tu58fs ${D}${bindir}/tu58fs
}
