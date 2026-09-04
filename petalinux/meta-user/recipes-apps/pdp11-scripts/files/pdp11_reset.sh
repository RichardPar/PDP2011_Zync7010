#!/bin/sh
# pdp11_reset.sh - pulse the PDP-11-only reset from PetaLinux.
#
# Runs ON THE BOARD (target-side), not from the build host. Pokes
# axi_gpio_reset's memory-mapped GPIO_DATA register directly (devmem)
# instead of going through the Linux GPIO subsystem - same technique
# proven on the earlier Zynq attempt after /sys/class/gpio label-based
# enumeration turned out unreliable across boots. C_ALL_OUTPUTS=1 on this
# GPIO, so offset 0x00 from its base is safe to write directly.
#
# axi_gpio_reset is ANDed (inverted) with the normal system reset in the
# block design and drives only zynq_top_0's aresetn - this resets the
# PDP-11 core (and its DDR bridge) without touching Linux, the AXI fabric,
# or anything else on the board.

GPIO_BASE=0x41200000

devmem $GPIO_BASE 32 0x1
sleep 0.1
devmem $GPIO_BASE 32 0x0
