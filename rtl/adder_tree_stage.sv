`timescale 1ns/1ps

(* use_dsp = "no" *)
module adder_tree_stage #(
    parameter int NUM_IN = 5,
    parameter int IN_W   = 16,
    parameter int OUT_W  = 32
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  wire logic signed [IN_W-1:0]      in_vec [0:NUM_IN-1],
    output logic signed [OUT_W-1:0]          out_val
);
    if (NUM_IN <= 1) begin : gen_base
        assign out_val = OUT_W'(in_vec[0]);
    end else begin : gen_step
        localparam int NUM_OUT = (NUM_IN + 1) / 2;
        localparam int NEXT_W  = IN_W + 1;
        (* use_dsp = "no" *) logic signed [NEXT_W-1:0] next_stage [0:NUM_OUT-1];

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                for (int i = 0; i < NUM_OUT; i++) next_stage[i] <= '0;
            end else begin
                for (int i = 0; i < NUM_IN / 2; i++) begin
                    next_stage[i] <= $signed(in_vec[2*i]) + $signed(in_vec[2*i + 1]);
                end
                if (NUM_IN % 2 != 0) begin
                    next_stage[NUM_OUT - 1] <= NEXT_W'(in_vec[NUM_IN - 1]);
                end
            end
        end

        adder_tree_stage #(
            .NUM_IN (NUM_OUT),
            .IN_W   (NEXT_W),
            .OUT_W  (OUT_W)
        ) u_next_tree (
            .clk     (clk),
            .rst_n   (rst_n),
            .in_vec  (next_stage),
            .out_val (out_val)
        );
    end
endmodule