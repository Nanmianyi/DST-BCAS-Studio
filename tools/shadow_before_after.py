"""生成"旧/新"剪影实现的直观对比图（供进游戏前肉眼确认）。

对选定的真实精灵做两档缩放（1.0 = 影子原尺寸、0.6 = 被压扁缩小），
分别按旧实现与新实现算出掩膜，再以影子浓度合成到草地色上，并排输出。

旧 = 比例填充 + bias+4 粗 mip 探针 + 点采样（截图里"碎成块"的那版）
新 = 比例填充 + ±2 纹素 5tap 探针 + 线性/mip 采样（本次修复）

用法: python tools/shadow_before_after.py
输出: work/_shadow_before_after.png
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shadow_fill_sim import load_page, GROUND, MULT_A

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
# (zip, x, y, size, 说明)
CASES = [
    ("bee_queen_build.zip", 156, 956, 200, "蜂后绒毛边"),
    ("evergreen_new.zip", 1888, 956, 200, "常青树叶片"),
    ("wilson.zip", 0, 665, 200, "威尔逊帽/发丝"),
]
SCALES = (1.0, 0.6)
EPS, GAIN, SEAL = 0.004, 5.0, 6
CJK = r"C:/Windows/Fonts/msyh.ttc"


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def mip_chain(A, levels=12):
    out = [A]
    cur = A
    for _ in range(levels):
        h, w = cur.shape
        if h <= 1 or w <= 1:
            break
        h2, w2 = max(1, h // 2), max(1, w // 2)
        cur = cur[:h2 * 2, :w2 * 2].reshape(h2, 2, w2, 2).mean(axis=(1, 3))
        out.append(cur)
    return out


def sample(chain, lod, size, point):
    L = max(0, min(len(chain) - 1, int(round(lod)) if point else int(lod)))
    img = Image.fromarray((chain[L] * 255).astype(np.uint8))
    img = img.resize((size, size), Image.NEAREST if point else Image.BILINEAR)
    a0 = np.asarray(img, dtype=np.float32) / 255.0
    if point:
        return a0, L
    L1 = min(len(chain) - 1, L + 1)
    if lod - L <= 0.001 or L1 == L:
        return a0, L
    img1 = Image.fromarray((chain[L1] * 255).astype(np.uint8)).resize(
        (size, size), Image.BILINEAR)
    a1 = np.asarray(img1, dtype=np.float32) / 255.0
    f = lod - L
    return a0 * (1 - f) + a1 * f, L


def probe_max(A, r):
    near = A.copy()
    for dy, dx in ((-r, 0), (r, 0), (0, -r), (0, r)):
        near = np.maximum(near, np.roll(np.roll(A, dy, 0), dx, 1))
    return near


def mask_old(A, mip):
    fill = np.clip(A * GAIN, 0.0, 1.0)
    return np.maximum(fill, smoothstep(0.55, 0.85, np.maximum(A, mip)))


def mask_new(A):
    """新：低阈值扁平填充 + 四向封洞（无内部细节）"""
    m = smoothstep(0.006, 0.035, A)
    paint = A >= 0.02
    seal = np.ones_like(A, dtype=bool)
    for dy, dx in ((-SEAL, 0), (SEAL, 0), (0, -SEAL), (0, SEAL)):
        seal &= np.roll(np.roll(paint, dy, 0), dx, 1)
    return np.maximum(m, seal.astype(np.float32))


def compose(mask):
    m = (mask * MULT_A)[..., None]
    return (np.asarray(GROUND, dtype=np.float32)[None, None, :] * (1 - m)).astype(np.uint8)


def label_font(sz):
    try:
        return ImageFont.truetype(CJK, sz)
    except Exception:
        return ImageFont.load_default()


def main():
    font = label_font(20)
    font_s = label_font(16)
    cols = []
    for zi, scale in enumerate(SCALES):
        for ci, (build, x, y, size, desc) in enumerate(CASES):
            name, img = load_page(os.path.join(DST_ANIM, build), 0)
            A = np.asarray(img.getchannel('A'), dtype=np.float32) / 255.0
            A = A[y:y + size, x:x + size]
            chain = mip_chain(A)
            px = max(1, int(round(size * scale)))
            import math
            lod = max(0.0, -math.log2(scale)) if scale < 1 else 0.0
            A_pt, L = sample(chain, lod, px, point=True)
            A_ln, _ = sample(chain, lod, px, point=False)
            Lb = min(len(chain) - 1, L + 4)
            A_bias = np.asarray(Image.fromarray((chain[Lb] * 255).astype(np.uint8)).resize(
                (px, px), Image.NEAREST), dtype=np.float32) / 255.0
            old = compose(mask_old(A_pt, A_bias))
            new = compose(mask_new(A_ln))
            pair = np.concatenate([old, new], axis=1)
            cols.append((f"{desc}  {int(scale*100)}%",
                         f"左:旧(碎)  右:新(纯色一整块)", pair))
    zoom = 2
    cell = cols[0][2].shape[0]
    pad, lh = 8, 24
    cw = cell * zoom * 2 + pad
    rows = (len(cols) + 1) // 2
    sheet = Image.new('RGB', (cw * 2 + pad * 3, (cell * zoom + lh + pad) * rows + pad),
                      (246, 246, 246))
    d = ImageDraw.Draw(sheet)
    for i, (t1, t2, im) in enumerate(cols):
        col, row = i % 2, i // 2
        ox = pad + col * (cw + pad)
        oy = pad + row * (cell * zoom + lh + pad)
        d.text((ox, oy), t1, fill=(20, 20, 20), font=font)
        d.text((ox, oy + 22), t2, fill=(90, 90, 90), font=font_s)
        sheet.paste(Image.fromarray(im).resize((cell * zoom * 2, cell * zoom), Image.NEAREST),
                    (ox, oy + lh + 22))
    out = 'work/_shadow_before_after.png'
    sheet.save(out)
    print('->', out, sheet.size)


if __name__ == '__main__':
    main()
