//============================================================================
// File        : riscv_soc.v
// Module      : riscv_soc
// Project     : Design and Verification of a RISC-V Multiply-Accumulate (MAC)
//               Unit for Digital Signal Processing
// Language    : Verilog-2005
// Authors     : Mohsin Mushtaq (2025MECECS001)
//               Mubashir Karim Ganaie (2025MECECS005)
// Supervisor  : Dr. Afshan Amin Khan
// Institution : Department of Electronics and Communications,
//               National Institute of Technology Srinagar
//
// Description :
//   Minimal system-on-chip: rv32_core (with the integrated MAC unit) plus a
//   Harvard instruction memory and a byte-enabled data memory.
//
//   Memory map (as seen by programs):
//     0x0000_0000 ... 0x0000_0FFF   instruction memory (IMEM_WORDS words)
//     0x0001_0000 ... 0x0001_3FFF   data memory        (DMEM_WORDS words)
//
//   Both memories have combinational read; the data memory writes on the
//   rising clock edge using per-byte enables. The memories are initialised
//   by the testbench with $readmemh (program and data images produced by
//   sw/build.py).
//============================================================================
`timescale 1ns/1ps

module riscv_soc #(
    parameter integer IMEM_WORDS = 1024,     // 4 KiB
    parameter integer DMEM_WORDS = 4096      // 16 KiB
) (
    input  wire clk_i,
    input  wire rst_ni,
    output wire halted_o,
    output wire error_o
);

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_we, dmem_re;
    wire [31:0] cycle_cnt, instret_cnt, stall_cnt, flush_cnt, mac_cnt;

    rv32_core u_core (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .imem_addr_o   (imem_addr),
        .imem_rdata_i  (imem_rdata),
        .dmem_addr_o   (dmem_addr),
        .dmem_wdata_o  (dmem_wdata),
        .dmem_be_o     (dmem_be),
        .dmem_we_o     (dmem_we),
        .dmem_re_o     (dmem_re),
        .dmem_rdata_i  (dmem_rdata),
        .halted_o      (halted_o),
        .error_o       (error_o),
        .cycle_cnt_o   (cycle_cnt),
        .instret_cnt_o (instret_cnt),
        .stall_cnt_o   (stall_cnt),
        .flush_cnt_o   (flush_cnt),
        .mac_cnt_o     (mac_cnt)
    );

    //------------------------------------------------------------------------
    // Instruction memory (ROM image loaded by the testbench)
    //------------------------------------------------------------------------
    reg [31:0] imem [0:IMEM_WORDS-1];
    assign imem_rdata = imem[imem_addr[$clog2(IMEM_WORDS)+1:2]];

    //------------------------------------------------------------------------
    // Data memory (word array, byte write enables)
    //------------------------------------------------------------------------
    reg [31:0] dmem [0:DMEM_WORDS-1];
    wire [$clog2(DMEM_WORDS)-1:0] d_idx = dmem_addr[$clog2(DMEM_WORDS)+1:2];

    assign dmem_rdata = dmem[d_idx];

    always @(posedge clk_i) begin
        if (dmem_we) begin
            if (dmem_be[0]) dmem[d_idx][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) dmem[d_idx][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) dmem[d_idx][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) dmem[d_idx][31:24] <= dmem_wdata[31:24];
        end
    end

endmodule
