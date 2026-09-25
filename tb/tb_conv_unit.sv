`timescale 1ns/1ps

module tb_conv_unit;

    // -------------------------------------------------------------------------
    // Testbench Parameters
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD   = 10;
    localparam int KERNEL_SIZE  = 3;
    localparam int PIXEL_WIDTH  = 8;
    localparam int WEIGHT_WIDTH = 8;
    localparam int ACC_WIDTH    = 32;

    localparam int NUM_TAPS     = KERNEL_SIZE * KERNEL_SIZE;
    localparam int NUM_MULTS    = (NUM_TAPS + 1) / 2;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    logic                                              valid_in;
    logic [(NUM_TAPS*PIXEL_WIDTH)-1:0]                 pixel_flat;
    logic [(NUM_TAPS*WEIGHT_WIDTH)-1:0]                weight_flat;

    logic                                              valid_out;
    logic signed [ACC_WIDTH-1:0]                       result;

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    conv_unit #(
        .KERNEL_SIZE  (KERNEL_SIZE),
        .PIXEL_WIDTH  (PIXEL_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        .pixel_flat  (pixel_flat),
        .weight_flat (weight_flat),
        .valid_out   (valid_out),
        .result      (result)
    );

    // -------------------------------------------------------------------------
    // Verification Queues & Helper Tasks
    // -------------------------------------------------------------------------
    
    // Queue to hold expected results for pipelined checking
    int expected_queue[$];
    int test_count = 0;
    int pass_count = 0;

    // Task to apply stimulus and calculate symmetric-pre-adder expected value
    task automatic apply_stimulus(
        input logic [PIXEL_WIDTH-1:0]        p [0:NUM_TAPS-1],
        input logic signed [WEIGHT_WIDTH-1:0] w [0:NUM_TAPS-1]
    );
        logic [(NUM_TAPS*PIXEL_WIDTH)-1:0]  p_flat;
        logic [(NUM_TAPS*WEIGHT_WIDTH)-1:0] w_flat;
        logic signed [ACC_WIDTH-1:0]        expected_val;

        // Flatten arrays for DUT
        for (int i = 0; i < NUM_TAPS; i++) begin
            p_flat[i*PIXEL_WIDTH +: PIXEL_WIDTH] = p[i];
            w_flat[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] = w[i];
        end

        // Calculate expected value based on the DSP48E1 pre-adder topology
        // P_out = sum( (p[i] + p[N-1-i]) * w[i] ) for i < N/2 + center_tap
        expected_val = 0;
        for (int i = 0; i < NUM_MULTS; i++) begin
            if (i < NUM_TAPS / 2) begin
                // Symmetric pair
                expected_val += (signed'({1'b0, p[i]}) + signed'({1'b0, p[NUM_TAPS-1-i]})) * w[i];
            end else begin
                // Center tap
                expected_val += signed'({1'b0, p[i]}) * w[i];
            end
        end

        // Drive signals
        @(negedge clk);
        valid_in    = 1'b1;
        pixel_flat  = p_flat;
        weight_flat = w_flat;

        // Push to verification queue
        expected_queue.push_back(expected_val);
        test_count++;
    endtask

    // Task to clear stimulus lines
    task automatic clear_stimulus();
        @(negedge clk);
        valid_in    = 1'b0;
        pixel_flat  = '0;
        weight_flat = '0;
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus Thread
    // -------------------------------------------------------------------------
    initial begin
        // Local arrays for generating test vectors
        logic [PIXEL_WIDTH-1:0]        p_test [0:NUM_TAPS-1];
        logic signed [WEIGHT_WIDTH-1:0] w_test [0:NUM_TAPS-1];

        // Initialize
        rst_n       = 0;
        valid_in    = 0;
        pixel_flat  = '0;
        weight_flat = '0;

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("===============================================================");
        $display("Starting conv_unit Pipeline Simulation");
        $display("===============================================================");

        // Test 1: All Zeros
        for(int i=0; i<NUM_TAPS; i++) begin p_test[i] = 0; w_test[i] = 0; end
        apply_stimulus(p_test, w_test);

        // Test 2: All Ones (Pixels = 1, Weights = 1) -> Expected = 9
        for(int i=0; i<NUM_TAPS; i++) begin p_test[i] = 1; w_test[i] = 1; end
        apply_stimulus(p_test, w_test);

        // Test 3: Identity Kernel (Center weight = 1, others 0)
        for(int i=0; i<NUM_TAPS; i++) begin p_test[i] = i+1; w_test[i] = (i==4) ? 1 : 0; end
        apply_stimulus(p_test, w_test);

        // Test 4: Back-to-Back Pipeline Stress Test (Edge Detection style kernel)
        for(int i=0; i<NUM_TAPS; i++) w_test[i] = (i==4) ? -8 : 1; 
        
        for(int t=0; t<5; t++) begin
            for(int i=0; i<NUM_TAPS; i++) p_test[i] = $urandom_range(0, 50);
            apply_stimulus(p_test, w_test);
        end

        // Wait for pipeline to flush
        clear_stimulus();
        #(CLK_PERIOD * 15);

        $display("===============================================================");
        $display("Simulation Complete. Passed: %0d / %0d", pass_count, test_count);
        $display("===============================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Output Monitor and Checker Thread
    // -------------------------------------------------------------------------
    initial begin
        logic signed [ACC_WIDTH-1:0] expected_val;

        forever begin
            @(posedge clk);
            if (valid_out) begin
                if (expected_queue.size() == 0) begin
                    $error("Time %0t: Unexpected valid_out asserted! No matching input.", $time);
                end else begin
                    expected_val = expected_queue.pop_front();
                    
                    if (result === expected_val) begin
                        $display("Time %0t: [PASS] Result = %0d", $time, result);
                        pass_count++;
                    end else begin
                        $error("Time %0t: [FAIL] Result = %0d, Expected = %0d", $time, result, expected_val);
                    end
                end
            end
        end
    end

endmodule