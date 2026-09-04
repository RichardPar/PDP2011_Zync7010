# program_jtag.tcl - load the fixed PDP-11 bitstream into the PL over JTAG
# (Xilinx Platform Cable USB). Boot the board from the current SD card FIRST so
# the FSBL brings up PS7 clocks (FCLK0/FCLK1) + DDR; this then overwrites only
# the PL with the freshly-built bitstream, leaving PS7/DDR running.
#
# Run headless:
#   source .../Vivado/2023.2/settings64.sh
#   export LD_LIBRARY_PATH=/home/richard/.local/vivado_compat:$LD_LIBRARY_PATH
#   vivado -mode batch -source program_jtag.tcl

set bit [file normalize [file join [file dirname [info script]] ../../deploy/pdp2011_zynq.bit]]
puts "program_jtag: using $bit"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7z010*] 0]
if {$dev eq ""} {
   error "No xc7z010 found on the JTAG chain - check cable/power/boot"
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "program_jtag: DONE - PL reprogrammed with fixed bitstream"
close_hw_target
disconnect_hw_server
