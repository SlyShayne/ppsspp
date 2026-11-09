"""Builds the slyshayne.p3p pack's Dark Hour clock pieces from a capture of your own game.

At midnight the game's clock bursts apart and its pieces fly off the screen; the pack draws the ones that would
be below it on the second screen, live, from the game's own piece records (see gungnir/notes). For that it needs
each piece's shape in the piece's own frame, which this takes from one captured frame of the burst:

    python -I gungnir/tools/p3p_clock.py <capture stem> <numeral atlas png> gungnir/packs/slyshayne.p3p/assets/game

<capture stem>.ppdmp is a PPSSPP GE frame dump of a frame mid-burst (the WebSocket debugger's gpu.record.dump), and
<capture stem>.rec the game's piece block at the same moment (4 KiB from 0x09410000, read with memory.read while
paused; slow the game with game.speed.set first so both are the same frame). The atlas is the numerals' texture
(128x128, address 093a1c70) from a PPSSPP texture dump. Writes clock_shapes.lua (the pieces' shapes, which the
pack loads) and clock_numeral_<n>.png. The shapes are the game's, so they stay out of the repository like the
rest of assets/game.

Needs Pillow and zstandard.
"""
import math
import os
import struct
import sys

import zstandard
from PIL import Image

SCALE = 4                   # the second screen's pixels per PSP pixel
NUMERAL_TINT = (0x0B, 0x6D, 0x2B)  # their vertex colour in the burst
RECORDS = 0x120             # the first piece record in the block read from 0x09410000
RECORD = 0x34
# Read after the dump, the records are about a frame on from the frame dumped: each is stepped back this many
# frames by its own velocities first (the value that makes the pieces most rigid between two captures).
LAG = 1.0
# The burst frame's draws in order, and the piece record each belongs to (the game draws them this way every frame):
# twelve numerals, twelve triangle markers (each with an outline draw after it), the three hands and the middle's
# disc, then the inner ring's four arcs and the outer ring's four (each with an outline after it).
NUMERAL_DRAWS = [(7 + k, 3 + k) for k in range(12)]
FILL_DRAWS = ([(19 + 2 * k, 15 + k) for k in range(12)] + [(43, 2), (45, 0), (47, 1), (49, 0)]
              + [(51 + 2 * k, 27 + k) for k in range(4)] + [(59 + 2 * k, 32 + k) for k in range(4)])


def read_dump(path):
    """The draws of a GE frame dump (GPU/Debugger/RecordFormat.h): each PRIM's type, count and vertex positions."""
    d = open(path, "rb").read()
    ncmd = struct.unpack_from("<I", d, 24)[0]
    at, blocks = 32, []
    dz = zstandard.ZstdDecompressor()
    while at < len(d):
        n = struct.unpack_from("<I", d, at)[0]
        blocks.append(dz.decompress(d[at + 4:at + 4 + n], max_output_size=64 << 20))
        at += 4 + n
    cmds, buf = blocks[0], blocks[1]
    vtype, verts, draws = 0, None, []
    for i in range(ncmd):
        kind, sz, ptr = struct.unpack_from("<BII", cmds, 9 * i)
        if kind == 2:
            verts = ptr
        if kind != 1:
            continue
        for j in range(sz // 4):
            w = struct.unpack_from("<I", buf, ptr + 4 * j)[0]
            op, arg = w >> 24, w & 0xFFFFFF
            if op == 0x12:
                vtype = arg
            elif op == 0x04:
                draws.append((((arg >> 16) & 7), arg & 0xFFFF, vtype, verts))
    return draws, buf


def positions(draw, buf):
    """The vertex positions of a through-mode draw with u16 texcoords, 8888 colour and float positions."""
    prim, count, vtype, ptr = draw
    if (vtype & 0x1FF) != 0x19E:
        sys.exit("unexpected vertex format %06x" % vtype)
    return [struct.unpack_from("<2f", buf, ptr + 20 * i + 8) for i in range(count)]


def outline(prim, pts):
    """Polygons covering a primitive: a strip as the ribbon it is, a fan without its centre, triangles as they are."""
    if prim == 4:
        return [pts[0::2] + pts[1::2][::-1]]
    if prim == 5:
        return [pts[1:]]
    if prim == 3:
        return [pts[i:i + 3] for i in range(0, len(pts) - 2, 3)]
    sys.exit("unexpected primitive %d" % prim)


def to_local(p, rec, scaled):
    x, y, ang, zoom = rec[0], rec[1], math.radians(rec[4]), rec[6] if scaled else 1.0
    dx, dy = p[0] - x, p[1] - y
    return ((dx * math.cos(-ang) - dy * math.sin(-ang)) / zoom, (dx * math.sin(-ang) + dy * math.cos(-ang)) / zoom)


def main(stem, atlas_path, dst):
    draws, buf = read_dump(stem + ".ppdmp")
    block = open(stem + ".rec", "rb").read()
    recs = []
    for k in range(36):
        x, y, vx, vy, ang, av, zoom, dz = struct.unpack_from("<8f", block, RECORDS + RECORD * k + 4)
        recs.append((x - LAG * vx, y - LAG * vy, vx, vy, ang - LAG * av, av, zoom - LAG * dz, dz))
    lines = ["-- Made by gungnir/tools/p3p_clock.py from the game's own clock; local PSP pixels at zoom 1.",
             "return {", "  pieces = {"]
    for d, r in FILL_DRAWS:
        prim = draws[d][0]
        polys = [[to_local(p, recs[r], True) for p in poly] for poly in outline(prim, positions(draws[d], buf))]
        body = ", ".join("{" + ", ".join("%.2f, %.2f" % p for p in poly) + "}" for poly in polys)
        lines.append("    { rec = %d, polys = { %s } }," % (r, body))
    lines += ["  },", "  numerals = {"]
    atlas = Image.open(atlas_path).convert("RGBA")
    for n, (d, r) in enumerate(NUMERAL_DRAWS):
        corners = [to_local(p, recs[r], False) for p in positions(draws[d], buf)]
        cx, cy = sum(c[0] for c in corners) / 4, sum(c[1] for c in corners) / 4
        # The quad's first edge runs along the texture's u axis: its turn in the piece's frame.
        turn = math.degrees(math.atan2(corners[1][1] - corners[0][1], corners[1][0] - corners[0][0]))
        lines.append("    { rec = %d, x = %.2f, y = %.2f, turn = %.2f }," % (r, cx, cy, turn))
        u, v = 1 + 32 * (n % 4), 1 + 18 * (n // 4)
        cell = atlas.crop((u, v, u + 31, v + 17)).resize((31 * SCALE, 17 * SCALE), Image.BILINEAR)
        tinted = Image.new("RGBA", cell.size, NUMERAL_TINT + (0,))
        tinted.putalpha(cell.getchannel("A"))
        tinted.save(os.path.join(dst, "clock_numeral_%d.png" % n))
    lines += ["  },", "}", ""]
    open(os.path.join(dst, "clock_shapes.lua"), "w", newline="\n").write("\n".join(lines))
    print("wrote clock_shapes.lua and 12 numerals to", dst)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
