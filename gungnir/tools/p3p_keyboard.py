"""Builds the slyshayne.p3p pack's name keyboard from a capture of your own game.

When the game asks for the protagonist's name it shows a keyboard of four blocks (A-Z, a-z, 0-9, symbols) with
buttons below. The pack hides it on the game's screen and draws it on the second, two blocks a page. This redraws
the game's own keyboard at the second screen's 4x from one frame of it:

    python -I gungnir/tools/p3p_keyboard.py <frame dump> <texture dump dir> gungnir/packs/slyshayne.p3p/assets/game

The frame dump is a PPSSPP GE frame dump (.ppdmp, the WebSocket debugger's gpu.record.dump) of the keyboard up
with the cursor on the first block. The texture dump dir is PPSSPP's TEXTURES/ULUS10512/new with the keyboard's
textures in it (SaveNewTextures on while it's shown; leave the cursor still a few seconds so its glow is dumped
too). Writes kb_*.png, which stay out of the repository like the rest of assets/game.

Needs Pillow and zstandard.
"""
import os
import struct
import sys

import zstandard
from PIL import Image

SCALE = 4
# The keyboard's textures, by their PPSSPP texture-dump names less the address (CLUT hash, data hash). The same
# three are made transparent on the game's screen by the pack's psp_textures.
TEXTURES = {"frame": "761e13dcd727d831", "font": "d71abe705af2670d", "icons": "fb9a49fbee39d8ff",
            "ball": "7be1e7f570d06089"}
# The cursor's glow, a soft black disc the game pulses round the ball while it rests (not in every frame).
GLOW = "075839fcf519dff4"
# A button's background as the game draws it while it can't be used: its art this far across the frame texture.
OFF_UV = (-88, 33)
NAVY = 0xFF513935           # the frame's colour, and the buttons' text (ABGR)
CELL = 0xFFF1BF99           # the keys' rows
BAR = 0xFFB7FBF9            # the cursor's row
BLACK, WHITE = 0xFF000000, 0xFFFFFFFF
# The game's keyboard, in PSP pixels: four blocks 110 apart from x = 20, rows 16 apart from y = 138, the buttons
# from y = 243. A page shows two blocks, so the second page's are drawn 220 to the left.
BLOCK_X, BLOCK_W = 20, 110
BUTTONS_Y = 241
# A page's picture covers this much of the game's screen (PSP pixels), its top left at (PAGE_X, PAGE_Y).
PAGE_X, PAGE_Y, PAGE_W, PAGE_H = 0, 112, 262, 152
# The button pictures: the game's draws with x in each range; the enabled background is OK's.
BUTTONS = {"del": (0, 75), "ok": (75, 130), "l": (180, 240), "r": (240, 300), "end": (360, 470)}


def read_dump(path):
    """Each sprite of a GE frame dump: texture address and its four vertices (x, y, u, v, colour)."""
    d = open(path, "rb").read()
    ncmd = struct.unpack_from("<I", d, 24)[0]
    at, blocks = 32, []
    dz = zstandard.ZstdDecompressor()
    while at < len(d):
        n = struct.unpack_from("<I", d, at)[0]
        blocks.append(dz.decompress(d[at + 4:at + 4 + n], max_output_size=64 << 20))
        at += 4 + n
    cmds, buf = blocks[0], blocks[1]
    state, verts, out = {}, None, []
    for i in range(ncmd):
        kind, sz, ptr = struct.unpack_from("<BII", cmds, 9 * i)
        if kind == 2:
            verts = ptr
        if kind != 1:
            continue
        for j in range(sz // 4):
            w = struct.unpack_from("<I", buf, ptr + 4 * j)[0]
            op, arg = w >> 24, w & 0xFFFFFF
            if op == 0x04 and (arg >> 16) & 7 == 4 and (state.get(0x12, 0) & 0x1FF) == 0x19E and verts is not None:
                tex = ((state.get(0xA8, 0) & 0xFF0000) << 8) | state.get(0xA0, 0)
                vs = []
                for k in range(arg & 0xFFFF):
                    u, v, col = struct.unpack_from("<2HI", buf, verts + 20 * k)
                    x, y = struct.unpack_from("<2f", buf, verts + 20 * k + 8)
                    vs.append((x, y, u, v, col))
                out.append((tex, vs))
            state[op] = arg
    return out


class Sprite:
    def __init__(self, tex, vs):
        self.tex = tex
        self.x0, self.x1 = min(v[0] for v in vs), max(v[0] for v in vs)
        self.y0, self.y1 = min(v[1] for v in vs), max(v[1] for v in vs)
        tl = min(vs, key=lambda v: (v[0], v[1]))
        br = max(vs, key=lambda v: (v[0], v[1]))
        self.uv = (tl[2], tl[3], br[2], br[3])
        self.col = vs[0][4]

    def moved(self, dx, col=None):
        s = Sprite.__new__(Sprite)
        s.__dict__.update(self.__dict__)
        s.x0, s.x1 = self.x0 + dx, self.x1 + dx
        if col is not None:
            s.col = col
        return s


def draw(img, s, tex, ox, oy):
    """One sprite onto [img], whose top left is PSP pixel (ox, oy): filtered as the game's upscaled screen is."""
    u0, v0, u1, v1 = s.uv
    crop = tex.crop((min(u0, u1), min(v0, v1), max(max(u0, u1), min(u0, u1) + 1), max(max(v0, v1), min(v0, v1) + 1)))
    if u1 < u0:
        crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
    if v1 < v0:
        crop = crop.transpose(Image.FLIP_TOP_BOTTOM)
    w, h = round((s.x1 - s.x0) * SCALE), round((s.y1 - s.y0) * SCALE)
    if w <= 0 or h <= 0:
        return
    crop = crop.resize((w, h), Image.BILINEAR)
    rgba = [(s.col >> 8 * k & 0xFF) / 255 for k in range(4)]
    crop = Image.merge("RGBA", [b.point(lambda p, m=m: round(p * m)) for b, m in zip(crop.split(), rgba)])
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    layer.paste(crop, (round((s.x0 - ox) * SCALE), round((s.y0 - oy) * SCALE)))
    img.alpha_composite(layer)


def picture(sprites, textures, box):
    x, y, w, h = box
    img = Image.new("RGBA", (w * SCALE, h * SCALE), (0, 0, 0, 0))
    for s in sprites:
        draw(img, s, textures[s.tex], x, y)
    return img


def main(dump, tex_dir, out):
    names = {}
    for f in os.listdir(tex_dir):
        for key, h in TEXTURES.items():
            if f.lower().endswith(h + ".png"):
                names[int(f[:8], 16)] = key
    sprites = [Sprite(t, vs) for t, vs in read_dump(dump)]
    sprites = [s for s in sprites if s.tex in names]
    found = {names[s.tex] for s in sprites}
    if found != set(TEXTURES):
        sys.exit("the keyboard's textures aren't all in %s (found %s)" % (tex_dir, sorted(found)))
    textures = {}
    for f in os.listdir(tex_dir):
        for key, h in TEXTURES.items():
            if f.lower().endswith(h + ".png"):
                textures[int(f[:8], 16)] = Image.open(os.path.join(tex_dir, f)).convert("RGBA")
    os.makedirs(out, exist_ok=True)
    kind = lambda s: names[s.tex]
    keys = [s for s in sprites if s.y0 < BUTTONS_Y]
    buttons = [s for s in sprites if s.y0 >= BUTTONS_Y]
    glyph = lambda s: kind(s) == "font" and s.col in (BLACK, WHITE) and s.x1 - s.x0 < 20
    row = lambda s, c: kind(s) == "font" and s.col == c
    block = lambda s: int((s.x0 - BLOCK_X) // BLOCK_W) if BLOCK_X <= s.x0 < BLOCK_X + 4 * BLOCK_W else None

    # The cursor's row and ball, which the pack moves; the rows under the bar are drawn as plain rows.
    bar = [s for s in keys if row(s, BAR)]
    ball = [s for s in keys if kind(s) == "ball"]
    bx, by = min(s.x0 for s in bar), min(s.y0 for s in bar)
    picture([s.moved(0) for s in bar], textures, (int(bx), int(by), 110, 19)).save(os.path.join(out, "kb_bar.png"))
    b = ball[0]
    picture(ball, textures, (int(b.x0), int(b.y0), 23, 23)).save(os.path.join(out, "kb_ball.png"))
    cells = [s.moved(0, CELL) if row(s, BAR) else s for s in keys if row(s, CELL) or row(s, BAR)]

    for page in (0, 1):
        shift = -2 * BLOCK_W * page
        base, black, white = [], [], []
        for s in keys:
            if kind(s) == "ball" or row(s, BAR):
                continue
            if row(s, CELL) or glyph(s):
                continue
            # The frame and its ornaments: those on the right come in to the second block's edge, the frame's
            # middle narrows to two blocks.
            if s.x0 < BLOCK_X + BLOCK_W and s.x1 > BLOCK_X + 3 * BLOCK_W:
                m = s.moved(0)
                m.x1 = s.x1 - 2 * BLOCK_W
                base.append(m)
            elif s.x0 > BLOCK_X + 2 * BLOCK_W:
                base.append(s.moved(-2 * BLOCK_W))
            else:
                base.append(s)
        for s in cells + [s for s in keys if glyph(s)]:
            k = block(s)
            if k is None or k // 2 != page:
                continue
            if glyph(s):
                base.append(s.moved(shift, BLACK))
                black.append(s.moved(shift, BLACK))
                white.append(s.moved(shift, WHITE))
            else:
                base.append(s.moved(shift))
        # Frame first, then rows, then letters, as the game draws them: the frame and the rows apart, since the
        # rows come in one by one as the keyboard arrives.
        order = lambda s: 0 if kind(s) == "frame" or s.col == NAVY else (1 if row(s, CELL) else 2)
        base.sort(key=order)
        box = (PAGE_X, PAGE_Y, PAGE_W, PAGE_H)
        picture([s for s in base if order(s) == 0], textures, box).save(os.path.join(out, "kb_frame%d.png" % page))
        picture([s for s in base if order(s) > 0], textures, box).save(os.path.join(out, "kb_rows%d.png" % page))
        # The letters alone, black (over the cursor's row) and white (the key under the cursor).
        picture(black, textures, box).save(os.path.join(out, "kb_black%d.png" % page))
        picture(white, textures, box).save(os.path.join(out, "kb_white%d.png" % page))

    # Each key's letter on its own, black, for the name as it's written: kb_k<key>.png, the key numbered as the
    # game does (block * 30 + row * 5 + column).
    for s in keys:
        if not glyph(s):
            continue
        k = block(s)
        col = round((s.x0 - 29 - BLOCK_W * k) / 19)
        r = round((s.y0 - 139) / 16)
        picture([s.moved(0, BLACK)], textures, (int(s.x0), int(s.y0), 17, 17)).save(
            os.path.join(out, "kb_k%d.png" % (k * 30 + r * 5 + col)))
    # The name's text cursor (a corner of the icons' texture, drawn black) and the cursor's glow, from its texture.
    icons = textures[next(t for t, n in names.items() if n == "icons")]
    bar_ = Image.merge("RGBA", [Image.new("L", (16, 5), 0)] * 3 + [icons.crop((0, 0, 16, 5)).split()[3]])
    bar_.resize((16 * SCALE, 5 * SCALE), Image.BILINEAR).save(os.path.join(out, "kb_tcur.png"))
    glow = [f for f in os.listdir(tex_dir) if f.lower().endswith(GLOW + ".png")]
    if not glow:
        sys.exit("the cursor's glow texture (*%s.png) isn't in %s: leave the cursor still a few seconds while "
                 "dumping" % (GLOW, tex_dir))
    Image.open(os.path.join(tex_dir, glow[0])).convert("RGBA").crop((1, 1, 31, 31)).resize(
        (44 * SCALE, 44 * SCALE), Image.BILINEAR).save(os.path.join(out, "kb_glow.png"))

    # The buttons, each cut to its own picture; Del and End also as the game draws them while they can't be used.
    def group(name):
        lo, hi = BUTTONS[name]
        return [s for s in buttons if lo <= s.x0 < hi]

    def save(name, group_):
        x0 = min(s.x0 for s in group_)
        y0 = min(s.y0 for s in group_)
        x1 = max(s.x1 for s in group_)
        y1 = max(s.y1 for s in group_)
        picture(group_, textures, (int(x0), int(y0), int(x1 - x0 + 0.999), int(y1 - y0 + 0.999))).save(
            os.path.join(out, name + ".png"))

    ok_bg = [s for s in group("ok") if kind(s) == "frame"]
    ok_left = min(ok_bg, key=lambda s: s.x0)

    def enabled(group_):
        out_ = []
        for s in group_:
            if kind(s) == "frame":
                m = s.moved(0)
                u0, v0, u1, v1 = ok_left.uv
                if s.uv[0] == s.uv[2]:      # the middle, a column stretched
                    m.uv = (u1, v0, u1, v1)
                elif s.uv[0] > s.uv[2]:     # the left cap, mirrored
                    m.uv = (u0, v0, u1, v1)
                else:
                    m.uv = (u1, v0, u0, v1)
                out_.append(m)
            else:
                out_.append(s)
        return out_

    for name in ("del", "end"):
        g = group(name)
        disabled = any(kind(s) == "frame" and s.uv[1] > 30 for s in g)
        save("kb_%s_%s" % (name, "off" if disabled else "on"), g)
        if disabled:
            save("kb_%s_on" % name, enabled(g))
    def disabled_(group_):
        out_ = []
        for s in group_:
            m = s.moved(0)
            if kind(s) == "frame":
                u0, v0, u1, v1 = s.uv
                m.uv = (u0 + OFF_UV[0], v0 + OFF_UV[1], u1 + OFF_UV[0], v1 + OFF_UV[1])
            out_.append(m)
        return out_

    for name in ("l", "r"):
        save("kb_%s_on" % name, group(name))
        save("kb_%s_off" % name, disabled_(group(name)))
    # The page buttons: L's button without its L, the game's < (and > as R's has it, mirrored).
    l_bg = [s for s in group("l") if kind(s) == "frame"]
    arrow = [s for s in group("l") if kind(s) == "font"][0]
    caps = sorted(l_bg, key=lambda s: s.x0)
    left, mid, right = caps[0], caps[1], caps[2]
    width = 36
    for name, flip in (("kb_prev", False), ("kb_next", True)):
        bg = [left.moved(-left.x0), mid.moved(-mid.x0 + (left.x1 - left.x0)), right.moved(-right.x0 + width - (right.x1 - right.x0))]
        bg[1].x1 = bg[1].x0 + width - (left.x1 - left.x0) - (right.x1 - right.x0)
        a = arrow.moved(-arrow.x0 + (width - (arrow.x1 - arrow.x0)) / 2)
        if flip:
            u0, v0, u1, v1 = a.uv
            a.uv = (u1, v0, u0, v1)
        save(name, bg + [a])
    # Behind it all, the misty blue of the game's name screen, darker at the top.
    top, bottom = (0x4F, 0x56, 0x66), (0x7A, 0x8A, 0xA3)
    grad = Image.new("RGB", (1, 270))
    for yy in range(270):
        t = yy / 269
        grad.putpixel((0, yy), tuple(round(a + (b_ - a) * t) for a, b_ in zip(top, bottom)))
    grad.save(os.path.join(out, "kb_bg.png"))
    print("wrote the keyboard to", out)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
