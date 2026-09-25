`timescale 1ns/1ps

module conv_datapath #(
    parameter int IMG_WIDTH    = 32,
    parameter int IMG_HEIGHT   = 32,
    parameter int PIXEL_WIDTH  = 8,
    parameter int WEIGHT_WIDTH = 8,
    parameter int ACC_WIDTH    = 32,
    parameter int OUT_WIDTH    = 16,
    parameter int KERNEL_SIZE  = 3,
    parameter bit IS_SYMMETRIC = 0,
    parameter int NUM_KERNELS  = 2
)(
    input  logic                                              clk,
    input  logic                                              rst_n,

    // Stream inputs
    input  logic                                              pixel_valid_in,
    input  logic [PIXEL_WIDTH-1:0]                            pixel_in,
    
    // Weight inputs for both parallel kernels
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0] weight_flat_k0_in,
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0] weight_flat_k1_in,

    // Stream outputs for both parallel channels
    output logic                                              pixel_valid_out,
    output logic signed [OUT_WIDTH-1:0]                       pixel_out_k0,
    output logic signed [OUT_WIDTH-1:0]                       pixel_out_k1
);

    localparam int NUM_TAPS = KERNEL_SIZE * KERNEL_SIZE;

    // Internal Signals
    logic                              wg_valid;
    logic [(NUM_TAPS*PIXEL_WIDTH)-1:0] wg_flat_0;
    logic [(NUM_TAPS*PIXEL_WIDTH)-1:0] wg_flat_1;
    
    logic                              conv_valid;
    logic signed [ACC_WIDTH-1:0]       conv_result_k0;
    logic signed [ACC_WIDTH-1:0]       conv_result_k1;
    
    logic signed [ACC_WIDTH-1:0]       conv_result_k0_trunc;
    logic signed [ACC_WIDTH-1:0]       conv_result_k1_trunc;
    
    logic signed [OUT_WIDTH-1:0]       sat_comb_k0;
    logic signed [OUT_WIDTH-1:0]       sat_comb_k1;
    
    logic signed [OUT_WIDTH-1:0]       relu_comb_k0;
    logic signed [OUT_WIDTH-1:0]       relu_comb_k1;

    // Truncation bit calculation based on Kernel Size
    function automatic int get_trunc_bits(int k_size);
        case (k_size)
            9: return 3;
            7: return 3;
            5: return 2;
            3: return 2;
            1: return 0;
            default: return (k_size >= 7) ? 3 : ((k_size >= 3) ? 2 : 0);
        endcase
    endfunction

    localparam int TRUNC_BITS = get_trunc_bits(KERNEL_SIZE);

    // -------------------------------------------------------------------------
    // 1. Sliding Window Generator
    // -------------------------------------------------------------------------
    window_gen #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .IS_SYMMETRIC (IS_SYMMETRIC),
        .NUM_KERNELS  (NUM_KERNELS)
    ) u_window_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .pixel_valid   (pixel_valid_in),
        .pixel_in      (pixel_in),
        .window_valid  (wg_valid),
        .window_flat_0 (wg_flat_0),
        .window_flat_1 (wg_flat_1)
    );

    // -------------------------------------------------------------------------
    // 2. Multi-Mode DSP48E1 Pre-Adder Convolution Processing Core
    // -------------------------------------------------------------------------
    conv_unit #(
        .KERNEL_SIZE  (KERNEL_SIZE),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .IS_SYMMETRIC (IS_SYMMETRIC),
        .NUM_KERNELS  (NUM_KERNELS)
    ) u_conv (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (wg_valid),
        .pixel_flat_0   (wg_flat_0),
        .pixel_flat_1   (wg_flat_1),
        .weight_flat_k0 (weight_flat_k0_in),
        .weight_flat_k1 (weight_flat_k1_in),
        .valid_out      (conv_valid),
        .result_k0      (conv_result_k0),
        .result_k1      (conv_result_k1)
    );

    // -------------------------------------------------------------------------
    // 3. Right-Shift Truncation
    // -------------------------------------------------------------------------
    assign conv_result_k0_trunc = conv_result_k0 >>> TRUNC_BITS;
    assign conv_result_k1_trunc = conv_result_k1 >>> TRUNC_BITS;

    // -------------------------------------------------------------------------
    // 4. Saturate to target output width (usually 32 to 16)
    // -------------------------------------------------------------------------
    saturate #(
        .ACC_WIDTH (ACC_WIDTH),
        .OUT_WIDTH (OUT_WIDTH)
    ) u_sat_k0 (
        .acc_in  (conv_result_k0_trunc),
        .sat_out (sat_comb_k0)
    );

    saturate #(
        .ACC_WIDTH (ACC_WIDTH),
        .OUT_WIDTH (OUT_WIDTH)
    ) u_sat_k1 (
        .acc_in  (conv_result_k1_trunc),
        .sat_out (sat_comb_k1)
    );

    // -------------------------------------------------------------------------
    // 5. ReLU Activation (Clamps negatives to zero)
    // -------------------------------------------------------------------------
    assign relu_comb_k0 = (sat_comb_k0 < 0) ? '0 : sat_comb_k0;
    assign relu_comb_k1 = (sat_comb_k1 < 0) ? '0 : sat_comb_k1;

    // -------------------------------------------------------------------------
    // 6. Registered Output
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_valid_out <= 1'b0;
            pixel_out_k0    <= '0;
            pixel_out_k1    <= '0;
        end else begin
            pixel_valid_out <= conv_valid;
            if (conv_valid) begin
                pixel_out_k0 <= relu_comb_k0;
                pixel_out_k1 <= (IS_SYMMETRIC ? '0 : relu_comb_k1);
            end
        end
    end

endmodule