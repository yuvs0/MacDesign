"""Reference implementation of the 2D Design V3 grammar used by TSDKit (see docs/FORMAT.md).

Parses a .3vs into prefix / layers / middle / objects / trailer, re-serialises it, and
reports whether the result is byte-identical. Usage: python3 tools/tsd_reference.py FILE...
"""
import struct, sys

HDR_TAIL = bytes.fromhex("ffffffffffffffff00") + b"\xff\xfe\xff\x01;\x00" * 2 + bytes.fromhex("03000100") + bytes(12) + b"\x05\x00"

def cstr(b, o):
    assert b[o:o+3] == b"\xff\xfe\xff", hex(o)
    n = b[o+3]; return b[o+4:o+4+2*n].decode("utf-16le"), o + 4 + 2*n

class P:
    def __init__(self, b): self.b = b; self.o = 0
    def u16(self): v = struct.unpack_from("<H", self.b, self.o)[0]; self.o += 2; return v
    def u32(self): v = struct.unpack_from("<I", self.b, self.o)[0]; self.o += 4; return v
    def f64(self): v = struct.unpack_from("<d", self.b, self.o)[0]; self.o += 8; return v
    def raw(self, n): v = self.b[self.o:self.o+n]; self.o += n; return v
    def expect(self, bs):
        got = self.raw(len(bs)); assert got == bs, (hex(self.o-len(bs)), got.hex(), bs.hex())

def parse_record(p):
    """Returns dict with type, id, layer(u32 guess), hasStyle, style, body (raw), children."""
    rec = {}
    start = p.o
    rec["type"] = p.u16()
    p.expect(b"\x03\x00\x01\x00")
    rec["id"] = p.u16()
    p.expect(bytes(6))
    p.expect(HDR_TAIL[:9])            # ff*8 00
    p.expect(HDR_TAIL[9:21])          # ;;
    p.expect(b"\x03\x00\x01\x00")
    rec["hdr12"] = p.raw(12)
    p.expect(b"\x05\x00")
    rec["hasStyle"] = p.u16()
    rec["style"] = p.raw(17) if rec["hasStyle"] == 1 else b""
    t = rec["type"]
    if t == 0x09:                      # path
        p.expect(b"\x03\x00\x01\x00")
        n = p.u32(); verts = []
        for _ in range(n):
            p.expect(b"\x03\x00"); x = p.f64(); y = p.f64(); f = p.u16(); verts.append((x, y, f))
        rec["verts"] = verts
    elif t in (0x05, 0x06):            # line
        p.expect(b"\x01\x00")
        rec["pts"] = [p.f64() for _ in range(4)]
        if t == 0x06: rec["tail"] = p.raw(1)
    elif t == 0x02:                    # point
        rec["pts"] = [p.f64(), p.f64()]; rec["tail"] = p.raw(1)
    elif t == 0x0a:                    # group
        p.expect(b"\x04\x00\x00\x00\x03\x00")
        n = p.u32(); rec["children"] = [parse_record(p) for _ in range(n)]
    elif t == 0x0c:                    # text
        p.expect(b"\x04\x00\x00\x00")
        rec["text"], p.o = cstr(p.b, p.o)
        rec["x"] = p.f64(); rec["y"] = p.f64(); rec["sx"] = p.f64()
        p.expect(b"\x00\x00"); rec["sy"] = p.f64(); rec["ax"] = p.f64(); rec["ay"] = p.f64()
        p.expect(b"\x00")
        font = parse_record(p); assert font["type"] == 0
        rec["font"] = font
        p.expect(b"\x03\x00"); n = p.u32()
        rec["glyphs"] = [parse_record(p) for _ in range(n)]
        p.expect(b"\x00\x00")
    elif t in (0x00, 0x0b):            # font / glyph
        p.expect(b"\x03\x00"); p.expect(bytes(5)); rec["char"] = p.u16()
        rec["x"] = p.f64(); rec["y"] = p.f64()
        p.expect(b"\x02\x00"); rec["logfont"] = p.raw(92); rec["fonttail"] = p.raw(90)
    else:
        raise ValueError(f"unknown type {t:#x} at {start:#x}")
    return rec

def write_record(r):
    w = bytearray()
    w += struct.pack("<H", r["type"]) + b"\x03\x00\x01\x00" + struct.pack("<H", r["id"]) + bytes(6)
    w += HDR_TAIL[:21] + b"\x03\x00\x01\x00" + r["hdr12"] + b"\x05\x00" + struct.pack("<H", r["hasStyle"]) + r["style"]
    t = r["type"]
    if t == 0x09:
        w += b"\x03\x00\x01\x00" + struct.pack("<I", len(r["verts"]))
        for x, y, f in r["verts"]: w += b"\x03\x00" + struct.pack("<ddH", x, y, f)
    elif t in (0x05, 0x06):
        w += b"\x01\x00" + struct.pack("<4d", *r["pts"]) + r.get("tail", b"")
    elif t == 0x02:
        w += struct.pack("<2d", *r["pts"]) + r["tail"]
    elif t == 0x0a:
        w += b"\x04\x00\x00\x00\x03\x00" + struct.pack("<I", len(r["children"]))
        for c in r["children"]: w += write_record(c)
    elif t == 0x0c:
        s = r["text"].encode("utf-16le")
        w += b"\x04\x00\x00\x00\xff\xfe\xff" + bytes([len(r["text"])]) + s
        w += struct.pack("<ddd", r["x"], r["y"], r["sx"]) + b"\x00\x00" + struct.pack("<ddd", r["sy"], r["ax"], r["ay"]) + b"\x00"
        w += write_record(r["font"]) + b"\x03\x00" + struct.pack("<I", len(r["glyphs"]))
        for g in r["glyphs"]: w += write_record(g)
        w += b"\x00\x00"
    elif t in (0x00, 0x0b):
        w += b"\x03\x00" + bytes(5) + struct.pack("<Hdd", r["char"], r["x"], r["y"]) + b"\x02\x00" + r["logfont"] + r["fonttail"]
    return bytes(w)

def parse_file(b):
    # layers
    l1 = b.find("Layer 1".encode("utf-16le")) - 4 - 4   # back over cstring marker and "01 00 03 00"
    count_off = l1 - 4
    assert b[count_off:count_off+4] == b"\x03\x00\x00\x00", b[count_off:count_off+4].hex()
    prefixA = b[:count_off]
    p = P(b); p.o = count_off; p.u32()
    layers = []
    for _ in range(3):
        p.expect(b"\x01\x00\x03\x00")
        n1, p.o = cstr(b, p.o); n2, p.o = cstr(b, p.o); assert n1 == n2
        idx = p.u16(); flags = p.raw(2); p.expect(bytes(7)); p.expect(b"\xff"*16); p.expect(b"\x00")
        layers.append((n1, idx, flags))
    mid_start = p.o
    # find object count: the first object record is preceded by "03 00 [count]"; locate via settings record end
    # settings record ends with "19 00 09 00 00 00 03 00" then count
    key = bytes.fromhex("19000900000003 00".replace(" ", ""))
    k = b.find(key, mid_start); assert k > 0
    middle = b[mid_start:k+len(key)]
    p.o = k + len(key)
    n = p.u32()
    objs = []
    for _ in range(n):
        pre = b""
        if b[p.o:p.o+2] == b"\x04\x00" and b[p.o+4:p.o+8] == b"\x03\x00\x01\x00": pre = p.raw(2)   # oddity before point
        r = parse_record(p); r["pre"] = pre; objs.append(r)
    trailer = p.raw(len(b) - p.o)
    return prefixA, layers, middle, objs, trailer

def write_file(prefixA, layers, middle, objs, trailer):
    w = bytearray(prefixA) + b"\x03\x00\x00\x00"
    for name, idx, flags in layers:
        s = name.encode("utf-16le"); cs = b"\xff\xfe\xff" + bytes([len(name)]) + s
        w += b"\x01\x00\x03\x00" + cs + cs + struct.pack("<H", idx) + flags + bytes(7) + b"\xff"*16 + b"\x00"
    w += middle + struct.pack("<I", len(objs))
    for r in objs: w += r["pre"] + write_record(r)
    w += trailer
    return bytes(w)

if __name__ == "__main__":
    for f in sys.argv[1:]:
        b = open(f, "rb").read()
        parts = parse_file(b)
        out = write_file(*parts)
        prefixA, layers, middle, objs, trailer = parts
        print(f, "roundtrip", "OK" if out == b else "MISMATCH", "| prefixA", len(prefixA), "middle", len(middle), "objects", len(objs), "trailer", len(trailer), trailer.hex())
        def show(r, ind="  "):
            extra = ""
            if r["type"] == 0x09: extra = f"{len(r['verts'])} verts"
            if r["type"] in (5, 6, 2): extra = str([round(v, 2) for v in r["pts"]])
            if r["type"] == 0x0c: extra = repr(r["text"]) + f" ({r['x']:.1f},{r['y']:.1f}) s({r['sx']},{r['sy']}) a({r['ax']:.2f},{r['ay']:.2f}) glyphs {len(r['glyphs'])} tail {r['font']['fonttail'][:16].hex()}"
            print(ind, f"type {r['type']:02x} id {r['id']:02x} hdr12 {r['hdr12'].hex()} style {r['style'].hex()} {extra}")
            for c in r.get("children", []): show(c, ind + "    ")
        for r in objs: show(r)
