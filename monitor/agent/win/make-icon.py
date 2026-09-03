#!/usr/bin/env python3
"""app.ico 생성기 (외부 라이브러리 없이). 배경 버건디 라운드 사각형 + 흰 모니터 + 초록 펄스 라인."""
import math, struct, zlib, sys

BG_TOP, BG_BOT = (181, 22, 63), (122, 15, 43)      # ILSAN IMS 색감
WHITE, SCREEN, GREEN = (255, 255, 255), (30, 41, 59), (34, 197, 94)

def sd_rrect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r); cy = min(max(py, y0 + r), y1 - r)
    return math.hypot(px - cx, py - cy) - r
def sd_seg(px, py, ax, ay, bx, by):
    abx, aby = bx - ax, by - ay; apx, apy = px - ax, py - ay
    t = max(0.0, min(1.0, (apx * abx + apy * aby) / (abx * abx + aby * aby)))
    return math.hypot(px - (ax + abx * t), py - (ay + aby * t))

PULSE = [(0.25, 0.44), (0.36, 0.44), (0.41, 0.33), (0.47, 0.56), (0.53, 0.37), (0.575, 0.44), (0.75, 0.44)]

def shade(u, v):
    """(u,v) in 0..1 → (r,g,b,a)"""
    a_bg = sd_rrect(u, v, 0.03, 0.03, 0.97, 0.97, 0.22)
    if a_bg > 0: return (0, 0, 0, 0)
    t = v
    col = tuple(int(BG_TOP[i] * (1 - t) + BG_BOT[i] * t) for i in range(3))
    # 모니터 외곽(흰) / 화면(네이비)
    if sd_rrect(u, v, 0.18, 0.20, 0.82, 0.64, 0.05) <= 0:
        col = WHITE
        if sd_rrect(u, v, 0.215, 0.235, 0.785, 0.605, 0.03) <= 0:
            col = SCREEN
            d = min(sd_seg(u, v, *PULSE[i], *PULSE[i + 1]) for i in range(len(PULSE) - 1))
            if d <= 0.022: col = GREEN
    # 스탠드 + 받침
    if 0.45 <= u <= 0.55 and 0.64 <= v <= 0.71: col = WHITE
    if sd_rrect(u, v, 0.32, 0.71, 0.68, 0.77, 0.03) <= 0: col = WHITE
    return (*col, 255)

def render(size, ss=4):
    """RGBA 픽셀 행 목록 (위→아래)"""
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            r = g = b = a = 0
            for j in range(ss):
                for i in range(ss):
                    u = (x + (i + 0.5) / ss) / size; v = (y + (j + 0.5) / ss) / size
                    pr, pg, pb, pa = shade(u, v)
                    r += pr * pa; g += pg * pa; b += pb * pa; a += pa
            n = ss * ss
            row.append((r // a, g // a, b // a, a // n) if a else (0, 0, 0, 0))
        rows.append(row)
    return rows

def png(size, rows):
    raw = b"".join(b"\0" + bytes(c for px in row for c in px) for row in rows)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")

def dib(size, rows):
    """고전 ICO 항목 (32bpp BGRA + AND 마스크). .NET Framework(Windows PowerShell) 트레이 아이콘 호환"""
    mask_row = ((size + 31) // 32) * 4
    hdr = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, size * size * 4 + mask_row * size, 0, 0, 0, 0)
    xor = b"".join(bytes(c for (r, g, b, a) in row for c in (b, g, r, a)) for row in reversed(rows))
    return hdr + xor + b"\0" * (mask_row * size)

sizes = [256, 64, 48, 32, 24, 16]
images = []
for s in sizes:
    rows = render(s)
    if s == 256: open("app-256.png", "wb").write(png(s, rows))   # 미리보기용
    images.append((s, png(s, rows) if s == 256 else dib(s, rows)))
with open("app.ico", "wb") as f:
    f.write(struct.pack("<HHH", 0, 1, len(images)))
    off = 6 + 16 * len(images)
    for s, data in images:
        f.write(struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), off)); off += len(data)
    for _, data in images: f.write(data)
print("app.ico", sum(len(d) for _, d in images), "bytes")
