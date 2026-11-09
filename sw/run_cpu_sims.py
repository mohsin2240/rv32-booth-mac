"""
run_cpu_sims.py - build all programs, simulate them on the RISC-V SoC and
collect the results.

Steps
  1. python sw/build.py            (data, golden values, program images)
  2. iverilog: compile tb/tb_riscv_soc.v + rtl (once)
  3. vvp: run each program from build/manifest.json
       - logs        -> sim/cpu/<prog>.log
       - outputs     -> sim/cpu/<prog>.yout.txt
       - trace / VCD -> sim/cpu/<prog>.trace.csv / .vcd  (selected programs)
  4. parse the 'RESULT ...' lines -> sim/cpu/results.json and a summary

Usage:  python sw/run_cpu_sims.py [--iverilog-bin C:/iverilog/bin]
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "sim", "cpu")
RTL = ["rtl/booth_multiplier.v", "rtl/mac_unit.v", "rtl/rv32_core.v", "rtl/riscv_soc.v"]
TRACE_PROGS = {"isa_test", "fir_mac_loop", "fir_rv32im_loop", "fir_mac_unrolled"}
VCD_PROGS = {"fir_mac_loop"}


def tool(name, bindir):
    exe = name + (".exe" if os.name == "nt" else "")
    p = os.path.join(bindir, exe) if bindir else exe
    return p if (not bindir or os.path.exists(p)) else name


def main():
    bindir = None
    if "--iverilog-bin" in sys.argv:
        bindir = sys.argv[sys.argv.index("--iverilog-bin") + 1]
    elif os.path.isdir("C:/iverilog/bin"):
        bindir = "C:/iverilog/bin"

    subprocess.run([sys.executable, os.path.join(ROOT, "sw", "build.py")], check=True, cwd=ROOT)
    os.makedirs(OUT, exist_ok=True)

    vvp_file = os.path.join(OUT, "tb_riscv_soc.vvp")
    subprocess.run([tool("iverilog", bindir), "-g2005", "-Wall", "-o", vvp_file]
                   + RTL + ["tb/tb_riscv_soc.v"], check=True, cwd=ROOT)

    manifest = json.load(open(os.path.join(ROOT, "build", "manifest.json")))
    results = []
    for m in manifest:
        name = m["name"]
        args = [tool("vvp", bindir), "-n", vvp_file,
                "+IMEM=" + m["imem"], "+DMEM=" + m["dmem"], "+NAME=" + name]
        if "golden" in m:
            args += ["+GOLDEN=" + m["golden"], "+YADDR=%x" % m["yaddr"], "+NOUT=%d" % m["nout"],
                     "+YOUT=" + "sim/cpu/" + name + ".yout.txt"]
        if name in TRACE_PROGS:
            args.append("+TRACE=" + "sim/cpu/" + name + ".trace.csv")
        if name in VCD_PROGS:
            args.append("+VCD=" + "sim/cpu/" + name + ".vcd")
        r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
        with open(os.path.join(OUT, name + ".log"), "w") as f:
            f.write(r.stdout)
        line = [l for l in r.stdout.splitlines() if l.startswith("RESULT ")]
        if not line:
            print(r.stdout[-2000:], r.stderr[-2000:])
            raise SystemExit("no RESULT line for " + name)
        kv = dict(re.findall(r"(\w+)=(\S+)", line[0]))
        for k in ("cycles", "instret", "stalls", "flushes", "macs", "errors"):
            kv[k] = int(kv[k])
        kv["cpi"] = kv["cycles"] / kv["instret"]
        kv["n_instr_static"] = m["n_instr_static"]
        results.append(kv)

    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(results, f, indent=2)

    print("\n%-22s %-6s %9s %9s %6s %7s %8s %6s" %
          ("program", "status", "cycles", "instret", "CPI", "stalls", "flushes", "MACs"))
    for r in results:
        print("%-22s %-6s %9d %9d %6.3f %7d %8d %6d" % (r["name"], r["status"], r["cycles"],
              r["instret"], r["cpi"], r["stalls"], r["flushes"], r["macs"]))
    fails = [r["name"] for r in results if r["status"] != "PASS"]
    print("\nALL PROGRAMS PASSED" if not fails else "FAILED: " + ", ".join(fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
