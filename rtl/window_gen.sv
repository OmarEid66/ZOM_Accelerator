`timescale 1ns/1ps

module window_gen #(
    parameter int IMG_WIDTH    = 32,
    parameter int IMG_HEIGHT   = 32,
    parameter int PIXEL_WIDTH  = 8,
    parameter int KERNEL_SIZE  = 3,
    parameter bit IS_SYMMETRIC = 0,
    parameter int NUM_KERNELS  = 2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                                            pixel_valid, // new pixel_in present this cycle
    input  logic [PIXEL_WIDTH-1:0]                          pixel_in,    // raster-order pixel stream

    (* max_fanout = 8 *) output logic                      window_valid,
    output logic [(KERNEL_SIZE*KERNEL_SIZE*PIXEL_WIDTH)-1:0] window_flat_0,
    output logic [(KERNEL_SIZE*KERNEL_SIZE*PIXEL_WIDTH)-1:0] window_flat_1
);

    localparam bit DUAL_PATCH = (!IS_SYMMETRIC && NUM_KERNELS == 1);
    localparam int COL_DEPTH  = DUAL_PATCH ? (KERNEL_SIZE + 1) : KERNEL_SIZE;

    localparam int ROWCNT_W = $clog2(IMG_HEIGHT) + 1;
    localparam int COLCNT_W = $clog2(IMG_WIDTH)  + 1;

    // -------------------------------------------------------------------------
    // Raster Position Counters: tracks (row, col) of incoming pixel
    // -------------------------------------------------------------------------
    logic [ROWCNT_W-1:0] row_cnt;
    logic [COLCNT_W-1:0] col_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= '0;
            col_cnt <= '0;
        end else if (pixel_valid) begin
            if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= '0;
                if (row_cnt == IMG_HEIGHT - 1)
                    row_cnt <= '0;
                else
                    row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Line Buffers: (KERNEL_SIZE - 1) line buffers of depth IMG_WIDTH
    // -------------------------------------------------------------------------
    logic [PIXEL_WIDTH-1:0] row_pixels [0:KERNEL_SIZE-1];

    assign row_pixels[0] = pixel_in; // Row 0 is current incoming line

    if (KERNEL_SIZE > 1) begin : gen_line_buffers
        localparam int NUM_LB = KERNEL_SIZE - 1;
        logic [PIXEL_WIDTH-1:0] line_buf [0:NUM_LB-1][0:IMG_WIDTH-1];

        // Line Buffer 0: receives pixel_in
        always_ff @(posedge clk) begin
            if (pixel_valid) begin
                for (int i = IMG_WIDTH-1; i > 0; i--) line_buf[0][i] <= line_buf[0][i-1];
                line_buf[0][0] <= pixel_in;
            end
        end
        assign row_pixels[1] = line_buf[0][IMG_WIDTH-1];

        // Line Buffers 1 to NUM_LB-1: cascade from previous line buffer
        for (genvar lb = 1; lb < NUM_LB; lb++) begin : gen_cascade
            always_ff @(posedge clk) begin
                if (pixel_valid) begin
                    for (int i = IMG_WIDTH-1; i > 0; i--) line_buf[lb][i] <= line_buf[lb][i-1];
                    line_buf[lb][0] <= line_buf[lb-1][IMG_WIDTH-1];
                end
            end
            assign row_pixels[lb+1] = line_buf[lb][IMG_WIDTH-1];
        end
    end

    // -------------------------------------------------------------------------
    // Per-Row Column Shift Registers: depth COL_DEPTH
    // -------------------------------------------------------------------------
    logic [PIXEL_WIDTH-1:0] col_taps [0:KERNEL_SIZE-1][0:COL_DEPTH-1];

    for (genvar r = 0; r < KERNEL_SIZE; r++) begin : gen_col_shift
        always_ff @(posedge clk) begin
            if (pixel_valid) begin
                col_taps[r][0] <= row_pixels[r];
                for (int c = 1; c < COL_DEPTH; c++) begin
                    col_taps[r][c] <= col_taps[r][c-1];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Window Validity & Output Coordinates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_valid <= 1'b0;
        end else if (pixel_valid) begin
            if (DUAL_PATCH) begin
                // In dual-patch mode, both patches are valid when row >= K-1, col >= K, on odd columns
                window_valid <= (row_cnt >= KERNEL_SIZE - 1) && 
                                (col_cnt >= KERNEL_SIZE) && 
                                (col_cnt[0] == 1'b1);
            end else begin
                window_valid <= (row_cnt >= KERNEL_SIZE - 1) && (col_cnt >= KERNEL_SIZE - 1);
            end
        end else begin
            window_valid <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Flatten Window to Output Bus (p0 = top-left, p_{N^2-1} = bottom-right)
    // -------------------------------------------------------------------------
    always_comb begin
        for (int wr = 0; wr < KERNEL_SIZE; wr++) begin
            for (int wc = 0; wc < KERNEL_SIZE; wc++) begin
                int tap_idx;
                tap_idx = wr * KERNEL_SIZE + wc;
                if (DUAL_PATCH) begin
                    // Patch 0: Older window (Column c), uses columns [COL_DEPTH - 1 - wc]
                    window_flat_0[tap_idx*PIXEL_WIDTH +: PIXEL_WIDTH] =
                        col_taps[KERNEL_SIZE - 1 - wr][COL_DEPTH - 1 - wc];
                    // Patch 1: Newer window (Column c+1), uses columns [COL_DEPTH - 2 - wc]
                    window_flat_1[tap_idx*PIXEL_WIDTH +: PIXEL_WIDTH] =
                        col_taps[KERNEL_SIZE - 1 - wr][COL_DEPTH - 2 - wc];
                end else begin
                    window_flat_0[tap_idx*PIXEL_WIDTH +: PIXEL_WIDTH] =
                        col_taps[KERNEL_SIZE - 1 - wr][KERNEL_SIZE - 1 - wc];
                    window_flat_1[tap_idx*PIXEL_WIDTH +: PIXEL_WIDTH] = '0;
                end
            end
        end
    end

endmodule