# ZOM Accelerator: High-Throughput Multi-Mode 2D Convolver

[![Language](https://img.shields.io/badge/Language-SystemVerilog-blue.svg)](https://en.wikipedia.org/wiki/SystemVerilog)
[![FPGA](https://img.shields.io/badge/FPGA-AMD%20Xilinx%20Zynq--7000-orange.svg)](https://www.xilinx.com/products/silicon-devices/soc/zynq-7000.html)
[![Frequency](https://img.shields.io/badge/Target%20Clock-280%20MHz-brightgreen.svg)]()
[![Power](https://img.shields.io/badge/Core%20Dynamic%20Power-84%20mW-success.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**ZOM Accelerator** is an ultra-high performance, energy-optimized 2D convolution hardware accelerator designed for embedded computer vision and deep learning inference on AMD/Xilinx FPGAs (specifically the **PYNQ-Z2 / Zynq-7000 XC7Z020**).

The accelerator achieves **280.034 MHz post-route timing closure** ($T_{clk} = 3.571\text{ ns}$), delivering up to **2 pixels per clock cycle (560 Megapixels/sec)** with only **84 mW** of core dynamic power.

---

## Key Features

* **Single Top-Level Parameter (`MODE`):**
  * **Mode 1 (Centrosymmetric):** Exploits spatial filter symmetry using DSP48E1 pre-adders to reduce DSP slice count by **50%** ($\frac{K^2+1}{2}$ DSPs).
  * **Mode 2 (Asymmetric Dual-Patch):** Applies 1 filter simultaneously across two adjacent spatial windows using Xilinx WP487 packing, delivering **2 pixels/cycle** ($K^2$ DSPs).
  * **Mode 3 (Asymmetric Dual-Kernel):** Computes two independent filters simultaneously in a single pass using SIMD weight packing ($K^2$ DSPs).
* **Dedicated Kernel Memory (`kernel_mem.sv`):**
  * Hardware-bounded depth: instantiated for exactly 1 kernel in Modes 1 & 2, and 2 kernels in Mode 3 (zero wasted flip-flops).
  * Elaboration-time constant address decoding (100% free of runtime hardware divider and modulo units).
* **High-Speed Timing Closure:**
  * Positive post-route setup slack (**WNS = +0.159 ns**) and hold slack (**WHS = +0.055 ns**) at 280 MHz for high-tap filters ($7\times 7$ and $9\times 9$).
* **100% Bit-Exact Verification:**
  * Validated against a bit-exact Python golden model (`Model/conv.py`) across all modes and kernel sizes.

---

## Architecture Overview

```
                         ┌─────────────────────────────┐
                         │      convolver_top          │
                         │   (Single Parameter: MODE)  │
                         └──────────────┬──────────────┘
                                        │
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
       MODE = 1                   MODE = 2                   MODE = 3
  Centrosymmetric Filter     Asymmetric Dual-Patch      Asymmetric Dual-Kernel
  • 1 Kernel / 1 Patch       • 1 Kernel / 2 Patches     • 2 Kernels / 1 Patch
  • DSP Pre-Adder Folded     • WP487 Dual-Patch SIMD    • WP487 Dual-Kernel SIMD
  • Throughput: 1 px/clk     • Throughput: 2 px/clk     • Throughput: 2 px/clk
  • (K²+1)/2 DSPs            • K² DSPs                  • K² DSPs
```

### Hardware Subsystems
1. **`convolver_top.sv`**: Top-level module coordinating control, memory, and datapath.
2. **`kernel_mem.sv`**: Dedicated coefficient register file with elaboration-time address decoding.
3. **`convolver_cu.sv`**: Hardware FSM managing pipeline state and multi-pass kernel iterations.
4. **`conv_datapath.sv`**: Structural wrapper integrating window generation and DSP arithmetic.
5. **`conv_unit.sv`**: Pipelined DSP48E1 compute matrix with operand isolation and balanced adder tree.
6. **`window_gen.sv`**: Streaming sliding-window generator with dual-port line buffers and column shift registers.
7. **`saturate.sv`**: Parameterized right-shift truncation, ReLU activation, and 16-bit signed saturation.

---

## Repository Structure

```
ZOM_Accelerator/
├── README.md                      # Project documentation and user guide
├── LICENSE                        # MIT License
├── .gitignore                     # Vivado and Python ignore rules
│
├── rtl/                           # Synthesizable SystemVerilog Core
│   ├── convolver_top.sv           # Top-level accelerator module with MODE abstraction
│   ├── kernel_mem.sv              # Dedicated kernel memory & address decoder subsystem
│   ├── convolver_cu.sv            # Hardware FSM control unit
│   ├── conv_datapath.sv           # Top-level datapath wrapper
│   ├── conv_unit.sv               # DSP48E1 compute core array
│   ├── window_gen.sv              # Streaming sliding window generator & line buffers
│   ├── adder_tree_stage.sv        # Recursive pipelined adder tree
│   └── saturate.sv                # Saturation arithmetic & ReLU activation
│
├── tb/                            # Verification Testbenches
│   ├── tb_convolver_top.sv        # Comprehensive self-checking top-level testbench
│   ├── tb_conv_unit.sv            # Unit testbench for DSP compute engine
│   ├── tb_window_gen.sv           # Unit testbench for sliding window generator
│   ├── tb_convolver_cu.sv         # Unit testbench for FSM control unit
│   ├── tb_adder_tree_stage.sv     # Unit testbench for adder tree
│   ├── tb_conv_datapath.sv        # Unit testbench for datapath
│   └── tb_saturate.sv             # Unit testbench for saturate/ReLU
│
├── constraints/                   # Timing Constraints
│   └── constraints_pynqz2.xdc     # 280 MHz timing constraints & clock uncertainty for PYNQ-Z2
│
├── scripts/                       # Automation TCL Scripts
│   └── run_ooc_flow.tcl           # Headless Out-Of-Context synthesis, implementation & power
│
├── sim/                           # Simulation Scripts
│   └── run_sim.tcl                # Vivado xsim batch simulation script
│
├── Model/                         # Bit-Exact Golden Reference Model
│   ├── conv.py                    # Standalone bit-exact Python simulator & test vector generator
│   └── original_model.ipynb       # Jupyter notebook reference
│
└── docs/                          # Detailed Technical Reports
    ├── architecture.md            # Detailed architectural & microarchitectural specification
    └── timing_and_power_report.md # 280 MHz timing closure & power optimization case study
```

---

## Quick Start Guide

### 1. Generate Test Vectors (Python)
Use `Model/conv.py` to generate stimulus images, kernel weights, and golden outputs:
```powershell
# Generate test vectors for all 3 modes (32x32 image, 3x3 kernel, 10 cases)
python Model/conv.py --mode all --img_size 32 --kernel_size 3 --num_cases 10

# Or generate for Mode 2 with a 7x7 kernel
python Model/conv.py --mode 2 --img_size 32 --kernel_size 7 --num_cases 10
```

### 2. Run Behavioral Simulation (Vivado xsim)
```powershell
# From Vivado terminal:
vivado -mode batch -source sim/run_sim.tcl
```
The testbench performs dual verification:
1. Comparison against `.mem` vectors generated by the Python golden model.
2. Independent on-the-fly verification against an internal algorithmic reference function.

### 3. Run Synthesis, Implementation & Power Analysis
Run headless Out-Of-Context (OOC) implementation at 280 MHz:
```powershell
# Usage: vivado -mode batch -source scripts/run_ooc_flow.tcl -tclargs <MODE> <KERNEL_SIZE>
vivado -mode batch -source scripts/run_ooc_flow.tcl -tclargs 2 7
```
Reports will be automatically exported to `./reports/`:
* `reports/timing_m2_k7.rpt`
* `reports/utilization_m2_k7.rpt`
* `reports/power_m2_k7.rpt`

---

## Performance & Resource Utilization

### Timing & Power Summary (Zynq-7000 `xc7z020-1` at 280.034 MHz)
| Metric | Value | Status |
| :--- | :---: | :---: |
| **Clock Frequency** | **280.034 MHz** | Target Achieved |
| **Clock Period ($T_{clk}$)** | **3.571 ns** | Target Achieved |
| **Worst Negative Slack (WNS)** | **+0.159 ns** | **MET (Zero Violations)** |
| **Worst Hold Slack (WHS)** | **+0.055 ns** | **MET (Zero Violations)** |
| **Core Dynamic Power** | **84 mW** | Verified via OOC |
| **Device Static Power** | **106 mW** | Silicon Baseline |
| **Peak Throughput (Mode 2)** | **560.07 Mpix/s** | 2 pixels / clock |

---

## Documentation

* [Architecture & Microarchitecture Specification](docs/architecture.md)
* [280 MHz Timing Closure & Power Optimization Report](docs/timing_and_power_report.md)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.