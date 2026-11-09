"""Builds the fonts the slyshayne.p3p pack's home screen writes in, from the game's font sheet p3p_font.py made.

The home screen (the one on the second screen most of the time) writes in the game's own font in a few colours: the
dark ink and the accent of each protagonist's menus, the menus' gold, and white. A bitmap font's colour roles
replace pixels whole, which would lose the letters' smooth edges, so each colour is a sheet of its own, tinted from
the white one:

    python -I gungnir/tools/p3p_home.py gungnir/packs/slyshayne.p3p/assets/game

Needs font_msg_white.png and .json there (gungnir/tools/p3p_font.py). Writes font_home_<colour>.png and .json; like
the rest of assets/game they stay out of the repository. Needs Pillow.
"""
import json
import os
import sys

from PIL import Image

# ink0/acc0 are his (the menus' navy and blue), ink1/acc1 hers (maroon and pink).
COLOURS = {"ink0": (0x0B, 0x24, 0x40), "ink1": (0x5C, 0x0B, 0x24), "acc0": (0x1E, 0x6F, 0xD8),
           "acc1": (0xD0, 0x30, 0x6A), "gold": (0xF5, 0xB6, 0x30), "white": (0xFF, 0xFF, 0xFF),
           "red": (0xB0, 0x10, 0x2A), "blue": (0x12, 0x36, 0xC8)}  # the calendar's Sundays and Saturdays


def main(dst):
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
    print("wrote font_home_{%s} to %s" % (",".join(COLOURS), dst))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
