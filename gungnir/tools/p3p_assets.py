"""Builds the slyshayne.p3p pack's title and Config art from textures dumped from your own copy of the game.

The art is the game's, so it isn't in the repository (the pack's assets/game/ is gitignored). Dump the
title's textures with PPSSPP ([Graphics] SaveNewTextures = True in ppsspp.ini, then open the title
menu with both protagonists and Config), then:

    python -I gungnir/tools/p3p_assets.py <PSP/TEXTURES/ULUS10512/new> gungnir/packs/slyshayne.p3p/assets/game

A third folder, optional, holds orpheus_male.png and orpheus_female.png decoded from the game's
umd0.cpk (see orpheus() below) for the protagonist select.

Needs Pillow. Texture names are PPSSPP's hashes for the US release (ULUS10512).
"""
import os
import sys

from PIL import Image, ImageFilter, ImageOps

WHOLE = {
    "art_female.png": "09443a10b93c8800fdbcf696.png",
    "art_male.png": "094331f0a7920b4f719330fe.png",
    "moon.png": "09415b503dac1822dbdf86ff.png",
    "logo.png": "09426230923277be62b1a086.png",
    "creature.png": "0942e9d04004957d4f57725f.png",
}
ATLAS = "09413270a4a5585354d8cad1.png"
# (u, v, w, h) in the text atlas.
PIECES = {
    "text_pab.png": (3, 3, 151, 9),
    "text_new.png": (161, 3, 82, 8),
    "text_load.png": (161, 16, 90, 8),
    "text_config.png": (178, 29, 59, 9),
    "text_install.png": (4, 53, 95, 9),
    "text_copyright.png": (4, 37, 126, 12),
    "pill_left.png": (242, 29, 10, 12),
}


# Config, drawn 4x (the second screen's scale) with smooth scaling: (texture, u, v, w, h).
CONFIG = {
    "cfg_title.png": ("0938f1b0840abcac91f82444", 2, 46, 144, 20),
    "cfg_on.png": ("0937ef301546d75730ff9a8d", 45, 115, 17, 7),
    "cfg_off.png": ("0937ef301546d75730ff9a8d", 102, 115, 24, 7),
    "cfg_none.png": ("0937ef301546d75730ff9a8d", 65, 115, 34, 7),
    "cfg_ok.png": ("0937ef301546d75730ff9a8d", 2, 102, 17, 7),
    "cfg_arrow.png": ("09367a10d5c9ffce74e8c8c4", 246, 60, 8, 7),
    "cfg_dpad.png": ("0937a0905267b1ffb3bf1128", 212, 24, 19, 17),
    "cfg_switch.png": ("0937a0905267b1ffb3bf1128", 154, 23, 43, 15),
    "cfg_x.png": ("0937a0905267b1ffb3bf1128", 24, 3, 16, 16),
    "cfg_okword.png": ("0937a0905267b1ffb3bf1128", 87, 3, 21, 17),
    "cfg_o.png": ("0937a0905267b1ffb3bf1128", 3, 3, 16, 16),
    "cfg_back.png": ("0937a0905267b1ffb3bf1128", 63, 23, 30, 15),
}
# Config's text is drawn a letter at a time, each letter its own 32x32 texture (white, alpha only) at 0.82
# scale. A letter's texture is uploaded wherever the game has room, so it's found by the data hash at the
# end of its name: char -> hash. A space is a texture too (a faint dot, not drawn here).
GLYPHS = {
    "a": "03c284bb", "b": "85c15dfb", "c": "fa5d73e5", "d": "01ee6886", "e": "5f052b7b", "f": "6bd9ec9b",
    "g": "ca6572b7", "h": "7381cdbd", "i": "03d68669", "l": "2fd6cc73", "m": "b843bdf1", "n": "dfc428fd",
    "o": "e69566ec", "p": "2860d806", "r": "bea63980", "s": "fb6eb1bb", "t": "2c95eb3b", "u": "061a0485",
    "v": "dfe78a82", "x": "2a092878", "y": "db0c564c", "A": "ed147567", "C": "7d39374c", "D": "edb7ebdc",
    "F": "935e4650", "I": "3cd6bd22", "M": "ef15fc3e", "N": "6775f70b", "O": "df4626de", "R": "ea689d87",
    "T": "c16af3e7", "V": "493188aa", "/": "2563dfb6", " ": "1fe5e53c",
}
ROWS = ["Voices", "Auto Text", "Cursor Memory", "Tactics Memory", "Invert Rotation", "Data Install", "Confirm"]
HELP = [
    ["Turn event voices", "ON/OFF"],
    ["Auto advance text", "during voiced events"],
    ["Remember the cursor position", "during battle"],
    ["Remember Tactics settings", "after battles"],
    ["Invert the rotation", "of the battle command menu"],
    ["Turn Data Install", "ON/OFF"],
    ["Confirm the settings", "and return to the game"],
]
SCALE = 4
GLYPH_SCALE = 0.82 * SCALE
GAP = 1.4 * SCALE
LINE = 13 * SCALE
PAD = 16  # the first letter's ink starts this far into the picture


def glyphs(src):
    """char -> (picture at GLYPH_SCALE, ink left, ink right in texture pixels)."""
    files = {name[16:24]: name for name in os.listdir(src) if len(name) == 28 and name.endswith(".png")}
    cell = round(32 * GLYPH_SCALE)
    out = {}
    for ch, data in GLYPHS.items():
        if data not in files:
            sys.exit("missing the glyph %r (*%s.png): open every Config row with texture dumping on" % (ch, data))
        image = Image.open(os.path.join(src, files[data])).convert("RGBA")
        left, _, right, _ = image.getchannel("A").getbbox() or (13, 0, 19, 0)
        out[ch] = (image.resize((cell, cell), Image.BILINEAR), left, right)
    return out


def text(font, lines):
    """Lines as the game lays them out: each letter's ink follows the last one's, GAP apart."""
    cell = round(32 * GLYPH_SCALE)
    placed, width = [], 0
    for row, line in enumerate(lines):
        pen = float(PAD)
        for ch in line:
            image, left, right = font[ch]
            x = pen - left * GLYPH_SCALE
            if ch != " ":
                placed.append((image, round(x), row * LINE))
            pen = x + right * GLYPH_SCALE + GAP
        width = max(width, int(pen) + PAD)
    out = Image.new("RGBA", (width, cell + LINE * (len(lines) - 1)), (0, 0, 0, 0))
    for image, x, y in placed:
        out.alpha_composite(image, (x, y))
    return out


def config(src, dst):
    for name, (tex, u, v, w, h) in CONFIG.items():
        piece = Image.open(os.path.join(src, tex + ".png")).convert("RGBA").crop((u, v, u + w, v + h))
        piece.resize((w * SCALE, h * SCALE), Image.BILINEAR).save(os.path.join(dst, name))
    font = glyphs(src)
    for i, name in enumerate(ROWS):
        text(font, [name]).save(os.path.join(dst, "cfg_label_%d.png" % i))
    for i, lines in enumerate(HELP):
        text(font, lines).save(os.path.join(dst, "cfg_help_%d.png" % i))

def main(src, dst):
    os.makedirs(dst, exist_ok=True)
    for name, tex in WHOLE.items():
        Image.open(os.path.join(src, tex)).convert("RGBA").save(os.path.join(dst, name))
    # The game adds the moon's light (at about 0.82) rather than covering what's behind; packs blend
    # normally, so fold its brightness into its alpha, which looks the same over the dark background.
    moon = Image.open(os.path.join(dst, "moon.png"))
    px = []
    for r, g, b, a in moon.getdata():
        m = max(r, g, b, 1)
        px.append((r * 255 // m, g * 255 // m, b * 255 // m, round(a * 0.82 * m / 255)))
    moon.putdata(px)
    moon.save(os.path.join(dst, "moon.png"))
    atlas = Image.open(os.path.join(src, ATLAS)).convert("RGBA")
    for name, (u, v, w, h) in PIECES.items():
        atlas.crop((u, v, u + w, v + h)).save(os.path.join(dst, name))
    cap = atlas.crop((242, 29, 252, 41))
    ImageOps.mirror(cap).save(os.path.join(dst, "pill_right.png"))
    # The game's own title, without what the pack draws instead: the atlas with only the copyright line.
    textures = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(dst))), "psp_textures")
    hidden = Image.new("RGBA", atlas.size, (0, 0, 0, 0))
    u, v, w, h = PIECES["text_copyright.png"]
    hidden.paste(atlas.crop((u, v, u + w, v + h)), (u, v))
    hidden.save(os.path.join(textures, "title_text.png"))
    config(src, dst)
    print("wrote the art to", dst, "and title_text.png to", textures)


ORPHEUS_HEIGHT = 1080  # the second screen's height: each Orpheus touches its top and bottom
ORPHEUS_EDGE = 6       # the outline round the full-colour one, as the protagonists have on the game's screen


def orpheus(src, dst):
    """Orpheus, his and hers, cropped to the figure and scaled smoothly to ORPHEUS_HEIGHT (the pack draws them
    1:1, so their edges stay smooth): _full in colour, _flat and _edge white (the pack tints them), _edge
    ORPHEUS_EDGE px bigger all round. [src] holds orpheus_male.png and orpheus_female.png: the game's
    data/camp/persona/pst_001.tmx and pst_0AE.tmx (in PSP_GAME/USRDIR/umd0.cpk), decoded to RGBA."""
    for name in ("orpheus_male", "orpheus_female"):
        image = Image.open(os.path.join(src, name + ".png")).convert("RGBA")
        alpha = image.getchannel("A").point(lambda a: a if a >= 8 else 0)  # its background isn't quite 0
        image.putalpha(alpha)
        image = image.crop(alpha.getbbox())
        size = (round(image.width * ORPHEUS_HEIGHT / image.height), ORPHEUS_HEIGHT)
        # Scaled with its colour premultiplied, so the edges don't pick up the background's colour.
        full = image.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")
        full.save(os.path.join(dst, name + "_full.png"))
        # Solid inside (its harp strings are see-through in colour), still smooth at the edge.
        flat = Image.new("RGBA", size, (255, 255, 255, 0))
        flat.putalpha(full.getchannel("A").point(lambda a: 0 if a < 24 else min(255, 8 * a)))
        flat.save(os.path.join(dst, name + "_flat.png"))
        e = ORPHEUS_EDGE
        grown = Image.new("L", (size[0] + 2 * e, size[1] + 2 * e), 0)
        grown.paste(full.getchannel("A"), (e, e))
        grown = grown.filter(ImageFilter.MaxFilter(2 * e + 1)).filter(ImageFilter.GaussianBlur(1))
        edge = Image.new("RGBA", grown.size, (255, 255, 255, 0))
        edge.putalpha(grown)
        edge.save(os.path.join(dst, name + "_edge.png"))
        print("%s: %dx%d" % (name, size[0], size[1]))
    print("wrote the Orpheus pictures to", dst)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
    if len(sys.argv) == 4:
        orpheus(sys.argv[3], sys.argv[2])
