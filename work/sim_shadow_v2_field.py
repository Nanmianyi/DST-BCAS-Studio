# -*- coding: utf-8 -*-
"""影子 v2 的离线"实测"：把着色器公式逐像素算在真实图集上，直接看观感。

与 tools/shadow_* 那批仿真的区别：这里算的就是**已发布的 PS 公式本身**
（smoothstep 过渡带 + 四向偏移采样 + 高度浓度衰减），不是近似。用它回答两件事：

  1 半影半径开多大，边缘像"拍虚"而不是"糊成一团"；
  2 偏移采样会不会把图集里的邻居精灵拉进影子（鬼影块）—— 直接看图。

注意：离线用"每列距最低不透明像素的高度"代替游戏里的顶点高度（POS2D_UV.y），
所以是形状上的近似；游戏里这个值来自顶点，逐符号精确。

用法: python work/sim_shadow_v2_field.py [zip] [--box x0 y0 x1 y1]
输出: work/_shadowv2_<build>.png
"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
from shadow_fill_sim import load_page  # noqa: E402

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
GROUND = (94, 120, 62)
FONT = r"C:\Windows\Fonts\msyh.ttc"
ZOOM = 2

CUT_LO, CUT_HI, CUT_HI_SOFT = 0.05, 0.52, 0.86
SPREAD_BASE, SPREAD_H, SOFT_SPREAD = 0.8, 3.0, 0.6
DENS_MIN, DENS_K = 0.42, 1.30
OLD_CUT = 0.30


def ss(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def tap(a, r, dy, dx):
    """按 R 像素偏移采样（图集外=透明）。"""
    out = np.zeros_like(a)
    h, w = a.shape
    ys, xs = max(0, dy), max(0, dx)
    ye, xe = min(h, h + dy), min(w, w + dx)
    out[max(0, -dy):min(h, h - dy), max(0, -dx):min(w, w - dx)] = a[ys:ye, xs:xe]
    return out


def mask_field(A, R, soft, H):
    """着色器的 mask：5 次 smoothstep 采样取平均，再乘高度浓度。支持 R 逐像素。"""
    hi = CUT_HI + (CUT_HI_SOFT - CUT_HI) * soft
    acc = ss(CUT_LO, hi, A)
    for dy, dx, sgn in ((0, -1, (-1, 0)), (0, 1, (1, 0)), (-1, 0, (0, -1)), (1, 0, (0, 1))):
        if np.isscalar(R):
            t = tap(A, 0, sgn[0] * int(round(R)), sgn[1] * int(round(R)))
        else:
            # R 逐像素：按最大半径取整 + 只在各自半径处取（用一次性平移近似）
            t = tap(A, 0, sgn[0] * int(round(float(np.max(R)))), sgn[1] * int(round(float(np.max(R)))))
        acc = acc + ss(CUT_LO, hi, t)
    m = acc * 0.2
    return m * (1.0 - (1.0 - DENS_MIN) * np.power(np.clip(H, 0, 1), DENS_K))


def height_field(A, cap=240.0):
    """每列"距最低不透明像素的高度/cap" —— 游戏里换成顶点高度。"""
    h, w = A.shape
    H = np.zeros((h, w), np.float32)
    for x in range(w):
        col = np.nonzero(A[:, x] > 0.05)[0]
        if col.size == 0:
            continue
        low = col.max()
        ys = np.arange(max(0, int(low - cap)), low + 1)
        H[ys, x] = (low - ys) / cap
    return np.clip(H, 0, 1)


def paint(mask, alpha, tint):
    """影子合成到草地上：dst*(1-a) + tint*a。"""
    a = mask * alpha
    g = np.array(GROUND, np.float32) / 255.0
    t = np.array(tint, np.float32)
    out = g[None, None, :] * (1.0 - a[..., None]) + t[None, None, :] * a[..., None]
    return (np.clip(out, 0, 1) * 255).astype(np.uint8)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    zip_path = args[0] if args else os.path.join(DST_ANIM, "wilson.zip")
    box = None
    if "--box" in sys.argv:
        i = sys.argv.index("--box")
        box = tuple(int(v) for v in sys.argv[i + 1:i + 5])
    name, img = load_page(zip_path, 0)
    A = np.asarray(img.getchannel("A"), dtype=np.float32) / 255.0
    Hf = height_field(A)
    base = os.path.splitext(os.path.basename(zip_path))[0]

    if box is None:
        lab, n = ndimage.label(A > 0.05, structure=np.ones((3, 3), bool))
        sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
        big = int(np.argmax(sizes)) + 1
        sl = ndimage.find_objects(lab)[big - 1]
        m = 26
        box = (max(0, sl[1].start - m), max(0, sl[0].start - m),
               min(A.shape[1], sl[1].stop + m), min(A.shape[0], sl[0].stop + m))
    x0, y0, x1, y1 = box
    sub = A[y0:y1, x0:x1]
    Hsub = Hf[y0:y1, x0:x1]

    DAY = [(0.50, (0.016, 0.024, 0.043))]     # tint = SHADOW_TINT_DAY（sRGB 近似）
    panels = []
    g = np.array(GROUND, np.float32) / 255.0
    panels.append(("0 美术原样",
                   (np.clip(g[None, None, :] * (1 - sub[..., None])
                            + np.array([0.18, 0.18, 0.22], np.float32)[None, None, :] * sub[..., None],
                            0, 1) * 255).astype(np.uint8)))
    panels.append(("1 v1 硬裁0.30 平涂", paint((sub >= OLD_CUT).astype(np.float32), 0.50, (0, 0, 0))))
    # v2：半径梯度 + 高度浓度（这就是发布版的形状）
    for tag, r_base, r_h, soft in (("2 v2 R≈1.5", 0.6, 0.9, 0.0),
                                   ("3 v2 R≈3   (正午 soft=0)", 0.6, 2.4, 0.0),
                                   ("4 v2 R≈5", 0.8, 4.2, 0.0),
                                   ("5 v2 R≈8   (黄昏 soft=1)", 0.8, 4.2, 1.0)):
        R = (r_base + r_h * Hsub) * (1.0 + SOFT_SPREAD * soft)
        m = np.zeros_like(sub)
        # 逐像素半径：用 4 个量化半径分档取平均（离线近似，游戏里逐像素精确）
        for rr in (1, 3, 5, 8, 11, 14, 18, 22):
            sel = (np.abs(R - rr) < 1.5)
            if not sel.any():
                continue
            m[sel] = mask_field(sub, rr, soft, Hsub)[sel]
        panels.append((tag, paint(m, 0.50, DAY[0][1])))
    panels.append(("6 v2 全柔度 soft=1（黄昏）",
                   paint(mask_field(sub, 8, 1.0, Hsub), 0.40, (0.027, 0.020, 0.024))))

    cw, ch = x1 - x0, y1 - y0
    pad, cap, head = 10, 24, 40
    zw, zh = cw * ZOOM, ch * ZOOM
    sheet = Image.new("RGB", ((zw + pad) * len(panels) + pad, zh + cap + head), (246, 246, 248))
    d = ImageDraw.Draw(sheet)
    d.text((pad + 2, 8), "%s  %s  (%dx%d, %d×)" % (base, box, cw, ch, ZOOM),
           font=ImageFont.truetype(FONT, 16), fill=(20, 20, 24))
    f = ImageFont.truetype(FONT, 14)
    for i, (tag, im) in enumerate(panels):
        cx = pad + i * (zw + pad)
        d.text((cx + 2, head - 16), tag, font=f, fill=(30, 30, 36))
        sheet.paste(Image.fromarray(im).resize((zw, zh), Image.NEAREST), (cx, head + cap))
    out = os.path.join(HERE, "_shadowv2_%s.png" % base)
    sheet.save(out)
    print("wrote", out, sheet.size, "box", box)


if __name__ == "__main__":
    main()
