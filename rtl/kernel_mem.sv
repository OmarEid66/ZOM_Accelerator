// =============================================================================
// kernel_mem.sv
//
// Dedicated Kernel Memory / Register File for convolver_top
//
// Features:
//   - Sized for exactly NUM_KERNELS (depth 1 for Mode 1 & 2; depth 2 for Mode 3)
//   - Elaboration-time constant address decoder (no divider/modulus units)
//   - High-speed registered weight outputs fed into DSP48 slices
// =============================================================================
`timescale 1ns/1ps

module kernel_mem #(
    parameter int KERNEL_SIZE  = 3,
    parameter int WEIGHT_WIDTH = 8,
    parameter int NUM_KERNELS  = 1,
    parameter bit IS_SYMMETRIC = 0
)(
    input  logic                                                              clk,
    input  logic                                                              rst_n,

    // Write Interface
    input  logic                                                              kernel_wr_en,
    input  logic [((NUM_KERNELS*KERNEL_SIZE*KERNEL_SIZE) > 1 ? $clog2(NUM_KERNELS*KERNEL_SIZE*KERNEL_SIZE)-1 : 0):0] kernel_wr_addr,
    input  logic signed [WEIGHT_WIDTH-1:0]                                    kernel_wr_data,

    // Read / Control Interface from CU
    input  logic [(NUM_KERNELS > 1 ? $clog2(NUM_KERNELS) : 0):0]             cu_kernel_idx,
    input  logic                                                              cu_kernel_valid_k1,

    // High-speed registered weight outputs to Datapath
    output logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0]                weight_flat_k0_out,
    output logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0]                weight_flat_k1_out
);

    localparam int NUM_TAPS          = KERNEL_SIZE * KERNEL_SIZE;
    localparam int TOTAL_WEIGHTS     = NUM_KERNELS * NUM_TAPS;
    localparam int KERNEL_REG_DEPTH  = NUM_KERNELS; // Exactly 1 for Mode 1 & 2, 2 for Mode 3

    // Kernel Storage Registers (Instantiated for a single kernel when NUM_KERNELS == 1)
    logic signed [WEIGHT_WIDTH-1:0] kernel_reg [0:KERNEL_REG_DEPTH-1][0:NUM_TAPS-1];

    // -------------------------------------------------------------------------
    // Kernel Weight Loading Interface
    // Direct decoder: elaboration-time mapping, zero hardware divider/mod units
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < KERNEL_REG_DEPTH; k++) begin
                for (int t = 0; t < NUM_TAPS; t++) begin
                    kernel_reg[k][t] <= '0;
                end
            end
        end else if (kernel_wr_en) begin
            for (int k = 0; k < KERNEL_REG_DEPTH; k++) begin
                for (int t = 0; t < NUM_TAPS; t++) begin
                    if (kernel_wr_addr == (k * NUM_TAPS + t)) begin
                        kernel_reg[k][t] <= kernel_wr_data;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // High-speed Registered Active Weights directly fed to Datapath DSP slices
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_flat_k0_out <= '0;
            weight_flat_k1_out <= '0;
        end else begin
            for (int t = 0; t < NUM_TAPS; t++) begin
                // Kernel 0 readout (used in all modes)
                weight_flat_k0_out[t*WEIGHT_WIDTH +: WEIGHT_WIDTH] <= kernel_reg[cu_kernel_idx][t];

                // Kernel 1 readout (only active when NUM_KERNELS > 1 and !IS_SYMMETRIC)
                if (NUM_KERNELS > 1 && !IS_SYMMETRIC && cu_kernel_valid_k1) begin
                    weight_flat_k1_out[t*WEIGHT_WIDTH +: WEIGHT_WIDTH] <= kernel_reg[cu_kernel_idx + 1][t];
                end else begin
                    weight_flat_k1_out[t*WEIGHT_WIDTH +: WEIGHT_WIDTH] <= '0;
                end
            end
        end
    end

endmodule
