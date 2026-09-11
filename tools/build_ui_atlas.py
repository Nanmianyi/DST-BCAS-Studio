# -*- coding: utf-8 -*-
"""BCAS Studio UI 图集生成器：圆角矩形 / 胶囊 / 圆形 → DST KTEX(DXT5, 真 alpha)。

输出（资产，直接进 mod）：
  BCAS-Studio/images/bcas_ui.tex
  BCAS-Studio/images/bcas_ui.xml
  work/bcas_ui_preview.png   （供目视校验）

KTEX 布局（与 tools/make_modicon.py 的逆向结论一致）：
  [8 字节头][全部 mip 元数据 依次][全部 mip 数据 依次]

===== 为什么是 2x 密度 + alpha 外扩（2026-09 实战定版） =====
实测玩家窗口 2057x1157，DST 面板走 SCALEMODE_PROPORTIONAL，
缩放 = min(w/1280, h/720) ≈ 1.6x。也就是说 1:1 出图的纹理在屏幕上被
**放大 1.6 倍**，任何硬边/圆角都会被拉毛。故：
  * TB = 2：图集按"每个 UI 单位 2 个纹素"出图（2048x2048），引擎在 1.6x
    屏幕上做 0.8x 缩小采样 —— 有富余分辨率，边缘才锐。
  * SS = 2：绘制时再 2x 超采样后缩回，圆角得到约 1 纹素宽的顺滑抗锯齿
    （密度足够高，DXT5 量化不再产生肉眼可见的碎点）。
  * alpha 外扩：把不透明像素的 RGB 往透明区渗透若干圈（alpha 仍为 0）。
    DXT5 颜色与 alpha 分离存储，若透明区是纯黑，放大时双线性会把黑混进
    边缘形成"黑边/白边"；外扩后颜色连续，边缘干净。
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'BCAS-Studio', 'images')
OUT_TEX = os.path.join(OUT_DIR, 'bcas_ui.tex')
OUT_XML = os.path.join(OUT_DIR, 'bcas_ui.xml')
OUT_PREVIEW = os.path.join(ROOT, 'work', 'bcas_ui_preview.png')

WU, HU = 1024, 1024          # 图集布局尺寸（UI 单位）
TB = 2                       # 每 UI 单位纹素数（作者密度）
SS = 2                       # 绘制超采样倍率
W, H = WU * TB, HU * TB      # 纹理尺寸 2048x2048
K = TB * SS                  # 绘制坐标倍率

PLATFORM, COMPRESSION, TEXTURE_2D, FLAGS, FILL = 0, 2, 1, 3, 4095


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def dec565(v):
    r = ((v >> 11) & 0x1F) << 3 | ((v >> 11) & 0x1F) >> 2
    g = ((v >> 5) & 0x3F) << 2 | ((v >> 5) & 0x3F) >> 4
    b = (v & 0x1F) << 3 | (v & 0x1F) >> 2
    return (r, g, b)


def encode_alpha_block(alphas):
    a0 = max(alphas)
    a1 = min(alphas)
    if a0 == a1:
        return bytes([a0, a1, 0, 0, 0, 0, 0, 0])
    levels = [a0, a1] + [int(round(((7 - i) * a0 + i * a1) / 7.0)) for i in range(1, 7)]
    idx = 0
    for n, av in enumerate(alphas):
        best_i, best_e = 0, None
        for i, lv in enumerate(levels):
            e = (av - lv) ** 2
            if best_e is None or e < best_e:
                best_e, best_i = e, i
        idx |= best_i << (3 * n)
    return bytes([a0, a1]) + idx.to_bytes(6, 'little')


def encode_color_block(px):
    lum = [0.299 * r + 0.587 * g + 0.114 * b for r, g, b in px]
    imax = max(range(16), key=lambda i: lum[i])
    imin = min(range(16), key=lambda i: lum[i])
    c0, c1 = rgb565(*px[imax]), rgb565(*px[imin])
    if c0 == c1:
        c0, c1 = min(65535, c0 + 1), c1
    if c0 < c1:
        c0, c1 = c1, c0
    p0, p1 = dec565(c0), dec565(c1)
    pal = [p0, p1,
           tuple((2 * p0[k] + p1[k]) // 3 for k in range(3)),
           tuple((p0[k] + 2 * p1[k]) // 3 for k in range(3))]
    idxs = 0
    for n, c in enumerate(px):
        best_e, best_i = None, 0
        for m, pc in enumerate(pal):
            e = sum((c[k] - pc[k]) ** 2 for k in range(3))
            if best_e is None or e < best_e:
                best_e, best_i = e, m
        idxs |= best_i << (2 * n)
    return struct.pack('<HHI', c0, c1, idxs)


def encode_mip(img):
    w, h = img.size
    rgba = list(img.convert('RGBA').getdata())
    out = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            px = []
            for y in range(by, min(by + 4, h)):
                for x in range(bx, min(bx + 4, w)):
                    px.append(rgba[y * w + x])
            while len(px) < 16:
                px.append(px[-1])
            out += encode_alpha_block([p[3] for p in px])
            out += encode_color_block([(p[0], p[1], p[2]) for p in px])
    return bytes(out)


def premultiply(img):
    """straight-alpha RGBA -> premultiplied RGB（整数运算，省内存）。"""
    import numpy as np
    arr = np.array(img.convert('RGBA')).astype(np.uint16)
    a = arr[..., 3]
    rgb = arr[..., :3] * a[..., None] // 255
    return Image.fromarray(np.dstack([rgb, a]).astype(np.uint8), 'RGBA')


def unpremultiply(img):
    """premultiplied RGBA -> straight-alpha；alpha=0 处 RGB 归 0（随后 alpha 外扩补色）。"""
    import numpy as np
    arr = np.array(img.convert('RGBA')).astype(np.uint16)
    a = arr[..., 3]
    num = arr[..., :3] * 255
    den = np.maximum(a[..., None], 1)
    rgb = np.where(a[..., None] > 0, num // den, 0)
    return Image.fromarray(np.dstack([np.clip(rgb, 0, 255), a]).astype(np.uint8), 'RGBA')




def rgba(r, g, b, a=255):
    return (int(r), int(g), int(b), int(a))


ELEMENTS = []          # (name, x, y, w, h) —— 纹素坐标


def main():
    img = Image.new('RGBA', (WU * K, HU * K), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    PARCH = rgba(244, 239, 227)
    CARD = rgba(242, 237, 224)
    LINE = rgba(200, 187, 162)
    WHITE = rgba(255, 255, 255, 255)

    def add(name, x, y, w, h):
        # 记录到纹素坐标（供 XML 用）
        ELEMENTS.append((name, x * TB, y * TB, w * TB, h * TB))

    def rr(name, x, y, w, h, radius, fill, outline=None, width=1):
        add(name, x, y, w, h)
        d.rounded_rectangle([x * K, y * K, (x + w) * K - 1, (y + h) * K - 1],
                            radius=radius * K, fill=fill, outline=outline,
                            width=max(1, round(width * K)))

    def circ(name, x, y, w, h, fill, outline=None, width=1):
        add(name, x, y, w, h)
        d.ellipse([x * K, y * K, (x + w) * K - 1, (y + h) * K - 1],
                  fill=fill, outline=outline, width=max(1, round(width * K)))

    def pill(h, x, y):
        """两片端帽：直径 h 的圆取左半/右半，各自 1:1(作者密度) 出图。"""
        cap = h // 2
        add('p%dl' % h, x, y, cap, h)
        add('p%dr' % h, x + cap + 2, y, cap, h)
        circ_img = Image.new('RGBA', (h * K, h * K), (0, 0, 0, 0))
        ImageDraw.Draw(circ_img).ellipse([0, 0, h * K - 1, h * K - 1], fill=WHITE)
        img.alpha_composite(circ_img.crop((0, 0, cap * K, h * K)), (x * K, y * K))
        img.alpha_composite(circ_img.crop(((h - cap) * K, 0, h * K, h * K)),
                            ((x + cap + 2) * K, y * K))

    # ---- 左列：整块面板与卡片（布局单位与旧版一致，仅密度 x2） ----
    rr('panel', 4, 4, 484, 686, 16, PARCH)
    rr('header', 4, 696, 466, 58, 14, WHITE)
    rr('card', 4, 760, 452, 36, 10, CARD, LINE, 1.5)
    rr('note42', 4, 802, 452, 42, 10, rgba(250, 248, 242, 232), LINE, 1.5)
    rr('note52', 4, 850, 452, 52, 11, rgba(250, 248, 242, 232), LINE, 1.5)
    rr('note76', 4, 908, 452, 76, 12, rgba(250, 248, 242, 232), LINE, 1.5)

    # ---- 右列：小控件 ----
    X0 = 500
    rr('box', X0, 8, 56, 24, 8, WHITE, rgba(190, 177, 152), 1.5)
    rr('swatch', X0 + 64, 8, 30, 30, 8, WHITE, rgba(190, 177, 152), 1.5)
    circ('knob', X0 + 102, 8, 28, 28, WHITE, rgba(120, 90, 40), 2)
    circ('dot', X0 + 138, 8, 14, 14, WHITE)
    rr('sq', X0 + 170, 8, 4, 4, 0, WHITE)
    rr('track', X0, 52, 68, 8, 4, WHITE)
    rr('fill', X0, 68, 68, 8, 4, WHITE)

    def accent(name, x, y, h, r):
        add(name, x, y, 7, h)
        tmp = Image.new('RGBA', (452 * K, h * K), (0, 0, 0, 0))
        ImageDraw.Draw(tmp).rounded_rectangle([0, 0, 452 * K - 1, h * K - 1],
                                              radius=r * K, fill=WHITE)
        img.alpha_composite(tmp.crop((0, 0, 7 * K, h * K)), (x * K, y * K))

    accent('acc36', 600, 300, 36, 10)
    accent('acc42', 620, 300, 42, 10)
    accent('acc52', 640, 300, 52, 11)
    accent('acc76', 660, 300, 76, 12)

    pill(26, X0, 90)
    pill(28, X0, 126)
    pill(36, X0, 164)

    # ---- 预乘 alpha 缩回 ----
    # 直接缩回会把透明区(0,0,0)混进边缘像素 → 边缘发黑。
    # 先预乘、面积平均(BOX)缩回、再反预乘，边缘颜色才正确。
    # ⚠ 绝不做 RGB 外扩(alpha bleed)：DST 的 UI 混合近似预乘/相加，
    #   透明区一旦带非零 RGB，会被直接加到底色上 → 每个圆角外面浮出一圈
    #   白框（2026-09 实测踩坑）。透明像素必须保持 (0,0,0,0)。
    img = unpremultiply(premultiply(img).resize((W, H), Image.BOX))

    # ---- KTEX ----
    mips = [img]
    w, h = W, H
    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        mips.append(img.resize((w, h), Image.BILINEAR))
    mip_count = len(mips)

    v = (PLATFORM << 0) | (COMPRESSION << 4) | (TEXTURE_2D << 9) | (mip_count << 13) | (FLAGS << 18) | (FILL << 20)
    blob = bytearray(struct.pack('<II', 0x5845544B, v))
    metas, datas = [], []
    for m in mips:
        mw, mh = m.size
        data = encode_mip(m)
        pitch = max(16, (mw // 4) * 16)
        metas.append(struct.pack('<HHHI', mw, mh, pitch, len(data)))
        datas.append(data)
    blob += b''.join(metas) + b''.join(datas)
    os.makedirs(OUT_DIR, exist_ok=True)
    open(OUT_TEX, 'wb').write(blob)

    # ---- XML（纹素坐标） ----
    ins_u = 0.5 / W
    ins_v = 0.5 / H
    parts = ['<Atlas><Texture filename="bcas_ui.tex" /><Elements>']
    for name, x, y, w_, h_ in ELEMENTS:
        u1 = x / W + ins_u
        u2 = (x + w_) / W - ins_u
        v1 = y / H + ins_v
        v2 = (y + h_) / H - ins_v
        parts.append('<Element name="%s.tex" u1="%g" u2="%g" v1="%g" v2="%g" />'
                     % (name, u1, u2, v1, v2))
    parts.append('</Elements></Atlas>')
    open(OUT_XML, 'w', encoding='utf-8').write(''.join(parts))

    os.makedirs(os.path.dirname(OUT_PREVIEW), exist_ok=True)
    img.save(OUT_PREVIEW)
    flat = Image.new('RGBA', img.size, (60, 60, 60, 255))
    flat.alpha_composite(img)
    flat.convert('RGB').save(os.path.join(ROOT, 'work', 'bcas_ui_preview_flat.png'))

    print('tex:', OUT_TEX, len(blob), 'bytes, mips =', mip_count, 'size', (W, H))
    print('elements:', [e[0] for e in ELEMENTS])


if __name__ == '__main__':
    main()
