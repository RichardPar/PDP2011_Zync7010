# 03_add_constraints.tcl - add the physical pin XDC

set script_dir [file dirname [info script]]
set proj_dir   [file normalize "$script_dir/../pdp2011_zynq"]

open_project [file join $proj_dir "pdp2011_zynq.xpr"]

add_files -fileset constrs_1 -norecurse [file join $script_dir "pdp2011_zynq.xdc"]

puts "03_add_constraints.tcl: done"
