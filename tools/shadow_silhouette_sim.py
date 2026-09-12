"""影子剪影映射的离线仿真（复现 GPU 采样：mip 金字塔 + 点/线性过滤）。

背景：影子是把实体贴图按投影矩阵压扁后重画的副本，着色器能改的只有 alpha。
要验证的是"哪个 alpha 映射能在真实美术上得到实心、无洞、无外来内容的剪影"。

已确认的工艺事实：
  * DST 图集 .tex 带完整 mip 链（mip_count=12）；粗 mip 会把相邻精灵平均进来，
    "用粗 mip 当局部平均"会在影子内部画出别人的美术（矩形块/异物）。
  * 影子常被压扁到 0.5~1.0 倍 → 采样落在 mip 上；点采样 + 陡比例斜坡会把
    细笔画（叶脉/描边）打成点阵/虚线段。

用法:
    python tools/shadow_silhouette_sim.py <zip> <x> <y> <size> [scale]
输出: work/_sisim_<build>_<x>_<y>_s<scale>.png
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter
from shadow_fill_sim import load_page, GROUND, MULT_A

SHADOW_A = MULT_A   # 影子整体浓度（Lua 侧 FLOAT_PARAMS.x）


def smoothstep(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def mip_chain(alpha, levels=13):
    out = [alpha]
    cur = alpha
    for _ in range(levels):
        w, h = cur.size
        if w <= 1 and h <= 1:
            break
        cur = cur.resize((max(1, w // 2), max(1, h // 2)), Image.BOX)
        out.append(cur)
    return out


def sample(chain, lod, w, point):
    """按 mip 选择 + 过滤方式重采样到 w x w"""
    if point:
        L = max(0, min(len(chain) - 1, int(round(lod))))
        return chain[L].resize((w, w), Image.NEAREST), L
    L0 = max(0, min(len(chain) - 1, int(lod)))
    L1 = min(len(chain) - 1, L0 + 1)
    f = lod - L0
    a0 = chain[L0].resize((w, w), Image.BILINEAR)
    if f <= 0.001 or L1 == L0:
        return a0, L0
    a1 = chain[L1].resize((w, w), Image.BILINEAR)
    return Image.blend(a0, a1, f), L0


def composite(img_a, mask_fn):
    """mask_fn(a) -> 0..1 掩膜；合成到草地底色（影子只压暗）"""
    w, h = img_a.size
    out = Image.new('RGB', (w, h), GROUND)
    pa, po = img_a.load(), out.load()
    for y in range(h):
        for x in range(w):
            m = min(1.0, max(0.0, mask_fn(pa[x, y] / 255.0))) * SHADOW_A
            po[x, y] = (int(GROUND[0] * (1 - m)), int(GROUND[1] * (1 - m)),
                        int(GROUND[2] * (1 - m)))
    return out


def composite2(img_a, img_b, fn):
    w, h = img_a.size
    out = Image.new('RGB', (w, h), GROUND)
    pa, pb, po = img_a.load(), img_b.load(), out.load()
    for y in range(h):
        for x in range(w):
            m = min(1.0, max(0.0, fn(pa[x, y] / 255.0, pb[x, y] / 255.0))) * SHADOW_A
            po[x, y] = (int(GROUND[0] * (1 - m)), int(GROUND[1] * (1 - m)),
                        int(GROUND[2] * (1 - m)))
    return out


def probe_max(img, radius):
    """邻域最大 alpha：只取中心 + 上下左右各 R 像素（对齐着色器 5 tap）"""
    w, h = img.size
    src = img.load()
    out = Image.new('L', (w, h))
    dst = out.load()
    for y in range(h):
        for x in range(w):
            m = src[x, y]
            for dx, dy in ((radius, 0), (-radius, 0), (0, radius), (0, -radius)):
                xx = min(w - 1, max(0, x + dx))
                yy = min(h - 1, max(0, y + dy))
                if src[xx, yy] > m:
                    m = src[xx, yy]
            dst[x, y] = m
    return out


def ramp(a, k, eps=0.004):
    return min(1.0, max(0.0, (a - eps) * k))


def new_mask(a, nb, k=5.0):
    """候选实现（与 bcas_shadow.ps 逐字一致）：比例填充 + 窄邻域 max 探针"""
    fill = ramp(a, k)
    inside = smoothstep(0.55, 0.85, max(a, nb)) * (1.0 if a > 0.004 else 0.0)
    return max(fill, inside)


def main():
    path = sys.argv[1]
    x, y, size = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    scale = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
    zoom = 3

    name, img = load_page(path)
    alpha_full = img.getchannel('A').crop((x, y, x + size, y + size))
    chain = mip_chain(alpha_full)
    w = max(1, int(round(size * scale)))
    lod = max(0.0, -math.log2(scale)) if scale < 1 else 0.0

    A_pt, L = sample(chain, lod, w, point=True)
    A_ln, _ = sample(chain, lod, w, point=False)
    Lb = min(len(chain) - 1, L + 4)                       # 当前实现的 bias +4 粗 mip
    A_bias = chain[Lb].resize((w, w), Image.NEAREST)

    def cur(a, ab):
        return max(ramp(a, 5.0, 0.0), smoothstep(0.55, 0.85, max(a, ab)))

    nb_ln = probe_max(A_ln, 2)          # 新实现：±2 texel（放大档）
    nb_pt = probe_max(A_pt, 2)

    panels = [
        ('A 当前: 点采样 + bias4 粗mip探针',
         composite2(A_pt, A_bias, cur)),
        ('新公式 + 点采样 (对照)',
         composite2(A_pt, nb_pt, lambda a, nb: new_mask(a, nb))),
        ('新公式 + 线性采样 (定稿)',
         composite2(A_ln, nb_ln, lambda a, nb: new_mask(a, nb))),
        ('纯比例 K=5 线性 (无探针)',
         composite(A_ln, lambda a: ramp(a, 5.0))),
        ('新公式 R=1 探针 (对照)',
         composite2(A_ln, probe_max(A_ln, 1), lambda a, nb: new_mask(a, nb))),
        ('原始 alpha（不填实）',
         composite(A_ln, lambda a: a)),
    ]

    lh = 16
    sheet = Image.new('RGB', (w * zoom * 2 + 12, (w * zoom + lh) * 3 + 8), (245, 245, 245))
    d = ImageDraw.Draw(sheet)
    for i, (tag, im) in enumerate(panels):
        col, row = i % 2, i // 2
        px, py = col * (w * zoom + 6) + 4, row * (w * zoom + lh) + 4
        d.text((px, py), f'{tag}  [mip L={L}]', fill=(10, 10, 10))
        sheet.paste(im.resize((w * zoom, w * zoom), Image.NEAREST), (px, py + lh))
    base = os.path.splitext(os.path.basename(path))[0]
    out = f'work/_sisim_{base}_{x}_{y}_s{scale}.png'
    sheet.save(out)
    print('->', out, f'(L={L}, out {w}x{w})')


if __name__ == '__main__':
    main()
