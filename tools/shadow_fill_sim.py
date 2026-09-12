"""离线复现/验收影子"填充"映射：为什么阈值法会啃掉影子，哪种映射才对。

用户实测反馈（截图）：二值阈值把影子啃得"少一块两块"、像二值图。
原因：剪影只能改 alpha，而
  * 美术本身是软的（笔触/叶簇/羽毛边缘都是半透明），
  * 影子又常被缩小绘制 → 采样落在 mip 上 → alpha 被平均得更淡，
硬阈值(>0.02 保留, 否则 0)在这些淡区直接判死 → 缺块；淡区边界又变硬 → 锯齿二值感。

本脚本对真实图集做三种映射并排对比（都按影子实拍的 0.55 浓度合成到草地）：
  OLD   : a * 0.55                      （引擎原始：保留全部软结构）
  CUT   : (a>0.02 ? 1 : 0) * 0.55       （当前着色器：填实，但会啃掉淡区）
  FILLxN: clamp((a-eps)*N) * 0.55       （候选：比例填充，永不清零）
并额外给一张 1/4 缩略（模拟 mip 采样后的淡 alpha）下的同样对比 —— 用户截图
里被啃掉的就是这一档。红=相对 OLD 被清零的像素（"少一块两块"的来源）。

用法: python tools/shadow_fill_sim.py [zip ...]
输出: work/_fillsim_<build>_<page>.png
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw
from ktex_preview import read_ktex, decode_dxt5

DST_ANIM = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/data/anim"
DEFAULT = ["wilson.zip", "evergreen_new.zip", "tree_leaf_orange_build.zip"]
GROUND = (96, 122, 62)
MULT_A = 0.55


def load_page(path, page=0):
    import zipfile
    with zipfile.ZipFile(path) as z:
        tex = sorted(n for n in z.namelist() if n.endswith('.tex'))
        if page >= len(tex):
            return None, None
        data = z.read(tex[page])
        name = os.path.basename(path) + ':' + tex[page]
    comp, metas, blobs = read_ktex(data)
    w, h, pitch, sz = metas[0]
    if comp != 2:
        return name, None
    return name, decode_dxt5(blobs[0], w, h)


def compose(alpha_img, mapping, mult_a=MULT_A):
    """把 alpha 映射结果合成到草地底色上，返回 RGB 图"""
    w, h = alpha_img.size
    a = alpha_img.load()
    out = Image.new('RGB', (w, h), GROUND)
    o = out.load()
    for y in range(h):
        for x in range(w):
            av = a[x, y] / 255.0
            m = mapping(av)
            al = m * mult_a
            o[x, y] = (int(GROUND[0] * (1 - al)), int(GROUND[1] * (1 - al)),
                       int(GROUND[2] * (1 - al)))
    return out


def cut_map(av):
    return 1.0 if av > 0.02 else 0.0


def fill_map(k):
    def f(av):
        return min(1.0, max(0.0, (av - 0.004) * k))
    return f


def old_map(av):
    return av


def panel_row(alpha_img, zoom, labels_out):
    """一行四格：OLD / CUT0.02 / FILL6 / FILL12（+ 被清零像素标红）"""
    cells = []
    for tag, fn in (('OLD', old_map), ('CUT .02', cut_map),
                    ('FILL x6', fill_map(6)), ('FILL x12', fill_map(12))):
        img = compose(alpha_img, fn)
        cells.append((tag, img))
    # 红标：OLD 有、CUT 没有（= 被啃掉的）
    w, h = alpha_img.size
    am = alpha_img.load()
    red = Image.new('L', (w, h), 0)
    rd = red.load()
    n_hole = 0
    for y in range(h):
        for x in range(w):
            if am[x, y] > 0 and cut_map(am[x, y] / 255.0) == 0.0:
                rd[x, y] = 255
                n_hole += 1
    marked = compose(alpha_img, old_map)
    marked.paste((220, 40, 40), mask=red)
    cells.append((f'HOLES {n_hole}', marked))
    labels_out.append(n_hole)
    return cells


def sheet(path, page=0, out_dir='work'):
    name, img = load_page(path, page)
    if img is None:
        print('skip', name)
        return None
    base = os.path.splitext(os.path.basename(path))[0]
    w, h = img.size
    scale = min(1.0, 900.0 / max(w, 1))
    dw, dh = max(1, int(w * scale)), max(1, int(h * scale))

    alpha = img.getchannel('A')
    mini = alpha.resize((max(1, w // 4), max(1, h // 4)), Image.LANCZOS)

    rows = []
    holes = []
    rows.append(('1x (原始分辨率)', panel_row(alpha, 1, holes)))
    rows.append(('1/4 (mip 采样后)', panel_row(mini, 1, holes)))

    cols = max(len(r[1]) for r in rows)
    sheet_w = dw * cols
    sheet_h = sum(dh + 20 for _ in rows)
    sheet_img = Image.new('RGB', (sheet_w, sheet_h), (250, 250, 250))
    d = ImageDraw.Draw(sheet_img)
    y = 0
    for title, cells in rows:
        d.text((6, y + 4), title, fill=(10, 10, 10))
        y += 20
        pw, ph = cells[0][1].size
        sc = min(1.0, 900.0 / max(pw, 1))
        for i, (tag, im) in enumerate(cells):
            d.text((i * dw + 6, y + 4), tag, fill=(10, 10, 10))
            sheet_img.paste(im.resize((dw, dh), Image.NEAREST), (i * dw, y + 18))
        y += dh + 18
    out = os.path.join(out_dir, f'_fillsim_{base}_p{page}.png')
    sheet_img.save(out)
    print(f'{base} page{page}: 1x 被啃 {holes[0]} px, 1/4 被啃 {holes[1]} px -> {out}')
    return out


if __name__ == '__main__':
    args = sys.argv[1:] or [os.path.join(DST_ANIM, b) for b in DEFAULT]
    for a in args:
        if os.path.exists(a):
            sheet(a)
        else:
            print('missing', a)
