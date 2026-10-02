# Non-project Vivado build for the K7 B210 clone (xc7k325tffg676-2).
#
# Reproduces the vendor's default synth_1/impl_1 flow without the .xpr:
#   vivado -mode batch -source fpga/scripts/build.tcl
# or simply `make` from fpga/. Outputs land in fpga/build/.
#
# Load the result with UHD:
#   uhd_usrp_probe --args "type=b200,fpga=fpga/build/b210_k7.bin"

set PART xc7k325tffg676-2
set TOP  b200

set script_dir [file dirname [file normalize [info script]]]
set repo       [file normalize [file join $script_dir .. ..]]
set build      [file join $repo fpga build]
set ipdir      [file join $build ip]

cd $repo
source [file join $script_dir sources.tcl]

file mkdir $build
file delete -force $ipdir
file mkdir $ipdir

create_project -in_memory -part $PART
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]

# Global include (TARGET_B210)
read_verilog fpga/top/b200/Define.vh
set_property is_global_include true [get_files fpga/top/b200/Define.vh]

read_verilog -library xil_defaultlib $VERILOG_SOURCES

# Clock generator IP. Copied into build/ so generated outputs stay out of git;
# synthesized inline (no OOC checkpoint) so the XDC hierarchy gen_clks/inst/... holds.
# Vivado writes the IP's generated files under the vendor project name in the
# .xci (B210_Project_Firmwire.gen/, git-ignored). Clear them so a changed
# IFCLK_PHASE is regenerated rather than locking the IP on stale outputs.
file delete -force [file join $repo B210_Project_Firmwire.gen]
file copy [file join $repo fpga ip b200_clk_gen] $ipdir
read_ip [file join $ipdir b200_clk_gen b200_clk_gen.xci]
set_property generate_synth_checkpoint false [get_files b200_clk_gen.xci]
upgrade_ip -quiet [get_ips]
# Third output = IFCLK source (FX3 PCLK). 261 deg: PCLK leads gpif_clk by 2.75 ns
# so the FX3's data is mid-window at the FPGA's IOB registers (b210.xdc, "FX3
# GPIF"). IFCLK_PHASE=<deg> overrides it for experiments.
set ifclk_phase [expr {[info exists ::env(IFCLK_PHASE)] ? $::env(IFCLK_PHASE) : 261}]
set_property CONFIG.CLKOUT3_REQUESTED_PHASE $ifclk_phase [get_ips b200_clk_gen]
puts "IFCLK phase: $ifclk_phase deg"
generate_target all [get_ips]

# Pre-built halfband decimator netlists (vendor coregen)
read_edif fpga/top/b200/coregen_dsp/hbdec1.edif
read_edif fpga/top/b200/coregen_dsp/hbdec2.edif

read_xdc fpga/top/b200/b210.xdc

synth_design -top $TOP -part $PART -include_dirs [list [file join $repo fpga lib dsp]]
write_checkpoint -force [file join $build post_synth.dcp]
report_utilization -file [file join $build utilization_synth.rpt]

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $build post_route.dcp]

report_utilization       -file [file join $build utilization_placed.rpt]
report_timing_summary    -file [file join $build timing_summary.rpt]
report_clock_utilization -file [file join $build clock_utilization.rpt]
report_drc               -file [file join $build drc.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING: WNS=$wns ns  WHS=$whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met; bitstream not written"
    exit 1
}

write_bitstream -force -bin_file [file join $build b210_k7.bit]
puts "DONE: [file join $build b210_k7.bin]"
