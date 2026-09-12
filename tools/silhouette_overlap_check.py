"""离线验证"硬 alpha 测试能消掉重叠加深线"（对着真实图集 + mip 采样）。

现象（用户截图）：影子内部有 1~2px 的深色细线 —— 部件美术的软边叠在另一个
部件的实心上，半透明混合叠加变深。上一版只把软边压成窄带（smoothstep），
它仍参与混合 → 线还在（离线实测：任何 alpha 映射的重叠加深量完全一样，见下）。
结论：低于阈值必须直接 discard，并且最终要靠"每像素只混合一层"根治。

这个脚本把真实精灵按影子的缩小比例（默认 0.5）采样，然后做两次合成：
  单层 = 精灵本身；双层 = 精灵 + 自身平移 2px（模拟相邻部件的软边压上来）。
两次之差的绝对值 = 重叠造成的"线"强度。硬阈值下软边被丢弃 → 差值应为 0。

用法: python tools/silhouette_overlap_check.py [zip] [x] [y] [size] [scale]
输出: work/_silcheck_<build>.png
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image
from shadow_fill_sim import load_page, GROUND, MULT_A
from shadow_silhouette_sim import mip_chain, sample


def stock(a):
    return a


def old_smooth(a):
    # 上一版：smoothstep(0.20, 0.36)
    t = min(1.0, max(0.0, (a - 0.20) / 0.16))
    return t * t * (3 - 2 * t)


def hard(a, cut=0.30):
    return 1.0 if a >= cut else 0.0


def composite(alpha_img, fn, shift=None):
    """每个片元的 alpha = 映射值 × 影子浓度（COLOUR_XFORM 在片元里就乘掉了），
    多层再按 1-(1-a1)(1-a2)... 叠加 —— 与引擎的 alpha 混合一致。"""
    w, h = alpha_img.size
    out = Image.new('RGB', (w, h), GROUND)
    pa, po = alpha_img.load(), out.load()
    for y in range(h):
        for x in range(w):
            m = fn(pa[x, y] / 255.0) * MULT_A
            if shift is not None:
                sx, sy = x - shift, y - shift
                if 0 <= sx < w and 0 <= sy < h:
                    m2 = fn(pa[sx, sy] / 255.0) * MULT_A
                    m = m + m2 - m * m
            po[x, y] = (int(GROUND[0] * (1 - m)), int(GROUND[1] * (1 - m)),
                        int(GROUND[2] * (1 - m)))
    return out


def diff(a, b):
    w, h = a.size
    out = Image.new('RGB', (w, h))
    pa, pb, po = a.load(), b.load(), out.load()
    for y in range(h):
        for x in range(w):
            d = max(abs(pa[x, y][i] - pb[x, y][i]) for i in range(3))
            d = min(255, d * 6)
            po[x, y] = (d, d, d)
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "wilson.zip"
    x = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    y = int(sys.argv[3]) if len(sys.argv) > 3 else 665
    size = int(sys.argv[4]) if len(sys.argv) > 4 else 320
    scale = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5

    if not os.path.isabs(path):
        path = os.path.join(r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim", path)
    name, img = load_page(path)
    alpha = img.getchannel('A').crop((x, y, x + size, y + size))
    chain = mip_chain(alpha)
    w = max(1, int(round(size * scale)))
    lod = max(0.0, -math.log2(scale)) if scale < 1 else 0.0
    A, _ = sample(chain, lod, w, point=False)

    panels = []
    for label, fn in (("STOCK 原版", stock),
                      ("SMOOTH 上一版", old_smooth),
                      ("HARD 本版 cut=0.30", hard)):
        single = composite(A, fn)
        double = composite(A, fn, shift=2)
        d = diff(single, double)
        dp = d.load()
        vals = [dp[x, y][0] / 6.0 for y in range(w) for x in range(w)]
        vals = [v for v in vals if v > 0.5]
        if vals:
            print(f"{label}: 重叠加深带 像素 {len(vals)}  平均 {sum(vals)/len(vals):6.1f}/255  最大 {max(vals):6.1f}/255")
        else:
            print(f"{label}: 重叠加深带 像素 0")
        panels.append((label, single, d))

    zoom = 2
    pad = 8
    pw = w * zoom
    sheet = Image.new('RGB', (pw * 3 + pad * 4, pw + 40), (12, 12, 12))
    for i, (label, single, d) in enumerate(panels):
        ox = pad + i * (pw + pad)
        top = single.resize((pw, pw), Image.NEAREST)
        bot = d.resize((pw, pw), Image.NEAREST)
        sheet.paste(top, (ox, 30))
        sheet.paste(bot, (ox, 30 + pw // 2))
    out = 'work/_silcheck_%s.png' % os.path.splitext(name)[0]
    sheet.save(out)
    print('saved', out, sheet.size)
    print('列1=STOCK 列2=SMOOTH(上一版) 列3=HARD(本版)；每列上半=单层影子，下半=双层-单层差值(×6)')


if __name__ == '__main__':
    main()
