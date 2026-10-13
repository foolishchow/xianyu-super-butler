#!/usr/bin/env python3
"""图标后处理：清除圆角外的白色像素 + 补 macOS 安全边距。

两件事：

1. qlmanage 渲染 SVG 时会先把整块画布涂成 (255,255,255,255)，再把图形画上去，
   于是圆角缺口露出的是白底而不是透明——在深色 Dock 里是一条刺眼的白边。
   本脚本按圆角矩形几何把四角圆角外的不透明像素清成透明。圆弧边缘完全不动。

2. macOS 桌面图标不是满铺的：内容约占画布 80%，四周留约 10% 透明安全边距。
   （实测 Safari 256px 档：内容 80.5%，左边距 9.8%。）
   本脚本把内容居中垫到更大的透明画布上。

用法:
    iconfix.py <input.png> <output.png> --canvas 1024 --margin 0.10 --radius 0.20

    --canvas   输出画布边长（正方形），默认 1024
    --margin   四周留白占画布的比例，默认 0.10
    --radius   圆角半径占内容边长的比例，默认 0.20
               （对应 static/favicon.svg 的 viewBox 100x100 + rx="20"）

输入必须是正方形，边长应为 canvas * (1 - 2*margin)；不符会缩放。
纯标准库，自带 PNG 编解码（含 row filter 还原）。
"""
import argparse
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


def as_rgba(w, h, ct, ch, rows):
    """统一成 RGBA，便于后续处理。"""
    if ct == 6:
        return rows
    if ct == 4:
        out = []
        for r in rows:
            o = bytearray(w * 4)
            for x in range(w):
                o[x * 4:x * 4 + 4] = bytes((r[x * 2], r[x * 2], r[x * 2], r[x * 2 + 1]))
            out.append(o)
        return out
    out = []
    for r in rows:
        o = bytearray(w * 4)
        for x in range(w):
            g = r[x]
            o[x * 4:x * 4 + 4] = bytes((g, g, g, 255))
        out.append(o)
    return out


def clear_corners(rows, S, radius_frac):
    """清除四角圆角矩形外的不透明像素，返回清除数量。"""
    R = S * radius_frac
    R2 = R * R
    cleared = 0
    for y in range(S):
        row = rows[y]
        for x in range(S):
            if row[x * 4 + 3] == 0:
                continue
            # 归一化到左上角坐标，超出 R 说明不在四角区域
            cx = x if x < R else S - 1 - x
            cy = y if y < R else S - 1 - y
            if cx >= R or cy >= R:
                continue
            # 像素中心相对圆心的距离，超出半径即在圆角之外
            dx = cx + 0.5 - R
            dy = cy + 0.5 - R
            if dx * dx + dy * dy > R2:
                row[x * 4 + 3] = 0
                cleared += 1
    return cleared


def pad_onto(canvas, rows, content):
    """把 content 居中放到透明画布上（content 必须 <= canvas）。"""
    off = (canvas - content) // 2
    for dy in range(content):
        src = rows[dy]
        dst = canvas_rows[off + dy]
        for x in range(content):
            o_src = x * 4
            o_dst = (off + x) * 4
            a = src[o_src + 3]
            if a == 0:
                continue
            dst[o_dst:o_dst + 4] = src[o_src:o_src + 4]


def main():
    ap = argparse.ArgumentParser(description="图标清角 + 补安全边距")
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--canvas", type=int, default=1024, help="输出画布边长")
    ap.add_argument("--margin", type=float, default=0.10, help="四周留白比例")
    ap.add_argument("--radius", type=float, default=0.20, help="圆角半径占内容边长比例")
    args = ap.parse_args()

    w, h, ct, ch, rows = read_png(args.input)
    assert w == h, "输入必须是正方形"
    rows = as_rgba(w, h, ct, ch, rows)

    # 1. 按内容边长清角（此时圆角矩形铺满整个输入）
    cleared = clear_corners(rows, w, args.radius)

    # 2. 缩到目标内容尺寸再居中垫到画布上
    target = round(args.canvas * (1.0 - 2.0 * args.margin))
    if w != target:
        # 最近邻缩放（源已足够大，缩放比接近 1，视觉影响可忽略）
        scaled = []
        for ty in range(target):
            y = ty * w // target
            row = rows[y]
            o = bytearray(target * 4)
            for tx in range(target):
                x = tx * w // target
                o[tx * 4:tx * 4 + 4] = row[x * 4:x * 4 + 4]
            scaled.append(o)
        rows, w = scaled, target

    global canvas_rows
    canvas_rows = [bytearray(args.canvas * 4) for _ in range(args.canvas)]
    pad_onto(args.canvas, rows, w)

    write_png(args.output, args.canvas, args.canvas, 6, 4, canvas_rows)
    print("  清角 %d 个白色像素（半径 %.0f%%）；内容 %d -> 画布 %d（留白 %.0f%%）"
          % (cleared, args.radius * 100, w, args.canvas, args.margin * 100))
    return 0


if __name__ == "__main__":
    sys.exit(main())
