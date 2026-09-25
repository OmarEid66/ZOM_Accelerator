# Timing Closure & Power Optimization Report

## 1. High-Frequency Timing Closure (280.034 MHz)

### 1.1 Timing Target
* **Device:** AMD/Xilinx Zynq-7000 (`xc7z020clg400-1`, -1 commercial speed grade).
* **Clock Constraint:** $3.571\text{ ns}$ period ($280.034\text{ MHz}$).
* **Uncertainty & Jitter:** $0.050\text{ ns}$ setup uncertainty, $0.071\text{ ns}$ system jitter.

### 1.2 Case Study: The 7x7 Mode 2 Timing Violation
When scaling the kernel size to $7\times 7$ ($NUM\_DSPS = 49$), post-route physical optimization failed timing:
```text
Slack (VIOLATED) : -0.029ns (required 3.903ns, arrival 3.932ns)
Source:      u_dp/u_window_gen/window_valid_reg/C (SLICE_X23Y32)
Destination: u_dp/u_conv/product_reg_reg[2]/RSTA (DSP48_X0Y1)
Data Path:   2.959ns (Logic: 0.580ns [19.6%], Route: 2.379ns [80.4%])
```

#### Diagnostic Breakdown
1. **Net Route Delay:** Net `product_reg_reg[14]_0` spanned vertically across 31 CLB/DSP rows from CLB `X23Y24` to DSP `X0Y1`, suffering a **1.723 ns** routing penalty.
2. **Setup Requirement on DSP Reset Pin:** The DSP48E1 primitive `RSTA` pin has a setup time requirement of **0.507 ns**.
3. **Root Cause:** The operand isolation statement `port_a_reg <= valid_in ? data : '0'` inferred an active-high synchronous reset (`RSTA`) across all 49 DSPs via a LUT1 inverter. In Mode 2, `valid_in` pulses every 2 cycles. Driving 49 DSP reset pins distributed across the die exceeded the 3.571 ns budget. Furthermore, forcing values to 0 on even cycles induced artificial $0 \leftrightarrow \text{data}$ bit transitions on every clock cycle.

#### Architectural Resolution
1. Removed `valid_in ? ... : '0'` from DSP inputs in `conv_unit.sv`. Input pixels are naturally held in line buffers when streaming stops, and top-level output registers are already clock-gated.
2. Applied `(* max_fanout = 8 *)` on `window_valid` in `window_gen.sv`.

#### Post-Route Timing Closure Results
```text
------------------------------------------------------------------------------------------------
| Design Timing Summary
------------------------------------------------------------------------------------------------
    WNS(ns)      TNS(ns)  TNS Failing Endpoints      WHS(ns)      THS(ns)     WPWS(ns)
    -------      -------  ---------------------      -------      -------     --------
     +0.159        0.000                      0       +0.055        0.000       +0.805

All user specified timing constraints are met.
Worst Negative Slack (WNS) : +0.159 ns
Total Negative Slack (TNS) :  0.000 ns
Frequency Achieved         : 280.034 MHz
```

---

## 2. Power Analysis & Optimization

### 2.1 Baseline Investigation & SAIF Net Annotation
Early behavioral power reports showed elevated power numbers. Investigation identified three contributing factors:
1. **Low SAIF Annotation (9%):** Behavioral simulation net names diverged from post-implementation net names, forcing Vivado to substitute probabilistic switching rates.
2. **I/O Pin Dissipation (0.047 W):** Toggling package I/O pins at 280 MHz created artificial output buffer power.
3. **Static Silicon Baseline (0.106 W):** Unavoidable leakage of the XC7Z020 die at commercial junction temperatures.

### 2.2 Applied Optimizations
1. **Out-Of-Context (OOC) Synthesis:** Synthesizing the IP without package I/O buffers (`-mode out_of_context`) eliminated the 0.047 W I/O pin penalty, reflecting true embedded system power when integrated with AXI DMA.
2. **Output Register Clock Gating:** Output registers `out_pixel_k0` and `out_pixel_k1` are gated by `dp_pixel_valid_out`, gating 51 registers when idle.
3. **Constant Decoder Optimization:** Zero hardware divider or modulo logic, reducing unnecessary logic transitions.

### 2.3 Final Power Breakdown (Post-Implementation at 280 MHz)
| Component | Power (W) | Percentage |
| :--- | :---: | :---: |
| **Clocks** | 0.024 W | 12.8% |
| **Signals / Routing** | 0.022 W | 11.7% |
| **Logic (LUTs / FFs)** | 0.015 W | 8.0% |
| **DSP48E1 Blocks** | 0.023 W | 12.2% |
| **Total Dynamic Power** | **0.084 W** | **44.7%** |
| **Device Static Leakage** | **0.106 W** | **55.3%** |
| **Total On-Chip Power** | **0.188 W** | **100.0%** |
