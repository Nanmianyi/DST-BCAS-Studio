"""Klei .ksh 着色器容器解析/构建器（新格式）

逆向自：游戏自带 postprocess_*.ksh / combine_colour_cubes.ksh + 创意工坊 pxl_42_color.ksh
（已通过字节级 round-trip 校验）。

容器布局（全部小端 u32 长度前缀，紧凑无填充）：
    [u32 namelen][name]
    [u32 entry_count]
    entry × entry_count:
        [u32 namelen][name]
        [u32 0]                          # 观察恒为 0（可能是寄存器/标志）
        [u32 TYPE]                       # 0=float 2=vec2 3=vec3 4=vec4 0x2b=sampler2D
        TYPE == 0x2b (采样器):
            [u32 arraylen]               # SAMPLER[n] 的 n
        其他 (floatN uniform):
            [u32 count=1]
            [u32 ncomps]                 # float=1 vec2=2 vec3=3 vec4=4
            [ncomps × u32 0]
    [u32 vsfnlen][vs_filename][u32 srclen][vs_source]
    [u32 psfnlen][ps_filename][u32 srclen][ps_source]
    [trailer]                            # 观察为 12 字节尾块，原样复制
"""
import struct, sys, os, glob

TYPE_FLOAT = 0
TYPE_VEC2 = 2
TYPE_VEC3 = 3
TYPE_VEC4 = 4
TYPE_SAMPLER2D = 0x2B
TYPE_NAME = {0: 'float', 2: 'vec2', 3: 'vec3', 4: 'vec4', 0x2B: 'sampler2D'}


def parse(path):
    data = open(path, 'rb').read()
    off = 0
    def u32():
        nonlocal off
        v = struct.unpack_from('<I', data, off)[0]; off += 4; return v
    def s():
        nonlocal off
        n = u32(); v = data[off:off+n]; off += n
        return v.decode('utf-8', 'replace')
    def raw(n):
        nonlocal off
        v = data[off:off+n]; off += n; return v

    r = {'name': s(), 'entry_count': u32(), 'entries': []}
    for _ in range(r['entry_count']):
        e = {'name': s(), 'a': u32(), 'type': u32()}
        if e['type'] == TYPE_SAMPLER2D:
            e['arraylen'] = u32()
        else:
            e['count'] = u32(); e['ncomps'] = u32()
            e['zeros'] = [u32() for _ in range(e['ncomps'])]
        r['entries'].append(e)
    r['vs_file'] = s()
    r['vs_src'] = raw(u32())
    r['ps_file'] = s()
    r['ps_src'] = raw(u32())
    r['trailer'] = raw(len(data) - off)
    return r


def build(r):
    out = bytearray()
    def u32(v): out.extend(struct.pack('<I', v))
    def st(t):
        b = t.encode('utf-8'); u32(len(b)); out.extend(b)
    st(r['name'])
    u32(r['entry_count'])
    for e in r['entries']:
        st(e['name']); u32(e['a']); u32(e['type'])
        if e['type'] == TYPE_SAMPLER2D:
            u32(e['arraylen'])
        else:
            u32(e['count']); u32(e['ncomps'])
            for z in e['zeros']: u32(z)
    st(r['vs_file'])
    u32(len(r['vs_src'])); out.extend(r['vs_src'])
    st(r['ps_file'])
    u32(len(r['ps_src'])); out.extend(r['ps_src'])
    out.extend(r['trailer'])
    return bytes(out)


if __name__ == '__main__':
    extract = '--extract' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    ok = fail = 0
    for pat in args:
        for p in sorted(glob.glob(pat)):
            try:
                orig = open(p, 'rb').read()
                r = parse(p)
                status = 'ROUNDTRIP OK' if build(r) == orig else 'ROUNDTRIP MISMATCH'
                if 'OK' in status: ok += 1
                else: fail += 1
                ents = ', '.join(
                    f"{e['name']}:{TYPE_NAME.get(e['type'], hex(e['type']))}"
                    + (f"[{e['arraylen']}]" if e['type'] == TYPE_SAMPLER2D else f"({e['ncomps']})")
                    for e in r['entries'])
                print(f"--- {os.path.basename(p)} [{status}]")
                print(f"    name={r['name']!r} entries({r['entry_count']}): {ents}")
                print(f"    vs={r['vs_file']!r}({len(r['vs_src'])}B) ps={r['ps_file']!r}({len(r['ps_src'])}B) trailer={r['trailer'].hex()}")
                if extract and 'OK' in status:
                    base = os.path.splitext(p)[0]
                    open(base + '.vs.glsl', 'wb').write(r['vs_src'])
                    open(base + '.ps.glsl', 'wb').write(r['ps_src'])
            except Exception as e:
                fail += 1
                print(f"--- {os.path.basename(p)} PARSE FAIL: {e}")
    print(f"\n== {ok} ok, {fail} fail ==")
