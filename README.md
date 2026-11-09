# RV32 Booth-MAC Core

Project page for a radix-4 Booth multiply-accumulate (MAC) unit integrated into a 5-stage pipelined RISC-V (RV32IM) processor. The design was taken from Verilog through simulation, Yosys synthesis and nextpnr place-and-route on a Lattice ECP5 FPGA.

**Live page:** https://mohsin2240.github.io/rv32-booth-mac/

The page includes:
- the pipeline architecture, with the MAC unit spanning the EX and MEM stages;
- an interactive floorplan of the placed and routed designs on the ECP5 die, with per-block layers, routing density, the critical path, zoom, pan and a mini-map;
- the sign-off checks: unit testbenches, gate-level simulation, ISA test, bit-exact FIR results and mutation tests;
- FIR filter performance with and without the custom MAC instructions.

`index.html` is a single self-contained file. The only external resource is Google Fonts.
