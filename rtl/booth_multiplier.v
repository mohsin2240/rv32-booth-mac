//============================================================================
// File        : booth_multiplier.v
// Module      : booth_multiplier
// Project     : Design and Verification of a RISC-V Multiply-Accumulate (MAC)
//               Unit for Digital Signal Processing
// Language    : Verilog-2005 (IEEE Std 1364-2005), synthesizable
// Authors     : Mohsin Mushtaq (2025MECECS001)
//               Mubashir Karim Ganaie (2025MECECS005)
// Supervisor  : Dr. Afshan Amin Khan
// Institution : Department of Electronics and Communications,
//               National Institute of Technology Srinagar
//
// Description :
//   Combinational signed multiplier using Radix-4 Modified Booth Encoding
//   (A. D. Booth, 1951; O. L. MacSorley, 1961).
//
//   The multiplier operand B is scanned in overlapping 3-bit groups
//   {b[2i+1], b[2i], b[2i-1]} (with b[-1] = 0). Each group selects one
//   partial product from the set {0, +A, +2A, -A, -2A}:
//
//        b[2i+1] b[2i] b[2i-1] | partial product
//        ----------------------+----------------
//           0      0      0    |   0
//           0      0      1    |  +A
//           0      1      0    |  +A
//           0      1      1    |  +2A
//           1      0      0    |  -2A
//           1      0      1    |  -A
//           1      1      0    |  -A
//           1      1      1    |   0
//
//   Partial product i has weight 4^i, so a W-bit multiply needs only W/2
//   partial products instead of W (halves the adder tree vs. array mult).
//
//   P = sum_{i=0}^{W/2-1} PP_i * 4^i      (two's complement, exact)
//
// Parameters :
//   W  - operand width in bits. MUST be even. Both operands are treated as
//        two's-complement signed numbers. Unsigned operation is obtained by
//        the caller zero-extending its operands by at least one bit.
//
// Ports :
//   a_i  [W-1:0]   multiplicand (signed)
//   b_i  [W-1:0]   multiplier   (signed, Booth-recoded)
//   p_o  [2W-1:0]  full-precision signed product a_i * b_i
//============================================================================
`timescale 1ns/1ps

module booth_multiplier #(
    parameter integer W = 34                 // operand width (even)
) (
    input  wire signed [W-1:0]   a_i,
    input  wire signed [W-1:0]   b_i,
    output reg  signed [2*W-1:0] p_o
);

    // Multiplicand sign-extended to the full product width so every
    // partial product (including the shifted/negated ones) is exact.
    wire signed [2*W-1:0] a_ext = {{W{a_i[W-1]}}, a_i};

    // Multiplier with the implicit b[-1] = 0 appended on the right.
    wire [W:0] b_ext = {b_i, 1'b0};

    integer           i;
    reg [2:0]         grp;     // current Booth group {b[2i+1], b[2i], b[2i-1]}
    reg signed [2*W-1:0] pp;   // current (un-shifted) partial product
    reg signed [2*W-1:0] acc;  // running sum of weighted partial products

    always @* begin
        acc = {2*W{1'b0}};
        for (i = 0; i < W/2; i = i + 1) begin
            grp = b_ext[2*i +: 3];

            // Booth recoding: select partial product from {0, ±A, ±2A}
            case (grp)
                3'b000, 3'b111: pp = {2*W{1'b0}};     //  0
                3'b001, 3'b010: pp =  a_ext;          // +A
                3'b011:         pp =  a_ext <<< 1;    // +2A
                3'b100:         pp = -(a_ext <<< 1);  // -2A
                3'b101, 3'b110: pp = -a_ext;          // -A
                default:        pp = {2*W{1'b0}};
            endcase

            // Accumulate with weight 4^i (shift by 2i bit positions)
            acc = acc + (pp <<< (2*i));
        end
        p_o = acc;
    end

endmodule
