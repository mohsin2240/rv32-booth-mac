# Design and Verification of a RISC-V Multiply-Accumulate (MAC) Unit for Digital Signal Processing

A 2-stage pipelined, 32×32→64-bit signed/unsigned MAC unit with saturation and Q15 fixed-point support. It is built as a **RISC-V custom-instruction functional unit**: it decodes R-type instructions in the `custom-0` opcode space. A radix-4 Booth multiplier does the multiplication.

The MAC unit is **integrated into a complete 5-stage pipelined RV32IM processor**, which runs real RISC-V programs: an ISA/hazard self-test and Q15 FIR filters. Everything is written in **Verilog-2005**, verified with self-checking testbenches in Icarus Verilog, and synthesised with Yosys/nextpnr for a Lattice ECP5 FPGA. The full report with all figures is [report/report.pdf](report/report.pdf).

| | |
|---|---|
| **Submitted by** | Mohsin Mushtaq (2025MECECS001)<br>Mubashir Karim Ganaie (2025MECECS005) |
| **Submitted to** | Dr. Afshan Amin Khan |
| **Department** | Department of Electronics and Communications, National Institute of Technology Srinagar |

## 1. Project files

| File | Type | Purpose |
|---|---|---|
| `rtl/mac_unit.v` | **Main module** | RISC-V custom-0 decoder, 2-stage pipeline, 64-bit saturating accumulator, Q15 read-out |
| `rtl/booth_multiplier.v` | Sub-module | Parameterised radix-4 Modified Booth multiplier (used at 34 bits) |
| `tb/tb_mac_unit.v` | **Testbench** | Self-checking system testbench: reference model, scoreboard, 13 test groups, DSP benchmarks, coverage |
| `tb/tb_booth_multiplier.v` | Testbench | Unit test of the multiplier: exhaustive 8-bit run plus random/corner 34-bit runs |
| `run_sim.bat` / `run_sim.sh` | Script | Compile and run both testbenches (Windows / Linux) |
| `sim/mac_sim.log`, `sim/booth_sim.log` | Results | Saved terminal output of the simulations |
| `sim/mac_unit.vcd` | Results | Waveform dump (open it in GTKWave) |
| `synth/synth_generic.ys`, `synth/synth_ecp5.ys` | Synthesis | Yosys scripts: generic gate-level synthesis and Lattice ECP5 FPGA synthesis |
| `synth/fmax_wrapper.v`, `synth/native_multiplier.v` | Synthesis | Registered-I/O wrapper for timing; `*` multiplier variant for the DSP-block comparison |
| `run_synth.sh` | Script | Synthesis → place & route → gate-level simulation |
| `synth/reports/`, `synth/out/` | Results | Yosys/nextpnr reports, gate-level netlist `mac_unit_netlist.v` |
| `sim/gate/mac_gate_sim.log` | Results | Testbench run on the synthesized netlist |
| `rtl/rv32_core.v` | **Processor** | 5-stage RV32IM pipeline (IF/ID/EX/MEM/WB) with forwarding, hazard unit and the integrated MAC unit |
| `rtl/riscv_soc.v` | Processor | Core + 4 KiB instruction memory + 16 KiB data memory |
| `tb/tb_riscv_soc.v` | Testbench | Runs RISC-V programs, checks results bit-exactly, reports counters, writes pipeline trace/VCD |
| `sw/rvasm.py` | Software | Two-pass RISC-V assembler (RV32I, RV32M multiply, custom MAC instructions, pseudo-ops) |
| `sw/build.py` | Software | Designs the FIR filter, makes the test signal and golden output, assembles all programs |
| `sw/isa_test.s`, `sw/fir_*.s`, `sw/gen/*.s` | Software | ISA/hazard self-test and four FIR versions (MAC vs RV32IM, looped vs unrolled) |
| `sw/run_cpu_sims.py` | Script | Build → compile → run every program on the processor → `sim/cpu/results.json` |
| `sim/cpu/` | Results | Per-program logs, CPU outputs, pipeline traces (CSV), VCD |
| `synth/synth_core.ys`, `synth/schematics.ys` | Synthesis | Full-processor synthesis; RTL netlists for schematics |
| `report/report.tex` + `report/ch_*.tex` | Report | LaTeX source; `report/scripts/` makes all figures from the real simulation and synthesis data |
| `report/report.pdf` | Report | Full project report (94 pages) |
| `docs/` | GitHub Pages | Public site https://mohsin2240.github.io/rv32-booth-mac/, served from `docs/index.html`. Rebuild with `python report/web/build_pages.py`, then commit and push |
| `report/web/rv32_booth_mac.html` | Project page | Interactive page: zoomable ECP5 floorplan with per-block highlighting, architecture, verification, performance. Built from `page_template.html` + `floorplan_data.json` (made by `report/scripts/export_floorplan.py`) |

## 2. Theory

### 2.1 Multiply-accumulate in DSP
Most DSP kernels come down to sums of products. Examples are FIR filters `y[n] = Σ h[k]·x[n-k]`, dot products, correlation, matrix multiplication and the DFT butterfly. A MAC unit computes `ACC ← ACC + a·b` in a single instruction. In a base RV32I/RV32M core, the same work takes a `mul` plus an `add` (and `mulh` too if you need the full 64-bit product). DSP-oriented RISC-V cores add a MAC for this reason, for example `p.mac` in the PULP RI5CY / CV32E40P cores [4][5].

### 2.2 Accumulator width and guard bits
A 32×32 signed product needs up to 64 bits. If you accumulate N such products, you need ⌈log₂N⌉ more bits to make overflow impossible. This design uses a **64-bit accumulator** (the same idea as the `q63_t` accumulators in ARM CMSIS-DSP [6]). For signed operations, it **saturates** to INT64_MAX/INT64_MIN instead of wrapping around, and sets a sticky `OVF` flag. Saturation is standard DSP behaviour because wraparound turns a small overflow into a huge sign error [7].

### 2.3 Q15 fixed-point
Q15 numbers are 16-bit signed fractions in the range [-1, 1). The product of two Q15 values is in Q30 format. `rdacc.q15` turns the Q30 accumulator back into Q15 with `sat16(ACC >>> 15)`. This matches what CMSIS-DSP `arm_fir_q15` does (`__SSAT(acc >> 15, 16)`) [6]. Note the corner case −1.0 × −1.0 = +1.0, which cannot be represented in Q15, so it saturates to 32767.

### 2.4 Radix-4 Modified Booth multiplication
Booth's algorithm [1], in MacSorley's radix-4 form [2], recodes the multiplier B. It looks at overlapping 3-bit groups `{b₂ᵢ₊₁, b₂ᵢ, b₂ᵢ₋₁}`, and each group picks a partial product from {0, ±A, ±2A}:

| b₂ᵢ₊₁ b₂ᵢ b₂ᵢ₋₁ | 000 | 001 | 010 | 011 | 100 | 101 | 110 | 111 |
|---|---|---|---|---|---|---|---|---|
| Partial product | 0 | +A | +A | +2A | −2A | −A | −A | 0 |

`P = Σ PPᵢ · 4ⁱ`. A W-bit multiply therefore needs only **W/2 partial products** instead of W, which halves the adder tree [3]. The MAC extends its operands to 34 bits: sign extension for signed operations, zero extension for `macu`. That way one signed Booth core handles both signed and unsigned multiplication, and the width is even, as radix-4 requires.

## 3. Instruction set extension

The instructions use the RISC-V **custom-0** major opcode `0001011`, which the ISA specification sets aside for non-standard extensions [8]. They use the standard R-type format:

```
 31       25 24   20 19   15 14  12 11    7 6       0
+-----------+-------+-------+------+-------+---------+
|  0000000  |  rs2  |  rs1  |funct3|  rd   | 0001011 |
+-----------+-------+-------+------+-------+---------+
```

| funct3 | Mnemonic | Operation | Value written to rd |
|---|---|---|---|
| 000 | `mac rd, rs1, rs2` | ACC = sat64(ACC + rs1·rs2), signed | ACC[31:0] |
| 001 | `msu rd, rs1, rs2` | ACC = sat64(ACC − rs1·rs2), signed | ACC[31:0] |
| 010 | `mul.acc rd, rs1, rs2` | ACC = rs1·rs2, OVF = 0 (starts a new sum) | ACC[31:0] |
| 011 | `macu rd, rs1, rs2` | ACC = ACC + rs1·rs2, unsigned, modulo 2⁶⁴ | ACC[31:0] |
| 100 | `rdacc.lo rd` | read only | ACC[31:0] |
| 101 | `rdacc.hi rd` | read only | ACC[63:32] |
| 110 | `rdacc.q15 rd` | read only | sext(sat16(ACC >>> 15)) |
| 111 | `clracc rd` | ACC = 0, OVF = 0 | 0 |

* As in RISC-V, nothing is written when `rd = x0`; the accumulator is still updated.
* If the opcode is not custom-0, or funct7 is not 0, the unit raises `illegal_o` and leaves the accumulator unchanged.

## 4. Micro-architecture

```
              STAGE 1 (EX1)                          STAGE 2 (EX2 / WB)
 instr_i ──► decode (opcode/funct3/funct7/rd) ──► s1_* ──┐
 rs1_i  ──► sign/zero extend ─┐                          ├─► 65-bit add/sub ─► saturate ─► ACC (64b)
 rs2_i  ──► sign/zero extend ─┴► Booth 34×34 ──► s1_prod ┘        │                       OVF (sticky)
                                                                  └─► result mux ─► rd_data_o, rd_we_o,
                                                                      (lo/hi/q15)    valid_o, illegal_o
```

* **Throughput:** 1 instruction per cycle. The unit never stalls, so `ready_o` is always 1.
* **Latency:** a fixed 2 cycles from `valid_i` to `valid_o`. The testbench checks this on every result.
* **No hazards:** all accumulator reads and writes happen in stage 2, in program order. Back-to-back dependent `mac` → `mac` → `rdacc` sequences therefore need no forwarding or stalls.
* **Overflow detection:** `acc` and `prod` are sign-extended to 65 bits. Overflow occurs when bits [64] and [63] of the result differ.

## 5. Verification

### 5.1 Method
`tb_mac_unit` uses a **reference model + scoreboard** setup. The reference model is written separately from the RTL and differs from it on purpose:

* it multiplies with the simulator's built-in `*` operator, not with Booth;
* it detects saturation by comparing a 128-bit sum against the limits, not with the 65-bit sign-bit method the RTL uses.

For every instruction, the testbench pushes the expected `rd`, write enable, illegal flag, rd data, full 64-bit accumulator and OVF flag into a FIFO. The monitor compares **all six values, plus the 2-cycle latency**, on every `valid_o`.

### 5.2 Test plan

| # | Test | What it checks |
|---|---|---|
| T1 | Reset | ACC = 0 after reset |
| T2 | Basic arithmetic | mul.acc / mac / msu with back-to-back issue |
| T3 | Sign combinations | (+·+), (+·−), (−·+), (−·−) and the sign-extended high word |
| T4 | Extreme operands | INT32_MAX², INT32_MIN², MIN·MAX, (−1)·MIN = +2³¹ |
| T5 | Saturation | positive and negative 64-bit saturation, sticky OVF, cleared by clracc and mul.acc |
| T6 | Unsigned | UINT32_MAX², modulo-2⁶⁴ wraparound, Σi² for i = 1..10 = **385** |
| T7 | rd = x0 | write suppressed while the accumulator still updates |
| T8 | Illegal | RV32M `MUL`, wrong funct7, `NOP` |
| T9 | Q15 | 0.5·0.5 = 0.25, −0.25, −1·−1 → saturates to 32767, ±saturation |
| T10 | Benchmark: dot product | [1..8]·[8..1] = **120** (known answer) |
| T11 | Benchmark: moving-average FIR | step response y[n] = 2048(n+1), then 16384 (known answer) |
| T12 | Benchmark: low-pass FIR | input is DC plus a Nyquist tone; H(π) = 0, so y[n] = **8000** exactly |
| T13 | Constrained random | 3000 instructions with operands biased toward corner values, ~5% illegal, random bubbles |

`tb_booth_multiplier` checks the 8-bit Booth instance **exhaustively** (all 65,536 operand pairs). It checks the 34-bit instance on 9 corner cases plus 20,000 random pairs.

**Checking the checker:** I made a copy of `mac_unit.v` with the saturation logic disabled and ran the testbench on it. The testbench reported FAIL on the T5 saturation tests and in the random regression, which shows it really detects faulty hardware.

### 5.3 Results (from `sim/mac_sim.log` and `sim/booth_sim.log`)

```
Booth multiplier : checks performed : 85545   errors : 0   >>> ALL TESTS PASSED <<<

MAC unit         : FUNCTIONAL COVERAGE
                   mac=570 msu=338 mul.acc=378 macu=381 rdacc.lo=346 rdacc.hi=386 rdacc.q15=393 clracc=374
                   illegal=162  saturation events=7  rd=x0 writes=360  bubble gaps=684
                   instructions issued : 3328
                   checks performed    : 3351
                   errors              : 0
                   >>> ALL TESTS PASSED <<<
```

DSP benchmark results:

| n | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8..11 |
|---|---|---|---|---|---|---|---|---|---|
| Moving average: DUT y[n] | 2048 | 4096 | 6144 | 8192 | 10240 | 12288 | 14336 | 16384 | 16384 |
| Moving average: analytic | 2048 | 4096 | 6144 | 8192 | 10240 | 12288 | 14336 | 16384 | 16384 |
| Low-pass FIR: DUT y[n] | 437 | 1375 | 2812 | 4750 | 6312 | 7375 | 7937 | **8000** | **8000** |

* The dot product runs at 9 instructions in 9 cycles, i.e. **1 instruction per cycle**.
* An 8-tap FIR takes **9 instructions per output sample**: 8 MAC operations and 1 `rdacc.q15`.

## 6. The 5-stage RISC-V processor

`rtl/rv32_core.v` is a classic in-order IF/ID/EX/MEM/WB pipeline:
- **ISA:** RV32I plus `MUL/MULH/MULHSU/MULHU`, plus the 8 MAC instructions.
- **Data hazards:** full forwarding from EX/MEM and MEM/WB, plus a write-first register-file bypass.
- **Load-use and MAC-use hazards:** one stall bubble.
- **Branches:** resolved in EX, with a 2-cycle flush.

The MAC unit's two internal registers line up exactly with the core's EX/MEM and MEM/WB registers, so MAC instructions flow down the pipeline like any other instruction. The testbench checks this alignment on every MAC write-back.

| Program | Result | Cycles | CPI | Notes |
|---|---|---|---|---|
| `isa_test` | PASS (18/18) | 348 | 1.160 | 8 hazard stalls resolved correctly |
| `fir_mac_loop` | PASS, 128/128 bit-exact | 19,724 | 1.262 | 7 instr/tap |
| `fir_rv32im_loop` | PASS, 128/128 bit-exact | 31,363 | 1.166 | 12 instr/tap |
| `fir_mac_unrolled` | PASS, 128/128 bit-exact | 7,180 | 1.037 | 3.5 cycles/tap |
| `fir_rv32im_unrolled` | PASS, 128/128 bit-exact | 19,203 | 1.034 | |

FIR results:
- **Speed-up from the MAC instructions:** 1.59× looped, 2.67× unrolled, with 2.6× smaller code.
- **Filter quality:** the unwanted 0.3-cycles/sample tone is attenuated by 60.1 dB, matching the filter design.
- **Mutation tests:** with WB forwarding disabled, or with the load-use stall disabled, `isa_test` fails.

## 7. Synthesis (Yosys 0.70 + nextpnr-ecp5)

**Generic gate-level synthesis** (2-input gates + D flip-flops, flattened):

| Metric | Value |
|---|---|
| Total cells | 9,532 (NAND 5,027 · AND 1,785 · XOR 1,459 · …) |
| Flip-flops | 179 (exactly the 74 + 105 pipeline/state bits of the RTL), no latches |
| Estimated transistors | ≈ 55,456 |
| Logic depth | 127 gate levels (operands → multiplier → `s1_prod`) |
| Multiplier share | 7,852 of 9,990 cells (≈ 79 %) in the hierarchical run |

A comparison run swapped the Booth module for `*` and used Yosys's own Booth + Wallace-tree generator (`synth -booth`). It needs 21 % fewer gates (7,541), but its depth is the same (128). The ripple-carry adders set the critical path, not the partial-product reduction.

**Lattice ECP5 LFE5U-85F**: placed and routed with nextpnr. For timing, all I/O is registered through `fmax_wrapper.v`, so every path is register-to-register.

| | A: MAC, Booth (as designed) | B: MAC, hard DSP blocks (comparison) | C: full RV32IM core + MAC |
|---|---|---|---|
| LUT4 | 5,108 | 611 | 6,486 |
| Flip-flops | 179 | 179 | 730 |
| MULT18X18D | 0 | 4 | 4 |
| Logic cells after P&R | 4,854 (5.8 %) | 963 (1.2 %) | 7,566 (9.0 %) |
| Critical path | 17.73 ns | 12.69 ns | 28.94 ns |
| **Fmax** | **56.4 MHz** | **78.8 MHz** | **34.6 MHz** |

In the full core, the critical path goes through the single-cycle RV32M `mul` multiplier in EX, not through the pipelined MAC unit. The report includes Yosys RTL schematics (rendered with netlistsvg), floorplans and routing-density maps of every design, critical-path plots and slack histograms.

**Gate-level simulation:** the netlist produced by Yosys passes the unchanged `tb_mac_unit` testbench (3,351 checks, 0 errors). This simulation has zero delay, so it checks function only; the timing numbers above come from nextpnr.

To run the synthesis flow (install with `pip install yowasp-yosys yowasp-nextpnr-ecp5` or use OSS CAD Suite):
```
YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 sh run_synth.sh
```

## 8. How to run

1. Install [Icarus Verilog](https://bleyer.org/icarus/) (`winget install Icarus.Verilog` on Windows). It includes GTKWave.
2. From the project folder, run:
   * Windows: `run_sim.bat`
   * Linux / macOS: `sh run_sim.sh`
3. Open the waveform with `gtkwave sim/mac_unit.vcd`. Useful signals to add: `clk`, `valid_i`, `instr_i`, `rs1_i`, `rs2_i`, `dut.s1_prod`, `valid_o`, `rd_data_o`, `acc_o`, `ovf_o`.

You can also compile manually:
```
iverilog -g2005 -Wall -o tb_mac.vvp rtl/booth_multiplier.v rtl/mac_unit.v tb/tb_mac_unit.v
vvp tb_mac.vvp
```
The code is plain Verilog-2005 with no vendor primitives, so it also runs unchanged in ModelSim/Questa, Vivado XSim or EDA Playground.

**Processor simulations.** This needs Python 3 with numpy. It assembles all programs, runs them on the 5-stage core, and checks the results:
```
python sw/run_cpu_sims.py
```

**Report figures and PDF.** Run these after the simulations and `run_synth.sh`. The schematics also need `npm install netlistsvg` and `python report/scripts/svg2pdf.py`.
```
python report/scripts/plot_cpu_figures.py
python report/scripts/plot_synth_figures.py
cd report && pdflatex report.tex && pdflatex report.tex
```

## 9. References

1. A. D. Booth, "A signed binary multiplication technique," *Quarterly Journal of Mechanics and Applied Mathematics*, vol. 4, no. 2, pp. 236–240, 1951.
2. O. L. MacSorley, "High-speed arithmetic in binary computers," *Proceedings of the IRE*, vol. 49, no. 1, pp. 67–91, Jan. 1961.
3. B. Parhami, *Computer Arithmetic: Algorithms and Hardware Designs*, 2nd ed., Oxford University Press, 2010 (chapters on high-radix and Booth-recoded multipliers).
4. M. Gautschi et al., "Near-Threshold RISC-V Core With DSP Extensions for Scalable IoT Endpoint Devices," *IEEE Transactions on VLSI Systems*, vol. 25, no. 10, pp. 2700–2713, Oct. 2017.
5. OpenHW Group, *CV32E40P User Manual*, "Xpulp instruction extensions": multiply-accumulate (`p.mac`, `p.msu`). https://docs.openhwgroup.org/projects/cv32e40p-user-manual/
6. ARM Ltd., *CMSIS-DSP Library*, `arm_fir_q15` and `arm_dot_prod_q15` (64-bit accumulator, `__SSAT(acc >> 15, 16)`). https://arm-software.github.io/CMSIS-DSP/
7. R. G. Lyons, *Understanding Digital Signal Processing*, 3rd ed., Prentice Hall, 2010 (fixed-point arithmetic, overflow and saturation).
8. A. Waterman and K. Asanović (eds.), *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*, v20191213, RISC-V International (base opcode map, `custom-0` = `0001011`; chapter "Extending RISC-V").
9. *IEEE Standard for Verilog Hardware Description Language*, IEEE Std 1364-2005.
10. D. A. Patterson and J. L. Hennessy, *Computer Organization and Design RISC-V Edition*, 2nd ed., Morgan Kaufmann, 2020 (5-stage pipeline, forwarding, hazards).
11. C. Wolf, *Yosys Open SYnthesis Suite*, https://yosyshq.net/yosys/ ; D. Shah et al., "Yosys+nextpnr: An open source framework from Verilog to bitstream for commercial FPGAs," IEEE FCCM 2019.
12. N. Turley, *netlistsvg*, https://github.com/nturley/netlistsvg
