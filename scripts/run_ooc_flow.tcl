# ==============================================================================
# run_ooc_flow.tcl
#
# Headless Out-Of-Context (OOC) Synthesis & Implementation for convolver_top
# Target: AMD/Xilinx Zynq-7000 (xc7z020clg400-1, PYNQ-Z2)
#
# Usage from Vivado terminal:
#   vivado -mode batch -source scripts/run_ooc_flow.tcl -tclargs <MODE> <KERNEL_SIZE>
# Example:
#   vivado -mode batch -source scripts/run_ooc_flow.tcl -tclargs 2 7
# ==============================================================================
set_param general.maxThreads 8

# Parse arguments (Default: Mode 3, 3x3 kernel)
set mode 3
set k_size 3
if { $argc >= 1 } { set mode   [lindex $argv 0] }
if { $argc >= 2 } { set k_size [lindex $argv 1] }

puts "=========================================================="
puts "  RUNNING OOC FLOW FOR CONVOLVER_TOP"
puts "  MODE:        $mode"
puts "  KERNEL SIZE: ${k_size}x${k_size}"
puts "=========================================================="

# 1. Read RTL Sources
read_verilog -sv [glob rtl/*.sv]

# 2. Read Timing Constraints
read_xdc constraints/constraints_pynqz2.xdc

# 3. Out-Of-Context Synthesis
synth_design -top convolver_top -part xc7z020clg400-1 \
    -generic MODE=$mode \
    -generic IMG_SIZE=32 \
    -generic KERNEL_SIZE=$k_size \
    -mode out_of_context

# 4. Implementation Steps
opt_design
power_opt_design
place_design
phys_opt_design
route_design

# 5. Generate Reports
file mkdir reports
report_utilization -file reports/utilization_m${mode}_k${k_size}.rpt
report_timing_summary -max_paths 10 -file reports/timing_m${mode}_k${k_size}.rpt
report_power -file reports/power_m${mode}_k${k_size}.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "=========================================================="
puts "  IMPLEMENTATION COMPLETE"
puts "  Worst Negative Slack (WNS): $wns ns"
puts "  Reports saved to ./reports/"
puts "=========================================================="
