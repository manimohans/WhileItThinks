#!/usr/bin/env python3
import math
import os
import struct
import sys
import zlib


ICON_NAMES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

FRAME_NAMES = [
    ("RaccoonBlink0.png", 0.0),
    ("RaccoonBlink1.png", 0.55),
    ("RaccoonBlink2.png", 1.0),
    ("RaccoonBlink3.png", 0.55),
]


def clamp(value, lower=0, upper=255):
    return max(lower, min(upper, int(round(value))))


def lerp(a, b, t):
    return a + (b - a) * t


def blend(dst, src):
    sr, sg, sb, sa = src
    dr, dg, db, da = dst
    a = sa / 255.0
    ia = 1.0 - a
    return (
        clamp(sr * a + dr * ia),
        clamp(sg * a + dg * ia),
        clamp(sb * a + db * ia),
        clamp(255 * (a + da / 255.0 * ia)),
    )


def rounded_rect_alpha(x, y, radius):
    px = min(x, 1.0 - x)
    py = min(y, 1.0 - y)
    if px >= radius or py >= radius:
        return 1.0
    cx = radius if x < 0.5 else 1.0 - radius
    cy = radius if y < 0.5 else 1.0 - radius
    d = math.hypot(x - cx, y - cy)
    edge = radius - d
    return max(0.0, min(1.0, edge * 80.0 + 0.5))


def line_distance(px, py, ax, ay, bx, by):
    vx = bx - ax
    vy = by - ay
    wx = px - ax
    wy = py - ay
    denom = vx * vx + vy * vy
    if denom == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    qx = ax + t * vx
    qy = ay + t * vy
    return math.hypot(px - qx, py - qy)


def ellipse_alpha(x, y, cx, cy, rx, ry, softness=90.0):
    value = 1.0 - ((x - cx) / rx) ** 2 - ((y - cy) / ry) ** 2
    return max(0.0, min(1.0, value * softness))


def triangle_alpha(px, py, ax, ay, bx, by, cx, cy):
    def sign(x1, y1, x2, y2, x3, y3):
        return (x1 - x3) * (y2 - y3) - (x2 - x3) * (y1 - y3)

    d1 = sign(px, py, ax, ay, bx, by)
    d2 = sign(px, py, bx, by, cx, cy)
    d3 = sign(px, py, cx, cy, ax, ay)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    if has_neg and has_pos:
        return 0.0
    edge = min(abs(d1), abs(d2), abs(d3))
    return max(0.0, min(1.0, edge * 42.0 + 0.35))


def draw_raccoon(size, blink=0.0, icon=True):
    pixels = []
    for j in range(size):
        row = []
        y = (j + 0.5) / size
        for i in range(size):
            x = (i + 0.5) / size
            alpha = rounded_rect_alpha(x, y, 0.185)
            diagonal = (x + y) / 2.0
            bg = (lerp(18, 32, diagonal), lerp(26, 54, diagonal), lerp(36, 50, diagonal), 255 * alpha)
            pixel = tuple(clamp(c) for c in bg)

            pulse = math.hypot(x - 0.74, y - 0.24)
            if pulse < 0.18:
                pixel = blend(pixel, (75, 227, 174, clamp((1.0 - pulse / 0.18) * 66 * alpha)))

            # Ears.
            for side in [-1, 1]:
                ear = triangle_alpha(
                    x,
                    y,
                    0.50 + side * 0.17,
                    0.33,
                    0.50 + side * 0.37,
                    0.18,
                    0.50 + side * 0.32,
                    0.49,
                )
                if ear:
                    pixel = blend(pixel, (49, 57, 60, clamp(240 * ear * alpha)))
                inner = triangle_alpha(
                    x,
                    y,
                    0.50 + side * 0.20,
                    0.34,
                    0.50 + side * 0.32,
                    0.24,
                    0.50 + side * 0.29,
                    0.43,
                )
                if inner:
                    pixel = blend(pixel, (210, 165, 132, clamp(185 * inner * alpha)))

            # Face and muzzle.
            face = ellipse_alpha(x, y, 0.50, 0.55, 0.36, 0.31, 22)
            if face:
                shade = 154 + 34 * (1.0 - y)
                pixel = blend(pixel, (shade, shade + 10, shade + 8, clamp(255 * face * alpha)))

            for cx in [0.38, 0.62]:
                patch = ellipse_alpha(x, y, cx, 0.50, 0.18, 0.12, 34)
                if patch:
                    pixel = blend(pixel, (39, 48, 51, clamp(235 * patch * alpha)))

            muzzle = ellipse_alpha(x, y, 0.50, 0.66, 0.19, 0.12, 34)
            if muzzle:
                pixel = blend(pixel, (229, 221, 197, clamp(242 * muzzle * alpha)))

            for cx in [0.39, 0.61]:
                eye_open = max(0.004, 0.030 * (1.0 - blink))
                eye = ellipse_alpha(x, y, cx, 0.50, 0.038, eye_open, 90)
                if blink < 0.96 and eye:
                    pixel = blend(pixel, (245, 246, 232, clamp(235 * eye * alpha)))
                    pupil = ellipse_alpha(x, y, cx, 0.50, 0.017, max(0.004, eye_open * 0.60), 130)
                    if pupil:
                        pixel = blend(pixel, (15, 24, 27, clamp(255 * pupil * alpha)))
                if blink > 0.25:
                    d = line_distance(x, y, cx - 0.035, 0.50, cx + 0.035, 0.50)
                    if d < 0.007 + 0.006 * blink:
                        pixel = blend(pixel, (12, 21, 24, clamp(230 * (1.0 - d / 0.014) * alpha)))

            nose = ellipse_alpha(x, y, 0.50, 0.62, 0.046, 0.030, 80)
            if nose:
                pixel = blend(pixel, (16, 24, 26, clamp(255 * nose * alpha)))

            smile = line_distance(x, y, 0.47, 0.69, 0.53, 0.69)
            if smile < 0.006:
                pixel = blend(pixel, (94, 78, 66, clamp(170 * (1.0 - smile / 0.006) * alpha)))

            for side in [-1, 1]:
                for yy in [0.63, 0.67]:
                    d = line_distance(x, y, 0.50 + side * 0.06, yy, 0.50 + side * 0.22, yy - 0.025 * side)
                    if d < 0.004:
                        pixel = blend(pixel, (95, 98, 91, clamp(120 * (1.0 - d / 0.004) * alpha)))

            if icon:
                for ax, ay, bx, by in [
                    (0.39, 0.19, 0.36, 0.12),
                    (0.50, 0.17, 0.50, 0.09),
                    (0.61, 0.19, 0.64, 0.12),
                ]:
                    d = line_distance(x, y, ax, ay, bx, by)
                    if d < 0.012:
                        pixel = blend(pixel, (238, 186, 64, clamp((1.0 - d / 0.012) * 230 * alpha)))
            else:
                for ax, ay, bx, by in [
                    (0.41, 0.23, 0.38, 0.17),
                    (0.50, 0.21, 0.50, 0.14),
                    (0.59, 0.23, 0.62, 0.17),
                ]:
                    d = line_distance(x, y, ax, ay, bx, by)
                    if d < 0.014:
                        pixel = blend(pixel, (238, 186, 64, clamp((1.0 - d / 0.014) * 230 * alpha)))

            row.append(tuple(clamp(c) for c in pixel))
        pixels.append(row)
    return pixels


def write_png(path, pixels):
    height = len(pixels)
    width = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend([r, g, b, a])

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
    png.extend(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
    png.extend(chunk(b"IEND", b""))

    with open(path, "wb") as handle:
        handle.write(png)


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: generate-icon.py OUTPUT.iconset [FRAMES_DIR]", file=sys.stderr)
        return 2
    output_dir = sys.argv[1]
    os.makedirs(output_dir, exist_ok=True)
    for name, size in ICON_NAMES:
        write_png(os.path.join(output_dir, name), draw_raccoon(size, blink=0.0, icon=True))
    if len(sys.argv) == 3:
        frames_dir = sys.argv[2]
        os.makedirs(frames_dir, exist_ok=True)
        for name, blink in FRAME_NAMES:
            write_png(os.path.join(frames_dir, name), draw_raccoon(256, blink=blink, icon=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
