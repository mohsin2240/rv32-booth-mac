# ===========================================================================
# isa_test.s - self-checking test program for rv32_core + MAC unit
#
# Every test loads its number into a3, computes a value and compares it
# with the expected constant. On the first mismatch the program jumps to
# 'fail' (a0 = failing test number). If everything passes, a0 = 0x600D.
# The testbench checks a0 when the core halts on ECALL.
#
# Besides instruction semantics, the tests are written so that the
# pipeline's hazard logic is exercised: back-to-back dependencies
# (EX/MEM and MEM/WB forwarding), load-use stalls, MAC-use stalls,
# store-after-load, taken/not-taken branches and jumps.
# ===========================================================================
        .equ PASS, 0x600D

        .text
start:
# ---- T1: ADD / SUB ---------------------------------------------------------
        li   a3, 1
        li   t0, 5
        li   t1, 7
        add  t2, t0, t1
        li   t6, 12
        bne  t2, t6, fail
        sub  t2, t0, t1
        li   t6, -2
        bne  t2, t6, fail

# ---- T2: forwarding EX/MEM and MEM/WB (back-to-back dependencies) ---------
        li   a3, 2
        addi t0, x0, 3
        addi t1, t0, 4          # t0 from EX/MEM
        add  t2, t1, t0         # t1 from EX/MEM, t0 from MEM/WB
        add  t2, t2, t2         # chain
        li   t6, 20
        bne  t2, t6, fail

# ---- T3: logic operations -------------------------------------------------
        li   a3, 3
        li   t0, 0x0F0F
        li   t1, 0x00FF
        xor  t2, t0, t1
        li   t6, 0x0FF0
        bne  t2, t6, fail
        or   t2, t0, t1
        li   t6, 0x0FFF
        bne  t2, t6, fail
        and  t2, t0, t1
        li   t6, 0x000F
        bne  t2, t6, fail
        xori t2, t0, -1
        li   t6, 0xFFFFF0F0
        bne  t2, t6, fail
        andi t2, t0, 0x0F0
        li   t6, 0x000
        bne  t2, t6, fail
        ori  t2, t1, 0x700
        li   t6, 0x7FF
        bne  t2, t6, fail

# ---- T4: shifts ------------------------------------------------------------
        li   a3, 4
        li   t0, -16            # 0xFFFFFFF0
        srai t1, t0, 2
        li   t6, -4
        bne  t1, t6, fail
        srli t1, t0, 28
        li   t6, 0xF
        bne  t1, t6, fail
        slli t1, t0, 4
        li   t6, -256
        bne  t1, t6, fail
        li   t2, 4
        sll  t1, t0, t2
        li   t6, -256
        bne  t1, t6, fail
        srl  t1, t0, t2
        li   t6, 0x0FFFFFFF
        bne  t1, t6, fail
        sra  t1, t0, t2
        li   t6, -1
        bne  t1, t6, fail

# ---- T5: set-less-than -----------------------------------------------------
        li   a3, 5
        li   t0, -16
        li   t1, 1
        slt  t2, t0, t1
        li   t6, 1
        bne  t2, t6, fail
        sltu t2, t0, t1
        bnez t2, fail
        slti t2, t0, -15
        li   t6, 1
        bne  t2, t6, fail
        sltiu t2, t1, 2
        li   t6, 1
        bne  t2, t6, fail

# ---- T6: LUI / AUIPC -------------------------------------------------------
        li   a3, 6
        lui  t0, 0x12345
        li   t6, 0x12345000
        bne  t0, t6, fail
here:   auipc t1, 0
        la   t2, here
        bne  t1, t2, fail

# ---- T7: loads / stores, sign & zero extension -----------------------------
        li   a3, 7
        la   s0, scratch
        li   t0, 0x80FF7F01
        sw   t0, 0(s0)
        lw   t1, 0(s0)
        bne  t1, t0, fail
        lb   t1, 0(s0)
        li   t6, 0x01
        bne  t1, t6, fail
        lb   t1, 1(s0)
        li   t6, 0x7F
        bne  t1, t6, fail
        lb   t1, 2(s0)
        li   t6, -1
        bne  t1, t6, fail
        lbu  t1, 2(s0)
        li   t6, 0xFF
        bne  t1, t6, fail
        lh   t1, 2(s0)
        li   t6, 0xFFFF80FF
        bne  t1, t6, fail
        lhu  t1, 2(s0)
        li   t6, 0x80FF
        bne  t1, t6, fail
        lh   t1, 0(s0)
        li   t6, 0x7F01
        bne  t1, t6, fail
        li   t0, 0xAA
        sb   t0, 1(s0)
        lw   t1, 0(s0)
        li   t6, 0x80FFAA01
        bne  t1, t6, fail
        li   t0, 0x1234
        sh   t0, 2(s0)
        lw   t1, 0(s0)
        li   t6, 0x1234AA01
        bne  t1, t6, fail

# ---- T8: load-use hazard and store-after-load ------------------------------
        li   a3, 8
        lw   t1, 0(s0)
        addi t2, t1, 1          # load-use: needs one bubble
        li   t6, 0x1234AA02
        bne  t2, t6, fail
        lw   t1, 0(s0)
        sw   t1, 4(s0)          # store data comes straight from a load
        lw   t2, 4(s0)
        bne  t2, t1, fail

# ---- T9: branches, taken and not taken -------------------------------------
        li   a3, 9
        li   t0, -1
        li   t1, 1
        beq  t0, t1, fail
        bne  t0, t0, fail
        blt  t1, t0, fail
        bge  t0, t1, fail
        bltu t0, t1, fail
        bgeu t1, t0, fail
        blt  t0, t1, b1
        j    fail
b1:     bge  t1, t0, b2
        j    fail
b2:     bltu t1, t0, b3
        j    fail
b3:     bgeu t0, t1, b4
        j    fail
b4:     beq  t1, t1, b5
        j    fail
b5:     bne  t0, t1, b6
        j    fail
b6:

# ---- T10: JAL / JALR (call and return) -------------------------------------
        li   a3, 10
        li   t5, 0
        call func
        li   t6, 77
        bne  t5, t6, fail
        la   t0, after
        jalr x0, 0(t0)          # computed jump
        j    fail
after:

# ---- T11: RV32M multiply ---------------------------------------------------
        li   a3, 11
        li   t0, -7
        li   t1, 3
        mul  t2, t0, t1
        li   t6, -21
        bne  t2, t6, fail
        mulh t2, t0, t1
        li   t6, -1
        bne  t2, t6, fail
        mulhu t2, t0, t1        # 0xFFFFFFF9 * 3 = 0x2_FFFFFFEB
        li   t6, 2
        bne  t2, t6, fail
        mulhsu t2, t0, t1
        li   t6, -1
        bne  t2, t6, fail
        li   t0, 0x7FFFFFFF
        mulh t2, t0, t0
        li   t6, 0x3FFFFFFF
        bne  t2, t6, fail

# ---- T12: MAC basics + MAC-use hazard --------------------------------------
        li   a3, 12
        li   t0, 6
        li   t1, 7
        mul.acc x0, t0, t1      # ACC = 42
        mac  t2, t0, t1         # ACC = 84, t2 = 84
        addi t3, t2, 1          # MAC-use: one bubble, then forward from WB
        li   t6, 85
        bne  t3, t6, fail
        rdacc.lo t4
        li   t6, 84
        bne  t4, t6, fail
        rdacc.hi t4
        bnez t4, fail

# ---- T13: MAC operands from the forwarding network -------------------------
        li   a3, 13
        clracc
        addi t0, x0, 10
        addi t1, x0, 20
        mac  t2, t0, t1         # t1 from EX/MEM, t0 from MEM/WB
        li   t6, 200
        bne  t2, t6, fail
        lw   t0, 0(s0)          # 0x1234AA01
        mac  t2, t0, x0         # load-use into MAC operand: + 0
        li   t6, 200
        bne  t2, t6, fail

# ---- T14: dependent MAC chain ----------------------------------------------
        li   a3, 14
        clracc
        li   t0, 2
        li   t1, 3
        mac  t2, t0, t1         # 6
        mac  t3, t0, t1         # 12
        add  t4, t2, t3         # 18
        li   t6, 18
        bne  t4, t6, fail
        msu  t5, t4, t1         # 12 - 18*3 = -42
        li   t6, -42
        bne  t5, t6, fail

# ---- T15: Q15 read-out and saturation through the core ---------------------
        li   a3, 15
        li   t0, 16384          # 0.5 in Q15
        mul.acc x0, t0, t0
        rdacc.q15 t2
        li   t6, 8192           # 0.25
        bne  t2, t6, fail
        li   t0, 0x80000000
        mul.acc x0, t0, t0      # 2^62
        mac  x0, t0, t0         # overflow -> saturate to INT64_MAX
        rdacc.hi t2
        li   t6, 0x7FFFFFFF
        bne  t2, t6, fail
        rdacc.q15 t2
        li   t6, 32767
        bne  t2, t6, fail

# ---- T16: unsigned MACU ----------------------------------------------------
        li   a3, 16
        clracc
        li   t0, -1             # 0xFFFFFFFF
        macu t2, t0, t0
        li   t6, 1
        bne  t2, t6, fail
        rdacc.hi t2
        li   t6, 0xFFFFFFFE
        bne  t2, t6, fail

# ---- T17: x0 is hard-wired to zero (ALU and MAC writes) --------------------
        li   a3, 17
        addi x0, x0, 5
        bnez x0, fail
        li   t0, 3
        mul.acc x0, t0, t0      # rd = x0: no write, ACC = 9
        bnez x0, fail
        rdacc.lo t2
        li   t6, 9
        bne  t2, t6, fail

# ---- T18: loop with backward branch: sum 1..10 -----------------------------
        li   a3, 18
        li   t0, 10
        li   t1, 0
loop:   add  t1, t1, t0
        addi t0, t0, -1
        bnez t0, loop
        li   t6, 55
        bne  t1, t6, fail

# ---- all passed ------------------------------------------------------------
        li   a0, PASS
        ecall

fail:   mv   a0, a3
        ecall

func:   addi t5, x0, 77
        ret

        .data
        .align 2
scratch: .space 16
