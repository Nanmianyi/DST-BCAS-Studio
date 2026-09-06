import os
import sys
import re
import struct
import zipfile
import time
import numpy as np
from PIL import Image, ImageFont, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TTC_PATH = r"C:\Users\{nan}\AppData\Local\Microsoft\Windows\Fonts\Sarasa-SuperTTC.ttc"
SARASA_INDEX = 295  # Sarasa UI SC SemiBold

ORIGINAL_NORMAL_ZIP = os.path.join(ROOT, "BCAS-Studio", "fonts", "normal.zip")
OUT_NORMAL_ZIP = os.path.join(ROOT, "BCAS-Studio", "fonts", "normal.zip")
OUT_OUTLINE_ZIP = os.path.join(ROOT, "BCAS-Studio", "fonts", "normal_outline.zip")

print("[1/5] 读取原版 font.fnt 字符布局坐标...", flush=True)
with zipfile.ZipFile(ORIGINAL_NORMAL_ZIP, 'r') as z:
    fnt_text = z.read('font.fnt').decode('utf-8', errors='ignore')

char_pattern = re.compile(r'<char\s+id="(\d+)"\s+x="(\d+)"\s+y="(\d+)"\s+width="(\d+)"\s+height="(\d+)"\s+xoffset="([^"]+)"\s+yoffset="([^"]+)"\s+xadvance="(\d+)"')
chars = char_pattern.findall(fnt_text)
print(f"解析到字符总数: {len(chars)}", flush=True)

print("[2/5] 加载思源黑体系字模母带 (Sarasa UI SC SemiBold) (Index 295)...", flush=True)
font_size = 72
font = ImageFont.truetype(TTC_PATH, font_size, index=SARASA_INDEX)

W, H = 4096, 8192
print(f"[3/5] 栅格化思源黑体系字模到 {W}x{H} 视网膜字模图集...", flush=True)
atlas = Image.new("L", (W, H), 0)
draw = ImageDraw.Draw(atlas)

t0 = time.time()
rendered = 0
for ch_id_str, x_str, y_str, w_str, h_str, xoff_str, yoff_str, adv_str in chars:
    ch_id = int(ch_id_str)
    x, y, w, h = int(x_str), int(y_str), int(w_str), int(h_str)
    if ch_id == 0 or ch_id == 32:
        continue
    try:
        ch = chr(ch_id)
    except Exception:
        continue
    
    bbox = font.getbbox(ch)
    if bbox:
        bw = bbox[2] - bbox[0]
        bh = bbox[3] - bbox[1]
        draw_x = x + max(0, (w - bw) // 2) - bbox[0]
        draw_y = y + max(0, (h - bh) // 2) - bbox[1]
        draw.text((draw_x, draw_y), ch, font=font, fill=255)
        rendered += 1

print(f"栅格化完成! 成功渲染: {rendered} 字, 耗时: {time.time() - t0:.2f}s", flush=True)

print("[4/5] 生成精密深焙描边图集...", flush=True)
t_out = time.time()
outline_atlas = atlas.filter(ImageFilter.MaxFilter(3))
print(f"描边生成完成! 耗时: {time.time() - t_out:.2f}s", flush=True)

# 纯 numpy 极速批量 DXT5 编码
lut = np.zeros(256, dtype=np.uint64)
lut[0] = 1
lut[240:] = 0
for v in range(1, 240):
    lut[v] = 7 - int(v * 5 // 255)

def encode_ktex_dxt5_vectorized(img_gray):
    headers = []
    mips_data = []
    curr = img_gray
    
    rgb_block_bytes = struct.pack('<HHI', 0xFFFF, 0xFFFF, 0)
    
    for mip_idx in range(14):
        mw, mh = curr.size
        pad_w = ((mw + 3) // 4) * 4
        pad_h = ((mh + 3) // 4) * 4
        if pad_w != mw or pad_h != mh:
            padded = Image.new("L", (pad_w, pad_h), 0)
            padded.paste(curr, (0, 0))
            arr = np.array(padded, dtype=np.uint8)
        else:
            arr = np.array(curr, dtype=np.uint8)
            
        bh, bw = arr.shape[0] // 4, arr.shape[1] // 4
        num_blocks = bh * bw
        blocks = arr.reshape(bh, 4, bw, 4).transpose(0, 2, 1, 3).reshape(num_blocks, 16)
        
        # 向量化 LUT 映射
        codes = lut[blocks] # shape: (num_blocks, 16), uint64
        
        # 将 16 个 3-bit 移位组合成 48-bit 整数
        shifts = np.arange(16, dtype=np.uint64) * 3
        bits = (codes << shifts).sum(axis=1, dtype=np.uint64)
        
        # 组装 Alpha 块 (8 字节: a0=255, a1=0, bits(6字节小端))
        # 对全零块优化
        is_zero = (blocks == 0).all(axis=1)
        
        # 批量打包结构体
        # 每个块 16 字节: 8 字节 Alpha + 8 字节 RGB
        block_bytes = np.zeros((num_blocks, 16), dtype=np.uint8)
        
        # 填充非零块
        nz_indices = np.nonzero(~is_zero)[0]
        if len(nz_indices) > 0:
            nz_bits = bits[nz_indices]
            # 填充 a0, a1
            block_bytes[nz_indices, 0] = 255
            block_bytes[nz_indices, 1] = 0
            # 拆分 48-bit 为 6 个字节
            for b_i in range(6):
                block_bytes[nz_indices, 2 + b_i] = ((nz_bits >> (b_i * 8)) & 0xFF).astype(np.uint8)
            # 填充 RGB (c0=0xFFFF, c1=0xFFFF, idx=0)
            block_bytes[nz_indices, 8] = 0xFF
            block_bytes[nz_indices, 9] = 0xFF
            block_bytes[nz_indices, 10] = 0xFF
            block_bytes[nz_indices, 11] = 0xFF
            # 后 4 字节为 0，已经是 0
            
        raw_data = block_bytes.tobytes()
        headers.append(struct.pack('<HHHI', mw, mh, 0, len(raw_data)))
        mips_data.append(raw_data)
        
        if mw > 1 or mh > 1:
            curr = curr.resize((max(1, mw // 2), max(1, mh // 2)), Image.Resampling.BILINEAR)
            
    ktex_head = struct.pack('<II', 0x5845544B, 0xFFF1C220)
    return ktex_head + b''.join(headers) + b''.join(mips_data)

print("[5/5] 极速向量化压制 KTEX DXT5...", flush=True)
t_dxt1 = time.time()
normal_ktex = encode_ktex_dxt5_vectorized(atlas)
print(f"正文 KTEX 压制完成! 大小: {len(normal_ktex)} 字节, 耗时: {time.time() - t_dxt1:.2f}s", flush=True)

t_dxt2 = time.time()
outline_ktex = encode_ktex_dxt5_vectorized(outline_atlas)
print(f"描边 KTEX 压制完成! 大小: {len(outline_ktex)} 字节, 耗时: {time.time() - t_dxt2:.2f}s", flush=True)

sarasa_fnt = re.sub(r'face="[^"]+"', 'face="Sarasa UI SC SemiBold"', fnt_text)

print(f"打包写入 {OUT_NORMAL_ZIP}...", flush=True)
with zipfile.ZipFile(OUT_NORMAL_ZIP, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('font.fnt', sarasa_fnt.encode('utf-8'))
    z.writestr('font.tex', normal_ktex)

print(f"打包写入 {OUT_OUTLINE_ZIP}...", flush=True)
with zipfile.ZipFile(OUT_OUTLINE_ZIP, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('font.fnt', sarasa_fnt.encode('utf-8'))
    z.writestr('font.tex', outline_ktex)

print("BCAS Studio 思源黑体高清字库构建完成！", flush=True)
