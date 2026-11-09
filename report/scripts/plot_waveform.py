"""
plot_waveform.py - render selected windows of sim/mac_unit.vcd as
digital timing diagrams (PNG) for the LaTeX report.

Usage:  python plot_waveform.py <vcd file> <output dir>

A minimal VCD parser is included so no extra packages beyond matplotlib
are needed. Each window is located by searching for a specific
instruction in the stimulus (e.g. the first 'mul.acc x5, 7, 6' of T2).
"""
import sys
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CLK_NS = 10  # clock period in the testbench


def parse_vcd(path, wanted):
    """Return {signal_name: [(time_ps, value_str), ...]} for wanted names."""
    id2name, scope, data = {}, [], {}
    t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if in_defs:
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    name = ".".join(scope[1:] + [tok[4]])
                    if name in wanted:
                        id2name.setdefault(tok[3], []).append(name)
                        data[name] = []
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            c = tok[0]
            if c[0] == "#":
                t = int(c[1:])
            elif c[0] in "01xz" and len(tok) == 1:
                for n in id2name.get(c[1:], []):
                    data[n].append((t, c[0]))
            elif c[0] == "b":
                for n in id2name.get(tok[1], []):
                    data[n].append((t, c[1:]))
    return data


def value_at(changes, t):
    v = "x"
    for ct, cv in changes:
        if ct > t:
            break
        v = cv
    return v


def fmt(bits, width, signed_dec):
    if any(ch in "xz" for ch in bits):
        return "x"
    v = int(bits, 2)
    if signed_dec:
        if v >= 1 << (width - 1):
            v -= 1 << width
        return str(v)
    return "%X" % v


def plot(data, signals, t0, t1, title, out):
    fig, ax = plt.subplots(figsize=(11, 0.55 * len(signals) + 0.8))
    for row, (name, label, width, dec) in enumerate(signals):
        y = len(signals) - 1 - row
        ch = data[name]
        # collect change points inside the window
        pts = [t0] + [ct for ct, _ in ch if t0 < ct < t1] + [t1]
        for a, b in zip(pts[:-1], pts[1:]):
            v = value_at(ch, a)
            xa, xb = a / 1000.0, b / 1000.0
            if width == 1:
                lvl = y + (0.7 if v == "1" else 0.1)
                ax.plot([xa, xb], [lvl, lvl], color="#1f4e9a", lw=1.4)
                nv = value_at(ch, b)
                if b != t1 and nv != v:
                    ax.plot([xb, xb], [y + 0.1, y + 0.7], color="#1f4e9a", lw=1.4)
            else:
                d = 0.25
                ax.fill([xa + d, xb - d, xb, xb - d, xa + d, xa],
                        [y + 0.7, y + 0.7, y + 0.4, y + 0.1, y + 0.1, y + 0.4],
                        facecolor="#e8eef8", edgecolor="#1f4e9a", lw=1.0)
                txt = fmt(v, width, dec)
                if (xb - xa) > 0.6 * len(txt) + 1:
                    ax.text((xa + xb) / 2, y + 0.4, txt, ha="center", va="center",
                            fontsize=7, family="monospace")
        ax.text(t0 / 1000.0 - 1, y + 0.4, label, ha="right", va="center",
                fontsize=8, family="monospace")
    # clock grid on rising edges
    first = (t0 // (CLK_NS * 1000) + 1) * CLK_NS * 1000
    for e in range(first, t1, CLK_NS * 1000):
        ax.axvline(e / 1000.0, color="#bbbbbb", lw=0.5, ls=":")
    ax.set_xlim(t0 / 1000.0, t1 / 1000.0)
    ax.set_ylim(-0.2, len(signals))
    ax.set_yticks([])
    ax.set_xlabel("time (ns)")
    ax.set_title(title, fontsize=10)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out, dpi=200)
    plt.close(fig)


def find_instr(data, rs1, rs2, f3, nth=1):
    """nth time valid_i=1 with given operands and funct3."""
    times = sorted({t for t, _ in data["instr_i"]} | {t for t, _ in data["rs1_i"]})
    for t in times:
        if value_at(data["valid_i"], t) != "1":
            continue
        ins = value_at(data["instr_i"], t)
        if "x" in ins:
            continue
        if ((int(ins, 2) >> 12) & 7) == f3 and \
           int(value_at(data["rs1_i"], t), 2) == rs1 and \
           int(value_at(data["rs2_i"], t), 2) == rs2:
            nth -= 1
            if nth == 0:
                return t
    raise RuntimeError("instruction not found")


def main():
    vcd, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    signals = [
        ("clk", "clk", 1, False),
        ("valid_i", "valid_i", 1, False),
        ("instr_i", "instr_i", 32, False),
        ("rs1_i", "rs1_i", 32, True),
        ("rs2_i", "rs2_i", 32, True),
        ("dut.s1_valid", "s1_valid", 1, False),
        ("dut.s1_prod", "s1_prod", 64, True),
        ("valid_o", "valid_o", 1, False),
        ("rd_we_o", "rd_we_o", 1, False),
        ("rd_data_o", "rd_data_o", 32, True),
        ("acc_o", "acc_o", 64, True),
        ("ovf_o", "ovf_o", 1, False),
    ]
    data = parse_vcd(vcd, {s[0] for s in signals})

    # Window 1: T2 back-to-back mul.acc / mac / msu / mac / rdacc.lo / rdacc.hi
    t = find_instr(data, 7, 6, 0b010)
    plot(data, signals, t - 7000, t + 9 * CLK_NS * 1000,
         "T2: back-to-back mul.acc, mac, msu, mac, rdacc.lo, rdacc.hi (2-cycle latency)",
         os.path.join(outdir, "wave_t2.png"))

    # Window 2: T5 positive saturation (mul.acc MIN*MIN then mac MIN*MIN)
    # (1st occurrence is in T4, 2nd is T5); 64-bit buses shown in hex
    hex_signals = [(n, l, w, d and w < 64) for n, l, w, d in signals]
    t = find_instr(data, 0x80000000, 0x80000000, 0b010, nth=2)
    plot(data, hex_signals, t - 7000, t + 7 * CLK_NS * 1000,
         "T5: accumulator saturates to INT64_MAX and OVF is set; clracc clears it",
         os.path.join(outdir, "wave_t5.png"))


if __name__ == "__main__":
    main()
