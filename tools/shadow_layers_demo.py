"""演示"多层影子叠加"为什么会有一块深一块浅，以及提高浓度上限后为什么就平了。

用真实图集里的一片树冠，按截图里那种"几棵树影互相压着"的方式叠 3 层，
分别用旧浓度 0.55 与新浓度 0.96 合成到地面色上，并排输出 + 标注每层的亮度。

用法: python tools/shadow_layers_demo.py
输出: work/_shadow_layers_demo.png
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shadow_fill_sim import load_page, GROUND

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
CJK = r"C:/Windows/Fonts/msyh.ttc"
SIZE = 300
# 截图那种地面亮度（黄昏实测 ~45）
GROUND_L = 45.0


def font(sz):
    try:
        return ImageFont.truetype(CJK, sz)
    except Exception:
        return ImageFont.load_default()


def flat_mask(A):
    """与 bcas_shadow.ps 一致：低阈值扁平 + 四向封洞（R=20）"""
    m = np.clip((A - 0.006) / (0.035 - 0.006), 0.0, 1.0)
    m = m * m * (3 - 2 * m)
    paint = A >= 0.02
    seal = np.ones_like(A, dtype=bool)
    for dy, dx in ((-20, 0), (20, 0), (0, -20), (0, 20)):
        seal &= np.roll(np.roll(paint, dy, 0), dx, 1)
    return np.maximum(m, seal.astype(np.float32))


def main():
    name, img = load_page(os.path.join(DST_ANIM, "evergreen_new.zip"), 0)
    A = np.asarray(img.getchannel('A'), dtype=np.float32) / 255.0
    crop = A[1681:1681 + SIZE, 588:588 + SIZE]          # 一片树冠
    mask = flat_mask(crop)

    # 三层互相错开 60px（模仿截图里几棵树影叠在一起）
    lay = np.zeros((SIZE, SIZE), dtype=np.float32)
    layers = [np.zeros_like(mask) for _ in range(3)]
    for i, (dy, dx) in enumerate(((40, 20), (140, 90), (240, 170))):
        m = np.zeros_like(mask)
        h = min(SIZE - dy, SIZE)
        w = min(SIZE - dx, SIZE)
        m[dy:dy + h, dx:dx + w] = mask[:h, :w]
        layers[i] = m
        lay += m                                    # 1 层 / 2 层 / 3 层

    base = np.asarray(GROUND, dtype=np.float32) * (GROUND_L / np.mean(GROUND))
    panels = []
    for alpha in (0.55, 0.96):
        # 标准 alpha 叠加：dst *= (1-a) 每层一次
        shade = np.ones((SIZE, SIZE), dtype=np.float32)
        for m in layers:
            shade = shade * (1.0 - alpha * m)
        out = (base[None, None, :] * shade[..., None]).astype(np.uint8)
        panels.append((alpha, out, shade))

    sheet = Image.new('RGB', (SIZE * 2 + 36, SIZE + 78), (246, 246, 246))
    d = ImageDraw.Draw(sheet)
    f, fs = font(20), font(15)
    for i, (alpha, out, shade) in enumerate(panels):
        x = 12 + i * (SIZE + 12)
        vals = [float(base.mean()) * (1 - alpha) ** n for n in (1, 2, 3)]
        d.text((x, 8), f"影子浓度 {alpha:.2f}" + ("（旧）" if alpha < 0.9 else "（新）"),
               fill=(20, 20, 20), font=f)
        d.text((x, 32), f"1层 {vals[0]:5.1f} / 2层 {vals[1]:5.1f} / 3层 {vals[2]:5.1f}"
                        f"   最大层间差 {vals[0]-vals[1]:4.1f}",
               fill=(90, 90, 90), font=fs)
        sheet.paste(Image.fromarray(out), (x, 56))
    out = 'work/_shadow_layers_demo.png'
    sheet.save(out)
    print('->', out, sheet.size)


if __name__ == '__main__':
    main()
