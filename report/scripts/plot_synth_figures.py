"""
plot_synth_figures.py - synthesis and FPGA implementation figures.

Inputs
  synth/reports/*.txt               Yosys 'stat' reports
  synth/reports/*_pnr.json          nextpnr timing/utilisation reports
  synth/reports/*_pnr.log           nextpnr logs (slack histograms)
  synth/out/*_routed.json           placed & routed designs (nextpnr --write)
Outputs (report/figures/)
  syn_cells.pdf, syn_area.pdf, fpga_resources.pdf, fpga_timing.pdf,
  fpga_critpath.pdf, fpga_slack.pdf, floorplan_mac.pdf, floorplan_core.pdf
"""
import json
import os
import re

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
REP = os.path.join(ROOT, "synth", "reports")
OUT = os.path.join(ROOT, "synth", "out")
FIG = os.path.join(ROOT, "report", "figures")

plt.rcParams.update({"font.size": 9, "axes.titlesize": 10, "savefig.bbox": "tight",
                     "font.family": "DejaVu Sans"})
BLUE, ORANGE, GREEN, RED, GREY, PURPLE = "#1f4e9a", "#e07b00", "#2e8b57", "#c0392b", "#9a9a9a", "#7b4fa0"


# ------------------------------------------------------------- parsers
def yosys_stat(fname, module=None):
    """Return {celltype: count} for the last (or named) module in a stat report."""
    txt = open(os.path.join(REP, fname)).read()
    blocks = re.split(r"^=== (.+) ===$", txt, flags=re.M)
    res = {}
    for name, body in zip(blocks[1::2], blocks[2::2]):
        if module and module not in name:
            continue
        cells = {}
        for m in re.finditer(r"^\s+(\d+)\s+(\$?[\w$]+)\s*$", body, re.M):
            cells[m.group(2)] = int(m.group(1))
        tot = re.search(r"^\s+(\d+) cells$", body, re.M)
        cells["__total"] = int(tot.group(1)) if tot else 0
        res[name] = cells
    return res


def pnr_fmax(log):
    vals = re.findall(r"Max frequency for clock[^:]*: ([\d.]+) MHz", open(os.path.join(REP, log)).read())
    return float(vals[-1])


def pnr_util(log):
    txt = open(os.path.join(REP, log)).read()
    sec = txt[txt.rfind("Device utilisation"):]
    u = {}
    for m in re.finditer(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)", sec):
        u.setdefault(m.group(1), (int(m.group(2)), int(m.group(3))))
    return u


def slack_hist(log):
    txt = open(os.path.join(REP, log)).read()
    sec = txt[txt.rfind("Slack histogram"):]
    rows = re.findall(r"\[\s*(-?\d+),\s*(-?\d+)\)\s*\|(\**)\+?\s*$", sec, re.M)
    scale = re.search(r"legend: \* represents (\d+) endpoint", sec)
    sc = int(scale.group(1)) if scale else 1
    return [(int(a) / 1000.0, int(b) / 1000.0, len(s) * sc) for a, b, s in rows]


def crit_path(rep):
    d = json.load(open(os.path.join(REP, rep)))
    paths = d.get("critical_paths", [])
    best = None
    for p in paths:
        if p.get("from", "").startswith("posedge") and p.get("to", "").startswith("posedge"):
            tot = sum(s["delay"] for s in p["path"])
            if best is None or tot > best[0]:
                best = (tot, p)
    return best[1] if best else None


# --------------------------------------------------- synthesis figures
def syn_figures():
    gen = yosys_stat("generic_stat.txt")
    mac = list(gen.values())[-1]
    gates = {k.strip("$_"): v for k, v in mac.items() if k.startswith("$_") and "DFF" not in k}
    ffs = sum(v for k, v in mac.items() if "DFF" in k)
    items = sorted(gates.items(), key=lambda kv: -kv[1]) + [("D flip-flops", ffs)]

    fig, ax = plt.subplots(figsize=(6.2, 3.2))
    names = [k for k, _ in items]
    vals = [v for _, v in items]
    cols = [BLUE] * (len(items) - 1) + [ORANGE]
    ax.barh(names, vals, color=cols)
    for i, v in enumerate(vals):
        ax.text(v + 40, i, str(v), va="center", fontsize=7)
    ax.invert_yaxis()
    ax.set_xlabel("number of cells")
    ax.set_title("mac_unit after generic synthesis (%d cells)" % mac["__total"])
    ax.grid(axis="x", alpha=0.3)
    fig.savefig(os.path.join(FIG, "syn_cells.pdf"))
    plt.close(fig)

    hier = yosys_stat("generic_hier_stat.txt")
    core = yosys_stat("core_generic_hier_stat.txt")
    g = lambda d, key: [v["__total"] for k, v in d.items() if key in k][0]
    mac_parts = [("Booth multiplier", g(hier, "booth")), ("MAC control + accumulator", g(hier, "mac_unit"))]
    core_parts = [("RV32 pipeline, register file,\nRV32M multiplier", g(core, "rv32_core")),
                  ("MAC control + accumulator", g(core, "mac_unit")), ("Booth multiplier", g(core, "booth"))]
    fig, axs = plt.subplots(1, 2, figsize=(9.5, 3.4))
    for ax, parts, title, cols in ((axs[0], mac_parts, "MAC unit (stand-alone)", [ORANGE, BLUE]),
                                   (axs[1], core_parts, "Complete processor (rv32_core)", [GREY, BLUE, ORANGE])):
        vals = [v for _, v in parts]
        wedges, _ = ax.pie(vals, colors=cols, startangle=90, counterclock=False,
                           wedgeprops=dict(width=0.38, edgecolor="white"))
        ax.text(0, 0, "%d\ngates" % sum(vals), ha="center", va="center", fontsize=9, weight="bold")
        ax.legend(wedges, ["%s: %d (%.0f%%)" % (n, v, 100 * v / sum(vals)) for n, v in parts],
                  loc="upper center", bbox_to_anchor=(0.5, 0.0), fontsize=7, frameon=False)
        ax.set_title(title)
    fig.savefig(os.path.join(FIG, "syn_area.pdf"))
    plt.close(fig)


# ------------------------------------------------------- FPGA figures
def fpga_figures():
    designs = [("MAC unit\n(Booth, LUTs)", "ecp5_booth_pnr.log", "ecp5_booth_pnr.json"),
               ("MAC unit\n(DSP blocks)", "ecp5_dsp_pnr.log", "ecp5_dsp_pnr.json"),
               ("Full RV32IM core\n+ MAC unit", "core_ecp5_pnr.log", "core_ecp5_pnr.json")]
    utils = [pnr_util(l) for _, l, _ in designs]
    fmax = [pnr_fmax(l) for _, l, _ in designs]

    # resources (absolute numbers, log scale)
    res = [("TRELLIS_COMB", "LUT/logic cells"), ("TRELLIS_FF", "flip-flops"),
           ("TRELLIS_RAMW", "LUT-RAM write ports"), ("MULT18X18D", "18x18 DSP multipliers"),
           ("TRELLIS_IO", "I/O pins")]
    fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.6), gridspec_kw={"width_ratios": [2.2, 1]})
    w = 0.26
    x = np.arange(len(res))
    cols = [BLUE, GREEN, ORANGE]
    for i, ((name, _, _), u) in enumerate(zip(designs, utils)):
        vals = [u.get(r, (0, 1))[0] for r, _ in res]
        bars = a.bar(x + (i - 1) * w, [max(v, 0.8) for v in vals], w, color=cols[i],
                     label=name.replace("\n", " "))
        for bb, v in zip(bars, vals):
            a.text(bb.get_x() + bb.get_width() / 2, max(v, 0.8) * 1.08, str(v), ha="center",
                   va="bottom", fontsize=6, rotation=90)
    a.set_yscale("log")
    a.set_ylim(0.7, 3e5)
    a.set_xticks(x)
    a.set_xticklabels([l for _, l in res], fontsize=7)
    a.set_ylabel("count (log scale)")
    a.legend(fontsize=7, loc="upper right")
    a.set_title("ECP5 LFE5U-85F resources after place & route")
    a.grid(axis="y", alpha=0.3, which="both")
    bars = b.bar([n for n, _, _ in designs], fmax, color=cols)
    for bb, f in zip(bars, fmax):
        b.text(bb.get_x() + bb.get_width() / 2, f + 1, "%.1f MHz" % f, ha="center", fontsize=8)
    b.set_ylim(0, max(fmax) * 1.25)
    b.set_ylabel("Fmax (MHz)")
    b.set_title("Post-route maximum frequency")
    b.tick_params(axis="x", labelsize=7)
    b.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "fpga_resources.pdf"))
    plt.close(fig)

    # critical paths: cumulative delay staircase
    fig, ax = plt.subplots(figsize=(10, 3.4))
    for (name, _, rep), col in zip(designs, cols):
        p = crit_path(rep)
        if not p:
            continue
        t = 0.0
        xs, ys = [0], [0.0]
        logic = routing = 0.0
        for k, s in enumerate(p["path"]):
            t += s["delay"]
            xs.append(k + 1)
            ys.append(t)
            if s["type"] == "routing":
                routing += s["delay"]
            else:
                logic += s["delay"]
        ax.step(xs, ys, where="post", color=col, lw=1.6,
                label="%s: %.2f ns (logic %.1f / routing %.1f)" % (name.replace("\n", " "), t, logic, routing))
    ax.set_xlabel("path segment (cell -> net -> cell ...)")
    ax.set_ylabel("cumulative delay (ns)")
    ax.set_title("Critical register-to-register path (nextpnr timing report)")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7)
    fig.savefig(os.path.join(FIG, "fpga_critpath.pdf"))
    plt.close(fig)

    # slack histograms
    fig, axs = plt.subplots(1, 3, figsize=(10, 2.8), sharey=False)
    for ax, (name, log, _), col in zip(axs, designs, cols):
        h = slack_hist(log)
        if h:
            ax.bar([(a_ + b_) / 2 for a_, b_, _ in h], [c for _, _, c in h],
                   width=[(b_ - a_) * 0.9 for a_, b_, _ in h], color=col)
        ax.set_title(name.replace("\n", " "), fontsize=8)
        ax.set_xlabel("slack (ns)")
        ax.grid(alpha=0.3)
    axs[0].set_ylabel("timing endpoints")
    fig.suptitle("Slack distribution of all timing endpoints", fontsize=10, y=1.03)
    fig.savefig(os.path.join(FIG, "fpga_slack.pdf"))
    plt.close(fig)


# ---------------------------------------------------------- floorplans
LOC = re.compile(r"X(\d+)/Y(\d+)")


def floorplan(routed, rep, title, out, groups):
    d = json.load(open(os.path.join(OUT, routed)))
    mod = [m for m in d["modules"].values() if m.get("attributes", {}).get("top")] or list(d["modules"].values())
    mod = mod[0]
    pts = {}
    xmax = ymax = 0
    for cname, c in mod["cells"].items():
        bel = c.get("attributes", {}).get("NEXTPNR_BEL", "")
        m = LOC.search(bel)
        if not m:
            continue
        x, y = int(m.group(1)), int(m.group(2))
        xmax, ymax = max(xmax, x), max(ymax, y)
        typ = c["type"]
        if typ == "TRELLIS_IO":
            g = "I/O"
        elif typ.startswith("MULT18") or typ.startswith("ALU54"):
            g = "DSP"
        else:
            # classify by hierarchy: after packing, nextpnr names each cell
            # after the net it drives, so the Booth multiplier is the logic
            # cone that drives the stage-1 product register (prod_ext/s1_prod)
            g = "other"
            for label, keys in groups:
                if any(k in cname for k in keys):
                    g = label
                    break
        pts.setdefault(g, []).append((x, y))

    # routing density: count routed wires per tile
    dens = np.zeros((ymax + 3, xmax + 3))
    for net in mod.get("netnames", {}).values():
        r = net.get("attributes", {}).get("ROUTING", "")
        for wire in r.split(";")[::3]:
            m = LOC.match(wire)
            if m:
                xx, yy = int(m.group(1)), int(m.group(2))
                if yy < dens.shape[0] and xx < dens.shape[1]:
                    dens[yy, xx] += 1

    fig, (a, b) = plt.subplots(1, 2, figsize=(11, 4.6))
    colours = {"I/O": GREY, "DSP": RED, "other": "#5fa8d3"}
    pal = [ORANGE, BLUE, GREEN, PURPLE]
    for i, (label, _) in enumerate(groups):
        colours[label] = pal[i % len(pal)]
    for g, p in sorted(pts.items(), key=lambda kv: -len(kv[1])):
        xs, ys = zip(*p)
        a.scatter(xs, ys, s=4 if g != "DSP" else 30, marker="s", color=colours.get(g, GREY),
                  label="%s (%d)" % (g, len(p)), alpha=0.85, linewidths=0)
    cp = crit_path(rep)
    if cp:
        locs = []
        for s in cp["path"]:
            for end in ("from", "to"):
                l = s.get(end, {}).get("loc")
                if l:
                    locs.append((l[0], l[1]))
        if locs:
            xs, ys = zip(*locs)
            a.plot(xs, ys, "-", color="black", lw=1.0, label="critical path")
            a.plot(xs[0], ys[0], "o", color="black", ms=4)
            a.plot(xs[-1], ys[-1], "*", color="black", ms=8)
    a.set_xlim(-1, xmax + 2)
    a.set_ylim(ymax + 2, -1)
    a.set_aspect("equal")
    a.set_title("Placement (one dot per placed cell)")
    a.set_xlabel("tile X")
    a.set_ylabel("tile Y")
    a.legend(fontsize=6.5, loc="lower left", markerscale=2.5, framealpha=0.9)
    im = b.imshow(np.log1p(dens), cmap="magma", origin="upper", aspect="equal")
    b.set_title("Routing density (log of routed wires per tile)")
    b.set_xlabel("tile X")
    fig.colorbar(im, ax=b, fraction=0.035)
    fig.suptitle(title, fontsize=10)
    fig.savefig(os.path.join(FIG, out), dpi=200)
    plt.close(fig)


def main():
    os.makedirs(FIG, exist_ok=True)
    syn_figures()
    fpga_figures()
    floorplan("mac_unit_ecp5_booth_routed.json", "ecp5_booth_pnr.json",
              "MAC unit (Booth multiplier in LUTs) on the ECP5 LFE5U-85F",
              "floorplan_mac.png",
              [("Booth multiplier", ["u_mac.prod_ext", "u_mac.op_", "u_booth", "prod_full"]),
               ("MAC stage 2 + control", ["u_mac."]),
               ("I/O registers (fmax wrapper)", [""])])
    floorplan("rv32_core_ecp5_routed.json", "core_ecp5_pnr.json",
              "Complete RV32IM core with the MAC unit on the ECP5 LFE5U-85F",
              "floorplan_core.png",
              [("Booth multiplier", ["u_mac.prod_ext", "u_mac.op_", "u_booth", "prod_full"]),
               ("MAC stage 2 + control", ["u_mac."]),
               ("RV32 pipeline + RV32M", [""])])
    print("figures written to", FIG)


if __name__ == "__main__":
    main()
