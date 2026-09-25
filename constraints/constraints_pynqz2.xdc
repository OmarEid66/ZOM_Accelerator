# ==============================================================================
# constraints_pynqz2.xdc
# Target Device: AMD/Xilinx Zynq-7000 (XC7Z020-1CLG400C)
# Target Board:  PYNQ-Z2
# Description:   Corrected timing constraints for convolver_top accelerator.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Primary Clock Definition
# ------------------------------------------------------------------------------
# Target Frequency: 280.0 MHz (Period: 3.571 ns)
create_clock -period 3.571 -name sys_clk -waveform {0.000 1.785} [get_ports clk]

# Clock uncertainty modeling (jitter + phase margin)
set_clock_uncertainty -setup 0.050 [get_clocks sys_clk]
set_clock_uncertainty -hold 0.050 [get_clocks sys_clk]

# ------------------------------------------------------------------------------
# 2. Asynchronous Reset (Active-Low)
# ------------------------------------------------------------------------------
set_false_path -from [get_ports -quiet rst_n]

# ------------------------------------------------------------------------------
# 3. Quasi-Static Configuration Ports (Loaded while state == S_IDLE)
# ------------------------------------------------------------------------------
set_false_path -from [get_ports -quiet kernel_wr_en]
set_false_path -from [get_ports -quiet {kernel_wr_addr {kernel_wr_addr[*]}}]
set_false_path -from [get_ports -quiet {kernel_wr_data {kernel_wr_data[*]}}]
set_false_path -from [get_cells -hierarchical -quiet -filter {NAME =~ *kernel_reg* && IS_SEQUENTIAL}]


# ------------------------------------------------------------------------------
# 4. Streaming Output Interface Ports (Option A)
# ------------------------------------------------------------------------------
# In out-of-context synthesis, outputs are directly registered at the boundary.

# ------------------------------------------------------------------------------
# 5. Accelerator Control & Status Ports
# ------------------------------------------------------------------------------
# 'start' is triggered by software/pushbutton, while 'busy' and 'done' drive
# on-board status LEDs (R14/P14) or AXI interrupt lines. They are not high-speed
# source-synchronous off-chip buses and must be treated as false paths.
set_false_path -from [get_ports -quiet start]
set_false_path -to [get_ports -quiet {busy done}]


# ------------------------------------------------------------------------------
# 6. Physical Pin Constraints (Uncomment ONLY for direct bitstream generation)
# ------------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports clk]
# set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports rst_n]
# set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports busy]
# set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports done]

# ------------------------------------------------------------------------------
# 7. Static and Dynamic Power Optimization Constraints
# ------------------------------------------------------------------------------
# Eliminates DC pull-up resistor leakage and floating-pin shoot-through on unused pads:
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

# Accurate thermal modeling (typical ambient with moderate airflow):
set_operating_conditions -ambient_temp 25.0
set_operating_conditions -airflow 250

# Standard 5 pF capacitive load on all output ports:
set_load 5.000 [all_outputs]
