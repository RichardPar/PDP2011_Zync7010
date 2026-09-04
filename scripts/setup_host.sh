#!/bin/bash
# setup_host.sh - one-shot host setup for this Linux Mint 22 box, run with sudo:
#     sudo bash /home/richard/Xilinx/Projects/PDP2011_Zync7010/scripts/setup_host.sh
#
# Does three sudo-only things needed to bring up the PDP2011 flow here:
#   1. PetaLinux 2023.2 host packages that were missing
#   2. point /bin/sh at bash instead of dash (PetaLinux requires bash)
#   3. install the Xilinx Platform Cable USB JTAG drivers (udev rules + fw)
#
# Safe to re-run. Reports status of each step; does not abort the whole
# script if one step has a problem.

set -u
VIVADO=/home/richard/Xilinx/Vivado/2023.2

echo "==================================================================="
echo "STEP 1/3: install missing PetaLinux host packages"
echo "==================================================================="
apt-get update
apt-get install -y \
    gawk python3-jinja2 chrpath socat diffstat texinfo tftpd-hpa screen \
    xterm gnupg zlib1g-dev libncurses-dev \
    build-essential gcc g++ git make net-tools python3 python3-pip \
    xz-utils cpio bc flex bison libssl-dev unzip wget rsync \
    file iproute2 autoconf libtool
echo "STEP 1 exit: $?"

echo
echo "==================================================================="
echo "STEP 2/3: point /bin/sh at bash (PetaLinux needs bash, not dash)"
echo "==================================================================="
# debconf preseed (keeps it correct across future dash upgrades) ...
echo "dash dash/sh boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash
# ... and force the symlink directly, since noninteractive reconfigure has
# been observed NOT to flip it on this box
ln -sf bash /bin/sh
echo -n "/bin/sh now -> "; readlink -f /bin/sh

echo
echo "==================================================================="
echo "STEP 3/3: install Xilinx Platform Cable USB JTAG drivers"
echo "==================================================================="
DRV="$VIVADO/data/xicom/cable_drivers/lin64/install_script/install_drivers"
if [ -x "$DRV/install_drivers" ]; then
    ( cd "$DRV" && ./install_drivers )
    echo "STEP 3 exit: $?  (unplug/replug the Platform Cable USB after this)"
else
    echo "WARNING: cable driver installer not found at $DRV - skipping"
fi

echo
echo "==================================================================="
echo "ALL HOST SETUP STEPS DONE"
echo "  - packages installed"
echo "  - /bin/sh -> $(readlink -f /bin/sh)"
echo "  - JTAG cable drivers installed (replug the cable)"
echo "==================================================================="
