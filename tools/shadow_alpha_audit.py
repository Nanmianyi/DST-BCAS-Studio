"""影子剪影 alpha 审计：真实图集里"内部淡结构"到底有多淡、多宽。

目的：决定剪影映射的形态。两种候选：
  A) 纯比例填充 m = clamp(a*K)：实现最简单、绝无外来内容，但内部比 1/K 还淡的
     结构会留着（= 影子内部透出眼睛/衣纹）。
  B) 比例填充 + 邻域探针（m = max(a*K, inside)）：能把宽的淡区也填实，但探针
     半径一大就会越过图集里相邻精灵的边界 → 影子内部出现"别人的美术"（矩形块）。

要回答的问题：
  1. DST 图集（.tex）到底带不带 mip 链？带的话粗 mip 会跨精灵平均。
  2. 淡像素里有多少是"被实心包围的内部"（漏点候选），有多少是外缘软边？
  3. 内部淡像素的淡区宽度分布 → 探针至少要多宽才够，K 要多大才够。

用法: python tools/shadow_alpha_audit.py [zip ...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageFilter
from ktex_preview import read_ktex, decode_dxt5

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"

DEFAULT = [
    "wilson.zip",                 # 玩家
    "dragonfly.zip",              # 大 Boss
    "beequeen.zip",
    "evergreen_new.zip",          # 树
    "bramblefx.zip",
    "wormwood.zip",               # 半透明系
]


def load_meta(path):
    import zipfile
    with zipfile.ZipFile(path) as z:
        tex = sorted(n for n in z.namelist() if n.endswith('.tex'))
        out = []
        for name in tex:
            data = z.read(name)
            comp, metas, blobs = read_ktex(data)
            out.append((name, comp, metas, blobs))
        return out


def audit(path, page=0):
    pages = load_meta(path)
    if page >= len(pages):
        return
    name, comp, metas, blobs = pages[page]
    w, h, pitch, sz = metas[0]
    print(f'== {os.path.basename(path)} : {name}  {w}x{h} comp={comp} mip_count={len(metas)}')
    print(f'   mip sizes: {[m[0] for m in metas][:8]}')
    if comp != 2:
        print('   (skip: not DXT5)')
        return
    img = decode_dxt5(blobs[0], w, h)
    a = img.getchannel('A')

    import numpy as np
    A = np.asarray(a, dtype=np.float32) / 255.0
    painted = A > 0
    n = int(painted.sum())
    if n == 0:
        print('   empty page')
        return
    solid = A >= 0.90
    faint = (A > 0.02) & (A < 0.35)
    mid = (A >= 0.35) & (A < 0.90)
    print(f'   有像素 {n}  solid>=0.9 {int(solid.sum())*100.0/n:.1f}%  '
          f'mid .35-.9 {int(mid.sum())*100.0/n:.1f}%  '
          f'faint .02-.35 {int(faint.sum())*100.0/n:.1f}%')

    # 邻域最大 alpha（把"被实心包围"和"外缘"分开）
    for R in (2, 4, 8):
        conv = ImageFilter.MaxFilter(2 * R + 1)
        near = np.asarray(a.filter(conv), dtype=np.float32) / 255.0
        enc = faint & (near >= 0.90)      # 内部漏点候选（半径 R 内有实心）
        iso = faint & (near <= 0.35)      # 真正孤立软边
        print(f'   R={R:2d}px: faint 里被实心包围 {int(enc.sum())*100.0/max(1,int(faint.sum())):.1f}%'
              f'  孤立软边 {int(iso.sum())*100.0/max(1,int(faint.sum())):.1f}%')

    # 内部漏点的 alpha 分布：K 取多大才够
    conv = ImageFilter.MaxFilter(17)
    near = np.asarray(a.filter(conv), dtype=np.float32) / 255.0
    enc = faint & (near >= 0.90)
    vals = A[enc]
    if vals.size:
        import collections
        qs = [1, 5, 10, 25, 50, 75, 90]
        pct = [float(np.percentile(vals, q)) for q in qs]
        print('   内部漏点 alpha 分位 ' + '  '.join(f'p{q}={v:.3f}' for q, v in zip(qs, pct)))
        for K in (3, 5, 8, 12, 20):
            fixed = float((vals * K >= 1.0).mean()) * 100.0
            print(f'      K={K:2d}: 这些漏点里 {fixed:.1f}% 被填成实心')
        # 宽度：淡区距离最近实心像素有多远 —— 用 R 系列估算
        conv2 = ImageFilter.MaxFilter(5)
        near5 = np.asarray(a.filter(conv2), dtype=np.float32) / 255.0
        w1 = float((faint & (near5 >= 0.9)).sum())
        print(f'   淡像素中，距离实心 <=2px 的占 {w1*100.0/max(1,int(faint.sum())):.1f}%'
              f'  （这些是描边/细节）')


if __name__ == '__main__':
    args = sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT]
    for p in args:
        if os.path.exists(p):
            try:
                audit(p)
            except Exception as e:
                print('ERR', p, e)
        else:
            print('missing', p)
