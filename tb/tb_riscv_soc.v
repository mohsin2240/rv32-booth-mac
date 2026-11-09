//============================================================================
// File        : tb_riscv_soc.v
// Module      : tb_riscv_soc
// Project     : Design and Verification of a RISC-V Multiply-Accumulate (MAC)
//               Unit for Digital Signal Processing
// Language    : Verilog-2005 (simulation only)
// Authors     : Mohsin Mushtaq (2025MECECS001)
//               Mubashir Karim Ganaie (2025MECECS005)
// Supervisor  : Dr. Afshan Amin Khan
// Institution : Department of Electronics and Communications,
//               National Institute of Technology Srinagar
//
// Description :
//   System-level testbench: runs a real RISC-V program on riscv_soc
//   (5-stage rv32_core + integrated MAC unit + memories) and checks it.
//
//   Plusargs
//     +IMEM=<file>     program image ($readmemh, 32-bit words)   [required]
//     +DMEM=<file>     data image                                 [optional]
//     +GOLDEN=<file>   expected Q15 outputs (16-bit per line)     [optional]
//     +YADDR=<hex>     byte address of the output array y[]
//     +NOUT=<n>        number of outputs to compare
//     +YOUT=<file>     write the outputs produced by the CPU
//     +TRACE=<file>    per-cycle pipeline trace (CSV)
//     +VCD=<file>      waveform dump
//     +NAME=<string>   program name used in the RESULT line
//
//   Checks performed
//     * the core halts on ECALL within the cycle budget, without an
//       illegal-instruction error
//     * a0 (x10) == 0x600D  (self-checking programs signal success)
//     * every output sample y[n] == golden[n]   (bit-exact)
//     * on every MAC write-back the MAC unit's valid / rd outputs line up
//       with the core's MEM/WB pipeline register (integration check)
//
//   The final 'RESULT ...' line is parsed by sw/run_cpu_sims.py.
//============================================================================
`timescale 1ns/1ps

module tb_riscv_soc;

    localparam integer CLK_PERIOD = 10;
    localparam integer IMEM_WORDS = 1024;
    localparam integer DMEM_WORDS = 4096;

    reg clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    wire halted, error;

    riscv_soc #(.IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS)) dut (
        .clk_i    (clk),
        .rst_ni   (rst_n),
        .halted_o (halted),
        .error_o  (error)
    );

    `define CORE dut.u_core

    //------------------------------------------------------------------------
    // Plusargs and bookkeeping
    //------------------------------------------------------------------------
    reg [8*512-1:0] f_imem, f_dmem, f_golden, f_yout, f_trace, f_vcd;
    reg [8*64-1:0]  name;
    integer yaddr, nout, max_cycles;
    integer have_golden, have_yout;
    integer trace_fd, yout_fd;
    integer i, errs, align_errs, timeout;
    reg [15:0] golden [0:4095];
    reg [15:0] yv;
    reg [31:0] word, a0;

    // Read a 16-bit value from the data memory (byte address)
    function [15:0] dmem_half;
        input [31:0] addr;
        reg [31:0] w;
        begin
            w = dut.dmem[addr[13:2]];
            dmem_half = addr[1] ? w[31:16] : w[15:0];
        end
    endfunction

    //------------------------------------------------------------------------
    // Integration check: MAC unit output aligned with MEM/WB register
    //------------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && !halted && `CORE.mem_wb_valid && `CORE.mem_wb_is_mac) begin
            if (!(`CORE.mac_valid && `CORE.mac_rd == `CORE.mem_wb_rd)) begin
                align_errs = align_errs + 1;
                $display("  [FAIL] MAC write-back misaligned at pc=%08h", `CORE.mem_wb_pc);
            end
        end
    end

    //------------------------------------------------------------------------
    // Pipeline trace: one CSV line per clock cycle (sampled mid-cycle)
    //   cycle, IF pc, ID v/pc, EX v/pc, MEM v/pc, WB v/pc,
    //   stall, flush, fwdA(EX/MEM,WB), fwdB(EX/MEM,WB), mac_in_EX
    //------------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && trace_fd != 0 && !halted) begin
            $fwrite(trace_fd, "%0d,%0h,%0d,%0d,%0h,%0d,%0h,%0d,%0h,%0d,%0h,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    `CORE.cycle_cnt_o,
                    `CORE.pc_q, `CORE.fetch_stop_q,
                    `CORE.if_id_valid,  `CORE.if_id_pc,
                    `CORE.id_ex_valid,  `CORE.id_ex_pc,
                    `CORE.ex_mem_valid, `CORE.ex_mem_pc,
                    `CORE.mem_wb_valid, `CORE.mem_wb_pc,
                    `CORE.stall, `CORE.ex_taken,
                    `CORE.fwd_a_mem, `CORE.fwd_a_wb, `CORE.fwd_b_mem, `CORE.fwd_b_wb,
                    `CORE.id_ex_valid & `CORE.id_ex_is_mac);
        end
    end

    //------------------------------------------------------------------------
    // Main sequence
    //------------------------------------------------------------------------
    initial begin
        errs = 0; align_errs = 0; timeout = 0;
        name = "program";
        void_args;

        // memories: NOP-filled program, zeroed data
        for (i = 0; i < IMEM_WORDS; i = i + 1) dut.imem[i] = 32'h0000_0013;
        for (i = 0; i < DMEM_WORDS; i = i + 1) dut.dmem[i] = 32'h0000_0000;
        $readmemh(f_imem, dut.imem);
        if ($value$plusargs("DMEM=%s", f_dmem)) $readmemh(f_dmem, dut.dmem);
        if (have_golden) $readmemh(f_golden, golden, 0, nout-1);

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;

        // run until ECALL / error / timeout
        while (!halted && !timeout) begin
            @(posedge clk);
            if (`CORE.cycle_cnt_o >= max_cycles) timeout = 1;
        end
        @(negedge clk);

        a0 = `CORE.rf[10];
        $display("====================================================================");
        $display(" RISC-V SoC simulation : %0s", name);
        $display("====================================================================");
        $display("  halted=%0d  error=%0d  timeout=%0d  a0=0x%08h %s",
                 halted, error, timeout, a0, (a0 == 32'h600D) ? "(PASS code)" : "(FAIL code)");
        $display("  cycles            : %0d", `CORE.cycle_cnt_o);
        $display("  instructions      : %0d", `CORE.instret_cnt_o);
        $display("  CPI               : %0.3f", `CORE.cycle_cnt_o * 1.0 / `CORE.instret_cnt_o);
        $display("  load/MAC-use stalls: %0d", `CORE.stall_cnt_o);
        $display("  taken branch flushes: %0d", `CORE.flush_cnt_o);
        $display("  MAC instructions  : %0d", `CORE.mac_cnt_o);

        if (have_golden) begin
            $display("  --- output check: %0d samples at 0x%08h ---", nout, yaddr);
            $display("     n |  y (CPU) | y (golden)");
            for (i = 0; i < nout; i = i + 1) begin
                yv = dmem_half(yaddr + 2*i);
                if (yv !== golden[i]) begin
                    errs = errs + 1;
                    if (errs <= 10)
                        $display("  [FAIL] y[%0d] = %0d, expected %0d", i, $signed(yv), $signed(golden[i]));
                end
                if (i < 8 || i == nout-1)
                    $display("   %3d | %8d | %8d", i, $signed(yv), $signed(golden[i]));
                if (have_yout) $fwrite(yout_fd, "%0d\n", $signed(yv));
            end
            $display("  output mismatches : %0d / %0d", errs, nout);
        end
        if (align_errs) $display("  MAC alignment errors: %0d", align_errs);

        if (halted && !error && !timeout && a0 == 32'h600D && errs == 0 && align_errs == 0)
            $display("  >>> PASS <<<");
        else
            $display("  >>> FAIL <<<");

        $display("RESULT name=%0s status=%0s cycles=%0d instret=%0d stalls=%0d flushes=%0d macs=%0d a0=%0h errors=%0d",
                 name,
                 (halted && !error && !timeout && a0 == 32'h600D && errs == 0 && align_errs == 0) ? "PASS" : "FAIL",
                 `CORE.cycle_cnt_o, `CORE.instret_cnt_o, `CORE.stall_cnt_o,
                 `CORE.flush_cnt_o, `CORE.mac_cnt_o, a0, errs + align_errs);

        if (trace_fd) $fclose(trace_fd);
        if (have_yout) $fclose(yout_fd);
        $finish;
    end

    // Parse plusargs (kept in a task so the initial block stays readable)
    task void_args;
        begin
            if (!$value$plusargs("IMEM=%s", f_imem)) begin
                $display("ERROR: +IMEM=<file> is required");
                $finish;
            end
            if (!$value$plusargs("NAME=%s", name)) name = "program";
            have_golden = $value$plusargs("GOLDEN=%s", f_golden);
            if (!$value$plusargs("YADDR=%h", yaddr)) yaddr = 0;
            if (!$value$plusargs("NOUT=%d", nout)) nout = 0;
            if (!$value$plusargs("MAXCYCLES=%d", max_cycles)) max_cycles = 500000;
            have_yout = $value$plusargs("YOUT=%s", f_yout);
            if (have_yout) yout_fd = $fopen(f_yout, "w");
            trace_fd = 0;
            if ($value$plusargs("TRACE=%s", f_trace)) trace_fd = $fopen(f_trace, "w");
            if ($value$plusargs("VCD=%s", f_vcd)) begin
                $dumpfile(f_vcd);
                $dumpvars(0, tb_riscv_soc);
            end
        end
    endtask

endmodule
