`timescale 1ns/1ps

module saturate #(
    parameter int ACC_WIDTH = 32,
    parameter int OUT_WIDTH = 16
)(
    input  logic signed [ACC_WIDTH-1:0] acc_in,
    output logic signed [OUT_WIDTH-1:0] sat_out
);

    localparam logic signed [ACC_WIDTH-1:0] POS_MAX = (ACC_WIDTH'(1) <<< (OUT_WIDTH-1)) - ACC_WIDTH'(1); //  32767
    localparam logic signed [ACC_WIDTH-1:0] NEG_MIN = -(ACC_WIDTH'(1) <<< (OUT_WIDTH-1));                // -32768

    always_comb begin
        if (acc_in > POS_MAX)
            sat_out = OUT_WIDTH'(POS_MAX);   //  32767
        else if (acc_in < NEG_MIN)
            sat_out = OUT_WIDTH'(NEG_MIN);   // -32768
        else
            sat_out = acc_in[OUT_WIDTH-1:0];
    end

endmodule

