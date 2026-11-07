"""Builds the slyshayne.p3p pack's title art from textures dumped from your own copy of the game.

The art is the game's, so it isn't in the repository (the pack's assets/game/ is gitignored). Dump the
title's textures with PPSSPP ([Graphics] SaveNewTextures = True in ppsspp.ini, then open the title
menu with both protagonists), then:

    python -I gungnir/tools/p3p_assets.py <PSP/TEXTURES/ULUS10512/new> gungnir/packs/slyshayne.p3p/assets/game

Needs Pillow. Texture names are PPSSPP's hashes for the US release (ULUS10512).
"""
import os
import sys

from PIL import Image, ImageOps

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
    print("wrote", len(WHOLE) + len(PIECES) + 1, "files to", dst, "and title_text.png to", textures)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
