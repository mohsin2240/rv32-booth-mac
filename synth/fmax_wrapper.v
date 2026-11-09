//============================================================================
// File        : fmax_wrapper.v
// Module      : mac_unit_fmax_wrapper  (synthesis / timing only)
//
// Description :
//   Registers every input and output of mac_unit so that, after place and
//   route, all timing paths are register-to-register. This models the real
//   environment inside a RISC-V core, where rs1/rs2 come from the register
//   file / ID-EX pipeline register, and excludes FPGA I/O pad delays from
//   the reported maximum frequency. Not part of the verified design.
//============================================================================
`timescale 1ns/1ps

module mac_unit_fmax_wrapper (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        valid_i,
    input  wire [31:0] instr_i,
    input  wire [31:0] rs1_i,
    input  wire [31:0] rs2_i,
    output reg         valid_o,
    output reg  [4:0]  rd_addr_o,
    output reg         rd_we_o,
    output reg  [31:0] rd_data_o,
    output reg         illegal_o,
    output reg         ovf_o,
    output reg  [63:0] acc_o
);
    // input registers (ID/EX pipeline register of the host core)
    reg        valid_q;
    reg [31:0] instr_q, rs1_q, rs2_q;

    wire        valid_w, rd_we_w, illegal_w, ovf_w, ready_w;
    wire [4:0]  rd_addr_w;
    wire [31:0] rd_data_w;
    wire [63:0] acc_w;

    always @(posedge clk_i) begin
        valid_q <= valid_i;
        instr_q <= instr_i;
        rs1_q   <= rs1_i;
        rs2_q   <= rs2_i;
    end

    mac_unit u_mac (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(valid_q), .instr_i(instr_q), .rs1_i(rs1_q), .rs2_i(rs2_q),
        .ready_o(ready_w),
        .valid_o(valid_w), .rd_addr_o(rd_addr_w), .rd_we_o(rd_we_w),
        .rd_data_o(rd_data_w), .illegal_o(illegal_w),
        .ovf_o(ovf_w), .acc_o(acc_w)
    );

    // output registers (register-file write port of the host core)
    always @(posedge clk_i) begin
        valid_o   <= valid_w;
        rd_addr_o <= rd_addr_w;
        rd_we_o   <= rd_we_w;
        rd_data_o <= rd_data_w;
        illegal_o <= illegal_w;
        ovf_o     <= ovf_w;
        acc_o     <= acc_w;
    end
endmodule
