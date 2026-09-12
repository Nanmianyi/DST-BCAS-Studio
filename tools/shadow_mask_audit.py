"""整页图集的掩膜审计：量化"旧实现吃图 / 画到别人身上"与"新实现"的差别。

判据（都在真实图集上逐像素统计）：
  A. 吃掉（alpha 有像素但掩膜 0）—— 越少越好（= 影子不缺块）。
  B. 越界（alpha=0 但掩膜>0）—— 新实现必须为 0：这就是"影子内部画出别人美术 /
     影子长出多余矩形块"的来源。
  C. 内部淡细节被填实（alpha 0.02~0.35 且邻域有实心 → 掩膜>=0.9）—— 越多越好
     （= 眼睛/衣纹/发丝不再透出地面）。

旧实现 = 比例填充 + bias+4 粗 mip 探针（粗 mip 用 16x16 盒式平均 + 最近邻放大模拟）。
新实现 = 比例填充 + ±2 纹素 5 tap 探针 + gate（与 src_shaders/bcas_shadow.ps 一致）。

用法: python tools/shadow_mask_audit.py [zip ...]
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shadow_fill_sim import load_page

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
DEFAULT = ["wilson.zip", "evergreen_new.zip", "dragonfly_build.zip",
           "bee_queen_build.zip", "bee_guard_build.zip"]
EPS = 0.004
GAIN = 5.0
PROBE = 20  # 封洞半径（纹素）


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def mip_proxy(A, level=4):
    """粗 mip 的近似：2^level 盒式平均后最近邻放大（对齐 GPU 的 NEAREST + mip）"""
    k = 2 ** level
    small = np.asarray(Image.fromarray((A * 255).astype(np.uint8)).resize(
        (max(1, A.shape[1] // k), max(1, A.shape[0] // k)), Image.BOX),
        dtype=np.float32) / 255.0
    big = np.asarray(Image.fromarray((small * 255).astype(np.uint8)).resize(
        (A.shape[1], A.shape[0]), Image.NEAREST), dtype=np.float32) / 255.0
    return big


def mask_old(A, mip):
    """第一版（已废弃）：比例填充 + bias+4 粗 mip 探针"""
    fill = np.clip(A * GAIN, 0.0, 1.0)
    inside = smoothstep(0.55, 0.85, np.maximum(A, mip))
    return np.maximum(fill, inside)


def mask_flat(A, seal=PROBE):
    """当前实现（与 src_shaders/bcas_shadow.ps 一致）：
    低阈值扁平填充 + 四向"封洞"（上下左右都有像素才填）。"""
    m = smoothstep(0.006, 0.035, A)
    paint = A >= 0.02
    seal_ok = np.ones_like(A, dtype=bool)
    for dy, dx in ((-seal, 0), (seal, 0), (0, -seal), (0, seal)):
        seal_ok &= np.roll(np.roll(paint, dy, 0), dx, 1)
    return np.maximum(m, seal_ok.astype(np.float32))


def mask_new(A):
    return mask_flat(A)


def audit(path, page=0):
    name, img = load_page(path, page)
    if img is None:
        print('skip', path)
        return
    A = np.asarray(img.getchannel('A'), dtype=np.float32) / 255.0
    painted = A > 0.02
    empty = A <= 0.001
    # 内部淡细节（被实心包围的淡像素）
    solid_near = ndimage.maximum_filter(A, size=17) >= 0.9
    detail = (A > 0.02) & (A < 0.35) & solid_near

    rows = []
    for tag, m in (('旧(bias+4 mip 探针)', mask_old(A, mip_proxy(A))),
                   ('新(扁平填充 + 封洞)', mask_new(A))):
        eaten = int((painted & (m <= 0.01)).sum())
        bleed = int((empty & (m > 0.01)).sum())
        filled = int((detail & (m >= 0.9)).sum())
        flat = int((painted & (m >= 0.9)).sum())
        rows.append((tag, eaten, bleed, filled, int(detail.sum()),
                     float(painted.sum()), flat))
    print(f'== {os.path.basename(path)} : {name}  {img.size}')
    for tag, eaten, bleed, filled, ndet, npaint, flat in rows:
        print(f'   {tag:22s} 吃掉 {eaten:7d}px ({eaten * 100.0 / npaint:5.2f}%)  '
              f'越界 {bleed:7d}px  '
              f'内部细节填实 {filled * 100.0 / max(1, ndet):5.1f}%  '
              f'整体实心占比 {flat * 100.0 / npaint:5.1f}%')


if __name__ == '__main__':
    args = sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT]
    for p in args:
        if os.path.exists(p):
            try:
                audit(p)
            except Exception as e:
                print('ERR', p, type(e).__name__, e)
        else:
            print('missing', p)
