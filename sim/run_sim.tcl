# ==============================================================================
# run_sim.tcl
#
# Batch Simulation Script for tb_convolver_top in Vivado xsim
#
# Usage from Vivado terminal or shell:
#   vivado -mode batch -source sim/run_sim.tcl
# ==============================================================================

# Create sim work directory
file mkdir sim_build
cd sim_build

# 1. Compile RTL and Testbench
set rtl_files [glob ../rtl/*.sv]
set tb_files  [glob ../tb/tb_convolver_top.sv]

exec xvlog -sv {*}$rtl_files {*}$tb_files

# 2. Elaborate
exec xelab -debug typical tb_convolver_top -s tb_sim

# 3. Simulate
exec xsim tb_sim -R

puts "=========================================================="
puts "  SIMULATION COMPLETED"
puts "=========================================================="
