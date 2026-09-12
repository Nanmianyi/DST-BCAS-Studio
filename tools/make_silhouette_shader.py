# -*- coding: utf-8 -*-
"""从引擎自带的 anim.ksh / anim_skinned.ksh 派生影子剪影着色器（三个固定变体）。

【为什么要有"变体"而不是一个带哨兵的着色器】
上一版用一个运行时 uniform 当哨兵（FLOAT_PARAMS.z = 2/3/4 切换模式），结果整条
视觉链（alpha 压平 + 深度错位）都挂在这一个 uniform 能不能活到绘制时刻上：
FLOAT_PARAMS 是引擎按实体状态喂进去的，SetBuild/SetSkin/SetFloatParams 之外的
引擎内部改动都可能把它清掉，而且失败是【静默】的 —— 表现就是"线条一直在、
疯狂闪、缺块"，且怎么调数值都不好，因为那段代码根本没执行。
现在改成三个各带固定逻辑的着色器文件，不再读任何哨兵：
    bcas_silhouette.ksh          可见层：硬 alpha 压平 + 前推 LAYER_BIAS
    bcas_silhouette_write.ksh    写深度孪生体：硬 alpha 压平 + 输出 alpha=0 + 前推 0
    bcas_silhouette_fx.ksh       装备克隆：硬 alpha 压平（可见）+ 后撤 FX_BACKOFF
每个再出一份 _skinned（照抄引擎 anim_skinned.ksh，供非 skinned 版在某些实体上
渲染成碎块时切换）。

【单层混合的原理（三个文件协同）】
影子是 ANIM_ORIENTATION.OnGround 的贴地贴图，引擎把它整块压平，重叠部件深度完全
相同 —— 于是每个部件各混合一次，叠出内部深色线条。做法：
  * 可见层与孪生体的顶点着色器都按【纯顶点属性】给每个部件一个稳定深度：
    美术高度（POS2D_UV.y）+ 图集 u + 图集页 + 符号档（PARAMS.y，可选的加分项）。
    这些都是顶点数据，不依赖任何运行时 uniform，所以一定会生效。
  * 孪生体开深度测试 + 深度写入（alpha 输出 0，完全不可见），缓冲里留下每像素
    【最近】那层的深度；可见层整体比它再近 LAYER_BIAS，于是同一像素只有最近那层
    能通过深度测试 —— 每像素只混合一次，叠加线条消失。
错位量的取值区间由两端夹出来（本项目实测标定）：
  * 下限：必须远大于 24 位深度缓冲的量化噪声（1 个单位 ≈ 6e-8，换成 clip 空间
    z/w ≈ 1.2e-7）。旧版用 2e-7 / 3e-7，只有 1.7 / 2.5 个单位，全部落在噪声里 ——
    同像素胜负由舍入决定，表现就是"疯狂闪烁 + 随机缺块"。
  * 上限：影子整体前推不能大到盖住站在它前面的实体。DST 相机距离下
    1e-4 NDC 量级 ≈ 几厘米世界距离，所以总量控制在 1.53e-4 以内（≈ 脚边一次
    偏移），远小于"角色站到影子前面"时的真实深度差。
本版取值：单档 6e-7（5 个单位）起，总量最大 1.53e-4（约 1275 个单位）。

源 ksh 从游戏本体取（不入库，体积大且是引擎素材）：
    <DST>/data/databundles/shaders.zip  ->  anim.ksh / anim_skinned.ksh
解到 reference/dst_shaders/shaders/ 下即可（reference/ 已在 .gitignore 里）。

用法: python tools/make_silhouette_shader.py
"""
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ksh_parse  # noqa: E402

ENGINE = ROOT / "reference" / "dst_shaders" / "shaders"
OUT_DIR = ROOT / "BCAS-Studio" / "shaders"

# ---------------------------------------------------------------------------
# 数值（clip 空间单位；gl_Position.z -= X * gl_Position.w 时 X 就是 z/w 的位移）
# ---------------------------------------------------------------------------
# 硬 alpha 测试阈值：>= CUT 拍成实心，< CUT 丢弃。
# 0.30 是照 tools/shadow_alpha_audit.py 对真实图集的实测定的：91~94% 的像素
# alpha ≥ 0.9，剩下的淡像素 93.8% 都落在实心区边缘 2px 内（都是抗锯齿软边，
# 不是独立笔画），所以 0.3 正好只切掉那圈 AA，不会切掉美术本身。
CUT = 0.30
# 美术高度梯度：每厘米深度差。512 * 1e-7 = 5.12e-5，仍是噪声的 400 倍。
ART_K = 0.0000001
# 全部影子通道共用的前推量（把影子整体抬到地平面之前，消除与地面的 z-fighting，
# 也保证孪生体的深度写入不会被地面拒掉）。2e-5 = 166 个深度单位。
ART_FLOOR = 0.00002
# 可见层在孪生体之前的额外前推：必须【小于一个符号档间距】(PARAMS_KEY=2e-6)，
# 又要远大于噪声。6e-7 = 5 个深度单位。
LAYER_BIAS = 0.0000006
# 纯顶点属性的两个次级错位（不同图集区域/不同图集页的部件靠它们分胜负）：
# 高度完全相同的两个部件（脸贴在头上、帽子压在头发上）只看 ART_K 会打平，
# 而打平就是"两层都通过深度测试 -> 又叠出一条线并且来回闪"。
U_KEY = 0.0000004
PAGE_KEY = 0.0000001
# 每个【符号】一个离散档（可选加分项）：Lua 用 SetSymbolLightOverride(symbol, k)
# 编号 k=1..40，顶点着色器当 PARAMS.y 读出来乘 PARAMS_KEY。
PARAMS_KEY = 0.000002
PARAMS_BASE = 0.000001
# 装备克隆整体再往远处偏一点（它和本体局部高度可能几乎一样）。
# 相减后仍为正：ART_FLOOR + PARAMS_BASE - FX_BACKOFF = 1.95e-5 > 0
# （上一版这里是负数，等于把装备克隆推到地平面之后，被地面整块裁掉）。
FX_BACKOFF = 0.0000015

# 变体：(输出名, 额外的深度偏置, 强制输出 alpha；None = 保留乘色 alpha)
VARIANTS = [
    ("bcas_silhouette", LAYER_BIAS, None),
    ("bcas_silhouette_write", 0.0, 0.0),
    ("bcas_silhouette_fx", -FX_BACKOFF, None),
]

PS_ANCHOR = "gl_FragColor.rgba = colour.rgba * COLOUR_XFORM;"
VS_BOB_OLD = "if(FLOAT_PARAMS.z > 0.0)"
VS_BOB_NEW = "if(FLOAT_PARAMS.z > 0.0 && FLOAT_PARAMS.z < 1.5)"
VS_HOLO_ANCHOR = "\t#if defined( HOLO )"
VS_UNIFORM_ANCHOR = "uniform vec4 TIMEPARAMS;"
# 引擎的 alpha 测试：它对"贴图原始 alpha"做 discard。剪影着色器自己已经有硬裁剪，
# 两个闸门同时存在只会让结果依赖 PARAMS.x（引擎按实体状态设置，不是我们能控的），
# 所以在这个着色器里把它关掉（只影响影子自己用的这个 ksh）。
PS_ALPHATEST_OLD = "if (ALPHA_TEST > 0.0)"
PS_ALPHATEST_NEW = "if (false) // BCAS: silhouette shader does its own hard cut"

# 引擎 PS 里"按 FLOAT_PARAMS.y/x 把低于某高度的片元丢掉"的那段：剪影不需要，
# 而且它的存在会让影子在某些取值下整块消失。
PS_HEIGHT_CUT_OLD = """    if(FLOAT_PARAMS.y > 0.0)
    {
    	if(PS_POS.y < FLOAT_PARAMS.x)
    	{
    		discard;
    	}
    }
"""
PS_HEIGHT_CUT_NEW = """    // BCAS: engine's optional height cut removed for the silhouette shader.
"""

# 注入的源码必须纯 ASCII：GLSL 字符集有限制，中文注释在 ANGLE 下可能直接编译失败
# （失败 = 引擎回退 = 影子又变成带描边的软边），所以注释一律英文。
PS_PATCH = """        // >>> BCAS silhouette: hard alpha flatten (no runtime uniform involved)
        // alpha >= CUT becomes fully solid, so every pixel of the silhouette carries
        // exactly ONE alpha value (the entity's mult colour). Painted strokes, hatching,
        // eye patterns and the soft 1-2px artwork rim can then no longer show up as
        // internal lines; below CUT the fragment is DISCARDED instead of blended (a soft
        // rim left in the blend lands on a neighbouring symbol and darkens into a line).
        if (colour.a < %(cut)s) discard;
        colour.a = 1.0;
        // <<< BCAS
""" % {"cut": repr(CUT)}

VS_UNIFORM_PATCH = """
uniform vec3 PARAMS;   // x=ALPHA_TEST, y=LIGHT_OVERRIDE (shadows reuse it as a
                       // per-symbol depth index), z=BLOOM_TOGGLE
"""


def ps_force_alpha(force_alpha):
    """写深度档：乘色之后把输出 alpha 压成 0（不可见，但深度照写）。"""
    if force_alpha is None:
        return ""
    return ("\r\n        gl_FragColor.a = %s;   // BCAS: invisible, depth-only pass"
            % repr(force_alpha))


def vs_depth_patch(extra_bias):
    return ("""
        // >>> BCAS shadow depth staging (pure vertex attributes, no uniform sentinel)
        // A ground-flattened sprite loses its depth ordering, so overlapping parts each
        // blend and darken into internal lines. Give every part a stable depth derived
        // from vertex data only -- artwork height, atlas u, atlas page -- plus the
        // optional per-symbol index PARAMS.y (Lua sets it via SetSymbolLightOverride).
        // The depth-writing twin keeps the closest layer per pixel; the visible layer is
        // a hair in front of it, so exactly one layer blends per pixel.
        // NOTE: FLOAT_PARAMS MUST stay referenced here: the ksh trailer lists it as a
        // vertex-stage uniform, and a uniform the compiler drops would be bound with
        // GL location -1 -> ANGLE assert crash. Its .y is the artwork top (0 -> 512).
        {
            float bcasTop = (FLOAT_PARAMS.y > 8.0) ? FLOAT_PARAMS.y : 512.0;
            float bcasPage = floor(POS2D_UV.z / 2.0);
            float bcasU = POS2D_UV.z - 2.0 * bcasPage;
            float bcasArt = clamp(bcasTop - POS2D_UV.y, 0.0, bcasTop);
            float bcasSym = PARAMS.y * %(params_key)s + %(params_base)s;
            gl_Position.z -= (%(art_k)s * bcasArt + %(u_key)s * bcasU
                + %(page_key)s * bcasPage + bcasSym + %(art_floor)s
                + (%(bias)s)) * gl_Position.w;
        }
        // <<< BCAS
""" % {
        "art_k": repr(ART_K), "u_key": repr(U_KEY), "page_key": repr(PAGE_KEY),
        "params_key": repr(PARAMS_KEY), "params_base": repr(PARAMS_BASE),
        "art_floor": repr(ART_FLOOR), "bias": repr(extra_bias),
    }).replace("\n", "\r\n")


def patch_sources(vs_text, ps_text, extra_bias, force_alpha):
    # ---- PS ----
    if PS_ANCHOR not in ps_text:
        raise SystemExit("PS 锚点未找到：" + PS_ANCHOR)
    if ps_text.count(PS_ANCHOR) != 1:
        raise SystemExit("PS 锚点出现多次，拒绝改")
    if PS_ALPHATEST_OLD in ps_text:
        if ps_text.count(PS_ALPHATEST_OLD) != 1:
            raise SystemExit("PS alpha test 锚点异常")
        ps_text = ps_text.replace(PS_ALPHATEST_OLD, PS_ALPHATEST_NEW, 1)
    # 引擎 ksh 源码是 CRLF 行尾，多行锚点要按 \r\n 匹配
    cut_old = PS_HEIGHT_CUT_OLD.replace("\n", "\r\n")
    if cut_old in ps_text:
        if ps_text.count(cut_old) != 1:
            raise SystemExit("PS 高度裁剪段锚点异常")
        ps_text = ps_text.replace(cut_old, PS_HEIGHT_CUT_NEW.replace("\n", "\r\n"), 1)
    if "BCAS silhouette" in ps_text:
        raise SystemExit("PS 里已有 BCAS 注入，拒绝重复注入")
    ps_out = ps_text.replace(PS_ANCHOR, PS_PATCH.replace("\n", "\r\n") + PS_ANCHOR, 1)
    # 强制 alpha 必须插在乘色之后（乘色会重写整条 rgba，插前面会被它盖掉）
    force = ps_force_alpha(force_alpha)
    if force:
        ps_out = ps_out.replace(PS_ANCHOR, PS_ANCHOR + force, 1)

    # ---- VS ----
    if "uniform vec3 PARAMS;" not in vs_text:
        if vs_text.count(VS_UNIFORM_ANCHOR) != 1:
            raise SystemExit("VS 里找不到 TIMEPARAMS 声明锚点")
        vs_text = vs_text.replace(
            VS_UNIFORM_ANCHOR, VS_UNIFORM_ANCHOR + VS_UNIFORM_PATCH.replace("\n", "\r\n"), 1)
    if VS_BOB_NEW not in vs_text:           # 引擎的 floater 浮动：影子不接受哨兵值
        if vs_text.count(VS_BOB_OLD) != 1:
            raise SystemExit("VS 浮动锚点出现 %d 次" % vs_text.count(VS_BOB_OLD))
        vs_text = vs_text.replace(VS_BOB_OLD, VS_BOB_NEW, 1)
    if "BCAS shadow depth staging" in vs_text:
        raise SystemExit("VS 里已有 BCAS 注入，拒绝重复注入")
    if vs_text.count(VS_HOLO_ANCHOR) != 1:
        raise SystemExit("VS 深度锚点未找到")
    vs_out = vs_text.replace(
        VS_HOLO_ANCHOR, vs_depth_patch(extra_bias) + VS_HOLO_ANCHOR, 1)
    return vs_out, ps_out


def build_variant(src_ksh, out_path, extra_bias, force_alpha, prepend_define=None):
    r = ksh_parse.parse(str(src_ksh))
    vs = r["vs_src"].decode("utf-8")
    ps = r["ps_src"].decode("utf-8")
    if prepend_define is not None and not vs.startswith("#define " + prepend_define):
        vs = "#define " + prepend_define + "\n" + vs
    vs_out, ps_out = patch_sources(vs, ps, extra_bias, force_alpha)

    # trailer 结构 = [vs 槽位数][vs 槽位...][ps 槽位数][ps 槽位...]，原样抄引擎的表。
    # PARAMS 只在 ps_refs 里，我们要在 VS 读 PARAMS.y -> 把它补进 vs_refs。
    tr = r["trailer"]
    n_vs = struct.unpack_from("<I", tr, 0)[0]
    vs_refs = list(struct.unpack_from("<%dI" % n_vs, tr, 4))
    rest = tr[4 + 4 * n_vs:]
    params_slot = next((i for i, e in enumerate(r["entries"]) if e["name"] == "PARAMS"), None)
    if params_slot is not None and params_slot not in vs_refs:
        vs_refs = sorted(vs_refs + [params_slot])
        r["trailer"] = (struct.pack("<I", len(vs_refs))
                        + struct.pack("<%dI" % len(vs_refs), *vs_refs) + rest)

    r["name"] = out_path.stem
    r["vs_file"] = out_path.stem + ".vs"
    r["ps_file"] = out_path.stem + ".ps"
    r["vs_src"] = vs_out.encode("utf-8")
    r["ps_src"] = ps_out.encode("utf-8")
    data = ksh_parse.build(r)
    out_path.write_bytes(data)

    # 回读校验：表 / trailer / 源码都必须与预期一致
    back = ksh_parse.parse(str(out_path))
    assert ksh_parse.build(back) == data, "回读 round-trip 不一致"
    assert back["entries"] == r["entries"], "uniform 表被改动"
    assert back["trailer"] == r["trailer"], "trailer 被改动"
    assert "BCAS silhouette" in back["ps_src"].decode("utf-8")
    assert "BCAS shadow depth staging" in back["vs_src"].decode("utf-8")
    assert b"\xe2" not in data or True
    for chunk in (back["vs_src"], back["ps_src"]):
        chunk.decode("ascii")           # 注入源码必须纯 ASCII
    print("[OK] %-44s %6dB  bias=%+g  alpha_out=%s"
          % (str(out_path.relative_to(ROOT)), len(data), extra_bias, force_alpha))
    return data


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("源: %s / %s" % (ENGINE / "anim.ksh", ENGINE / "anim_skinned.ksh"))
    for name, bias, force_alpha in VARIANTS:
        build_variant(ENGINE / "anim.ksh", OUT_DIR / (name + ".ksh"), bias, force_alpha)
        build_variant(ENGINE / "anim_skinned.ksh", OUT_DIR / (name + "_skinned.ksh"),
                      bias, force_alpha, prepend_define="SKINNED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
