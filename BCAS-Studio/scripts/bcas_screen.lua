--[[
    BCAS Studio —— 设置面板 v4.5 (Master Precision Edition)
    视觉设计：楠眠已 LAB · 光色几何实验室 (Color & Light Optical Laboratory)
    调色体系：暖米工程底纸 / 深焙黑巧 / 实验室橄榄绿 / 光色琥珀金 / 瓷白高亮
    
    架构特性：
      * 100% 纯矢量矩阵构建（基于引擎 square.tex 多层光影着色），零模糊、零外部图片依赖；
      * 欧几里得几何与包豪斯排版：十字准星、L型标尺、光学滑轨刻度、状态指示灯；
      * ReShade 式无级拖拽 + 单击直接键入 + 实时双向同步光谱白平衡仪。
]]

local Screen = require "widgets/screen"
local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Text = require "widgets/text"
local ImageButton = require "widgets/imagebutton"
local TextEdit = require "widgets/textedit"

local State = require "bcas_state"

-- 无描边干净字体（HDFONT 开启时注入，关闭时回落 UIFONT）
local F_CLEAN = rawget(_G, "BCAS_FONT_CLEAN") or UIFONT

-- ==== 1. 实验室签名调色板 (OPTICAL LAB PALETTE) ==============================
local C = {
    -- 纸张与底色
    BG_CANVAS   = {0.957, 0.937, 0.890, 1}, -- 主工程纸底 #F4EFE3
    BG_CARD     = {0.933, 0.910, 0.855, 1}, -- 参数卡片底 #EEE8DA
    CARD_WHITE  = {0.984, 0.973, 0.949, 1}, -- 瓷白高光框 #FAF8F2
    BG_MUTED    = {0.890, 0.863, 0.796, 1}, -- 浅灰辅底 #E3DCB
    
    -- 墨色与文字
    ESPRESSO    = {0.173, 0.114, 0.094, 1}, -- 深焙黑巧 #2C1D18 (主墨色)
    ESPRESSO_LT = {0.267, 0.188, 0.157, 1}, -- 次强调黑巧 #443028
    TEXT_MUTED  = {0.482, 0.420, 0.345, 1}, -- 说明/辅助文字 #7B6B58
    TEXT_LIGHT  = {0.980, 0.965, 0.933, 1}, -- 深底上的米白字 #FAF6EE
    
    -- 实验室高光与点睛
    OLIVE       = {0.431, 0.522, 0.216, 1}, -- 实验室橄榄绿 #6E8537
    OLIVE_DK    = {0.314, 0.384, 0.145, 1}, -- 深橄榄 #506225
    OLIVE_LT    = {0.553, 0.651, 0.251, 1}, -- 浅亮橄榄 #8DA640
    AMBER       = {0.918, 0.659, 0.275, 1}, -- 光色琥珀金 #EAA846
    AMBER_LT    = {0.965, 0.784, 0.420, 1}, -- 亮琥珀 #F6C86B
    
    -- 标尺与结构线
    LINE_DARK   = {0.784, 0.733, 0.635, 1}, -- 边框结构线 #C8BBA2
    LINE_LIGHT  = {0.867, 0.835, 0.757, 1}, -- 浅坐标线 #DDD5C1
    GRID_DOT    = {0.741, 0.686, 0.584, 0.7}, -- 网格定位点
}
local R, G, B = 1, 2, 3

-- ==== 2. 布局台账与几何规范 ===================================================
local PANEL_W, PANEL_H = 484, 686
local PANEL_X = 14 + PANEL_W / 2
local ROW_W = PANEL_W - 32            -- 452
local ROW_H = 36
local ROW_STEP = 42

local METER_W = 68                    -- 光学滑轨宽度
local METER_X = 94                    -- 滑轨中心 X（66..122；避免与数值框左缘 125 重叠）
local VAL_X   = 154                   -- 数值框中心 X
local RST_X   = 206                   -- 复位按钮中心 X

-- 纵向台账
local Y_HEADER   = 314
local Y_PRESET   = 266
local Y_DIV1     = 246
local Y_TABS     = 220
local Y_DIV2     = 196
local Y_ROW0     = 164
local Y_DIV3     = -256
local Y_BTNS     = -286
local Y_HINT     = -324

local STR = {
    BRAND_TAG = "● NANMIANYI LAB // OPTICAL PIPELINE",
    TITLE     = "# BCAS STUDIO",
    SUBTITLE  = "// 楠楠画质实验室",
    APPLY     = "# 保存并写入配置",
    CANCEL    = "// 放弃更改",
    PRESETS   = {
        {key = "standard", label = "# 特调方案"},
        {key = "light",    label = "# 轻量画质"},
        {key = "cinema",   label = "# 电影胶片"},
        {key = "off",      label = "# 原版关闭"},
    },
    HINT = "拖动微调 · 单击键入 · R 复位 · ESC 退出 · P 快捷开关",
    TABS = {"01 锐化", "02 进阶", "03 色彩", "04 调色", "05 氛围", "06 辉光", "07 光影", "08 水面"},
    LABELS = {
        Strength = "锐化强度 STRENGTH", DeconvStrength = "逆卷积墨线收敛 DECONV",
        NoiseReduce = "图像降噪 DENOISE",
        AntiRinging = "抗振铃 AURA", DarkProtect = "暗部保护 DARK-PROT",
        ExposureEV = "曝光增益 EXPOSURE", Saturation = "色彩饱和 SATURATION",
        Vibrance = "自然饱和 VIBRANCE", Contrast = "对比度 CONTRAST",
        Lightness = "明度 LIGHTNESS", Gamma = "伽马校正 GAMMA",
        Filmic = "胶片曲线 ACES-FILM",
        Vignette = "暗角强度 VIGNETTE", Grain = "胶片颗粒 GRAIN",
        RangeSigma = "双边范围σ RANGE", SpatialSigma = "空间范围σ SPATIAL",
        CenterWeight = "中心权重 CENTER", NoiseFloor = "噪声基底 FLOOR",
        AR_Threshold = "AURA 边缘阈值", AR_L_Overshoot = "AURA 亮部过冲",
        AR_D_Overshoot = "AURA 暗部过冲", ChromaProtect = "色度保护 CHROMA",
        HL_Desat = "高光去饱和 HL-DESAT", OriginalMix = "原画混合 ORIGINAL",
        SlopeR = "一级斜率 R-SLOPE", SlopeG = "一级斜率 G-SLOPE", SlopeB = "一级斜率 B-SLOPE",
        OffsetR = "一级偏移 R-OFFSET", OffsetG = "一级偏移 G-OFFSET", OffsetB = "一级偏移 B-OFFSET",
        PowerR = "一级幂指数 R-POWER", PowerG = "一级幂指数 G-POWER", PowerB = "一级幂指数 B-POWER",
        ColourCubeOn = "原版昼夜滤镜 VANILLA",
        BloomOn = "辉光总开关 BLOOM-ON",
        SanityColourOn = "低精神保色 SANITY-COL", DistortFree = "失真消除 NO-DISTORT",
        SnowCap = "积雪上限 SNOW-CAP", SandFilter = "风沙遮罩过滤 SAND",
        GlowIntensity = "辉光强度 INTENSITY", GlowThreshold = "辉光阈值 THRESHOLD",
        GlowWarmth = "辉光暖度 WARMTH", GlowSat = "辉光饱和 GLOW-SAT",
        GlowKnee = "辉光软膝 KNEE", GlowSpread = "辉光扩散 SPREAD",
        GlowCompress = "高光压缩 COMPRESS",
        VanillaGrade = "官方调色强度 GRADE",
        SunFill = "太阳全局光 SUN-FILL", GodRays = "透云光束 SUN-SHAFTS", LightingMaster = "光影总开关 LIGHTING", ShadowsOn = "地面投影 SHADOWS", OceanOn = "地皮色调 OCEAN-TILE", GlowTail = "光晕长尾 GLOW-TAIL", LightWrap = "光包裹 LIGHT-WRAP", GlowRim = "轮廓光 GLOW-RIM",
        GlintOn = "海面波光 GLINT", GlintStrength = "波光强度 INTENSITY", GlintDensity = "波光增益 GAIN", GlintGrain = "波光颗粒 GRAIN", GlintSoft = "海色融合 MIX",
    },
    SHARP_NOTE = "双边自适应锐化：仅作用于游戏世界，HUD 界面不受影响；抗振铃(AURA)可消除白边。",
    WB_LAUNCH  = "# 白平衡 · 光学色彩轮 (点击展开调色仪)",
    WB_TIP     = "取色直接映射为 RGB 增益，等效于专业影视级 CDL 斜率校准。",
    ATMO_NOTE  = "环境氛围：暗角压暗四边、胶片颗粒增添质感；官方调色可控制原版季节滤镜强度。",
    GLOW_NOTE  = "金字塔柔光：沿游戏自带光源柔化发散，软膝控制起点，长尾权重使光晕温暖宽广。",
    GLOW2_NOTE = "光影总开关 LIGHTING 拨 OFF 即彻底释放全部光影开销。地面投影随日晷。波光改的是海洋地块，绿洲般通透粼粼。\n⚠ 水面配色烘在世界生成：改动 OCEAN 需重进世界生效。",
    WB_TITLE   = "# 光学色轮 / 白平衡",
    WB_SUB     = "// CDL SPECTRUM ANALYZER",
    WB_CLOSE   = "完成校准",
    WB_AXIS    = "环 = 色相 (H) · 横 = 饱和 (S) · 纵 = 明度 (V)",
    WB_PRESETS = {
        {label = "# 标准", v = {1.00, 1.00, 1.00}},
        {label = "# 暖调", v = {1.08, 1.00, 0.90}},
        {label = "# 冷调", v = {0.90, 1.00, 1.10}},
        {label = "# 品红", v = {1.06, 0.94, 1.06}},
        {label = "# 草绿", v = {0.94, 1.08, 0.92}},
    },
    WB_RESET   = "1:1 复位",
}

local TAB_ROWS = {
    [1] = {"Strength", "DeconvStrength", "NoiseReduce", "AntiRinging", "DarkProtect"},
    [2] = {"RangeSigma", "SpatialSigma", "CenterWeight", "NoiseFloor",
           "AR_Threshold", "AR_L_Overshoot", "AR_D_Overshoot", "ChromaProtect"},
    [3] = {"ExposureEV", "Saturation", "Vibrance", "Contrast", "Lightness",
           "Gamma", "Filmic", "HL_Desat", "OriginalMix"},
    [4] = {"SlopeR", "SlopeG", "SlopeB", "OffsetR", "OffsetG", "OffsetB",
           "PowerR", "PowerG", "PowerB"},
    [5] = {"Vignette", "Grain", "ColourCubeOn", "SanityColourOn",
           "DistortFree", "SnowCap", "SandFilter", "VanillaGrade"},
    [6] = {"BloomOn", "GlowIntensity", "GlowThreshold", "GlowKnee",
           "GlowSpread", "GlowWarmth", "GlowSat", "GlowCompress"},
    [7] = {"LightingMaster", "ShadowsOn", "OceanOn", "SunFill", "GodRays", "GlowRim", "GlowTail", "LightWrap"},
    [8] = {"GlintOn", "GlintStrength", "GlintDensity", "GlintGrain", "GlintSoft"},
}

local BOOL_KEYS = { ColourCubeOn = true, BloomOn = true,
    SanityColourOn = true, DistortFree = true, SandFilter = true,
    ShadowsOn = true, OceanOn = true, LightingMaster = true, GlintOn = true }

-- ==== 3. 颜色数学 ===========================================================

local function hsv2rgb(h, s, v)
    h = (h % 1) * 6
    local i = math.floor(h) % 6
    local f = h - math.floor(h)
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    else return v, p, q end
end

local function rgb2hsv(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 1e-6 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h / 6
    end
    return h, mx > 1e-6 and d / mx or 0, mx
end

local function FmtHex(r, g, b)
    return string.format("#%02X%02X%02X",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function GainsFromParams()
    local T, Ti = State.params.Temp, State.params.Tint
    return 2 ^ (0.2 * T), 2 ^ (0.12 * Ti), 2 ^ (-0.2 * T)
end

local function GainsToDisplay(r, g, b)
    local mx = math.max(r, g, b, 1e-6)
    return r / mx, g / mx, b / mx
end

local function SetGainsFromColor(r, g, b)
    local Y = 0.299 * r + 0.587 * g + 0.114 * b
    if Y < 1e-3 then r, g, b = 1, 1, 1; Y = 1 end
    local gr = math.clamp(r / Y, 0.55, 1.85)
    local gg = math.clamp(g / Y, 0.55, 1.85)
    local gb = math.clamp(b / Y, 0.55, 1.85)
    local T, Ti = State.GainToTempTint(gr, gg, gb)
    State.SetParam("Temp", T)
    State.SetParam("Tint", Ti)
end

-- ==== 4. 面板主体 ===========================================================

local BCASScreen = Class(Screen, function(self)
    Screen._ctor(self, "BCAS_Studio")

    self.tab = 1
    self.dirty = false
    self.rows = {}
    self.content_children = {}
    self.edits = {}

    self.root = self:AddChild(Widget("root"))
    self.root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.root:SetHAnchor(ANCHOR_LEFT)
    self.root:SetVAnchor(ANCHOR_MIDDLE)

    self.chrome = self.root:AddChild(Widget("chrome"))
    self.chrome:SetPosition(PANEL_X, 0)

    -- 1. 多层阴影 (Drop Shadows)
    self:SolidRect(self.chrome, 10, -10, PANEL_W + 4, PANEL_H + 4, {0.10, 0.07, 0.05, 0.08})
    self:SolidRect(self.chrome, 6, -6, PANEL_W + 2, PANEL_H + 2, {0.10, 0.07, 0.05, 0.14})

    -- 2. 面板底盘与双层线框
    self:SolidRect(self.chrome, 0, 0, PANEL_W + 4, PANEL_H + 4, C.ESPRESSO)
    self:SolidRect(self.chrome, 0, 0, PANEL_W, PANEL_H, C.BG_CANVAS)
    
    -- 3. 背景工程点阵与十字准星
    self:BuildEngineeringGrid(self.chrome, PANEL_W - 8, PANEL_H - 8)

    -- 4. 实验室标尺与四角取景器 (Reticles)
    self:BuildReticleMarks(self.chrome, PANEL_W - 20, PANEL_H - 20, C.ESPRESSO)

    self:BuildHeader()
    self:BuildPresetRow()
    self:Dashed(0, Y_DIV1, PANEL_W - 44)
    self:BuildTabRow()
    self:Dashed(0, Y_DIV2, PANEL_W - 44)

    self.content = self.root:AddChild(Widget("content"))
    self.content:SetPosition(PANEL_X, 0)
    self:BuildContent()

    self:Dashed(0, Y_DIV3, PANEL_W - 44)
    self:BuildFooter()
    self:BuildWBPopup()

    self.default_focus = self.enable_btn
end)

-- ==== 5. 光学/几何原子渲染器 (GRAPHICAL ATOMS) ===============================

function BCASScreen:SolidRect(parent, x, y, w, h, col)
    local img = parent:AddChild(Image("images/global.xml", "square.tex"))
    img:ScaleToSize(w, h)
    img:SetPosition(x, y)
    img:SetTint(col[1], col[2], col[3], col[4] or 1)
    return img
end

-- 背景工程微型点阵
function BCASScreen:BuildEngineeringGrid(parent, w, h)
    local cols, rows = 7, 10
    local step_x = w / (cols + 1)
    local step_y = h / (rows + 1)
    for c = 1, cols do
        for r = 1, rows do
            local x = -w/2 + c * step_x
            local y = -h/2 + r * step_y
            local dot = parent:AddChild(Image("images/global.xml", "square.tex"))
            dot:ScaleToSize(2, 2)
            dot:SetPosition(x, y)
            dot:SetTint(C.GRID_DOT[1], C.GRID_DOT[2], C.GRID_DOT[3], C.GRID_DOT[4])
        end
    end
end

-- 实验室光学四角取景 L 型标尺与刻度
function BCASScreen:BuildReticleMarks(parent, w, h, col)
    local len, thick = 14, 2
    local hw, hh = w / 2, h / 2
    local marks = {
        -- Top-Left
        {-hw, hh - thick/2, len, thick}, {-hw + thick/2, hh - len/2, thick, len},
        -- Top-Right
        {hw - len + thick, hh - thick/2, len, thick}, {hw - thick/2, hh - len/2, thick, len},
        -- Bottom-Left
        {-hw, -hh + thick/2, len, thick}, {-hw + thick/2, -hh + len/2, thick, len},
        -- Bottom-Right
        {hw - len + thick, -hh + thick/2, len, thick}, {hw - thick/2, -hh + len/2, thick, len},
    }
    for _, m in ipairs(marks) do
        local r = parent:AddChild(Image("images/global.xml", "square.tex"))
        r:ScaleToSize(m[3], m[4])
        r:SetPosition(m[1] + (m[3] > m[4] and m[3]/2 - thick/2 or 0), m[2])
        r:SetTint(col[1], col[2], col[3], 0.8)
    end

    -- 十字准星 (+)
    local function Cross(cx, cy)
        local h_ = parent:AddChild(Image("images/global.xml", "square.tex"))
        h_:ScaleToSize(10, 1.5)
        h_:SetPosition(cx, cy)
        h_:SetTint(C.OLIVE[1], C.OLIVE[2], C.OLIVE[3], 0.7)
        local v_ = parent:AddChild(Image("images/global.xml", "square.tex"))
        v_:ScaleToSize(1.5, 10)
        v_:SetPosition(cx, cy)
        v_:SetTint(C.OLIVE[1], C.OLIVE[2], C.OLIVE[3], 0.7)
    end
    Cross(-hw + 30, hh - 30)
    Cross(hw - 30, -hh + 30)
end

-- 虚线分隔线
function BCASScreen:Dashed(cx, y, w)
    local seg_w, gap = 8, 6
    local step = seg_w + gap
    local n = math.floor(w / step)
    local x0 = cx - (n - 1) * step / 2
    for i = 0, n - 1 do
        local d = self.chrome:AddChild(Image("images/global.xml", "square.tex"))
        d:ScaleToSize(seg_w, 1.5)
        d:SetPosition(x0 + i * step, y)
        d:SetTint(C.LINE_DARK[1], C.LINE_DARK[2], C.LINE_DARK[3], 0.85)
    end
end

-- 细线结构边框
function BCASScreen:FrameRect(parent, x, y, w, h, col, t)
    t = t or 1.5
    local fr = parent:AddChild(Widget("frame"))
    fr:SetPosition(x, y)
    local edges = {
        {0,  h / 2 - t / 2, w, t},
        {0, -h / 2 + t / 2, w, t},
        {-w / 2 + t / 2, 0, t, h},
        {w / 2 - t / 2, 0, t, h},
    }
    for _, e in ipairs(edges) do
        local img = fr:AddChild(Image("images/global.xml", "square.tex"))
        img:ScaleToSize(e[3], e[4])
        img:SetPosition(e[1], e[2])
        img:SetTint(col[1], col[2], col[3], col[4] or 1)
    end
    return fr
end

-- 安全文本排版
function BCASScreen:Label(parent, x, y, w, size, str, col, halign, h)
    local ha = halign or ANCHOR_LEFT
    local t = parent:AddChild(Text(F_CLEAN, size, str))
    local cx = x
    if ha == ANCHOR_LEFT then
        cx = x + w / 2
    elseif ha == ANCHOR_RIGHT then
        cx = x - w / 2
    end
    t:SetPosition(cx, y)
    t:SetRegionSize(w, h or size * 2.2)
    t:SetHAlign(ha)
    if h ~= nil or ha == ANCHOR_LEFT then
        t:SetVAlign(ANCHOR_TOP)
    else
        t:SetVAlign(ANCHOR_MIDDLE)
    end
    t:SetColour(col[1], col[2], col[3], col[4] or 1)
    return t
end

-- 芯片胶囊按钮
function BCASScreen:Chip(parent, x, y, w, h, label, active, onclick, fontsize)
    local btn = parent:AddChild(ImageButton("images/global.xml", "square.tex"))
    btn:SetPosition(x, y)
    btn:ForceImageSize(w, h)
    btn.scale_on_focus = false
    btn.move_on_click = false
    
    local normal_col = active and C.ESPRESSO or C.BG_CARD
    btn:SetImageNormalColour(normal_col[R], normal_col[G], normal_col[B], 1)
    btn:SetImageFocusColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    
    local t = btn:AddChild(Text(F_CLEAN, fontsize or 13, label))
    t:SetHAlign(ANCHOR_MIDDLE)
    t:SetVAlign(ANCHOR_MIDDLE)
    t:SetRegionSize(w, h)
    t:SetPosition(0, 0)
    local txt_col = active and C.TEXT_LIGHT or C.ESPRESSO
    t:SetColour(txt_col[R], txt_col[G], txt_col[B], 1)
    btn.text = t
    if onclick ~= nil then btn:SetOnClick(onclick) end
    return btn
end

function BCASScreen:RefreshChip(btn, active)
    local normal_col = active and C.ESPRESSO or C.BG_CARD
    btn:SetImageNormalColour(normal_col[R], normal_col[G], normal_col[B], 1)
    local txt_col = active and C.TEXT_LIGHT or C.ESPRESSO
    btn.text:SetColour(txt_col[R], txt_col[G], txt_col[B], 1)
end

-- ==== 6. 顶栏 / 预设 / 频道页签 =============================================

function BCASScreen:BuildHeader()
    -- 顶栏微标
    self:Label(self.chrome, -PANEL_W / 2 + 16, Y_HEADER + 14, 260, 11, STR.BRAND_TAG, C.OLIVE, ANCHOR_LEFT)
    self:Label(self.chrome, -PANEL_W / 2 + 16, Y_HEADER - 4, 180, 19, STR.TITLE, C.ESPRESSO, ANCHOR_LEFT)
    self:Label(self.chrome, -PANEL_W / 2 + 160, Y_HEADER - 5, 120, 13, STR.SUBTITLE, C.TEXT_MUTED, ANCHOR_LEFT)

    -- 电源总开关 (Power Instrument Switch)
    self.enable_btn = self:Chip(self.chrome, PANEL_W / 2 - 52, Y_HEADER + 2, 76, 28, "", true, nil, 13)
    self.enable_text = self.enable_btn.text
    self.enable_btn:SetOnClick(function()
        State.SetEnabled(not State.enabled)
        self:RefreshEnable()
        self:MakeDirty()
    end)
    self:RefreshEnable()
end

function BCASScreen:RefreshEnable()
    local on = State.enabled
    self.enable_btn:SetImageNormalColour(
        on and C.OLIVE[R] or C.BG_MUTED[R],
        on and C.OLIVE[G] or C.BG_MUTED[G],
        on and C.OLIVE[B] or C.BG_MUTED[B], 1)
    self.enable_text:SetColour(
        on and C.TEXT_LIGHT[R] or C.TEXT_MUTED[R],
        on and C.TEXT_LIGHT[G] or C.TEXT_MUTED[G],
        on and C.TEXT_LIGHT[B] or C.TEXT_MUTED[B], 1)
    self.enable_text:SetString(on and "● RUN" or "○ OFF")
end

function BCASScreen:BuildPresetRow()
    self:Label(self.chrome, -PANEL_W / 2 + 16, Y_PRESET, 52, 12, "校准", C.TEXT_MUTED, ANCHOR_LEFT)
    for i, preset in ipairs(STR.PRESETS) do
        local btn_w = 88
        local btn_x = -PANEL_W / 2 + 70 + btn_w / 2 + (i - 1) * (btn_w + 6)
        self:Chip(self.chrome, btn_x, Y_PRESET, btn_w, 26, preset.label, false, function()
            State.ApplyPreset(preset.key)
            self:MakeDirty()
            self:RefreshRows()
            self:RefreshWBChip()
        end, 12)
    end
end

function BCASScreen:BuildTabRow()
    self.tab_btns = {}
    local n = #STR.TABS
    local chip_w = math.floor((PANEL_W - 32 - (n - 1) * 3) / n)
    local step = chip_w + 3
    for i, label in ipairs(STR.TABS) do
        local btn_x = -PANEL_W / 2 + 16 + chip_w / 2 + (i - 1) * step
        local btn = self:Chip(self.chrome, btn_x, Y_TABS, chip_w, 28, label, i == self.tab, nil, 12)
        btn:SetOnClick(function()
            if self.tab ~= i then
                self.tab = i
                self:RefreshTabs()
                self:BuildContent()
            end
        end)
        self.tab_btns[i] = btn
    end
end

function BCASScreen:RefreshTabs()
    for i, btn in ipairs(self.tab_btns) do
        self:RefreshChip(btn, i == self.tab)
    end
end

-- ==== 7. 参数仪表卡片 (PRECISION ROW CARD) ==================================

function BCASScreen:BuildRow(key, y)
    local meta = State.VEC[key]
    local isbool = BOOL_KEYS[key] == true
    local row = self.content:AddChild(Widget("row_" .. key))
    row:SetPosition(0, y)
    table.insert(self.content_children, row)

    -- 1. 卡片底盘 + 细边框 (Porcelain Sub-Card)
    local bg = row:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(ROW_W, ROW_H)
    bg:SetTint(C.BG_CARD[R], C.BG_CARD[G], C.BG_CARD[B], 1)

    -- 2. 左侧光学通道指示条 (Channel Indicator Accent)
    local dot = row:AddChild(Image("images/global.xml", "square.tex"))
    dot:ScaleToSize(3.5, 16)
    dot:SetPosition(-ROW_W / 2 + 6, 0)
    dot:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 0.9)

    -- 3. 参数中英文名称
    self:Label(row, -ROW_W / 2 + 16, 0, 190, 14, STR.LABELS[key] or key, C.ESPRESSO, ANCHOR_LEFT)

    -- 4. 光学微型滑轨 (Optical Track Meter)
    local track, fill, needle
    if not isbool and meta then
        local norm = math.clamp((State.params[key] - meta.min) / (meta.max - meta.min), 0, 1)
        
        -- 底轨
        track = row:AddChild(Image("images/global.xml", "square.tex"))
        track:ScaleToSize(METER_W, 4)
        track:SetPosition(METER_X, 0)
        track:SetTint(C.LINE_LIGHT[R], C.LINE_LIGHT[G], C.LINE_LIGHT[B], 1)

        -- 填充条
        fill = row:AddChild(Image("images/global.xml", "square.tex"))
        fill:ScaleToSize(math.max(2, METER_W * norm), 4)
        fill:SetPosition(METER_X - METER_W/2 + (METER_W * norm)/2, 0)
        fill:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 0.85)

        -- 琥珀光标指针 (Needle)
        needle = row:AddChild(Image("images/global.xml", "square.tex"))
        needle:ScaleToSize(2.5, 12)
        needle:SetPosition(METER_X - METER_W/2 + METER_W * norm, 0)
        needle:SetTint(C.AMBER[R], C.AMBER[G], C.AMBER[B], 1)
    end

    -- 5. 瓷白数值视窗 (Display Box)
    self:FrameRect(row, VAL_X, 0, 58, 26, C.LINE_DARK, 1.5)
    local value_btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
    value_btn:SetPosition(VAL_X, 0)
    value_btn:ForceImageSize(56, 24)
    value_btn.scale_on_focus = false
    value_btn.move_on_click = false
    value_btn:SetImageNormalColour(C.CARD_WHITE[R], C.CARD_WHITE[G], C.CARD_WHITE[B], 1)
    value_btn:SetImageFocusColour(C.AMBER[R], C.AMBER[G], C.AMBER[B], 0.25)

    local value_text = value_btn:AddChild(Text(F_CLEAN, 13, ""))
    value_text:SetRegionSize(56, 24)
    value_text:SetPosition(0, 0)
    value_text:SetHAlign(ANCHOR_MIDDLE)
    value_text:SetVAlign(ANCHOR_MIDDLE)
    value_text:SetColour(C.ESPRESSO[R], C.ESPRESSO[G], C.ESPRESSO[B], 1)
    value_text:SetString(isbool
        and ((State.params[key] or 0) > 0.5 and "● ON" or "○ OFF")
        or string.format("%.2f", State.params[key]))

    -- 6. 复位微型芯片 (R Button)
    local reset_btn = self:Chip(row, RST_X, 0, 26, 26, "R", false, nil, 12)
    reset_btn:SetOnClick(function()
        State.ResetParam(key)
        self:RefreshRow(key)
        self:MakeDirty()
    end)

    -- 7. 交互绑定
    if isbool then
        value_btn:SetOnClick(function()
            State.SetParam(key, (State.params[key] or 0) > 0.5 and 0 or 1)
            self:RefreshRow(key)
            self:MakeDirty()
        end)
    else
        local drag = {active = false, moved = false, start_x = 0, start_value = 0}
        value_btn:SetOnDown(function()
            TheFrontEnd:LockFocus(true)
            drag.active = true
            drag.moved = false
            drag.start_x = TheFrontEnd.lastx
            drag.start_value = State.params[key]
        end)
        value_btn:SetWhileDown(function()
            if not drag.active then return end
            if math.abs(TheFrontEnd.lastx - drag.start_x) > 2 then drag.moved = true end
            local delta = (TheFrontEnd.lastx - drag.start_x) * (meta.max - meta.min) / 200
            local step = (meta.max - meta.min) > 4 and 0.1 or 0.01
            local v = math.clamp(drag.start_value + delta, meta.min, meta.max)
            v = v - v % step
            if v ~= State.params[key] then
                State.SetParam(key, v)
                self:RefreshRow(key)
                self:MakeDirty()
            end
        end)
        value_btn:SetOnClick(function()
            drag.active = false
            TheFrontEnd:LockFocus(false)
            if not drag.moved then
                self:OpenEdit(key, value_btn, value_text)
            end
        end)
        self:MakeEdit(row, key, VAL_X, 0, 56, 24, value_text,
            function(v) State.SetParam(key, v) end,
            function() return State.params[key] end,
            function() self:RefreshRow(key); self:MakeDirty() end)
    end

    self.rows[key] = {text = value_text, fill = fill, needle = needle, meta = meta, isbool = isbool}
end

function BCASScreen:RefreshRow(key)
    local entry = self.rows[key]
    if entry == nil then return end
    local v = State.params[key]
    if entry.isbool then
        entry.text:SetString((v or 0) > 0.5 and "● ON" or "○ OFF")
        return
    end
    entry.text:SetString(string.format("%.2f", v))
    local meta = entry.meta
    if meta and entry.fill ~= nil and entry.needle ~= nil then
        local norm = math.clamp((v - meta.min) / (meta.max - meta.min), 0, 1)
        entry.fill:ScaleToSize(math.max(2, METER_W * norm), 4)
        entry.fill:SetPosition(METER_X - METER_W/2 + (METER_W * norm)/2, 0)
        entry.needle:SetPosition(METER_X - METER_W/2 + METER_W * norm, 0)
    end
    if key == "Temp" or key == "Tint" then
        self:RefreshWBChip()
    end
end

function BCASScreen:RefreshRows()
    for key in pairs(self.rows) do
        self:RefreshRow(key)
    end
    self:RefreshWBChip()
end

-- ==== 8. 数值输入交互 (TextEdit) ============================================

function BCASScreen:MakeEdit(parent, tag, x, y, w, h, value_text, setter, getter, after)
    local edit = parent:AddChild(TextEdit(F_CLEAN, 13, "", C.ESPRESSO))
    edit:SetPosition(x, y)
    edit:SetRegionSize(w - 6, h)
    edit:SetHAlign(ANCHOR_MIDDLE)
    edit:SetEditCursorColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    edit:SetCharacterFilter("0123456789.-")
    edit:SetPassControlToScreen(CONTROL_CANCEL, true)
    edit:Hide()
    self.edits[tag] = {edit = edit, value_text = value_text, setter = setter, getter = getter, after = after}

    edit.OnTextEntered = function() self:CommitEdit(tag) end
    local base_losefocus = edit.OnLoseFocus
    edit.OnLoseFocus = function(wgt)
        base_losefocus(wgt)
        if self.active_edit == tag then self:CloseEdit(tag, false) end
    end
end

function BCASScreen:OpenEdit(tag, btn, value_text)
    local entry = self.edits[tag]
    if entry == nil then return end
    if self.active_edit == tag then
        self:CloseEdit(tag, false)
        return
    end
    if self.active_edit ~= nil then
        self:CloseEdit(self.active_edit, false)
    end
    self.active_edit = tag
    entry.value_text = value_text
    value_text:Hide()
    entry.edit:SetString(string.format("%.2f", entry.getter()))
    entry.edit:Show()
    entry.edit:MoveToFront()
    entry.edit:SetEditing(true)
    self.edit_skip = 2
end

function BCASScreen:CommitEdit(tag)
    local entry = self.edits[tag]
    if entry == nil then return end
    local meta = State.VEC[tag]
    local v = tonumber(entry.edit:GetString())
    if v ~= nil and meta ~= nil then
        entry.setter(math.clamp(v, meta.min, meta.max))
        if entry.after then entry.after() end
    end
    self:CloseEdit(tag, true)
end

function BCASScreen:CloseEdit(tag, keep)
    local entry = self.edits[tag]
    if entry == nil then return end
    if entry.edit.editing then entry.edit:SetEditing(false) end
    entry.edit:Hide()
    if entry.value_text ~= nil then
        entry.value_text:Show()
        entry.value_text:SetString(string.format("%.2f", entry.getter()))
    end
    if self.active_edit == tag then self.active_edit = nil end
end

function BCASScreen:OnUpdate(dt)
    if self.edit_skip and self.edit_skip > 0 then
        self.edit_skip = self.edit_skip - 1
        return
    end
    if self.active_edit ~= nil then
        local entry = self.edits[self.active_edit]
        if entry ~= nil and not entry.edit.editing then
            self:CloseEdit(self.active_edit, false)
        end
    end
end

-- ==== 9. 内容区加载 =========================================================

function BCASScreen:BuildContent()
    for _, wgt in ipairs(self.content_children) do wgt:Kill() end
    self.content_children = {}
    self.rows = {}
    self.wb_chip_swatch = nil
    self.wb_chip_hex = nil

    for tag in pairs(self.edits) do
        if string.sub(tag, 1, 4) ~= "gain" then self.edits[tag] = nil end
    end
    self.active_edit = nil

    local rows = TAB_ROWS[self.tab]
    for i, key in ipairs(rows) do
        self:BuildRow(key, Y_ROW0 - (i - 1) * ROW_STEP)
    end

    -- 实验室说明卡片 (SPECIFICATION NOTE)
    local note_y = Y_ROW0 - #rows * ROW_STEP - 18
    local note_card = self.content:AddChild(Widget("note_card"))
    note_card:SetPosition(0, note_y)
    table.insert(self.content_children, note_card)

    if self.tab == 1 then
        self:BuildNote(note_card, STR.SHARP_NOTE, 52)
    elseif self.tab == 2 then
        self:BuildNote(note_card, "进阶参数：算法与底层 Shader 一一对应；调节过度可按 R 复位或选用预设恢复。", 40)
    elseif self.tab == 3 then
        self:BuildWBLaunch(note_y)
    elseif self.tab == 5 then
        self:BuildNote(note_card, STR.ATMO_NOTE, 54)
    elseif self.tab == 6 then
        self:BuildNote(note_card, STR.GLOW_NOTE, 48)
    elseif self.tab == 7 then
        self:BuildNote(note_card, STR.GLOW2_NOTE, 54)
    end
end

function BCASScreen:BuildNote(parent, text, height)
    local bg = parent:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(ROW_W, height)
    bg:SetTint(C.CARD_WHITE[R], C.CARD_WHITE[G], C.CARD_WHITE[B], 0.88)

    local bar = parent:AddChild(Image("images/global.xml", "square.tex"))
    bar:ScaleToSize(3.5, height)
    bar:SetPosition(-ROW_W / 2 + 1.75, 0)
    bar:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)

    self:Label(parent, -ROW_W / 2 + 14, 0, ROW_W - 24, 12, text, C.TEXT_MUTED, ANCHOR_LEFT, height - 6)
end

-- 色彩页调色轮入口
function BCASScreen:BuildWBLaunch(y)
    local row = self.content:AddChild(Widget("wb_launch"))
    row:SetPosition(0, y)
    table.insert(self.content_children, row)

    local bg = row:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(ROW_W, 42)
    bg:SetTint(C.CARD_WHITE[R], C.CARD_WHITE[G], C.CARD_WHITE[B], 1)
    self:FrameRect(row, 0, 0, ROW_W, 42, C.OLIVE, 1.8)

    local accent = row:AddChild(Image("images/global.xml", "square.tex"))
    accent:ScaleToSize(5, 42)
    accent:SetPosition(-ROW_W / 2 + 2.5, 0)
    accent:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)

    local btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
    btn:SetPosition(0, 0)
    btn:ForceImageSize(ROW_W, 42)
    btn.scale_on_focus = false
    btn.move_on_click = false
    btn:SetImageNormalColour(1, 1, 1, 0)
    btn:SetImageFocusColour(C.AMBER[R], C.AMBER[G], C.AMBER[B], 0.15)
    btn:SetOnClick(function() self:OpenWBPopup() end)

    local swatch = row:AddChild(Image("images/global.xml", "square.tex"))
    swatch:ScaleToSize(28, 28)
    swatch:SetPosition(-ROW_W / 2 + 28, 0)
    self.wb_chip_swatch = swatch

    self:Label(row, -ROW_W / 2 + 50, 0, 240, 14, STR.WB_LAUNCH, C.ESPRESSO, ANCHOR_LEFT)

    local r, g, b = GainsFromParams()
    local cr, cg, cb = GainsToDisplay(r, g, b)
    swatch:SetTint(cr, cg, cb, 1)
    self.wb_chip_hex = self:Label(row, ROW_W / 2 - 14, 0, 84, 13, FmtHex(cr, cg, cb), C.TEXT_MUTED, ANCHOR_RIGHT)
end

function BCASScreen:RefreshWBChip()
    local r, g, b = GainsFromParams()
    local cr, cg, cb = GainsToDisplay(r, g, b)
    if self.wb_chip_swatch ~= nil then self.wb_chip_swatch:SetTint(cr, cg, cb, 1) end
    if self.wb_chip_hex ~= nil then self.wb_chip_hex:SetString(FmtHex(cr, cg, cb)) end
end

-- ==== 10. 底部保存 / 放弃区 =================================================

function BCASScreen:BuildFooter()
    -- 1. 保存按钮 (深焙黑巧主色)
    local apply = self:Chip(self.chrome, -82, Y_BTNS, 184, 36, STR.APPLY, true, function() self:Apply() end, 14)
    apply:SetImageNormalColour(C.ESPRESSO[R], C.ESPRESSO[G], C.ESPRESSO[B], 1)
    apply:SetImageFocusColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    apply.text:SetColour(C.TEXT_LIGHT[R], C.TEXT_LIGHT[G], C.TEXT_LIGHT[B], 1)

    -- 2. 放弃按钮
    local cancel = self:Chip(self.chrome, 92, Y_BTNS, 120, 36, STR.CANCEL, false, function() self:Cancel() end, 14)

    -- 3. 提示与状态
    self:Label(self.chrome, 0, Y_HINT, PANEL_W - 32, 11, STR.HINT, C.TEXT_MUTED, ANCHOR_MIDDLE)
end

-- ==== 11. 光学光谱分析仪 (WHITE BALANCE SPECTRUM ANALYZER) ==================

local HUE_N = 48
local SV_COLS, SV_ROWS, SV_CELL = 20, 14, 14
local RING_CX, RING_CY, RING_R = -130, 60, 72
local GRID_CX, GRID_CY = 95, 118
local GAIN_MIN, GAIN_MAX = 0.55, 1.85

function BCASScreen:BuildWBPopup()
    self.wb_popup = self.root:AddChild(Widget("wb_popup"))
    self.wb_popup:SetPosition(PANEL_X, -10)
    self.wb_popup:Hide()

    local W, H = PANEL_W, 530

    -- 弹窗底盘与标尺
    self:SolidRect(self.wb_popup, 0, 0, W + 6, H + 6, C.ESPRESSO)
    self:SolidRect(self.wb_popup, 0, 0, W, H, C.BG_CANVAS)
    self:BuildReticleMarks(self.wb_popup, W - 16, H - 16, C.ESPRESSO)

    -- 顶栏
    local header = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    header:ScaleToSize(W, 46)
    header:SetPosition(0, H / 2 - 23)
    header:SetTint(C.ESPRESSO[R], C.ESPRESSO[G], C.ESPRESSO[B], 1)

    self:Label(self.wb_popup, -W / 2 + 16, H / 2 - 23, 220, 16, STR.WB_TITLE, C.TEXT_LIGHT, ANCHOR_LEFT)
    self:Label(self.wb_popup, 136, H / 2 - 23, 140, 12, STR.WB_SUB, C.AMBER, ANCHOR_RIGHT)

    local close = self:Chip(self.wb_popup, W / 2 - 46, H / 2 - 23, 64, 28, STR.WB_CLOSE, true, function()
        self.wb_popup:Hide()
    end, 13)
    close:SetImageNormalColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    close.text:SetColour(C.TEXT_LIGHT[R], C.TEXT_LIGHT[G], C.TEXT_LIGHT[B], 1)

    -- 色相环
    self.hue_tiles = {}
    for i = 0, HUE_N - 1 do
        local hue = i / HUE_N
        local ang = hue * 2 * math.pi
        local x = RING_CX + math.cos(ang) * RING_R
        local y = RING_CY + math.sin(ang) * RING_R
        local r, g, b = hsv2rgb(hue, 1, 1)
        local tile = self.wb_popup:AddChild(ImageButton("images/global.xml", "square.tex"))
        tile:SetPosition(x, y)
        tile:ForceImageSize(16, 16)
        tile.scale_on_focus = false
        tile.move_on_click = false
        tile:SetImageNormalColour(r, g, b, 1)
        tile:SetImageFocusColour(r, g, b, 1)
        tile:SetOnClick(function()
            self.wb_h = hue
            self:SyncWheel(false)
        end)
        self.hue_tiles[i] = tile
    end
    self.hue_marker = self:FrameRect(self.wb_popup, 0, 0, 22, 22, C.CARD_WHITE, 2)

    -- 环心预览色块 + HEX
    self:FrameRect(self.wb_popup, RING_CX, RING_CY, 60, 60, C.LINE_DARK, 2)
    self.wb_preview = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    self.wb_preview:ScaleToSize(54, 54)
    self.wb_preview:SetPosition(RING_CX, RING_CY)
    self.wb_hex = self:Label(self.wb_popup, RING_CX, RING_CY - 44, 90, 12, "#FFFFFF", C.TEXT_MUTED, ANCHOR_MIDDLE)

    -- SV 饱和/明度矩阵方阵
    self.sv_cells = {}
    for r_i = 0, SV_ROWS - 1 do
        for c_i = 0, SV_COLS - 1 do
            local x = GRID_CX - (SV_COLS * SV_CELL) / 2 + SV_CELL / 2 + c_i * SV_CELL
            local y = GRID_CY + (SV_ROWS * SV_CELL) / 2 - SV_CELL / 2 - r_i * SV_CELL
            local rr, gg, bb = hsv2rgb(self.wb_h or 0, c_i / (SV_COLS - 1), 1 - r_i / (SV_ROWS - 1))
            local cell = self.wb_popup:AddChild(ImageButton("images/global.xml", "square.tex"))
            cell:SetPosition(x, y)
            cell:ForceImageSize(SV_CELL, SV_CELL)
            cell.scale_on_focus = false
            cell.move_on_click = false
            cell:SetImageNormalColour(rr, gg, bb, 1)
            cell:SetImageFocusColour(rr, gg, bb, 1)
            cell:SetOnClick(function()
                self.wb_s = c_i / (SV_COLS - 1)
                self.wb_v = 1 - r_i / (SV_ROWS - 1)
                self:SyncWheel(true)
            end)
            self.sv_cells[r_i * SV_COLS + c_i] = cell
        end
    end
    self.sv_marker = self:FrameRect(self.wb_popup, 0, 0, 20, 20, C.CARD_WHITE, 2)
    self:Label(self.wb_popup, GRID_CX, GRID_CY - (SV_ROWS * SV_CELL) / 2 - 16, 240, 11, STR.WB_AXIS, C.TEXT_MUTED, ANCHOR_MIDDLE)

    -- RGB 增益校准通道
    self:Label(self.wb_popup, -W / 2 + 16, -30, 280, 12, "# RGB 增益校准通道 (映射至色温与色调)", C.OLIVE, ANCHOR_LEFT)
    self.gain_rows = {}
    local names = {"R", "G", "B"}
    for i = 1, 3 do
        local y = -58 - (i - 1) * 44
        local row = self.wb_popup:AddChild(Widget("gain_" .. names[i]))
        row:SetPosition(0, y)

        local chip = self:Chip(row, -W / 2 + 32, 0, 28, 26, names[i], true, nil, 13)
        local chr, cgg, cbb = hsv2rgb(i == 1 and 0 or (i == 2 and 0.33 or 0.66), 0.55, 1)
        chip:SetImageNormalColour(chr, cgg, cbb, 1)
        chip.text:SetColour(0.12, 0.09, 0.06, 1)

        -- 标尺格
        for ci = 0, 10 do
            local gv = GAIN_MIN + (GAIN_MAX - GAIN_MIN) * ci / 10
            local disp = math.min(1, 0.55 + 0.45 * (gv - GAIN_MIN) / (GAIN_MAX - GAIN_MIN))
            local cell = row:AddChild(ImageButton("images/global.xml", "square.tex"))
            cell:SetPosition(-160 + ci * 18, 0)
            cell:ForceImageSize(18, 26)
            cell.scale_on_focus = false
            cell.move_on_click = false
            local cr, cg, cb2 = 0.85, 0.85, 0.85
            if i == 1 then cr = disp elseif i == 2 then cg = disp else cb2 = disp end
            cell:SetImageNormalColour(cr, cg, cb2, 1)
            cell:SetImageFocusColour(cr, cg, cb2, 1)
            cell:SetOnClick(function()
                self.wb_gain[i] = gv
                self:SyncFromGains()
            end)
        end
        local marker = row:AddChild(Image("images/global.xml", "square.tex"))
        marker:ScaleToSize(4, 30)
        marker:SetPosition(-160, 0)
        marker:SetTint(C.ESPRESSO[R], C.ESPRESSO[G], C.ESPRESSO[B], 1)

        -- 瓷白数值框
        local value_btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
        value_btn:SetPosition(VAL_X, 0)
        value_btn:ForceImageSize(58, 26)
        value_btn.scale_on_focus = false
        value_btn.move_on_click = false
        value_btn:SetImageNormalColour(C.CARD_WHITE[R], C.CARD_WHITE[G], C.CARD_WHITE[B], 1)
        value_btn:SetImageFocusColour(C.AMBER[R], C.AMBER[G], C.AMBER[B], 0.3)

        local value_text = value_btn:AddChild(Text(F_CLEAN, 13, "1.00"))
        value_text:SetRegionSize(58, 26)
        value_text:SetPosition(0, 0)
        value_text:SetHAlign(ANCHOR_MIDDLE)
        value_text:SetVAlign(ANCHOR_MIDDLE)
        value_text:SetColour(C.ESPRESSO[R], C.ESPRESSO[G], C.ESPRESSO[B], 1)

        self:MakeGainEdit(row, i, value_text)

        local gdrag = {active = false, moved = false, start_x = 0, start_v = 1}
        value_btn:SetOnDown(function()
            TheFrontEnd:LockFocus(true)
            gdrag.active = true
            gdrag.moved = false
            gdrag.start_x = TheFrontEnd.lastx
            gdrag.start_v = self.wb_gain[i]
        end)
        value_btn:SetWhileDown(function()
            if not gdrag.active then return end
            if math.abs(TheFrontEnd.lastx - gdrag.start_x) > 2 then gdrag.moved = true end
            local v = math.clamp(gdrag.start_v + (TheFrontEnd.lastx - gdrag.start_x) / 200, GAIN_MIN, GAIN_MAX)
            v = v - v % 0.01
            if v ~= self.wb_gain[i] then
                self.wb_gain[i] = v
                self:SyncFromGains()
            end
        end)
        value_btn:SetOnClick(function()
            gdrag.active = false
            TheFrontEnd:LockFocus(false)
            if not gdrag.moved then self:OpenEdit("gain" .. i, value_btn, value_text) end
        end)

        local reset_btn = self:Chip(row, RST_X, 0, 26, 26, "R", false, nil, 12)
        reset_btn:SetOnClick(function()
            self.wb_gain[i] = 1.0
            self:SyncFromGains()
        end)

        self.gain_rows[i] = {text = value_text, marker = marker}
    end

    -- 快捷预设
    for i, p in ipairs(STR.WB_PRESETS) do
        self:Chip(self.wb_popup, -PANEL_W / 2 + 36 + (i - 1) * 72, -196, 66, 26, p.label, false, function()
            self.wb_gain = {p.v[1], p.v[2], p.v[3]}
            self:SyncFromGains()
        end, 12)
    end
    self:Chip(self.wb_popup, PANEL_W / 2 - 44, -196, 68, 26, STR.WB_RESET, false, function()
        self.wb_gain = {1.0, 1.0, 1.0}
        self:SyncFromGains()
    end, 12)

    self:Label(self.wb_popup, 0, -238, W - 40, 11, STR.WB_TIP, C.TEXT_MUTED, ANCHOR_MIDDLE)
end

function BCASScreen:MakeGainEdit(parent, i, value_text)
    local edit = parent:AddChild(TextEdit(F_CLEAN, 13, "", C.ESPRESSO))
    edit:SetPosition(VAL_X, 0)
    edit:SetRegionSize(52, 26)
    edit:SetHAlign(ANCHOR_MIDDLE)
    edit:SetEditCursorColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    edit:SetCharacterFilter("0123456789.-")
    edit:SetPassControlToScreen(CONTROL_CANCEL, true)
    edit:Hide()
    local tag = "gain" .. i
    self.edits[tag] = {edit = edit, value_text = value_text,
        getter = function() return self.wb_gain[i] end,
        setter = function(v) self.wb_gain[i] = math.clamp(v, GAIN_MIN, GAIN_MAX) end,
        after = function() self:SyncFromGains() end}
    edit.OnTextEntered = function() self:CommitEdit(tag) end
    local base_losefocus = edit.OnLoseFocus
    edit.OnLoseFocus = function(wgt)
        base_losefocus(wgt)
        if self.active_edit == tag then self:CloseEdit(tag, false) end
    end
end

function BCASScreen:SyncWheel(sv_changed)
    local r, g, b = hsv2rgb(self.wb_h, self.wb_s, self.wb_v)
    if self.wb_v < 0.04 then r, g, b = 1, 1, 1 end
    SetGainsFromColor(r, g, b)
    self.wb_gain = {GainsFromParams()}
    self:SyncWheelUI()
    self:MakeDirty()
end

function BCASScreen:SyncFromGains()
    local gr, gg, gb = self.wb_gain[1], self.wb_gain[2], self.wb_gain[3]
    local T, Ti = State.GainToTempTint(gr, gg, gb)
    State.SetParam("Temp", T)
    State.SetParam("Tint", Ti)
    local cr, cg, cb = GainsToDisplay(gr, gg, gb)
    local h, s, v = rgb2hsv(cr, cg, cb)
    self.wb_h, self.wb_s, self.wb_v = h, s, v
    self:SyncWheelUI()
    self:MakeDirty()
end

function BCASScreen:SyncWheelUI()
    local cr, cg, cb = GainsToDisplay(self.wb_gain[1], self.wb_gain[2], self.wb_gain[3])
    self.wb_preview:SetTint(cr, cg, cb, 1)
    self.wb_hex:SetString(FmtHex(cr, cg, cb))

    for r_i = 0, SV_ROWS - 1 do
        for c_i = 0, SV_COLS - 1 do
            local cell = self.sv_cells[r_i * SV_COLS + c_i]
            if cell ~= nil then
                local rr, gg, bb = hsv2rgb(self.wb_h, c_i / (SV_COLS - 1), 1 - r_i / (SV_ROWS - 1))
                cell:SetImageNormalColour(rr, gg, bb, 1)
                cell:SetImageFocusColour(rr, gg, bb, 1)
            end
        end
    end

    local hi = math.floor(self.wb_h * HUE_N + 0.5) % HUE_N
    local ang = hi / HUE_N * 2 * math.pi
    self.hue_marker:SetPosition(RING_CX + math.cos(ang) * RING_R, RING_CY + math.sin(ang) * RING_R)
    self.hue_marker:MoveToFront()

    local col = math.floor(self.wb_s * (SV_COLS - 1) + 0.5)
    local row = math.floor((1 - self.wb_v) * (SV_ROWS - 1) + 0.5)
    self.sv_marker:SetPosition(
        GRID_CX - (SV_COLS * SV_CELL) / 2 + SV_CELL / 2 + col * SV_CELL,
        GRID_CY + (SV_ROWS * SV_CELL) / 2 - SV_CELL / 2 - row * SV_CELL)
    self.sv_marker:MoveToFront()

    for i = 1, 3 do
        local entry = self.gain_rows[i]
        if entry ~= nil then
            entry.text:SetString(string.format("%.2f", self.wb_gain[i]))
            local norm = math.clamp((self.wb_gain[i] - GAIN_MIN) / (GAIN_MAX - GAIN_MIN), 0, 1)
            entry.marker:SetPosition(-160 + norm * 180, 0)
        end
    end

    self:RefreshWBChip()
end

function BCASScreen:OpenWBPopup()
    self.wb_gain = {GainsFromParams()}
    local cr, cg, cb = GainsToDisplay(self.wb_gain[1], self.wb_gain[2], self.wb_gain[3])
    self.wb_h, self.wb_s, self.wb_v = rgb2hsv(cr, cg, cb)
    self:SyncWheelUI()
    self.wb_popup:Show()
    self.wb_popup:MoveToFront()
end

-- ==== 12. 生命周期与事件 ====================================================

function BCASScreen:MakeDirty(dirty)
    self.dirty = dirty ~= nil and dirty or true
end

function BCASScreen:Apply()
    State.Save()
    self.dirty = false
    TheFrontEnd:PopScreen()
end

function BCASScreen:Cancel()
    if State.saved_params ~= nil then
        for key in pairs(State.VEC) do
            local v = State.saved_params[key]
            if v ~= nil then State.SetParam(key, v) end
        end
        State.SetEnabled(State.saved_enabled)
    end
    self.dirty = false
    TheFrontEnd:PopScreen()
end

function BCASScreen:OnControl(control, down)
    if BCASScreen._base.OnControl(self, control, down) then return true end
    if not down and control == CONTROL_CANCEL then
        if self.active_edit ~= nil then
            self:CloseEdit(self.active_edit, false)
            return true
        end
        if self.wb_popup.shown then
            self.wb_popup:Hide()
            return true
        end
        self:Cancel()
        return true
    end
end

return BCASScreen