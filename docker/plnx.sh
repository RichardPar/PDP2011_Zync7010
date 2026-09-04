#!/bin/bash
# plnx.sh - orchestrate the Dockerized PetaLinux 2023.2 build.
#
#   ./plnx.sh image     build the Ubuntu-22.04 tool image (once, ~5 min)
#   ./plnx.sh install   install PetaLinux into a persistent host dir (once, ~15 min)
#   ./plnx.sh build     create project, import XSA, full build, package BOOT.BIN
#   ./plnx.sh shell     interactive shell in the container (debug)
#
# All heavy state lives in bind-mounted HOST dirs so it survives container
# exit and the image stays small:
#   $PLNX_INSTALL  the PetaLinux install (~40 GB)
#   $WORK          the PetaLinux project + build tree
#   $DEPLOY        this project's deploy/ (XSA in, BOOT.BIN out)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$HERE/.." && pwd)

IMG=petalinux-2023.2:ubuntu22

# Portable paths - override any of these via the environment:
#   PLNX_INSTALLER  path to the petalinux-v2023.2-*-installer.run
#   PLNX_INSTALL    where the ~40 GB PetaLinux install lives (persistent)
#   PLNX_WORK       where the project + build tree lives
# Defaults: look for the installer next to / under the project, and keep the
# heavy install/work state in a sibling .petalinux-docker dir.
# NB: the trailing `|| true` matters - `ls a b` where only one of the globs
# matches exits 2, and with `set -euo pipefail` that would abort the whole
# script silently before any subcommand ran.
INSTALLER="${PLNX_INSTALLER:-$(ls "$PROJ_ROOT"/../petalinux-v2023.2-*-installer.run \
             "$PROJ_ROOT"/petalinux-v2023.2-*-installer.run 2>/dev/null | head -1 || true)}"
# Where the ~40 GB install and the build tree live. Default to a sibling of the
# project (portable for a fresh clone); but if that doesn't exist and an install
# already lives under ~/petalinux-docker, use that - so it's turnkey on a box
# where the state was set up there. Override either with PLNX_INSTALL/PLNX_WORK.
# Test for a REAL install (settings.sh) / a real project, not just an empty dir
# left behind by a previous mkdir -p, so a stale sibling doesn't shadow the one
# that's actually populated.
if   [ -n "${PLNX_INSTALL:-}" ];                                        then :
elif [ -f "$PROJ_ROOT/../.petalinux-docker/2023.2/settings.sh" ];      then PLNX_INSTALL="$PROJ_ROOT/../.petalinux-docker/2023.2"
elif [ -f "$HOME/petalinux-docker/2023.2/settings.sh" ];               then PLNX_INSTALL="$HOME/petalinux-docker/2023.2"
else                                                                        PLNX_INSTALL="$PROJ_ROOT/../.petalinux-docker/2023.2"
fi
if   [ -n "${PLNX_WORK:-}" ];                                                then WORK="$PLNX_WORK"
elif [ -d "$PROJ_ROOT/../.petalinux-docker/work/pdp2011_zynq_petalinux" ];   then WORK="$PROJ_ROOT/../.petalinux-docker/work"
elif [ -d "$HOME/petalinux-docker/work/pdp2011_zynq_petalinux" ];           then WORK="$HOME/petalinux-docker/work"
else                                                                             WORK="$PROJ_ROOT/../.petalinux-docker/work"
fi
DEPLOY="$PROJ_ROOT/deploy"

if [ "${1:-}" != "image" ] && [ -z "$INSTALLER" ]; then
   echo "ERROR: PetaLinux installer not found. Set PLNX_INSTALLER=/path/to/petalinux-v2023.2-*-installer.run"
   exit 1
fi
mkdir -p "$PLNX_INSTALL" "$WORK" "$DEPLOY"

# run a command in the container with all mounts. $1=command, $2=tty flag.
# $PROJ_ROOT is mounted read-only at /project so the vendored PetaLinux
# customizations (petalinux/meta-user) are available inside the container.
crun() {
  local tty="${2:-}"
  docker run --rm $tty \
    -v "$INSTALLER":/installer.run:ro \
    -v "$PLNX_INSTALL":/opt/petalinux/2023.2 \
    -v "$WORK":/home/plnx/work \
    -v "$DEPLOY":/deploy \
    -v "$PROJ_ROOT":/project:ro \
    "$IMG" bash -lc "$1"
}

case "${1:-}" in
  image)
    docker build -t "$IMG" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$HERE"
    ;;
  install)
    crun 'yes y | bash /installer.run --dir /opt/petalinux/2023.2 --platform arm \
            --log /home/plnx/work/install.log 2>&1; echo "INSTALL_EXIT=$?"'
    ;;
  build)
    crun '
      set -e
      source /opt/petalinux/2023.2/settings.sh
      cd /home/plnx/work
      rm -rf pdp2011_zynq_petalinux
      petalinux-create -t project --template zynq -n pdp2011_zynq_petalinux
      cd pdp2011_zynq_petalinux

      # --- apply the vendored customizations (recipes, device tree, kernel
      # config) so a fresh project gets pdp11-diskd/tu58fs/picocom/pdp11-scripts,
      # the reserved-memory node, the UIO node, etc. ---
      cp -rf /project/petalinux/meta-user/. project-spec/meta-user/

      petalinux-config --get-hw-description=/deploy --silentconfig

      # config settings that are not carried by meta-user: ext4-on-SD rootfs and
      # the uio_pdrv_genirq bootarg (see README)
      C=project-spec/configs/config
      sed -i "s|.*CONFIG_SUBSYSTEM_ROOTFS_INITRD.*|# CONFIG_SUBSYSTEM_ROOTFS_INITRD is not set|" $C
      sed -i "s|.*CONFIG_SUBSYSTEM_ROOTFS_EXT4.*|CONFIG_SUBSYSTEM_ROOTFS_EXT4=y|" $C
      sed -i "s|.*CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT.*|# CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT is not set|" $C
      grep -q "^CONFIG_SUBSYSTEM_SDROOT_DEV=" $C || echo "CONFIG_SUBSYSTEM_SDROOT_DEV=\"/dev/mmcblk0p2\"" >> $C
      sed -i "s|^CONFIG_SUBSYSTEM_EXTRA_BOOTARGS=.*|CONFIG_SUBSYSTEM_EXTRA_BOOTARGS=\"uio_pdrv_genirq.of_id=generic-uio\"|" $C
      petalinux-config --silentconfig

      petalinux-build
      petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
        --fpga /deploy/pdp2011_zynq.bit --u-boot --force
      cp -f images/linux/BOOT.BIN /deploy/BOOT.BIN
      cp -f images/linux/image.ub /deploy/image.ub
      [ -f images/linux/boot.scr ] && cp -f images/linux/boot.scr /deploy/boot.scr || true
      cp -f images/linux/rootfs.tar.gz /deploy/rootfs.tar.gz 2>/dev/null || true
      echo "BUILD_DONE -> deploy/BOOT.BIN (+ image.ub, boot.scr, rootfs.tar.gz)"
    '
    ;;
  rebuild)
    # incremental rebuild of the EXISTING project (keeps meta-user
    # customizations: reserved-memory dtsi, pdp11-scripts, EXT4 SD rootfs).
    # Applies config changes, builds, packages, and gathers ALL SD artifacts.
    crun '
      set -e
      source /opt/petalinux/2023.2/settings.sh
      cd /home/plnx/work/pdp2011_zynq_petalinux
      petalinux-config --silentconfig
      petalinux-build
      petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
        --fpga /deploy/pdp2011_zynq.bit --u-boot --force
      cp -f images/linux/BOOT.BIN   /deploy/BOOT.BIN
      cp -f images/linux/image.ub   /deploy/image.ub
      [ -f images/linux/boot.scr ] && cp -f images/linux/boot.scr /deploy/boot.scr || true
      for r in rootfs.tar.gz rootfs.cpio.gz rootfs.ext4; do
        [ -f images/linux/$r ] && cp -f images/linux/$r /deploy/$r || true
      done
      echo "REBUILD_DONE"; ls -la /deploy/BOOT.BIN /deploy/image.ub /deploy/boot.scr /deploy/rootfs.*
    '
    ;;
  rehw)
    # re-import a NEW XSA into the existing project (device tree picks up new PL
    # IP, e.g. the uartlites) WITHOUT wiping meta-user customizations, then full
    # build + package + gather all SD artifacts to deploy/.
    crun '
      set -e
      source /opt/petalinux/2023.2/settings.sh
      cd /home/plnx/work/pdp2011_zynq_petalinux
      petalinux-config --get-hw-description=/deploy --silentconfig
      petalinux-build
      petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
        --fpga /deploy/pdp2011_zynq.bit --u-boot --force
      cp -f images/linux/BOOT.BIN /deploy/BOOT.BIN
      cp -f images/linux/image.ub /deploy/image.ub
      [ -f images/linux/boot.scr ] && cp -f images/linux/boot.scr /deploy/boot.scr || true
      cp -f images/linux/rootfs.tar.gz /deploy/rootfs.tar.gz 2>/dev/null || true
      echo "REHW_DONE"; ls -la /deploy/BOOT.BIN /deploy/image.ub /deploy/boot.scr /deploy/rootfs.tar.gz
    '
    ;;
  package)
    # fast: repackage BOOT.BIN with the current /deploy/pdp2011_zynq.bit using
    # the already-built fsbl/u-boot ELFs (no full rebuild). -> deploy/BOOT.BIN
    crun '
      set -e
      source /opt/petalinux/2023.2/settings.sh
      cd /home/plnx/work/pdp2011_zynq_petalinux
      petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
        --fpga /deploy/pdp2011_zynq.bit --u-boot --force
      cp -f images/linux/BOOT.BIN /deploy/BOOT.BIN
      echo "PACKAGE_DONE -> deploy/BOOT.BIN"; ls -la /deploy/BOOT.BIN
    '
    ;;
  shell)
    crun 'bash' '-it'
    ;;
  *)
    echo "usage: $0 {image|install|build|rebuild|package|shell}"; exit 1 ;;
esac
