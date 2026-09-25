# Architecture Specification: Multi-Mode 2D Convolver Accelerator

## 1. Executive Overview

The **ZOM Accelerator** is an ultra-high throughput, energy-efficient 2D convolution engine implemented in synthesizable SystemVerilog. Optimized for **AMD/Xilinx 7-Series & Zynq-7000 FPGAs** (specifically the PYNQ-Z2 `xc7z020clg400-1`), the core achieves **280.034 MHz timing closure** with full pipelining and zero BRAM overhead on the datapath.

### Key Architectural Highlights
* **Target Clock:** 280.034 MHz ($T_{clk} = 3.571\text{ ns}$) at -1 speed grade.
* **Throughput:** Up to **2 pixels/cycle** (560.07 Megapixels/sec peak).
* **Power Efficiency:** **0.084 W** core dynamic power at 280 MHz.
* **Kernel Flexibility:** Supports square kernels of size $1\times 1, 3\times 3, 5\times 5, 7\times 7, 9\times 9$.
* **Three Operational Modes:** Single centrosymmetric kernel, dual-patch asymmetric kernel, and dual-kernel asymmetric filtering.
* **Memory Subsystem:** Dedicated, tightly bounded `kernel_mem` module with elaboration-time constant address decoding.

---

## 2. Operational Modes & Mathematical Formulations

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

### Mode 1: Centrosymmetric Kernel (Folded Pre-Adder)
Exploits point symmetry around the center of the convolution filter:
$$W[r, c] = W[K-1-r, K-1-c]$$
By pairing symmetric pixels before multiplication using the internal DSP48E1 pre-adder:
$$P_{sym} = (P_A + P_D) \times W_{unique}$$
This cuts the required number of DSP slices by **50%**:
$$\text{NUM\_DSPS} = \frac{K^2 + 1}{2}$$

### Mode 2: Asymmetric Dual-Patch (2 Pixels/Cycle)
Applies a single asymmetric kernel simultaneously across two adjacent spatial windows (Patch 0 at column $c$, Patch 1 at column $c+1$) using Xilinx WP487 arithmetic packing:
* **Port A (25-bit):** High half carries Patch 1 pixel ($P_1$), low half carries Patch 0 pixel ($P_0$):
  $$\text{Port A} = (P_1 \ll 16) + P_0$$
* **Port B (18-bit):** Signed 8-bit weight $W_0$.
* **Multiplier Output (43-bit):**
  $$\text{Product} = \text{Port A} \times \text{Port B} = (P_1 \times W_0 \ll 16) + (P_0 \times W_0)$$
Because the 16-bit shift guarantees non-overlapping products, both multiplications execute in a single DSP slice, achieving **2 outputs per clock cycle**.

### Mode 3: Asymmetric Dual-Kernel (2 Independent Filters)
Applies two distinct asymmetric kernels ($K_0, K_1$) simultaneously to the same spatial window:
* **Port A (25-bit):** Static packed weights from Kernel 1 and Kernel 0:
  $$\text{Port A} = (W_{k1} \ll 16) + W_{k0}$$
* **Port B (18-bit):** Streamed image pixel $P_0$.
* **Multiplier Output:**
  $$\text{Product} = (W_{k1} \times P_0 \ll 16) + (W_{k0} \times P_0)$$
Yields simultaneous, bit-exact outputs for two independent filters in a single pass.

---

## 3. Subsystem Breakdown

### 1. `convolver_top`
Top-level wrapper that coordinates control, memory, and datapath. Accepts a single `MODE` parameter ($1, 2, 3$) and derives:
```systemverilog
localparam bit IS_SYMMETRIC  = (MODE == 1) ? 1'b1 : 1'b0;
localparam int NUM_KERNELS   = (MODE == 3) ? 2 : 1;
localparam int NUM_TAPS      = KERNEL_SIZE * KERNEL_SIZE;
localparam int TOTAL_WEIGHTS = NUM_KERNELS * NUM_TAPS;
```

### 2. `kernel_mem`
Dedicated storage module for filter coefficients:
* Sized strictly for `NUM_KERNELS`: depth is 1 for Modes 1 & 2, and 2 for Mode 3.
* Eliminates runtime hardware dividers (`/`) and modulo (`%`) by using an elaboration-time constant decoder.
* Protects active weight readout with boundary guards to prevent out-of-bounds array access.

### 3. `window_gen` (Sliding Window Generator)
Generates the 2D window taps from a continuous 1D raster-order pixel stream:
* Implements $(K-1)$ line buffers implemented as dual-port distributed/block shift registers.
* Row column shift registers provide immediate spatial access to $K \times K$ taps.
* For Mode 2 (Dual-Patch), an additional column register (`COL_DEPTH = K + 1`) is maintained to extract both Patch 0 and Patch 1 simultaneously.

### 4. `conv_unit` (DSP48E1 Processing Array)
Core arithmetic matrix:
* **Stage 0:** Input boundary register.
* **Stage 1:** DSP multiply (`AREG`, `BREG`, `MREG`).
* **Stage 2:** Registered product (`PREG`).
* **Stage 3:** High/low slice unpacker.
* **Stage 4+:** Recursive pipelined adder tree with balanced latency.

### 5. `saturate`
Performs right-shift truncation according to kernel size:
$$\text{TRUNC\_BITS} = \begin{cases} 3, & K \ge 7 \\ 2, & K \ge 3 \\ 0, & K < 3 \end{cases}$$
Followed by ReLU activation ($\max(0, x)$) and saturation to 16-bit signed range $[0, 32767]$.
