# 04_build.tcl - synth, impl, bitstream, XSA export

set script_dir [file dirname [info script]]
set proj_dir   [file normalize "$script_dir/../pdp2011_zynq"]
set deploy_dir [file normalize "$script_dir/../../deploy"]

open_project [file join $proj_dir "pdp2011_zynq.xpr"]

catch {reset_run synth_1}
catch {reset_run impl_1}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
   error "synth_1 did not complete successfully"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
   error "impl_1 did not complete successfully"
}

open_run impl_1
report_timing_summary -file [file join $proj_dir "timing_summary.rpt"]
report_utilization -file [file join $proj_dir "utilization.rpt"]

file mkdir $deploy_dir
write_bitstream -force [file join $deploy_dir "pdp2011_zynq.bit"]
write_hw_platform -fixed -include_bit -force [file join $deploy_dir "pdp2011_zynq_wrapper.xsa"]

puts "04_build.tcl: done - bitstream and XSA in $deploy_dir"
