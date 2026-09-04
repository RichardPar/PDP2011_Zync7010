#!/bin/bash
# System-wide libtinfo.so.5 shim so ALL Xilinx tools (Vivado AND the PetaLinux
# xsct/hsi subprocesses, which reset LD_LIBRARY_PATH internally) can load it on
# Ubuntu 24.04 / Mint 22, which ships only libtinfo.so.6. Run with sudo:
#     sudo bash /home/richard/Xilinx/Projects/PDP2011_Zync7010/scripts/fix_libtinfo.sh
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
ldconfig
echo -n "installed: "; ls -l /usr/lib/x86_64-linux-gnu/libtinfo.so.5
