`timescale 1ns/1ps

module tb_conv_datapath;

    //    // -------------------------------------------------------------------------
    // Testbench Parameters
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD   = 10;
    localparam int IMG_WIDTH    = 16; // 16x16 is large enough to test horizontal blanking
    localparam int IMG_HEIGHT   = 16;
    localparam int PIXEL_WIDTH  = 8;
    localparam int WEIGHT_WIDTH = 8;
    localparam int ACC_WIDTH    = 32;
    localparam int OUT_WIDTH    = 16;
    localparam int KERNEL_SIZE  = 3;

    localparam int NUM_TAPS     = KERNEL_SIZE * KERNEL_SIZE;
    localparam int NUM_MULTS    = (NUM_TAPS + 1) / 2;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic                                              clk;
    logic                                              rst_n;

    logic                                              pixel_valid_in;
    logic [PIXEL_WIDTH-1:0]                            pixel_in;
    logic [(NUM_TAPS*WEIGHT_WIDTH)-1:0]                weight_flat_in;

    logic                                              pixel_valid_out;
    logic signed [OUT_WIDTH-1:0]                       pixel_out;

    // Testbench storage variables
    logic [PIXEL_WIDTH-1:0]           img    [0:IMG_HEIGHT-1][0:IMG_WIDTH-1];
    logic signed [WEIGHT_WIDTH-1:0]   kernel [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

    int expected_q[$];
    int pass_cnt = 0;
    int fail_cnt = 0;

    //    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    conv_datapath #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .KERNEL_SIZE  (KERNEL_SIZE)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .pixel_valid_in  (pixel_valid_in),
        .pixel_in        (pixel_in),
        .weight_flat_in  (weight_flat_in),
        .pixel_valid_out (pixel_valid_out),
        .pixel_out       (pixel_out)
    );

    //    // -------------------------------------------------------------------------
    // Golden Reference Model
    // Calculates the mathematically exact expected outputs for the full stream.
    // Models the hardware's symmetric fold, right-shift, saturation, and ReLU.
    // -------------------------------------------------------------------------
    function automatic void calc_expected();
        // Number of valid convolution windows inside the image bounds
        int valid_rows = IMG_HEIGHT - KERNEL_SIZE + 1;
        int valid_cols = IMG_WIDTH - KERNEL_SIZE + 1;

        for (int r = 0; r < valid_rows; r++) begin
            for (int c = 0; c < valid_cols; c++) begin
                logic signed [31:0] acc = 0;
                int p[9];
                int w[9];

                // Extract current sliding window and flatten to 1D arrays
                for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
                    for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                        int idx = kr * KERNEL_SIZE + kc;
                        p[idx] = img[r+kr][c+kc];
                        w[idx] = kernel[kr][kc];
                    end
                end

                // Mimic the DSP48 pre-adder folding logic inside `conv_unit`
                // P_out = sum( (p[i] + p[N-1-i]) * w[i] ) for i < N/2
                for (int i = 0; i < NUM_MULTS; i++) begin
                    if (i < NUM_TAPS / 2) begin
                        acc += (p[i] + p[NUM_TAPS-1-i]) * w[i];
                    end else begin
                        acc += p[i] * w[i]; // Center Tap
                    end
                end

                // 3. Truncation (Right Shift by 2 for KERNEL_SIZE=3)
                acc = acc >>> 2; 

                // 4. Saturation to OUT_WIDTH (16 bits)
                if (acc > 32767)       acc = 32767;
                else if (acc < -32768) acc = -32768;

                // 5. ReLU (Clamp negatives to zero)
                if (acc < 0) acc = 0;

                expected_q.push_back(acc);
            end
        end
    endfunction

    //    // -------------------------------------------------------------------------
    // Stream injection and pipeline synchronization
    // -------------------------------------------------------------------------
    task automatic run_image_pass(string pass_name);
        $display("---------------------------------------------------------------");
        $display("Starting Convolution Pass: %s", pass_name);
        $display("---------------------------------------------------------------");

        // Prepare expected queue
        expected_q.delete();
        calc_expected();

        // Flush/Load Kernel into Flattened Vector
        for (int r = 0; r < KERNEL_SIZE; r++) begin
            for (int c = 0; c < KERNEL_SIZE; c++) begin
                int idx = r * KERNEL_SIZE + c;
                weight_flat_in[idx*WEIGHT_WIDTH +: WEIGHT_WIDTH] = kernel[r][c];
            end
        end

        // Stream the entire image matrix in raster-scan order
        for (int r = 0; r < IMG_HEIGHT; r++) begin
            for (int c = 0; c < IMG_WIDTH; c++) begin
                @(negedge clk);
                pixel_valid_in = 1'b1;
                pixel_in       = img[r][c];
            end
        end
        
        // De-assert data bus
        @(negedge clk);
        pixel_valid_in = 1'b0;
        pixel_in       = '0;

        // Await pipeline flush (Wait for expected queue to empty safely)
        fork
            begin
                wait(expected_q.size() == 0);
                #(CLK_PERIOD * 5); // Pad slightly
            end
            begin
                #(CLK_PERIOD * (IMG_WIDTH * KERNEL_SIZE + 50)); 
                $error("Timeout! Pipeline stalled. Missing %0d items.", expected_q.size());
            end
        join_any
        disable fork; // Kill the timeout if cleanly finished
        
    endtask

    //    // -------------------------------------------------------------------------
    // Main execution sequence
    // -------------------------------------------------------------------------
    initial begin
        // Reset Setup
        rst_n          = 0;
        pixel_valid_in = 0;
        pixel_in       = '0;
        weight_flat_in = '0;

        // Initialize Image with random synthetic data
        for (int r = 0; r < IMG_HEIGHT; r++) begin
            for (int c = 0; c < IMG_WIDTH; c++) begin
                img[r][c] = $urandom_range(0, 255);
            end
        end

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);
        
        $display("===============================================================");
        $display("STARTING CONV_DATAPATH TOP-LEVEL VALIDATION");
        $display("===============================================================");

        // ------------------------------------------------------
        // Test 1: Symmetric Edge Detection Kernel
        // Tests the ReLU behavior (forces lots of large negative sums)
        // ------------------------------------------------------
        kernel[0][0] = -1; kernel[0][1] = -1; kernel[0][2] = -1;
        kernel[1][0] = -1; kernel[1][1] =  8; kernel[1][2] = -1;
        kernel[2][0] = -1; kernel[2][1] = -1; kernel[2][2] = -1;
        run_image_pass("Symmetric Edge Detector");

        // ------------------------------------------------------
        // Test 2: Identity Passthrough Kernel
        // Tests pure non-clamped positive accumulations
        // (Uses a weight of 4 to cancel out the >> 2 hardware shift)
        // ------------------------------------------------------
        kernel[0][0] = 0; kernel[0][1] = 0; kernel[0][2] = 0;
        kernel[1][0] = 0; kernel[1][1] = 4; kernel[1][2] = 0;
        kernel[2][0] = 0; kernel[2][1] = 0; kernel[2][2] = 0;
        run_image_pass("Shift-Corrected Identity");
        
        $display("===============================================================");
        $display("SIMULATION COMPLETE");
        $display("Pixels Passed : %0d", pass_cnt);
        $display("Pixels Failed : %0d", fail_cnt);
        if (fail_cnt == 0) $display(">>> OVERALL STATUS: [ SUCCESS ] <<<");
        else               $display(">>> OVERALL STATUS: [ FAILURE ] <<<");
        $display("===============================================================");
        
        $finish;
    end

    //    // -------------------------------------------------------------------------
    // Automatic Checker Monitor
    // Validates streamed output values as they exit the datapath
    // -------------------------------------------------------------------------
    initial begin
        forever begin
            @(posedge clk);
            if (pixel_valid_out) begin
                if (expected_q.size() > 0) begin
                    logic signed [OUT_WIDTH-1:0] exp_val = expected_q.pop_front();
                    
                    if (pixel_out !== exp_val) begin
                        $error("Time %0t | MISMATCH! Expected = %0d, Got = %0d", $time, exp_val, pixel_out);
                        fail_cnt++;
                    end else begin
                        pass_cnt++;
                    end
                end else begin
                    $error("Time %0t | SPURIOUS OUTPUT! Received valid_out when no data was expected.", $time);
                    fail_cnt++;
                end
            end
        end
    end

endmodule