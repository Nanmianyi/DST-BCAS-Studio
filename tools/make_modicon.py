# -*- coding: utf-8 -*-
"""把 modicon_128.png 编码为 DST 引擎 KTEX（DXT5, 8 mip）并回验。

格式（与参考 modicon.tex 字节级互证，见 2026-09 逆向笔记）：
  头 8 字节: "KTEX" + 打包位域 u32
    platform(4)=0 DEFAULT | compression(5)=2 DXT5 | texture(4)=1 2D
    | mipmap_count(5)=8 | flags(2)=3 | fill(12)=4095
    打包值 = 0xFFFD0220（LE 字节 20 02 fd ff，与引擎自带一致）
  每个 mip: width u16, height u16, pitch u16(行块数*16), datasz u32, 后跟数据
  128x128 全链总长 = 8 + 8*10 + (16384+4096+1024+256+64+16+16+16) = 21960
"""
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'BCAS-Studio', 'modicon_128.png')
OUT_TEX = os.path.join(ROOT, 'BCAS-Studio', 'modicon.tex')
OUT_XML = os.path.join(ROOT, 'BCAS-Studio', 'modicon.xml')
OUT_VERIFY = os.path.join(ROOT, 'BCAS-Studio', 'modicon_verify.png')

PLATFORM, COMPRESSION, TEXTURE_2D, MIPS, FLAGS, FILL = 0, 2, 1, 8, 3, 4095


def pack_header():
    v = (PLATFORM << 0) | (COMPRESSION << 4) | (TEXTURE_2D << 9)         | (MIPS << 13) | (FLAGS << 18) | (FILL << 20)
    assert v == 0xFFFD0220, hex(v)
    return struct.pack('<II', 0x5845544B, v)  # 'KTEX'


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def dec565(v):
    r = ((v >> 11) & 0x1F) << 3 | ((v >> 11) & 0x1F) >> 2
    g = ((v >> 5) & 0x3F) << 2 | ((v >> 5) & 0x3F) >> 4
    b = (v & 0x1F) << 3 | (v & 0x1F) >> 2
    return (r, g, b)


def encode_block(px):
    """px: 16 个 (r,g,b)。DXT5 颜色部分：在 16 色里暴力挑最优 (c0,c1) 对。"""
    best = None
    for i in range(16):
        for j in range(16):
            c0, c1 = px[i], px[j]
            p0, p1 = dec565(rgb565(*c0)), dec565(rgb565(*c1))
            pal = [p0, p1,
                   tuple((2 * p0[k] + p1[k]) // 3 for k in range(3)),
                   tuple((p0[k] + 2 * p1[k]) // 3 for k in range(3))]
            err = 0
            idxs = 0
            for n, c in enumerate(px):
                best_e, best_i = None, 0
                for m, pc in enumerate(pal):
                    e = sum((c[k] - pc[k]) ** 2 for k in range(3))
                    if best_e is None or e < best_e:
                        best_e, best_i = e, m
                err += best_e
                idxs |= best_i << (2 * n)
            if best is None or err < best[0]:
                best = (err, i, j, idxs)
    _, i, j, idxs = best
    c0, c1 = rgb565(*px[i]), rgb565(*px[j])
    # 8 字节 alpha 头：全不透明 -> a0=a1=255，索引全 0
    return bytes([255, 255, 0, 0, 0, 0, 0, 0]) + struct.pack('<HHI', c0, c1, idxs)


def encode_mip(img):
    w, h = img.size
    rgba = list(img.convert('RGBA').getdata())
    out = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            px = []
            for y in range(by, min(by + 4, h)):
                for x in range(bx, min(bx + 4, w)):
                    r, g, b, a = rgba[y * w + x]
                    px.append((r, g, b))
            while len(px) < 16:
                px.append(px[-1])
            out += encode_block(px)
    return bytes(out)


def decode_mip(data, w, h):
    """回验用解码（alpha 略，全 255）。注意 DXT 数据按 4x4 块交错存储，
    解码必须按块坐标回填到逐行像素缓冲，不能直接 append（2026-09 实测
    教训：append 出来的块交错列表被当成逐行索引采样，全图错位）。"""
    out = [(0, 0, 0)] * (w * h)
    idx = 0
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            idx += 8  # 跳过 8 字节 alpha 段（全不透明）
            c0, c1, bits = struct.unpack_from('<HHI', data, idx)
            idx += 8
            pal = [dec565(c0), dec565(c1),
                   tuple((2 * p + q) // 3 for p, q in zip(dec565(c0), dec565(c1))),
                   tuple((p + 2 * q) // 3 for p, q in zip(dec565(c0), dec565(c1)))]
            for n in range(16):
                x = bx + (n % 4)
                y = by + (n // 4)
                if x < w and y < h:
                    out[y * w + x] = pal[(bits >> (2 * n)) & 3]
    return out


def bayer_dither(img, strength=14):
    """4x4 Bayer 有序抖动：DXT5 压径向渐变会出条带，抖动把条带化开成
    细噪点，小尺寸下视觉上就是平滑渐变（DXT 编码器标准做法）。"""
    m = ((0, 8, 2, 10),
         (12, 4, 14, 6),
         (3, 11, 1, 9),
         (15, 7, 13, 5))
    px = list(img.getdata())
    w = img.size[0]
    out = []
    for y in range(img.size[1]):
        for x in range(w):
            r, g, b, a = px[y * w + x]
            d = (m[y % 4][x % 4] / 16.0 - 0.5) * 2.0 * strength
            out.append((max(0, min(255, int(r + d))),
                        max(0, min(255, int(g + d))),
                        max(0, min(255, int(b + d))), a))
    dimg = Image.new('RGBA', img.size)
    dimg.putdata(out)
    return dimg


def main():
    img = Image.open(SRC).convert('RGBA')
    assert img.size == (128, 128), img.size
    img = bayer_dither(img)

    mips = [img]
    w, h = 128, 128
    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        mips.append(img.resize((w, h), Image.LANCZOS))

    # ⚠ KTEX 真实布局（引擎 trans.tex + 参考 modicon 双证，2026-09 踩坑）：
    # [8字节头][全部 mip 元数据 依次][全部 mip 数据 依次]——元数据在前、
    # 数据在后，绝不交错。交错写法引擎 DeserializeTexture 读歪，
    # glGetError 0x501 图标全黑。小 mip（2x2/1x1）pitch 最低 16（一块）。
    blob = pack_header()
    metas = []
    datas = []
    sizes = []
    for m in mips:
        data = encode_mip(m)
        w, h = m.size
        pitch = max(16, (w // 4) * 16)
        metas.append(struct.pack('<HHHI', w, h, pitch, len(data)))
        datas.append(data)
        sizes.append(len(data))
    blob += b''.join(metas) + b''.join(datas)
    assert sizes == [16384, 4096, 1024, 256, 64, 16, 16, 16], sizes
    assert len(blob) == 21960, len(blob)

    with open(OUT_TEX, 'wb') as f:
        f.write(blob)
    print('header hex:', blob[:16].hex(' '), '(参考 modicon.tex 头部应一致)')

    xml = ('<Atlas><Texture filename="modicon.tex" /><Elements>'
           '<Element name="modicon.tex" u1="0.00390625" u2="0.99609375" '
           'v1="0.00390625" v2="0.99609375" /></Elements></Atlas>')
    with open(OUT_XML, 'w', encoding='ascii') as f:
        f.write(xml)

    # ---- 回验：按真实布局（元数据全在前）解码到 128 PNG，对比源图 RMS ----
    off = 8
    decoded = None
    meta_list = []
    for _m in mips:
        meta_list.append(struct.unpack_from('<HHHI', blob, off))
        off += 10
    for (w, h, pitch, dsz) in meta_list:
        data = blob[off:off + dsz]
        off += dsz
        pix = decode_mip(data, w, h)
        if w == 128:
            decoded = pix
    src_px = list(img.getdata())
    err = 0.0
    for a, b in zip(src_px, decoded):
        err += sum((a[k] - b[k]) ** 2 for k in range(3))
    rms = (err / (128 * 128 * 3)) ** 0.5
    print('KTEX written:', OUT_TEX, len(blob), 'bytes, 8 mips, DXT5')
    print('decode RMS vs source:', round(rms, 3))
    vimg = Image.new('RGB', (128, 128))
    vimg.putdata([tuple(p) for p in decoded])
    vimg.save(OUT_VERIFY)
    print('verify png:', OUT_VERIFY)


if __name__ == '__main__':
    main()
