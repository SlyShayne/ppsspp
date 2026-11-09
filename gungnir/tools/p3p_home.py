"""Builds the slyshayne.p3p pack's home screen art: its fonts, and the game's art it shows.

The home screen (the one on the second screen most of the time) is drawn in the game's own font and art, so none of
it is in the repository (the pack's assets/game/ is gitignored):

    python -I gungnir/tools/p3p_home.py gungnir/packs/slyshayne.p3p/assets/game [umd0.cpk] [textures]

- Fonts, always: the game's font in the colours the screen writes in (the dark ink and accent of each protagonist's
  menus, gold, white, and the calendar's red and blue), tinted from font_msg_white (gungnir/tools/p3p_font.py).
  A bitmap font's colour roles replace pixels whole, which would lose the letters' smooth edges, so each colour is
  a sheet of its own.
- With the game's PSP_GAME/USRDIR/umd0.cpk: a headshot of each Persona (ps_<id>.png, cut from its picture
  data/camp/persona/pst_<id>.tmx), the Social Link cards (card_<arcana>.png from data/commu/card/c_cardNN.tmx) and
  the Social Links' people (bust_<NN>.png from data/commu/bustup/i_bustNN_a.tmx).
- With a PPSSPP texture dump (PSP/TEXTURES/ULUS10512/new, the menus opened while SaveNewTextures is on): the moods'
  icons (mood_<n>.png) and the social stats' kanji (kanji_<n>.png), from the menus' atlases.

Needs Pillow.
"""
import json
import os
import struct
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SCALE = 4
# ink0/acc0 are his (the menus' navy and blue), ink1/acc1 hers (maroon and pink).
COLOURS = {"ink0": (0x0B, 0x24, 0x40), "ink1": (0x5C, 0x0B, 0x24), "acc0": (0x1E, 0x6F, 0xD8),
           "acc1": (0xD0, 0x30, 0x6A), "gold": (0xF5, 0xB6, 0x30), "white": (0xFF, 0xFF, 0xFF),
           "red": (0xB0, 0x10, 0x2A), "blue": (0x12, 0x36, 0xC8)}  # the calendar's Sundays and Saturdays
HEADSHOT = 128   # px, the Persona panel's picture
CARD = (176, 220)   # px, the link details' card and person
CARD_SMALL = (56, 72)
KANJI_SCALE = 3  # the kanji beside the social stats, a little smaller than the screen's 4x
PORTRAIT_SCALE = 2.5  # the protagonist beside a choice they make
PORTRAIT_BLINK_Y = 36
# The menus' atlas (texture dump names less the address): the moods' disc and faces, the stats' kanji. Each piece
# is (u0, v0, u1, v1), placed at (x, y) in PSP pixels as the game draws it, in its colour (RGB, alpha).
ATLAS = "d5c9ffce74e8c8c4"
KANJI_A, KANJI_B = "1546d75730ff9a8d", "555b40a01c6c7de6"
DISC = ((1, 148, 23, 169), (0, 0), (0x4D, 0x6B, 0x89, 255))
FACES = {  # condition: face (the game draws them 1 px into the 22x21 disc)
    0: ((41, 129, 60, 147), (0x99, 0xF3, 0xFF, 255)),   # Good
    2: ((1, 129, 20, 147), (0xF3, 0xFF, 0xA3, 255)),    # Great
    3: ((21, 129, 40, 147), (0x99, 0xF3, 0xFF, 255)),   # Tired
    5: ((61, 129, 80, 147), (0xFF, 0xA3, 0xCF, 255)),   # Sick
}
KANJI = [  # Academics, Charm, Courage: two characters each, the second fainter, as on the STATUS screen
    [(KANJI_A, (62, 1, 95, 29), (0, 0), 0xE5), (KANJI_A, (96, 1, 127, 28), (30, 1), 0x99)],
    [(KANJI_B, (190, 47, 223, 75), (0, 0), 0xE5), (KANJI_A, (96, 1, 127, 28), (30, 0), 0x99)],
    [(KANJI_A, (61, 30, 92, 57), (0, 0), 0xE5), (KANJI_A, (93, 30, 126, 57), (29, 0), 0x99)],
]


def fonts(dst):
    src_png = os.path.join(dst, "font_msg_white.png")
    src_json = os.path.join(dst, "font_msg_white.json")
    if not (os.path.exists(src_png) and os.path.exists(src_json)):
        sys.exit("font_msg_white.png/.json aren't in %s: build them with gungnir/tools/p3p_font.py first" % dst)
    alpha = Image.open(src_png).convert("RGBA").getchannel("A")
    meta = json.load(open(src_json))
    sheet_dir = os.path.dirname(meta["sheet"])
    for name, rgb in COLOURS.items():
        tinted = Image.new("RGBA", alpha.size, rgb + (0,))
        tinted.putalpha(alpha)
        tinted.save(os.path.join(dst, "font_home_%s.png" % name))
        m = dict(meta, sheet="%s/font_home_%s.png" % (sheet_dir, name))
        with open(os.path.join(dst, "font_home_%s.json" % name), "w") as f:
            json.dump(m, f, indent=1)
    # Each letter's advance, for the script to shrink a name that wouldn't fit (assets/game/font_home_metrics.lua).
    adv = meta["advances"]
    pairs = ", ".join("[%d] = %d" % (ord(c), a) for c, a in zip(meta["chars"], adv))
    with open(os.path.join(dst, "font_home_metrics.lua"), "w", newline="\n") as f:
        f.write("-- The home screen font's advances by character code, in pixels at size 52 (p3p_home.py).\n")
        f.write("return { %s }\n" % pairs)
    print("wrote font_home_{%s} and font_home_metrics.lua" % ",".join(COLOURS))


# --- the game's archive ----------------------------------------------------------------------------------

def cpk_index(path):
    from p3p_font import utf_rows
    with open(path, "rb") as f:
        h = utf_rows(f.read(0x800), 0x10)[0]
        toc, content = h["TocOffset"], h["ContentOffset"]
        f.seek(toc)
        rows = utf_rows(f.read(h["TocSize"]), 0x10)
    base = min(toc, content) if content else toc
    out = {}
    for r in rows:
        name = (r["DirName"] + "/" + r["FileName"]) if r.get("DirName") else r["FileName"]
        out[name] = (base + r["FileOffset"], r["FileSize"])
    return out


def cpk_read(path, entry):
    from p3p_font import crilayla
    with open(path, "rb") as f:
        f.seek(entry[0])
        data = f.read(entry[1])
    return crilayla(data) if data[:8] == b"CRILAYLA" else data


def tmx(d):
    """A TMX0 picture: 8-bit (its CLUT swizzled as the PS2's), 4-bit, or 32-bit; alpha 0..0x80."""
    w, h = struct.unpack("<HH", d[0x12:0x16])
    fmt = d[0x16]
    pos = 0x40
    if fmt == 0:
        px = [tuple(d[pos + 4 * i:pos + 4 * i + 3]) + (min(255, d[pos + 4 * i + 3] * 2),) for i in range(w * h)]
    else:
        n = {0x13: 256, 0x14: 16}[fmt]
        pal = [tuple(d[pos + 4 * i:pos + 4 * i + 3]) + (min(255, d[pos + 4 * i + 3] * 2),) for i in range(n)]
        if n == 256:
            pal = [pal[i ^ 0x18 if (i & 0x18) in (0x08, 0x10) else i] for i in range(256)]
        pos += 4 * n
        if fmt == 0x13:
            px = [pal[b] for b in d[pos:pos + w * h]]
        else:
            px = []
            for b in d[pos:pos + w * h // 2]:
                px += [pal[b & 15], pal[b >> 4]]
    im = Image.new("RGBA", (w, h))
    im.putdata(px)
    return im


def cleaned(im):
    a = im.getchannel("A").point(lambda v: v if v >= 12 else 0)  # the background isn't quite 0
    im.putalpha(a)
    return im


def smooth(im, size):
    """Scaled with its colour premultiplied, so the edges don't pick up the background's colour."""
    return im.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def fit(im, box):
    """Into a box of [box] px, keeping its shape, at the bottom middle."""
    w, h = box
    s = min(w / im.width, h / im.height)
    small = smooth(im, (max(1, round(im.width * s)), max(1, round(im.height * s))))
    out = Image.new("RGBA", box, (0, 0, 0, 0))
    out.alpha_composite(small, ((w - small.width) // 2, h - small.height))
    return out


def headshot(im):
    """A square round the Persona's head: from the top of its body (the figure with thin parts such as staffs,
    horns and strings worn away), a side of 40% of the body's height (at most its width), centred on where the
    body is in that band."""
    from PIL import ImageFilter
    im = cleaned(im)
    a = im.getchannel("A").point(lambda v: 255 if v > 40 else 0).filter(ImageFilter.MinFilter(11))
    box = a.getbbox() or im.getchannel("A").getbbox()
    if not box:
        return None
    x0, y0, x1, y1 = box
    side = max(40, min(x1 - x0, round((y1 - y0) * 0.4)))
    band = a.crop((x0, y0, x1, y0 + side))
    cols = [sum(band.crop((x, 0, x + 1, side)).getdata()) for x in range(band.width)]
    total = sum(cols) or 1
    cx = x0 + sum(i * c for i, c in enumerate(cols)) / total
    left = round(cx - side / 2)
    top = y0 - round(side * 0.06)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.alpha_composite(im.crop((left, top, left + side, top + side)))
    return smooth(square, (HEADSHOT, HEADSHOT))


def archive_art(dst, cpk):
    idx = cpk_index(cpk)
    n = 0
    for pid in range(1, 256):
        e = idx.get("data/camp/persona/pst_%03X.tmx" % pid)
        if not e:
            continue
        hs = headshot(tmx(cpk_read(cpk, e)))
        if hs:
            hs.save(os.path.join(dst, "ps_%d.png" % pid))
            n += 1
    cards = 0
    for k in range(32):
        e = idx.get("data/commu/card/c_card%02x.tmx" % k)
        if not e:
            continue
        im = cleaned(tmx(cpk_read(cpk, e)))
        im = im.crop(im.getchannel("A").getbbox())
        fit(im, CARD).save(os.path.join(dst, "card_%d.png" % (k + 1)))
        fit(im, CARD_SMALL).save(os.path.join(dst, "card_s_%d.png" % (k + 1)))
        cards += 1
    busts = 0
    for name in idx:
        if name.startswith("data/commu/bustup/i_bust") and name.endswith("_a.tmx"):
            num = int(name[len("data/commu/bustup/i_bust"):-len("_a.tmx")], 16)
            im = cleaned(tmx(cpk_read(cpk, idx[name])))
            im = im.crop(im.getchannel("A").getbbox())
            fit(im, CARD).save(os.path.join(dst, "bust_%d.png" % num))
            busts += 1
    # The protagonists' bust-ups (data/bustup/b<character>_<outfit>.bin: a 256x256 TMX, then a 256x64 one, the
    # top of the face with its eyes shut, which goes PORTRAIT_BLINK_Y down it), for a choice they make:
    # port_<character>_<outfit>.png and _b.png.
    ports = 0
    for c in (1, 99):
        prefix = "data/bustup/b%d_" % c
        for name in idx:
            if not (name.startswith(prefix) and name.endswith(".bin")):
                continue
            d = cpk_read(cpk, idx[name])
            at = [i - 8 for i in _find_all(d, b"TMX0")]
            if len(at) < 2:
                continue
            outfit = name[len(prefix):-len(".bin")]
            base = cleaned(tmx(d[at[0]:]))
            shut = cleaned(tmx(d[at[1]:]))
            size = round(256 * PORTRAIT_SCALE)
            smooth(base, (size, size)).save(os.path.join(dst, "port_%d_%s.png" % (c, outfit)))
            smooth(shut, (size, round(64 * PORTRAIT_SCALE))).save(os.path.join(dst, "port_%d_%s_b.png" % (c, outfit)))
            ports += 1
    print("wrote %d Persona headshots, %d cards, %d people and %d protagonist portraits" % (n, cards, busts, ports))


def _find_all(data, word):
    out, i = [], data.find(word)
    while i >= 0:
        out.append(i)
        i = data.find(word, i + 1)
    return out


# --- the menus' atlases ------------------------------------------------------------------------------------

def find(textures, suffix):
    for f in os.listdir(textures):
        if f.lower().endswith(suffix + ".png"):
            return Image.open(os.path.join(textures, f)).convert("RGBA")
    sys.exit("*%s.png isn't in %s: open the menu (and STATUS) with SaveNewTextures on" % (suffix, textures))


def piece(atlas, uv, colour, size=None):
    p = atlas.crop(uv)
    r, g, b, a = colour
    tinted = Image.new("RGBA", p.size, (r, g, b, 0))
    tinted.putalpha(p.getchannel("A").point(lambda v: v * a // 255))
    return tinted


def menu_art(dst, textures):
    atlas = find(textures, ATLAS)
    for cond, (uv, colour) in FACES.items():
        icon = Image.new("RGBA", (22, 21), (0, 0, 0, 0))
        icon.alpha_composite(piece(atlas, DISC[0], DISC[2]), DISC[1])
        icon.alpha_composite(piece(atlas, uv, colour), (1, 2))
        icon.resize((22 * SCALE, 21 * SCALE), Image.BILINEAR).save(os.path.join(dst, "mood_%d.png" % cond))
    sheets = {KANJI_A: find(textures, KANJI_A), KANJI_B: find(textures, KANJI_B)}
    for k, parts in enumerate(KANJI):
        img = Image.new("RGBA", (64, 30), (255, 255, 255, 0))
        for sheet, uv, at, alpha in parts:
            img.alpha_composite(piece(sheets[sheet], uv, (255, 255, 255, alpha)), at)
        img.resize((64 * KANJI_SCALE, 30 * KANJI_SCALE), Image.BILINEAR).save(os.path.join(dst, "kanji_%d.png" % k))
    print("wrote the moods' icons and the stats' kanji")


def main(dst, cpk=None, textures=None):
    fonts(dst)
    if cpk:
        archive_art(dst, cpk)
    if textures:
        menu_art(dst, textures)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
