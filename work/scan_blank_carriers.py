# -*- coding: utf-8 -*-
"""空白载体普查：本机所有模组里，"图集基本空白"的 anim 包有多少、叫什么名字、
有没有互不相关的模组给出**逐字节相同**的空白载体。

判定：图集 mip0 的唯一 DXT5 块 ≤ 4 种（空白/单色填充级别）。
输出：按整包 sha256 分组，看跨模组的全等组。只读。

== 本机实测结果（2026-09-15，DST 322330 全部已订阅模组）==
  * 带 build.bin 的 anim 包                5,751 个
  * 其中图集基本空白的（"空白载体"）          18 个
  * 两个不同创意工坊物品之间逐字节相同的       5 组 / 10 个文件
    （例如 512×512 全透明的同一个文件出现在两个互不相关的模组里，
     连 build.bin 里的名称串都一样）
结论：空/全透明图集的 anim 包在这个生态里会反复出现逐字节相同的副本，
单凭"哈希相同"说明不了来源。反之，带图案的图集因编码器约定不同
（同一张纯白方块，不同编码器写出的 alpha 端点字节并不一样）不会自然收敛 ——
判断具体文件时要区分这两类。
"""
import hashlib
import os
import re
import struct
import zipfile
from collections import defaultdict

WORKSHOP = r"J:/SteamLibrary/steamapps/workshop/content/322330"
BLOCK_LIMIT = 4


def strings(b, minlen=2):
    return [m.group().decode("ascii") for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, b)]


def mip0_blocks(blob):
    if blob[:4] != b"KTEX":
        return None
    word, = struct.unpack("<I", blob[4:8])
    n_mips = (word >> 13) & 0x1F
    off = 8
    mw = mh = size0 = None
    for i in range(n_mips):
        w_, h_, pitch, size = struct.unpack("<HHHI", blob[off:off + 10])
        off += 10
        if i == 0:
            mw, mh, size0 = w_, h_, size
    mip0 = blob[off:off + size0]
    if len(mip0) < size0:
        return None
    return mw, mh, n_mips, {mip0[i:i + 16] for i in range(0, size0, 16)}


def main():
    cands = []
    scanned = 0
    for dp, _dn, fn in os.walk(WORKSHOP):
        for f in fn:
            if not f.lower().endswith(".zip"):
                continue
            p = os.path.join(dp, f)
            try:
                with zipfile.ZipFile(p) as zf:
                    names = zf.namelist()
                    tex = next((n for n in names if n.lower().endswith(".tex")), None)
                    bld = next((n for n in names if n.lower().endswith("build.bin")), None)
                    if tex is None or bld is None:
                        continue
                    scanned += 1
                    rep = mip0_blocks(zf.read(tex))
                    if rep is None or len(rep[3]) > BLOCK_LIMIT:
                        continue
                    raw = open(p, "rb").read()
                    cands.append((p, rep, strings(zf.read(bld))[1:2], hashlib.sha256(raw).hexdigest()))
            except Exception:
                continue

    print("扫描 anim 包 %d 个；图集 mip0 唯一块 ≤ %d 的（空白载体）%d 个\n"
          % (scanned, BLOCK_LIMIT, len(cands)))

    groups = defaultdict(list)
    for p, rep, name, h in cands:
        groups[h].append((p, rep, name))

    print("== 按整包 sha256 分组 ==")
    for h, items in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        mods = sorted({os.path.relpath(i[0], WORKSHOP).replace("\\", "/").split("/")[0] for i in items})
        mw, mh, mips, blocks = items[0][1]
        print("\n%dx%d mips=%d 唯一块%d种  sha256=%s  模组%d个 文件%d个"
              % (mw, mh, mips, len(blocks), h[:16], len(mods), len(items)))
        for b in sorted(blocks):
            print("      块 %s" % b.hex())
        for p, rep, name in items:
            print("      %-58s build 名: %s" % (
                os.path.relpath(p, WORKSHOP).replace("\\", "/")[:58], name))


main()
