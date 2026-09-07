#!/bin/bash
#
# build.sh - build the entire PDP-11/44-on-Zynq-7010 project from source.
#
# Two stages, run end to end by default:
#   1. Vivado 2023.2  -> deploy/pdp2011_zynq.bit + pdp2011_zynq_wrapper.xsa
#   2. PetaLinux 2023.2 (in an Ubuntu-22.04 Docker container, see docker/)
#      -> deploy/BOOT.BIN, image.ub, boot.scr, rootfs.tar.gz
#      This bakes in the reserved-memory carve-out, the extra KL11 consoles
#      (ttyUL*), and the rootfs apps: pdp11-hostd (disk + network server), tu58fs
#      (TU58 emulator), picocom, pdp11-scripts.
#
# Prerequisites (see README "Building"):
#   - Vivado 2023.2 installed. Override its location with:  VIVADO=/path/to/Vivado/2023.2
#   - Docker, with your user in the "docker" group.
#   - The PetaLinux 2023.2 installer .run. Point to it with:
#         PLNX_INSTALLER=/path/to/petalinux-v2023.2-*-installer.run
#     (or drop it next to / inside this project directory - build.sh will find it).
#
# Usage:
#   ./build.sh              # bitstream, then PetaLinux (full, from scratch)
#   ./build.sh bitstream    # Vivado only
#   ./build.sh petalinux    # PetaLinux only (needs the XSA in deploy/ already)
#
# All build artifacts land in deploy/.

set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
VIVADO="${VIVADO:-$HOME/Xilinx/Vivado/2023.2}"
STAGE="${1:-all}"

# --- stage 1: Vivado bitstream + XSA --------------------------------------
build_bitstream() {
   echo "==================================================================="
   echo " Stage 1/2: Vivado bitstream"
   echo "==================================================================="
   [ -x "$VIVADO/bin/vivado" ] || { echo "ERROR: Vivado not found at $VIVADO (set VIVADO=...)"; exit 1; }

   # Vivado 2023.2 needs libtinfo.so.5; modern distros ship only .so.6.
   # Provide a private symlink and add it to LD_LIBRARY_PATH (no root needed).
   local libtinfo6
   libtinfo6=$(ls /usr/lib/*/libtinfo.so.6 /usr/lib/libtinfo.so.6 2>/dev/null | head -1)
   if [ -n "$libtinfo6" ]; then
      mkdir -p "$ROOT/.vivado_compat"
      ln -sf "$libtinfo6" "$ROOT/.vivado_compat/libtinfo.so.5"
      export LD_LIBRARY_PATH="$ROOT/.vivado_compat:${LD_LIBRARY_PATH:-}"
   fi

   # shellcheck disable=SC1090
   source "$VIVADO/settings64.sh"
   cd "$ROOT/vivado/scripts"
   for s in 01_create_project 02_create_bd 03_add_constraints 04_build; do
      echo "----- vivado: $s -----"
      vivado -mode batch -notrace -nojournal -source "$s.tcl" -log "$s.log"
   done
   echo "-> deploy/pdp2011_zynq.bit + pdp2011_zynq_wrapper.xsa"
}

# --- stage 2: PetaLinux (Dockerized) --------------------------------------
build_petalinux() {
   echo "==================================================================="
   echo " Stage 2/2: PetaLinux (Docker)"
   echo "==================================================================="
   [ -f "$ROOT/deploy/pdp2011_zynq_wrapper.xsa" ] || {
      echo "ERROR: deploy/pdp2011_zynq_wrapper.xsa missing - run the bitstream stage first"; exit 1; }
   command -v docker >/dev/null || { echo "ERROR: docker not installed / not in PATH"; exit 1; }

   cd "$ROOT/docker"
   ./plnx.sh image                       # build the Ubuntu-22.04 tool image
   # install PetaLinux once (skip if already installed)
   PLNX_INSTALL_DIR="${PLNX_INSTALL:-$ROOT/../.petalinux-docker/2023.2}"
   if [ ! -f "$PLNX_INSTALL_DIR/settings.sh" ]; then
      ./plnx.sh install
   else
      echo "PetaLinux already installed at $PLNX_INSTALL_DIR - skipping install"
   fi
   ./plnx.sh build                       # create project, import XSA, build, package
   # gather the remaining SD artifacts (build packages BOOT.BIN; grab the rest)
   ./plnx.sh rebuild
   echo "-> deploy/BOOT.BIN.docker, image.ub.docker, boot.scr.docker, rootfs.tar.gz.docker"
}

case "$STAGE" in
   bitstream) build_bitstream ;;
   petalinux) build_petalinux ;;
   all)       build_bitstream; build_petalinux ;;
   *) echo "usage: $0 {all|bitstream|petalinux}"; exit 1 ;;
esac

echo
echo "==================================================================="
echo " Build complete. Artifacts in deploy/:"
ls -1 "$ROOT"/deploy/ 2>/dev/null | sed 's/^/   /'
echo "==================================================================="
