@echo off
REM ==========================================================================
REM run_sim.bat - compile and run both testbenches with Icarus Verilog
REM   Requires: Icarus Verilog (iverilog / vvp) on PATH, default C:\iverilog\bin
REM   Output  : terminal log + sim\*.log files + sim\mac_unit.vcd waveform
REM ==========================================================================
set PATH=C:\iverilog\bin;%PATH%
if not exist sim mkdir sim
cd sim

echo === [1/2] Booth multiplier unit test ===
iverilog -g2005 -Wall -o tb_booth.vvp ..\rtl\booth_multiplier.v ..\tb\tb_booth_multiplier.v || goto :error
vvp -n tb_booth.vvp > booth_sim.log
type booth_sim.log

echo === [2/2] MAC unit system test ===
iverilog -g2005 -Wall -o tb_mac.vvp ..\rtl\booth_multiplier.v ..\rtl\mac_unit.v ..\tb\tb_mac_unit.v || goto :error
vvp -n tb_mac.vvp > mac_sim.log
type mac_sim.log

echo.
echo Logs: sim\booth_sim.log, sim\mac_sim.log   Waveform: sim\mac_unit.vcd
echo View waveform with:  gtkwave sim\mac_unit.vcd
cd ..
exit /b 0

:error
echo Compilation failed.
cd ..
exit /b 1
