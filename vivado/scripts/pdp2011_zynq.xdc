# Physical pin constraints - QMTECH Zynq-7010 "Bajie" board (clg400 package)
#
# Pin numbers as given directly by the user (not yet cross-checked against a
# vendor schematic/manual in this project - IOSTANDARD LVCMOS33 is an
# assumption matching this board's other 3.3V-bank pins used in the earlier
# Zynq attempt's wozmon feature; verify both before trusting the physical
# link if the console/SD don't come up).

# PDP-11 console UART (KL11 kl0), 9600 8N1
set_property PACKAGE_PIN P20 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property PACKAGE_PIN T19 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

# Physical microSD SPI pins - idle/unused. Both RL11 and RH11/RP06 are AXI
# file-backed now (see README "File-backed RL disk" / "File-backed RH/RP06
# disk"); zynq_top.vhd ties these to idle constants. Kept constrained rather
# than removed in case a physical-disk backend is ever wanted again.
set_property PACKAGE_PIN N20 [get_ports sd_miso]
set_property IOSTANDARD LVCMOS33 [get_ports sd_miso]
set_property PACKAGE_PIN R19 [get_ports sd_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports sd_sclk]
set_property PACKAGE_PIN T20 [get_ports sd_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports sd_mosi]
set_property PACKAGE_PIN V20 [get_ports sd_cs]
set_property IOSTANDARD LVCMOS33 [get_ports sd_cs]

# Bring-up diagnostic LED (active-low, LOW=ON per user), ~0.75Hz blink
# driven by clk50mhz - see zynq_top.vhd header for why this exists
set_property PACKAGE_PIN H17 [get_ports led_n]
set_property IOSTANDARD LVCMOS33 [get_ports led_n]

# 8x8 (64-LED) WS2812 NeoPixel front panel (user-added, single-wire data) -
# see zynq_top.vhd header for the panel layout
set_property PACKAGE_PIN T11 [get_ports neo_dout]
set_property IOSTANDARD LVCMOS33 [get_ports neo_dout]

# Physical PDP-11-only reset button, U15 (user-added). Normally HIGH,
# LOW when pressed - PULLUP added as a safety net in case the board's own
# pull-up is weak/absent, harmless if redundant.
set_property PACKAGE_PIN U15 [get_ports reset_btn_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_btn_n]
set_property PULLUP true [get_ports reset_btn_n]
