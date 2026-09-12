"""把一张图集页面的"内部淡像素"可视化：判断它们到底是什么（描边/眼睛/衣纹）。

分类着色：
  实心 alpha>=0.9  -> 黑
  中间 .35-.9      -> 中灰
  淡 .02-.35 且 17x17 邻域内有实心（= 被包住的内部细节） -> 红
  淡 .02-.35 且 邻域内没有实心（= 外缘软边）            -> 黄

用法: python tools/shadow_faint_map.py <zip> <x> <y> <size> [zoom]
输出: work/_faint_<build>_<x>_<y>.png（左=alpha 分级，右=原始美术）
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shadow_fill_sim import load_page


def main():
    path = sys.argv[1]
    x, y, size = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    zoom = int(sys.argv[5]) if len(sys.argv) > 5 else 2

    name, img = load_page(path)
    img = img.crop((x, y, x + size, y + size))
    A = np.asarray(img.getchannel('A'), dtype=np.float32) / 255.0

    from scipy import ndimage
    near = ndimage.maximum_filter(A, size=17)

    out = np.zeros(A.shape + (3,), dtype=np.uint8)
    out[:] = (255, 255, 255)                                   # 背景
    out[A >= 0.9] = (0, 0, 0)                                  # 实心
    mid = (A >= 0.35) & (A < 0.9)
    out[mid] = (140, 140, 140)                                 # 中间
    faint = (A > 0.02) & (A < 0.35)
    out[faint & (near >= 0.9)] = (230, 30, 30)                 # 内部细节
    out[faint & (near < 0.9)] = (250, 210, 40)                 # 外缘软边

    rgbsrc = np.asarray(img.convert('RGB'))
    panel = np.concatenate([out, rgbsrc], axis=1)
    pim = Image.fromarray(panel).resize(
        (panel.shape[1] * zoom, panel.shape[0] * zoom), Image.NEAREST)
    base = os.path.splitext(os.path.basename(path))[0]
    outp = f'work/_faint_{base}_{x}_{y}.png'
    pim.save(outp)

    tot = max(1, int((A > 0).sum()))
    print(f'{outp}: 实心 {(A>=0.9).sum()*100.0/tot:.1f}%  中间 {mid.sum()*100.0/tot:.1f}%  '
          f'内部细节(红) {(faint & (near>=0.9)).sum()*100.0/tot:.1f}%  '
          f'外缘软边(黄) {(faint & (near<0.9)).sum()*100.0/tot:.1f}%  '
          f'(红/黄={int((faint & (near>=0.9)).sum())}/{int((faint & (near<0.9)).sum())} px)')


if __name__ == '__main__':
    main()
