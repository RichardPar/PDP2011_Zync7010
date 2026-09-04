# 01_create_project.tcl - create the Vivado project and add all VHDL sources
# (pdp2011 core + zynq_top.vhd + ddr_mem.vhd + front_panel.vhd/bringup_diag.vhd,
# the two modules zynq_top.vhd instantiates). No BD yet - that's 02.

set proj_name "pdp2011_zynq"
set part_name "xc7z010clg400-1"
set script_dir [file dirname [info script]]
set proj_dir   [file normalize "$script_dir/../$proj_name"]
set core_dir   [file normalize "$script_dir/../pdp2011_core"]

create_project $proj_name $proj_dir -part $part_name -force

add_files -norecurse [glob $core_dir/core/*.vhd]
add_files -norecurse [list $core_dir/zynq_top.vhd $core_dir/ddr_mem.vhd $core_dir/neopixel_driver.vhd \
   $core_dir/front_panel.vhd $core_dir/bringup_diag.vhd]

set_property file_type {VHDL} [get_files *.vhd]
update_compile_order -fileset sources_1

puts "01_create_project.tcl: done, [llength [get_files *.vhd]] VHDL files added"
