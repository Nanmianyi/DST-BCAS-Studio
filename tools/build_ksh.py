"""把 src_shaders/*.ps / *.vs 组装为引擎可加载的 .ksh 容器。

用法:
    python tools/build_ksh.py            # 构建全部（锐化 + 调色两个 pass）
    python tools/build_ksh.py [ps源] [ksh输出]   # 单独构建一个

不依赖 NVIDIA Cg 工具链。容器 schema 经字节级 round-trip 验证
（见 tools/ksh_parse.py 文档，10/10 对齐游戏自带 + 工坊着色器）。

双 pass 架构（2026-08）：单 pass 源码有 ~4096 字节引擎缓冲上限，
参数全暴露后塞不下，拆为：
    bcas_studio.ksh  锐化（核心 + 进阶 + AURA）
    bcas_cinema.ksh  调色引擎（EV/WB/CDL/二级CDL/饱和/ACES/暗角/颗粒）
链路顺序： studio -> cinema（渲染顺序 锐化 -> 调色 -> 氛围，与旧 fx 一致）。
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ksh_parse import build, parse, TYPE_FLOAT, TYPE_VEC2, TYPE_VEC3, TYPE_VEC4, TYPE_SAMPLER2D

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_VS = os.path.join(ROOT, 'src_shaders', 'postprocess_base.vs')

# 源码结尾必须与 Klei 自带 ksh 一致：\r\n\r\n\x00（NUL 计入长度）。
# 引擎按"读到 NUL 为止"消费源码；没有 NUL 会越界多读一个堆垃圾字节，
# 直接报 invalid character 编译失败（2026-08 实测，日志可复现）。
SRC_TAIL = b'\r\n\r\n\x00'


def V(name):
    """vec4 条目速记"""
    return dict(name=name, type=TYPE_VEC4, a=0, count=1, ncomps=4, zeros=[0, 0, 0, 0])


SHADERS = [
    {
        # PASS 1：电影调色（EV/WB/CDL/二级CDL/饱和/ACES）
        'name': 'bcas_cinema',
        'ps': os.path.join(ROOT, 'src_shaders', 'bcas_cinema.ps'),
        'out': os.path.join(ROOT, 'BCAS-Studio', 'shaders', 'bcas_cinema.ksh'),
        # 条目表必须与 GLSL uniform 声明完全一致，且只登记"被实际使用"的
        # uniform——未使用的会被编译器优化掉，引擎查不到索引就原生断言闪退
        'entries': [
            dict(name='SAMPLER', type=TYPE_SAMPLER2D, a=0, arraylen=1),
            V('BCAS_GRADE_A'),   # x曝光EV y色温 z色调 w饱和度
            V('BCAS_GRADE_B'),   # x自然饱和 y对比度 z亮度 wGamma
            V('BCAS_EXTRA'),     # xACES混合
            V('BCAS_CDL_S'),     # xyz一级斜率 w二级开关
            V('BCAS_CDL_O'),     # xyz一级偏移 w高光去饱和
            V('BCAS_CDL_P'),     # xyz一级幂
            V('BCAS_SEC_S'),     # xyz二级斜率
            V('BCAS_SEC_O'),     # xyz二级偏移 w原始混合
            V('BCAS_SEC_P'),     # xyz二级幂
        ],
    },
    {
        # PASS 2：锐化与终合成（双边锐化/AURA/暗角/颗粒/抖动）
        'name': 'bcas_studio',
        'ps': os.path.join(ROOT, 'src_shaders', 'bcas_studio.ps'),
        'out': os.path.join(ROOT, 'BCAS-Studio', 'shaders', 'bcas_studio.ksh'),
        'entries': [
            dict(name='SAMPLER', type=TYPE_SAMPLER2D, a=0, arraylen=1),
            V('SCREEN_PARAMS'),
            V('BCAS_SHARPEN'),   # x强度 y降噪 z抗振铃 w暗部保护
            V('BCAS_SHARP2'),    # xRangeSigma ySpatialSigma zCenterWeight wNoiseFloor
            V('BCAS_AURA'),      # x边缘阈值 y亮部过冲 z暗部过冲 w色度保护
            V('BCAS_ATMO'),      # x暗角 y颗粒 z时间(动画)
        ],
    },
]


def read_source(path):
    text = open(path, 'r', encoding='utf-8').read()
    # ANGLE 的 GLSL ES 编译器拒绝一切非 ASCII 字符（"invalid character"），
    # 着色器源码必须保持纯 ASCII —— 这里强制把关，防止中文注释混进来。
    bad = [(i + 1, ch) for i, line in enumerate(text.split('\n'))
           for ch in line if ord(ch) > 127]
    if bad:
        lineno, ch = bad[0]
        raise SystemExit(
            f'{path}: 发现非 ASCII 字符 {ch!r}（第 {lineno} 行，共 {len(bad)} 处）。'
            f'ANGLE 的 GLSL ES 编译器不接受非 ASCII 源码，请改用英文注释。')
    return text


def minify_glsl(text):
    """把 GLSL 压成单行：去注释、展开 #define、去掉预处理分支、折叠空白。

    为什么：引擎对多行源码做换行转换时长度会算错（2026-08 实测：源码
    最后一行之后被塞进堆垃圾，报 "invalid character 0xED" 静默编译失败）。
    单行源码没有换行符，长度必然精确。代价是编译报错不再有行号，可接受。

    第二道关（2026-08 实测）：引擎把源码递给 GL 编译器时走 ~4096 字节的
    定长缓冲，超长部分变成堆垃圾，同样报 "invalid character"/"syntax
    error" 且注册照常返回 true（静默无效果）。因此压缩器还要剥掉一切
    可省字符：非"单词之间"的空格全部删除，浮点尾零 N.0 -> N.，压缩产物
    必须控制在 ~3800 字节以内（build 时会打印长度，超限要回头改源码）。
    """
    assert '/*' not in text, '不支持块注释'
    defines = {}
    kept = []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('//'):
            continue
        code = stripped.split('//', 1)[0].rstrip()
        if code.startswith('#define'):
            parts = code.split(None, 2)
            if len(parts) == 3:
                defines[parts[1]] = parts[2]
            continue
        if code.startswith('#if') or code.startswith('#endif') or code.startswith('#else'):
            # 目前只用于 GL_ES precision 守卫：去掉守卫、保留内部语句
            continue
        if code:
            kept.append(code)
    body = '\n'.join(kept)
    for _ in range(3):
        for name, value in defines.items():
            body = re.sub(r'\b%s\b' % re.escape(name), value, body)
    body = ' '.join(body.split())
    # 只保留夹在两个单词字符之间的空格（关键字/名字边界），其余全删
    body = re.sub(r'(?<=[^A-Za-z0-9_]) +', '', body)
    body = re.sub(r' +(?=[^A-Za-z0-9_])', '', body)
    # 浮点尾零：0.0 -> 0.（"1.05" 之类不受影响，\b 保证后面不再是数字）
    body = re.sub(r'\b(\d+)\.0\b', r'\1.', body)
    return body.encode('ascii')


def glsl_uniforms(src_text):
    """从 GLSL 源里提取声明的 uniform 名与类型"""
    out = {}
    for m in re.finditer(r'\buniform\s+(\w+)\s+(\w+)\s*(?:\[\s*\d+\s*\])?\s*;', src_text):
        out[m.group(2)] = m.group(1)
    return out


def build_one(spec, vs_src):
    ps_text = read_source(spec['ps'])
    ps_src = minify_glsl(ps_text) + SRC_TAIL

    # 引擎 ~4096 字节源码缓冲的硬防线：超限的 ksh 能注册但编译必败（静默无效果）
    if len(ps_src) > 3900:
        raise SystemExit(
            f"{spec['name']}: 压缩后 ps 源码 {len(ps_src)} 字节，超过安全线 3900"
            f'（引擎 ~4096 缓冲截断后会静默编译失败），请缩短着色器源码。')

    # GLSL <-> 条目表 交叉校验（SAMPLER 数组单独处理）
    declared = glsl_uniforms(ps_text)
    entries = spec['entries']
    # 未使用 uniform 防线：编译器会优化掉没被使用的 uniform，引擎查不到
    # 索引（0xFFFFFFFF）直接原生断言闪退（2026-08 实测 SCREEN_PARAMS）。
    # 压缩产物里名字只出现一次 = 只有声明、没有使用。
    for e in entries:
        if e['name'] == 'SAMPLER':
            continue
        if ps_src.count(e['name'].encode('ascii')) < 2:
            raise SystemExit(
                f"{spec['name']}: uniform {e['name']} 已声明但未使用，编译器会优化掉它，"
                f'引擎将原生断言闪退。请从条目表和 GLSL 中移除，或在代码中实际使用。')

    entry_names = {e['name'] for e in entries}
    for name, typ in declared.items():
        if name == 'SAMPLER':
            continue
        if name not in entry_names:
            raise SystemExit(f"{spec['name']}: GLSL 声明了未登记的 uniform: {name} ({typ}) —— 请同步 ENTRIES")
    for e in entries:
        if e['name'] == 'SAMPLER':
            assert declared.get('SAMPLER') == 'sampler2D', 'GLSL 中缺少 uniform sampler2D SAMPLER[1];'
            continue
        if e['name'] not in declared:
            raise SystemExit(f"{spec['name']}: 条目 {e['name']} 未在 GLSL 中声明")
        expect = {TYPE_FLOAT: 'float', TYPE_VEC2: 'vec2', TYPE_VEC3: 'vec3', TYPE_VEC4: 'vec4'}[e['type']]
        if declared[e['name']] != expect:
            raise SystemExit(f"{spec['name']}: 条目 {e['name']} 类型不符: ksh={expect} glsl={declared[e['name']]}")

    n = len(entries)
    trailer = struct.pack('<II', 0, n) + b''.join(struct.pack('<I', i) for i in range(n))
    ksh = {
        'name': spec['name'],
        'entry_count': n,
        'entries': entries,
        'vs_file': 'postprocess_base.vs',
        'vs_src': vs_src,
        'ps_file': spec['name'] + '.ps',
        'ps_src': ps_src,
        'trailer': trailer,
    }
    blob = build(ksh)
    out_path = spec['out']
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    open(out_path, 'wb').write(blob)

    # 自校验：重新解析并 round-trip
    r = parse(out_path)
    assert build(r) == blob, 'round-trip 失败'
    print(f"OK  {out_path}  ({len(blob)} bytes, {n} entries, ps_src={len(ps_src)})")
    return blob


def main():
    args = sys.argv[1:]
    vs_text = read_source(DEFAULT_VS)
    vs_src = minify_glsl(vs_text) + SRC_TAIL
    if len(args) >= 2:
        # 单独构建一个：build_ksh.py [ps源] [ksh输出] —— 兼容旧用法（studio）
        spec = dict(SHADERS[0])
        spec['ps'] = args[0]
        spec['out'] = args[1]
        build_one(spec, vs_src)
        return
    for spec in SHADERS:
        build_one(spec, vs_src)


if __name__ == '__main__':
    main()
