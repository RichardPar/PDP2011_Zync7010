#!/bin/bash
# Stop bitbake's "Failed to spawn fakeroot worker ... Broken pipe" failures,
# which are fork()-under-memory-pressure (swap was 100% full at baseline).
# Two robust fixes, run with sudo:
#   1. vm.overcommit_memory=1  -> fork() is never denied for memory reasons
#   2. add an 8G swapfile       -> real headroom for the native compiles
#     sudo bash /home/richard/Xilinx/Projects/PDP2011_Zync7010/scripts/fix_build_memory.sh

sysctl -w vm.overcommit_memory=1

SW=/swapfile2
if swapon --show 2>/dev/null | grep -q "$SW"; then
  echo "swap $SW already active"
else
  fallocate -l 8G "$SW" 2>/dev/null || dd if=/dev/zero of="$SW" bs=1M count=8192
  chmod 600 "$SW"
  mkswap "$SW"
  swapon "$SW"
fi

echo "=== swap ==="; swapon --show
echo "=== mem ==="; free -h
echo "=== overcommit mode (want 1) ==="; cat /proc/sys/vm/overcommit_memory
