`timescale 1ns/1ps

module tb_window_gen;

    // -------------------------------------------------------------------------
    // Testbench Parameters
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD  = 10;
    localparam int IMG_WIDTH   = 8;  // Small image for easier trace debugging
    localparam int IMG_HEIGHT  = 8;
    localparam int PIXEL_WIDTH = 8;
    localparam int KERNEL_SIZE = 3;

    localparam int NUM_TAPS    = KERNEL_SIZE * KERNEL_SIZE;
    localparam int TOTAL_PIX   = IMG_WIDTH * IMG_HEIGHT;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    logic                                            pixel_valid;
    logic [PIXEL_WIDTH-1:0]                          pixel_in;

    logic                                            window_valid;
    logic [(NUM_TAPS*PIXEL_WIDTH)-1:0]               window_flat;
    logic [$clog2(IMG_HEIGHT):0]                     out_row;
    logic [$clog2(IMG_WIDTH):0]                      out_col;

    // Unpacked window for easier waveform viewing
    logic [PIXEL_WIDTH-1:0] window_unpacked [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

    always_comb begin
        for (int r = 0; r < KERNEL_SIZE; r++) begin
            for (int c = 0; c < KERNEL_SIZE; c++) begin
                int tap_idx = r * KERNEL_SIZE + c;
                window_unpacked[r][c] = window_flat[tap_idx*PIXEL_WIDTH +: PIXEL_WIDTH];
            end
        end
    end

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
    window_gen #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .pixel_valid  (pixel_valid),
        .pixel_in     (pixel_in),
        .window_valid (window_valid),
        .window_flat  (window_flat),
        .out_row      (out_row),
        .out_col      (out_col)
    );

    // -------------------------------------------------------------------------
    // Stimulus and Verification Tasks
    // -------------------------------------------------------------------------
    
    // Function to calculate a synthetic pixel value based on row and col
    function automatic logic [PIXEL_WIDTH-1:0] get_pixel(int r, int c);
        // Simple synthetic pattern: (row * 10) + col
        return (r * 10) + c;
    endfunction

    initial begin
        // Initialize signals
        rst_n       = 0;
        pixel_valid = 0;
        pixel_in    = '0;

        // Apply reset
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("===============================================================");
        $display("Starting window_gen Simulation");
        $display("Image Size: %0dx%0d, Kernel Size: %0dx%0d", IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE);
        $display("===============================================================");

        // Stream an entire image
        for (int r = 0; r < IMG_HEIGHT; r++) begin
            for (int c = 0; c < IMG_WIDTH; c++) begin
                @(negedge clk);
                pixel_valid = 1;
                pixel_in    = get_pixel(r, c);
            end
        end

        // De-assert valid after image completes
        @(negedge clk);
        pixel_valid = 0;
        pixel_in    = '0;

        // Wait a few cycles to observe pipeline flushing
        #(CLK_PERIOD * 10);
        
        $display("===============================================================");
        $display("Simulation Complete.");
        $display("===============================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Monitor Output Activity
    // -------------------------------------------------------------------------
    initial begin
        int valid_count = 0;
        forever begin
            @(posedge clk);
            if (window_valid) begin
                valid_count++;
                
                // Only print the first few and last few to avoid flooding the console
                if (valid_count <= 5 || valid_count >= ((IMG_WIDTH - KERNEL_SIZE + 1) * (IMG_HEIGHT - KERNEL_SIZE + 1) - 4)) begin
                    $display("Time: %0t | Valid Output #%0d | Center Coords: (%0d, %0d)", 
                             $time, valid_count, out_row + KERNEL_SIZE/2, out_col + KERNEL_SIZE/2);
                    $display("Window Data (Top-Left to Bottom-Right):");
                    for (int r = 0; r < KERNEL_SIZE; r++) begin
                        $write("  [ ");
                        for (int c = 0; c < KERNEL_SIZE; c++) begin
                            $write("%3d ", window_unpacked[r][c]);
                        end
                        $display("]");
                    end
                end else if (valid_count == 6) begin
                     $display("... (suppressing middle output prints) ...");
                end
            end
        end
    end

endmodule