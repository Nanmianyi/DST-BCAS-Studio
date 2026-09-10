--[[ BCAS Studio —— 参数状态机

单一数据源：所有可调参数、预设、uniform 打包/下发、持久化。
在游戏全局环境运行（require 加载），直接使用引擎全局量。

四 pass 架构（2026-09 v2 起，管线顺序由用户拍板）：
    cinema(调色) -> studio(锐化+氛围) -> glow A(核心+中环) -> glow B(宽环+光晕)
    先调色再锐化：动态范围先稳定，锐化不被二次拉伸；颗粒在锐化后生成。
    辉光在链尾：作用于最终画面，辉光层本身永不被锐化或二次调色。
辉光金字塔（2026-09 v2，Kawase Bloom 变种）：
    引擎辉光缓冲(BloomSampler, Klei 按实体写入) ->
    软膝预滤(Unreal 二次曲线, 保色提取高光) -> 4 级 Kawase 双线性滤波
    (每级仅 4 taps, 步长 1/2/4/8, 全部 1/4 分辨率) ->
    合成 A(core+mid, 加法) -> 合成 B(wide+halo, 暖色偏移+呼吸微闪+
    Reinhard 高光压缩)。长尾衰减权重(扩散滑条可调)是柔和感的关键。
    原生 Bloom 接管（2026-09 v2）：开启我们辉光时经 SetBloomEnabled 关
    原生 + metatable 钩子压制引擎任何重开（设置变更/进世界），
    关闭我们时按玩家 Profile 的原生 Bloom 偏好恢复。
uniform 数量无 4 个限制（pxl_42 实测绑了 9 个，之前的断言是条目表
没同步导致的误判）。
]]

local State = {
    effect_id = nil,      -- studio（锐化）
    effect2_id = nil,     -- cinema（调色）
    glow_id = nil,        -- 辉光合成/金字塔挂载的目标 effect
    glow2_id = nil,       -- 已废弃：v3 单合成 pass（保留字段兼容存档诊断）
    merged_has_glow = false, -- merged 单 pass 是否已含辉光合成（bcas_merged_glow）
    glow_folded = false,  -- 辉光是否折叠进主 pass（true 时 glow_id == effect_id）
    merged_pass = false,  -- 实验开关：调色+锐化合并单 pass（MERGED_PASS modinfo）
    merged_id = nil,      -- 合并 pass 效果 id（实验成功时替代 cinema+studio）
    glow_samplers = nil,  -- 辉光金字塔 4 级 SamplerEffect id（诊断用）
    flicker = 1.0,        -- 光晕呼吸标量（Lua 8Hz 计算，BCAS_GLOW2.w）
    sun_u = 0.22,         -- 太阳屏幕 UV.x（cinema/glow 共用 BCAS_EXTRA.z）
    sun_v = 0.14,         -- 太阳屏幕 UV.y（BCAS_EXTRA.w）
    handles = {},         -- uniform 名 -> 句柄
    enabled = true,
    boot_preset = "standard",
    params = {},          -- 参数名 -> 数值
    saved_params = nil,   -- 面板打开时的快照（用于"放弃更改"）
    saved_enabled = true,
    ready = false,        -- shader 注册完成
    native_bloom_hooked = false, -- 原生 Bloom 开关接管钩子是否已安装
    vanilla_fx_hooked = false,   -- 原版滤镜接管钩子是否已安装（低SAN/失真/积雪/风沙）
    snow_map = nil,              -- 当前世界 Map 实例（积雪上限重放用）
    snow_last_level = nil,       -- 最近一次请求的积雪等级（重放用）
    cc_src0 = nil,               -- 官方环境色块最近一次 src（官方调色强度还原用）
    cc_dst0 = nil,               -- 官方环境色块最近一次 dst（同上）
    sandover_widgets = nil,      -- 风沙遮罩 widget 弱引用表（关闭时恢复可见）
    sanity_override = nil,       -- 上次应用的低SAN保色接管态（切换检测用）
    distort_override = nil,      -- 上次应用的失真消除接管态（切换检测用）
    cc_lerp0 = nil,              -- 最近一次环境色块混合 lerp（官方调色强度重放用）
    mod_addprefabpostinit = nil, -- modutil 注入模组环境的 AddPrefabPostInit（modmain 传入）
    mod_addclasspostconstruct = nil, -- 同上 AddClassPostConstruct
    snow_hook_print = false,     -- 积雪钩子首次挂载日志（一次性）
    sand_hook_print = false,     -- 风沙钩子首次挂载日志（一次性）
}

local SAVE_FILE = "bcas_studio"

-- 参数元数据：uniform 打包位置 + 滑条范围 + 默认值（缺省 = 旧 fx 实测值）
-- comp 对应 SetUniformVariable(handle, x, y, z, w) 的第几个分量
-- uniform = nil 的参数不下发着色器（如 ColourCubeOn，走引擎开关）
local VEC = {
    -- == 锐化核心 (studio / BCAS_SHARPEN) ==
    Strength    = {uniform = "BCAS_SHARPEN", comp = 1, min = 0,    max = 8,    default = 7.8},
    NoiseReduce = {uniform = "BCAS_SHARPEN", comp = 2, min = 0,    max = 1,    default = 0.67},
    AntiRinging = {uniform = "BCAS_SHARPEN", comp = 3, min = 0,    max = 1,    default = 0.89},
    DarkProtect = {uniform = "BCAS_SHARPEN", comp = 4, min = 0,    max = 1,    default = 0.25},

    -- == 逆卷积墨线收敛 (studio / BCAS_DECONV) ==
    DeconvStrength = {uniform = "BCAS_DECONV", comp = 1, min = 0,    max = 2.0,  default = 1.89},
    DeconvGate     = {uniform = "BCAS_DECONV", comp = 2, min = 0.01, max = 0.08, default = 0.025},
    DeconvPenetr   = {uniform = "BCAS_DECONV", comp = 3, min = 0,    max = 1.0,  default = 0.80},

    -- == 锐化进阶 (studio / BCAS_SHARP2) ==
    RangeSigma   = {uniform = "BCAS_SHARP2", comp = 1, min = 0.01, max = 2,    default = 0.26},
    SpatialSigma = {uniform = "BCAS_SHARP2", comp = 2, min = 0,    max = 4,    default = 1.10},
    CenterWeight = {uniform = "BCAS_SHARP2", comp = 3, min = 0,    max = 4,    default = 1.0},
    NoiseFloor   = {uniform = "BCAS_SHARP2", comp = 4, min = 0,    max = 0.05, default = 0.01},

    -- == AURA 抗过冲 (studio / BCAS_AURA) ==
    AR_Threshold  = {uniform = "BCAS_AURA", comp = 1, min = 0,     max = 0.02, default = 0.0},
    AR_L_Overshoot= {uniform = "BCAS_AURA", comp = 2, min = 0.001, max = 0.1,  default = 0.001},
    AR_D_Overshoot= {uniform = "BCAS_AURA", comp = 3, min = 0.001, max = 0.1,  default = 0.001},
    ChromaProtect = {uniform = "BCAS_AURA", comp = 4, min = 0,     max = 1,    default = 1.0},

    -- == 色彩基础 (cinema / BCAS_GRADE_A/B/EXTRA) ==
    ExposureEV  = {uniform = "BCAS_GRADE_A", comp = 1, min = -2,   max = 2,    default = 0.06},
    Temp        = {uniform = "BCAS_GRADE_A", comp = 2, min = -1,   max = 1,    default = 0.40},
    Tint        = {uniform = "BCAS_GRADE_A", comp = 3, min = -1,   max = 1,    default = -0.11},
    Saturation  = {uniform = "BCAS_GRADE_A", comp = 4, min = 0,    max = 2,    default = 0.988},
    Vibrance    = {uniform = "BCAS_GRADE_B", comp = 1, min = -1,   max = 1,    default = 0.27},
    Contrast    = {uniform = "BCAS_GRADE_B", comp = 2, min = -0.5, max = 1,    default = 0.03},
    Lightness   = {uniform = "BCAS_GRADE_B", comp = 3, min = -0.3, max = 0.3,  default = 0},
    Gamma       = {uniform = "BCAS_GRADE_B", comp = 4, min = 0.5,  max = 2,    default = 1.0},
    Filmic      = {uniform = "BCAS_EXTRA",   comp = 1, min = 0,    max = 1,    default = 0.32},
    SunFill     = {uniform = "BCAS_EXTRA",   comp = 2, min = 0,    max = 1,    default = 0.75},

    -- == 氛围 (studio / BCAS_ATMO) ==
    Vignette    = {uniform = "BCAS_ATMO",    comp = 1, min = 0,    max = 1,    default = 0},
    Grain       = {uniform = "BCAS_ATMO",    comp = 2, min = 0,    max = 1,    default = 0},
    -- BCAS_ATMO.z = TIME，由 modmain 的 8Hz 任务动画驱动，不是参数

    -- == CDL 一级 (cinema / BCAS_CDL_S/O/P) ==
    SlopeR   = {uniform = "BCAS_CDL_S", comp = 1, min = 0,   max = 4, default = 1.0},
    SlopeG   = {uniform = "BCAS_CDL_S", comp = 2, min = 0,   max = 4, default = 1.0},
    SlopeB   = {uniform = "BCAS_CDL_S", comp = 3, min = 0,   max = 4, default = 1.0},
    SecOn    = {uniform = "BCAS_CDL_S", comp = 4, min = 0,   max = 1, default = 0},
    OffsetR  = {uniform = "BCAS_CDL_O", comp = 1, min = -1,  max = 1, default = 0},
    OffsetG  = {uniform = "BCAS_CDL_O", comp = 2, min = -1,  max = 1, default = 0},
    OffsetB  = {uniform = "BCAS_CDL_O", comp = 3, min = -1,  max = 1, default = 0},
    HL_Desat = {uniform = "BCAS_CDL_O", comp = 4, min = 0,   max = 1, default = 0.41},
    PowerR   = {uniform = "BCAS_CDL_P", comp = 1, min = 0.1, max = 4, default = 1.0},
    PowerG   = {uniform = "BCAS_CDL_P", comp = 2, min = 0.1, max = 4, default = 1.0},
    PowerB   = {uniform = "BCAS_CDL_P", comp = 3, min = 0.1, max = 4, default = 1.0},

    -- == CDL 二级 (cinema / BCAS_SEC_S/O/P) ==
    SecSlopeR  = {uniform = "BCAS_SEC_S", comp = 1, min = 0,   max = 4, default = 1.0},
    SecSlopeG  = {uniform = "BCAS_SEC_S", comp = 2, min = 0,   max = 4, default = 1.0},
    SecSlopeB  = {uniform = "BCAS_SEC_S", comp = 3, min = 0,   max = 4, default = 1.0},
    SecOffsetR = {uniform = "BCAS_SEC_O", comp = 1, min = -1,  max = 1, default = 0},
    SecOffsetG = {uniform = "BCAS_SEC_O", comp = 2, min = -1,  max = 1, default = 0},
    SecOffsetB = {uniform = "BCAS_SEC_O", comp = 3, min = -1,  max = 1, default = 0},
    OriginalMix= {uniform = "BCAS_SEC_O", comp = 4, min = 0,   max = 1, default = 0.10},
    SecPowerR  = {uniform = "BCAS_SEC_P", comp = 1, min = 0.1, max = 4, default = 1.0},
    SecPowerG  = {uniform = "BCAS_SEC_P", comp = 2, min = 0.1, max = 4, default = 1.0},
    SecPowerB  = {uniform = "BCAS_SEC_P", comp = 3, min = 0.1, max = 4, default = 1.0},

    -- == 辉光 Bloom (glow A/B / BCAS_GLOW + BCAS_GLOW2) ==
    -- 辉光源 = 引擎辉光缓冲（Klei 按实体写入：萤火虫/火堆/灯笼…会发光），
    -- 本组参数只修饰与合成，不决定谁发光。
    -- 金字塔模型（Kawase 1/2/4/8）：软膝预滤只让真光源通过，四层模糊
    -- 按长尾权重叠加，B 合成收尾做暖色偏移 + Reinhard 高光压缩。
    -- 发布默认（楠眠已实机调校 2026-09）：强度拉满 4.0 + 阈值几乎不过滤
    -- （0.04）+ 全暖全饱和 + 关闭高光压缩 = 又亮又暖的柔光。
    GlowIntensity = {uniform = "BCAS_GLOW",  comp = 1, min = 0, max = 4,   default = 1.20},
    GlowThreshold = {uniform = "BCAS_GLOW",  comp = 2, min = 0, max = 1,   default = 0.04},
    GlowKnee      = {uniform = "BCAS_GLOW",  comp = 3, min = 0.05, max = 1, default = 1.00},
    GlowWarmth    = {uniform = "BCAS_GLOW",  comp = 4, min = -1, max = 1, default = 1.00},
    GlowSpread    = {uniform = "BCAS_GLOW2", comp = 1, min = 0, max = 1, default = 1.00},
    GlowSat       = {uniform = "BCAS_GLOW2", comp = 2, min = 0, max = 1, default = 1.0},
    GlowCompress  = {uniform = "BCAS_GLOW2", comp = 3, min = 0, max = 0.5, default = 0.03},

    -- == 引擎开关（不占 uniform）==
    -- 昼夜滤镜：预设不接管（见 PRESET_NEUTRAL），R 回归 = 原版开
    ColourCubeOn = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},
    BloomOn      = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},

    -- == 原版滤镜接管（滤镜RR 3115280970 移植，引擎开关型，不占 uniform）==
    -- 低SAN保色：低精神值不再黑白化（只压精神色块通道混合，不碰环境色块）
    SanityColourOn = {uniform = nil, comp = 0, min = 0, max = 1, default = 0},
    -- 失真消除：关掉精神值屏幕晃动（DISTORTION_FACTOR=1 = shader 里取原图）
    DistortFree    = {uniform = nil, comp = 0, min = 0, max = 1, default = 0},
    -- 积雪上限：0=无雪（RR 默认）0.6=有点积雪 3=原版，中间值自由截断
    SnowCap        = {uniform = nil, comp = 0, min = 0, max = 3, default = 0.64},
    -- 过滤风沙：藏起沙尘暴全屏遮罩（含沙尘层）
    SandFilter     = {uniform = nil, comp = 0, min = 0, max = 1, default = 0},
    -- 官方调色强度：复用官方季节/昼夜 LUT 调教，只缩放混合强度
    -- （0=完全原色 ~ 1=官方原版，包装器按此缩放 SetColourCubeLerp(0,·)）
    VanillaGrade   = {uniform = nil, comp = 0, min = 0, max = 1, default = 0.73},

    -- == 光影科学 v3.2（BCAS_GLOW3，glow 合成 pass）==
    -- 光晕长尾：光晕最外层四阶抬升，辉光向夜空长尾消散而非数码截断
    GlowTail   = {uniform = "BCAS_GLOW3", comp = 1, min = 0, max = 1,   default = 1.0},
    -- 光包裹：暖光晕按暗部掩码沁入阴影（空气散射，软化光圈硬边）
    LightWrap  = {uniform = "BCAS_GLOW3", comp = 2, min = 0, max = 1,   default = 1.0},
    -- 轮廓光：光照附近的几何边缘勾 1-2px 暖亮边（halo 门控，远处不勾）
    GlowRim    = {uniform = "BCAS_GLOW3", comp = 3, min = 0, max = 1,   default = 0.05},
    -- 空气光束：沿太阳方向拉辉光层，形成空气里的斜向光柱
    GodRays    = {uniform = "BCAS_GLOW3", comp = 4, min = 0, max = 2.0, default = 1.0},

    -- == 增强功能独立总控开关 (不占uniform) ==
    ShadowsOn  = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},
    OceanOn    = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},
    LightingMaster = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},

    -- == 海面波光 (bcas_glint；非后处理参数，uniform 字段仅作面板标记，
    --    实际由 bcas_glint 每帧读取并 SetFloatParams/SetOceanBlendParams/
    --    SetMultColour 下发；程序化 caustics 光网 + 离岸深度过渡) ==
    GlintOn       = {uniform = "GLINT", comp = 0, min = 0,    max = 1,     default = 1},
    -- 强度：叠加层不透明度/亮度，<1 时金色波光半透明能透出底下水色
    GlintStrength = {uniform = "GLINT", comp = 1, min = 0,    max = 2,     default = 0.33},
    -- 增益：caustics 光网亮度（0.93 = 原模组 *10 的精确值）
    GlintDensity  = {uniform = "GLINT", comp = 2, min = 0.80, max = 0.998, default = 0.99},
    -- 颗粒：caustics 频率倍率，越大光网越细碎
    GlintGrain    = {uniform = "GLINT", comp = 3, min = 0.4,  max = 2.5,   default = 0.74},
    -- 海色融合：把金色与原版海水颜色混合的量，越大越像真实水下沙地
    GlintSoft     = {uniform = "GLINT", comp = 4, min = 0,    max = 1,     default = 1.0},
}
State.VEC = VEC


-- 各效果绑定的 uniform 名（SetEffectUniformVariables 顺序）
-- 渲染顺序：cinema(调色, pass1) -> studio(锐化+氛围, pass2)
local EFFECT_UNIFORMS = {
    cinema = {
        "BCAS_GRADE_A", "BCAS_GRADE_B", "BCAS_EXTRA",
        "BCAS_CDL_S", "BCAS_CDL_O", "BCAS_CDL_P",
        "BCAS_SEC_S", "BCAS_SEC_O", "BCAS_SEC_P",
    },
    studio = {"BCAS_SHARPEN", "BCAS_SHARP2", "BCAS_AURA", "BCAS_ATMO", "BCAS_DECONV"},
    merged = {
        "BCAS_SHARPEN", "BCAS_SHARP2", "BCAS_AURA", "BCAS_ATMO", "BCAS_DECONV",
        "BCAS_GRADE_A", "BCAS_GRADE_B", "BCAS_EXTRA",
        "BCAS_CDL_S", "BCAS_CDL_O", "BCAS_CDL_P",
        "BCAS_SEC_S", "BCAS_SEC_O", "BCAS_SEC_P",
        -- SCREEN_PARAMS 不绑（同 studio）：引擎对这一魔法名自动按 RT 填充；
        -- Lua 侧 AddUniformVariable 再绑一层会每帧被 ApplyAll 覆写成 0。
    },
    -- 折叠 pass（grade+sharpen+bloom 单 pass）：条目顺序必须与 ksh 一致
    merged_glow = {
        "BCAS_SHARPEN", "BCAS_SHARP2", "BCAS_AURA", "BCAS_ATMO", "BCAS_DECONV",
        "BCAS_GRADE_A", "BCAS_GRADE_B", "BCAS_EXTRA",
        "BCAS_CDL_S", "BCAS_CDL_O", "BCAS_CDL_P",
        "BCAS_SEC_S", "BCAS_SEC_O", "BCAS_SEC_P",
        "BCAS_GLOW", "BCAS_GLOW2", "BCAS_GLOW3",
    },
    glow = {"BCAS_GLOW", "BCAS_GLOW2", "BCAS_GLOW3", "BCAS_EXTRA", "SCREEN_PARAMS"},
}

-- 白平衡 RGB 增益（调色窗虚拟旋钮）：不占 uniform，数学映射到 Temp/Tint。
-- 着色器模型: r=2^(0.2T) b=2^(-0.2T) g=2^(0.12Ti)，归一化不影响通道比值。
function State.GainToTempTint(r, g, b)
    local T = math.clamp(math.log(math.max(r, 0.05) / math.max(b, 0.05)) / (0.4 * math.log(2)), -1, 1)
    local Ti = math.clamp(math.log(math.max(g, 0.05) / math.sqrt(math.max(r, 0.05) * math.max(b, 0.05))) / (0.12 * math.log(2)), -1, 1)
    return T, Ti
end

local PRESETS = {
    -- 作者特调（楠眠实机调校 2026-09-11 定版，按面板逐页截图基准）
    standard = {
        ShadowsOn = 1, OceanOn = 1, LightingMaster = 1,
        -- 01 锐化
        Strength = 7.80, DeconvStrength = 1.89, NoiseReduce = 0.67, AntiRinging = 0.89, DarkProtect = 0.25,
        DeconvGate = 0.025, DeconvPenetr = 0.80,
        -- 02 进阶
        RangeSigma = 0.26, SpatialSigma = 1.10, CenterWeight = 1.0, NoiseFloor = 0.01,
        AR_Threshold = 0.0, AR_L_Overshoot = 0.0, AR_D_Overshoot = 0.0, ChromaProtect = 1.0,
        -- 03 色彩（白平衡轮 #FFEFE4 = Temp 0.40 / Tint -0.11）
        ExposureEV = 0.06, Temp = 0.40, Tint = -0.11, Saturation = 0.99,
        Vibrance = 0.27, Contrast = 0.03, Lightness = 0, Gamma = 1.0,
        Filmic = 0.32, HL_Desat = 0.41, OriginalMix = 0.10,
        -- 04 调色 CDL 一级
        SlopeR = 0.94, SlopeG = 1.0, SlopeB = 1.0,
        OffsetR = 0, OffsetG = 0, OffsetB = 0,
        PowerR = 1.0, PowerG = 1.0, PowerB = 1.0,
        -- 05 氛围
        Vignette = 0, Grain = 0.06,
        SanityColourOn = 0, DistortFree = 0, SnowCap = 0.64, SandFilter = 0,
        VanillaGrade = 0.73,
        -- 06 辉光
        GlowIntensity = 1.20, GlowThreshold = 0.04, GlowKnee = 1.00,
        GlowSpread = 1.00, GlowWarmth = 1.00, GlowSat = 1.0, GlowCompress = 0.03,
        BloomOn = 1,
        -- 07 光影
        GlowTail = 1.00, LightWrap = 1.00, GlowRim = 0.05, GodRays = 2.0, SunFill = 1.0,
        -- 08 水面
        GlintOn = 1, GlintStrength = 0.33, GlintDensity = 0.99, GlintGrain = 0.74, GlintSoft = 1.00,
    },
    -- 轻量画质：作者特调的收敛版（低配 / 长时间游玩），保留同一色彩基调
    light = {
        ShadowsOn = 1, OceanOn = 1, LightingMaster = 1,
        Strength = 5.00, DeconvStrength = 0.90, NoiseReduce = 0.50, AntiRinging = 0.70, DarkProtect = 0.15,
        DeconvGate = 0.025, DeconvPenetr = 0.75,
        RangeSigma = 0.26, SpatialSigma = 1.10, CenterWeight = 1.0, NoiseFloor = 0.012,
        AR_Threshold = 0.0, AR_L_Overshoot = 0.0, AR_D_Overshoot = 0.0, ChromaProtect = 0.70,
        ExposureEV = 0.06, Temp = 0.40, Tint = -0.11, Saturation = 0.99,
        Vibrance = 0.18, Contrast = 0.02, Lightness = 0, Gamma = 1.0,
        Filmic = 0.22, HL_Desat = 0.30, OriginalMix = 0.12,
        SlopeR = 0.96, SlopeG = 1.0, SlopeB = 1.0,
        OffsetR = 0, OffsetG = 0, OffsetB = 0,
        PowerR = 1.0, PowerG = 1.0, PowerB = 1.0,
        Vignette = 0, Grain = 0.04,
        SanityColourOn = 0, DistortFree = 0, SnowCap = 0.64, SandFilter = 0,
        VanillaGrade = 0.80,
        GlowIntensity = 0.90, GlowThreshold = 0.06, GlowKnee = 0.90,
        GlowSpread = 0.90, GlowWarmth = 0.90, GlowSat = 1.0, GlowCompress = 0.05,
        BloomOn = 1,
        GlowTail = 0.80, LightWrap = 0.80, GlowRim = 0.03, GodRays = 1.20, SunFill = 0.90,
        GlintOn = 1, GlintStrength = 0.28, GlintDensity = 0.99, GlintGrain = 0.74, GlintSoft = 1.00,
    },
    -- 电影胶片：作者特调的加重版（截图 / 录视频），暖调、暗角、颗粒、重辉光
    cinema = {
        ShadowsOn = 1, OceanOn = 1, LightingMaster = 1,
        Strength = 7.00, DeconvStrength = 1.50, NoiseReduce = 0.70, AntiRinging = 0.80, DarkProtect = 0.20,
        DeconvGate = 0.025, DeconvPenetr = 0.85,
        RangeSigma = 0.26, SpatialSigma = 1.10, CenterWeight = 1.0, NoiseFloor = 0.01,
        AR_Threshold = 0.0, AR_L_Overshoot = 0.0, AR_D_Overshoot = 0.0, ChromaProtect = 0.80,
        ExposureEV = 0.10, Temp = 0.42, Tint = -0.10, Saturation = 0.95,
        Vibrance = 0.30, Contrast = 0.06, Lightness = -0.01, Gamma = 0.98,
        Filmic = 0.55, HL_Desat = 0.45, OriginalMix = 0.04,
        SlopeR = 0.92, SlopeG = 0.99, SlopeB = 1.0,
        OffsetR = 0, OffsetG = 0, OffsetB = 0,
        PowerR = 1.0, PowerG = 1.0, PowerB = 1.0,
        Vignette = 0.20, Grain = 0.12,
        SanityColourOn = 0, DistortFree = 0, SnowCap = 0.50, SandFilter = 0,
        VanillaGrade = 0.60,
        GlowIntensity = 1.60, GlowThreshold = 0.04, GlowKnee = 1.00,
        GlowSpread = 1.00, GlowWarmth = 1.00, GlowSat = 1.0, GlowCompress = 0.08,
        BloomOn = 1,
        GlowTail = 1.00, LightWrap = 1.00, GlowRim = 0.08, GodRays = 2.0, SunFill = 1.0,
        GlintOn = 1, GlintStrength = 0.40, GlintDensity = 0.99, GlintGrain = 0.74, GlintSoft = 1.00,
    },
    off = {
        ShadowsOn = 0, OceanOn = 0, LightingMaster = 0, GlintOn = 0,
        Strength = 0, NoiseReduce = 0, AntiRinging = 0, DarkProtect = 0,
        ExposureEV = 0, Temp = 0, Tint = 0, Saturation = 1.0,
        Vibrance = 0, Contrast = 0, Lightness = 0, Gamma = 1.0,
        Vignette = 0, Grain = 0, Filmic = 0, SunFill = 0,

        HL_Desat = 0, OriginalMix = 0, ColourCubeOn = 1,
        GlowIntensity = 0, GlowThreshold = 0.45, GlowKnee = 0.5,
        GlowSpread = 1.0, GlowWarmth = 0, GlowSat = 0.85, GlowCompress = 0,
        BloomOn = 0,
        SanityColourOn = 0, DistortFree = 0, SnowCap = 3, SandFilter = 0,
        VanillaGrade = 1, GlowTail = 0, LightWrap = 0, GlowRim = 0, GodRays = 0,
        DeconvStrength = 0, DeconvGate = 0.025, DeconvPenetr = 0,
    },
}
State.PRESETS = PRESETS

-- ==========================================================================
-- 内部
-- ==========================================================================

function State.PackUniform(uniform)
    local v = {0, 0, 0, 0}
    for key, meta in pairs(VEC) do
        if meta.uniform == uniform then
            v[meta.comp] = State.params[key]
        end
    end
    -- BCAS_GLOW2.w = 光晕呼吸标量（非用户参数，Lua 8Hz 任务计算）。
    -- 打进打包逻辑后，参数改动（SetParam/ApplyAll）下发时永远带着
    -- 当前呼吸值，光晕不会在参数刷新瞬间熄灭。
    if uniform == "BCAS_GLOW2" then
        v[4] = State.flicker or 1.0
    end
    -- 折叠模式：辉光合成在主 pass 里，关辉光不能靠禁用 effect（会连调色锐化
    -- 一起关），改为把强度归零。
    if uniform == "BCAS_GLOW" then
        local bloom_on = State.enabled ~= false and (State.params.BloomOn or 0) > 0.5
        if State.glow_folded and not bloom_on then
            v[1] = 0.0
        end
    end
    if uniform == "BCAS_EXTRA" then
        v[3] = State.sun_u or 0.22
        v[4] = State.sun_v or 0.14
        if _G.TheWorld and _G.TheWorld:HasTag("cave") then
            v[2] = 0.0
        end
    end
    -- Water sun-glitter rides BCAS_GLOW3.w: zero it when the ocean look is
    -- off so the panel toggle is a real live A/B (waves sparkle off instantly).
    if uniform == "BCAS_GLOW3" then
        local ocean_on = State.enabled ~= false
            and (State.params.OceanOn or 1) > 0.5
        if not ocean_on then
            v[4] = 0.0
        end
    end
    return v
end

function State.ApplyUniform(uniform)
    local h = State.handles[uniform]
    if State.handles[uniform] == nil then return end
    local v = State.PackUniform(uniform)
    PostProcessor:SetUniformVariable(h, v[1], v[2], v[3], v[4])
end

function State.ApplyAll()
    if State.effect_id == nil then return end
    for _, group in pairs(EFFECT_UNIFORMS) do
        for _, name in ipairs(group) do
            State.ApplyUniform(name)
        end
    end
end

-- 原版昼夜滤镜开关（对齐 pxl_42 的做法：直接开关引擎的 ColourCube 效果）
function State.ApplyEnhancements()
    local SunSystem = _G.package.loaded["bcas_sun_emitter"]
    if SunSystem == nil then return end
    local master = State.enabled ~= false
    if SunSystem.SetMasterEnabled ~= nil then
        if State.LightingHardOff then
            -- mod 配置 LIGHTING=off 是硬关断：预设/存档/面板都压不过它，
            -- 面板行被同步压回 OFF，视觉与实际一致
            State.params.LightingMaster = 0
            SunSystem.SetMasterEnabled(false)
        else
            SunSystem.SetMasterEnabled((State.params.LightingMaster or 1) > 0.5)
        end
    end
    if SunSystem.SetShadowsEnabled ~= nil then
        SunSystem.SetShadowsEnabled(master and (State.params.ShadowsOn or 1) > 0.5)
    end
    if SunSystem.SetOceanEnabled ~= nil then
        SunSystem.SetOceanEnabled(master and (State.params.OceanOn or 1) > 0.5)
    end
    if SunSystem.SetShaftsAmount ~= nil then
        local amt = master and (State.params.GodRays or 0) or 0
        SunSystem.SetShaftsAmount(amt)
    end
end

function State.ApplyColourCube()
    if PostProcessor == nil then return end
    local on = (State.params.ColourCubeOn or 1) > 0.5
    if PostProcessorEffects ~= nil and PostProcessorEffects.ColourCube ~= nil then
        PostProcessor:EnablePostProcessEffect(PostProcessorEffects.ColourCube, on)
    end
end

-- ==========================================================================
-- 原版滤镜接管（滤镜RR 3115280970 移植，2026-09）
-- 四个实时开关：低SAN保色 / 失真消除 / 积雪上限 / 过滤风沙。
-- 与 RR 的差异：RR 是启动配置（一次性把引擎方法 null 掉、不可逆），我们
-- 全部做成可逆包装——开关开时压参数，关时原样放行并主动重放一次原版
-- 状态，保证面板里拨一下立刻生效、立刻还原。
-- ==========================================================================

-- 重放精神值事件：原版 colourcube 组件的 OnSanityDelta 会按当前 sanity
-- 重算"精神色块混合 lerp + 失真系数"（组件只读 replica 值，不读 data
-- 字段），我们伪造一个与真实事件同形的 sanitydelta 触发它——关闭我们
-- 的开关后原版黑白/失真立刻回到应有状态。
-- ⚠ 数据形状必须与 sanity.lua:405 完全一致：oldpercent/newpercent/
-- overtime/sanitymode 一个都不能少——HUD 精神徽章(statusdisplays)会做
-- newpercent>oldpercent 比较，缺字段直接 "attempt to compare nil with
-- number" 崩溃（2026-09 实测，游戏 Force aborting）。
-- new==old 保证不触发脉冲/音效；percent<=0 时不发：wx78 占据体
-- (possessedbody) 会把 newpercent==0 当精神死亡直接 Kill 玩家。
function State.RefreshSanityFX()
    local p = ThePlayer
    if p == nil or p.replica == nil or p.replica.sanity == nil then return end
    local percent = p.replica.sanity:GetPercent()
    if percent == nil or percent <= 0 then return end
    p:PushEvent("sanitydelta", {
        oldpercent = percent,
        newpercent = percent,
        overtime = false,
        sanitymode = p.replica.sanity:GetSanityMode(),
    })
end

-- 按当前参数立即应用/还原四个开关（SetParam/预设/进世界统一走这里）
function State.ApplyVanillaFilters()
    if PostProcessor == nil then return end
    local sanity_on = (State.params.SanityColourOn or 0) > 0.5
    local distort_on = (State.params.DistortFree or 0) > 0.5
    -- 低SAN保色：精神色块通道（index 1）混合恒 0 = 不黑白；钩子负责持续压制
    if sanity_on then
        PostProcessor:SetColourCubeLerp(1, 0)
    end
    -- 官方调色强度：重放"色块数据 + 混合"。数据重放让包装器按当前强度
    -- 把通道 0 的 src 换成 identity（强度=1 时还原官方 src/dst 对），
    -- 混合重放按当前强度缩放 lerp。官方过渡动画仍在引擎手里。
    if State.cc_dst0 ~= nil then
        PostProcessor:SetColourCubeData(0, State.cc_src0, State.cc_dst0)
    end
    PostProcessor:SetColourCubeLerp(0, State.cc_lerp0 ~= nil and State.cc_lerp0 or 1)
    -- 失真消除：DISTORTION_FACTOR=1 在 distort shader 里 = 完全取原图
    -- （mix(distorted, base, 1)）；原版低 SAN 时 factor 才会往 0 压（最晃）。
    if distort_on then
        PostProcessor:SetDistortionFactor(1)
    end
    -- 积雪：按新上限重放最近一次请求的积雪等级（走包装后的 SetOverlayLerp，
    -- 自动按 SnowCap 截断）；world 尚未生成时跳过，天气系统下次更新自然生效
    if State.snow_map ~= nil and State.snow_last_level ~= nil then
        local mmt = getmetatable(State.snow_map)
        local midx = mmt and mmt.__index
        if midx ~= nil and type(midx.SetOverlayLerp) == "function" then
            midx.SetOverlayLerp(State.snow_map, State.snow_last_level)
        end
    end
    -- 风沙：开=每帧藏（OnUpdate 钩子），关=把还记着"该显示"的遮罩拉回可见
    if (State.params.SandFilter or 0) <= 0.5 and State.sandover_widgets ~= nil then
        for w in pairs(State.sandover_widgets) do
            if w.shown and w.inst ~= nil and w.inst.entity ~= nil then
                w:Show()
            end
        end
    end
    -- 只有"接管 -> 放行"的状态切换才重放原版状态（黑白/失真即时还原）。
    -- 重复调用（Reassert/进世界/读档）不重放：原版组件在 playeractivated
    -- 时会自己刷新，且伪造事件有被其他监听者当真实事件处理的边角风险
    -- （2026-09 曾因 Reassert 每 3 秒重放把 HUD 徽章打崩，实测）。
    local need_refresh = (State.sanity_override and not sanity_on)
        or (State.distort_override and not distort_on)
    State.sanity_override = sanity_on
    State.distort_override = distort_on
    if need_refresh then
        State.RefreshSanityFX()
    end
end

-- modutil.lua 把 AddPrefabPostInit / AddClassPostConstruct 注入到"模组
-- 环境"（env.xxx），不是游戏全局——bcas_state 经 require 加载运行在游戏
-- 全局的严格环境里，rawget(_G, ...) 永远拿不到它们（2026-09 实测：
-- 四个开关"积雪/风沙"静默失效的根因，日志里那句"已接管"是假象）。
-- 必须由 modmain 加载时经本函数把两个函数显式传进来。
function State.ProvideModHooks(add_prefab_postinit, add_class_postconstruct)
    State.mod_addprefabpostinit = add_prefab_postinit
    State.mod_addclasspostconstruct = add_class_postconstruct
end

-- 一次性安装全部钩子（幂等；modmain 顶层 + InitShader 各调一次兜底）
function State.HookVanillaFilters()
    if State.vanilla_fx_hooked then return true end
    if PostProcessor == nil then return false end
    local pp_ok = true
    local mt = getmetatable(PostProcessor)
    local idx = mt and mt.__index
    if type(idx) ~= "table" then
        print("[BCAS] 警告：原版滤镜接管钩子失败（PostProcessor metatable 结构异常）")
        return false
    end

    -- 低SAN保色（index 1：精神色块混合压 0）+ 官方调色强度（index 0）。
    -- ⚠ 官方调色强度的正确语义（2026-09 踩坑）：绝不能在 src/dst 的
    -- lerp 上做乘法——原版 colourcube 组件在季节过渡结束后会把通道 0
    -- 的 src/dst 永远留在"上一季 → 本季"这对 LUT 上，全靠 lerp=1 压住
    -- 上一季。压 lerp = 上一季 LUT 复活混入画面（夏天=暖红、冬天=发灰，
    -- 用户实测"一调就变红"）。正确做法：强度 <1 时把 src 换成 identity
    -- LUT——混合语义变成"无调色 ↔ 官方当前 LUT"，lerp 再乘强度即得
    -- 官方调教的可调强度；=1 时原样放行，完全等价原版。
    if type(idx.SetColourCubeLerp) == "function" then
        local orig = idx.SetColourCubeLerp
        idx.SetColourCubeLerp = function(self, index, lerp, ...)
            if index == 0 then
                State.cc_lerp0 = lerp
                lerp = lerp * (State.params.VanillaGrade ~= nil and State.params.VanillaGrade or 1)
            elseif index == 1 and (State.params.SanityColourOn or 0) > 0.5 then
                lerp = 0
            end
            return orig(self, index, lerp, ...)
        end
    else
        pp_ok = false
    end
    if type(idx.SetColourCubeData) == "function" then
        local orig = idx.SetColourCubeData
        idx.SetColourCubeData = function(self, index, src, dest)
            if index == 0 then
                State.cc_src0 = src
                State.cc_dst0 = dest
                if (State.params.VanillaGrade ~= nil and State.params.VanillaGrade or 1) < 1 then
                    src = "images/colour_cubes/identity_colourcube.tex"
                end
            end
            return orig(self, index, src, dest)
        end
    else
        pp_ok = false
    end

    -- 失真消除：factor=1 = 取原图（原版低 SAN 才会往 0 压）
    if type(idx.SetDistortionFactor) == "function" then
        local orig = idx.SetDistortionFactor
        idx.SetDistortionFactor = function(self, factor, ...)
            if (State.params.DistortFree or 0) > 0.5 then
                factor = 1
            end
            return orig(self, factor, ...)
        end
    else
        pp_ok = false
    end

    -- 风沙遮罩：原版 OnUpdate 跑完再藏一层，仅开关打开时生效。
    -- 函数经 State.ProvideModHooks 从 modmain 传入（env 注入函数，
    -- 游戏全局里不存在——见 ProvideModHooks 注释）。
    State.sandover_widgets = setmetatable({}, {__mode = "k"})
    local cpc = State.mod_addclasspostconstruct
    local sand_ok = type(cpc) == "function"
    if sand_ok then
        cpc("widgets/sandover", function(w)
            if not State.sand_hook_print then
                State.sand_hook_print = true
                print("[BCAS] 风沙钩子：sandover 遮罩已挂载")
            end
            State.sandover_widgets[w] = true
            local OnUpdate_old = w.OnUpdate
            if OnUpdate_old ~= nil then
                w.OnUpdate = function(self, ...)
                    OnUpdate_old(self, ...)
                    if (State.params.SandFilter or 0) > 0.5 then
                        if self.shown and self.inst ~= nil and self.inst.entity ~= nil then
                            self.inst.entity:Hide(false)
                        end
                        if self.dust ~= nil and self.dust.shown and self.dust.inst ~= nil and self.dust.inst.entity ~= nil then
                            self.dust.inst.entity:Hide(false)
                        end
                    end
                end
            end
        end)
    end

    -- 积雪上限：world 生成时包 Map.SetOverlayLerp。Map 的 metatable __index
    -- 全实例共用，只包一次（_bcas_snow_orig 标记）；每进世界刷新
    -- State.snow_map，包装闭包内比较实例、截断超上限等级。
    local ppi = State.mod_addprefabpostinit
    local snow_ok = type(ppi) == "function"
    if snow_ok then
        ppi("world", function(inst)
            local map = inst.Map
            if map == nil then return end
            State.snow_map = map
            local mmt = getmetatable(map)
            local midx = mmt and mmt.__index
            if midx == nil or type(midx.SetOverlayLerp) ~= "function" then
                print("[BCAS] 警告：Map.SetOverlayLerp 未找到，积雪过滤不可用")
                return
            end
            if not State.snow_hook_print then
                State.snow_hook_print = true
                print("[BCAS] 积雪钩子：world Map.SetOverlayLerp 已接管")
            end
            if midx._bcas_snow_orig == nil then
                local orig = midx.SetOverlayLerp
                midx._bcas_snow_orig = orig
                midx.SetOverlayLerp = function(somemap, level, ...)
                    if somemap == State.snow_map then
                        State.snow_last_level = level
                        if (State.params.SnowCap or 3) < 3 then
                            level = math.min(level, State.params.SnowCap)
                        end
                    end
                    return midx._bcas_snow_orig(somemap, level, ...)
                end
            end
        end)
    end

    State.vanilla_fx_hooked = true
    print("[BCAS] 原版滤镜接管结果: PP包装=" .. tostring(pp_ok)
        .. " 积雪钩子=" .. tostring(snow_ok) .. " 风沙钩子=" .. tostring(sand_ok))
    return pp_ok and snow_ok and sand_ok
end

-- 我们是否正在接管辉光（ApplyBloom 与原生开关钩子的共用判定）。
-- 有效开关 = BCAS 总开关 AND BloomOn AND 辉光链注册成功。
function State.GlowOverrideActive()
    return State.glow_id ~= nil
        and State.enabled
        and (State.params.BloomOn or 0) > 0.5
end

-- 只要我们的辉光链已注册且 mod 总开关开着，Bloom 就由我们托管：原生辉光
-- 一律压死（无论 BloomOn 是开是关）。这样 BloomOn=关 = 真正没有任何辉光
-- （此前关掉只是"恢复玩家原生辉光"，所以关不干净、也不省性能）。
-- 只有 mod 总开关关闭（P）或辉光链不可用时，才把原生设置还给玩家。
function State.BloomManaged()
    return State.glow_id ~= nil and State.enabled
end

-- 原生 Bloom 开关接管钩子（一次性安装，幂等）。
-- 引擎在玩家设置变更 / 进世界时经 PostProcessor:SetBloomEnabled 反复重开
-- 原生 Bloom（playerprofile ApplySettings，postprocesseffects.lua 的 Lua
-- 方法记账 bloom_enabled 标志）。包装 metatable.__index 上的该方法
-- （光影绘卷同款做法）：我们辉光接管期间一律强制关，释放后原样放行
-- 玩家的原生设置值。效果：
--   开我们 = 官方辉光必关（任何引擎路径都点不亮）；
--   关我们 = 官方辉光恢复玩家自己的画质偏好。
-- 不碰 Profile/TheSim 设置本身：玩家偏好永不被改写。
function State.HookNativeBloom()
    if State.native_bloom_hooked then return true end
    if PostProcessor == nil then return false end
    local mt = getmetatable(PostProcessor)
    local idx = mt and mt.__index
    if type(idx) ~= "table" or type(idx.SetBloomEnabled) ~= "function" then
        print("[BCAS] 警告：SetBloomEnabled 钩子失败（metatable 结构异常），原生辉光可能被引擎重新点亮")
        return false
    end
    local orig = idx.SetBloomEnabled
    idx.SetBloomEnabled = function(self, enabled)
        if State.BloomManaged() then
            enabled = false
        end
        orig(self, enabled)
    end
    State.native_bloom_hooked = true
    print("[BCAS] 已接管原生 Bloom 开关（SetBloomEnabled 钩子安装成功）")
    return true
end

-- 辉光总开关 + 原生 Bloom 接管（2026-09 v2）。
-- 接管：开我们 → EnablePostProcessEffect(glow, on) + SetBloomEnabled(false)
--   关原生（钩子同时保证引擎后续任何重开都被压下）；
-- 释放：关我们 → 按玩家画质设置里的原生 Bloom 偏好恢复。
-- 不再裸调 EnablePostProcessEffect(PostProcessorEffects.Bloom, ...)：
-- 那会让引擎内部 bloom_enabled 标志与实际状态脱节，玩家一改设置引擎
-- 就自行重开原生（双重叠光）。SetBloomEnabled 走引擎自己的记账。
function State.ApplyBloom()
    State.ApplyEnhancements()
    if PostProcessor == nil or State.glow_id == nil then return end
    local on = State.GlowOverrideActive()
    -- 折叠模式：glow_id 就是主 pass（grade+sharpen+bloom），不能按辉光开关
    -- 去 Enable/Disable 它——否则关辉光会把调色锐化一起关掉。改用强度归零
    -- （PackUniform 里处理）+ 金字塔 sampler 断电。
    if not State.glow_folded then
        PostProcessor:EnablePostProcessEffect(State.glow_id, on)
    end
    -- 金字塔四级 sampler 逐级断电（v3）：此前辉光关闭时四个 1/4 分辨率
    -- pass 仍在每帧空跑。引擎绑定表原生方法，pcall 防老版本签名差异。
    if State.glow_samplers ~= nil then
        for i = 1, #State.glow_samplers do
            local sid = State.glow_samplers[i]
            if sid ~= nil then
                pcall(PostProcessor.SetSamplerEffectState, PostProcessor, sid, on)
            end
        end
    end
    if PostProcessorEffects ~= nil and PostProcessorEffects.Bloom ~= nil then
        if State.BloomManaged() then
            -- 托管期间原生辉光恒关：BloomOn=关 才是真的没有辉光，也真的省性能
            PostProcessor:SetBloomEnabled(false)
        else
            local native = true
            if Profile ~= nil and Profile.GetBloomEnabled ~= nil then
                native = Profile:GetBloomEnabled() ~= false
            end
            PostProcessor:SetBloomEnabled(native)
        end
    end
    if State.glow_folded then
        State.ApplyUniform("BCAS_GLOW")
    end
end

function State.Snapshot()
    State.saved_params = {}
    for k, v in pairs(State.params) do State.saved_params[k] = v end
    State.saved_enabled = State.enabled
end

-- ==========================================================================
-- 公开操作（modmain / 设置界面 / 控制台）
-- ==========================================================================

function State.SetParam(key, value)
    local meta = VEC[key]
    if meta == nil then return end
    State.params[key] = math.clamp(value, meta.min, meta.max)
    if meta.uniform == "GLINT" then
        -- 海面波光参数：由 bcas_glint 每帧读取并下发到水面实体，
        -- 不走后处理 effect 的 uniform 表（该 pass 没有这些 uniform）
        return
    end
    if key == "ColourCubeOn" then
        State.ApplyColourCube()
        return
    end
    if key == "BloomOn" then
        State.ApplyBloom()
    State.ApplyEnhancements()
        return
    end
    if key == "ShadowsOn" or key == "OceanOn" or key == "GodRays" or key == "LightingMaster" then
        State.ApplyEnhancements()
        if key == "GodRays" then
            State.ApplyUniform(meta.uniform)
        end
        return
    end
    if key == "SanityColourOn" or key == "DistortFree" or key == "SnowCap"
        or key == "SandFilter" or key == "VanillaGrade" then
        State.ApplyVanillaFilters()
        -- 控制台可验证的落点：拨开关后 client_log 搜"原版滤镜开关"
        print("[BCAS] 原版滤镜开关: " .. key .. " -> " .. tostring(State.params[key]))
        return
    end
    State.ApplyUniform(meta.uniform)
end

function State.ResetParam(key)
    State.SetParam(key, VEC[key].default)
end

function State.SetEnabled(on)
    State.enabled = on and true or false
    if State.effect_id ~= nil then
        PostProcessor:EnablePostProcessEffect(State.effect_id, State.enabled)
    end
    if State.effect2_id ~= nil then
        PostProcessor:EnablePostProcessEffect(State.effect2_id, State.enabled)
    end
    State.ApplyBloom()
    State.ApplyEnhancements()
end

function State.ToggleEnabled()
    State.SetEnabled(not State.enabled)
    print("[BCAS] 滤镜已" .. (State.enabled and "开启" or "关闭"))
end

-- 预设不接管的参数（切换预设时保留当前值：不重置、不覆盖）。
-- 昼夜滤镜（ColourCubeOn）由用户自己在氛围页拨开关，预设不得代管——
-- 否则切预设会偷偷改掉用户的昼夜滤镜选择（用户 2026-09 拍板：
-- "每个预设都不要默认去开启关闭昼夜滤镜"）。"off" 预设例外：全还原原版。
local PRESET_NEUTRAL = { ColourCubeOn = true }

function State.ApplyPreset(name, also_enable)
    local preset = PRESETS[name] or PRESETS.standard
    -- 快照预设中立参数（首次启动时回落到 VEC 默认 = 原版开）
    local neutral = {}
    if name ~= "off" then
        for key in pairs(PRESET_NEUTRAL) do
            neutral[key] = State.params[key] ~= nil and State.params[key] or VEC[key].default
        end
    end
    for key, meta in pairs(VEC) do
        State.params[key] = preset[key] ~= nil and preset[key] or meta.default
    end
    for key, v in pairs(neutral) do
        State.params[key] = v
    end
    if also_enable ~= false then
        State.SetEnabled(name ~= "off")
    end
    State.ApplyAll()
    State.ApplyColourCube()
    State.ApplyBloom()
    State.ApplyEnhancements()
    State.ApplyVanillaFilters()
end

function State.Save()
    local data = {
        ver = 18,
        enabled = State.enabled,
        params = State.params,
    }
    TheSim:SetPersistentString(SAVE_FILE, json.encode(data))
end

-- ==========================================================================
-- 引擎接入（由 modmain 的官方钩子触发）
-- ==========================================================================

-- 注册一个 pass：ksh 效果 + 该效果的全部 uniform + 绑定。
-- 同名 uniform 的句柄只注册一次、多效果共用（引擎 OVERLAY_BLEND 先例：
-- ZoomBlur 与 Lunacy 共用一个句柄；glow A/B/预滤级也共用 BCAS_GLOW）。
-- 重复 AddUniformVariable 同名可能产生第二个句柄，造成两个效果各自
-- 持有不同句柄、参数下发只更新其中一个——必须走 State.handles 复用。
local function RegisterPass(ksh_path, effect_uniforms)
    local id = PostProcessor:AddPostProcessEffect(resolvefilepath(ksh_path))
    if id == nil then
        print("[BCAS] 错误：" .. ksh_path .. " 注册失败！请查看日志中更早的着色器编译报错。")
        return nil
    end
    -- ⚠ 必须用数组 unpack：字符串键表 unpack 出来是空的，效果会带着
    -- 0 个 uniform 绑定上岗，渲染期一上传参数就断言闪退（实测）。
    local arr = {}
    for i, name in ipairs(effect_uniforms) do
        local h = State.handles[name]
        if h == nil then
            h = PostProcessor:AddUniformVariable(name, 4)
            if h == nil then
                print("[BCAS] 警告：uniform " .. name .. " 注册返回 nil")
            end
            State.handles[name] = h
        end
        arr[i] = h
    end
    PostProcessor:SetEffectUniformVariables(id, unpack(arr))
    return id
end

-- 注册辉光金字塔（2026-09 v2）：两个合成 pass + 4 级 1/4 分辨率 Kawase。
-- 采样链输入 = 引擎辉光缓冲（SamplerEffectBase.BloomSampler，Klei 按实体
-- 写入的辉光源，引擎每帧照常填充、与原生 Bloom 效果的开关无关——光影绘卷
-- 已实测），逐级经 SamplerEffectBase.Shader 级联：
--   级 1 = 软膝预滤 + Kawase 步长 1（= 金字塔 CORE，预滤后才模糊）
--   级 2/3 = Kawase 步长 3/8（MID / HALO，每级仅 4 taps）
-- 合成 A 绑 core+mid，合成 B 绑 wide+halo（多 AddSampler 槽位语义同引擎
-- BuildLunacyShader：调用顺序 = SAMPLER[1..] 顺序）。
-- 性能：4 级 × 4 taps @ 1/4 分辨率 ≈ 每像素 1 tap 的原生分辨率开销，
--   比旧版 6 级 × 9 taps 高斯链省一半以上（Kawase 用双线性白嫖平滑）。
-- 不碰 SetBloomSamplerParams：保持引擎默认 0.25 分辨率 RGB 辉光缓冲。
-- 注意 ksh 是 sampler 效果：SAMPLER_PARAMS 魔法 uniform 由引擎按 RT 自动
-- 填充，只需经 SetEffectUniformVariables 绑定（同引擎 blur 链做法），
-- 绝不能 AddUniformVariable；预滤级额外绑 BCAS_GLOW（与合成共用句柄，
-- 引擎 OVERLAY_BLEND 先例）。
-- 注册辉光管线（2026-09 v4 单合成 pass + 3 级金字塔）：一个全分辨率
-- 合成 + 3 级 1/4 分辨率 Kawase（半径曲线 1.5/3.8/9.3 覆盖原四级
-- 1.5/2.9/5.3/10.1，中环一级承载原 mid+wide 能量，少一个 pass）。
-- 采样链输入 = 引擎辉光缓冲（SamplerEffectBase.BloomSampler，Klei 按实体
-- 写入的辉光源，引擎每帧照常填充、与原生 Bloom 效果的开关无关——光影绘卷
-- 已实测），逐级经 SamplerEffectBase.Shader 级联：
--   级 1 = 软膝预滤 + Kawase 步长 1（= 金字塔 CORE，预滤后才模糊）
--   级 2/3 = Kawase 步长 3/8（MID / HALO，每级仅 4 taps）
-- 合成 pass（bcas_glow.ksh v4）SAMPLER[1..3] 依次绑三级金字塔输出，
-- SAMPLER[0] = 链路输入（studio 输出），一次完成旧 A+B 全部合成
-- （权重/暖色/饱和塑形与旧两 pass 数学等价：饱和塑形对 bloom 线性）。
-- 性能：合成 2 pass -> 1 pass（全分辨率少一个 RT 往返）；3 级 × 4 taps
--   @ 1/4 分辨率 ≈ 每像素 0.75 tap 的原生分辨率开销（旧 4 级为 1 tap）。
-- 关闭真零开销：EnablePostProcessEffect 停合成 + SetSamplerEffectState
--   逐级停金字塔（引擎绑定表原生方法，v3 新接入——此前辉光关闭时
--   sampler 仍在每帧空跑）。
-- 不碰 SetBloomSamplerParams：保持引擎默认 0.25 分辨率 RGB 辉光缓冲。
-- 注意 ksh 是 sampler 效果：SAMPLER_PARAMS 魔法 uniform 由引擎按 RT 自动
-- 填充，只需经 SetEffectUniformVariables 绑定（同引擎 blur 链做法），
-- 绝不能 AddUniformVariable；预滤级额外绑 BCAS_GLOW（与合成共用句柄，
-- 引擎 OVERLAY_BLEND 先例）。
local function RegisterGlowChain()
    -- 折叠模式：辉光合成已经并进 merged 单 pass，只需把 mip 金字塔挂到它上面，
    -- 不再注册独立的 glow 合成 pass（全分辨率 pass 1 个）。
    local folded = State.merged_has_glow
    local glow_id
    if folded then
        glow_id = State.merged_id
    else
        glow_id = RegisterPass("shaders/bcas_glow.ksh", EFFECT_UNIFORMS.glow)
        if glow_id == nil then
            print("[BCAS] 错误：glow 合成 pass 注册失败！辉光不可用，请查日志更早的编译报错。")
            return nil
        end
    end
    if SamplerEffectBase == nil or SamplerSizes == nil or SamplerColourMode == nil
        or FILTER_MODE == nil or MIP_FILTER_MODE == nil or UniformVariables == nil
        or UniformVariables.SAMPLER_PARAMS == nil then
        -- 引擎全局量缺失：合成 pass 留着也无害（SAMPLER[1..4] 无输入 =
        -- 辉光 0 = 加法混合原样直通），但功能不完整，提示并降级
        State.glow_folded = folded
        print("[BCAS] 警告：SamplerEffect 引擎全局量缺失，辉光金字塔未创建")
        return glow_id
    end
    local chain = {
        {path = "shaders/bcas_bloom_pre.ksh", base = SamplerEffectBase.BloomSampler, prefilter = true, size = 0.25},
        {path = "shaders/bcas_bloom_d1.ksh",  base = SamplerEffectBase.Shader, size = 0.125},
        {path = "shaders/bcas_bloom_d2.ksh",  base = SamplerEffectBase.Shader, size = 0.0625},
        {path = "shaders/bcas_bloom_d3.ksh",  base = SamplerEffectBase.Shader, size = 0.03125},
    }
    local samplers = {}
    local prev = nil
    for i, c in ipairs(chain) do
        local sid
        if i == 1 then
            sid = PostProcessor:AddSamplerEffect(resolvefilepath(c.path),
                SamplerSizes.Relative, c.size, c.size, SamplerColourMode.RGB, c.base)
        else
            sid = PostProcessor:AddSamplerEffect(resolvefilepath(c.path),
                SamplerSizes.Relative, c.size, c.size, SamplerColourMode.RGB, c.base, prev)
        end
        if sid == nil then
            -- 不整体放弃：已建成的级仍可绑给合成（金字塔缺层仍能工作）
            print("[BCAS] 警告：辉光金字塔级 " .. i .. " 注册失败，辉光不完整")
            break
        end
        PostProcessor:SetSamplerEffectFilter(sid, FILTER_MODE.LINEAR, FILTER_MODE.LINEAR, MIP_FILTER_MODE.NONE)
        if c.prefilter and State.handles.BCAS_GLOW ~= nil then
            PostProcessor:SetEffectUniformVariables(sid, UniformVariables.SAMPLER_PARAMS, State.handles.BCAS_GLOW)
        else
            PostProcessor:SetEffectUniformVariables(sid, UniformVariables.SAMPLER_PARAMS)
        end
        samplers[i] = sid
        prev = sid
    end
    -- 金字塔绑定：合成 pass 的 SAMPLER[1..4] 依次吃四级输出
    for i = 1, 4 do
        if samplers[i] ~= nil then
            PostProcessor:AddSampler(glow_id, SamplerEffectBase.Shader, samplers[i])
        end
    end
    State.glow_samplers = samplers
    State.glow_folded = folded
    return glow_id
end

function State.InitShader()
    if PostProcessor == nil then
        print("[BCAS] PostProcessor 不可用，滤镜未加载")
        return
    end
    -- 尽早安装原生 Bloom / 原版滤镜接管钩子（modmain 顶层可能早于
    -- 引擎方法就绪，此处兜底重试，幂等）
    State.HookNativeBloom()
    State.HookVanillaFilters()
    -- 实验路径（MERGED_PASS=on）：先试注册 6593B 合并 pass。引擎源码缓冲
    -- 若小于源码长度，ksh 注册照常返回 id 但编译静默失败（画面=无调色无
    -- 锐化），无法运行时探测——所以成败只能靠用户看画面验证，失败就关
    -- 开关回双 pass（默认路径零风险）。
    if State.merged_pass then
        -- 内置默认：调色+锐化+辉光在同一个全分辨率 pass 里完成（架构优化，
        -- 全屏 pass 2 -> 1）。实机 A/B 已确认与双 pass 画质一致。
        State.merged_id = RegisterPass("shaders/bcas_merged_glow.ksh", EFFECT_UNIFORMS.merged_glow)
        if State.merged_id ~= nil then
            State.merged_has_glow = true
            print("[BCAS] 合并 pass 注册 -> id=" .. tostring(State.merged_id)
                .. " (GRADE+SHARPEN+BLOOM 单 pass)")
        else
            print("[BCAS] merged_glow 注册失败，回退普通 merged + 独立辉光")
            State.merged_id = RegisterPass("shaders/bcas_merged.ksh", EFFECT_UNIFORMS.merged)
        end
    end
    if State.merged_id ~= nil then
        State.effect_id = State.merged_id
        State.effect2_id = nil
    else
        State.effect_id = RegisterPass("shaders/bcas_studio.ksh", EFFECT_UNIFORMS.studio)
        if State.effect_id == nil then return end
        State.effect2_id = RegisterPass("shaders/bcas_cinema.ksh", EFFECT_UNIFORMS.cinema)
        if State.effect2_id == nil then
            print("[BCAS] 警告：cinema pass 注册失败，仅有锐化生效")
        end
    end
    State.glow_id = RegisterGlowChain()
    State.glow2_id = nil
    -- 只写参数，不在这里启用（启用统一放在 SortAndStart，对齐引擎时序）
    State.ApplyPreset(State.boot_preset, false)
    State.enabled = true
    print("[BCAS] 后处理效果注册成功 (id=" .. tostring(State.effect_id) .. "," .. tostring(State.effect2_id)
        .. ",glow=" .. tostring(State.glow_id) .. ") 合成单pass v3")
end

function State.SortAndStart()
    if State.effect_id == nil then return end

    -- 插入渲染链：全游戏生命周期只此一次（引擎在启动时统一调
    -- SortAndEnableShaders，链路跨存档持续存在；再插就是叠加副本）。
    -- 顺序（用户定的管线）：先调色后锐化 -> 链路 Lunacy -> cinema -> studio。
    -- 调色在前让动态范围先稳定，锐化不会再被后续对比度二次拉伸；
    -- 颗粒在锐化之后生成，锐化永远采不到噪点。
    local rc = false
    if State.merged_id ~= nil then
        -- 合并 pass 单体插入：位置同调色链（Lunacy 之后），锐化链全跳过
        rc = PostProcessor:SetPostProcessEffectAfter(State.merged_id, PostProcessorEffects.Lunacy)
        print("[BCAS] 插入合并pass After(Lunacy) -> " .. tostring(rc))
    elseif State.effect2_id ~= nil then
        rc = PostProcessor:SetPostProcessEffectAfter(State.effect2_id, PostProcessorEffects.Lunacy)
        print("[BCAS] 插入调色链 After(Lunacy) -> " .. tostring(rc))
    end
    if not rc and State.merged_id ~= nil then
        rc = PostProcessor:SetPostProcessEffectBefore(State.merged_id, PostProcessorEffects.Distort)
        print("[BCAS] 合并pass Before(Distort) -> " .. tostring(rc))
    end
    if not rc then
        -- 调色 pass 缺席时锐化直接顶上；或作为回退插入位置
        rc = PostProcessor:SetPostProcessEffectBefore(State.effect_id, PostProcessorEffects.Distort)
        print("[BCAS] 锐化链 Before(Distort) -> " .. tostring(rc))
    end
    if State.effect_id ~= nil and State.effect2_id ~= nil then
        local rs = PostProcessor:SetPostProcessEffectAfter(State.effect_id, State.effect2_id)
        print("[BCAS] 插入锐化链 After(cinema) -> " .. tostring(rs))
    end
    -- merged 路径：effect_id == merged_id 且 effect2_id == nil，上面自然跳过
    -- 辉光合成插在 studio 之后（链尾）：作用于最终画面，辉光层永不被
    -- 锐化或二次调色。v3 单合成 pass：SAMPLER[0] 自动取链路输入
    -- （studio 输出），SAMPLER[1..4] = 四级金字塔。MoonPulse（月暴）
    -- 在引擎排序里位于我们之后，其事件效果叠在辉光上，可接受。
    if State.glow_id ~= nil then
        local rg = PostProcessor:SetPostProcessEffectAfter(State.glow_id, State.effect_id)
        print("[BCAS] 插入辉光链 After(studio) -> " .. tostring(rg))
    end

    local rc_en = PostProcessor:EnablePostProcessEffect(State.effect_id, true)
    if State.effect2_id ~= nil then
        PostProcessor:EnablePostProcessEffect(State.effect2_id, true)
    end
    State.enabled = true
    print("[BCAS] 启用效果 -> " .. tostring(rc_en))
    State.ApplyAll()
    State.ApplyColourCube()
    State.ApplyBloom()
    State.ApplyEnhancements()
    State.ApplyVanillaFilters()

    TheSim:GetPersistentString(SAVE_FILE, function(ok, str)
        if ok and str ~= nil and str ~= "" then
            local status, data = pcall(json.decode, str)
            if status and type(data) == "table" then
                if data.ver ~= 18 then
                    -- 升级到 v18: 全局定向太阳天光与全生态 3D 太阳长影
                    print("[BCAS] 忽略旧版本(v" .. tostring(data.ver) .. ")存档，使用默认预设")
                elseif type(data.params) == "table" then
                    for key, meta in pairs(VEC) do
                        local v = tonumber(data.params[key])
                        if v ~= nil then
                            State.params[key] = math.clamp(v, meta.min, meta.max)
                        end
                    end
                    State.enabled = data.enabled ~= false
                    print("[BCAS] 已载入保存的设置 (enabled=" .. tostring(State.enabled) .. ")")
                end
            end
        end
        State.ApplyAll()
        State.ApplyColourCube()
        State.SetEnabled(State.enabled)
        State.ApplyVanillaFilters()
        State.ready = true
        if not State.enabled then
            print("[BCAS] 注意：保存的设置为关闭状态，按 P 开启")
        end
        State.Info() -- 自动打印完整状态，无需手动输入命令
    end)
end

-- 进世界后保险式重申：只重发"开关标志 + uniform 数值"（幂等、零副作用）。
-- ⚠ 绝对不要在这里调 SetPostProcessEffectAfter：引擎语义是"插入"链表
-- （注释原文 added into the sorted post processor list），而且链路只在
-- 游戏启动时经 SortAndEnableShaders 建一次、跨存档持续存在。反复插入 =
-- N 层滤镜叠加（闪光弹），且 disable 压不住一堆副本（P 键关不掉）。
function State.Reassert()
    if PostProcessor == nil or State.effect_id == nil then return end
    PostProcessor:EnablePostProcessEffect(State.effect_id, State.enabled and true or false)
    if State.effect2_id ~= nil then
        PostProcessor:EnablePostProcessEffect(State.effect2_id, State.enabled and true or false)
    end
    State.ApplyColourCube()
    State.ApplyBloom()
    State.ApplyEnhancements()
    State.ApplyVanillaFilters()
    State.ApplyAll()
end

-- 控制台自检：c_bcasinfo() / BCAS.Info()
function State.Info()
    print("[BCAS] ---- 自检 ----")
    print("[BCAS] effect_id = " .. tostring(State.effect_id))
    print("[BCAS] effect2_id = " .. tostring(State.effect2_id))
    print("[BCAS] glow_id(A) = " .. tostring(State.glow_id))
    print("[BCAS] glow 合成 v3（单 pass）= " .. tostring(State.glow_id))
    if State.glow_samplers ~= nil then
        print("[BCAS] glow 金字塔 = " .. table.concat(State.glow_samplers, ","))
    end
    print("[BCAS] enabled = " .. tostring(State.enabled))
    print("[BCAS] ready = " .. tostring(State.ready))
    for name, h in pairs(State.handles) do
        print("[BCAS] uniform " .. name .. " handle = " .. tostring(h))
    end
    local n = 0
    for k, v in pairs(State.params) do
        n = n + 1
    end
    print("[BCAS] 共 " .. n .. " 个参数")
end

-- 渲染链冒烟测试：绕过状态机直接向引擎下发爆炸参数
function State.Test()
    if State.effect_id == nil or State.handles.BCAS_GRADE_A == nil then
        print("[BCAS] 测试失败：effect_id 或 uniform 句柄为 nil")
        return
    end
    PostProcessor:EnablePostProcessEffect(State.effect_id, true)
    PostProcessor:SetUniformVariable(State.handles.BCAS_GRADE_A, 2.0, 0.5, 0.0, 2.0)
    print("[BCAS] 已强制下发测试参数（+2EV / 暖色 / 饱和x2）。")
    print("[BCAS] 画面有明显变化 => 渲染链正常，问题在参数状态机；")
    print("[BCAS] 画面毫无变化 => 后处理链没有经过本效果，请把 client_log.txt 里所有 [BCAS] 行发出来。")
end

return State
