#!/bin/sh
# ===========================================================================
# run_synth.sh - Yosys synthesis + nextpnr place & route + gate-level sim
#   Requires: yosys, nextpnr-ecp5, iverilog/vvp on PATH
#             (or the YoWASP builds:  pip install yowasp-yosys yowasp-nextpnr-ecp5
#              and set YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5)
#   Run from the project root.
# ===========================================================================
set -e
YOSYS=${YOSYS:-yosys}
NEXTPNR=${NEXTPNR:-nextpnr-ecp5}
mkdir -p synth/reports synth/out sim/gate

echo "=== [1/6] Generic gate-level synthesis of the MAC unit ==="
$YOSYS -q -l synth/reports/generic_yosys.log -s synth/synth_generic.ys

echo "=== [2/6] ECP5 synthesis of the MAC unit (Booth / DSP variants) ==="
$YOSYS -q -l synth/reports/ecp5_yosys.log -s synth/synth_ecp5.ys

echo "=== [3/6] Synthesis of the complete RV32IM core with the MAC unit ==="
$YOSYS -q -l synth/reports/core_yosys.log -s synth/synth_core.ys

echo "=== [4/6] RTL netlists for schematics (render with netlistsvg) ==="
$YOSYS -q -l synth/reports/schematics_yosys.log -s synth/schematics.ys

echo "=== [5/6] ECP5 place & route (LFE5U-85F) ==="
for v in booth dsp; do
  $NEXTPNR --85k --package CABGA756 --json synth/out/mac_unit_ecp5_$v.json \
           --freq 100 --timing-allow-fail --seed 1 \
           --report synth/reports/ecp5_${v}_pnr.json \
           --write synth/out/mac_unit_ecp5_${v}_routed.json \
           --log synth/reports/ecp5_${v}_pnr.log > /dev/null 2>&1
  echo "  MAC ($v): $(grep 'Max frequency' synth/reports/ecp5_${v}_pnr.log | tail -1 | sed 's/.*: //')"
done
$NEXTPNR --85k --package CABGA756 --json synth/out/rv32_core_ecp5.json \
         --freq 50 --timing-allow-fail --seed 1 \
         --report synth/reports/core_ecp5_pnr.json \
         --write synth/out/rv32_core_ecp5_routed.json \
         --log synth/reports/core_ecp5_pnr.log > /dev/null 2>&1
echo "  core     : $(grep 'Max frequency' synth/reports/core_ecp5_pnr.log | tail -1 | sed 's/.*: //')"

echo "=== [6/6] Gate-level simulation of the synthesized MAC netlist ==="
cd sim/gate
iverilog -g2005 -o tb_gate.vvp ../../synth/out/mac_unit_netlist.v ../../tb/tb_mac_unit.v
vvp -n tb_gate.vvp | tee mac_gate_sim.log | tail -8
