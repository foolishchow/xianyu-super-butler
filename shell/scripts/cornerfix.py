#!/usr/bin/env python3
"""清除圆角矩形图标四角的白色像素。

用途：macOS 的 qlmanage 渲染 SVG 时会先把整块画布涂白，再把图形画上去，
于是圆角缺口露出的是白底而不是透明——在深色 Dock 里就是一条刺眼的白边。

本脚本按圆角矩形几何精确清角：只处理四个角的方形区域，
区域外距离圆心超过半径的像素改成全透明。圆弧边缘完全不动。

用法: cornerfix.py <input.png> <output.png> [radius_fraction]
      radius_fraction 默认 0.20（对应 viewBox 100x100 里的 rx="20"）
"""
import struct
import sys
import zlib


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path):
    """返回 (w, h, colortype, channels, rows)，rows 为 bytearray 行列表。"""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "不是 PNG"
    off, idat, w, h, ct, il = 8, [], 0, 0, 0, 0
    while off + 8 <= len(d):
        ln = struct.unpack(">I", d[off:off + 4])[0]
        typ = d[off + 4:off + 8]
        body = d[off + 8:off + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct, _c, _f, il = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        off += 8 + ln + 4
    assert bd == 8 and ct in (0, 4, 6), "仅支持 8-bit 灰度/灰度alpha/RGBA"
    assert il == 0, "不支持隔行扫描"
    ch = {0: 1, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(b"".join(idat))
    stride = w * ch
    rows = []
    pos = 0
    for y in range(h):
        f = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        prev = rows[y - 1] if rows else bytearray(stride)
        for i in range(stride):
            a = row[i - ch] if i >= ch else 0   # A(x-1)
            b = prev[i]                          # B(x)
            c = prev[i - ch] if i >= ch else 0   # C(x-1)
            if f == 1:
                row[i] = (row[i] + a) & 255
            elif f == 2:
                row[i] = (row[i] + b) & 255
            elif f == 3:
                row[i] = (row[i] + ((a + b) // 2)) & 255
            elif f == 4:
                row[i] = (row[i] + _paeth(a, b, c)) & 255
        rows.append(row)
    return w, h, ct, ch, rows


def write_png(path, w, h, ct, ch, rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, ct, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    r_frac = float(sys.argv[3]) if len(sys.argv) > 3 else 0.20

    w, h, ct, ch, rows = read_png(src)
    if ct == 4:  # 灰度+alpha 展开成 RGBA，后面统一按 RGBA 处理
        expanded = []
        for r in rows:
            o = bytearray()
            for x in range(w):
                o.extend((r[x * 2], r[x * 2], r[x * 2], r[x * 2 + 1]))
            expanded.append(o)
        rows, ct, ch = expanded, 6, 4

    S = w
    R = S * r_frac
    R2 = R * R
    cleared = 0
    for y in range(S):
        row = rows[y]
        for x in range(S):
            if row[x * ch + 3] == 0:
                continue
            # 归一化到左上角的坐标，超出 R 说明不在四角区域
            cx = x if x < R else S - 1 - x
            cy = y if y < R else S - 1 - y
            if cx >= R or cy >= R:
                continue
            # 像素中心相对圆心的距离，超出半径即在圆角之外
            dx = cx + 0.5 - R
            dy = cy + 0.5 - R
            if dx * dx + dy * dy > R2:
                row[x * ch + 3] = 0
                cleared += 1

    write_png(dst, S, S, ct, ch, rows)
    print("  已清除 %d 个圆角外白色像素（半径 %.0f%%）" % (cleared, r_frac * 100))
    return 0


if __name__ == "__main__":
    sys.exit(main())
