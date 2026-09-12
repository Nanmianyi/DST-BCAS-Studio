# -*- coding: utf-8 -*-
"""按引擎行为预览：从 bcas_ui.tex 图集裁元素，按 UI 缩放 1.6x 合成面板局部。"""
import os, re, struct
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = 1.6          # 实测 UI 缩放（窗口 2057x1157 -> min(w/1280,h/720) ~ 1.6）
Z = 2            # 再放大 2 倍便于肉眼检查
S = D * Z

d = open(os.path.join(ROOT, 'BCAS-Studio', 'images', 'bcas_ui.tex'), 'rb').read()
_, v = struct.unpack('<II', d[:8])
mip = (v >> 13) & 0x1F
off = 8; metas = []
for _ in range(mip):
    w, h, pitch, sz = struct.unpack_from('<HHHI', d, off); off += 10
    metas.append((w, h, pitch, sz))
W, H, _, sz0 = metas[0]; base = d[off:off + sz0]
BW = W // 4


def dec565(c):
    r = ((c >> 11) & 0x1F); r = (r << 3) | (r >> 2)
    g = ((c >> 5) & 0x3F); g = (g << 2) | (g >> 4)
    b = c & 0x1F; b = (b << 3) | (b >> 2)
    return (r, g, b)


_cache = {}


def block(bx, by):
    k = (bx, by)
    v_ = _cache.get(k)
    if v_ is not None:
        return v_
    o = (by * BW + bx) * 16
    a0, a1 = base[o], base[o + 1]
    bits = int.from_bytes(base[o + 2:o + 8], 'little')
    if a0 == 0 and a1 == 0 and bits == 0:
        _cache[k] = None
        return None
    if a0 > a1:
        al = [a0, a1] + [int(round(((7 - i) * a0 + i * a1) / 7.0)) for i in range(1, 7)]
    else:
        al = [a0, a1] + [int(round(((6 - i) * a0 + (i - 1) * a1) / 5.0)) for i in range(1, 7)]
    c0, c1, cb = struct.unpack_from('<HHI', base, o + 8)
    pal = [dec565(c0), dec565(c1),
           tuple((2 * p + q) // 3 for p, q in zip(dec565(c0), dec565(c1))),
           tuple((p + 2 * q) // 3 for p, q in zip(dec565(c0), dec565(c1)))]
    pix = []
    for n in range(16):
        pix.append(pal[(cb >> (2 * n)) & 3] + (al[(bits >> (3 * n)) & 7],))
    _cache[k] = pix
    return pix


def crop(x0, y0, x1, y1):
    x0, y0 = max(0, x0), max(0, y0); x1, y1 = min(W, x1), min(H, y1)
    im = Image.new('RGBA', (x1 - x0, y1 - y0), (0, 0, 0, 0)); p = im.load()
    for by in range(y0 // 4, (y1 + 3) // 4):
        for bx in range(x0 // 4, (x1 + 3) // 4):
            pix = block(bx, by)
            if pix is None:
                continue
            for j in range(4):
                for i in range(4):
                    gx, gy = bx * 4 + i, by * 4 + j
                    if x0 <= gx < x1 and y0 <= gy < y1:
                        p[gx - x0, gy - y0] = pix[j * 4 + i]
    return im


els = {}
for m in re.finditer(r'name="([a-z0-9_]+)\.tex" u1="([\d.]+)" u2="([\d.]+)" v1="([\d.]+)" v2="([\d.]+)"',
                     open(os.path.join(ROOT, 'BCAS-Studio', 'images', 'bcas_ui.xml')).read()):
    n, u1, u2, v1, v2 = m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5))
    els[n] = crop(round(u1 * W), round(v1 * H), round(u2 * W), round(v2 * H))

FONT = r'C:\Windows\Fonts\msyh.ttc'
def font(sz_): return ImageFont.truetype(FONT, max(6, int(sz_ * S)))

PANEL_W, PANEL_H = 484, 686
CW, CH = int((PANEL_W + 40) * S), int((PANEL_H + 40) * S)
canvas = Image.new('RGBA', (CW, CH), (108, 118, 74, 255))
dr = ImageDraw.Draw(canvas)


def put(name, cx, cy, w, h):
    im = els[name].resize((max(1, int(round(w * S))), max(1, int(round(h * S)))), Image.BILINEAR)
    canvas.alpha_composite(im, (int(round((cx - w / 2 + 20) * S)), int(round((PANEL_H / 2 - cy + 20) * S))))


def txt(cx, top, size, s, col, align='left'):
    f = font(size)
    y = int(round((PANEL_H / 2 - top + 20) * S))
    x = int(round((cx + 20) * S))
    dr.text((x, y), s, font=f, fill=col, anchor=('la' if align == 'left' else 'ma'))


def pill(l, r, cx, cy, w, h):
    cap = h // 2
    put(l, cx - (w / 2 - cap / 2), cy, cap, h)
    put(r, cx + (w / 2 - cap / 2), cy, cap, h)
    if w - cap * 2 > 0:
        put('sq', cx, cy, w - cap * 2, h)


# 面板 + 页眉
put('panel', PANEL_W / 2, 0, PANEL_W, PANEL_H)
put('header', PANEL_W / 2, 305, PANEL_W - 18, 58)
txt(22 + 110, 321, 10, "● NANMIANYI LAB // OPTICAL PIPELINE", (234, 168, 70))
txt(22 + 80, 303, 19, "# BCAS STUDIO", (250, 246, 238))
pill('p28l', 'p28r', PANEL_W / 2 - 52, 305, 78, 28)
txt(PANEL_W / 2 - 52, 313, 13, "● RUN", (250, 246, 238), 'center')

# 两行参数卡
for i, (lab, norm) in enumerate([("锐化强度 STRENGTH", 0.55), ("逆卷积墨线收敛 DECONV", 0.40)]):
    ry = 164 - i * 42
    put('card', PANEL_W / 2, ry, 452, 36)
    put('accent', PANEL_W / 2 - 452 / 2 + 7, ry, 5, 18)
    txt(PANEL_W / 2 - 452 / 2 + 16 + 98, ry + 7, 15, lab, (44, 29, 24))
    put('track', PANEL_W / 2 + 94, ry, 68, 8)
    put('fill', PANEL_W / 2 + 94 - 34 + 34 * norm, ry, max(6, 68 * norm), 8)
    put('knob', PANEL_W / 2 + 94 - 34 + 68 * norm, ry, 14, 14)
    put('box', PANEL_W / 2 + 154, ry, 56, 24)
    txt(PANEL_W / 2 + 154, ry + 5, 14, "%.2f" % (norm * 2), (44, 29, 24), 'center')
    pill('p26l', 'p26r', PANEL_W / 2 + 206, ry, 26, 26)
    txt(PANEL_W / 2 + 206, ry + 6, 12, "R", (44, 29, 24), 'center')

# 页签一排（全部胶囊，选中第一个用深色）
n = 8; cw = (484 - 32 - (n - 1) * 3) // n
for i, s in enumerate(["01 锐化", "02 进阶", "03 色彩", "04 调色", "05 氛围", "06 辉光", "07 光影", "08 水面"]):
    x = PANEL_W / 2 - PANEL_W / 2 + 16 + cw / 2 + i * (cw + 3)
    pill('p28l', 'p28r', x, 220, cw, 28)
    txt(x, 227, 13, s, (250, 246, 238) if i == 0 else (44, 29, 24), 'center')

out = os.path.join(ROOT, 'work', 'bcas_engine_preview.png')
canvas.convert('RGB').save(out)
print('saved', out, canvas.size)
