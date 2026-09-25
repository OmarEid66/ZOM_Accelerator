// =============================================================================
// tb_convolver_top.sv
//
// Fully Parameterized Testbench for convolver_top (SINGLE DUT)
//
// +-------------------------------------------------------------+
// |               QUICK CONFIGURATION - Edit Here               |
// |                                                             |
// |  Set MODE, IMG_SIZE (or IMG_WIDTH/IMG_HEIGHT), KERNEL_SIZE  |
// |  Then run conv.py with matching parameters first:           |
// |                                                             |
// |  python E:/conv.py --mode <MODE> --img_size <IMG_SIZE>      |
// |                    --kernel_size <KERNEL_SIZE>              |
// |                    --num_cases <NUM_TEST_CASES>             |
// +-------------------------------------------------------------+
//
// Operating Modes:
//   MODE 1 : Centrosymmetric  - IS_SYMMETRIC=1, NUM_KERNELS=1
//            W[r,c] == W[K-1-r, K-1-c]; uses (K^2+1)/2 DSPs
//   MODE 2 : Dual-Patch       - IS_SYMMETRIC=0, NUM_KERNELS=1
//            2 patches/cycle, 2 outputs per clock
//   MODE 3 : Dual-Kernel      - IS_SYMMETRIC=0, NUM_KERNELS=2
//            2 kernels/cycle, 2 kernel outputs per clock
//
// Clock: 280.034 MHz (3.571 ns period)
// =============================================================================
`timescale 1ns/1ps

module tb_convolver_top #(
    // ---------------------------------------------------------
    //  Primary parameters: change these to switch configurations
    // ---------------------------------------------------------
    parameter int MODE           = 2,    // 1: Centrosymmetric | 2: Dual-Patch | 3: Dual-Kernel
    parameter int IMG_SIZE       = 32,   // Square shortcut (overridden by IMG_WIDTH/IMG_HEIGHT)
    parameter int IMG_WIDTH      = IMG_SIZE,
    parameter int IMG_HEIGHT     = IMG_SIZE,
    parameter int KERNEL_SIZE    = 3,    // 1 | 3 | 5 | 7 | 9
    parameter int NUM_TEST_CASES = 10,

    // ---------------------------------------------------------
    //  Data-width parameters (rarely need changing)
    // ---------------------------------------------------------
    parameter int PIXEL_WIDTH    = 8,
    parameter int WEIGHT_WIDTH   = 8,
    parameter int ACC_WIDTH      = 32,
    parameter int OUT_WIDTH      = 16
);

    // -------------------------------------------------------------------------
    // Architecture derived from MODE
    // -------------------------------------------------------------------------
    localparam bit IS_SYMMETRIC = (MODE == 1) ? 1'b1 : 1'b0;
    localparam int NUM_KERNELS  = (MODE == 3) ? 2 : 1;
    localparam int NUM_K        = NUM_KERNELS;

    // Geometry
    localparam int NUM_TAPS      = KERNEL_SIZE * KERNEL_SIZE;
    localparam int TOTAL_WEIGHTS = NUM_K * NUM_TAPS;
    localparam int OUT_W         = IMG_WIDTH  - KERNEL_SIZE + 1;
    localparam int OUT_H         = IMG_HEIGHT - KERNEL_SIZE + 1;
    localparam int IMG_PIXELS    = IMG_WIDTH  * IMG_HEIGHT;
    localparam int OUT_PIXELS    = OUT_W * OUT_H;
    localparam int TOTAL_OUT     = NUM_K * OUT_PIXELS;

    // Mode 2: outputs come in pairs (2 pixels per valid cycle)
    // The number of valid pulses = OUT_PIXELS / 2
    localparam int M2_PAIRS      = OUT_PIXELS / 2;

    // Truncation rule - must match conv.py get_trunc_bits()
    function automatic int get_trunc_bits(int k);
        if      (k >= 7) return 3;
        else if (k >= 3) return 2;
        else             return 0;
    endfunction
    localparam int TRUNC_BITS = get_trunc_bits(KERNEL_SIZE);

    // -------------------------------------------------------------------------
    // Clock (280 MHz) & Reset
    // -------------------------------------------------------------------------
    localparam real CLK_PERIOD = 3.571; // 280.034 MHz
    logic clk   = 1'b0;
    logic rst_n;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    longint unsigned cycle_count = 0;
    always_ff @(posedge clk) cycle_count <= cycle_count + 1;

    int pass_count  = 0;
    int fail_count  = 0;
    int test_number = 0;

    // -------------------------------------------------------------------------
    // DUT Ports
    // -------------------------------------------------------------------------
    logic                                                          start;
    logic                                                          busy;
    logic                                                          done;
    logic                                                          pixel_valid_in;
    logic [PIXEL_WIDTH-1:0]                                        pixel_in;
    logic                                                          kernel_wr_en;
    logic [(TOTAL_WEIGHTS > 1 ? $clog2(TOTAL_WEIGHTS)-1 : 0):0]   kernel_wr_addr;
    logic signed [WEIGHT_WIDTH-1:0]                                kernel_wr_data;
    logic                                                          out_valid;
    logic signed [OUT_WIDTH-1:0]                                   out_pixel_k0;
    logic signed [OUT_WIDTH-1:0]                                   out_pixel_k1;
    logic                                                          out_last;
    logic [(NUM_K > 1 ? $clog2(NUM_K) : 0):0]                     out_kernel_idx;

    longint unsigned start_cycle;
    longint unsigned done_cycle;
    realtime         start_time;
    realtime         done_time;

    // -------------------------------------------------------------------------
    // DUT Instance
    // -------------------------------------------------------------------------
    convolver_top #(
        .MODE        (MODE),
        .IMG_SIZE    (IMG_SIZE),
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH   (ACC_WIDTH),
        .OUT_WIDTH   (OUT_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .busy          (busy),
        .done          (done),
        .pixel_valid_in(pixel_valid_in),
        .pixel_in      (pixel_in),
        .kernel_wr_en  (kernel_wr_en),
        .kernel_wr_addr(kernel_wr_addr),
        .kernel_wr_data(kernel_wr_data),
        .out_valid     (out_valid),
        .out_pixel_k0  (out_pixel_k0),
        .out_pixel_k1  (out_pixel_k1),
        .out_last      (out_last),
        .out_kernel_idx(out_kernel_idx)
    );

    // -------------------------------------------------------------------------
    // Test Vector Memory (loaded from .mem files generated by conv.py)
    // -------------------------------------------------------------------------
    logic [PIXEL_WIDTH-1:0]         test_images   [0:(NUM_TEST_CASES * IMG_PIXELS)   - 1];
    logic signed [WEIGHT_WIDTH-1:0] test_weights  [0:(NUM_TEST_CASES * TOTAL_WEIGHTS)- 1];
    logic signed [OUT_WIDTH-1:0]    test_expected [0:(NUM_TEST_CASES * TOTAL_OUT)     - 1];

    // -------------------------------------------------------------------------
    // Algorithmic (on-the-fly) Golden Reference
    // Used as a second independent cross-check in addition to .mem file check.
    // -------------------------------------------------------------------------
    function automatic logic signed [OUT_WIDTH-1:0] compute_golden(
        ref   logic [PIXEL_WIDTH-1:0]         img     [0:IMG_PIXELS-1],
        input logic signed [WEIGHT_WIDTH-1:0] w       [0:NUM_TAPS-1],
        input int row, input int col
    );
        longint sum = 0;
        for (int wr = 0; wr < KERNEL_SIZE; wr++)
            for (int wc = 0; wc < KERNEL_SIZE; wc++)
                sum += longint'(img[(row+wr)*IMG_WIDTH + (col+wc)])
                     * longint'(w [wr*KERNEL_SIZE + wc]);
        sum = sum >>> TRUNC_BITS;
        // ReLU + 16-bit saturation
        if      (sum < 0)     sum = 0;
        else if (sum > 32767) sum = 32767;
        return OUT_WIDTH'(sum);
    endfunction

    // -------------------------------------------------------------------------
    // Universal Test Task
    // Works for Mode 1, 2, and 3 with any IMG_WIDTH / IMG_HEIGHT / KERNEL_SIZE
    // -------------------------------------------------------------------------
    task automatic run_test_case(input int tc);
        automatic int local_fails    = 0;
        automatic int img_offset     = tc * IMG_PIXELS;
        automatic int weight_offset  = tc * TOTAL_WEIGHTS;
        automatic int exp_offset     = tc * TOTAL_OUT;

        automatic logic signed [OUT_WIDTH-1:0] captured_out [0:TOTAL_OUT-1];

        test_number++;

        $display("\n==================================================");
        $display(">>> Starting Test Case %0d/%0d", test_number, NUM_TEST_CASES);
        $display("    Mode %0d | Image %0dx%0d | Kernel %0dx%0d | Kernels %0d | Trunc %0d bits | ReLU ON",
                 MODE, IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE, NUM_K, TRUNC_BITS);
        $display("    IS_SYMMETRIC=%0d  OUT_SIZE=%0dx%0d  TOTAL_OUT=%0d",
                 IS_SYMMETRIC, OUT_W, OUT_H, TOTAL_OUT);
        $display("==================================================");

        // -- 1. Load Kernel Weights -----------------------------------------
        @(negedge clk);
        kernel_wr_en = 1'b1;
        for (int i = 0; i < TOTAL_WEIGHTS; i++) begin
            kernel_wr_addr = i;
            kernel_wr_data = test_weights[weight_offset + i];
            @(negedge clk);
        end
        kernel_wr_en = 1'b0;
        @(negedge clk);

        // -- 2. Assert Start -----------------------------------------------
        start_time  = $realtime;
        start_cycle = cycle_count;
        start       = 1'b1;
        @(negedge clk);
        start = 1'b0;

        if (!busy) begin
            $display("[ERROR] 'busy' did not assert after 'start'!");
            local_fails++;
        end

        // -- 3. Stream pixels & collect outputs (all run in parallel) ------
        fork
            // -- Pixel Feeder ----------------------------------------------
            begin : stream_feeder
                for (int i = 0; i < IMG_PIXELS; i++) begin
                    @(negedge clk);
                    pixel_valid_in = 1'b1;
                    pixel_in       = test_images[img_offset + i];
                end
                @(negedge clk);
                pixel_valid_in = 1'b0;
                pixel_in       = '0;
            end

            // -- Output Collector ------------------------------------------
            begin : stream_collector
                if (MODE == 1) begin
                    // -- Mode 1: 1 output pixel per valid cycle -------------
                    automatic int collected = 0;
                    while (collected < OUT_PIXELS) begin
                        @(posedge clk); #1ps;
                        if (out_valid) begin
                            captured_out[collected] = out_pixel_k0;
                            collected++;
                        end
                    end

                end else if (MODE == 2) begin
                    // -- Mode 2: 2 output pixels per valid cycle ------------
                    // out_pixel_k0 = even column, out_pixel_k1 = odd column
                    // They arrive in raster order: (r,0),(r,1), (r,2),(r,3)...
                    automatic int pair_idx = 0;
                    while (pair_idx < M2_PAIRS) begin
                        @(posedge clk); #1ps;
                        if (out_valid) begin
                            automatic int r  = pair_idx / (OUT_W / 2);
                            automatic int c0 = (pair_idx % (OUT_W / 2)) * 2;
                            automatic int c1 = c0 + 1;
                            captured_out[r * OUT_W + c0] = out_pixel_k0;
                            captured_out[r * OUT_W + c1] = out_pixel_k1;
                            pair_idx++;
                        end
                    end

                end else begin
                    // -- Mode 3: 2 kernel outputs per valid cycle -----------
                    // out_kernel_idx tells which kernel pair k0/k1 map to
                    automatic int captured_k0_cnt = 0;
                    automatic int captured_k1_cnt = 0;
                    automatic int total_collected  = 0;
                    while (total_collected < TOTAL_OUT) begin
                        @(posedge clk); #1ps;
                        if (out_valid) begin
                            automatic int base_k0 = out_kernel_idx * OUT_PIXELS;
                            captured_out[base_k0 + captured_k0_cnt] = out_pixel_k0;
                            captured_k0_cnt++;
                            total_collected++;
                            if (captured_k0_cnt == OUT_PIXELS) captured_k0_cnt = 0;

                            if (out_kernel_idx + 1 < NUM_K) begin
                                automatic int base_k1 = (out_kernel_idx + 1) * OUT_PIXELS;
                                captured_out[base_k1 + captured_k1_cnt] = out_pixel_k1;
                                captured_k1_cnt++;
                                total_collected++;
                                if (captured_k1_cnt == OUT_PIXELS) captured_k1_cnt = 0;
                            end
                        end
                    end
                end
            end

            // -- Done Watcher ----------------------------------------------
            begin : wait_done
                @(posedge done);
                done_time  = $realtime;
                done_cycle = cycle_count;
            end
        join

        // -- 4. Verification vs .mem File (Python Golden) ------------------
        for (int k = 0; k < NUM_K; k++) begin
            for (int r = 0; r < OUT_H; r++) begin
                for (int c = 0; c < OUT_W; c++) begin
                    automatic int flat = k * OUT_PIXELS + r * OUT_W + c;
                    automatic logic signed [OUT_WIDTH-1:0] exp_val = test_expected[exp_offset + flat];
                    automatic logic signed [OUT_WIDTH-1:0] act_val = captured_out[flat];
                    if (act_val !== exp_val) begin
                        if (local_fails < 10)
                            $display("  [MEM MISMATCH] K%0d(r=%0d,c=%0d) exp=%0d got=%0d",
                                     k, r, c, exp_val, act_val);
                        local_fails++;
                    end
                end
            end
        end

        // -- 5. Cross-check vs Algorithmic Golden Reference ----------------
        begin : algo_check
            automatic logic [PIXEL_WIDTH-1:0]         curr_img [0:IMG_PIXELS-1];
            automatic logic signed [WEIGHT_WIDTH-1:0] curr_w   [0:NUM_TAPS-1];

            for (int i = 0; i < IMG_PIXELS; i++)
                curr_img[i] = test_images[img_offset + i];

            for (int k = 0; k < NUM_K; k++) begin
                for (int t = 0; t < NUM_TAPS; t++)
                    curr_w[t] = test_weights[weight_offset + k * NUM_TAPS + t];

                for (int r = 0; r < OUT_H; r++) begin
                    for (int c = 0; c < OUT_W; c++) begin
                        automatic int flat    = k * OUT_PIXELS + r * OUT_W + c;
                        automatic logic signed [OUT_WIDTH-1:0] algo = compute_golden(curr_img, curr_w, r, c);
                        automatic logic signed [OUT_WIDTH-1:0] act  = captured_out[flat];
                        if (act !== algo) begin
                            if (local_fails < 10)
                                $display("  [ALGO MISMATCH] K%0d(r=%0d,c=%0d) algo=%0d got=%0d",
                                         k, r, c, algo, act);
                            local_fails++;
                        end
                    end
                end
            end
        end

        // -- 6. Results ----------------------------------------------------
        pass_count += (TOTAL_OUT - local_fails);
        fail_count += local_fails;

        if (local_fails == 0) begin
            automatic longint unsigned proc_cycles = done_cycle - start_cycle;
            automatic real proc_us   = (done_time - start_time) / 1000.0;
            automatic real mpps      = (real'(TOTAL_OUT) / (proc_us * 1e-6)) / 1e6;
            automatic real fps       = 1.0 / (proc_us * 1e-6);
            $display(">>> Test %0d: PASSED! (%0d/%0d outputs correct)", tc, TOTAL_OUT, TOTAL_OUT);
            $display("    Processing Time : %0d cycles (%.3f us)", proc_cycles, proc_us);
            $display("    Throughput      : %.2f Megapixels/sec", mpps);
            $display("    Frame Rate      : %.1f passes/sec", fps);
        end else begin
            $display(">>> Test %0d: FAILED with %0d errors!", tc, local_fails);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Initial Block
    // -------------------------------------------------------------------------
    string mem_dir;
    string img_file, wt_file, exp_file;

    initial begin
        // Allow MEM_PATH plusarg override (e.g. +MEM_PATH=E:/outputs)
        if (!$value$plusargs("MEM_PATH=%s", mem_dir))
            mem_dir = "E:";

        $display("==================================================");
        $display(" CONVOLVER TOP TESTBENCH");
        $display(" MODE=%0d | IMG=%0dx%0d | KERNEL=%0dx%0d | CASES=%0d",
                 MODE, IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE, NUM_TEST_CASES);
        $display(" IS_SYMMETRIC=%0d  NUM_KERNELS=%0d  TRUNC_BITS=%0d",
                 IS_SYMMETRIC, NUM_K, TRUNC_BITS);
        $display(" OUT_SIZE=%0dx%0d  TOTAL_OUT_PER_CASE=%0d", OUT_W, OUT_H, TOTAL_OUT);
        $display("==================================================");

        // Try mode-tagged files first, then fall back to generic
        img_file = $sformatf("%s/all_images_m%0d.mem",   mem_dir, MODE);
        wt_file  = $sformatf("%s/all_weights_m%0d.mem",  mem_dir, MODE);
        exp_file = $sformatf("%s/all_expected_m%0d.mem", mem_dir, MODE);

        begin : file_check
            automatic int fh = $fopen(img_file, "r");
            if (fh == 0) begin
                img_file = $sformatf("%s/all_images.mem",   mem_dir);
                wt_file  = $sformatf("%s/all_weights.mem",  mem_dir);
                exp_file = $sformatf("%s/all_expected.mem", mem_dir);
                fh = $fopen(img_file, "r");
                if (fh == 0) begin
                    $display("[FATAL] No .mem files found in '%s'!", mem_dir);
                    $display("  Expected: all_images_m%0d.mem OR all_images.mem", MODE);
                    $display("  Run: python E:/conv.py --mode %0d --img_size %0d --kernel_size %0d",
                             MODE, IMG_SIZE, KERNEL_SIZE);
                    $finish;
                end
            end
            $fclose(fh);
        end

        $display(" Loading test vectors...");
        $display("   Images   -> %s", img_file);
        $display("   Weights  -> %s", wt_file);
        $display("   Expected -> %s", exp_file);
        $readmemh(img_file,  test_images);
        $readmemh(wt_file,   test_weights);
        $readmemh(exp_file,  test_expected);
        $display(" Vectors loaded.");
        $display("==================================================");

        // Initialize DUT
        rst_n          = 1'b0;
        start          = 1'b0;
        pixel_valid_in = 1'b0;
        pixel_in       = '0;
        kernel_wr_en   = 1'b0;
        kernel_wr_addr = '0;
        kernel_wr_data = '0;

        // Reset sequence
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5)  @(negedge clk);

        // Run all test cases
        for (int tc = 0; tc < NUM_TEST_CASES; tc++)
            run_test_case(tc);

        // Summary
        $display("\n==================================================");
        $display("         FINAL VERIFICATION SUMMARY");
        $display("  MODE=%0d | IMG=%0dx%0d | KERNEL=%0dx%0d",
                 MODE, IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE);
        $display("==================================================");
        $display(" Total Assertions : %0d", pass_count + fail_count);
        $display(" Passed           : %0d", pass_count);
        $display(" Failed           : %0d", fail_count);
        $display("==================================================");

        if (fail_count == 0)
            $display(" *** MODE %0d PASSED -- 100%% BIT-ACCURATE ***\n", MODE);
        else
            $display(" *** MODE %0d FAILED -- %0d ERRORS ***\n", MODE, fail_count);

        $finish;
    end

endmodule