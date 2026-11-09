//============================================================================
// File        : tb_booth_multiplier.v
// Module      : tb_booth_multiplier
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
//   Unit-level testbench for the radix-4 Booth multiplier.
//
//   Part A : EXHAUSTIVE check of an 8-bit instance - all 2^16 = 65,536
//            signed operand pairs are compared against the simulator's
//            native '*' operator.
//   Part B : The 34-bit instance actually used in mac_unit, checked on
//            directed corner cases (0, +-1, INT32_MIN/MAX as used by the MAC,
//            34-bit extremes) and 20,000 random operand pairs.
//
//   Because the Booth algorithm is width-independent, the exhaustive 8-bit
//   proof plus the random/corner 34-bit regression gives high confidence in
//   the multiplier used by the MAC unit.
//============================================================================
`timescale 1ns/1ps

module tb_booth_multiplier;

    //------------------------------------------------------------------------
    // Part A DUT : 8-bit exhaustive
    //------------------------------------------------------------------------
    reg  signed [7:0]  a8, b8;
    wire signed [15:0] p8;

    booth_multiplier #(.W(8)) dut8 (.a_i(a8), .b_i(b8), .p_o(p8));

    //------------------------------------------------------------------------
    // Part B DUT : 34-bit (same configuration as inside mac_unit)
    //------------------------------------------------------------------------
    reg  signed [33:0] a34, b34;
    wire signed [67:0] p34;

    booth_multiplier #(.W(34)) dut34 (.a_i(a34), .b_i(b34), .p_o(p34));

    integer i, j, errs, checks, seed;
    reg signed [67:0] ref34;

    // Check one 34-bit pair against the reference product
    task check34;
        input signed [33:0] a;
        input signed [33:0] b;
        input               show;
        begin
            a34 = a; b34 = b;
            #1;
            ref34  = a * b;          // 68-bit reference (context-sized)
            checks = checks + 1;
            if (p34 !== ref34) begin
                errs = errs + 1;
                $display("  [FAIL] %0d * %0d : got %0d, expected %0d", a, b, p34, ref34);
            end else if (show)
                $display("  [PASS] %0d * %0d = %0d", a, b, p34);
        end
    endtask

    initial begin
        errs = 0; checks = 0; seed = 32'hC0FFEE;

        $display("====================================================================");
        $display(" Radix-4 Booth Multiplier -- Unit Testbench");
        $display("====================================================================");

        //---------------- Part A: exhaustive 8x8 ----------------
        $display("\n--- Part A: exhaustive 8-bit signed (65,536 cases) ---");
        for (i = -128; i < 128; i = i + 1) begin
            for (j = -128; j < 128; j = j + 1) begin
                a8 = i; b8 = j;
                #1;
                checks = checks + 1;
                if (p8 !== i * j) begin
                    errs = errs + 1;
                    if (errs < 10)
                        $display("  [FAIL] %0d * %0d : got %0d, expected %0d", i, j, p8, i * j);
                end
            end
        end
        $display("  exhaustive 8-bit check done, errors so far = %0d", errs);

        //---------------- Part B: 34-bit directed ----------------
        $display("\n--- Part B: 34-bit directed corner cases ---");
        check34(0, 0, 1);
        check34(1, -1, 1);
        check34(-1, -1, 1);
        check34(123456, -654321, 1);
        check34(34'sh0_7FFF_FFFF, 34'sh0_7FFF_FFFF, 1);  // INT32_MAX^2
        check34(34'sh3_8000_0000, 34'sh3_8000_0000, 1);  // INT32_MIN^2 (sign-ext)
        check34(34'sh0_FFFF_FFFF, 34'sh0_FFFF_FFFF, 1);  // UINT32_MAX^2 (zero-ext)
        check34(34'sh1_FFFF_FFFF, 34'sh2_0000_0000, 1);  // 34-bit MAX * MIN
        check34(34'sh2_0000_0000, 34'sh2_0000_0000, 1);  // 34-bit MIN * MIN

        //---------------- Part B: 34-bit random ----------------
        $display("\n--- Part B: 34-bit random (20,000 cases) ---");
        for (i = 0; i < 20000; i = i + 1)
            check34({$random(seed), $random(seed)}, {$random(seed), $random(seed)}, 0);
        $display("  random 34-bit check done");

        $display("\n====================================================================");
        $display("   checks performed : %0d", checks);
        $display("   errors           : %0d", errs);
        if (errs == 0) $display("   >>> ALL TESTS PASSED <<<");
        else           $display("   >>> TEST FAILED <<<");
        $display("====================================================================");
        $finish;
    end

endmodule
