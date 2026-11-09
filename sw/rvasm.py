"""
rvasm.py - minimal two-pass RISC-V assembler for this project.

Supports
  * RV32I base instructions, the multiply subset of RV32M
    (mul, mulh, mulhsu, mulhu) and ECALL/EBREAK/FENCE
  * the custom-0 MAC extension implemented by rtl/mac_unit.v:
        mac rd, rs1, rs2      msu rd, rs1, rs2      mul.acc rd, rs1, rs2
        macu rd, rs1, rs2     rdacc.lo rd           rdacc.hi rd
        rdacc.q15 rd          clracc [rd]
  * pseudo-instructions: nop li la mv not neg j jr ret call beqz bnez
        bltz bgez blez bgtz bgt ble bgtu bleu seqz snez
  * directives: .text .data .word .half .byte .space .align .equ .include
  * labels, '#' comments, integer expressions using labels/.equ symbols

Memory layout: .text starts at 0x00000000, .data at 0x00010000.

Usage (library):  prog = assemble_file("prog.s"); prog.write("build/prog")
Usage (CLI):      python rvasm.py prog.s build/prog
  -> build/prog.imem.hex, build/prog.dmem.hex, build/prog.lst, build/prog.sym
"""
import ast
import os
import re
import sys

TEXT_BASE = 0x0000_0000
DATA_BASE = 0x0001_0000

ABI = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13,
    "a4": 14, "a5": 15, "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20,
    "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}
for _i in range(32):
    ABI["x%d" % _i] = _i

# (opcode, funct3, funct7)
R_OPS = {
    "add": (0x33, 0, 0x00), "sub": (0x33, 0, 0x20), "sll": (0x33, 1, 0x00),
    "slt": (0x33, 2, 0x00), "sltu": (0x33, 3, 0x00), "xor": (0x33, 4, 0x00),
    "srl": (0x33, 5, 0x00), "sra": (0x33, 5, 0x20), "or": (0x33, 6, 0x00),
    "and": (0x33, 7, 0x00),
    "mul": (0x33, 0, 0x01), "mulh": (0x33, 1, 0x01), "mulhsu": (0x33, 2, 0x01),
    "mulhu": (0x33, 3, 0x01),
    # custom-0 MAC extension (R-type)
    "mac": (0x0B, 0, 0x00), "msu": (0x0B, 1, 0x00), "mul.acc": (0x0B, 2, 0x00),
    "macu": (0x0B, 3, 0x00),
}
MAC_READ = {"rdacc.lo": 4, "rdacc.hi": 5, "rdacc.q15": 6, "clracc": 7}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_I = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x20)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


def _fits(v, bits):
    return -(1 << (bits - 1)) <= v < (1 << (bits - 1))


def _hi_lo(v):
    """Split a 32-bit constant for lui + addi (addi sign-extends lo)."""
    v &= 0xFFFFFFFF
    lo = v & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((v - lo) >> 12) & 0xFFFFF
    return hi, lo


def enc_r(op, f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(op, f3, rd, rs1, imm):
    if not _fits(imm, 12):
        raise AsmError("I-immediate out of range: %d" % imm)
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(op, f3, rs1, rs2, imm):
    if not _fits(imm, 12):
        raise AsmError("S-immediate out of range: %d" % imm)
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def enc_b(f3, rs1, rs2, off):
    if off & 1 or not _fits(off, 13):
        raise AsmError("branch offset invalid: %d" % off)
    o = off & 0x1FFF
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63


def enc_u(op, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(rd, off):
    if off & 1 or not _fits(off, 21):
        raise AsmError("jump offset invalid: %d" % off)
    o = off & 0x1FFFFF
    return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | \
           (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


class Program:
    def __init__(self):
        self.text = {}      # addr -> word
        self.data = {}      # byte addr -> byte
        self.listing = []   # (addr, word, source)
        self.symbols = {}

    def write(self, prefix, imem_words=1024, dmem_words=4096):
        """Write memory images padded to the full memory size (NOP / zero),
        so $readmemh fills every word, plus the listing and symbol table."""
        os.makedirs(os.path.dirname(prefix) or ".", exist_ok=True)
        n_text = (max(self.text) - TEXT_BASE) // 4 + 1 if self.text else 0
        n_data = ((max(self.data) - DATA_BASE) // 4 + 1) if self.data else 1
        if n_text > imem_words or n_data > dmem_words:
            raise AsmError("program does not fit in the memories")
        n_text, n_data = imem_words, dmem_words
        with open(prefix + ".imem.hex", "w") as f:
            for i in range(n_text):
                f.write("%08x\n" % self.text.get(TEXT_BASE + 4 * i, 0x00000013))
        with open(prefix + ".dmem.hex", "w") as f:
            for i in range(n_data):
                w = 0
                for b in range(4):
                    w |= self.data.get(DATA_BASE + 4 * i + b, 0) << (8 * b)
                f.write("%08x\n" % w)
        with open(prefix + ".lst", "w") as f:
            for addr, word, src in self.listing:
                f.write("%08x  %08x  %s\n" % (addr, word, src))
        with open(prefix + ".sym", "w") as f:
            for k, v in sorted(self.symbols.items(), key=lambda kv: kv[1]):
                f.write("%08x %s\n" % (v & 0xFFFFFFFF, k))


def _read_lines(path, seen=None):
    """Read a source file, expanding .include recursively."""
    seen = seen or set()
    path = os.path.abspath(path)
    if path in seen:
        raise AsmError("recursive include: " + path)
    seen.add(path)
    out = []
    with open(path) as f:
        for n, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            m = re.match(r'\.include\s+"([^"]+)"', line)
            if m:
                inc = os.path.join(os.path.dirname(path), m.group(1))
                out.extend(_read_lines(inc, seen))
            else:
                out.append((os.path.basename(path), n, line))
    return out


def _eval(expr, symbols):
    expr = expr.strip()
    tree = ast.parse(expr, mode="eval")
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant,
                                 ast.Name, ast.Load, ast.Add, ast.Sub, ast.Mult,
                                 ast.FloorDiv, ast.USub, ast.UAdd, ast.LShift,
                                 ast.RShift, ast.BitAnd, ast.BitOr)):
            raise AsmError("bad expression: " + expr)
        if isinstance(node, ast.Name) and node.id not in symbols:
            raise AsmError("undefined symbol: " + node.id)
    return int(eval(compile(tree, "<expr>", "eval"), {"__builtins__": {}}, dict(symbols)))


def _reg(tok):
    tok = tok.strip()
    if tok not in ABI:
        raise AsmError("bad register: " + tok)
    return ABI[tok]


def _split_ops(s):
    return [t.strip() for t in s.split(",")] if s.strip() else []


def _mem_operand(tok):
    m = re.match(r"(.*)\((\w+)\)\s*$", tok.strip())
    if not m:
        raise AsmError("bad memory operand: " + tok)
    return (m.group(1).strip() or "0"), _reg(m.group(2))


def _size(mn, ops, symbols):
    """Number of instructions an instruction/pseudo expands to (pass 1)."""
    if mn == "la" or mn == "call":
        return 2 if mn == "la" else 1
    if mn == "li":
        try:
            v = _eval(ops[1], symbols)
        except AsmError:
            return 2
        return 1 if _fits(v, 12) else 2
    return 1


def _expand(mn, ops, pc, sym, n_words=1):
    """Return a list of 32-bit instruction words (n_words = pass-1 size)."""
    E = lambda e: _eval(e, sym)

    if mn == "nop":
        return [enc_i(0x13, 0, 0, 0, 0)]
    if mn == "li":
        rd, v = _reg(ops[0]), E(ops[1])
        if _fits(v, 12) and n_words == 1:
            return [enc_i(0x13, 0, rd, 0, v)]
        hi, lo = _hi_lo(v)
        return [enc_u(0x37, rd, hi), enc_i(0x13, 0, rd, rd, lo)]
    if mn == "la":
        rd, v = _reg(ops[0]), E(ops[1])
        hi, lo = _hi_lo(v)
        return [enc_u(0x37, rd, hi), enc_i(0x13, 0, rd, rd, lo)]
    if mn == "mv":
        return [enc_i(0x13, 0, _reg(ops[0]), _reg(ops[1]), 0)]
    if mn == "not":
        return [enc_i(0x13, 4, _reg(ops[0]), _reg(ops[1]), -1)]
    if mn == "neg":
        return [enc_r(0x33, 0, 0x20, _reg(ops[0]), 0, _reg(ops[1]))]
    if mn == "seqz":
        return [enc_i(0x13, 3, _reg(ops[0]), _reg(ops[1]), 1)]
    if mn == "snez":
        return [enc_r(0x33, 3, 0, _reg(ops[0]), 0, _reg(ops[1]))]
    if mn == "j":
        return [enc_j(0, E(ops[0]) - pc)]
    if mn == "call":
        return [enc_j(1, E(ops[0]) - pc)]
    if mn == "jr":
        return [enc_i(0x67, 0, 0, _reg(ops[0]), 0)]
    if mn == "ret":
        return [enc_i(0x67, 0, 0, 1, 0)]
    pseudo_br = {"beqz": ("beq", 0, 1), "bnez": ("bne", 0, 1), "bltz": ("blt", 0, 1),
                 "bgez": ("bge", 0, 1), "blez": ("bge", 1, 0), "bgtz": ("blt", 1, 0)}
    if mn in pseudo_br:
        real, a, b = pseudo_br[mn]
        regs = [_reg(ops[0]), 0]
        return [enc_b(BRANCHES[real], regs[a], regs[b], E(ops[1]) - pc)]
    swap_br = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
    if mn in swap_br:
        return [enc_b(BRANCHES[swap_br[mn]], _reg(ops[1]), _reg(ops[0]), E(ops[2]) - pc)]

    if mn in R_OPS:
        op, f3, f7 = R_OPS[mn]
        return [enc_r(op, f3, f7, _reg(ops[0]), _reg(ops[1]), _reg(ops[2]))]
    if mn in MAC_READ:
        rd = _reg(ops[0]) if ops else 0
        return [enc_r(0x0B, MAC_READ[mn], 0, rd, 0, 0)]
    if mn in I_ALU:
        return [enc_i(0x13, I_ALU[mn], _reg(ops[0]), _reg(ops[1]), E(ops[2]))]
    if mn in SHIFT_I:
        f3, f7 = SHIFT_I[mn]
        sh = E(ops[2])
        if not 0 <= sh < 32:
            raise AsmError("shift amount out of range")
        return [(f7 << 25) | (sh << 20) | (_reg(ops[1]) << 15) | (f3 << 12) | (_reg(ops[0]) << 7) | 0x13]
    if mn in LOADS:
        off, base = _mem_operand(ops[1])
        return [enc_i(0x03, LOADS[mn], _reg(ops[0]), base, E(off))]
    if mn in STORES:
        off, base = _mem_operand(ops[1])
        return [enc_s(0x23, STORES[mn], base, _reg(ops[0]), E(off))]
    if mn in BRANCHES:
        return [enc_b(BRANCHES[mn], _reg(ops[0]), _reg(ops[1]), E(ops[2]) - pc)]
    if mn == "jal":
        if len(ops) == 1:
            return [enc_j(1, E(ops[0]) - pc)]
        return [enc_j(_reg(ops[0]), E(ops[1]) - pc)]
    if mn == "jalr":
        if len(ops) == 1:
            return [enc_i(0x67, 0, 1, _reg(ops[0]), 0)]
        if "(" in ops[1]:
            off, base = _mem_operand(ops[1])
            return [enc_i(0x67, 0, _reg(ops[0]), base, E(off))]
        return [enc_i(0x67, 0, _reg(ops[0]), _reg(ops[1]), E(ops[2]) if len(ops) > 2 else 0)]
    if mn == "lui":
        return [enc_u(0x37, _reg(ops[0]), E(ops[1]))]
    if mn == "auipc":
        return [enc_u(0x17, _reg(ops[0]), E(ops[1]))]
    if mn == "ecall":
        return [0x00000073]
    if mn == "ebreak":
        return [0x00100073]
    if mn == "fence":
        return [0x0000000F]
    raise AsmError("unknown instruction: " + mn)


def assemble_file(path):
    lines = _read_lines(path)
    prog = Program()
    sym = {}
    sizes = {}

    # ---------------- pass 1: addresses of labels, .equ ----------------
    for pass_no in (1, 2):
        section, pc, dpc = "text", TEXT_BASE, DATA_BASE
        for idx, (fname, ln, line) in enumerate(lines):
            where = "%s:%d" % (fname, ln)
            try:
                while True:
                    m = re.match(r"^([A-Za-z_.$][\w.$]*):\s*(.*)$", line)
                    if not m:
                        break
                    if pass_no == 1:
                        if m.group(1) in sym:
                            raise AsmError("duplicate label " + m.group(1))
                        sym[m.group(1)] = pc if section == "text" else dpc
                    line = m.group(2)
                if not line:
                    continue
                parts = line.split(None, 1)
                mn, rest = parts[0].lower(), (parts[1] if len(parts) > 1 else "")
                ops = _split_ops(rest)

                if mn == ".text":
                    section = "text"; continue
                if mn == ".data":
                    section = "data"; continue
                if mn == ".equ":
                    if pass_no == 1:
                        sym[ops[0]] = _eval(ops[1], sym)
                    continue
                if mn in (".word", ".half", ".byte"):
                    size = {".word": 4, ".half": 2, ".byte": 1}[mn]
                    if section != "data":
                        raise AsmError("data directive outside .data")
                    for o in ops:
                        if pass_no == 2:
                            v = _eval(o, sym) & ((1 << (8 * size)) - 1)
                            for b in range(size):
                                prog.data[dpc + b] = (v >> (8 * b)) & 0xFF
                        dpc += size
                    continue
                if mn == ".space":
                    n = _eval(ops[0], sym)
                    if pass_no == 2:
                        for b in range(n):
                            prog.data[dpc + b] = 0
                    dpc += n
                    continue
                if mn == ".align":
                    a = 1 << _eval(ops[0], sym)
                    if section == "data":
                        dpc = (dpc + a - 1) & ~(a - 1)
                    else:
                        pc = (pc + a - 1) & ~(a - 1)
                    continue
                if mn.startswith("."):
                    raise AsmError("unknown directive " + mn)

                if section != "text":
                    raise AsmError("instruction outside .text")
                if pass_no == 1:
                    sizes[idx] = _size(mn, ops, sym)
                    pc += 4 * sizes[idx]
                else:
                    words = _expand(mn, ops, pc, sym, sizes[idx])
                    if len(words) != sizes[idx]:
                        raise AsmError("internal size mismatch")
                    for i, w in enumerate(words):
                        prog.text[pc] = w
                        prog.listing.append((pc, w, line if i == 0 else "  (cont.) " + line))
                        pc += 4
            except AsmError as e:
                raise AsmError("%s: %s  [%s]" % (where, e, line))
    prog.symbols = sym
    return prog


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    p = assemble_file(sys.argv[1])
    p.write(sys.argv[2])
    print("assembled %d instructions, %d data bytes" % (len(p.text), len(p.data)))
