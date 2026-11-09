//============================================================================
// File        : rv32_core.v
// Module      : rv32_core
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
//   Classic 5-stage in-order pipelined RISC-V processor (RV32I + the
//   multiply subset of RV32M) with the MAC unit integrated as a custom-0
//   functional unit.
//
//       IF  ->  ID  ->  EX  ->  MEM  ->  WB
//                       |        |        ^
//                       +--MAC---+--MAC---+   (mac_unit stage 1 / stage 2)
//
//   * IF  : PC register, instruction memory read
//   * ID  : decode, immediate generation, register-file read, hazard unit
//   * EX  : forwarding muxes, ALU (incl. MUL/MULH/MULHSU/MULHU),
//           branch / jump resolution, MAC stage 1 (Booth multiply)
//   * MEM : data memory access (byte/half/word), MAC stage 2 (accumulate)
//   * WB  : register-file write-back (ALU / load / MAC result)
//
//   The two internal pipeline registers of mac_unit line up exactly with
//   the EX/MEM and MEM/WB registers of the core, so a MAC instruction flows
//   down the pipeline like any other instruction and writes back in WB.
//
//   Hazards
//   -------
//   * Data hazards : full forwarding from EX/MEM and MEM/WB into EX, plus
//                    write-first bypass of the register file in ID.
//   * Load-use and MAC-use : a load result (end of MEM) or a MAC result
//                    (end of MEM, out of mac_unit stage 2) is not ready for
//                    an instruction directly behind it, so the hazard unit
//                    inserts ONE bubble; the value is then forwarded from WB.
//   * Control      : branches and jumps resolve in EX; a taken branch
//                    flushes the two younger instructions (2-cycle penalty).
//   * ECALL / EBREAK stop instruction fetch; when the instruction reaches
//     WB the core halts (halted_o). An illegal instruction halts with
//     error_o = 1.
//
//   Supported instructions
//   ----------------------
//   RV32I : LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU LB LH LW LBU LHU
//           SB SH SW ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI ADD SUB
//           SLL SLT SLTU XOR SRL SRA OR AND FENCE(nop) ECALL EBREAK
//   RV32M : MUL MULH MULHSU MULHU   (divide instructions not implemented)
//   Xmac  : mac msu mul.acc macu rdacc.lo rdacc.hi rdacc.q15 clracc
//
// Ports :
//   clk_i, rst_ni        clock, active-low synchronous reset
//   imem_addr_o / imem_rdata_i                  instruction memory port
//   dmem_addr_o / dmem_wdata_o / dmem_be_o /
//   dmem_we_o / dmem_re_o / dmem_rdata_i        data memory port
//   halted_o, error_o    program finished (ECALL) / illegal instruction
//   *_cnt_o              performance counters for the testbench
//============================================================================
`timescale 1ns/1ps

module rv32_core (
    input  wire        clk_i,
    input  wire        rst_ni,

    // Instruction memory (combinational read)
    output wire [31:0] imem_addr_o,
    input  wire [31:0] imem_rdata_i,

    // Data memory (combinational read, synchronous write)
    output wire [31:0] dmem_addr_o,
    output reg  [31:0] dmem_wdata_o,
    output reg  [3:0]  dmem_be_o,
    output wire        dmem_we_o,
    output wire        dmem_re_o,
    input  wire [31:0] dmem_rdata_i,

    // Status
    output reg         halted_o,
    output reg         error_o,

    // Performance counters
    output reg  [31:0] cycle_cnt_o,
    output reg  [31:0] instret_cnt_o,
    output reg  [31:0] stall_cnt_o,
    output reg  [31:0] flush_cnt_o,
    output reg  [31:0] mac_cnt_o
);

    //------------------------------------------------------------------------
    // Encoding constants
    //------------------------------------------------------------------------
    localparam [6:0] OP_LUI    = 7'b0110111;
    localparam [6:0] OP_AUIPC  = 7'b0010111;
    localparam [6:0] OP_JAL    = 7'b1101111;
    localparam [6:0] OP_JALR   = 7'b1100111;
    localparam [6:0] OP_BRANCH = 7'b1100011;
    localparam [6:0] OP_LOAD   = 7'b0000011;
    localparam [6:0] OP_STORE  = 7'b0100011;
    localparam [6:0] OP_IMM    = 7'b0010011;
    localparam [6:0] OP_REG    = 7'b0110011;
    localparam [6:0] OP_FENCE  = 7'b0001111;
    localparam [6:0] OP_SYSTEM = 7'b1110011;
    localparam [6:0] OP_CUST0  = 7'b0001011;   // MAC unit

    // ALU operations
    localparam [3:0] ALU_ADD    = 4'd0;
    localparam [3:0] ALU_SUB    = 4'd1;
    localparam [3:0] ALU_SLL    = 4'd2;
    localparam [3:0] ALU_SLT    = 4'd3;
    localparam [3:0] ALU_SLTU   = 4'd4;
    localparam [3:0] ALU_XOR    = 4'd5;
    localparam [3:0] ALU_SRL    = 4'd6;
    localparam [3:0] ALU_SRA    = 4'd7;
    localparam [3:0] ALU_OR     = 4'd8;
    localparam [3:0] ALU_AND    = 4'd9;
    localparam [3:0] ALU_PASSB  = 4'd10;
    localparam [3:0] ALU_MUL    = 4'd11;
    localparam [3:0] ALU_MULH   = 4'd12;
    localparam [3:0] ALU_MULHSU = 4'd13;
    localparam [3:0] ALU_MULHU  = 4'd14;

    // ALU operand-A select
    localparam [1:0] A_RS1  = 2'd0;
    localparam [1:0] A_PC   = 2'd1;

    //========================================================================
    // Pipeline registers
    //========================================================================
    // IF
    reg [31:0] pc_q;
    reg        fetch_stop_q;          // set once ECALL has left ID

    // IF/ID
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // ID/EX
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [31:0] id_ex_rs1_val, id_ex_rs2_val, id_ex_imm;
    reg [3:0]  id_ex_alu_op;
    reg [1:0]  id_ex_a_sel;
    reg        id_ex_b_imm;
    reg        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_branch, id_ex_jal, id_ex_jalr;
    reg        id_ex_is_mac, id_ex_is_ecall, id_ex_illegal;

    // EX/MEM
    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc;
    reg [4:0]  ex_mem_rd;
    reg [31:0] ex_mem_result;          // ALU result or PC+4 (jumps)
    reg [31:0] ex_mem_store_data;
    reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_is_mac, ex_mem_is_ecall, ex_mem_illegal;

    // MEM/WB
    reg        mem_wb_valid;
    reg [31:0] mem_wb_pc;
    reg [4:0]  mem_wb_rd;
    reg [31:0] mem_wb_data;            // ALU result or load data
    reg        mem_wb_reg_write;
    reg        mem_wb_is_mac, mem_wb_is_ecall, mem_wb_illegal;

    // Register file
    reg [31:0] rf [0:31];

    //========================================================================
    // WB stage (declared first: its outputs feed ID bypass and forwarding)
    //========================================================================
    wire        mac_valid, mac_we, mac_illegal, mac_ovf;
    wire [4:0]  mac_rd;
    wire [31:0] mac_data;
    wire [63:0] mac_acc;

    wire        wb_we    = mem_wb_valid && !halted_o &&
                           (mem_wb_is_mac ? mac_we : mem_wb_reg_write) &&
                           (mem_wb_rd != 5'd0);
    wire [31:0] wb_value = mem_wb_is_mac ? mac_data : mem_wb_data;

    //========================================================================
    // IF stage
    //========================================================================
    assign imem_addr_o = pc_q;

    //========================================================================
    // ID stage: decode
    //========================================================================
    wire [31:0] instr  = if_id_instr;
    wire [6:0]  opcode = instr[6:0];
    wire [4:0]  rd     = instr[11:7];
    wire [2:0]  funct3 = instr[14:12];
    wire [4:0]  rs1    = instr[19:15];
    wire [4:0]  rs2    = instr[24:20];
    wire [6:0]  funct7 = instr[31:25];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    reg [31:0] d_imm;
    reg [3:0]  d_alu_op;
    reg [1:0]  d_a_sel;
    reg        d_b_imm;
    reg        d_reg_write, d_mem_read, d_mem_write;
    reg        d_branch, d_jal, d_jalr, d_is_mac, d_is_ecall, d_illegal;
    reg        d_uses_rs1, d_uses_rs2;

    always @* begin
        d_imm       = 32'd0;
        d_alu_op    = ALU_ADD;
        d_a_sel     = A_RS1;
        d_b_imm     = 1'b0;
        d_reg_write = 1'b0;
        d_mem_read  = 1'b0;
        d_mem_write = 1'b0;
        d_branch    = 1'b0;
        d_jal       = 1'b0;
        d_jalr      = 1'b0;
        d_is_mac    = 1'b0;
        d_is_ecall  = 1'b0;
        d_illegal   = 1'b0;
        d_uses_rs1  = 1'b0;
        d_uses_rs2  = 1'b0;

        case (opcode)
            OP_LUI: begin
                d_reg_write = 1'b1; d_alu_op = ALU_PASSB; d_b_imm = 1'b1; d_imm = imm_u;
            end
            OP_AUIPC: begin
                d_reg_write = 1'b1; d_a_sel = A_PC; d_b_imm = 1'b1; d_imm = imm_u;
            end
            OP_JAL: begin
                d_reg_write = 1'b1; d_jal = 1'b1; d_imm = imm_j;
            end
            OP_JALR: begin
                d_reg_write = 1'b1; d_jalr = 1'b1; d_imm = imm_i; d_uses_rs1 = 1'b1;
                d_illegal = (funct3 != 3'b000);
            end
            OP_BRANCH: begin
                d_branch = 1'b1; d_imm = imm_b; d_uses_rs1 = 1'b1; d_uses_rs2 = 1'b1;
                d_illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
            end
            OP_LOAD: begin
                d_reg_write = 1'b1; d_mem_read = 1'b1; d_b_imm = 1'b1; d_imm = imm_i;
                d_uses_rs1 = 1'b1;
                d_illegal = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
            end
            OP_STORE: begin
                d_mem_write = 1'b1; d_b_imm = 1'b1; d_imm = imm_s;
                d_uses_rs1 = 1'b1; d_uses_rs2 = 1'b1;
                d_illegal = (funct3[2] == 1'b1) || (funct3 == 3'b011);
            end
            OP_IMM: begin
                d_reg_write = 1'b1; d_b_imm = 1'b1; d_imm = imm_i; d_uses_rs1 = 1'b1;
                case (funct3)
                    3'b000: d_alu_op = ALU_ADD;
                    3'b010: d_alu_op = ALU_SLT;
                    3'b011: d_alu_op = ALU_SLTU;
                    3'b100: d_alu_op = ALU_XOR;
                    3'b110: d_alu_op = ALU_OR;
                    3'b111: d_alu_op = ALU_AND;
                    3'b001: begin
                        d_alu_op = ALU_SLL; d_illegal = (funct7 != 7'b0000000);
                    end
                    3'b101: begin
                        d_alu_op  = funct7[5] ? ALU_SRA : ALU_SRL;
                        d_illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
                    end
                endcase
            end
            OP_REG: begin
                d_reg_write = 1'b1; d_uses_rs1 = 1'b1; d_uses_rs2 = 1'b1;
                if (funct7 == 7'b0000001) begin            // RV32M (multiply only)
                    case (funct3)
                        3'b000:  d_alu_op = ALU_MUL;
                        3'b001:  d_alu_op = ALU_MULH;
                        3'b010:  d_alu_op = ALU_MULHSU;
                        3'b011:  d_alu_op = ALU_MULHU;
                        default: d_illegal = 1'b1;          // DIV/REM not implemented
                    endcase
                end else if (funct7 == 7'b0000000) begin
                    case (funct3)
                        3'b000: d_alu_op = ALU_ADD;
                        3'b001: d_alu_op = ALU_SLL;
                        3'b010: d_alu_op = ALU_SLT;
                        3'b011: d_alu_op = ALU_SLTU;
                        3'b100: d_alu_op = ALU_XOR;
                        3'b101: d_alu_op = ALU_SRL;
                        3'b110: d_alu_op = ALU_OR;
                        3'b111: d_alu_op = ALU_AND;
                    endcase
                end else if (funct7 == 7'b0100000 && funct3 == 3'b000) begin
                    d_alu_op = ALU_SUB;
                end else if (funct7 == 7'b0100000 && funct3 == 3'b101) begin
                    d_alu_op = ALU_SRA;
                end else begin
                    d_illegal = 1'b1;
                end
            end
            OP_CUST0: begin
                // MAC unit decodes funct3/funct7 itself; only multiply-type
                // operations (funct3[2] = 0) read rs1/rs2.
                d_is_mac    = 1'b1;
                d_reg_write = 1'b1;
                d_uses_rs1  = ~funct3[2];
                d_uses_rs2  = ~funct3[2];
            end
            OP_FENCE: ;                                     // no-op
            OP_SYSTEM: begin
                if (instr == 32'h0000_0073 || instr == 32'h0010_0073)
                    d_is_ecall = 1'b1;                      // ECALL / EBREAK
                else
                    d_illegal = 1'b1;                       // CSRs not implemented
            end
            default: d_illegal = 1'b1;
        endcase
    end

    // Register-file read with write-first bypass from WB
    wire [31:0] rs1_val = (rs1 == 5'd0) ? 32'd0 :
                          (wb_we && mem_wb_rd == rs1) ? wb_value : rf[rs1];
    wire [31:0] rs2_val = (rs2 == 5'd0) ? 32'd0 :
                          (wb_we && mem_wb_rd == rs2) ? wb_value : rf[rs2];

    //------------------------------------------------------------------------
    // Hazard detection unit: load-use / MAC-use => one bubble
    //------------------------------------------------------------------------
    wire ex_is_late = id_ex_valid && (id_ex_mem_read || id_ex_is_mac) && (id_ex_rd != 5'd0);
    wire stall = if_id_valid && ex_is_late &&
                 ((d_uses_rs1 && rs1 == id_ex_rd) || (d_uses_rs2 && rs2 == id_ex_rd));

    //========================================================================
    // EX stage
    //========================================================================
    // Forwarding unit. EX/MEM can forward only ALU/jump results; load and
    // MAC results are forwarded from MEM/WB (the stall guarantees this).
    wire fwd_a_mem = ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read &&
                     !ex_mem_is_mac && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1);
    wire fwd_b_mem = ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read &&
                     !ex_mem_is_mac && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2);
    wire fwd_a_wb  = wb_we && (mem_wb_rd == id_ex_rs1);
    wire fwd_b_wb  = wb_we && (mem_wb_rd == id_ex_rs2);

    wire [31:0] fwd_a = fwd_a_mem ? ex_mem_result : fwd_a_wb ? wb_value : id_ex_rs1_val;
    wire [31:0] fwd_b = fwd_b_mem ? ex_mem_result : fwd_b_wb ? wb_value : id_ex_rs2_val;

    wire [31:0] alu_a = (id_ex_a_sel == A_PC) ? id_ex_pc : fwd_a;
    wire [31:0] alu_b = id_ex_b_imm ? id_ex_imm : fwd_b;

    // One shared 33x33 signed multiplier for all RV32M multiply variants:
    // each operand gets a 33rd bit that is its sign (signed operand) or 0
    // (unsigned operand). MUL uses the low word, MULH* the high word.
    wire mul_a_signed = (id_ex_alu_op == ALU_MULH) || (id_ex_alu_op == ALU_MULHSU);
    wire mul_b_signed = (id_ex_alu_op == ALU_MULH);
    wire signed [32:0] mul_a = {mul_a_signed & alu_a[31], alu_a};
    wire signed [32:0] mul_b = {mul_b_signed & alu_b[31], alu_b};
    wire signed [65:0] mul_p = mul_a * mul_b;

    reg [31:0] alu_out;
    always @* begin
        case (id_ex_alu_op)
            ALU_ADD:    alu_out = alu_a + alu_b;
            ALU_SUB:    alu_out = alu_a - alu_b;
            ALU_SLL:    alu_out = alu_a << alu_b[4:0];
            ALU_SLT:    alu_out = {31'd0, $signed(alu_a) < $signed(alu_b)};
            ALU_SLTU:   alu_out = {31'd0, alu_a < alu_b};
            ALU_XOR:    alu_out = alu_a ^ alu_b;
            ALU_SRL:    alu_out = alu_a >> alu_b[4:0];
            ALU_SRA:    alu_out = $signed(alu_a) >>> alu_b[4:0];
            ALU_OR:     alu_out = alu_a | alu_b;
            ALU_AND:    alu_out = alu_a & alu_b;
            ALU_PASSB:  alu_out = alu_b;
            ALU_MUL:    alu_out = mul_p[31:0];
            ALU_MULH:   alu_out = mul_p[63:32];
            ALU_MULHSU: alu_out = mul_p[63:32];
            ALU_MULHU:  alu_out = mul_p[63:32];
            default:    alu_out = 32'd0;
        endcase
    end

    // Branch / jump resolution
    reg br_cond;
    always @* begin
        case (id_ex_funct3)
            3'b000:  br_cond = (fwd_a == fwd_b);                    // BEQ
            3'b001:  br_cond = (fwd_a != fwd_b);                    // BNE
            3'b100:  br_cond = ($signed(fwd_a) <  $signed(fwd_b));  // BLT
            3'b101:  br_cond = ($signed(fwd_a) >= $signed(fwd_b));  // BGE
            3'b110:  br_cond = (fwd_a <  fwd_b);                    // BLTU
            3'b111:  br_cond = (fwd_a >= fwd_b);                    // BGEU
            default: br_cond = 1'b0;
        endcase
    end

    wire        ex_taken  = id_ex_valid && ((id_ex_branch && br_cond) || id_ex_jal || id_ex_jalr);
    wire [31:0] ex_target = id_ex_jalr ? ((fwd_a + id_ex_imm) & ~32'd1) : (id_ex_pc + id_ex_imm);
    wire [31:0] ex_result = (id_ex_jal || id_ex_jalr) ? (id_ex_pc + 32'd4) : alu_out;

    //------------------------------------------------------------------------
    // MAC unit: stage 1 in EX, stage 2 in MEM, result in WB
    //------------------------------------------------------------------------
    mac_unit u_mac (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .valid_i   (id_ex_valid && id_ex_is_mac),
        .instr_i   (id_ex_instr),
        .rs1_i     (fwd_a),
        .rs2_i     (fwd_b),
        .ready_o   (),
        .valid_o   (mac_valid),
        .rd_addr_o (mac_rd),
        .rd_we_o   (mac_we),
        .rd_data_o (mac_data),
        .illegal_o (mac_illegal),
        .ovf_o     (mac_ovf),
        .acc_o     (mac_acc)
    );

    //========================================================================
    // MEM stage
    //========================================================================
    wire [1:0] byte_off = ex_mem_result[1:0];

    assign dmem_addr_o = ex_mem_result;
    assign dmem_we_o   = ex_mem_valid && ex_mem_mem_write && !halted_o;
    assign dmem_re_o   = ex_mem_valid && ex_mem_mem_read;

    // Store data alignment and byte enables
    always @* begin
        case (ex_mem_funct3[1:0])
            2'b00: begin                                    // SB
                dmem_wdata_o = {4{ex_mem_store_data[7:0]}};
                dmem_be_o    = 4'b0001 << byte_off;
            end
            2'b01: begin                                    // SH
                dmem_wdata_o = {2{ex_mem_store_data[15:0]}};
                dmem_be_o    = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin                                  // SW
                dmem_wdata_o = ex_mem_store_data;
                dmem_be_o    = 4'b1111;
            end
        endcase
    end

    // Load data extraction and sign/zero extension
    wire [31:0] ld_shifted = dmem_rdata_i >> {byte_off, 3'b000};
    reg  [31:0] load_data;
    always @* begin
        case (ex_mem_funct3)
            3'b000:  load_data = {{24{ld_shifted[7]}},  ld_shifted[7:0]};   // LB
            3'b001:  load_data = {{16{ld_shifted[15]}}, ld_shifted[15:0]};  // LH
            3'b100:  load_data = {24'd0, ld_shifted[7:0]};                  // LBU
            3'b101:  load_data = {16'd0, ld_shifted[15:0]};                 // LHU
            default: load_data = dmem_rdata_i;                              // LW
        endcase
    end

    //========================================================================
    // Sequential logic: pipeline registers
    //========================================================================
    wire id_leaves_ecall = if_id_valid && d_is_ecall && !stall && !ex_taken;

    // IF: program counter
    always @(posedge clk_i) begin
        if (!rst_ni)                       pc_q <= 32'd0;
        else if (ex_taken)                 pc_q <= ex_target;
        else if (stall || fetch_stop_q ||
                 id_leaves_ecall)          pc_q <= pc_q;
        else                               pc_q <= pc_q + 32'd4;
    end

    always @(posedge clk_i) begin
        if (!rst_ni)              fetch_stop_q <= 1'b0;
        else if (id_leaves_ecall) fetch_stop_q <= 1'b1;
    end

    // IF/ID
    always @(posedge clk_i) begin
        if (!rst_ni || ex_taken) begin
            if_id_valid <= 1'b0;
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h0000_0013;                   // NOP
        end else if (stall) begin
            // hold
        end else if (fetch_stop_q || id_leaves_ecall) begin
            if_id_valid <= 1'b0;
        end else begin
            if_id_valid <= 1'b1;
            if_id_pc    <= pc_q;
            if_id_instr <= imem_rdata_i;
        end
    end

    // ID/EX (bubble on reset, flush, stall or empty ID)
    always @(posedge clk_i) begin
        if (!rst_ni || ex_taken || stall || !if_id_valid) begin
            id_ex_valid     <= 1'b0;
            id_ex_reg_write <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_branch    <= 1'b0;
            id_ex_jal       <= 1'b0;
            id_ex_jalr      <= 1'b0;
            id_ex_is_mac    <= 1'b0;
            id_ex_is_ecall  <= 1'b0;
            id_ex_illegal   <= 1'b0;
            id_ex_rd        <= 5'd0;
            id_ex_rs1       <= 5'd0;
            id_ex_rs2       <= 5'd0;
            id_ex_pc        <= if_id_pc;
            id_ex_instr     <= 32'h0000_0013;
        end else begin
            id_ex_valid     <= 1'b1;
            id_ex_pc        <= if_id_pc;
            id_ex_instr     <= if_id_instr;
            id_ex_rs1       <= d_uses_rs1 ? rs1 : 5'd0;
            id_ex_rs2       <= d_uses_rs2 ? rs2 : 5'd0;
            id_ex_rd        <= rd;
            id_ex_rs1_val   <= rs1_val;
            id_ex_rs2_val   <= rs2_val;
            id_ex_imm       <= d_imm;
            id_ex_alu_op    <= d_alu_op;
            id_ex_a_sel     <= d_a_sel;
            id_ex_b_imm     <= d_b_imm;
            id_ex_reg_write <= d_reg_write;
            id_ex_mem_read  <= d_mem_read;
            id_ex_mem_write <= d_mem_write;
            id_ex_funct3    <= funct3;
            id_ex_branch    <= d_branch;
            id_ex_jal       <= d_jal;
            id_ex_jalr      <= d_jalr;
            id_ex_is_mac    <= d_is_mac;
            id_ex_is_ecall  <= d_is_ecall;
            id_ex_illegal   <= d_illegal;
        end
    end

    // EX/MEM
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            ex_mem_valid      <= 1'b0;
            ex_mem_reg_write  <= 1'b0;
            ex_mem_mem_read   <= 1'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_is_mac     <= 1'b0;
            ex_mem_is_ecall   <= 1'b0;
            ex_mem_illegal    <= 1'b0;
            ex_mem_rd         <= 5'd0;
            ex_mem_pc         <= 32'd0;
            ex_mem_result     <= 32'd0;
            ex_mem_store_data <= 32'd0;
            ex_mem_funct3     <= 3'd0;
        end else begin
            ex_mem_valid      <= id_ex_valid;
            ex_mem_pc         <= id_ex_pc;
            ex_mem_rd         <= id_ex_rd;
            ex_mem_result     <= ex_result;
            ex_mem_store_data <= fwd_b;
            ex_mem_reg_write  <= id_ex_valid & id_ex_reg_write;
            ex_mem_mem_read   <= id_ex_valid & id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_valid & id_ex_mem_write;
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_is_mac     <= id_ex_valid & id_ex_is_mac;
            ex_mem_is_ecall   <= id_ex_valid & id_ex_is_ecall;
            ex_mem_illegal    <= id_ex_valid & id_ex_illegal;
        end
    end

    // MEM/WB
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            mem_wb_valid     <= 1'b0;
            mem_wb_reg_write <= 1'b0;
            mem_wb_is_mac    <= 1'b0;
            mem_wb_is_ecall  <= 1'b0;
            mem_wb_illegal   <= 1'b0;
            mem_wb_rd        <= 5'd0;
            mem_wb_pc        <= 32'd0;
            mem_wb_data      <= 32'd0;
        end else begin
            mem_wb_valid     <= ex_mem_valid;
            mem_wb_pc        <= ex_mem_pc;
            mem_wb_rd        <= ex_mem_rd;
            mem_wb_data      <= ex_mem_mem_read ? load_data : ex_mem_result;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_is_mac    <= ex_mem_is_mac;
            mem_wb_is_ecall  <= ex_mem_is_ecall;
            mem_wb_illegal   <= ex_mem_illegal;
        end
    end

    // WB: register file write (x0 is never written). The register file has
    // no reset, as in most RISC-V cores, so synthesis can map it to RAM;
    // programs initialise every register before reading it.
    always @(posedge clk_i) begin
        if (wb_we) rf[mem_wb_rd] <= wb_value;
    end

    // Halt on ECALL/EBREAK or illegal instruction reaching WB
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            halted_o <= 1'b0;
            error_o  <= 1'b0;
        end else if (mem_wb_valid && !halted_o) begin
            if (mem_wb_is_ecall) halted_o <= 1'b1;
            if (mem_wb_illegal || (mem_wb_is_mac && mac_illegal)) begin
                halted_o <= 1'b1;
                error_o  <= 1'b1;
            end
        end
    end

    // Performance counters
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            cycle_cnt_o   <= 32'd0;
            instret_cnt_o <= 32'd0;
            stall_cnt_o   <= 32'd0;
            flush_cnt_o   <= 32'd0;
            mac_cnt_o     <= 32'd0;
        end else if (!halted_o) begin
            cycle_cnt_o <= cycle_cnt_o + 32'd1;
            if (mem_wb_valid)                 instret_cnt_o <= instret_cnt_o + 32'd1;
            if (stall)                        stall_cnt_o   <= stall_cnt_o + 32'd1;
            if (ex_taken)                     flush_cnt_o   <= flush_cnt_o + 32'd1;
            if (mem_wb_valid && mem_wb_is_mac) mac_cnt_o    <= mac_cnt_o + 32'd1;
        end
    end

endmodule
