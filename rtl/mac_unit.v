//============================================================================
// File        : mac_unit.v
// Module      : mac_unit
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
//   A 2-stage pipelined Multiply-Accumulate execution unit that plugs into a
//   RV32 core as a custom-instruction functional unit. It decodes R-type
//   instructions in the RISC-V "custom-0" major opcode (0001011), which the
//   RISC-V Unprivileged ISA specification reserves for non-standard
//   extensions, and operates on a dedicated 64-bit accumulator register.
//
//   A 64-bit accumulator holding the sum of 32x32 products is the classic
//   DSP "guard bit" arrangement (cf. CMSIS-DSP q63_t accumulators): it lets
//   long dot products / FIR filters run without intermediate overflow, and
//   the signed operations additionally saturate instead of wrapping.
//
//   Instruction encoding (R-type):
//
//    31        25 24    20 19    15 14  12 11     7 6         0
//   +------------+--------+--------+------+--------+-----------+
//   |  0000000   |  rs2   |  rs1   |funct3|   rd   |  0001011  |
//   +------------+--------+--------+------+--------+-----------+
//
//   funct3 | mnemonic       | operation                         | rd value
//   -------+----------------+-----------------------------------+-------------
//    000   | mac   rd,a,b   | ACC = sat64(ACC + a*b)   (signed) | ACC[31:0]
//    001   | msu   rd,a,b   | ACC = sat64(ACC - a*b)   (signed) | ACC[31:0]
//    010   | mul.acc rd,a,b | ACC = a*b, OVF = 0       (signed) | ACC[31:0]
//    011   | macu  rd,a,b   | ACC = ACC + a*b (unsigned, mod 2^64)| ACC[31:0]
//    100   | rdacc.lo rd    | (read only)                       | ACC[31:0]
//    101   | rdacc.hi rd    | (read only)                       | ACC[63:32]
//    110   | rdacc.q15 rd   | (read only) Q30 -> Q15 conversion | sext(sat16(ACC>>>15))
//    111   | clracc rd      | ACC = 0, OVF = 0                  | 0
//
//   OVF is a sticky flag set whenever a signed operation saturates.
//   Writes to rd = x0 are suppressed (rd_we_o = 0), as in RISC-V.
//   Instructions with a different opcode or funct7 raise illegal_o and do
//   not modify the accumulator.
//
// Micro-architecture :
//
//            Stage 1 (EX1)                     Stage 2 (EX2 / WB)
//   instr -> decode ----------------> s1_* -> accumulate / saturate -> ACC
//   rs1   -> extend -> Booth 34x34 -> s1_prod                        -> rd_data_o
//   rs2   -> extend ->   multiplier
//
//   * Fully pipelined: one instruction may be issued every clock cycle.
//   * Fixed latency of 2 cycles from valid_i to valid_o.
//   * All accumulator reads and writes happen in stage 2, in program order,
//     so back-to-back dependent MAC / read instructions need no stalls or
//     forwarding.
//
// Ports :
//   clk_i, rst_ni     clock, active-low synchronous reset
//   valid_i           instruction + operands valid this cycle
//   instr_i[31:0]     32-bit RISC-V instruction word
//   rs1_i, rs2_i      register-file operand values for rs1 / rs2
//   ready_o           always 1 (unit never stalls)
//   valid_o           result valid (2 cycles after valid_i)
//   rd_addr_o         destination register index
//   rd_we_o           register-file write enable (0 for x0 / illegal)
//   rd_data_o         value to write to rd
//   illegal_o         instruction was not a valid MAC instruction
//   ovf_o             sticky saturation flag
//   acc_o             current accumulator value (debug / observability)
//============================================================================
`timescale 1ns/1ps

module mac_unit (
    input  wire        clk_i,
    input  wire        rst_ni,

    // Issue interface (from the core's decode/register-read stage)
    input  wire        valid_i,
    input  wire [31:0] instr_i,
    input  wire [31:0] rs1_i,
    input  wire [31:0] rs2_i,
    output wire        ready_o,

    // Write-back interface (to the core's register file)
    output reg         valid_o,
    output reg  [4:0]  rd_addr_o,
    output reg         rd_we_o,
    output reg  [31:0] rd_data_o,
    output reg         illegal_o,

    // Status / debug
    output reg         ovf_o,
    output reg  [63:0] acc_o
);

    //------------------------------------------------------------------------
    // Encoding constants
    //------------------------------------------------------------------------
    localparam [6:0] OPC_CUSTOM0 = 7'b0001011;   // RISC-V custom-0 opcode
    localparam [6:0] F7_MAC      = 7'b0000000;

    localparam [2:0] F3_MAC   = 3'b000;
    localparam [2:0] F3_MSU   = 3'b001;
    localparam [2:0] F3_MUL   = 3'b010;
    localparam [2:0] F3_MACU  = 3'b011;
    localparam [2:0] F3_RDLO  = 3'b100;
    localparam [2:0] F3_RDHI  = 3'b101;
    localparam [2:0] F3_RDQ15 = 3'b110;
    localparam [2:0] F3_CLR   = 3'b111;

    localparam signed [63:0] ACC_MAX = 64'sh7FFF_FFFF_FFFF_FFFF;
    localparam signed [63:0] ACC_MIN = 64'sh8000_0000_0000_0000;

    assign ready_o = 1'b1;   // fully pipelined, never back-pressures

    //========================================================================
    // STAGE 1 : decode + operand extension + Booth multiplication
    //========================================================================
    wire [6:0] opcode = instr_i[6:0];
    wire [4:0] rd     = instr_i[11:7];
    wire [2:0] funct3 = instr_i[14:12];
    wire [6:0] funct7 = instr_i[31:25];

    wire is_mac_instr = (opcode == OPC_CUSTOM0) && (funct7 == F7_MAC);

    // Unsigned multiply only for MACU; everything else is signed.
    wire is_unsigned = (funct3 == F3_MACU);

    // Extend the 32-bit operands to 34 bits (even width required by the
    // radix-4 Booth multiplier). Sign-extension gives a signed multiply,
    // zero-extension gives an unsigned multiply on the same hardware.
    wire [33:0] op_a = is_unsigned ? {2'b00, rs1_i} : {{2{rs1_i[31]}}, rs1_i};
    wire [33:0] op_b = is_unsigned ? {2'b00, rs2_i} : {{2{rs2_i[31]}}, rs2_i};

    // 34 x 34 -> 68-bit product. The true product always fits in 64 bits
    // (signed: |a*b| <= 2^62, unsigned: a*b < 2^64), so bits [63:0] are exact.
    wire signed [67:0] prod_full;

    booth_multiplier #(.W(34)) u_booth (
        .a_i (op_a),
        .b_i (op_b),
        .p_o (prod_full)
    );

    // Stage-1 pipeline registers
    reg        s1_valid;
    reg        s1_illegal;
    reg [2:0]  s1_funct3;
    reg [4:0]  s1_rd;
    reg [63:0] s1_prod;

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            s1_valid   <= 1'b0;
            s1_illegal <= 1'b0;
            s1_funct3  <= 3'b000;
            s1_rd      <= 5'd0;
            s1_prod    <= 64'd0;
        end else begin
            s1_valid   <= valid_i;
            s1_illegal <= valid_i & ~is_mac_instr;
            s1_funct3  <= funct3;
            s1_rd      <= rd;
            s1_prod    <= prod_full[63:0];
        end
    end

    //========================================================================
    // STAGE 2 : accumulate / saturate / read-out
    //========================================================================
    reg signed [63:0] acc_q;     // architectural accumulator
    reg               ovf_q;     // sticky overflow flag

    // 65-bit add / subtract so the carry into the sign position is visible.
    wire signed [64:0] acc_ext  = {acc_q[63], acc_q};
    wire signed [64:0] prod_ext = {s1_prod[63], s1_prod};
    wire signed [64:0] sum_add  = acc_ext + prod_ext;
    wire signed [64:0] sum_sub  = acc_ext - prod_ext;

    // Signed overflow <=> the two top bits of the 65-bit result disagree.
    wire ovf_add = sum_add[64] ^ sum_add[63];
    wire ovf_sub = sum_sub[64] ^ sum_sub[63];

    // Saturated results: clamp toward the sign of the true (65-bit) result.
    wire [63:0] sat_add = ovf_add ? (sum_add[64] ? ACC_MIN : ACC_MAX) : sum_add[63:0];
    wire [63:0] sat_sub = ovf_sub ? (sum_sub[64] ? ACC_MIN : ACC_MAX) : sum_sub[63:0];

    // Q30 -> Q15 conversion for rdacc.q15 (same as CMSIS-DSP:
    // __SSAT(acc >> 15, 16)): arithmetic shift, then saturate to int16.
    wire signed [63:0] acc_shr15 = acc_q >>> 15;
    wire [15:0] q15_val = (acc_shr15 >  64'sd32767) ? 16'h7FFF :
                          (acc_shr15 < -64'sd32768) ? 16'h8000 :
                                                      acc_shr15[15:0];

    // Next-state / result logic for stage 2
    reg [63:0] acc_nxt;
    reg        ovf_nxt;
    reg [31:0] res_nxt;

    always @* begin
        acc_nxt = acc_q;
        ovf_nxt = ovf_q;
        res_nxt = 32'd0;

        if (s1_valid && !s1_illegal) begin
            case (s1_funct3)
                F3_MAC: begin
                    acc_nxt = sat_add;
                    ovf_nxt = ovf_q | ovf_add;
                    res_nxt = sat_add[31:0];
                end
                F3_MSU: begin
                    acc_nxt = sat_sub;
                    ovf_nxt = ovf_q | ovf_sub;
                    res_nxt = sat_sub[31:0];
                end
                F3_MUL: begin
                    acc_nxt = s1_prod;          // start a new accumulation
                    ovf_nxt = 1'b0;
                    res_nxt = s1_prod[31:0];
                end
                F3_MACU: begin
                    acc_nxt = acc_q + s1_prod;  // modular, no saturation
                    res_nxt = acc_nxt[31:0];
                end
                F3_RDLO:  res_nxt = acc_q[31:0];
                F3_RDHI:  res_nxt = acc_q[63:32];
                F3_RDQ15: res_nxt = {{16{q15_val[15]}}, q15_val};
                F3_CLR: begin
                    acc_nxt = 64'd0;
                    ovf_nxt = 1'b0;
                    res_nxt = 32'd0;
                end
                default: ;
            endcase
        end
    end

    // Stage-2 registers: accumulator state and write-back outputs
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            acc_q     <= 64'd0;
            ovf_q     <= 1'b0;
            valid_o   <= 1'b0;
            rd_addr_o <= 5'd0;
            rd_we_o   <= 1'b0;
            rd_data_o <= 32'd0;
            illegal_o <= 1'b0;
        end else begin
            acc_q     <= acc_nxt;
            ovf_q     <= ovf_nxt;
            valid_o   <= s1_valid;
            rd_addr_o <= s1_rd;
            rd_we_o   <= s1_valid & ~s1_illegal & (s1_rd != 5'd0);
            rd_data_o <= res_nxt;
            illegal_o <= s1_illegal;
        end
    end

    // Status outputs mirror the architectural state
    always @* begin
        acc_o = acc_q;
        ovf_o = ovf_q;
    end

endmodule
