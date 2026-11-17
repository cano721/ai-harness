"""Harness Board 런처 앱 아이콘(.icns)을 그린다.

`board.sh launcher install`이 부른다. 저장소에 바이너리 아이콘을 두지 않고 설치 때 표준 라이브러리만으로 그린다.
.icns는 크기별 PNG를 담는 컨테이너라 iconutil·sips 없이 직접 쓴다(macOS 10.7부터 PNG 항목을 읽는다).
그림: 어두운 남색 둥근 사각형 위에 2×2 타일(보드) — 오른쪽 위 하나만 초록(살아 있는 세션).
"""

import math
import struct
import sys
import zlib

# (icns 항목 종류, 픽셀 크기). @2x 항목은 같은 그림을 재사용한다.
ENTRIES = [
    (b"icp4", 16), (b"icp5", 32), (b"ic07", 128), (b"ic08", 256), (b"ic09", 512),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]

TOP = (0x2B, 0x3A, 0x67)
BOTTOM = (0x11, 0x18, 0x2F)
TILE = (0xE2, 0xE8, 0xF0)
ACCENT = (0x34, 0xD3, 0x99)


def rounded_rect(px, py, cx, cy, half, radius):
    """둥근 사각형까지의 부호 거리(안쪽 음수)."""
    qx = abs(px - cx) - half + radius
    qy = abs(py - cy) - half + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def coverage(dist):
    return min(max(0.5 - dist, 0.0), 1.0)


def render(size):
    s = float(size)
    # macOS 아이콘 격자: 1024 중 본체 824, 모서리 반경 약 185.
    body_half, body_radius = s * 412 / 1024, s * 185 / 1024
    gap, tile_half = s * 36 / 1024, s * 118 / 1024
    offset = gap / 2 + tile_half
    tiles = [(-offset, -offset, TILE), (offset, -offset, ACCENT), (-offset, offset, TILE), (offset, offset, TILE)]
    tile_radius = s * 44 / 1024
    c = s / 2
    rows = []
    for y in range(size):
        py = y + 0.5
        t = (py - (c - body_half)) / (2 * body_half)
        t = min(max(t, 0.0), 1.0)
        base = tuple(TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3))
        row = bytearray(b"\x00")
        for x in range(size):
            px = x + 0.5
            alpha = coverage(rounded_rect(px, py, c, c, body_half, body_radius))
            if alpha <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue
            color = base
            for dx, dy, tile_color in tiles:
                k = coverage(rounded_rect(px, py, c + dx, c + dy, tile_half, tile_radius))
                if k > 0.0:
                    color = tuple(color[i] + (tile_color[i] - color[i]) * k for i in range(3))
            row += bytes((int(color[0] + 0.5), int(color[1] + 0.5), int(color[2] + 0.5), int(alpha * 255 + 0.5)))
        rows.append(bytes(row))
    return png(size, b"".join(rows))


def png(size, raw):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def icns():
    images = {size: render(size) for size in sorted({size for _, size in ENTRIES})}
    body = b"".join(kind + struct.pack(">I", len(images[size]) + 8) + images[size] for kind, size in ENTRIES)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: launcher-icon.py <out.icns>\n")
        return 2
    with open(sys.argv[1], "wb") as out:
        out.write(icns())
    return 0


if __name__ == "__main__":
    sys.exit(main())
