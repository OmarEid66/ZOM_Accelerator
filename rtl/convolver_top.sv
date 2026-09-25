`timescale 1ns/1ps

module convolver_top #(
    // Mode Parameter:
    //   1: Centrosymmetric (1 symmetrical kernel, 1 patch)
    //   2: Asymmetric Dual-Patch (1 asymmetrical kernel, 2 spatial patches)
    //   3: Asymmetric Dual-Kernel (2 asymmetrical kernels, 1 spatial patch)
    parameter int MODE         = 2,

    parameter int IMG_SIZE     = 32,
    parameter int IMG_WIDTH    = IMG_SIZE,
    parameter int IMG_HEIGHT   = IMG_SIZE,
    parameter int PIXEL_WIDTH  = 8,
    parameter int WEIGHT_WIDTH = 8,
    parameter int ACC_WIDTH    = 32,
    parameter int OUT_WIDTH    = 16,
    parameter int KERNEL_SIZE  = 3,

    // Internal derived architectural localparams
    localparam bit IS_SYMMETRIC  = (MODE == 1) ? 1'b1 : 1'b0,
    localparam int NUM_KERNELS   = (MODE == 3) ? 2 : 1,
    localparam int NUM_TAPS      = KERNEL_SIZE * KERNEL_SIZE,
    localparam int TOTAL_WEIGHTS = NUM_KERNELS * NUM_TAPS
)(
    input  logic clk,
    input  logic rst_n,

    // Accelerator Control
    input  logic start,
    output logic busy,
    output logic done,

    // Direct Pixel Streaming Input (100% BRAM-Free)
    input  logic                                            pixel_valid_in,
    input  logic [PIXEL_WIDTH-1:0]                          pixel_in,

    // Kernel Configuration Interface
    input  logic                                            kernel_wr_en,
    input  logic [(TOTAL_WEIGHTS > 1 ? $clog2(TOTAL_WEIGHTS)-1 : 0):0] kernel_wr_addr,
    input  logic signed [WEIGHT_WIDTH-1:0]                  kernel_wr_data,

    // Streaming Output Interface
    output logic                                            out_valid,
    output logic signed [OUT_WIDTH-1:0]                     out_pixel_k0,
    output logic signed [OUT_WIDTH-1:0]                     out_pixel_k1,
    output logic                                            out_last,
    output logic [(NUM_KERNELS > 1 ? $clog2(NUM_KERNELS) : 0):0] out_kernel_idx
);

    localparam int OUT_W          = IMG_WIDTH  - KERNEL_SIZE + 1;
    localparam int OUT_H          = IMG_HEIGHT - KERNEL_SIZE + 1;
    localparam int OUT_PIXELS     = OUT_W * OUT_H;
    localparam int TOTAL_OUT      = NUM_KERNELS * OUT_PIXELS;

    localparam int OUTADDR_W      = (OUT_PIXELS > 1) ? $clog2(OUT_PIXELS) : 1;
    localparam int KERNEL_CNT_W   = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) + 1 : 1;
    localparam int TOTAL_OUT_W    = (TOTAL_OUT > 1) ? $clog2(TOTAL_OUT) : 1;
    localparam int KERNEL_STEP    = (IS_SYMMETRIC || NUM_KERNELS == 1) ? 1 : 2;

    // --- CU Status & Control Signals ---
    logic [(NUM_KERNELS > 1 ? $clog2(NUM_KERNELS) : 0):0] cu_kernel_idx;
    logic                                                  cu_kernel_valid_k1;
    logic                                                  cu_last_pixel;
    logic                                                  dp_rst_n;

    // --- Pipelined Streaming Inputs to Datapath ---
    logic                                              dp_pixel_valid_in;
    logic [PIXEL_WIDTH-1:0]                            dp_pixel_in;
    logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0] dp_weight_flat_k0_in;
    logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0] dp_weight_flat_k1_in;
    
    // --- Datapath Outputs ---
    logic                                              dp_pixel_valid_out;
    logic signed [OUT_WIDTH-1:0]                       dp_pixel_out_k0;
    logic signed [OUT_WIDTH-1:0]                       dp_pixel_out_k1;

    // Input boundary registers: isolate external I/O delays for 280 MHz timing closure
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dp_pixel_valid_in <= 1'b0;
            dp_pixel_in       <= '0;
        end else begin
            dp_pixel_valid_in <= pixel_valid_in;
            dp_pixel_in       <= pixel_in;
        end
    end

    // -------------------------------------------------------------------------
    // Dedicated Kernel Memory Module Instantiation (Requirement 2 & 3)
    // Instantiates registers for a single kernel in Modes 1 & 2, and 2 in Mode 3
    // -------------------------------------------------------------------------
    kernel_mem #(
        .KERNEL_SIZE (KERNEL_SIZE),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .NUM_KERNELS (NUM_KERNELS),
        .IS_SYMMETRIC(IS_SYMMETRIC)
    ) u_kernel_mem (
        .clk                (clk),
        .rst_n              (rst_n),
        .kernel_wr_en       (kernel_wr_en),
        .kernel_wr_addr     (kernel_wr_addr),
        .kernel_wr_data     (kernel_wr_data),
        .cu_kernel_idx      (cu_kernel_idx),
        .cu_kernel_valid_k1 (cu_kernel_valid_k1),
        .weight_flat_k0_out (dp_weight_flat_k0_in),
        .weight_flat_k1_out (dp_weight_flat_k1_in)
    );

    // Direct Registered Streaming Output with Power Clock Gating
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid      <= 1'b0;
            out_pixel_k0   <= '0;
            out_pixel_k1   <= '0;
            out_last       <= 1'b0;
            out_kernel_idx <= '0;
        end else begin
            out_valid <= dp_pixel_valid_out;
            if (dp_pixel_valid_out) begin
                out_pixel_k0   <= dp_pixel_out_k0;
                out_pixel_k1   <= (cu_kernel_valid_k1 && !IS_SYMMETRIC) ? dp_pixel_out_k1 : '0;
                out_last       <= cu_last_pixel && (cu_kernel_idx + KERNEL_STEP >= NUM_KERNELS);
                out_kernel_idx <= cu_kernel_idx;
            end else begin
                out_last <= 1'b0;
            end
        end
    end

    // Control Unit Instance
    convolver_cu #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .NUM_KERNELS  (NUM_KERNELS),
        .IS_SYMMETRIC (IS_SYMMETRIC)
    ) u_cu (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        
        .kernel_idx_out     (cu_kernel_idx),
        .kernel_valid_k1    (cu_kernel_valid_k1),
        .last_pixel_out     (cu_last_pixel),
        
        .dp_rst_n           (dp_rst_n),
        .dp_pixel_valid_out (dp_pixel_valid_out)
    );

    // Convolution Datapath Instance
    conv_datapath #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .IS_SYMMETRIC (IS_SYMMETRIC),
        .NUM_KERNELS  (NUM_KERNELS)
    ) u_dp (
        .clk               (clk),
        .rst_n             (dp_rst_n), 
        .pixel_valid_in    (dp_pixel_valid_in),
        .pixel_in          (dp_pixel_in),
        .weight_flat_k0_in (dp_weight_flat_k0_in),
        .weight_flat_k1_in (dp_weight_flat_k1_in),
        .pixel_valid_out   (dp_pixel_valid_out),
        .pixel_out_k0      (dp_pixel_out_k0),
        .pixel_out_k1      (dp_pixel_out_k1)
    );

endmodule