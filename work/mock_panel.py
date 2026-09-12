# -*- coding: utf-8 -*-
"""按 bcas_screen.lua 的坐标/配色渲染面板效果图（不依赖游戏，供目视验收）。"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 2                                  # 超采样
SC = 1.6                                # 模拟 1920x1080 下的 UI 缩放
W, H = int(560 * SC * SS), int(760 * SC * SS)

C = {
    'canvas': (244, 239, 227), 'card': (242, 237, 224), 'white': (250, 248, 242),
    'muted': (227, 220, 203), 'espresso': (44, 29, 24), 'espresso_lt': (68, 48, 40),
    'text_muted': (90, 76, 60), 'text_light': (250, 246, 238),
    'olive': (110, 133, 55), 'olive_dk': (80, 98, 37), 'amber': (234, 168, 70),
    'amber_lt': (246, 200, 107), 'line': (200, 187, 162), 'line_lt': (221, 213, 193),
    'border': (190, 177, 152), 'grid': (189, 175, 149),
}

FONT = None
for f in [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\msyhbd.ttc', r'C:\Windows\Fonts\simhei.ttf']:
    if os.path.exists(f):
        FONT = f
        break


def font(sz):
    return ImageFont.truetype(FONT, int(sz * SC * SS))


def px(x, y):
    """widget 坐标 -> 画布像素（面板中心在画布中心，y 轴翻转）"""
    return int(W / 2 + x * SC * SS), int(H / 2 - y * SC * SS)


img = Image.new('RGB', (W, H), (108, 118, 74))       # 模拟草地底色
d = ImageDraw.Draw(img, 'RGBA')


def rr(cx, cy, w, h, r, fill=None, outline=None, width=1):
    x0, y0 = px(cx - w / 2, cy + h / 2)
    x1, y1 = px(cx + w / 2, cy - h / 2)
    d.rounded_rectangle([x0, y0, x1, y1], radius=int(r * SC * SS),
                        fill=fill, outline=outline, width=max(1, int(width * SC * SS)))


def label(cx, top, w, size, s, col, align='left'):
    f = font(size)
    x0, y0 = px(cx - w / 2, top)
    lines = s.split('\n')
    for i, line in enumerate(lines):
        yy = y0 + i * int(size * SC * SS * 1.35)
        if align == 'left':
            d.text((x0, yy), line, font=f, fill=col, anchor='la')
        elif align == 'right':
            d.text((px(cx + w / 2, top)[0], yy), line, font=f, fill=col, anchor='ra')
        else:
            d.text((px(cx, top)[0], yy), line, font=f, fill=col, anchor='ma')


PANEL_W, PANEL_H = 484, 686
ROW_W, ROW_H, ROW_STEP = 452, 36, 42
METER_W, METER_X, VAL_X, RST_X = 68, 94, 154, 206

# 投影 + 面板
rr(0, -9, PANEL_W, PANEL_H, 16, fill=(30, 20, 15))
rr(0, 0, PANEL_W, PANEL_H, 16, fill=C['canvas'], outline=C['espresso'], width=2)
# 点阵
for c in range(1, 8):
    for r in range(1, 11):
        x = -(PANEL_W - 8) / 2 + c * (PANEL_W - 8) / 8
        y = -(PANEL_H - 8) / 2 + r * (PANEL_H - 8) / 11
        d.rectangle([*px(x, y), px(x, y)[0] + int(2 * SC * SS), px(x, y)[1] + int(2 * SC * SS)],
                    fill=C['grid'])
# 页眉
rr(0, 305, PANEL_W - 18, 58, 14, fill=C['espresso'])
label(-PANEL_W / 2 + 22 + 130, 321, 260, 10, "● NANMIANYI LAB // OPTICAL PIPELINE", C['amber'])
label(-PANEL_W / 2 + 22 + 90, 303, 180, 19, "# BCAS STUDIO", C['text_light'])
label(65, 302, 130, 12, "// 楠楠画质实验室", C['muted'], 'right')
# RUN
rr(PANEL_W / 2 - 52, 305, 78, 28, 15, fill=C['olive'], outline=C['border'])
label(PANEL_W / 2 - 52, 313, 78, 13, "● RUN", C['text_light'], 'center')
# 预设
label(-PANEL_W / 2 + 16 + 26, 260, 52, 13, "校准", C['text_muted'])
for i, s in enumerate(["# 特调方案", "# 轻量画质", "# 电影胶片", "# 原版关闭"]):
    x = -PANEL_W / 2 + 70 + 44 + i * 94
    rr(x, 260, 88, 26, 13, fill=C['muted'])
    label(x, 266, 88, 12, s, C['espresso'], 'center')
# 虚线
y = 238
n = int(440 // 14)
x0 = -(n - 1) * 14 / 2
for i in range(n):
    rr(x0 + i * 14, y, 8, 1.5, 0, fill=C['line'])
# 页签
n = 8
cw = (484 - 32 - (n - 1) * 3) // n
tabs = ["01 锐化", "02 进阶", "03 色彩", "04 调色", "05 氛围", "06 辉光", "07 光影", "08 水面"]
for i, s in enumerate(tabs):
    x = -PANEL_W / 2 + 16 + cw / 2 + i * (cw + 3)
    act = (i == 0)
    rr(x, 220, cw, 28, 14, fill=C['espresso'] if act else C['muted'])
    label(x, 227, cw, 13, s, C['text_light'] if act else C['espresso'], 'center')
rr(0, 196, 440, 1.5, 0, fill=C['line'])

# 参数行
rows = [("锐化强度 STRENGTH", 0.55), ("逆卷积墨线收敛 DECONV", 0.40),
        ("图像降噪 DENOISE", 0.50), ("抗振铃 AURA", 0.35), ("暗部保护 DARK-PROT", 0.60)]
for i, (lab, norm) in enumerate(rows):
    ry = 164 - i * ROW_STEP
    rr(0, ry, ROW_W, ROW_H, 10, fill=C['card'], outline=C['line'])
    rr(-ROW_W / 2 + 7, ry, 5, 18, 3, fill=C['olive'])
    label(-ROW_W / 2 + 16 + 98, ry + 7, 196, 15, lab, C['espresso'])
    rr(METER_X, ry, METER_W, 8, 4, fill=C['line_lt'])
    rr(METER_X - METER_W / 2 + METER_W * norm / 2, ry, max(6, METER_W * norm), 8, 4, fill=C['olive'])
    rr(METER_X - METER_W / 2 + METER_W * norm, ry, 14, 14, 7, fill=C['amber'],
       outline=(120, 90, 40))
    rr(VAL_X, ry, 56, 24, 9, fill=C['white'], outline=C['border'])
    label(VAL_X, ry + 5, 56, 14, "%.2f" % (norm * 2), C['espresso'], 'center')
    rr(RST_X, ry, 26, 26, 13, fill=C['muted'])
    label(RST_X, ry + 6, 26, 12, "R", C['espresso'], 'center')

# 说明卡
ny = 164 - 5 * ROW_STEP - 18
rr(0, ny, ROW_W, 54, 12, fill=C['white'], outline=C['line'])
rr(-ROW_W / 2 + 7, ny, 5, 40, 3, fill=C['olive'])
label(-ROW_W / 2 + 14 + 214, ny + 18, 428, 13,
      "双边自适应锐化：仅作用于游戏世界，HUD 界面不受影响。\n抗振铃 (AURA) 可消除白边与过冲伪影。",
      C['text_muted'])

rr(0, -256, 440, 1.5, 0, fill=C['line'])
rr(-82, -286, 184, 36, 18, fill=C['espresso'])
label(-82, -280, 184, 14, "# 保存并写入配置", C['text_light'], 'center')
rr(92, -286, 120, 36, 18, fill=C['muted'])
label(92, -280, 120, 14, "// 放弃更改", C['espresso'], 'center')
label(0, -324, PANEL_W - 32, 12, "拖动微调 · 单击键入 · R 复位 · ESC 退出 · P 快捷开关",
      C['text_muted'], 'center')

out = os.path.join(ROOT, 'work', 'bcas_ui_mock.png')
img.save(out)
print(out, img.size)
