"""离线预览影子剪影：把"旧渲染 vs 新着色器"画在草地底色上，肉眼验收。

影子夹具（假实体）的渲染 = 美术贴图 × MultColour：
    旧： rgb = 美术rgb × mult_rgb,  a = 美术alpha × mult_a
    新： rgb = mix(黑, 月蓝, moon),  a = 阈值(美术alpha, 0.02) × mult_a
（mult 来自 bcas_sun_emitter.lua 的 GetSunParams：白天 (0,0,0,0.55)，
  满月夜 (0.10,0.15,0.30,0.40)。）

所以"旧的内部结构"= 美术的墨线/眼纹 RGB 在夜里被月蓝乘出来；白天两者
几乎一样，差别只在被阈值抹平的淡像素。这个脚本把两种结果并排画出来，
并标出阈值砍掉的像素，用来验证：
  1) 新剪影是实心无洞（被砍的都是 1px 抗锯齿边）；
  2) 内部结构（眼睛纹样/衣纹/描边）确实消失；
  3) 填色跟着影子浓度走（白天/夜晚两档）。

用法: python tools/shadow_preview.py [zip...]
输出: work/_shadowpreview_<build>.png
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw
from ktex_preview import load_source

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
DEFAULT_BUILDS = ["wilson.zip", "evergreen_new.zip", "twiggy_build.zip"]
CUT = 0.02
SOFT = 0.015
GROUND = (96, 122, 62)          # 草地底色
DAY = (0.55, (0.0, 0.0, 0.0))
MOON = (0.40, (0.10, 0.15, 0.30))


def over(dst, rgb, a):
    return tuple(int(round(dst[i] * (1.0 - a) + rgb[i] * a)) for i in range(3))


def render(img, mult_a, mult_rgb, use_mask):
    """返回影子的 RGBA 合成块（透明=无像素，交调用方贴到草地上）。"""
    w, h = img.size
    px = img.load()
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    op = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if use_mask:
                m = min(1.0, max(0.0, (a / 255.0 - (CUT - SOFT)) / (2 * SOFT)))
                alpha = m * mult_a
                col = mult_rgb
            else:
                alpha = (a / 255.0) * mult_a
                col = ((r / 255.0) * mult_rgb[0], (g / 255.0) * mult_rgb[1],
                       (b / 255.0) * mult_rgb[2])
            op[x, y] = (int(col[0] * 255), int(col[1] * 255), int(col[2] * 255),
                        int(alpha * 255))
    return out


def sheet(path, out_dir='work'):
    name, img, comp = load_source(path)
    base = os.path.splitext(os.path.basename(path))[0]
    w, h = img.size
    scale = min(1.0, 1000.0 / max(w, 1))
    dw, dh = max(1, int(w * scale)), max(1, int(h * scale))

    ground = Image.new('RGB', (w, h), GROUND)

    panels = []
    for tag, (ma, rgb) in (('day', DAY), ('moon', MOON)):
        old = ground.copy()
        old.paste(render(img, ma, rgb, False), (0, 0), render(img, ma, rgb, False))
        new = ground.copy()
        new.paste(render(img, ma, rgb, True), (0, 0), render(img, ma, rgb, True))
        panels.append((f'OLD {tag}', old))
        panels.append((f'NEW {tag}', new))

    # 被阈值砍掉的像素（红）：应当只剩 1px 抗锯齿边
    cut = ground.copy()
    cp = cut.load()
    ad = img.getchannel('A').load()
    n_cut = n_paint = 0
    for y in range(h):
        for x in range(w):
            a = ad[x, y]
            if a > 0:
                n_paint += 1
                if a <= int(CUT * 255):
                    n_cut += 1
                    cp[x, y] = (215, 40, 40)
    panels.append((f'cut {n_cut}/{n_paint}', cut))

    cols = 2
    rows = (len(panels) + cols - 1) // cols
    sheet_img = Image.new('RGB', (dw * cols, dh * rows + 22 * rows), (250, 250, 250))
    d = ImageDraw.Draw(sheet_img)
    for i, (tag, p) in enumerate(panels):
        cx, cy = (i % cols) * dw, (i // cols) * (dh + 22)
        d.text((cx + 6, cy + 6), tag, fill=(20, 20, 20))
        sheet_img.paste(p.resize((dw, dh), Image.NEAREST), (cx, cy + 22))
    out = os.path.join(out_dir, f'_shadowpreview_{base}.png')
    sheet_img.save(out)
    print(f'{base}: painted={n_paint} cut={n_cut} ({n_cut * 100.0 / max(n_paint,1):.3f}%) -> {out}')
    return out


if __name__ == '__main__':
    args = sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT_BUILDS]
    for a in args:
        if os.path.exists(a):
            sheet(a)
        else:
            print('missing', a)
