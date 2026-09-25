`timescale 1ns/1ps

module convolver_cu #(
    parameter int IMG_WIDTH    = 32,
    parameter int IMG_HEIGHT   = 32,
    parameter int PIXEL_WIDTH  = 8,
    parameter int WEIGHT_WIDTH = 8,
    parameter int OUT_WIDTH    = 16,
    parameter int KERNEL_SIZE  = 3,
    parameter int NUM_KERNELS  = 2,
    parameter bit IS_SYMMETRIC = 0
)(
    input  logic clk,
    input  logic rst_n,

    // External Interface
    input  logic start,
    output logic busy,
    output logic done,

    output logic [(NUM_KERNELS > 1 ? $clog2(NUM_KERNELS) : 0):0] kernel_idx_out,
    output logic                                            kernel_valid_k1,
    output logic                                            last_pixel_out,

    // Interface to Datapath
    output logic                                            dp_rst_n,
    input  logic                                            dp_pixel_valid_out
);

    localparam int NUM_TAPS         = KERNEL_SIZE * KERNEL_SIZE;
    localparam int TOTAL_WEIGHTS    = NUM_KERNELS * NUM_TAPS;
    localparam int OUT_W            = IMG_WIDTH  - KERNEL_SIZE + 1;
    localparam int OUT_H            = IMG_HEIGHT - KERNEL_SIZE + 1;
    localparam int OUT_PIXELS       = OUT_W * OUT_H;
    localparam int TOTAL_OUT_CYCLES = (!IS_SYMMETRIC && NUM_KERNELS == 1) ? (OUT_PIXELS / 2) : OUT_PIXELS;
    localparam int OUTADDR_W        = (TOTAL_OUT_CYCLES > 1) ? $clog2(TOTAL_OUT_CYCLES) : 1;
    localparam int KERNEL_CNT_W     = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) + 1 : 1;
    localparam int KERNEL_STEP      = (IS_SYMMETRIC || NUM_KERNELS == 1) ? 1 : 2;

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_NEXT_K, S_DONE} state_t;
    state_t state;

    logic [KERNEL_CNT_W-1:0] kernel_idx;

    localparam int OUT_LOW_W   = (OUTADDR_W >= 6) ? 6 : OUTADDR_W;
    localparam int OUT_HIGH_W  = (OUTADDR_W + 1 > OUT_LOW_W) ? (OUTADDR_W + 1 - OUT_LOW_W) : 1;
    logic [OUT_LOW_W-1:0]  out_count_low;
    logic [OUT_HIGH_W-1:0] out_count_high;
    logic [OUTADDR_W:0]    out_count;

    assign out_count = {out_count_high, out_count_low};

    assign kernel_idx_out  = kernel_idx;
    // In dual-patch mode, k1 channel carries the second patch (valid); in symmetric mode, only k0 channel is used
    assign kernel_valid_k1 = IS_SYMMETRIC ? 1'b0 : (NUM_KERNELS == 1 ? 1'b1 : (kernel_idx + 1 < NUM_KERNELS));
    assign busy            = (state != S_IDLE);
    assign done            = (state == S_DONE);
    
    // Clear internal state of datapath between kernel passes
    assign dp_rst_n        = rst_n && (state != S_NEXT_K);

    // Look-ahead registered flag for terminal pixel count (optimizes 280 MHz timing)
    logic last_pixel_reg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_pixel_reg <= 1'b0;
        end else if (state == S_IDLE || state == S_NEXT_K) begin
            last_pixel_reg <= (TOTAL_OUT_CYCLES <= 1);
        end else if (dp_pixel_valid_out) begin
            last_pixel_reg <= (out_count == OUTADDR_W'(TOTAL_OUT_CYCLES - 2));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            kernel_idx     <= '0;
            out_count_low  <= '0;
            out_count_high <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    kernel_idx     <= '0;
                    out_count_low  <= '0;
                    out_count_high <= '0;
                    if (start) begin
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (dp_pixel_valid_out) begin
                        out_count_low <= out_count_low + 1'b1;
                        if (out_count_low == {OUT_LOW_W{1'b1}}) begin
                            out_count_high <= out_count_high + 1'b1;
                        end
                        if (last_pixel_reg) begin
                            // Check if all kernels have finished
                            if (kernel_idx + KERNEL_STEP >= NUM_KERNELS) begin
                                state <= S_DONE;
                            end else begin
                                state <= S_NEXT_K;
                            end
                        end
                    end
                end

                S_NEXT_K: begin
                    // Advance to next kernel(s)
                    kernel_idx     <= kernel_idx + KERNEL_STEP;
                    out_count_low  <= '0;
                    out_count_high <= '0;
                    state          <= S_RUN;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign last_pixel_out = last_pixel_reg;

endmodule