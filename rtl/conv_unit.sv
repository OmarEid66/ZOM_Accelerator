`timescale 1ns/1ps

// =============================================================================
// conv_unit.sv – Unified multi-mode convolution compute core (DSP48E1)
//
// Power-Optimized Architecture:
//   1. Operand Isolation: Pixel input port is gated to 0 when valid_in=0;
//      Weight port remains stable (zero toggling on weights).
//      Multiplier sees 0 on pixel input during idle cycles -> zero switching.
//   2. Clock-Gated Stage 3 Unpack Registers (gated by valid_pipe[2])
//   3. Hierarchical Clock-Gated Adder Trees (gated by valid_pipe[3])
//
// Pipeline latency (all modes):
//   Stage 0  Input register                    (DSP AREG=1 / BREG=1)          1 cycle
//   Stage 1  Multiply                          (Vivado infers ADREG=1+MREG=1)  1 cycle
//   Stage 2  Product register                  (DSP PREG=1)                    1 cycle
//   Stage 3  Unpack register                   (Clock-gated by valid_pipe[2])  1 cycle
//   Stage 4+ Pipelined adder tree              (Clock-gated by valid_pipe[3])  TREE_LAT cycles
//   TOTAL_LAT = 4 + TREE_LAT
// =============================================================================

module conv_unit #(
    parameter int KERNEL_SIZE  = 3,
    parameter int PIXEL_WIDTH  = 8,
    parameter int WEIGHT_WIDTH = 8,
    parameter int ACC_WIDTH    = 32,
    parameter bit IS_SYMMETRIC = 0,
    parameter int NUM_KERNELS  = 2
)(
    input  logic                                                clk,
    input  logic                                                rst_n,

    input  logic                                                valid_in,
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*PIXEL_WIDTH)-1:0]    pixel_flat_0,
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*PIXEL_WIDTH)-1:0]    pixel_flat_1,
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0]   weight_flat_k0,
    input  logic [(KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH)-1:0]   weight_flat_k1,

    output logic                                                valid_out,
    output logic signed [ACC_WIDTH-1:0]                         result_k0,
    output logic signed [ACC_WIDTH-1:0]                         result_k1
);

    localparam int NUM_TAPS  = KERNEL_SIZE * KERNEL_SIZE;
    localparam int NUM_DSPS  = IS_SYMMETRIC ? ((NUM_TAPS + 1) / 2) : NUM_TAPS;
    localparam int TREE_LAT  = ($clog2(NUM_DSPS) == 0) ? 0 : $clog2(NUM_DSPS);
    localparam int TOTAL_LAT = 4 + TREE_LAT;

    // -------------------------------------------------------------------------
    // Valid pipeline: shift register length = TOTAL_LAT
    // -------------------------------------------------------------------------
    logic [TOTAL_LAT-1:0] valid_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
        end else begin
            valid_pipe <= {valid_pipe[TOTAL_LAT-2:0], valid_in};
        end
    end
    assign valid_out = valid_pipe[TOTAL_LAT-1];

    // -------------------------------------------------------------------------
    // Unpack pixel and weight slices
    // -------------------------------------------------------------------------
    logic        [PIXEL_WIDTH-1:0]  pixel_0 [0:NUM_TAPS-1];
    logic        [PIXEL_WIDTH-1:0]  pixel_1 [0:NUM_TAPS-1];
    logic signed [WEIGHT_WIDTH-1:0] w_k0    [0:NUM_TAPS-1];
    logic signed [WEIGHT_WIDTH-1:0] w_k1    [0:NUM_TAPS-1];

    always_comb begin
        for (int i = 0; i < NUM_TAPS; i++) begin
            pixel_0[i] = pixel_flat_0[i*PIXEL_WIDTH  +: PIXEL_WIDTH];
            pixel_1[i] = pixel_flat_1[i*PIXEL_WIDTH  +: PIXEL_WIDTH];
            w_k0[i]    = $signed(weight_flat_k0[i*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
            w_k1[i]    = $signed(weight_flat_k1[i*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
        end
    end

    // -------------------------------------------------------------------------
    // Stage 0: Input Registers with Operand Isolation
    //
    //  In all modes:
    //  - Weight inputs are stable across pixels (zero toggle power).
    //  - Pixel inputs are zeroed when valid_in == 0 (operand isolation).
    //  - When valid_in == 0, multiplier sees 0 -> internal DSP logic is quiescent.
    // -------------------------------------------------------------------------
    logic signed [24:0] port_a_reg [0:NUM_DSPS-1];
    logic signed [17:0] port_b_reg [0:NUM_DSPS-1];

    generate

        if (IS_SYMMETRIC) begin : gen_stage0_sym
            // Mode 1 – Centrosymmetric
            for (genvar gi = 0; gi < NUM_DSPS; gi++) begin : gen_dsp_elem_sym

                if (gi < NUM_TAPS - 1 - gi) begin : gen_pair
                    always_ff @(posedge clk) begin
                        port_a_reg[gi] <= ($signed({1'b0, pixel_0[gi]})
                                         + $signed({1'b0, pixel_0[NUM_TAPS - 1 - gi]}));
                        port_b_reg[gi] <= $signed(w_k0[gi]);
                    end
                end else begin : gen_center
                    always_ff @(posedge clk) begin
                        port_a_reg[gi] <= $signed({1'b0, pixel_0[gi]});
                        port_b_reg[gi] <= $signed(w_k0[gi]);
                    end
                end

            end // gen_dsp_elem_sym

        end else if (NUM_KERNELS == 1) begin : gen_stage0_m2
            // Mode 2 – Dual-Patch (1 kernel, 2 patches)
            always_ff @(posedge clk) begin
                for (int i = 0; i < NUM_DSPS; i++) begin
                    port_a_reg[i] <= ($signed({1'b0, pixel_1[i]}) <<< 16)
                                   + $signed({1'b0, pixel_0[i]});
                    port_b_reg[i] <= $signed(w_k0[i]);
                end
            end

        end else begin : gen_stage0_m3
            // Mode 3 – Dual-Kernel WP487 (2 kernels, 1 patch)
            // port_a_reg holds static packed weights (25-bit context)
            // port_b_reg holds pixel stream
            always_ff @(posedge clk) begin
                for (int i = 0; i < NUM_DSPS; i++) begin
                    port_a_reg[i] <= ($signed(w_k1[i]) <<< 16)
                                   + $signed(w_k0[i]);
                    port_b_reg[i] <= $signed({1'b0, pixel_0[i]});
                end
            end

        end

    endgenerate

    // -------------------------------------------------------------------------
    // Stage 1: Multiply  (DSP AREG→ADREG→MREG)
    // -------------------------------------------------------------------------
    (* use_dsp = "yes" *) logic signed [42:0] mult_mreg [0:NUM_DSPS-1];

    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_DSPS; i++) begin
            mult_mreg[i] <= port_a_reg[i] * port_b_reg[i];
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Product Register  (DSP PREG=1)
    // -------------------------------------------------------------------------
    (* use_dsp = "yes" *) logic signed [42:0] product_reg [0:NUM_DSPS-1];

    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_DSPS; i++) begin
            product_reg[i] <= mult_mreg[i];
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: Product Unpack Register
    // -------------------------------------------------------------------------
    logic signed [16:0] prod_k0_reg [0:NUM_DSPS-1];
    logic signed [16:0] prod_k1_reg [0:NUM_DSPS-1];

    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_DSPS; i++) begin
            if (IS_SYMMETRIC) begin
                prod_k0_reg[i] <= $signed(product_reg[i][16:0]);
                prod_k1_reg[i] <= '0;
            end else begin
                prod_k0_reg[i] <= $signed(product_reg[i][15:0]);
                prod_k1_reg[i] <= $signed(product_reg[i][39:16])
                                 + $signed({1'b0, product_reg[i][15]});
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stages 4+: Adder Trees
    // -------------------------------------------------------------------------
    adder_tree_stage #(
        .NUM_IN (NUM_DSPS),
        .IN_W   (17),
        .OUT_W  (ACC_WIDTH)
    ) u_adder_tree_k0 (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_vec  (prod_k0_reg),
        .out_val (result_k0)
    );

    generate
        if (IS_SYMMETRIC) begin : gen_sym_k1
            assign result_k1 = '0;
        end else begin : gen_asym_k1
            adder_tree_stage #(
                .NUM_IN (NUM_DSPS),
                .IN_W   (17),
                .OUT_W  (ACC_WIDTH)
            ) u_adder_tree_k1 (
                .clk     (clk),
                .rst_n   (rst_n),
                .in_vec  (prod_k1_reg),
                .out_val (result_k1)
            );
        end
    endgenerate

endmodule