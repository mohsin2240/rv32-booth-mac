//============================================================================
// File        : native_multiplier.v
// Module      : booth_multiplier  (drop-in replacement, comparison only)
//
// Description :
//   Same module name and ports as rtl/booth_multiplier.v, but written with
//   the Verilog '*' operator. It is used ONLY by synth/synth_ecp5.ys to
//   compare the hand-written radix-4 Booth multiplier (mapped to LUTs)
//   against the FPGA's hard DSP multipliers, which Yosys infers from '*'.
//   It is not part of the verified design.
//============================================================================
`timescale 1ns/1ps

module booth_multiplier #(
    parameter integer W = 34
) (
    input  wire signed [W-1:0]   a_i,
    input  wire signed [W-1:0]   b_i,
    output wire signed [2*W-1:0] p_o
);
    assign p_o = a_i * b_i;
endmodule
