# 02_create_bd.tcl - PS7 (DDR3/MIO from the vendor dict) + FCLK0 (100 MHz,
# ddr_mem's AXI/FSM clock) + FCLK1 (50 MHz, clk50mhz) + S_AXI_HP0 (32-bit,
# through an AXI4->AXI3 protocol converter) + zynq_top module-reference cell
# + a PDP-11-only reset path (axi_gpio on M_AXI_GP0, ANDed with the normal
# system reset - mirrors the earlier project's proven scoped-reset trick).

set script_dir [file dirname [info script]]
set proj_dir   [file normalize "$script_dir/../pdp2011_zynq"]

open_project [file join $proj_dir "pdp2011_zynq.xpr"]
source [file join $script_dir "ps7_config_dict.tcl"]

create_bd_design "system"
current_bd_design [get_bd_designs system]

# --- PS7 ---
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
set_property -dict $ps7_config_dict      [get_bd_cells processing_system7_0]
set_property -dict $ps7_config_overrides [get_bd_cells processing_system7_0]

set DDR_0    [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR_0]
set FIXED_IO [create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO]
connect_bd_intf_net [get_bd_intf_ports DDR_0]    [get_bd_intf_pins processing_system7_0/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]

# --- reset ---
set proc_sys_reset0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]    [get_bd_pins proc_sys_reset0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset0/ext_reset_in]

# --- PDP-11-only reset button: axi_gpio on M_AXI_GP0, ANDed (inverted) with
# the normal peripheral_aresetn. Pulsing the GPIO bit high forces
# zynq_top_0's aresetn low momentarily without touching S_AXI_HP0/the
# protocol converter/the rest of the fabric. ---
set axi_interconn_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_interconn_gp0]
# M00=reset gpio, M01=dbg gpio, M02/M03/M04 = uartlites, M05 = the
# "expansion" sub-interconnect below (RL/RH disk backends + network today,
# more devices later without ever touching NUM_MI or uart_irq_concat here
# again - see docs, this file's own header, and axi_interconn_expansion's
# comment below)
set_property -dict [list CONFIG.NUM_MI {6}] [get_bd_cells axi_interconn_gp0]

set axi_gpio_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_reset]
set_property -dict [list \
   CONFIG.C_GPIO_WIDTH {1} \
   CONFIG.C_ALL_OUTPUTS {1} \
   CONFIG.C_IS_DUAL {0} \
] [get_bd_cells axi_gpio_reset]

# bring-up diagnostics (see zynq_top.vhd header) - read-only, 4 status bits
set axi_gpio_dbg [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_dbg]
set_property -dict [list \
   CONFIG.C_GPIO_WIDTH {7} \
   CONFIG.C_ALL_INPUTS {1} \
   CONFIG.C_IS_DUAL {0} \
] [get_bd_cells axi_gpio_dbg]

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconn_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconn_gp0/M00_AXI] [get_bd_intf_pins axi_gpio_reset/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconn_gp0/M01_AXI] [get_bd_intf_pins axi_gpio_dbg/S_AXI]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconn_gp0/ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconn_gp0/S00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconn_gp0/M00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconn_gp0/M01_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_gpio_reset/s_axi_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_gpio_dbg/s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_gp0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_gp0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_gp0/M00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_gp0/M01_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_gpio_reset/s_axi_aresetn]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_gpio_dbg/s_axi_aresetn]

# --- three extra PDP-11 consoles via axi_uartlite (Serial1/2/3) ---
# Each uartlite is wired BACK-TO-BACK with a KL11 in the fabric: uartlite.tx ->
# zynq_top.serN_rx, zynq_top.serN_tx -> uartlite.rx. It's a real async serial
# link, so the uartlite baud MUST match the KL11's kl_N_bps (ser1 19200, ser2
# 9600, ser3 9600). ACLK is FCLK0 (100 MHz) - set as the uartlite ref freq so
# the baud divisor is correct. Each uartlite's interrupt is wired to the PS via
# IRQ_F2P (through the concat below): the Xilinx 6.1 uartlite driver REQUIRES an
# IRQ (it has no polled mode - a driverless first attempt failed with "IRQ index
# 0 not found"). Linux sees them as /dev/ttyUL* (raw, no getty).
# In0..In2 = uartlites, In3 = RL disk backend, In4 = RH (RP06) disk backend,
# In5 = network (xuaxi/pdp11-espd) backend
set uart_irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat uart_irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {6}] [get_bd_cells uart_irq_concat]
connect_bd_net [get_bd_pins uart_irq_concat/dout] [get_bd_pins processing_system7_0/IRQ_F2P]

set ser_bauds {19200 9600 9600}
for {set i 1} {$i <= 3} {incr i} {
   set baud [lindex $ser_bauds [expr {$i - 1}]]
   set mi   [format "M%02d" [expr {$i + 1}]]   ;# M02, M03, M04
   set ul   [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_$i]
   # 8-N-1 are the IP defaults; only baud + the ref clock freq need setting
   set_property -dict [list \
      CONFIG.C_BAUDRATE $baud \
      CONFIG.C_S_AXI_ACLK_FREQ_HZ {100000000} \
   ] [get_bd_cells axi_uartlite_$i]

   connect_bd_intf_net [get_bd_intf_pins axi_interconn_gp0/${mi}_AXI] [get_bd_intf_pins axi_uartlite_$i/S_AXI]
   connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]        [get_bd_pins axi_interconn_gp0/${mi}_ACLK]
   connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn]    [get_bd_pins axi_interconn_gp0/${mi}_ARESETN]
   connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]        [get_bd_pins axi_uartlite_$i/s_axi_aclk]
   connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn]    [get_bd_pins axi_uartlite_$i/s_axi_aresetn]

   # interrupt -> IRQ_F2P[i-1] via the concat
   connect_bd_net [get_bd_pins axi_uartlite_$i/interrupt] [get_bd_pins uart_irq_concat/In[expr {$i - 1}]]

   # back-to-back with zynq_top_0's serN_tx/serN_rx (wired below, after the
   # zynq_top_0 cell is created)
}

# --- expansion sub-interconnect (M05 on the outer axi_interconn_gp0): one
# nested axi_interconnect instance carrying every PS-facing device bridge
# that isn't the reset/dbg GPIOs or the extra-console uartlites above - RL
# disk, RH (RP06) disk, and network today. Reuses the exact same proven IP
# as axi_interconn_gp0 itself rather than any hand-written AXI-Lite address
# router, and means the OUTER interconnect's NUM_MI/uart_irq_concat sizing
# never has to change again for a future PS-facing device: just bump this
# inner instance's own NUM_MI and add one more M0x here. Addresses/UIO/
# interrupts for RL/RH/net are completely unaffected - see the connections
# below, unchanged from before this was nested. ---
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins axi_interconn_gp0/M05_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_gp0/M05_ARESETN]

set axi_interconn_expansion [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_interconn_expansion]
# M00 = RL disk backend, M01 = RH (RP06) disk backend, M02 = network
# (xuaxi/pdp11-espd) backend, M03-M05 = spare for future PS-facing devices
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells axi_interconn_expansion]

connect_bd_intf_net [get_bd_intf_pins axi_interconn_gp0/M05_AXI] [get_bd_intf_pins axi_interconn_expansion/S00_AXI]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins axi_interconn_expansion/ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins axi_interconn_expansion/S00_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_expansion/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_expansion/S00_ARESETN]

foreach mi {M00 M01 M02 M03 M04 M05} {
   connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins axi_interconn_expansion/${mi}_ACLK]
   connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_interconn_expansion/${mi}_ARESETN]
}
# M03-M05's own AXI data pins stay unconnected (no address assigned) until a
# future device claims one - the interconnect IP still requires every
# enabled master port's clock/reset wired regardless, or validate_bd_design
# errors on "clock pins not connected to a valid clock source" even for a
# port nothing is using yet.

set reset_inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic reset_inv]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells reset_inv]
connect_bd_net [get_bd_pins axi_gpio_reset/gpio_io_o] [get_bd_pins reset_inv/Op1]

set reset_and [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic reset_and]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells reset_and]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins reset_and/Op1]
connect_bd_net [get_bd_pins reset_inv/Res] [get_bd_pins reset_and/Op2]

# --- physical PDP-11-only reset button, U15 (normally HIGH, LOW when
# pressed - same active-low convention as aresetn itself, so it ANDs in
# directly with no inversion needed). Same scope as the GPIO-based reset
# above: only zynq_top_0's aresetn, not S_AXI_HP0/the protocol converter/
# the rest of the fabric - deliberately narrow, and useful specifically
# because it works even if Linux/the AXI fabric itself is the thing
# misbehaving, unlike the devmem-poke reset. ---
set reset_btn_n [create_bd_port -dir I reset_btn_n]
set reset_and2 [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic reset_and2]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells reset_and2]
connect_bd_net [get_bd_pins reset_and/Res] [get_bd_pins reset_and2/Op1]
connect_bd_net [get_bd_ports reset_btn_n] [get_bd_pins reset_and2/Op2]

# --- zynq_top (module reference) ---
set zynq_top_0 [create_bd_cell -type module -reference zynq_top zynq_top_0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins zynq_top_0/aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK1] [get_bd_pins zynq_top_0/clk50mhz]
connect_bd_net [get_bd_pins reset_and2/Res] [get_bd_pins zynq_top_0/aresetn]

# (uart_tx/uart_rx/sd_*/led_n are plain std_logic ports, not a bus interface
# - make them external individually; m_axi and dbg_status stay internal -
# m_axi wired to the protocol converter below, dbg_status to axi_gpio_dbg)
foreach p {uart_tx uart_rx sd_cs sd_mosi sd_sclk sd_miso led_n neo_dout} {
   make_bd_pins_external -name $p [get_bd_pins zynq_top_0/$p]
}
connect_bd_net [get_bd_pins zynq_top_0/dbg_status] [get_bd_pins axi_gpio_dbg/gpio_io_i]

# back-to-back serial links between each uartlite and zynq_top_0's serN pins
# (internal nets - the extra consoles never reach physical pins)
for {set i 1} {$i <= 3} {incr i} {
   connect_bd_net [get_bd_pins axi_uartlite_$i/tx] [get_bd_pins zynq_top_0/ser${i}_rx]
   connect_bd_net [get_bd_pins zynq_top_0/ser${i}_tx] [get_bd_pins axi_uartlite_$i/rx]
}

# --- RL disk backend: axi_interconn_expansion/M00 -> zynq_top_0's inferred
# disk_s_axi AXI-Lite slave; FCLK0/peripheral_aresetn as its clock/reset;
# irq -> concat In3 (irq wiring is unaffected by the expansion bus - it
# never goes through either axi_interconnect). The disk_s_axi_* pins on the
# zynq_top module reference are grouped by Vivado into the 'disk_s_axi'
# interface pin (same as m_axi is). ---
connect_bd_intf_net [get_bd_intf_pins axi_interconn_expansion/M00_AXI] [get_bd_intf_pins zynq_top_0/disk_s_axi]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins zynq_top_0/disk_s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins zynq_top_0/disk_s_axi_aresetn]
connect_bd_net [get_bd_pins zynq_top_0/disk_irq] [get_bd_pins uart_irq_concat/In3]

# --- RH (RP06) disk backend: axi_interconn_expansion/M01 -> zynq_top_0's
# inferred rh_disk_s_axi AXI-Lite slave; same clock/reset; irq -> concat
# In4. Same bridge as the RL disk backend just above, one AXI-Lite slave
# per drive. ---
connect_bd_intf_net [get_bd_intf_pins axi_interconn_expansion/M01_AXI] [get_bd_intf_pins zynq_top_0/rh_disk_s_axi]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins zynq_top_0/rh_disk_s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins zynq_top_0/rh_disk_s_axi_aresetn]
connect_bd_net [get_bd_pins zynq_top_0/rh_disk_irq] [get_bd_pins uart_irq_concat/In4]

# --- network (xuaxi) backend: axi_interconn_expansion/M02 -> zynq_top_0's
# inferred net_s_axi AXI-Lite slave; same clock/reset; irq -> concat In5.
# Served by pdp11-espd on the PS - see docs/xu-networking-plan.md. ---
connect_bd_intf_net [get_bd_intf_pins axi_interconn_expansion/M02_AXI] [get_bd_intf_pins zynq_top_0/net_s_axi]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins zynq_top_0/net_s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins zynq_top_0/net_s_axi_aresetn]
connect_bd_net [get_bd_pins zynq_top_0/net_irq] [get_bd_pins uart_irq_concat/In5]

# --- AXI4 -> AXI3 protocol converter into S_AXI_HP0 (Zynq-7000 HP ports are
# AXI3-only) ---
set axi_protocol_convert_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter axi_protocol_convert_0]
set_property -dict [list \
   CONFIG.SI_PROTOCOL {AXI4} \
   CONFIG.MI_PROTOCOL {AXI3} \
   CONFIG.DATA_WIDTH {32} \
] [get_bd_cells axi_protocol_convert_0]

connect_bd_intf_net [get_bd_intf_pins zynq_top_0/m_axi] [get_bd_intf_pins axi_protocol_convert_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_protocol_convert_0/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_protocol_convert_0/aclk]
connect_bd_net [get_bd_pins proc_sys_reset0/peripheral_aresetn] [get_bd_pins axi_protocol_convert_0/aresetn]

# --- address assignment ---
# zynq_top_0's AXI master (ddr_mem.vhd) needs the HP0 DDR segment mapped so
# its own ddr_base generic (0x1F800000, see ddr_mem.vhd) resolves to real
# DDR3. Map the full available segment - ddr_mem.vhd's own address math is
# what keeps every access inside the intended 8 MB carve-out.
assign_bd_address -target_address_space [get_bd_addr_spaces zynq_top_0/m_axi] \
   [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force

# axi_gpio_reset (PDP-11-only reset button) at 0x41200000, matching
# scripts/pdp11_reset.sh's GPIO_BASE
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
   [get_bd_addr_segs axi_gpio_reset/S_AXI/Reg] -offset 0x41200000 -range 4K -force

# axi_gpio_dbg (bring-up diagnostics, read-only) at 0x41210000
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
   [get_bd_addr_segs axi_gpio_dbg/S_AXI/Reg] -offset 0x41210000 -range 4K -force

# the 3 extra-console uartlites at 0x42000000/0x42010000/0x42020000
# (PetaLinux auto-generates the /dev/ttyUL* nodes from these; the reset-gpio
# devmem base 0x41200000 is unaffected)
for {set i 1} {$i <= 3} {incr i} {
   set off [format 0x%08x [expr {0x42000000 + ($i - 1) * 0x10000}]]
   assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
      [get_bd_addr_segs axi_uartlite_$i/S_AXI/Reg] -offset $off -range 64K -force
}

# RL disk backend AXI-Lite slave at 0x43000000 (pdp11-diskd finds it via the
# PetaLinux-generated UIO node, so the exact address is not load-bearing)
set disk_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins zynq_top_0/disk_s_axi]]
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
   $disk_seg -offset 0x43000000 -range 64K -force

# RH (RP06) disk backend AXI-Lite slave at 0x43010000 - same rationale as the
# RL disk backend above, pdp11-diskd finds it by its UIO map0 address
set rh_disk_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins zynq_top_0/rh_disk_s_axi]]
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
   $rh_disk_seg -offset 0x43010000 -range 64K -force

# network (xuaxi) backend AXI-Lite slave at 0x43020000 - next free 64K slot
# after the disk backends above; pdp11-espd finds it by its UIO map0 address
set net_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins zynq_top_0/net_s_axi]]
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
   $net_seg -offset 0x43020000 -range 64K -force

validate_bd_design
save_bd_design

make_wrapper -files [get_files [file join $proj_dir "pdp2011_zynq.srcs/sources_1/bd/system/system.bd"]] -top
add_files -norecurse [file join $proj_dir "pdp2011_zynq.gen/sources_1/bd/system/hdl/system_wrapper.v"]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "02_create_bd.tcl: done"
