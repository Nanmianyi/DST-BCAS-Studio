--[[ BCAS Studio —— 参数状态机

单一数据源：所有可调参数、预设、uniform 打包/下发、持久化。
在游戏全局环境运行（require 加载），直接使用引擎全局量。

双 pass 架构（2026-08，管线顺序由用户拍板）：
    cinema(调色, effect2) -> studio(锐化+氛围, effect)
    先调色再锐化：动态范围先稳定，锐化不被二次拉伸；颗粒在锐化后生成。
uniform 数量无 4 个限制（pxl_42 实测绑了 9 个，之前的断言是条目表
没同步导致的误判）。
]]

local State = {
    effect_id = nil,      -- studio（锐化）
    effect2_id = nil,     -- cinema（调色）
    handles = {},         -- uniform 名 -> 句柄
    enabled = true,
    boot_preset = "standard",
    params = {},          -- 参数名 -> 数值
    saved_params = nil,   -- 面板打开时的快照（用于"放弃更改"）
    saved_enabled = true,
    ready = false,        -- shader 注册完成
}

local SAVE_FILE = "bcas_studio"

-- 参数元数据：uniform 打包位置 + 滑条范围 + 默认值（缺省 = 旧 fx 实测值）
-- comp 对应 SetUniformVariable(handle, x, y, z, w) 的第几个分量
-- uniform = nil 的参数不下发着色器（如 ColourCubeOn，走引擎开关）
local VEC = {
    -- == 锐化核心 (studio / BCAS_SHARPEN) ==
    Strength    = {uniform = "BCAS_SHARPEN", comp = 1, min = 0,    max = 5,    default = 5.0},
    NoiseReduce = {uniform = "BCAS_SHARPEN", comp = 2, min = 0,    max = 1,    default = 0.6},
    AntiRinging = {uniform = "BCAS_SHARPEN", comp = 3, min = 0,    max = 1,    default = 0.6},
    DarkProtect = {uniform = "BCAS_SHARPEN", comp = 4, min = 0,    max = 1,    default = 0.25},

    -- == 锐化进阶 (studio / BCAS_SHARP2) ==
    RangeSigma   = {uniform = "BCAS_SHARP2", comp = 1, min = 0.01, max = 2,    default = 0.26},
    SpatialSigma = {uniform = "BCAS_SHARP2", comp = 2, min = 0,    max = 4,    default = 1.10},
    CenterWeight = {uniform = "BCAS_SHARP2", comp = 3, min = 0,    max = 4,    default = 1.0},
    NoiseFloor   = {uniform = "BCAS_SHARP2", comp = 4, min = 0,    max = 0.05, default = 0.008},

    -- == AURA 抗过冲 (studio / BCAS_AURA) ==
    AR_Threshold  = {uniform = "BCAS_AURA", comp = 1, min = 0,     max = 0.02, default = 0.0015},
    AR_L_Overshoot= {uniform = "BCAS_AURA", comp = 2, min = 0.001, max = 0.1,  default = 0.003},
    AR_D_Overshoot= {uniform = "BCAS_AURA", comp = 3, min = 0.001, max = 0.1,  default = 0.009},
    ChromaProtect = {uniform = "BCAS_AURA", comp = 4, min = 0,     max = 1,    default = 0.65},

    -- == 色彩基础 (cinema / BCAS_GRADE_A/B/EXTRA) ==
    ExposureEV  = {uniform = "BCAS_GRADE_A", comp = 1, min = -2,   max = 2,    default = 0.06},
    Temp        = {uniform = "BCAS_GRADE_A", comp = 2, min = -1,   max = 1,    default = 0.305},
    Tint        = {uniform = "BCAS_GRADE_A", comp = 3, min = -1,   max = 1,    default = -0.089},
    Saturation  = {uniform = "BCAS_GRADE_A", comp = 4, min = 0,    max = 2,    default = 0.988},
    Vibrance    = {uniform = "BCAS_GRADE_B", comp = 1, min = -1,   max = 1,    default = 0.143},
    Contrast    = {uniform = "BCAS_GRADE_B", comp = 2, min = -0.5, max = 1,    default = 0},
    Lightness   = {uniform = "BCAS_GRADE_B", comp = 3, min = -0.3, max = 0.3,  default = 0},
    Gamma       = {uniform = "BCAS_GRADE_B", comp = 4, min = 0.5,  max = 2,    default = 1.0},
    Filmic      = {uniform = "BCAS_EXTRA",   comp = 1, min = 0,    max = 1,    default = 0.311},

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
    HL_Desat = {uniform = "BCAS_CDL_O", comp = 4, min = 0,   max = 1, default = 0},
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
    OriginalMix= {uniform = "BCAS_SEC_O", comp = 4, min = 0,   max = 1, default = 0.05},
    SecPowerR  = {uniform = "BCAS_SEC_P", comp = 1, min = 0.1, max = 4, default = 1.0},
    SecPowerG  = {uniform = "BCAS_SEC_P", comp = 2, min = 0.1, max = 4, default = 1.0},
    SecPowerB  = {uniform = "BCAS_SEC_P", comp = 3, min = 0.1, max = 4, default = 1.0},

    -- == 引擎开关（不占 uniform）==
    ColourCubeOn = {uniform = nil, comp = 0, min = 0, max = 1, default = 1},
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
    studio = {"BCAS_SHARPEN", "BCAS_SHARP2", "BCAS_AURA", "BCAS_ATMO"},
}

-- 白平衡 RGB 增益（调色窗虚拟旋钮）：不占 uniform，数学映射到 Temp/Tint。
-- 着色器模型: r=2^(0.2T) b=2^(-0.2T) g=2^(0.12Ti)，归一化不影响通道比值。
function State.GainToTempTint(r, g, b)
    local T = math.clamp(math.log(math.max(r, 0.05) / math.max(b, 0.05)) / (0.4 * math.log(2)), -1, 1)
    local Ti = math.clamp(math.log(math.max(g, 0.05) / math.sqrt(math.max(r, 0.05) * math.max(b, 0.05))) / (0.12 * math.log(2)), -1, 1)
    return T, Ti
end

local PRESETS = {
    -- 作者特调（楠眠已实机调校，发布默认画质）
    standard = {
        Strength = 5.0, NoiseReduce = 0.88, AntiRinging = 1.0, DarkProtect = 0.05,
        RangeSigma = 0.26, SpatialSigma = 1.10, CenterWeight = 1.0, NoiseFloor = 0.01,
        AR_Threshold = 0.0, AR_L_Overshoot = 0.01, AR_D_Overshoot = 0.01, ChromaProtect = 0.39,
        ExposureEV = 0.06, Temp = 0.305, Tint = -0.089, Saturation = 0.99,
        Vibrance = 0.14, Contrast = 0.01, Lightness = 0, Gamma = 1.0,
        Vignette = 0, Grain = 0, Filmic = 0.31,
        HL_Desat = 0.10, OriginalMix = 0.05,
        SlopeR = 0.94, SlopeG = 1.0, SlopeB = 1.0,
        ColourCubeOn = 0,
        OffsetR = 0, OffsetG = 0, OffsetB = 0,
        PowerR = 1.0, PowerG = 1.0, PowerB = 1.0,
    },
    light = {
        Strength = 2.0, NoiseReduce = 0.35, AntiRinging = 0.8, DarkProtect = 0.4,
        ExposureEV = 0, Temp = 0.1, Tint = 0, Saturation = 1.0,
        Vibrance = 0.06, Contrast = 0.02, Lightness = 0, Gamma = 1.0,
        Vignette = 0, Grain = 0, Filmic = 0.12,
        ColourCubeOn = 0,
    },
    cinema = {
        Strength = 4.0, NoiseReduce = 0.5, AntiRinging = 0.6, DarkProtect = 0.4,
        ExposureEV = 0.03, Temp = 0.35, Tint = -0.02, Saturation = 1.05,
        Vibrance = 0.25, Contrast = 0.06, Lightness = -0.01, Gamma = 0.97,
        Vignette = 0.28, Grain = 0.12, Filmic = 0.45,
        HL_Desat = 0.3, ColourCubeOn = 0,
    },
    off = {
        Strength = 0, NoiseReduce = 0, AntiRinging = 0, DarkProtect = 0,
        ExposureEV = 0, Temp = 0, Tint = 0, Saturation = 1.0,
        Vibrance = 0, Contrast = 0, Lightness = 0, Gamma = 1.0,
        Vignette = 0, Grain = 0, Filmic = 0,
        HL_Desat = 0, OriginalMix = 0, ColourCubeOn = 1,
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
function State.ApplyColourCube()
    if PostProcessor == nil then return end
    local on = (State.params.ColourCubeOn or 1) > 0.5
    if PostProcessorEffects ~= nil and PostProcessorEffects.ColourCube ~= nil then
        PostProcessor:EnablePostProcessEffect(PostProcessorEffects.ColourCube, on)
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
    if key == "ColourCubeOn" then
        State.ApplyColourCube()
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
end

function State.ToggleEnabled()
    State.SetEnabled(not State.enabled)
    print("[BCAS] 滤镜已" .. (State.enabled and "开启" or "关闭"))
end

function State.ApplyPreset(name, also_enable)
    local preset = PRESETS[name] or PRESETS.standard
    for key, meta in pairs(VEC) do
        State.params[key] = preset[key] ~= nil and preset[key] or meta.default
    end
    if also_enable ~= false then
        State.SetEnabled(name ~= "off")
    end
    State.ApplyAll()
    State.ApplyColourCube()
end

function State.Save()
    local data = {
        ver = 4,
        enabled = State.enabled,
        params = State.params,
    }
    TheSim:SetPersistentString(SAVE_FILE, json.encode(data))
end

-- ==========================================================================
-- 引擎接入（由 modmain 的官方钩子触发）
-- ==========================================================================

-- 注册一个 pass：ksh 效果 + 该效果的全部 uniform + 绑定
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
        local h = PostProcessor:AddUniformVariable(name, 4)
        if h == nil then
            print("[BCAS] 警告：uniform " .. name .. " 注册返回 nil")
        end
        arr[i] = h
        State.handles[name] = h
    end
    PostProcessor:SetEffectUniformVariables(id, unpack(arr))
    return id
end

function State.InitShader()
    if PostProcessor == nil then
        print("[BCAS] PostProcessor 不可用，滤镜未加载")
        return
    end
    State.effect_id = RegisterPass("shaders/bcas_studio.ksh", EFFECT_UNIFORMS.studio)
    if State.effect_id == nil then return end
    State.effect2_id = RegisterPass("shaders/bcas_cinema.ksh", EFFECT_UNIFORMS.cinema)
    if State.effect2_id == nil then
        print("[BCAS] 警告：cinema pass 注册失败，仅有锐化生效")
    end
    -- 只写参数，不在这里启用（启用统一放在 SortAndStart，对齐引擎时序）
    State.ApplyPreset(State.boot_preset, false)
    State.enabled = true
    print("[BCAS] 后处理效果注册成功 (id=" .. tostring(State.effect_id) .. "," .. tostring(State.effect2_id) .. ")")
end

function State.SortAndStart()
    if State.effect_id == nil then return end

    -- 插入渲染链：全游戏生命周期只此一次（引擎在启动时统一调
    -- SortAndEnableShaders，链路跨存档持续存在；再插就是叠加副本）。
    -- 顺序（用户定的管线）：先调色后锐化 -> 链路 Lunacy -> cinema -> studio。
    -- 调色在前让动态范围先稳定，锐化不会再被后续对比度二次拉伸；
    -- 颗粒在锐化之后生成，锐化永远采不到噪点。
    local rc = false
    if State.effect2_id ~= nil then
        rc = PostProcessor:SetPostProcessEffectAfter(State.effect2_id, PostProcessorEffects.Lunacy)
        print("[BCAS] 插入调色链 After(Lunacy) -> " .. tostring(rc))
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

    local rc_en = PostProcessor:EnablePostProcessEffect(State.effect_id, true)
    if State.effect2_id ~= nil then
        PostProcessor:EnablePostProcessEffect(State.effect2_id, true)
    end
    State.enabled = true
    print("[BCAS] 启用效果 -> " .. tostring(rc_en))
    State.ApplyAll()
    State.ApplyColourCube()

    TheSim:GetPersistentString(SAVE_FILE, function(ok, str)
        if ok and str ~= nil and str ~= "" then
            local status, data = pcall(json.decode, str)
            if status and type(data) == "table" then
                if data.ver ~= 4 then
                    -- 旧版本存档的参数量纲已过时，直接作废回落预设
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
    State.ApplyAll()
end

-- 控制台自检：c_bcasinfo() / BCAS.Info()
function State.Info()
    print("[BCAS] ---- 自检 ----")
    print("[BCAS] effect_id = " .. tostring(State.effect_id))
    print("[BCAS] effect2_id = " .. tostring(State.effect2_id))
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
