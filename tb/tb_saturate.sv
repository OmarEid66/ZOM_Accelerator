`timescale 1ns/1ps

module tb_saturate;

    localparam int ACC_WIDTH = 32;
    localparam int OUT_WIDTH = 16;

    logic signed [ACC_WIDTH-1:0] acc_in;
    logic signed [OUT_WIDTH-1:0] sat_out;

    int pass_count = 0;
    int fail_count = 0;

    saturate #(.ACC_WIDTH(ACC_WIDTH), .OUT_WIDTH(OUT_WIDTH)) dut (
        .acc_in  (acc_in),
        .sat_out (sat_out)
    );

    task automatic check(input string name, input logic signed [ACC_WIDTH-1:0] v,
                          input logic signed [OUT_WIDTH-1:0] expected);
        acc_in = v;
        #1; // allow combinational settle
        if (sat_out === expected) begin
            $display("%-24s PASS  in=%0d expected=%0d actual=%0d", name, v, expected, sat_out);
            pass_count++;
        end else begin
            $display("%-24s FAIL  in=%0d expected=%0d actual=%0d", name, v, expected, sat_out);
            fail_count++;
        end
    endtask

    initial begin
        check("zero",                 32'sd0,      16'sd0);
        check("plus_one",              32'sd1,      16'sd1);
        check("minus_one",            -32'sd1,     -16'sd1);
        check("pos_boundary",          32'sd32767,  16'sd32767);   // exact top rail, no saturation
        check("pos_boundary_plus1",    32'sd32768, 16'sd32767);   // one past -> saturate
        check("neg_boundary",         -32'sd32768, -16'sd32768);  // exact bottom rail, no saturation
        check("neg_boundary_minus1",  -32'sd32769, -16'sd32768);  // one past -> saturate
        check("max_pos_accumulator",   32'sd291465, 16'sd32767);  // worst-case +accumulator from Stage 1 (9*255*127)
        check("max_neg_accumulator",  -32'sd293760, -16'sd32768); // worst-case -accumulator from Stage 1 (9*255*-128)

        $display("--------------------------------------------------");
        $display("TOTAL: %0d   PASS: %0d   FAIL: %0d", pass_count+fail_count, pass_count, fail_count);
        if (fail_count == 0) $display("OVERALL: PASS");
        else                 $display("OVERALL: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule

