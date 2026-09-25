`timescale 1ns/1ps

module tb_adder_tree_stage;

    //    // -------------------------------------------------------------------------
    // Testbench Parameters
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD = 10;
    localparam int NUM_IN     = 5;  // Default matched to 3x3 pre-adder conv_unit
    localparam int DATA_W     = 24; 

    // Function to calculate recursive pipeline latency
    function automatic int get_latency(int n);
        if (n <= 1) return 0;
        else return $clog2(n);
    endfunction

    localparam int LATENCY = get_latency(NUM_IN);

    //    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic                             clk;
    logic                             rst_n;
    logic signed [DATA_W-1:0]         in_vec [0:NUM_IN-1];
    logic signed [DATA_W-1:0]         out_val;

    // Testbench internal synchronization
    logic                             valid_in;
    logic [LATENCY:0]                 valid_pipe; // Size safely to avoid 0-width
    logic                             valid_out;
    
    int expected_q[$];
    int pass_cnt = 0;
    int fail_cnt = 0;
    int test_cnt = 0;

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
    adder_tree_stage #(
        .NUM_IN (NUM_IN),
        .DATA_W (DATA_W)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_vec  (in_vec),
        .out_val (out_val)
    );

    //    // -------------------------------------------------------------------------
    // Stimulus & Golden Model Task
    // -------------------------------------------------------------------------
    task automatic drive_vector(input logic signed [DATA_W-1:0] vec [0:NUM_IN-1]);
        logic signed [DATA_W-1:0] expected_sum;
        
        // Golden model: Sum all elements (relying on natural DATA_W wrap/truncation)
        expected_sum = 0;
        for (int i = 0; i < NUM_IN; i++) begin
            expected_sum += vec[i];
        end

        // Drive DUT
        @(negedge clk);
        valid_in = 1'b1;
        for (int i = 0; i < NUM_IN; i++) begin
            in_vec[i] = vec[i];
        end

        // Track in queue
        expected_q.push_back(expected_sum);
        test_cnt++;
    endtask

    //    // -------------------------------------------------------------------------
    // Pipeline Synchronization
    // Track valid signals through the exact depth of the adder tree
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
        end else begin
            if (LATENCY > 0) begin
                valid_pipe <= {valid_pipe[LATENCY-1:0], valid_in};
            end
        end
    end

    assign valid_out = (LATENCY == 0) ? valid_in : valid_pipe[LATENCY-1];

    //    // -------------------------------------------------------------------------
    // Main Stimulus Sequence
    // -------------------------------------------------------------------------
    initial begin
        logic signed [DATA_W-1:0] test_vec [0:NUM_IN-1];

        // Initialization
        rst_n    = 0;
        valid_in = 0;
        for (int i = 0; i < NUM_IN; i++) in_vec[i] = '0;

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("===============================================================");
        $display("STARTING ADDER_TREE_STAGE VALIDATION");
        $display("NUM_IN: %0d | DATA_W: %0d | Calculated Latency: %0d cycles", NUM_IN, DATA_W, LATENCY);
        $display("===============================================================");

        // Test 1: All Zeros
        for (int i = 0; i < NUM_IN; i++) test_vec[i] = 0;
        drive_vector(test_vec);

        // Test 2: All Ones
        for (int i = 0; i < NUM_IN; i++) test_vec[i] = 1;
        drive_vector(test_vec);

        // Test 3: Alternating Signs
        for (int i = 0; i < NUM_IN; i++) test_vec[i] = (i % 2 == 0) ? 50 : -25;
        drive_vector(test_vec);

        // Test 4: Back-to-Back Random Pipeline Stress
        for (int t = 0; t < 20; t++) begin
            for (int i = 0; i < NUM_IN; i++) begin
                // Randomize within a safe range to easily observe without extreme wrapping
                test_vec[i] = $signed($urandom_range(0, 2000)) - 1000;
            end
            drive_vector(test_vec);
        end

        // Flush Pipeline
        @(negedge clk);
        valid_in = 1'b0;
        for (int i = 0; i < NUM_IN; i++) in_vec[i] = '0;

        // Wait for all expected results to flush out
        wait(expected_q.size() == 0);
        #(CLK_PERIOD * 5);

        $display("===============================================================");
        $display("SIMULATION COMPLETE");
        $display("Tests Run : %0d", test_cnt);
        $display("Passed    : %0d", pass_cnt);
        $display("Failed    : %0d", fail_cnt);
        if (fail_cnt == 0) $display(">>> OVERALL STATUS: [ SUCCESS ] <<<");
        else               $display(">>> OVERALL STATUS: [ FAILURE ] <<<");
        $display("===============================================================");
        
        $finish;
    end

    //    // -------------------------------------------------------------------------
    // Automatic Checker Monitor
    // -------------------------------------------------------------------------
    initial begin
        forever begin
            @(posedge clk);
            if (valid_out) begin
                if (expected_q.size() > 0) begin
                    logic signed [DATA_W-1:0] exp_val = expected_q.pop_front();
                    
                    if (out_val !== exp_val) begin
                        $error("Time %0t | MISMATCH! Expected = %0d, Got = %0d", $time, exp_val, out_val);
                        fail_cnt++;
                    end else begin
                        pass_cnt++;
                    end
                end else begin
                    $error("Time %0t | SPURIOUS OUTPUT! Received output when no data was expected.", $time);
                    fail_cnt++;
                end
            end
        end
    end

endmodule