"""
export_floorplan.py - turn the placed & routed ECP5 designs into
  (1) compact JSON for the interactive project page  (report/web/floorplan_data.json)
  (2) dark "die render" floorplan images for the report
      (report/figures/floorplan_mac.png, floorplan_core.png)

Inputs: synth/out/*_routed.json (nextpnr --write), synth/reports/*_pnr.json/.log

Every placed cell is assigned to a block. After packing, nextpnr names each
cell after the net it drives, so the Booth multiplier is the logic cone that
drives the stage-1 product register (u_mac.prod_ext / s1_prod), the rest of
u_mac.* is MAC stage 2 + control, rf.* is the register file, and everything
else belongs to the RV32 pipeline (or to the timing wrapper for the
stand-alone MAC designs).
"""
import json
import os
import re
import collections

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Patch
from matplotlib.lines import Line2D
import matplotlib.patheffects as pe

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "synth", "out")
REP = os.path.join(ROOT, "synth", "reports")
LOC = re.compile(r"X(\d+)/Y(\d+)")

# block id -> (label, colour used in the renders)
GROUPS = [
    ("booth", "Booth multiplier", "#f29e4c"),
    ("mac",   "MAC stage 2 + control", "#5ab4e8"),
    ("core",  "RV32 pipeline + RV32M", "#7fc8a9"),
    ("rf",    "Register file (LUT-RAM)", "#c39bd3"),
    ("wrap",  "Timing wrapper registers", "#8a94a6"),
    ("dsp",   "DSP multipliers", "#ef6f6c"),
    ("io",    "I/O pads", "#d9c7a7"),
]
GID = {g[0]: i for i, g in enumerate(GROUPS)}

DESIGNS = [
    ("core", "rv32_core_ecp5_routed.json", "core_ecp5", "RV32IM core + MAC unit", True),
    ("mac_booth", "mac_unit_ecp5_booth_routed.json", "ecp5_booth", "MAC unit, Booth multiplier", False),
    ("mac_dsp", "mac_unit_ecp5_dsp_routed.json", "ecp5_dsp", "MAC unit, DSP blocks", False),
]


def classify(name, typ, is_core):
    if typ == "TRELLIS_IO":
        return "io"
    if typ.startswith("MULT18") or typ.startswith("ALU54"):
        return "dsp"
    if any(k in name for k in ("u_mac.prod_ext", "u_mac.op_", "u_booth", "prod_full")):
        return "booth"
    if name.startswith("u_mac."):
        return "mac"
    if is_core:
        if typ == "TRELLIS_RAMW" or name.startswith("rf."):
            return "rf"
        return "core"
    return "wrap"


def load(design):
    key, routed, rep, title, is_core = design
    d = json.load(open(os.path.join(OUT, routed)))
    mod = [m for m in d["modules"].values() if m.get("attributes", {}).get("top")][0]
    tiles = collections.defaultdict(lambda: collections.Counter())
    counts = collections.Counter()
    for name, c in mod["cells"].items():
        m = LOC.search(c.get("attributes", {}).get("NEXTPNR_BEL", ""))
        if not m or c["type"] == "DCCA":
            continue
        g = classify(name, c["type"], is_core)
        tiles[(int(m.group(1)), int(m.group(2)))][g] += 1
        counts[g] += 1
    dens = collections.Counter()
    for net in mod.get("netnames", {}).values():
        for wire in net.get("attributes", {}).get("ROUTING", "").split(";")[::3]:
            m = LOC.match(wire)
            if m:
                dens[(int(m.group(1)), int(m.group(2)))] += 1

    report = json.load(open(os.path.join(REP, rep + "_pnr.json")))
    cp = [p for p in report["critical_paths"]
          if p["from"].startswith("posedge") and p["to"].startswith("posedge")][0]
    path, t = [], 0.0
    for s in cp["path"]:
        t += s["delay"]
        loc = s["to"].get("loc") or s["from"].get("loc")
        path.append([loc[0], loc[1], round(s["delay"], 3), s["type"]])
    start = cp["path"][0]["from"]["cell"]
    end = cp["path"][-1]["to"]["cell"]
    log = open(os.path.join(REP, rep + "_pnr.log")).read()
    fmax = float(re.findall(r"Max frequency for clock[^:]*: ([\d.]+) MHz", log)[-1])
    util = {}
    sec = log[log.rfind("Device utilisation"):]
    for m in re.finditer(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)", sec):
        util.setdefault(m.group(1), [int(m.group(2)), int(m.group(3))])
    logic = sum(s["delay"] for s in cp["path"] if s["type"] != "routing")
    return {
        "key": key, "title": title,
        "tiles": [[x, y, GID[max(c, key=c.get)], sum(c.values())] for (x, y), c in tiles.items()],
        "tileMix": {"%d,%d" % xy: {g: n for g, n in c.items()} for xy, c in tiles.items()},
        "density": [[x, y, n] for (x, y), n in dens.items()],
        "counts": dict(counts),
        "crit": {"path": path, "total": round(t, 2), "logic": round(logic, 2),
                 "routing": round(t - logic, 2), "start": start, "end": end},
        "fmax": fmax, "util": util,
    }


# ---------------------------------------------------------------- render
def render(dd, out, W=127, H=96, S=8):
    """Dark die render: substrate, tiles coloured by block, copper routing
    glow, pad ring, critical path. One image pixel block of S x S per tile."""
    img = np.zeros((H * S, W * S, 3))
    img[:] = np.array([0x0c, 0x10, 0x16]) / 255.0          # substrate
    # faint tile grid
    for x in range(W):
        img[:, x * S, :] += 0.018
    for y in range(H):
        img[y * S, :, :] += 0.018
    # routing density as copper glow (log scale)
    dmax = max((n for _, _, n in dd["density"]), default=1)
    copper = np.array([0xb8, 0x73, 0x33]) / 255.0
    for x, y, n in dd["density"]:
        a = 0.55 * np.log1p(n) / np.log1p(dmax)
        img[y * S:(y + 1) * S, x * S:(x + 1) * S, :] = (1 - a) * img[y * S:(y + 1) * S, x * S:(x + 1) * S, :] + a * copper
    # placed tiles
    for x, y, g, n in dd["tiles"]:
        col = np.array(matplotlib.colors.to_rgb(GROUPS[g][2]))
        fill = 0.55 + 0.45 * min(1.0, n / 16.0)
        y0, x0 = y * S + 1, x * S + 1
        img[y0:y0 + S - 2, x0:x0 + S - 2, :] = col * fill
    img = np.clip(img, 0, 1)

    fig = plt.figure(figsize=(8.6, 7.0), facecolor="#0c1016")
    ax = fig.add_axes([0.02, 0.10, 0.96, 0.84])
    ax.imshow(img, extent=(-0.5, W - 0.5, H - 0.5, -0.5), interpolation="nearest")
    ax.set_facecolor("#0c1016")
    # die outline / seal ring
    for off, lw, col in ((1.6, 2.2, "#4a3b2c"), (2.4, 1.0, "#8a6a48")):
        ax.add_patch(Rectangle((-0.5 - off, -0.5 - off), W + 2 * off, H + 2 * off,
                               fill=False, lw=lw, ec=col))
    # critical path with glow
    xs = [p[0] for p in dd["crit"]["path"]]
    ys = [p[1] for p in dd["crit"]["path"]]
    ax.plot(xs, ys, color="#ffffff", lw=1.3,
            path_effects=[pe.Stroke(linewidth=4.5, foreground="#ffd27a", alpha=0.35), pe.Normal()])
    ax.plot(xs[0], ys[0], "o", color="#ffffff", ms=5, mec="#ffd27a")
    ax.plot(xs[-1], ys[-1], "*", color="#ffd27a", ms=11, mec="#ffffff", mew=0.6)
    ax.set_xlim(-4, W + 3)
    ax.set_ylim(H + 3, -4)
    ax.axis("off")
    present = [g for g in GROUPS if dd["counts"].get(g[0])]
    handles = [Patch(fc=c, ec="none", label="%s  (%d)" % (l, dd["counts"][k])) for k, l, c in present]
    handles += [Patch(fc="#b87333", ec="none", alpha=0.6, label="routing density"),
                Line2D([0], [0], color="white", lw=1.3, label="critical path  %.2f ns" % dd["crit"]["total"])]
    leg = fig.legend(handles=handles, loc="lower center", ncol=4, fontsize=7.5, frameon=False,
                     labelcolor="#d6dde6", bbox_to_anchor=(0.5, 0.0))
    fig.text(0.03, 0.965, dd["title"], color="#eef2f6", fontsize=12, weight="bold", va="top")
    fig.text(0.97, 0.965, "Lattice ECP5 LFE5U-85F  ·  Fmax %.1f MHz" % dd["fmax"],
             color="#c9a27a", fontsize=9, va="top", ha="right")
    fig.savefig(out, dpi=220, facecolor=fig.get_facecolor())
    plt.close(fig)


def main():
    data = {"groups": [{"id": k, "label": l, "color": c} for k, l, c in GROUPS],
            "die": {"w": 127, "h": 96}, "designs": []}
    for d in DESIGNS:
        dd = load(d)
        data["designs"].append(dd)
        print("%-10s tiles=%d cells=%s fmax=%.1f crit=%.2fns" %
              (dd["key"], len(dd["tiles"]), dict(dd["counts"]), dd["fmax"], dd["crit"]["total"]))
    web = os.path.join(ROOT, "report", "web")
    os.makedirs(web, exist_ok=True)
    with open(os.path.join(web, "floorplan_data.json"), "w") as f:
        json.dump(data, f, separators=(",", ":"))
    figs = os.path.join(ROOT, "report", "figures")
    by = {d["key"]: d for d in data["designs"]}
    render(by["mac_booth"], os.path.join(figs, "floorplan_mac.png"))
    render(by["core"], os.path.join(figs, "floorplan_core.png"))
    print("wrote", os.path.join(web, "floorplan_data.json"), os.path.getsize(os.path.join(web, "floorplan_data.json")), "bytes")


if __name__ == "__main__":
    main()
