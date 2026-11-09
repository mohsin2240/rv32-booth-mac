"""
plot_cpu_figures.py - figures for the RISC-V processor chapters, generated
from the real simulation outputs.

Inputs  (run sw/run_cpu_sims.py first)
  build/*.lst                    assembler listings (pc -> instruction text)
  build/fir_signal.json          FIR input, taps, golden and float reference
  sim/cpu/*.trace.csv            per-cycle pipeline trace from tb_riscv_soc
  sim/cpu/fir_mac_loop.vcd       waveform dump
  sim/cpu/fir_mac_loop.yout.txt  outputs written by the CPU
  sim/cpu/results.json           cycle counts / counters
Outputs (report/figures/)
  pipe_isa_mac_hazard.pdf, pipe_fir_loop.pdf, pipe_fir_unrolled.pdf
  wave_cpu_mac.pdf, fir_time.pdf, fir_spectrum.pdf, fir_freqresp.pdf,
  perf_cycles.pdf, perf_breakdown.pdf
"""
import csv
import json
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FIG = os.path.join(ROOT, "report", "figures")
sys.path.insert(0, HERE)
from plot_waveform import parse_vcd, value_at  # noqa: E402

plt.rcParams.update({"font.size": 9, "axes.titlesize": 10, "figure.dpi": 150,
                     "savefig.bbox": "tight", "font.family": "DejaVu Sans"})
BLUE, ORANGE, GREEN, RED, GREY = "#1f4e9a", "#e07b00", "#2e8b57", "#c0392b", "#9a9a9a"
STAGES = ["IF", "ID", "EX", "MEM", "WB"]
STAGE_COL = {"IF": "#dbe7f7", "ID": "#c6dbf2", "EX": "#a9c7ec", "MEM": "#8db4e4", "WB": "#719fd9"}


# ---------------------------------------------------------------- helpers
def listing(prog):
    m = {}
    for line in open(os.path.join(ROOT, "build", prog + ".lst")):
        parts = line.rstrip("\n").split(None, 2)
        if len(parts) < 3:
            continue
        txt = parts[2].replace("(cont.) ", "").strip()
        txt = " ".join(txt.split())
        if "(cont.)" in line:
            txt += " (2)"
        m[int(parts[0], 16)] = txt
    return m


def read_trace(prog):
    rows = []
    with open(os.path.join(ROOT, "sim", "cpu", prog + ".trace.csv")) as f:
        for r in csv.reader(f):
            v = [int(x, 16) if i in (1, 4, 6, 8, 10) else int(x) for i, x in enumerate(r)]
            rows.append({"cyc": v[0], "if_pc": v[1], "fstop": v[2], "id_v": v[3], "id_pc": v[4],
                         "ex_v": v[5], "ex_pc": v[6], "mem_v": v[7], "mem_pc": v[8],
                         "wb_v": v[9], "wb_pc": v[10], "stall": v[11], "flush": v[12],
                         "fam": v[13], "faw": v[14], "fbm": v[15], "fbw": v[16], "mac": v[17]})
    return rows


# ------------------------------------------------ classic pipeline diagram
def pipeline_diagram(prog, c0, c1, title, out, max_rows=18):
    """Instruction x cycle diagram reconstructed from the trace."""
    tr = read_trace(prog)
    lst = listing(prog)
    T = {r["cyc"]: r for r in tr}
    inst = []                                   # list of dicts: pc, cells{cyc: label}

    for t in range(max(0, c0 - 6), c1 + 1):
        r = T.get(t)
        if not r or not r["ex_v"]:
            continue
        p = r["ex_pc"]
        cells = {t: "EX", t + 1: "MEM", t + 2: "WB"}
        s = t - 1
        ids = []
        while s in T and T[s]["id_v"] and T[s]["id_pc"] == p and len(ids) < 4:
            ids.append(s); s -= 1
        for k, c in enumerate(sorted(ids)):
            cells[c] = "ID" if k == len(ids) - 1 else "ID*"      # * = stalled
        first = min(ids) if ids else t
        s = first - 1
        ifs = []
        while s in T and T[s]["if_pc"] == p and len(ifs) < 4:
            ifs.append(s); s -= 1
        for k, c in enumerate(sorted(ifs)):
            cells[c] = "IF" if k == len(ifs) - 1 else "IF*"
        fwd = []
        if r["fam"] or r["fbm"]:
            fwd.append("MEM")
        if r["faw"] or r["fbw"]:
            fwd.append("WB")
        inst.append({"pc": p, "cells": cells, "start": min(cells), "mac": r["mac"],
                     "fwd": fwd, "flushed": False})

    # instructions squashed by a taken branch (never reach EX)
    for t in range(c0, c1 + 1):
        r = T.get(t)
        if not r or not r["flush"]:
            continue
        if r["id_v"]:
            p = r["id_pc"]
            cells = {t: "ID", t + 1: "x"}
            if (t - 1) in T and T[t - 1]["if_pc"] == p:
                cells[t - 1] = "IF"
            inst.append({"pc": p, "cells": cells, "start": min(cells), "mac": 0, "fwd": [], "flushed": True})
        if not r["fstop"]:
            p = r["if_pc"]
            inst.append({"pc": p, "cells": {t: "IF", t + 1: "x"}, "start": t, "mac": 0,
                         "fwd": [], "flushed": True})

    inst = [i for i in inst if any(c0 <= c <= c1 for c in i["cells"])]
    inst.sort(key=lambda i: (i["start"], i["flushed"]))
    inst = inst[:max_rows]

    ncyc = c1 - c0 + 1
    fig, ax = plt.subplots(figsize=(min(11, 1.6 + 0.48 * ncyc), 0.8 + 0.34 * len(inst)))
    for row, i in enumerate(inst):
        y = len(inst) - 1 - row
        for c, lab in i["cells"].items():
            if not (c0 <= c <= c1):
                continue
            x = c - c0
            base = lab.rstrip("*")
            if lab == "x":
                ax.text(x + 0.5, y + 0.5, "flush", ha="center", va="center", fontsize=6.5, color=RED)
                continue
            col = STAGE_COL.get(base, "white")
            hatch = None
            if lab.endswith("*"):
                col, hatch = "#f3d9d9", "///"
            if i["mac"] and base in ("EX", "MEM"):
                col = "#ffd9a8"
            if i["flushed"]:
                col = "#e6e6e6"
            ax.add_patch(Rectangle((x + 0.04, y + 0.08), 0.92, 0.84, facecolor=col,
                                   edgecolor="#555555", lw=0.5, hatch=hatch))
            txt = base
            if i["mac"] and base == "EX":
                txt = "MAC1"
            elif i["mac"] and base == "MEM":
                txt = "MAC2"
            elif lab.endswith("*"):
                txt = "stall"
            ax.text(x + 0.5, y + 0.5, txt, ha="center", va="center", fontsize=6.5)
            if base == "EX" and i["fwd"]:
                ax.text(x + 0.5, y + 0.98, "fwd " + "+".join(i["fwd"]), ha="center", va="bottom",
                        fontsize=5, color=GREEN)
        name = lst.get(i["pc"], "?")
        ax.text(-0.2, y + 0.5, "%04x  %s" % (i["pc"], name[:26]), ha="right", va="center",
                fontsize=7, family="monospace", color=GREY if i["flushed"] else "black")
    ax.set_xlim(0, ncyc)
    ax.set_ylim(-0.1, len(inst) + 0.2)
    ax.set_xticks([k + 0.5 for k in range(ncyc)])
    ax.set_xticklabels([str(c0 + k) for k in range(ncyc)], fontsize=7)
    ax.set_xlabel("clock cycle")
    ax.set_yticks([])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.set_title(title)
    fig.savefig(os.path.join(FIG, out))
    plt.close(fig)


def find_cycle(prog, pc, stage="ex", nth=1):
    for r in read_trace(prog):
        if r[stage + "_v"] and r[stage + "_pc"] == pc:
            nth -= 1
            if nth == 0:
                return r["cyc"]
    raise RuntimeError("pc %x not found" % pc)


# ------------------------------------------------------ waveform (VCD)
def wave_cpu():
    lst = listing("fir_mac_loop")
    core = "dut.u_core."
    sig = [("clk", "clk", 1, None),
           (core + "pc_q", "IF  pc", 32, "asm"),
           (core + "if_id_pc", "ID", 32, "asm"),
           (core + "id_ex_pc", "EX", 32, "asm"),
           (core + "ex_mem_pc", "MEM", 32, "asm"),
           (core + "mem_wb_pc", "WB", 32, "asm"),
           (core + "ex_taken", "flush", 1, None),
           (core + "u_mac.valid_i", "mac.valid_i", 1, None),
           (core + "u_mac.rs1_i", "mac.rs1 (x[n])", 32, "s"),
           (core + "u_mac.rs2_i", "mac.rs2 (h[k])", 32, "s"),
           (core + "u_mac.s1_prod", "mac.s1_prod", 64, "s"),
           (core + "u_mac.acc_o", "mac.acc", 64, "s"),
           (core + "wb_we", "rf write", 1, None),
           (core + "mem_wb_rd", "rd", 5, "u"),
           (core + "wb_value", "rd value", 32, "s")]
    # a bus is drawn grey (no value) while its qualifying valid signal is low
    valid = {core + "if_id_pc": core + "if_id_valid", core + "id_ex_pc": core + "id_ex_valid",
             core + "ex_mem_pc": core + "ex_mem_valid", core + "mem_wb_pc": core + "mem_wb_valid",
             core + "u_mac.rs1_i": core + "u_mac.valid_i", core + "u_mac.rs2_i": core + "u_mac.valid_i",
             core + "u_mac.s1_prod": core + "u_mac.s1_valid",
             core + "mem_wb_rd": core + "wb_we", core + "wb_value": core + "wb_we"}
    names = {s[0] for s in sig} | set(valid.values())
    data = parse_vcd(os.path.join(ROOT, "sim", "cpu", "fir_mac_loop.vcd"), names)

    # window: around the end of the 3rd output sample (rdacc.q15 in EX)
    rd_pc = [a for a, t in lst.items() if t.startswith("rdacc.q15")][0]
    t_hit = None
    count = 0
    vt = data[core + "id_ex_pc"]
    for i, (t, v) in enumerate(vt):
        if "x" not in v and int(v, 2) == rd_pc and value_at(data[core + "id_ex_valid"], t) == "1":
            count += 1
            if count == 3:
                t_hit = t
                break
    clk = 10000
    t0, t1 = t_hit - 14 * clk - 2000, t_hit + 4 * clk + 2000

    def short(txt):
        """'addi t0, t0, 2' -> 'addi t0'; keep MAC mnemonics readable."""
        parts = txt.replace(",", " ").split()
        if not parts:
            return txt
        if parts[0] in ("mac", "msu", "macu", "mul.acc"):
            return parts[0]
        return " ".join(parts[:2])

    fig, ax = plt.subplots(figsize=(13, 0.42 * len(sig) + 0.9))
    for row, (name, label, width, kind) in enumerate(sig):
        y = len(sig) - 1 - row
        ch = data[name]
        pts = [t0] + [ct for ct, _ in ch if t0 < ct < t1] + [t1]
        if name in valid:
            pts = sorted(set(pts + [ct for ct, _ in data[valid[name]] if t0 < ct < t1]))
        for a, b in zip(pts[:-1], pts[1:]):
            v = value_at(ch, a)
            xa, xb = a / 1000.0, b / 1000.0
            if width == 1:
                lvl = y + (0.7 if v == "1" else 0.1)
                ax.plot([xa, xb], [lvl, lvl], color=BLUE, lw=1.2)
                nv = value_at(ch, b)
                if b != t1 and nv != v:
                    ax.plot([xb, xb], [y + 0.1, y + 0.7], color=BLUE, lw=1.2)
                continue
            bubble = name in valid and value_at(data[valid[name]], a) != "1"
            if bubble and any(ch2 in "xz" for ch2 in v):
                v = "0" * width
            d = 0.2
            fc = "#eeeeee" if bubble else ("#ffe3bf" if "mac" in label else "#e8eef8")
            ax.fill([xa + d, xb - d, xb, xb - d, xa + d, xa],
                    [y + 0.72, y + 0.72, y + 0.4, y + 0.08, y + 0.08, y + 0.4],
                    facecolor=fc, edgecolor=BLUE, lw=0.8)
            if any(ch2 in "xz" for ch2 in v):
                txt = "x"
            else:
                iv = int(v, 2)
                if bubble:
                    txt = "bubble" if kind == "asm" else ""
                elif kind == "asm":
                    txt = short(lst.get(iv, "%x" % iv))
                elif kind == "s":
                    txt = str(iv - (1 << width) if iv >= 1 << (width - 1) else iv)
                else:
                    txt = str(iv)
            if txt and (xb - xa) > 0.62 * len(txt) + 0.6:
                ax.text((xa + xb) / 2, y + 0.4, txt, ha="center", va="center", fontsize=6.3,
                        family="monospace")
        ax.text(t0 / 1000.0 - 0.8, y + 0.4, label, ha="right", va="center", fontsize=7.5,
                family="monospace")
    first = (t0 // clk + 1) * clk
    for e in range(first, t1, clk):
        ax.axvline(e / 1000.0, color="#cccccc", lw=0.5, ls=":")
    ax.set_xlim(t0 / 1000.0, t1 / 1000.0)
    ax.set_ylim(-0.2, len(sig))
    ax.set_yticks([])
    ax.set_xlabel("simulation time (ns)")
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.set_title("fir_mac_loop on the 5-stage core: last two taps of y[2], loop exit, rdacc.q15 and store")
    fig.savefig(os.path.join(FIG, "wave_cpu_mac.pdf"))
    plt.close(fig)


# ------------------------------------------------------------ FIR plots
def fir_plots():
    d = json.load(open(os.path.join(ROOT, "build", "fir_signal.json")))
    N = d["N"]
    x = np.array(d["x"]) / 32768.0
    g = np.array(d["golden"]) / 32768.0
    yf = np.array(d["y_float"])
    ycpu = np.array([int(l) for l in open(os.path.join(ROOT, "sim", "cpu", "fir_mac_loop.yout.txt"))]) / 32768.0
    n = np.arange(N)

    fig, (a1, a2) = plt.subplots(2, 1, figsize=(10, 5.2), sharex=True,
                                 gridspec_kw={"height_ratios": [3, 1.2]})
    a1.plot(n, x, color=GREY, lw=0.9, label="input x[n] (Q15)")
    a1.plot(n, ycpu, color=BLUE, lw=1.6, label="output y[n] computed by the RISC-V core (MAC unit)")
    a1.plot(n, g, "o", ms=2.3, color=ORANGE, label="golden model (bit-exact)")
    a1.plot(n, 0.5 * np.sin(2 * np.pi * d["f_low"] * n), "--", color=GREEN, lw=0.9,
            label="wanted tone %.3f cycles/sample" % d["f_low"])
    a1.set_ylabel("amplitude")
    a1.legend(loc="upper right", fontsize=7, ncol=2)
    a1.grid(alpha=0.3)
    a1.set_title("16-tap Q15 low-pass FIR executed on the processor (N = %d samples)" % N)
    a2.plot(n, (ycpu - g) * 32768, color=RED, lw=1.0, label="CPU - golden (LSB)")
    a2.plot(n, (ycpu - yf) * 32768, color=GREY, lw=0.8, label="CPU - ideal float filter (LSB)")
    a2.set_ylabel("error (LSB)")
    a2.set_xlabel("sample n")
    a2.legend(loc="upper right", fontsize=7, ncol=2)
    a2.grid(alpha=0.3)
    fig.savefig(os.path.join(FIG, "fir_time.pdf"))
    plt.close(fig)

    # spectra (Hann window)
    w = np.hanning(N)
    f = np.fft.rfftfreq(N)
    X = 20 * np.log10(np.abs(np.fft.rfft(x * w)) / (w.sum() / 2) + 1e-9)
    Y = 20 * np.log10(np.abs(np.fft.rfft(ycpu * w)) / (w.sum() / 2) + 1e-9)
    fig, ax = plt.subplots(figsize=(10, 3.4))
    ax.plot(f, X, color=GREY, lw=1.0, label="input spectrum")
    ax.plot(f, Y, color=BLUE, lw=1.5, label="output spectrum (CPU)")
    for fr, lab in ((d["f_low"], "wanted"), (d["f_high"], "unwanted")):
        ax.axvline(fr, color=ORANGE, ls=":", lw=1)
        ax.text(fr + 0.004, 0, lab, color=ORANGE, fontsize=7, va="top")
    ax.set_xlabel("normalised frequency (cycles/sample)")
    ax.set_ylabel("magnitude (dBFS)")
    ax.set_ylim(-90, 5)
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7)
    ax.set_title("Spectrum before and after filtering on the RISC-V core")
    fig.savefig(os.path.join(FIG, "fir_spectrum.pdf"))
    plt.close(fig)

    # filter frequency response and taps
    h = np.array(d["h"]) / 32768.0
    fr = np.linspace(0, 0.5, 512)
    H = np.array([np.sum(h * np.exp(-2j * np.pi * fq * np.arange(len(h)))) for fq in fr])
    fig, (b1, b2) = plt.subplots(1, 2, figsize=(10, 3.0), gridspec_kw={"width_ratios": [1, 1.6]})
    b1.stem(np.arange(len(h)), np.array(d["h"]), basefmt=" ")
    b1.set_title("Q15 taps h[k]")
    b1.set_xlabel("k")
    b1.grid(alpha=0.3)
    b2.plot(fr, 20 * np.log10(np.abs(H) + 1e-9), color=BLUE)
    b2.axvline(d["FC"], color=GREEN, ls="--", lw=0.9)
    b2.text(d["FC"] + 0.005, -5, "cut-off", color=GREEN, fontsize=7)
    for fq in (d["f_low"], d["f_high"]):
        b2.axvline(fq, color=ORANGE, ls=":", lw=1)
    b2.set_ylim(-80, 5)
    b2.set_xlabel("normalised frequency (cycles/sample)")
    b2.set_ylabel("|H| (dB)")
    b2.set_title("Frequency response of the quantised filter")
    b2.grid(alpha=0.3)
    fig.savefig(os.path.join(FIG, "fir_freqresp.pdf"))
    plt.close(fig)


# ---------------------------------------------------- performance plots
def perf_plots():
    res = {r["name"]: r for r in json.load(open(os.path.join(ROOT, "sim", "cpu", "results.json")))}
    progs = ["fir_rv32im_loop", "fir_mac_loop", "fir_rv32im_unrolled", "fir_mac_unrolled"]
    labels = ["RV32IM\nloop", "MAC unit\nloop", "RV32IM\nunrolled", "MAC unit\nunrolled"]
    cols = [GREY, BLUE, GREY, BLUE]
    cyc = [res[p]["cycles"] for p in progs]
    base = res["fir_rv32im_loop"]["cycles"]
    taps = 128 * 16

    fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.4))
    bars = a.bar(labels, cyc, color=cols, edgecolor="black", lw=0.5)
    for bb, c in zip(bars, cyc):
        a.text(bb.get_x() + bb.get_width() / 2, c, "%d\n(%.2f cyc/tap)" % (c, c / taps),
               ha="center", va="bottom", fontsize=7)
    a.set_ylabel("clock cycles (128 outputs x 16 taps)")
    a.set_ylim(0, max(cyc) * 1.25)
    a.set_title("Measured cycles for the FIR benchmark")
    a.grid(axis="y", alpha=0.3)
    sp = [base / c for c in cyc]
    bars = b.bar(labels, sp, color=cols, edgecolor="black", lw=0.5)
    for bb, s in zip(bars, sp):
        b.text(bb.get_x() + bb.get_width() / 2, s, "%.2fx" % s, ha="center", va="bottom", fontsize=8)
    b.set_ylabel("speed-up vs RV32IM loop")
    b.set_ylim(0, max(sp) * 1.25)
    b.set_title("Speed-up")
    b.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "perf_cycles.pdf"))
    plt.close(fig)

    # cycle breakdown: retired instructions + stall bubbles + flush penalty + fill
    fig, ax = plt.subplots(figsize=(10, 3.0))
    allp = ["isa_test"] + progs
    alll = ["isa_test"] + [l.replace("\n", " ") for l in labels]
    ins = np.array([res[p]["instret"] for p in allp], float)
    stl = np.array([res[p]["stalls"] for p in allp], float)
    fl = np.array([2 * res[p]["flushes"] for p in allp], float)
    tot = np.array([res[p]["cycles"] for p in allp], float)
    other = tot - ins - stl - fl
    frac = lambda v: 100 * v / tot
    ax.barh(alll, frac(ins), color=BLUE, label="useful (retired instructions)")
    ax.barh(alll, frac(stl), left=frac(ins), color=RED, label="load/MAC-use stall bubbles")
    ax.barh(alll, frac(fl), left=frac(ins + stl), color=ORANGE, label="branch flush penalty (2/branch)")
    ax.barh(alll, frac(other), left=frac(ins + stl + fl), color=GREY, label="pipeline fill/drain")
    for i, p in enumerate(allp):
        ax.text(101, i, "CPI %.3f" % res[p]["cpi"], va="center", fontsize=8)
    ax.set_xlim(0, 115)
    ax.set_xlabel("% of clock cycles")
    ax.legend(fontsize=7, ncol=4, loc="upper center", bbox_to_anchor=(0.5, -0.25))
    ax.set_title("Where the cycles go (measured with the core's performance counters)")
    ax.invert_yaxis()
    fig.savefig(os.path.join(FIG, "perf_breakdown.pdf"))
    plt.close(fig)


def main():
    os.makedirs(FIG, exist_ok=True)
    lst = listing("isa_test")
    t12 = [a for a, t in lst.items() if t == "li a3, 12"][0]
    c = find_cycle("isa_test", t12, "ex")
    pipeline_diagram("isa_test", c - 1, c + 13,
                     "isa_test T12: MAC instructions in the pipeline, MAC-use stall and forwarding",
                     "pipe_isa_mac_hazard.pdf")
    lstf = listing("fir_mac_loop")
    inner = [a for a, t in lstf.items() if t.startswith("lh t3")][0]
    c = find_cycle("fir_mac_loop", inner, "ex", nth=3)
    pipeline_diagram("fir_mac_loop", c - 1, c + 15,
                     "fir_mac_loop: inner-loop iterations with the taken-branch flush",
                     "pipe_fir_loop.pdf")
    lstu = listing("fir_mac_unrolled")
    first = [a for a, t in lstu.items() if t.startswith("lh t3, 0(s0)")][0]
    c = find_cycle("fir_mac_unrolled", first, "ex", nth=2)
    pipeline_diagram("fir_mac_unrolled", c, c + 15,
                     "fir_mac_unrolled: lh/lh/lh/lh/mac/mac groups at CPI = 1",
                     "pipe_fir_unrolled.pdf")
    wave_cpu()
    fir_plots()
    perf_plots()
    print("figures written to", FIG)


if __name__ == "__main__":
    main()
