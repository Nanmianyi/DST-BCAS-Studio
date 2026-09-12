"""离线验收"剪影填充"映射（对着真实图集，就是着色器里的公式）。

着色器（bcas_shadow.ps）：
    fill   = clamp(a * 4)                          比例填充（永不硬切）
    nb     = max(四个 ±3texel 对角邻居的 a)          极小半径闭运算探针
    inside = smoothstep(0.45, 0.75, max(a, nb))     内部 → 实心
    m      = max(fill, inside)，alpha = m * 影子浓度 0.55

并排渲染：OLD（原版，能看到接缝/排线）/ CUT（旧的硬阈值，会啃）/ FILL（只比例
填充）/ FINAL（比例填充 + 闭运算）；另加一张 1/4 缩略（模拟影子缩小绘制的 mip
采样）。用来确认：1) 接缝/排线消失；2) 外轮廓没被啃成二值；3) 没有矩形色带
（探针半径过大会把图集打包布局盖进影子）。

用法: python tools/shadow_final_sim.py <zip> <x> <y> [size] [page]
输出: work/_finalsim_<build>_<x>_<y>.png
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter
from shadow_fill_sim import load_page, GROUND, MULT_A

PROBE = 3          # texel
GAIN = 4.0


def closing_max(alpha, r):
    """四向（上下左右 ±r texel）取最小（与着色器的四 tap 一致）：
    四边都实心才算"内部"，因此不会跨图集精灵边界搭桥。"""
    w, h = alpha.size
    src = alpha.load()
    out = Image.new('L', (w, h))
    dst = out.load()
    offs = ((r, 0), (-r, 0), (0, r), (0, -r))
    for y in range(h):
        for x in range(w):
            worst = 255
            for dx, dy in offs:
                xx = min(w - 1, max(0, x + dx))
                yy = min(h - 1, max(0, y + dy))
                v = src[xx, yy]
                if v < worst:
                    worst = v
            dst[x, y] = worst
    return out


def smoothstep(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def compose(alpha, nb, mapping):
    w, h = alpha.size
    out = Image.new('RGB', (w, h), GROUND)
    ap, bp, op = alpha.load(), nb.load(), out.load()
    for y in range(h):
        for x in range(w):
            m = mapping(ap[x, y] / 255.0, bp[x, y] / 255.0) * MULT_A
            op[x, y] = (int(GROUND[0] * (1 - m)), int(GROUND[1] * (1 - m)),
                        int(GROUND[2] * (1 - m)))
    return out


def maps():
    def fill(a, nb):
        return min(1.0, a * GAIN)

    def final(a, nb):
        return max(min(1.0, a * GAIN), smoothstep(0.50, 0.80, nb))

    return [
        ('OLD 原版', lambda a, nb: a),
        ('CUT 硬阈值', lambda a, nb: 1.0 if a > 0.02 else 0.0),
        ('FILL 只比例填充', fill),
        ('FINAL 填充+闭运算', final),
    ]


def main():
    path = sys.argv[1]
    x, y = int(sys.argv[2]), int(sys.argv[3])
    size = int(sys.argv[4]) if len(sys.argv) > 4 else 320
    page = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    zoom = 2
    name, img = load_page(path, page)
    alpha = img.getchannel('A').crop((x, y, x + size, y + size))
    blurred = alpha.filter(ImageFilter.GaussianBlur(1.0))

    cells = []
    for tag, src in (('原始', alpha), ('缩略模糊', blurred)):
        nb = closing_max(src, PROBE)
        for mtag, fn in maps():
            cells.append((f'{tag} {mtag}', compose(src, nb, fn)))

    w, h = alpha.size
    rows = (len(cells) + 1) // 2
    sheet = Image.new('RGB', (w * zoom * 2, (h * zoom + 18) * rows), (250, 250, 250))
    d = ImageDraw.Draw(sheet)
    for i, (tag, im) in enumerate(cells):
        col, row = i % 2, i // 2
        d.text((col * w * zoom + 6, row * (h * zoom + 18) + 2), tag, fill=(10, 10, 10))
        sheet.paste(im.resize((w * zoom, h * zoom), Image.NEAREST),
                    (col * w * zoom, row * (h * zoom + 18) + 16))
    base = os.path.splitext(os.path.basename(path))[0]
    out = f'work/_finalsim_{base}_{x}_{y}.png'
    sheet.save(out)
    print('->', out)


if __name__ == '__main__':
    main()
