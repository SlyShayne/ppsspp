"""Builds the slyshayne.p3p pack's bitmap font sheet from the font file on your own copy of Persona 3 Portable.

The font is the game's, so it isn't in the repository (the pack's assets/game/ is gitignored). The input is
the game's umd0.cpk (PSP_GAME/USRDIR/umd0.cpk), or font0.fnt already pulled out of it:

    python -I gungnir/tools/p3p_font.py <umd0.cpk | font0.fnt> gungnir/packs/slyshayne.p3p/assets/game [textures]

Writes font_msg_<colour>.png and .json (gungnir-core's bitmap font format), one per colour in COLOURS, to the
second folder, at half the companion's 4x (drawn at 2x). The optional
third argument is a PPSSPP texture dump folder (PSP/TEXTURES/ULUS10512/new); with it the decoded glyphs are
compared with the glyph textures p3p_assets.py uses, and the largest difference is printed.

The game draws conversations, choices and Config with font/font0.fnt, an entry of the archive data/init.bin
in umd0.cpk (entries: a 252-byte name, a u32 size, then the data, padded to 64 bytes). It decodes each glyph
into a 4bpp texture when it's first needed and draws it through FONT_ALPHA. (data/font/font1.fnt is a
smaller font in the same format.) Both, as decoded here:
  0x00  header: u32 0x20, u32 data size, u16 glyph count at 0x0e (504), u16 glyph w and h (32x32).
  0x20  16-entry RGBA palette (a grey ramp, entry 0 clear).
  0x60  u32 byte count of the per-glyph (ink left, ink right) table, then the table (a pair per glyph).
  then  a Huffman-coded blob of the glyphs, 512 bytes each (32x32, 4bpp, low nibble first):
        u32 header size (0x20), u32 tree bytes, u32 data bytes, u32 data bits, u32 block size (0x200),
        u32 block count + 1, u32 index bytes, u32 decoded size; then the tree as u16 triples
        (id, left, right); leaves are (id, 0, byte) for ids 1..leaf count; then a u32 bit offset per block;
        then the bits, least significant bit first, from the root (the last node), 0 = left.
  Glyph n is the character 0x20 + n for the printable ASCII range.
Needs Pillow. The CPK reader (with CRILAYLA) is the one from the Orpheus decode.
"""
import json
import os
import struct
import sys

from PIL import Image

SCALE = 2  # the sheet is half the companion's 4x: gungnir-core takes cells up to 64 px and draws them at 2x
GLYPH_SCALE = 0.82 * SCALE  # 0.82 as in p3p_assets.py
GAP = 1.4 * SCALE
LINE = 13 * SCALE
CHARS = "".join(chr(c) for c in range(0x20, 0x7F))
COLUMNS = 16
# The colours a choice's options come in: the one under the cursor, and the rest with each protagonist.
COLOURS = {"white": (255, 255, 255), "him": (0x10, 0x58, 0xCD), "her": (0xEC, 0x44, 0x7F)}
ARCHIVE = "data/init.bin"
FONT = "font/font0.fnt"
# The alpha the game gives each of a glyph's 16 levels (its texture's palette, read from the glyph textures).
FONT_ALPHA = [0, 24, 46, 66, 88, 106, 126, 142, 158, 174, 188, 202, 214, 230, 246, 255]


# --- CPK (CRI) with CRILAYLA ----------------------------------------------------------------------------

def utf_rows(d, base=0):
    b = base + 8
    rows_off, str_off, data_off, _, ncols, rowlen, nrows = struct.unpack(">IIIIHHI", d[b:b + 24])
    strs = b + str_off
    sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 8, 7: 8, 8: 4}

    def value(p, ty):
        if ty <= 7:
            n = sizes[ty]
            return int.from_bytes(d[p:p + n], "big", signed=ty in (1, 3, 5, 7)), p + n
        if ty == 8:
            return struct.unpack(">f", d[p:p + 4])[0], p + 4
        if ty == 0xA:
            s = strs + struct.unpack(">I", d[p:p + 4])[0]
            return d[s:d.index(b"\0", s)].decode("utf8", "replace"), p + 4
        if ty == 0xB:
            o, n = struct.unpack(">II", d[p:p + 8])
            return (b + data_off + o, n), p + 8
        raise ValueError(ty)

    p = b + 24
    cols = []
    for _ in range(ncols):
        flag = d[p]
        p += 1
        name = None
        if flag & 0xF0:
            s = strs + struct.unpack(">I", d[p:p + 4])[0]
            name = d[s:d.index(b"\0", s)].decode("utf8", "replace")
            p += 4
        const = None
        if flag >> 4 == 3:
            const, p = value(p, flag & 15)
        cols.append((name, flag >> 4, flag & 15, const))
    rows = []
    for r in range(nrows):
        q = b + rows_off + r * rowlen
        row = {}
        for name, storage, ty, const in cols:
            if storage == 5:
                row[name], q = value(q, ty)
            else:
                row[name] = const
        rows.append(row)
    return rows


def crilayla(data):
    usize, hsize = struct.unpack("<II", data[8:16])
    comp = data[16:16 + hsize]
    out = bytearray(usize + 0x100)
    out[:0x100] = data[16 + hsize:16 + hsize + 0x100]
    pos = len(comp) - 1
    pool = [0, 0]

    def bits(n):
        nonlocal pos
        r = 0
        while n:
            if pool[1] == 0:
                pool[0] = comp[pos]
                pos -= 1
                pool[1] = 8
            take = min(n, pool[1])
            r = (r << take) | ((pool[0] >> (pool[1] - take)) & ((1 << take) - 1))
            pool[1] -= take
            n -= take
        return r

    o = usize - 1
    while o >= 0 and pos >= 0:
        if bits(1):
            off = bits(13) + 3
            n = 3
            for width in (2, 3, 5, 8):
                v = bits(width)
                n += v
                if v != (1 << width) - 1:
                    break
            else:
                while True:
                    v = bits(8)
                    n += v
                    if v != 255:
                        break
            for _ in range(n):
                out[o + 0x100] = out[o + 0x100 + off]
                o -= 1
        else:
            out[o + 0x100] = bits(8)
            o -= 1
    return bytes(out)


def read_cpk_file(path, wanted):
    with open(path, "rb") as f:
        header = f.read(0x800)
        h = utf_rows(header, 0x10)[0]
        toc, content = h["TocOffset"], h["ContentOffset"]
        f.seek(toc)
        rows = utf_rows(f.read(h["TocSize"]), 0x10)
        base = min(toc, content) if content else toc
        for r in rows:
            name = (r["DirName"] + "/" + r["FileName"]) if r.get("DirName") else r["FileName"]
            if name == wanted:
                f.seek(base + r["FileOffset"])
                data = f.read(r["FileSize"])
                return crilayla(data) if data[:8] == b"CRILAYLA" else data
    sys.exit("%s isn't in %s" % (wanted, path))


# --- font1.fnt ------------------------------------------------------------------------------------------

class Font:
    def __init__(self, d):
        self.d = d
        self.count = struct.unpack("<H", d[0x0E:0x10])[0]
        table = struct.unpack("<I", d[0x60:0x64])[0]
        blob = 0x64 + table
        while d[blob] == 0:  # the (left, right) table is followed by padding
            blob += 1
        hsize, tree_bytes, _, _, block, blocks, index_bytes, _ = struct.unpack("<8I", d[blob:blob + 32])
        tree = blob + hsize
        self.nodes = [struct.unpack("<3H", d[tree + 6 * k:tree + 6 * k + 6]) for k in range(tree_bytes // 6)]
        self.root = len(self.nodes) - 1
        self.leaves = self.nodes[0][2]  # the first node repeats the root: (root, right, leaf count)
        index = tree + tree_bytes
        self.index = struct.unpack("<%dI" % blocks, d[index:index + 4 * blocks])
        self.bits = d[index + index_bytes:]
        self.block = block

    def glyph(self, n):
        """Glyph n as 32x32 values 0..15."""
        pos = self.index[n]
        bits, nodes = self.bits, self.nodes
        out = bytearray()
        while len(out) < self.block:
            node = self.root
            while node > self.leaves:
                bit = (bits[pos >> 3] >> (pos & 7)) & 1
                pos += 1
                node = nodes[node][2 if bit else 1]
            out.append(nodes[node][2])
        px = []
        for b in out:
            px += [b & 15, b >> 4]
        return px

    def alpha(self, n):
        im = Image.new("L", (32, 32))
        im.putdata([FONT_ALPHA[v] for v in self.glyph(n)])
        return im


def build(font, dst):
    cell = round(32 * GLYPH_SCALE)
    cols = COLUMNS
    rows = (len(CHARS) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell, rows * cell), (255, 255, 255, 0))
    advances, glyphs = [], {}
    for i, ch in enumerate(CHARS):
        alpha = font.alpha(ord(ch) - 0x20)
        if ch == " ":
            alpha = Image.new("L", (32, 32))  # the game's space is a faint dot, not drawn
        box = alpha.getbbox()
        left, right = (box[0], box[2]) if box else (13, 19)  # the space's ink, as in p3p_assets.py
        # Shift the glyph so its ink starts at the cell's left edge: the pen then moves by the ink's width
        # plus GAP, which is how p3p_assets.text() places letters.
        shifted = Image.new("L", (64, 32), 0)
        shifted.paste(alpha, (-left, 0))
        shifted = shifted.resize((round(64 * GLYPH_SCALE), cell), Image.BILINEAR).crop((0, 0, cell, cell))
        tile = Image.new("RGBA", (cell, cell), (255, 255, 255, 0))
        tile.putalpha(shifted)
        sheet.paste(tile, (i % cols * cell, i // cols * cell))
        advance = round((right - left) * GLYPH_SCALE + GAP)
        advances.append(advance)
        ink = tile.getchannel("A").getbbox()
        if ink:
            glyphs[ch] = {"advance": advance, "ink": [ink[0], ink[1], ink[2] - 1, ink[3] - 1]}
    os.makedirs(dst, exist_ok=True)
    pack = os.path.dirname(os.path.dirname(os.path.abspath(dst)))  # a pack's paths start at its folder
    # A sheet per colour the text comes in, tinted as the game tints its white glyphs: a bitmap font's colour
    # roles replace pixels whole, which would lose the letters' smooth edges.
    for name, rgb in COLOURS.items():
        tinted = Image.new("RGBA", sheet.size, rgb + (0,))
        tinted.putalpha(sheet.getchannel("A"))
        png = os.path.join(dst, "font_msg_%s.png" % name)
        tinted.save(png)
        meta = {
            "sheet": os.path.relpath(png, pack).replace(os.sep, "/"),
            "cell": [cell, cell],
            "columns": cols,
            "chars": CHARS,
            "advances": advances,
            "glyphs": glyphs,
            "line_h": LINE,
            "missing": "?",
        }
        with open(os.path.join(dst, "font_msg_%s.json" % name), "w") as f:
            json.dump(meta, f, indent=1)
    print("wrote font_msg_{%s}.png (%dx%d, cells %d, %d columns) and .json to %s"
          % (",".join(COLOURS), sheet.width, sheet.height, cell, cols, dst))


def verify(font, textures):
    """Largest difference between the decoded glyphs and the dumped glyph textures p3p_assets.py uses."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import p3p_assets
    files = {n[16:24]: n for n in os.listdir(textures) if len(n) == 28 and n.endswith(".png")}
    worst = 0
    for ch, data in p3p_assets.GLYPHS.items():
        if data not in files:
            continue
        tex = Image.open(os.path.join(textures, files[data])).convert("RGBA").getchannel("A")
        a, b = list(font.alpha(ord(ch) - 0x20).getdata()), list(tex.getdata())
        diff = max(abs(x - y) for x, y in zip(a, b))
        worst = max(worst, diff)
        print("%r: max difference %d" % (ch, diff))
    print("worst:", worst)


def pac_entry(pac, wanted):
    """An entry of one of the game's .bin/.pac archives."""
    at = 0
    while at + 256 <= len(pac):
        name = pac[at:at + 252].split(b"\0")[0].decode("ascii", "replace")
        size = struct.unpack("<I", pac[at + 252:at + 256])[0]
        if not name:
            break
        if name == wanted:
            return pac[at + 256:at + 256 + size]
        at += 256 + (size + 63) // 64 * 64
    sys.exit("%s isn't in %s" % (wanted, ARCHIVE))


def main(src, dst, textures=None):
    if src.lower().endswith(".cpk"):
        data = pac_entry(read_cpk_file(src, ARCHIVE), FONT)
    else:
        data = open(src, "rb").read()
    font = Font(data)
    build(font, dst)
    if textures:
        verify(font, textures)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
