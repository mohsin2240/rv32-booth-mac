# ===========================================================================
# fir_rv32im_loop.s - the same Q15 FIR filter in plain RV32IM software
#
# Baseline for the MAC unit: identical data, loop structure and results,
# but without the custom instructions. The 64-bit accumulator lives in the
# register pair {s5:s4} and is updated with mul / mulh / add / sltu (carry)
# / add / add. The Q30 -> Q15 conversion and the saturation to 16 bits
# are done in software after each output sample.
# ===========================================================================
        .include "fir_data.inc"

        .text
start:
        la   s0, x_pad
        la   s1, h_rev
        la   s2, y
        li   s3, N
        li   a5, 32767
        li   a6, -32768
        li   a7, -1
outer:
        mv   t0, s0
        mv   t1, s1
        li   t2, TAPS
        li   s4, 0              # acc low
        li   s5, 0              # acc high
inner:
        lh   t3, 0(t0)
        lh   t4, 0(t1)
        addi t0, t0, 2
        addi t1, t1, 2
        mul  a2, t3, t4         # product low word
        mulh a3, t3, t4         # product high word
        addi t2, t2, -1
        add  s4, s4, a2         # 64-bit add with carry
        sltu a4, s4, a2
        add  s5, s5, a3
        add  s5, s5, a4
        bnez t2, inner

        # t6:t5 = acc >>> 15  (64-bit arithmetic shift)
        srli t5, s4, 15
        slli t6, s5, 17
        or   t5, t5, t6
        srai t6, s5, 15
        # saturate to [-32768, 32767]
        bltz t6, neg
        bnez t6, satpos
        bltu a5, t5, satpos
        j    store
neg:    bne  t6, a7, satneg
        bltu t5, a6, satneg
        j    store
satpos: mv   t5, a5
        j    store
satneg: mv   t5, a6
store:
        sh   t5, 0(s2)
        addi s2, s2, 2
        addi s0, s0, 2
        addi s3, s3, -1
        bnez s3, outer

        li   a0, 0x600D
        ecall
