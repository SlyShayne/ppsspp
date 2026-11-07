"""Renders the P3P title's background gradient for the slyshayne.p3p pack (assets/gradient.png).

The game draws it with vertex colours, not a texture. Measured on its top screen (1920x1080, the PSP's
480x272 at 4x): radial from the top-right corner, #4D4FAE there to #05072F about 1350 px away, falling
off as 1 - (d / 1350) ** 1.16 (it matches samples at 40, 422, 1110, 1236 and 1336 px). The companion's
canvas is 1240x1080, the same height, so the same radius in pixels keeps the look.

    python -I gungnir/tools/p3p_gradient.py gungnir/packs/slyshayne.p3p/assets/gradient.png
"""
import struct
import sys
import zlib

W, H = 1240, 1080
BRIGHT = (0x4D, 0x4F, 0xAE)
DARK = (0x05, 0x07, 0x2F)
RADIUS = 1350.0
POWER = 1.16


def colour(x, y):
    d = ((W - x) ** 2 + y ** 2) ** 0.5
    f = max(0.0, 1.0 - min(d / RADIUS, 1.0) ** POWER)
    return bytes(round(DARK[k] + (BRIGHT[k] - DARK[k]) * f) for k in range(3))


def png(path):
    rows = bytearray()
    for y in range(H):
        rows.append(0)
        for x in range(W):
            rows += colour(x + 0.5, y + 0.5)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    png(sys.argv[1] if len(sys.argv) > 1 else "gradient.png")
