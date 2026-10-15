#!/usr/bin/env python3
"""校验 Windows PE 里嵌入了图标资源。

用法: python3 verify_pe_icon.py shell.exe

背景：Wails v3 beta.28 取窗口图标的顺序是
  1. LoadIcon(GetModuleHandle(""), 3)  —— 找 RT_GROUP_ICON，ID 写死为 3
  2. 失败才回退 application.Options.Icon

rsrc 生成的 RT_GROUP_ICON ID 固定是 1，对不上 3。所以 .syso 只能让
资源管理器/属性对话框看到图标，任务栏和窗口左上角还得靠 Options.Icon。
这个脚本用来确认两件都在，避免以后又悄悄退回到通用默认图标。

注意：Go 链接器写出的 .rsrc 段里，RESOURCE_DIR_ENTRY 的 OFFSET_TO_DATA
（高位置位时）是相对 .rsrc 段起始的偏移，不是绝对 RVA。
"""
import struct
import sys

TYPE_NAMES = {3: "RT_ICON", 14: "RT_GROUP_ICON", 24: "RT_MANIFEST"}


def die(msg):
    print(f"  ❌ {msg}")
    sys.exit(1)


def main(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        die("不是 PE 文件（DOS 头不是 MZ）")

    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        die("找不到 PE 签名")

    n_sections = struct.unpack_from("<H", data, pe_off + 6)[0]
    size_opt = struct.unpack_from("<H", data, pe_off + 20)[0]
    sections = []
    off = pe_off + 24 + size_opt
    for _ in range(n_sections):
        name = data[off:off + 8].rstrip(b"\0").decode("latin1")
        sections.append({
            "name": name,
            "vaddr": struct.unpack_from("<I", data, off + 12)[0],
            "vsize": struct.unpack_from("<I", data, off + 8)[0],
            "rawptr": struct.unpack_from("<I", data, off + 20)[0],
        })
        off += 40

    def rva2off(rva):
        for s in sections:
            if s["vaddr"] <= rva < s["vaddr"] + s["vsize"]:
                return s["rawptr"] + (rva - s["vaddr"])
        return None

    rsrc = next((s for s in sections if s["name"] == ".rsrc"), None)
    if rsrc is None:
        die("没有 .rsrc 段 —— 图标资源完全没被打进去（检查 rsrc_windows_amd64.syso 是否入库）")
    base = rsrc["vaddr"]
    print(f"  .rsrc 段: vaddr=0x{base:X} vsize=0x{rsrc['vsize']:.0f}")

    def read_dir(rva):
        """返回 [(标签, 子目录绝对RVA)]；子目录为 None 表示挂资源数据。"""
        off = rva2off(rva)
        if off is None:
            return []
        n_named = struct.unpack_from("<H", data, off + 12)[0]
        n_id = struct.unpack_from("<H", data, off + 14)[0]
        out = []
        for i in range(n_named + n_id):
            ent = off + 16 + i * 8
            name_id = struct.unpack_from("<I", data, ent)[0]
            if name_id & 0x80000000:  # 高位置位 → 指向 UTF-16 名字结构
                s_off = rva2off(base + (name_id & 0x7FFFFFFF))
                if s_off is None:
                    label = "??"
                else:
                    ln = struct.unpack_from("<H", data, s_off)[0]
                    label = "name:" + data[s_off + 2:s_off + 2 + ln * 2 - 2].decode("utf-16-le")
            else:
                label = f"id:{name_id}"
            raw_child = struct.unpack_from("<I", data, ent + 4)[0]
            child = (base + (raw_child & 0x7FFFFFFF)) if raw_child & 0x80000000 else None
            out.append((label, child))
        return out

    found = {}  # 类型ID -> [资源标签]
    for tlabel, tdir in read_dir(base):
        for idlabel, _leaf in read_dir(tdir):
            typ = tlabel.split(":")[1]
            found.setdefault(typ, []).append(idlabel.split(":")[1])

    for typ in sorted(found, key=int):
        print(f"  {TYPE_NAMES.get(int(typ), typ):14s}(0x{typ}): 资源ID {found[typ]}")

    if "14" not in found:
        die("没有 RT_GROUP_ICON —— Windows 显示不出图标")

    ids = found["14"]
    print(f"\n  RT_GROUP_ICON 的资源ID: {ids}")
    if "3" in ids:
        print("  ✅ ID 3 —— Wails beta.28 的 LoadIcon(handle, 3) 直接命中")
    else:
        print("  ⚠️  没有 ID 3 —— LoadIcon(handle, 3) 会失败，")
        print("      窗口左上角 / 任务栏图标必须靠 application.Options.Icon 兜住，")
        print("      资源管理器与属性对话框不受影响（它们枚举 RT_GROUP_ICON 不看 ID）")


if __name__ == "__main__":
    main(sys.argv[1])
