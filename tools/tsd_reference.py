"""Reference implementation of the 2D Design V3 object grammar used by TSDKit (see docs/FORMAT.md).

Walks every record and checks the object list ends exactly at the standard trailer.
Usage: python3 tools/tsd_reference.py [-v] FILE...   (-v prints one line per record)
"""
import struct, sys

TRAILER = bytes.fromhex("000000000001000100010000000000000001000100010000000000000000000000")
MIDDLE_END = bytes.fromhex("1900090000000300")
KINDS = {0x00: "font", 0x02: "point", 0x05: "line", 0x06: "circle", 0x07: "arc", 0x08: "bezier",
         0x09: "path", 0x0A: "group", 0x0B: "glyph", 0x0C: "text", 0x0D: "dimension",
         0x0E: "container", 0x17: "arrow"}
FILLS = ["none", "solid", "hatch", "gradient", "char pattern", "shape pattern"]
LINES = ["none", "solid", "dashed", "dotted", "dash-dot"]


class GrammarError(Exception):
    pass


class P:
    def __init__(self, b, o, verbose):
        self.b, self.o, self.verbose = b, o, verbose

    def u8(self): v = self.b[self.o]; self.o += 1; return v
    def u16(self): v = struct.unpack_from("<H", self.b, self.o)[0]; self.o += 2; return v
    def u32(self): v = struct.unpack_from("<I", self.b, self.o)[0]; self.o += 4; return v
    def f64(self): v = struct.unpack_from("<d", self.b, self.o)[0]; self.o += 8; return v
    def raw(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v

    def expect(self, bs, what):
        got = self.raw(len(bs))
        if got != bs:
            raise GrammarError(f"{what}: expected {bs.hex()} got {got.hex()} at {self.o - len(bs):#x}")

    def cstr(self):
        self.expect(b"\xff\xfe\xff", "string")
        n = self.u8()
        s = self.b[self.o:self.o + 2 * n].decode("utf-16le"); self.o += 2 * n
        return s

    def log(self, depth, text):
        if self.verbose: print("  " * depth + text)

    # Blocks

    def header(self):
        self.expect(b"\x03\x00", "header")
        layer, number = self.u16(), self.u16()
        self.raw(14); self.expect(b"\x00", "header")
        self.cstr(); self.cstr()
        return layer, number

    def line(self):
        self.expect(b"\x03\x00", "line block")
        t = self.u16()
        if t == 1: width = self.f64(); colour = self.u32()
        elif t == 0: width, colour = 0, 0
        else: self.u16(); self.f64(); width = self.f64(); colour = self.u32()
        return f"{LINES[t] if t < len(LINES) else t} w={width:g} #{colour:06x}"

    def matrix(self):
        self.expect(b"\x01\x00", "transform")
        return struct.unpack_from("<6d", self.raw(48))

    def pattern_tail_at(self, o):
        if self.b[o:o + 2] != b"\x01\x00" or self.b[o + 50:o + 54] != b"\x01\x00\x01\x00":
            return False
        m = struct.unpack_from("<6d", self.b, o + 2)
        return all(abs(v) < 1e6 for v in m) and abs(m[0] * m[3] - m[1] * m[2]) > 1e-9

    def fill(self, depth):
        self.expect(b"\x05\x00", "fill block")
        f = self.u16()
        if f == 0: return "none"
        if f == 1: self.raw(17); return "solid"
        self.u16()
        if self.u8(): self.raw(4)
        self.matrix()
        if f == 2:
            self.line(); self.raw(24 + 2); n = self.u16(); self.raw(16 * n)
            return "hatch"
        self.raw(15 + 48 + 74 + 5)
        if f == 3:
            self.raw(6); self.expect(b"\x06\x00", "gradient"); self.u8()
            n = self.u16(); self.raw(8 * n)
            n = self.u16(); self.raw(8 * n + 4)
            n = self.u16(); self.raw(8 * n)
            self.raw(17)
        elif f == 4:
            self.header(); self.line(); self.fill(depth + 1)
            self.expect(b"\x06\x00", "pattern")
            start = self.o
            while not self.pattern_tail_at(self.o):
                self.o += 1
                if self.o >= len(self.b): raise GrammarError(f"pattern tail not found after {start:#x}")
            self.raw(50 + 59)
        elif f == 5:
            self.typed(depth + 1)
        else:
            raise GrammarError(f"fill type {f} at {self.o:#x}")
        return FILLS[f]

    # Records

    def typed(self, depth):
        at = self.o
        t = self.u16()
        if t not in KINDS: raise GrammarError(f"unknown record type {t:#x} at {at:#x}")
        self.record(t, depth, at)

    def record(self, t, depth, at):
        layer, number = self.header()
        line = self.line()
        fill = self.fill(depth)
        what = self.body(t, depth)
        self.log(depth, f"{at:#07x} {KINDS[t]} layer {layer} #{number} line {line} fill {fill} {what}")

    def children(self, depth):
        n = self.u32()
        for _ in range(n): self.typed(depth + 1)
        return f"{n} parts"

    def text_body(self, depth):
        self.expect(b"\x04\x00\x00\x00", "text")
        s = self.cstr(); self.raw(24 + 2 + 24 + 3)
        self.header(); self.line(); self.fill(depth); self.glyph_body()
        self.expect(b"\x03\x00", "glyph list")
        n = self.u32()
        for _ in range(n):
            if self.u16() != 0x0B: raise GrammarError(f"glyph expected at {self.o - 2:#x}")
            self.header(); self.line(); self.fill(depth); self.glyph_body()
        self.expect(b"\x00\x00", "text end")
        return repr(s)

    def glyph_body(self):
        self.expect(b"\x03\x00\x00\x00\x00\x00\x00", "glyph"); self.u16(); self.raw(16)
        self.expect(b"\x02\x00", "font"); self.raw(92 + 90)

    def body(self, t, depth):
        if t == 0x09:
            self.expect(b"\x03\x00\x01\x00", "path"); n = self.u32()
            for _ in range(n): self.expect(b"\x03\x00", "vertex"); self.raw(18)
            return f"{n} vertices"
        if t == 0x05: self.expect(b"\x01\x00", "line"); self.raw(32); return ""
        if t == 0x06: self.expect(b"\x01\x00", "circle"); self.raw(33); return ""
        if t == 0x07: self.expect(b"\x01\x00", "arc"); self.raw(48); return "clockwise" if self.raw(3)[0] else ""
        if t == 0x08: self.expect(b"\x01\x00", "bezier"); self.u16(); n = self.u16(); self.raw(16 * (n + 1)); return ""
        if t == 0x02: self.raw(17); return ""
        if t == 0x0A: self.expect(b"\x04\x00\x00\x00\x03\x00", "group"); return self.children(depth)
        if t == 0x0E:
            self.expect(b"\x04\x00\x00\x00", "container"); self.raw(3); self.expect(b"\x03\x00", "container")
            return self.children(depth)
        if t == 0x0C: return self.text_body(depth)
        if t == 0x0D:
            self.expect(b"\x05\x00", "dimension"); self.raw(7 + 96 + 3 + 16 + 1)
            self.cstr(); self.cstr(); self.raw(10)
            self.header(); self.line(); self.fill(depth)
            return "label " + self.text_body(depth)
        if t == 0x17:
            self.expect(b"\x01\x00", "arrow"); self.raw(49)
            self.header(); self.line(); self.fill(depth)
            self.expect(b"\x04\x00\x00\x00\x03\x00", "arrow")
            return self.children(depth)
        raise GrammarError(f"no body grammar for type {t:#x}")


def check(path, verbose):
    b = open(path, "rb").read()
    k = b.find(MIDDLE_END)
    if k < 0: raise GrammarError("object list not found")
    p = P(b, k + len(MIDDLE_END), verbose)
    n = p.u32()
    for _ in range(n):
        if b[p.o:p.o + 2] == b"\x04\x00" and b[p.o + 4:p.o + 6] == b"\x03\x00":
            p.o += 2   # unexplained 04 00 before point records
        p.typed(0)
    rest = b[p.o:]
    trailer = "standard trailer" if rest == TRAILER else f"{len(rest)} trailing bytes: {rest[:40].hex()}"
    return n, trailer


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "-v"]
    ok = True
    for f in args:
        try:
            n, trailer = check(f, "-v" in sys.argv)
            print(f"{f}: {n} objects, {trailer}")
        except GrammarError as e:
            ok = False
            print(f"{f}: FAILED {e}")
    sys.exit(0 if ok else 1)
