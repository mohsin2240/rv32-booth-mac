//============================================================================
// File        : tb_mac_unit.v
// Module      : tb_mac_unit
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
//   Self-checking testbench for mac_unit.
//
//   Verification architecture
//   -------------------------
//
//     +-----------+  instr/rs1/rs2  +-----------+  rd/data/acc/ovf  +---------+
//     | stimulus  |---------------->|  DUT      |------------------>| monitor |
//     | (tasks)   |                 | mac_unit  |                   | checker |
//     +-----------+                 +-----------+                   +---------+
//           |                                                            ^
//           |   +-----------------------+    expected results (FIFO)     |
//           +-->| reference model       |--------------------------------+
//               | (behavioural, 128-bit)|
//               +-----------------------+
//
//   * The reference model is written independently of the RTL: it uses the
//     simulator's native '*' operator (not Booth) and 128-bit arithmetic
//     with explicit range comparisons for saturation (not carry/sign-bit
//     overflow detection like the RTL).
//   * For every issued instruction the expected rd value, rd address,
//     write-enable, illegal flag, accumulator and overflow flag are pushed
//     into a scoreboard FIFO; the monitor pops and compares ALL of them on
//     every valid_o, and also checks the 2-cycle latency.
//
//   Test plan
//   ---------
//     T1  Reset state
//     T2  Basic MUL / MAC / MSU arithmetic (small signed values)
//     T3  Sign combinations (+*+, +*-, -*+, -*-)
//     T4  Extreme operands (INT32_MAX, INT32_MIN) and 64-bit results
//     T5  Positive / negative saturation of the 64-bit accumulator + OVF
//     T6  Unsigned MACU (modular), sum of squares benchmark
//     T7  rd = x0 (write suppressed, accumulator still updated)
//     T8  Illegal instruction detection
//     T9  Q15 fixed-point read-out incl. the -1.0 * -1.0 corner case
//     T10 DSP benchmark : dot product [1..8].[8..1] = 120
//     T11 DSP benchmark : 8-tap moving-average FIR, step response
//     T12 DSP benchmark : 8-tap triangular low-pass FIR, DC + Nyquist tone
//     T13 Constrained-random regression (back-to-back + bubbles + illegal)
//
//   Outputs: PASS/FAIL lines on the terminal, a summary with functional
//   coverage counters, and a VCD waveform file (mac_unit.vcd).
//============================================================================
`timescale 1ns/1ps

module tb_mac_unit;

    //------------------------------------------------------------------------
    // Clock (100 MHz) and reset
    //------------------------------------------------------------------------
    localparam integer CLK_PERIOD = 10;

    reg clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;

    //------------------------------------------------------------------------
    // DUT interface
    //------------------------------------------------------------------------
    reg         valid_i;
    reg  [31:0] instr_i;
    reg  [31:0] rs1_i;
    reg  [31:0] rs2_i;
    wire        ready_o;
    wire        valid_o;
    wire [4:0]  rd_addr_o;
    wire        rd_we_o;
    wire [31:0] rd_data_o;
    wire        illegal_o;
    wire        ovf_o;
    wire [63:0] acc_o;

    mac_unit dut (
        .clk_i     (clk),
        .rst_ni    (rst_n),
        .valid_i   (valid_i),
        .instr_i   (instr_i),
        .rs1_i     (rs1_i),
        .rs2_i     (rs2_i),
        .ready_o   (ready_o),
        .valid_o   (valid_o),
        .rd_addr_o (rd_addr_o),
        .rd_we_o   (rd_we_o),
        .rd_data_o (rd_data_o),
        .illegal_o (illegal_o),
        .ovf_o     (ovf_o),
        .acc_o     (acc_o)
    );

    //------------------------------------------------------------------------
    // Instruction encoding helpers
    //------------------------------------------------------------------------
    localparam [6:0] OPC_CUSTOM0 = 7'b0001011;

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

    // Build a 32-bit R-type instruction word.
    // rs1/rs2 register indices are fixed (x1, x2): the operand VALUES are
    // supplied separately on rs1_i / rs2_i, as a core's register file would.
    function [31:0] enc;
        input [6:0] f7;
        input [2:0] f3;
        input [4:0] rd;
        input [6:0] opc;
        begin
            enc = {f7, 5'd2, 5'd1, f3, rd, opc};
        end
    endfunction

    //------------------------------------------------------------------------
    // Reference model state
    //------------------------------------------------------------------------
    reg signed [63:0] m_acc;
    reg               m_ovf;

    // Golden behavioural model of one instruction. Updates m_acc / m_ovf and
    // returns the expected illegal flag, write-enable and rd value.
    task model_exec;
        input  [31:0] instr;
        input  [31:0] a;
        input  [31:0] b;
        output        e_ill;
        output        e_we;
        output [31:0] e_res;
        reg signed [63:0]  sa, sb, sp;   // signed operands / product
        reg        [63:0]  up;           // unsigned product
        reg signed [127:0] wide;         // overflow-free wide sum
        reg signed [63:0]  sh;
        begin
            e_ill = !((instr[6:0] == OPC_CUSTOM0) && (instr[31:25] == 7'd0));
            e_we  = !e_ill && (instr[11:7] != 5'd0);
            e_res = 32'd0;

            sa = $signed(a);                 // sign-extend to 64 bits
            sb = $signed(b);
            sp = sa * sb;                    // native multiply (not Booth)
            up = {32'd0, a} * {32'd0, b};    // unsigned 64-bit product

            if (!e_ill) begin
                case (instr[14:12])
                    F3_MAC, F3_MSU: begin
                        wide = m_acc;
                        if (instr[14:12] == F3_MAC) wide = wide + sp;
                        else                        wide = wide - sp;
                        if (wide > ACC_MAX) begin
                            m_acc = ACC_MAX; m_ovf = 1'b1;
                        end else if (wide < ACC_MIN) begin
                            m_acc = ACC_MIN; m_ovf = 1'b1;
                        end else begin
                            m_acc = wide[63:0];
                        end
                        e_res = m_acc[31:0];
                    end
                    F3_MUL: begin
                        m_acc = sp; m_ovf = 1'b0; e_res = m_acc[31:0];
                    end
                    F3_MACU: begin
                        m_acc = m_acc + up;   // wraps modulo 2^64
                        e_res = m_acc[31:0];
                    end
                    F3_RDLO: e_res = m_acc[31:0];
                    F3_RDHI: e_res = m_acc[63:32];
                    F3_RDQ15: begin
                        sh = m_acc >>> 15;
                        if      (sh >  32767) e_res = 32'h0000_7FFF;
                        else if (sh < -32768) e_res = 32'hFFFF_8000;
                        else                  e_res = {{16{sh[15]}}, sh[15:0]};
                    end
                    F3_CLR: begin
                        m_acc = 64'd0; m_ovf = 1'b0; e_res = 32'd0;
                    end
                endcase
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Scoreboard (expected-result FIFO)
    //------------------------------------------------------------------------
    localparam integer SB_DEPTH = 1024;

    reg [31:0]     sb_data [0:SB_DEPTH-1];
    reg [4:0]      sb_rd   [0:SB_DEPTH-1];
    reg            sb_we   [0:SB_DEPTH-1];
    reg            sb_ill  [0:SB_DEPTH-1];
    reg [63:0]     sb_acc  [0:SB_DEPTH-1];
    reg            sb_ovf  [0:SB_DEPTH-1];
    reg            sb_show [0:SB_DEPTH-1];   // print a PASS line
    reg            sb_cap  [0:SB_DEPTH-1];   // capture rd value for FIR tests
    reg [8*44-1:0] sb_desc [0:SB_DEPTH-1];
    time           sb_t    [0:SB_DEPTH-1];   // time operands were driven

    integer wr_ptr, rd_ptr;
    integer n_checks, n_errors, n_cap;
    reg [31:0] cap_buf [0:255];
    reg        verbose;

    // Functional coverage counters
    integer cov_op [0:7];
    integer cov_ill, cov_sat, cov_x0, cov_bubble;

    //------------------------------------------------------------------------
    // Driver: issue one instruction (model + scoreboard push + drive DUT)
    //------------------------------------------------------------------------
    task issue;
        input [31:0]     instr;
        input [31:0]     a;
        input [31:0]     b;
        input            cap;
        input [8*44-1:0] desc;
        reg e_ill, e_we, ovf_before;
        reg [31:0] e_res;
        integer idx;
        begin
            ovf_before = m_ovf;
            model_exec(instr, a, b, e_ill, e_we, e_res);

            idx = wr_ptr % SB_DEPTH;
            sb_data[idx] = e_res;
            sb_rd[idx]   = instr[11:7];
            sb_we[idx]   = e_we;
            sb_ill[idx]  = e_ill;
            sb_acc[idx]  = m_acc;
            sb_ovf[idx]  = m_ovf;
            sb_show[idx] = verbose;
            sb_cap[idx]  = cap;
            sb_desc[idx] = desc;
            wr_ptr = wr_ptr + 1;

            // coverage
            if (e_ill) cov_ill = cov_ill + 1;
            else       cov_op[instr[14:12]] = cov_op[instr[14:12]] + 1;
            if (!ovf_before && m_ovf) cov_sat = cov_sat + 1;
            if (!e_ill && instr[11:7] == 5'd0) cov_x0 = cov_x0 + 1;

            // drive on the falling edge, DUT samples on the next rising edge
            @(negedge clk);
            sb_t[idx] = $time;
            valid_i = 1'b1;
            instr_i = instr;
            rs1_i   = a;
            rs2_i   = b;
            @(posedge clk);
            #1 valid_i = 1'b0;
        end
    endtask

    // Shorthand for a legal MAC-unit instruction
    task op;
        input [2:0]      f3;
        input [4:0]      rd;
        input [31:0]     a;
        input [31:0]     b;
        input [8*44-1:0] desc;
        begin
            issue(enc(7'd0, f3, rd, OPC_CUSTOM0), a, b, 1'b0, desc);
        end
    endtask

    // Insert idle (bubble) cycles
    task idle;
        input integer n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    // Wait until every issued instruction has been checked
    task drain;
        begin
            while (rd_ptr < wr_ptr) @(negedge clk);
            @(negedge clk);
        end
    endtask

    //------------------------------------------------------------------------
    // Monitor / checker
    //------------------------------------------------------------------------
    integer mi;
    reg     ok;

    always @(negedge clk) begin
        if (rst_n && valid_o) begin
            if (rd_ptr >= wr_ptr) begin
                n_errors = n_errors + 1;
                $display("  [FAIL] unexpected valid_o at t=%0t", $time);
            end else begin
                mi = rd_ptr % SB_DEPTH;
                ok = (rd_data_o === sb_data[mi]) && (rd_addr_o === sb_rd[mi]) &&
                     (rd_we_o   === sb_we[mi])   && (illegal_o === sb_ill[mi]) &&
                     (acc_o     === sb_acc[mi])  && (ovf_o     === sb_ovf[mi]) &&
                     ($time - sb_t[mi] == 2*CLK_PERIOD);   // 2-cycle latency
                n_checks = n_checks + 1;

                if (!ok) begin
                    n_errors = n_errors + 1;
                    $display("  [FAIL] %s", sb_desc[mi]);
                    $display("         expected: rd=x%0d we=%b ill=%b data=0x%08h acc=0x%016h ovf=%b",
                             sb_rd[mi], sb_we[mi], sb_ill[mi], sb_data[mi], sb_acc[mi], sb_ovf[mi]);
                    $display("         got     : rd=x%0d we=%b ill=%b data=0x%08h acc=0x%016h ovf=%b latency=%0t",
                             rd_addr_o, rd_we_o, illegal_o, rd_data_o, acc_o, ovf_o, $time - sb_t[mi]);
                end else if (sb_show[mi]) begin
                    $display("  [PASS] %s | rd=0x%08h (%0d)  acc=0x%016h ovf=%b%s",
                             sb_desc[mi], rd_data_o, $signed(rd_data_o), acc_o, ovf_o,
                             illegal_o ? "  ILLEGAL" : (rd_we_o ? "" : "  (no write)"));
                end

                if (sb_cap[mi]) begin
                    cap_buf[n_cap] = rd_data_o;
                    n_cap = n_cap + 1;
                end
                rd_ptr = rd_ptr + 1;
            end
        end
    end

    //------------------------------------------------------------------------
    // Helper: compare a single value against an analytically known result
    //------------------------------------------------------------------------
    task check_value;
        input [8*44-1:0] name;
        input [31:0]     got;
        input [31:0]     exp;
        begin
            n_checks = n_checks + 1;
            if (got === exp)
                $display("  [PASS] %s | got %0d, expected %0d", name, $signed(got), $signed(exp));
            else begin
                n_errors = n_errors + 1;
                $display("  [FAIL] %s | got %0d, expected %0d", name, $signed(got), $signed(exp));
            end
        end
    endtask

    //------------------------------------------------------------------------
    // FIR filter benchmark helper
    //   y[n] = sat16( (sum_k h[k] * x[n-k]) >>> 15 )   (Q15 in, Q15 out)
    //   executed on the DUT as:  mul.acc  x0, x[n],   h[0]
    //                            mac      x0, x[n-k], h[k]   k = 1..7
    //                            rdacc.q15 x10
    //------------------------------------------------------------------------
    localparam integer TAPS = 8;
    reg signed [15:0] fir_h [0:TAPS-1];
    reg signed [15:0] fir_x [0:63];
    integer           fir_len;

    task run_fir;
        integer n, k;
        reg [31:0] xv;
        begin
            n_cap = 0;
            for (n = 0; n < fir_len; n = n + 1) begin
                for (k = 0; k < TAPS; k = k + 1) begin
                    xv = (n - k >= 0) ? {{16{fir_x[n-k][15]}}, fir_x[n-k]} : 32'd0;
                    op((k == 0) ? F3_MUL : F3_MAC, 5'd0, xv,
                       {{16{fir_h[k][15]}}, fir_h[k]}, "fir tap");
                end
                issue(enc(7'd0, F3_RDQ15, 5'd10, OPC_CUSTOM0), 32'd0, 32'd0, 1'b1, "fir out");
            end
            drain;
        end
    endtask

    //------------------------------------------------------------------------
    // Random stimulus helpers (fixed seed => reproducible regression)
    //------------------------------------------------------------------------
    integer seed;
    reg [31:0] rnd_val;

    // Operand generator biased toward arithmetic corner cases
    task rnd_operand;
        integer sel;
        begin
            sel = {$random(seed)} % 10;
            case (sel)
                0: rnd_val = 32'h0000_0000;
                1: rnd_val = 32'h0000_0001;
                2: rnd_val = 32'hFFFF_FFFF;               // -1
                3: rnd_val = 32'h7FFF_FFFF;               // INT32_MAX
                4: rnd_val = 32'h8000_0000;               // INT32_MIN
                5: rnd_val = $random(seed) % 256;         // small signed
                6: rnd_val = {{16{1'b0}}, $random(seed)} & 32'h0000_FFFF;
                default: rnd_val = $random(seed);         // full range
            endcase
        end
    endtask

    //------------------------------------------------------------------------
    // Main test sequence
    //------------------------------------------------------------------------
    integer i, n, k, t0, t1;
    reg [31:0] a_r, b_r, ins;
    reg [2:0]  f3_r;
    reg [4:0]  rd_r;
    integer    sum_sq;

    initial begin
        $dumpfile("mac_unit.vcd");
        $dumpvars(0, tb_mac_unit);

        // init
        rst_n   = 1'b0;
        valid_i = 1'b0;
        instr_i = 32'd0;
        rs1_i   = 32'd0;
        rs2_i   = 32'd0;
        m_acc   = 64'd0;
        m_ovf   = 1'b0;
        wr_ptr  = 0;  rd_ptr = 0;
        n_checks = 0; n_errors = 0; n_cap = 0;
        verbose = 1'b1;
        seed    = 32'h1234_5678;
        for (i = 0; i < 8; i = i + 1) cov_op[i] = 0;
        cov_ill = 0; cov_sat = 0; cov_x0 = 0; cov_bubble = 0;

        $display("====================================================================");
        $display(" RISC-V MAC Unit (custom-0) -- Self-Checking Testbench");
        $display("====================================================================");

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;

        //--------------------------------------------------------------------
        $display("\n--- T1: Reset state ---");
        op(F3_RDLO, 5'd5, 0, 0, "rdacc.lo x5          (after reset)");
        op(F3_RDHI, 5'd5, 0, 0, "rdacc.hi x5          (after reset)");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T2: Basic MUL / MAC / MSU (back-to-back issue) ---");
        op(F3_MUL,  5'd5, 7,  6,            "mul.acc x5, 7, 6     -> 42");
        op(F3_MAC,  5'd5, 3,  -32'sd4,      "mac x5, 3, -4        -> 30");
        op(F3_MSU,  5'd5, -32'sd5, 10,      "msu x5, -5, 10       -> 80");
        op(F3_MAC,  5'd5, 100, 1000,        "mac x5, 100, 1000    -> 100080");
        op(F3_RDLO, 5'd6, 0, 0,             "rdacc.lo x6          -> 100080");
        op(F3_RDHI, 5'd7, 0, 0,             "rdacc.hi x7          -> 0");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T3: Sign combinations ---");
        op(F3_MUL,  5'd5,  12,       13,       "mul.acc  (+12)*(+13) -> 156");
        op(F3_MUL,  5'd5,  12,      -32'sd13,  "mul.acc  (+12)*(-13) -> -156");
        op(F3_RDHI, 5'd6,  0, 0,               "rdacc.hi (sign ext.) -> -1");
        op(F3_MUL,  5'd5, -32'sd12,  13,       "mul.acc  (-12)*(+13) -> -156");
        op(F3_MUL,  5'd5, -32'sd12, -32'sd13,  "mul.acc  (-12)*(-13) -> 156");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T4: Extreme operands, full 64-bit product ---");
        op(F3_MUL,  5'd5, 32'h7FFFFFFF, 32'h7FFFFFFF, "mul.acc MAX*MAX = 0x3FFFFFFF00000001");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0x3FFFFFFF");
        op(F3_MUL,  5'd5, 32'h80000000, 32'h80000000, "mul.acc MIN*MIN = 2^62");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0x40000000");
        op(F3_MUL,  5'd5, 32'h80000000, 32'h7FFFFFFF, "mul.acc MIN*MAX = 0xC000000080000000");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0xC0000000");
        op(F3_MUL,  5'd5, 32'hFFFFFFFF, 32'h80000000, "mul.acc (-1)*MIN = +2^31");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T5: 64-bit accumulator saturation and sticky OVF ---");
        op(F3_MUL,  5'd5, 32'h80000000, 32'h80000000, "mul.acc MIN*MIN        acc=2^62");
        op(F3_MAC,  5'd5, 32'h80000000, 32'h80000000, "mac +2^62 -> 2^63 SAT to INT64_MAX");
        op(F3_MAC,  5'd5, 32'h7FFFFFFF, 32'h7FFFFFFF, "mac  (stays saturated, OVF sticky)");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi               -> 0x7FFFFFFF");
        op(F3_CLR,  5'd0, 0, 0,                       "clracc (clears ACC and OVF)");
        op(F3_MUL,  5'd5, 32'h80000000, 32'h7FFFFFFF, "mul.acc MIN*MAX        acc~-2^62");
        op(F3_MSU,  5'd5, 32'h80000000, 32'h80000000, "msu  -2^62             (no ovf)");
        op(F3_MAC,  5'd5, 32'h80000000, 32'h7FFFFFFF, "mac  -> below -2^63, SAT to INT64_MIN");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi               -> 0x80000000");
        op(F3_MUL,  5'd5, 2, 3,                       "mul.acc (restarts, clears OVF) -> 6");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T6: Unsigned MACU (modulo 2^64) ---");
        op(F3_CLR,  5'd0, 0, 0,                       "clracc");
        op(F3_MACU, 5'd5, 32'hFFFFFFFF, 32'hFFFFFFFF, "macu 0xFFFFFFFF^2 = 0xFFFFFFFE00000001");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0xFFFFFFFE");
        op(F3_MACU, 5'd5, 32'hFFFFFFFF, 32'hFFFFFFFF, "macu again (wraps, no OVF)");
        op(F3_RDHI, 5'd6, 0, 0,                       "rdacc.hi        -> 0xFFFFFFFC");
        verbose = 1'b0;
        op(F3_CLR,  5'd0, 0, 0, "clracc");
        for (i = 1; i <= 10; i = i + 1)
            op(F3_MACU, 5'd0, i, i, "macu i*i");
        verbose = 1'b1;
        n_cap = 0;
        issue(enc(7'd0, F3_RDLO, 5'd10, OPC_CUSTOM0), 0, 0, 1'b1, "rdacc.lo  sum_{i=1..10} i^2");
        drain;
        check_value("sum of squares 1..10 (analytic 385)", cap_buf[0], 32'd385);

        //--------------------------------------------------------------------
        $display("\n--- T7: Destination x0 (no register write) ---");
        op(F3_MUL,  5'd0, 9, 9,  "mul.acc x0, 9, 9  (acc=81, no write)");
        op(F3_MAC,  5'd0, 1, 19, "mac     x0, 1, 19 (acc=100, no write)");
        op(F3_RDLO, 5'd31, 0, 0, "rdacc.lo x31      -> 100");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T8: Illegal instruction detection ---");
        issue(enc(7'b0000001, 3'b000, 5'd5, 7'b0110011), 5, 5, 1'b0,
              "RV32M MUL (opcode OP) -> illegal here");
        issue(enc(7'b0100000, F3_MAC, 5'd5, OPC_CUSTOM0), 5, 5, 1'b0,
              "custom-0 with funct7=0100000 -> illegal");
        issue(32'h0000_0013, 0, 0, 1'b0, "NOP (addi x0,x0,0) -> illegal here");
        op(F3_RDLO, 5'd5, 0, 0, "rdacc.lo  (ACC unchanged) -> 100");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T9: Q15 fixed-point read-out (rdacc.q15) ---");
        op(F3_MUL,   5'd0, 16384, 16384,               "mul.acc 0.5 * 0.5   (Q15)");
        op(F3_RDQ15, 5'd5, 0, 0,                       "rdacc.q15 -> 0.25  = 8192");
        op(F3_MUL,   5'd0, -32'sd16384, 16384,         "mul.acc -0.5 * 0.5  (Q15)");
        op(F3_RDQ15, 5'd5, 0, 0,                       "rdacc.q15 -> -0.25 = -8192");
        op(F3_MUL,   5'd0, 32'hFFFF8000, 32'hFFFF8000, "mul.acc -1.0 * -1.0 (Q15)");
        op(F3_RDQ15, 5'd5, 0, 0,                       "rdacc.q15 -> +1.0 SAT to 32767");
        op(F3_MAC,   5'd0, 32767, 32767,               "mac ~ +1.0");
        op(F3_MAC,   5'd0, 32767, 32767,               "mac ~ +1.0");
        op(F3_RDQ15, 5'd5, 0, 0,                       "rdacc.q15 -> ~3.0 SAT to 32767");
        op(F3_MUL,   5'd0, 32'hFFFF8000, 32767,        "mul.acc -1.0 * 0.99997");
        op(F3_MAC,   5'd0, 32'hFFFF8000, 32767,        "mac  -> ~ -2.0");
        op(F3_RDQ15, 5'd5, 0, 0,                       "rdacc.q15 -> SAT to -32768");
        drain;

        //--------------------------------------------------------------------
        $display("\n--- T10: DSP benchmark - dot product [1..8].[8..1] ---");
        verbose = 1'b0;
        t0 = $time;
        for (i = 1; i <= 8; i = i + 1)
            op((i == 1) ? F3_MUL : F3_MAC, 5'd0, i, 9 - i, "dot-product term");
        verbose = 1'b1;
        n_cap = 0;
        issue(enc(7'd0, F3_RDLO, 5'd10, OPC_CUSTOM0), 0, 0, 1'b1, "rdacc.lo  dot product result");
        t1 = $time;
        drain;
        check_value("dot product (analytic 120)", cap_buf[0], 32'd120);
        $display("  Throughput: 9 instructions issued in %0d cycles (1 instr/cycle)",
                 (t1 - t0) / CLK_PERIOD);

        //--------------------------------------------------------------------
        $display("\n--- T11: DSP benchmark - 8-tap moving-average FIR, step input ---");
        $display("  h[k] = 4096 (0.125 in Q15), x[n] = 16384 (0.5) for n >= 0");
        $display("  Analytic: y[n] = 2048*(n+1) for n < 8, then 16384");
        verbose = 1'b0;
        for (k = 0; k < TAPS; k = k + 1) fir_h[k] = 16'sd4096;
        fir_len = 12;
        for (n = 0; n < fir_len; n = n + 1) fir_x[n] = 16'sd16384;
        t0 = $time;
        run_fir;
        t1 = $time;
        verbose = 1'b1;
        $display("    n | x[n]   | y[n] DUT | y[n] analytic");
        for (n = 0; n < fir_len; n = n + 1) begin
            $display("   %2d | %6d | %8d | %8d %s", n, fir_x[n], $signed(cap_buf[n]),
                     (n < 8) ? 2048*(n+1) : 16384,
                     ($signed(cap_buf[n]) == ((n < 8) ? 2048*(n+1) : 16384)) ? "PASS" : "FAIL");
            check_value("FIR moving average y[n]", cap_buf[n], (n < 8) ? 2048*(n+1) : 16384);
        end
        $display("  FIR cost: %0d instructions/sample, %0d cycles for %0d samples (incl. drain)",
                 TAPS + 1, (t1 - t0) / CLK_PERIOD, fir_len);

        //--------------------------------------------------------------------
        $display("\n--- T12: DSP benchmark - 8-tap triangular low-pass FIR ---");
        $display("  h = {1024,3072,5120,7168,7168,5120,3072,1024}  (sum = 1.0 in Q15)");
        $display("  x[n] = 8000 + 6000*(-1)^n   (DC + Nyquist-frequency tone)");
        $display("  Analytic: H(Nyquist) = sum h[k](-1)^k = 0, H(DC) = 1");
        $display("            => y[n] = 8000 exactly once the 8-tap window is full");
        fir_h[0] = 1024; fir_h[1] = 3072; fir_h[2] = 5120; fir_h[3] = 7168;
        fir_h[4] = 7168; fir_h[5] = 5120; fir_h[6] = 3072; fir_h[7] = 1024;
        fir_len = 16;
        for (n = 0; n < fir_len; n = n + 1)
            fir_x[n] = (n % 2 == 0) ? 16'sd14000 : 16'sd2000;
        verbose = 1'b0;
        run_fir;
        verbose = 1'b1;
        $display("    n | x[n]   | y[n] DUT");
        for (n = 0; n < fir_len; n = n + 1)
            $display("   %2d | %6d | %8d %s", n, fir_x[n], $signed(cap_buf[n]),
                     (n >= TAPS-1) ? "(steady state)" : "(warm-up)");
        for (n = TAPS-1; n < fir_len; n = n + 1)
            check_value("LPF steady-state output = 8000", cap_buf[n], 32'd8000);

        //--------------------------------------------------------------------
        $display("\n--- T13: Constrained-random regression (3000 instructions) ---");
        verbose = 1'b0;
        for (i = 0; i < 3000; i = i + 1) begin
            rnd_operand; a_r = rnd_val;
            rnd_operand; b_r = rnd_val;
            f3_r = $random(seed);
            rd_r = $random(seed);
            if ({$random(seed)} % 20 == 0) begin
                // ~5% illegal: wrong opcode or non-zero funct7
                if ({$random(seed)} % 2)
                    ins = enc(7'd0, f3_r, rd_r, 7'b0110011);
                else
                    ins = enc(7'b0000001 + ({$random(seed)} % 127), f3_r, rd_r, OPC_CUSTOM0);
            end else
                ins = enc(7'd0, f3_r, rd_r, OPC_CUSTOM0);

            issue(ins, a_r, b_r, 1'b0, "random");

            // ~25% chance of 1..3 bubble cycles between instructions
            if ({$random(seed)} % 4 == 0) begin
                idle(1 + {$random(seed)} % 3);
                cov_bubble = cov_bubble + 1;
            end
        end
        drain;
        $display("  random regression complete");

        //--------------------------------------------------------------------
        // Summary
        //--------------------------------------------------------------------
        $display("\n====================================================================");
        $display(" FUNCTIONAL COVERAGE");
        $display("   mac=%0d msu=%0d mul.acc=%0d macu=%0d rdacc.lo=%0d rdacc.hi=%0d rdacc.q15=%0d clracc=%0d",
                 cov_op[0], cov_op[1], cov_op[2], cov_op[3],
                 cov_op[4], cov_op[5], cov_op[6], cov_op[7]);
        $display("   illegal=%0d  saturation events=%0d  rd=x0 writes=%0d  bubble gaps=%0d",
                 cov_ill, cov_sat, cov_x0, cov_bubble);
        $display(" RESULTS");
        $display("   instructions issued : %0d", wr_ptr);
        $display("   checks performed    : %0d", n_checks);
        $display("   errors              : %0d", n_errors);
        if (n_errors == 0 && rd_ptr == wr_ptr)
            $display("   >>> ALL TESTS PASSED <<<");
        else
            $display("   >>> TEST FAILED <<<");
        $display("====================================================================");
        $finish;
    end

    // Safety timeout
    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
