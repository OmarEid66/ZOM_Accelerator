`timescale 1ns/1ps

module tb_convolver_cu;

    // -------------------------------------------------------------------------
    // Testbench Parameters
    // Use a small image size to keep simulation trace short and readable
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD   = 10;
    localparam int IMG_WIDTH    = 8;
    localparam int IMG_HEIGHT   = 8;
    localparam int PIXEL_WIDTH  = 8;
    localparam int WEIGHT_WIDTH = 8;
    localparam int OUT_WIDTH    = 16;
    localparam int KERNEL_SIZE  = 3;
    localparam int NUM_KERNELS  = 2; // Test multi-kernel sequencing

    localparam int NUM_TAPS     = KERNEL_SIZE * KERNEL_SIZE;
    localparam int IMG_PIXELS   = IMG_WIDTH * IMG_HEIGHT;
    localparam int OUT_W        = IMG_WIDTH - KERNEL_SIZE + 1;
    localparam int OUT_H        = IMG_HEIGHT - KERNEL_SIZE + 1;
    localparam int OUT_PIXELS   = OUT_W * OUT_H;
    localparam int TOTAL_OUT    = NUM_KERNELS * OUT_PIXELS;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    // External Interface
    logic start;
    logic busy;
    logic done;

    // Memory Interfaces
    logic [$clog2(IMG_PIXELS)-1:0]    img_rd_addr;
    logic [PIXEL_WIDTH-1:0]           img_rd_data;
    
    // kernel_rd_addr width logic duplicated from CU
    localparam int KERNEL_ADDR_W = (NUM_KERNELS*NUM_TAPS > 1) ? $clog2(NUM_KERNELS*NUM_TAPS) : 1;
    logic [KERNEL_ADDR_W-1:0]         kernel_rd_addr;
    
    logic                             out_wr_en;
    localparam int OUT_ADDR_W = (TOTAL_OUT > 1) ? $clog2(TOTAL_OUT) : 1;
    logic [OUT_ADDR_W-1:0]            out_wr_addr;

    // Datapath Interface
    logic                             dp_rst_n;
    logic                             dp_pixel_valid_in;
    logic [PIXEL_WIDTH-1:0]           dp_pixel_in;
    logic                             dp_pixel_valid_out;

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Mock Image Memory
    // -------------------------------------------------------------------------
    logic [PIXEL_WIDTH-1:0] img_mem [0:IMG_PIXELS-1];
    
    initial begin
        for (int i = 0; i < IMG_PIXELS; i++) begin
            img_mem[i] = i; // Fill with simple sequential data
        end
    end

    // Simulated 1-cycle SRAM read latency (combinational read, registered in CU)
    assign img_rd_data = img_mem[img_rd_addr];

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    convolver_cu #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .NUM_KERNELS  (NUM_KERNELS)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .img_rd_addr        (img_rd_addr),
        .img_rd_data        (img_rd_data),
        .kernel_rd_addr     (kernel_rd_addr),
        .out_wr_en          (out_wr_en),
        .out_wr_addr        (out_wr_addr),
        .dp_rst_n           (dp_rst_n),
        .dp_pixel_valid_in  (dp_pixel_valid_in),
        .dp_pixel_in        (dp_pixel_in),
        .dp_pixel_valid_out (dp_pixel_valid_out)
    );

    // -------------------------------------------------------------------------
    // Mock Datapath Valid-Signal Generator
    // Replicates sliding-window spatial valid conditions + pipeline delay
    // -------------------------------------------------------------------------
    logic [$clog2(IMG_WIDTH):0]  dp_col_cnt;
    logic [$clog2(IMG_HEIGHT):0] dp_row_cnt;
    logic                        dp_window_valid;
    logic [4:0]                  dp_valid_pipe; // Simulates conv core pipeline depth

    always_ff @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            dp_col_cnt      <= '0;
            dp_row_cnt      <= '0;
            dp_window_valid <= 1'b0;
        end else if (dp_pixel_valid_in) begin
            if (dp_col_cnt == IMG_WIDTH - 1) begin
                dp_col_cnt <= '0;
                dp_row_cnt <= dp_row_cnt + 1'b1;
            end else begin
                dp_col_cnt <= dp_col_cnt + 1'b1;
            end
            
            // Valid only when window is fully populated
            dp_window_valid <= (dp_row_cnt >= KERNEL_SIZE - 1) && (dp_col_cnt >= KERNEL_SIZE - 1);
        end else begin
            dp_window_valid <= 1'b0;
        end
    end

    // Pipeline the valid signal to mimic convolution latency
    always_ff @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            dp_valid_pipe <= '0;
        end else begin
            dp_valid_pipe <= {dp_valid_pipe[3:0], dp_window_valid};
        end
    end

    assign dp_pixel_valid_out = dp_valid_pipe[4];

    // -------------------------------------------------------------------------
    // Output Verification Monitors
    // -------------------------------------------------------------------------
    int total_writes_captured = 0;
    int expected_addr = 0;
    int error_cnt = 0;

    always_ff @(posedge clk) begin
        if (out_wr_en) begin
            total_writes_captured++;
            
            // Verify write address increments strictly sequentially
            if (out_wr_addr !== expected_addr) begin
                $error("Time %0t | WRITE ADDR MISMATCH! Expected %0d, Got %0d", $time, expected_addr, out_wr_addr);
                error_cnt++;
            end
            expected_addr++;
        end
    end

    // -------------------------------------------------------------------------
    // Main Stimulus Sequence
    // -------------------------------------------------------------------------
    initial begin
        // Reset Setup
        rst_n = 0;
        start = 0;

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("===============================================================");
        $display("STARTING CONVOLVER_CU VALIDATION");
        $display("Expected Writes per Kernel: %0d", OUT_PIXELS);
        $display("Total Expected Writes     : %0d", TOTAL_OUT);
        $display("===============================================================");

        // Trigger FSM
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        // Check if FSM asserted busy
        if (!busy) begin
            $error("Time %0t | FSM failed to assert 'busy' after start!", $time);
            error_cnt++;
        end

        // Wait for first kernel pass to complete
        wait (kernel_rd_addr == NUM_TAPS);
        $display("Time %0t | Successfully switched to Kernel 1. (kernel_rd_addr = %0d)", $time, kernel_rd_addr);
        
        if (dp_rst_n !== 1'b0) begin
             $error("Time %0t | Datapath reset (dp_rst_n) was not asserted during kernel switch!", $time);
             error_cnt++;
        end

        // Wait for FSM to assert done
        wait (done == 1'b1);
        $display("Time %0t | FSM asserted 'done'.", $time);

        if (busy) begin
            $error("Time %0t | FSM is still 'busy' while 'done' is asserted!", $time);
            error_cnt++;
        end

        // Final verification of write counts
        if (total_writes_captured !== TOTAL_OUT) begin
            $error("Total writes mismatch! Expected %0d, Captured %0d", TOTAL_OUT, total_writes_captured);
            error_cnt++;
        end else begin
            $display("Total writes matched expected (%0d).", TOTAL_OUT);
        end

        #(CLK_PERIOD * 5);

        $display("===============================================================");
        $display("SIMULATION COMPLETE");
        $display("Errors Found: %0d", error_cnt);
        if (error_cnt == 0) $display(">>> OVERALL STATUS: [ SUCCESS ] <<<");
        else                $display(">>> OVERALL STATUS: [ FAILURE ] <<<");
        $display("===============================================================");
        
        $finish;
    end

endmodule