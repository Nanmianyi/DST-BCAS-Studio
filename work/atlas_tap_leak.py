# -*- coding: utf-8 -*-
"""量化"半影采样半径"能开到多大而不串到图集里的邻居精灵。

背景：影子 v2 在片元着色器里沿屏幕空间做 4 次偏移采样（半影）。采样点会跑出
本精灵在图集里的矩形，一旦落到**相邻精灵的不透明像素**上，影子边缘就会长出
邻居的形状（鬼影块）。

测量方法（用真实图集，不需要 build.bin 解析）：
  * 连通域 = 精灵内容（打包器按内容裁剪，矩形≈内容外扩 1~2px）；用连通域
    外接框 + PAD 当作精灵矩形，也就是"片元会出现的地方"。
  * 对矩形内每个像素，按着色器同样的公式算掩膜（自身 + 四向偏移采样）。
  * 泄漏 = 掩膜 > 0 但【自身美术在这一像素本来就是透明的】—— 这些像素本来
    不该有影子，是采样跑去邻居家取回来的。

输出：每个半径 R 下，各精灵的泄漏面积占比（最差 / 中位），据此定 SPREAD 上限。

用法: python work/atlas_tap_leak.py [zip ...]
"""
import os
import sys
import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
from shadow_fill_sim import load_page  # noqa: E402

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
DEFAULT = ["wilson.zip", "evergreen_new.zip", "tree_leaf_orange_build.zip",
           "sapling.zip", "flowers.zip", "bee_queen_build.zip"]

CUT_LO, CUT_HI = 0.05, 0.52      # 与着色器一致
PAD = 2                          # 打包器给精灵矩形留的边距（保守取小）
RADII = list(range(1, 13))
MIN_AREA = 400                   # 太小的连通域（噪点/笔画碎片）跳过


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def shifted(a, dy, dx):
    """把 a 平移 (dy,dx)，越界补 0（图集外是空的）。"""
    out = np.zeros_like(a)
    h, w = a.shape
    ys0, ys1 = max(0, dy), min(h, h + dy)
    xs0, xs1 = max(0, dx), min(w, w + dx)
    yd0, yd1 = max(0, -dy), min(h, h - dy)
    xd0, xd1 = max(0, -dx), min(w, w - dx)
    out[yd0:yd1, xd0:xd1] = a[ys0:ys1, xs0:xs1]
    return out


def measure(zip_path):
    name, img = load_page(zip_path, 0)
    A = np.asarray(img.getchannel("A"), dtype=np.float32) / 255.0
    opaque = A > CUT_LO
    lab, n = ndimage.label(opaque, structure=np.ones((3, 3), bool))
    objs = ndimage.find_objects(lab)
    base = smoothstep(CUT_LO, CUT_HI, A)

    worst = {r: 0.0 for r in RADII}
    worst_med = {r: [] for r in RADII}
    n_used = 0
    for i, sl in enumerate(objs):
        if sl is None:
            continue
        ys, xs = sl
        comp = (lab[sl] == (i + 1))
        if comp.sum() < MIN_AREA:
            continue
        y0, y1 = max(0, ys.start - PAD), min(A.shape[0], ys.stop + PAD)
        x0, x1 = max(0, xs.start - PAD), min(A.shape[1], xs.stop + PAD)
        own = A[y0:y1, x0:x1]
        m0 = base[y0:y1, x0:x1]
        for r in RADII:
            taps = (base[y0 - r:y1 - r, x0:x1] if y0 - r >= 0 else None)
            acc = None
            for dy, dx in ((-r, 0), (r, 0), (0, -r), (0, r)):
                t = shifted(base, dy, dx)[y0:y1, x0:x1]
                acc = t if acc is None else acc + t
            mask = (m0 + acc) * 0.2
            leak = (mask > 0.06) & (own <= CUT_LO)
            frac = leak.sum() / float(mask.size)
            worst[r] = max(worst[r], frac)
            worst_med[r].append(frac)
        n_used += 1
    print("%-34s 页 %s 精灵 %d" % (os.path.basename(zip_path), img.size, n_used))
    for r in RADII:
        arr = np.array(worst_med[r]) * 100.0
        print("   R=%2d px   最差 %6.2f%%   中位 %5.2f%%   >1%% 的精灵 %d/%d"
              % (r, worst[r] * 100.0, np.median(arr), int((arr > 1.0).sum()), len(arr)))
    return worst


def main():
    for a in (sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT]):
        if os.path.exists(a):
            measure(a)
        else:
            print("missing", a)


if __name__ == "__main__":
    main()
