# -*- coding: utf-8 -*-
"""从 anim.bin 里找顶点数据，判定"美术 y 朝上还是朝下"。

影子 v2 的半影半径要按"离地高度"变化（贴地锐、越高越柔）。高度来自顶点属性
POS2D_UV.y，但**它的正方向没人验证过**：现有深度错位用的是 `美术上界 - y`，
那只是"给每个部件一个不同的深度"，方向颠倒也照样不闪（所以它证明不了正负）。

判定方法（不需要 build.bin 解析器）：在 anim.bin 里扫出 (x, y, u+页*2, v)
四元组（x,y 是美术坐标、u/v 是图集 UV），对同一个四边形的 4 个顶点看
**y 与 v 的相关性**：
  * 图集图片是"第一行=视觉顶部"存的（我们离线解码看图一直是正的）；
  * 所以对某个精灵，视觉顶部的那条边 v 更小；
  * y 与 v 正相关 → 视觉顶部对应更小的 y → y 朝下（越高 = y 越小）
  * y 与 v 负相关 → y 朝上。

用法: python work/anim_vertex_scan.py [zip ...]
"""
import io
import os
import struct
import sys
import zipfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
DEFAULT = ["wilson.zip", "evergreen_new.zip", "sapling.zip", "flowers.zip",
           "twiggy_build.zip", "bee_queen_build.zip"]


def scan_floats(data):
    """把整段字节按 4 字节对齐读成 float32（多种起点都试，避免对错相位）。"""
    best = None
    for phase in range(4):
        n = (len(data) - phase) // 4
        if n < 16:
            continue
        a = np.frombuffer(data[phase:phase + n * 4], dtype="<f4").astype(np.float64)
        yield phase, a


def quad_stats(a):
    """在浮点序列里找 (x, y, u+2p, v) 四元组：v∈[0,1]、u+2p∈[0,3.2]、x,y∈[1,4096]。"""
    n = (len(a) // 4) * 4
    q = a[:n].reshape(-1, 4)
    x, y, u, v = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    ok = ((v >= -0.001) & (v <= 1.001) & (u >= -0.001) & (u <= 3.2)
          & (x >= 0.5) & (x <= 4096.0) & (y >= 0.5) & (y <= 4096.0))
    idx = np.nonzero(ok)[0]
    if idx.size < 4:
        return None
    # 相邻 4 个一组 = 一个四边形
    quads = []
    i = 0
    while i + 4 <= idx.size:
        blk = idx[i:i + 4]
        if blk[-1] - blk[0] == 3:
            quads.append(q[blk])
            i += 4
        else:
            i += 1
    return quads


def analyze(path):
    with zipfile.ZipFile(path) as z:
        member = None
        for n in z.namelist():
            if n.endswith("anim.bin") or n.endswith(".bin") and b"ANIM" in z.read(n)[:16]:
                member = n
                break
        if member is None:
            print("%-26s 找不到 anim.bin" % os.path.basename(path))
            return 0, 0
        data = z.read(member)
    zooms = []
    for name in z.namelist():
        if name.startswith("atlas"):
            zi = z.getinfo(name)
            zooms.append((name, zi.file_size))
    total = pos = neg = flat = 0
    for phase, a in scan_floats(data):
        quads = quad_stats(a)
        if not quads:
            continue
        for qd in quads:
            ys, vs = qd[:, 1], qd[:, 3]
            # 只看 y 或 v 有变化的四边形（有意义的边）
            if np.ptp(ys) < 0.5 or np.ptp(vs) < 1e-4:
                continue
            r = np.corrcoef(ys, vs)[0, 1]
            if r > 0.5:
                pos += 1
            elif r < -0.5:
                neg += 1
            else:
                flat += 1
    total = pos + neg + flat
    print("%-26s y↑v 正相关 %4d   负相关 %4d   无相关 %4d" % (os.path.basename(path), pos, neg, flat))
    return pos, neg


def main():
    P = N = 0
    for a in (sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT]):
        if not os.path.exists(a):
            print("missing", a)
            continue
        p, n = analyze(a)
        P += p
        N += n
    print("-" * 62)
    print("合计：正相关 %d  负相关 %d" % (P, N))
    if P + N:
        print("判定：%s" % ("美术 y 朝【下】(越大越靠下, 现状 bcasTop-y 正确)"
                            if P > N else "美术 y 朝【上】(越大越高, 半影要用 y/bcasTop)"))


if __name__ == "__main__":
    main()
