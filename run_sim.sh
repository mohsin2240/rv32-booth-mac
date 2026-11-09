#!/bin/sh
# ===========================================================================
# run_sim.sh - compile and run both testbenches with Icarus Verilog
#   Requires: iverilog / vvp on PATH
#   Output  : terminal log + sim/*.log files + sim/mac_unit.vcd waveform
# ===========================================================================
set -e
mkdir -p sim
cd sim

echo "=== [1/2] Booth multiplier unit test ==="
iverilog -g2005 -Wall -o tb_booth.vvp ../rtl/booth_multiplier.v ../tb/tb_booth_multiplier.v
vvp -n tb_booth.vvp | tee booth_sim.log

echo "=== [2/2] MAC unit system test ==="
iverilog -g2005 -Wall -o tb_mac.vvp ../rtl/booth_multiplier.v ../rtl/mac_unit.v ../tb/tb_mac_unit.v
vvp -n tb_mac.vvp | tee mac_sim.log

echo
echo "Logs: sim/booth_sim.log, sim/mac_sim.log   Waveform: sim/mac_unit.vcd"
