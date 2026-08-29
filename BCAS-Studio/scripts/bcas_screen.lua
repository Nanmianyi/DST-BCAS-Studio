--[[ BCAS Studio —— 设置面板 v3

视觉：楠眠已 LAB 博客风（奶油纸底 / 深棕墨色 / 橄榄绿点缀 / # 与 // 装饰 /
虚线分隔），浅底文字一律无描边干净字体（BCAS_FONT_CLEAN，见 modmain）。

布局纪律（防重叠/超框）：
  * 面板 470x670，所有 y 坐标走同一张台账（见 BuildXXX 各常量）；
  * 所有 Text 必须给 SetRegionSize + 对齐，禁止让文字自由伸展；
  * 文字宽度按 15pt 中文约 15px/字、拉丁约 8px/字 预算，区域留 10% 余量。

交互：
  * 数值框：按住左右拖动（ReShade 式）；单击弹出输入框可直接键入任意值；
  * R 按钮：恢复该参数默认值；
  * 色彩页：白平衡调色轮（色相环 + 饱和/明度方格 + RGB 增益行 + 快捷预设），
    增益经 GainToTempTint 映射到 Temp/Tint 两个 uniform，不占新 uniform。
]]

local Screen = require "widgets/screen"
local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Text = require "widgets/text"
local ImageButton = require "widgets/imagebutton"
local TextEdit = require "widgets/textedit"

local State = require "bcas_state"

-- 无描边干净字体（HDFONT 开启时由 modmain rawset 注入；关闭时回落到游戏原 UIFONT）
-- 注意：本文件经 require 跑在游戏环境（没有 modenv 的 GLOBAL 名字），
-- 且 strict.lua 对未声明名字的普通读取会报错，必须 rawget(_G, ...) 绕过。
local F_CLEAN = rawget(_G, "BCAS_FONT_CLEAN") or UIFONT

-- ==== 博客色板（取自楠眠已 LAB） ==========================================
local C = {
    CREAM      = {0.949, 0.937, 0.902, 1},   -- 页面底 #F2EFE6
    CREAM_ALT  = {0.914, 0.894, 0.835, 1},   -- 行底 #E9E4D5
    PAPER      = {0.980, 0.969, 0.933, 1},   -- 卡片/数值框 #FAF7EE
    BROWN      = {0.180, 0.137, 0.090, 1},   -- 墨棕 #2E2317
    BROWN_MID  = {0.352, 0.278, 0.196, 1},   -- 次强调
    BROWN_SOFT = {0.431, 0.373, 0.294, 1},   -- 说明文字 #6E5F4B
    LINE       = {0.788, 0.753, 0.663, 1},   -- 边框线 #C9C0A9
    OLIVE      = {0.486, 0.604, 0.247, 1},   -- 橄榄绿 #7C9A3F
    OLIVE_DK   = {0.361, 0.463, 0.157, 1},
    CREAM_TXT  = {0.961, 0.937, 0.867, 1},   -- 深底上的米白字
}
local R, G, B = 1, 2, 3 -- 可读性别名

-- ==== 布局台账 =============================================================
local PANEL_W, PANEL_H = 470, 670
local PANEL_X = 12 + PANEL_W / 2       -- ANCHOR_LEFT 原点在屏幕左缘
local ROW_W = PANEL_W - 32             -- 行宽 438
local ROW_H = 34
local ROW_STEP = 40
local VAL_X = 134                      -- 数值框中心 x（面板局部）
local RST_X = 196                      -- 重置按钮中心 x

-- 纵向：335 顶 → [312 头] [262 预设] [244 虚线] [216 页签] [192 虚线]
--       行区 160..-137 → [-262 虚线] [-292 按钮] [-322 提示]
local Y_HEADER, Y_PRESET, Y_TABS = 312, 262, 216
local Y_DIV1, Y_DIV2, Y_DIV3 = 244, 192, -262
local Y_ROW0, Y_BTNS, Y_HINT = 160, -292, -322

local STR = {
    TITLE = "# BCAS STUDIO",
    SUBTITLE = "// 画质工作室",
    APPLY = "# 应用并保存",
    CANCEL = "# 放弃",
    PRESETS = {
        {key = "standard", label = "作者特调"},
        {key = "light",    label = "轻量"},
        {key = "cinema",   label = "电影"},
        {key = "off",      label = "关闭"},
    },
    HINT = "拖数值微调 · 点数值键入 · R 重置 · PgDn 保存 · ESC 放弃 · P 开关",
    TABS = {"锐化", "进阶", "色彩", "调色", "氛围"},
    LABELS = {
        Strength = "锐化强度 STRENGTH", NoiseReduce = "降噪 DENOISE",
        AntiRinging = "抗振铃 AURA", DarkProtect = "暗部保护 DARK",
        ExposureEV = "曝光 EXPOSURE EV", Saturation = "饱和度 SAT",
        Vibrance = "自然饱和 VIBRANCE", Contrast = "对比度 CONTRAST",
        Lightness = "亮度 LIGHTNESS", Gamma = "GAMMA",
        Filmic = "胶片曲线 ACES",
        Vignette = "暗角 VIGNETTE", Grain = "颗粒 GRAIN",
        RangeSigma = "双边范围σ RANGE", SpatialSigma = "空间σ SPATIAL",
        CenterWeight = "中心权重 CENTER", NoiseFloor = "噪声基底 FLOOR",
        AR_Threshold = "AURA 边缘阈值", AR_L_Overshoot = "AURA 亮部过冲",
        AR_D_Overshoot = "AURA 暗部过冲", ChromaProtect = "色度保护 CHROMA",
        HL_Desat = "高光去饱和 HL-DESAT", OriginalMix = "原始混合 ORIGINAL",
        SlopeR = "一级斜率 R SLOPE", SlopeG = "一级斜率 G SLOPE", SlopeB = "一级斜率 B SLOPE",
        OffsetR = "一级偏移 R OFFSET", OffsetG = "一级偏移 G OFFSET", OffsetB = "一级偏移 B OFFSET",
        PowerR = "一级幂 R POWER", PowerG = "一级幂 G POWER", PowerB = "一级幂 B POWER",
        ColourCubeOn = "原版昼夜滤镜 VANILLA",
    },
    SHARP_NOTE = "双边自适应锐化：只锐世界画面，HUD 不受影响；抗振铃(AURA)调到 0 可完全关闭过冲抑制；改乱了点行尾 R 复位。",
    WB_LAUNCH = "白平衡 · 调色轮（点击进入）",
    WB_TIP = "在色轮上取色会映射为 RGB 增益，等效于 ReShade 的 CDL 斜率",
    ATMO_NOTE = "暗角：压暗四角聚焦视线；颗粒：动态胶片颗粒(8Hz 闪动)；原版昼夜滤镜：开关游戏自带 ColourCube 调色。",
    WB_TITLE = "# 色彩轮 / 白平衡",
    WB_SUB = "// CDL SLOPE",
    WB_CLOSE = "关闭",
    WB_AXIS = "右 = 饱和 · 上 = 明度 · 环 = 色相",
    WB_PRESETS = {
        {label = "标准", v = {1.0, 1.0, 1.0}},
        {label = "暖",   v = {1.08, 1.0, 0.90}},
        {label = "冷",   v = {0.90, 1.0, 1.10}},
        {label = "品红", v = {1.06, 0.94, 1.06}},
        {label = "草绿", v = {0.94, 1.08, 0.92}},
    },
    WB_RESET = "1:1",
    EDIT_TITLE = "输入数值后回车（ESC 取消）",
}

local TAB_ROWS = {
    [1] = {"Strength", "NoiseReduce", "AntiRinging", "DarkProtect"},
    [2] = {"RangeSigma", "SpatialSigma", "CenterWeight", "NoiseFloor",
           "AR_Threshold", "AR_L_Overshoot", "AR_D_Overshoot", "ChromaProtect"},
    [3] = {"ExposureEV", "Saturation", "Vibrance", "Contrast", "Lightness",
           "Gamma", "Filmic", "HL_Desat", "OriginalMix"},
    [4] = {"SlopeR", "SlopeG", "SlopeB", "OffsetR", "OffsetG", "OffsetB",
           "PowerR", "PowerG", "PowerB"},
    [5] = {"Vignette", "Grain", "ColourCubeOn"},
}

-- 开关型参数行：值区显示 ON/OFF 胶片，点击切换（不走拖拽/键入）
local BOOL_KEYS = { ColourCubeOn = true }

-- ==== 颜色数学 =============================================================

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

-- Temp/Tint -> RGB 增益（State.GainToTempTint 的精确逆）
local function GainsFromParams()
    local T, Ti = State.params.Temp, State.params.Tint
    return 2 ^ (0.2 * T), 2 ^ (0.12 * Ti), 2 ^ (-0.2 * T)
end

-- 增益 -> 显示色（归一化到最大分量 1，便于当颜色看）
local function GainsToDisplay(r, g, b)
    local mx = math.max(r, g, b, 1e-6)
    return r / mx, g / mx, b / mx
end

-- 色轮取色 -> RGB 增益（按亮度归一，保持通道比值），写回 Temp/Tint
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

    -- 面板装饰层：root 原点在屏幕左缘（ANCHOR_LEFT），不是面板中心！
    -- 标题/预设/页签/底栏等一切用"面板中心坐标"的静态件必须挂在这里，
    -- 否则整体左移一个 PANEL_X 跑出屏幕（v3 首测翻车的教训）。
    self.chrome = self.root:AddChild(Widget("chrome"))
    self.chrome:SetPosition(PANEL_X, 0)

    -- 面板底盘 + 墨棕描边（博客卡片风）
    self:Rect(0, 0, PANEL_W + 4, PANEL_H + 4, C.BROWN)
    self:Rect(0, 0, PANEL_W, PANEL_H, C.CREAM)

    self:BuildHeader()
    self:BuildPresetRow()
    self:Dashed(0, Y_DIV1, PANEL_W - 48)
    self:BuildTabRow()
    self:Dashed(0, Y_DIV2, PANEL_W - 48)

    self.content = self.root:AddChild(Widget("content"))
    self.content:SetPosition(PANEL_X, 0)
    self:BuildContent()

    self:Dashed(0, Y_DIV3, PANEL_W - 48)
    self:BuildFooter()
    self:BuildWBPopup()

    self.default_focus = self.enable_btn
end)

-- ==== 基础件 ===============================================================

function BCASScreen:Rect(x, y, w, h, col)
    local img = self.chrome:AddChild(Image("images/global.xml", "square.tex"))
    img:ScaleToSize(w, h)
    img:SetPosition(x, y)
    img:SetTint(col[1], col[2], col[3], col[4] or 1)
    return img
end

-- 虚线分隔（博客风格细节）
function BCASScreen:Dashed(cx, y, w)
    local n = math.floor(w / 14)
    local x0 = cx - (n - 1) * 14 / 2
    for i = 0, n - 1 do
        local d = self.chrome:AddChild(Image("images/global.xml", "square.tex"))
        d:ScaleToSize(7, 2)
        d:SetPosition(x0 + i * 14, y)
        d:SetTint(C.LINE[1], C.LINE[2], C.LINE[3], 1)
    end
end

-- 1px 感细边框（四条细矩形，返回可整体移动的 widget）
function BCASScreen:FrameRect(parent, x, y, w, h, col, t)
    t = t or 2
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
        img:SetTint(col[1], col[2], col[3], 1)
    end
    return fr
end

-- x 语义：LEFT = 文本左缘，RIGHT = 文本右缘，MIDDLE = 文本中心。
-- 关坑：DST 的 Text 区域以"区域中心"对齐到控件坐标，若把区域中心直接
-- 设在期望的文本边缘，文本会整体偏移半个区域宽（v3 首测：行标签整体
-- 飞出屏幕左侧、"R=重置"提示悬空到面板外、标题消失，全是这一根因）。
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
    -- 区域高度给足 2 倍字号：高清位图字体实际行高偏大，贴边区域会把单行文本裁没
    t:SetRegionSize(w, h or size * 2)
    t:SetHAlign(ha)
    -- 引擎实测怪癖：HAlign LEFT 的文本不显式设 VAlign 就整段不渲染
    -- （LEFT+TOP 验证可用；MIDDLE/RIGHT 配 MIDDLE 验证可用）
    if h ~= nil or ha == ANCHOR_LEFT then
        t:SetVAlign(ANCHOR_TOP)
    else
        t:SetVAlign(ANCHOR_MIDDLE)
    end
    t:SetColour(col[1], col[2], col[3], 1)
    return t
end

-- 博客风胶囊按钮：active=墨棕底米白字，idle=浅底棕字，focus=橄榄深
function BCASScreen:Chip(parent, x, y, w, h, label, active, onclick, fontsize)
    local btn = parent:AddChild(ImageButton("images/global.xml", "square.tex"))
    btn:SetPosition(x, y)
    btn:ForceImageSize(w, h)
    btn.scale_on_focus = false
    btn.move_on_click = false
    btn:SetImageNormalColour(
        active and C.BROWN[R] or C.CREAM_ALT[R],
        active and C.BROWN[G] or C.CREAM_ALT[G],
        active and C.BROWN[B] or C.CREAM_ALT[B], 1)
    btn:SetImageFocusColour(C.OLIVE_DK[R], C.OLIVE_DK[G], C.OLIVE_DK[B], 1)
    local t = btn:AddChild(Text(F_CLEAN, fontsize or 15, label))
    t:SetHAlign(ANCHOR_MIDDLE)
    t:SetVAlign(ANCHOR_MIDDLE)
    t:SetRegionSize(w, h)
    t:SetPosition(0, 0)
    t:SetColour(active and C.CREAM_TXT[R] or C.BROWN[R],
                active and C.CREAM_TXT[G] or C.BROWN[G],
                active and C.CREAM_TXT[B] or C.BROWN[B], 1)
    btn.text = t
    if onclick ~= nil then btn:SetOnClick(onclick) end
    return btn
end

function BCASScreen:RefreshChip(btn, active)
    btn:SetImageNormalColour(
        active and C.BROWN[R] or C.CREAM_ALT[R],
        active and C.BROWN[G] or C.CREAM_ALT[G],
        active and C.BROWN[B] or C.CREAM_ALT[B], 1)
    btn.text:SetColour(active and C.CREAM_TXT[R] or C.BROWN[R],
                       active and C.CREAM_TXT[G] or C.BROWN[G],
                       active and C.CREAM_TXT[B] or C.BROWN[B], 1)
end

-- ==== 标题栏 / 预设 / 页签 ==================================================

function BCASScreen:BuildHeader()
    local title = self:Label(self.chrome, -PANEL_W / 2 + 14, Y_HEADER, 220, 19, STR.TITLE, C.CREAM_TXT, ANCHOR_LEFT)
    local sub = self:Label(self.chrome, PANEL_W / 2 - 88, Y_HEADER, 120, 14, STR.SUBTITLE, C.OLIVE, ANCHOR_RIGHT)

    self.enable_btn = self:Chip(self.chrome, PANEL_W / 2 - 50, Y_HEADER, 64, 28, "", true, nil, 14)
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
    -- ON = 橄榄绿点亮；OFF = 线框灰底
    self.enable_btn:SetImageNormalColour(
        on and C.OLIVE[R] or C.CREAM_ALT[R],
        on and C.OLIVE[G] or C.CREAM_ALT[G],
        on and C.OLIVE[B] or C.CREAM_ALT[B], 1)
    self.enable_text:SetString(on and "ON" or "OFF")
end

function BCASScreen:BuildPresetRow()
    self:Label(self.chrome, -PANEL_W / 2 + 14, Y_PRESET, 52, 13, "预设", C.OLIVE, ANCHOR_LEFT)
    for i, preset in ipairs(STR.PRESETS) do
        self:Chip(self.chrome, -PANEL_W / 2 + 70 + 43 + (i - 1) * 94, Y_PRESET, 86, 28, preset.label, false, function()
            State.ApplyPreset(preset.key)
            self:MakeDirty()
            self:RefreshRows()
            self:RefreshWBChip()
        end, 13)
    end
end

function BCASScreen:BuildTabRow()
    self.tab_btns = {}
    for i, label in ipairs(STR.TABS) do
        local btn = self:Chip(self.chrome, -PANEL_W / 2 + 14 + 40 + (i - 1) * 90, Y_TABS, 80, 30, label, i == self.tab, nil, 14)
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

-- ==== 数值行 ===============================================================
-- 行结构（面板局部坐标，x 相对 content 中心 0）：
--   [bg 438x34] [label 左对齐 x=-207 区域 236] [数值框 86x26 @134] [R 26x26 @196]

function BCASScreen:BuildRow(key, y)
    local meta = State.VEC[key]
    local isbool = BOOL_KEYS[key] == true
    local row = self.content:AddChild(Widget("row_" .. key))
    row:SetPosition(0, y)
    table.insert(self.content_children, row)

    local bg = row:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(ROW_W, ROW_H)
    bg:SetTint(C.CREAM_ALT[R], C.CREAM_ALT[G], C.CREAM_ALT[B], 1)

    self:Label(row, -ROW_W / 2 + 12, 0, 236, 15, STR.LABELS[key] or key, C.BROWN, ANCHOR_LEFT)

    -- 数值框：细边框 + 纸色按钮
    self:FrameRect(row, VAL_X, 0, 90, 30, C.LINE, 2)
    local value_btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
    value_btn:SetPosition(VAL_X, 0)
    value_btn:ForceImageSize(86, 26)
    value_btn.scale_on_focus = false
    value_btn.move_on_click = false
    value_btn:SetImageNormalColour(C.PAPER[R], C.PAPER[G], C.PAPER[B], 1)
    value_btn:SetImageFocusColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)

    local value_text = value_btn:AddChild(Text(F_CLEAN, 15, ""))
    value_text:SetRegionSize(86, 26)
    value_text:SetPosition(0, 0)
    value_text:SetHAlign(ANCHOR_MIDDLE)
    value_text:SetVAlign(ANCHOR_MIDDLE)
    value_text:SetColour(C.BROWN[R], C.BROWN[G], C.BROWN[B], 1)
    value_text:SetString(isbool
        and ((State.params[key] or 0) > 0.5 and "ON" or "OFF")
        or string.format("%.2f", State.params[key]))

    -- 行内进度线（博客感的小仪表）；开关行没有进度概念
    local track, fill
    if not isbool then
        local norm = (State.params[key] - meta.min) / (meta.max - meta.min)
        track = row:AddChild(Image("images/global.xml", "square.tex"))
        track:ScaleToSize(86, 3)
        track:SetPosition(VAL_X, -ROW_H / 2 + 4)
        track:SetTint(C.LINE[R], C.LINE[G], C.LINE[B], 1)
        fill = row:AddChild(Image("images/global.xml", "square.tex"))
        fill:ScaleToSize(math.max(2, 86 * math.clamp(norm, 0, 1)), 3)
        fill:SetPosition(VAL_X - 43 + math.max(1, 43 * math.clamp(norm, 0, 1)), -ROW_H / 2 + 4)
        fill:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    end

    -- R 重置
    local reset_btn = self:Chip(row, RST_X, 0, 26, 26, "R", true, nil, 12)
    reset_btn:SetOnClick(function()
        State.ResetParam(key)
        self:RefreshRow(key)
        self:MakeDirty()
    end)

    if isbool then
        -- 开关行：点击切换 0/1，不拖拽不键入
        value_btn:SetOnClick(function()
            State.SetParam(key, (State.params[key] or 0) > 0.5 and 0 or 1)
            self:RefreshRow(key)
            self:MakeDirty()
        end)
    else
        -- 拖动 + 单击输入
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
            local span = 220
            local delta = (TheFrontEnd.lastx - drag.start_x) * (meta.max - meta.min) / span
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
        -- 隐藏的输入框（点击数值时浮现）
        self:MakeEdit(row, key, VAL_X, 0, 86, 26, value_text,
            function(v) State.SetParam(key, v) end,
            function() return State.params[key] end,
            function() self:RefreshRow(key); self:MakeDirty() end)
    end

    self.rows[key] = {text = value_text, fill = fill, meta = meta, isbool = isbool}
end

function BCASScreen:RefreshRow(key)
    local entry = self.rows[key]
    if entry == nil then return end
    local v = State.params[key]
    if entry.isbool then
        entry.text:SetString((v or 0) > 0.5 and "ON" or "OFF")
        return
    end
    entry.text:SetString(string.format("%.2f", v))
    local meta = entry.meta
    local norm = math.clamp((v - meta.min) / (meta.max - meta.min), 0, 1)
    if entry.fill ~= nil then
        entry.fill:ScaleToSize(math.max(2, 86 * norm), 3)
        entry.fill:SetPosition(VAL_X - 43 + math.max(1, 43 * norm), -ROW_H / 2 + 4)
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

-- ==== 数值输入框（TextEdit） ===============================================
-- 点击数值 -> 输入框浮现原位，回车提交（自动 clamp 到滑条范围），ESC/失焦取消。

function BCASScreen:MakeEdit(parent, tag, x, y, w, h, value_text, setter, getter, after)
    local edit = parent:AddChild(TextEdit(F_CLEAN, 15, "", {0.18, 0.137, 0.09, 1}))
    edit:SetPosition(x, y)
    edit:SetRegionSize(w - 8, h)
    edit:SetHAlign(ANCHOR_MIDDLE)
    edit:SetEditCursorColour(0.30, 0.42, 0.13, 1)
    edit:SetCharacterFilter("0123456789.-")
    edit:SetPassControlToScreen(CONTROL_CANCEL, true)
    edit:Hide()
    self.edits[tag] = {edit = edit, value_text = value_text, setter = setter, getter = getter, after = after}

    edit.OnTextEntered = function()
        self:CommitEdit(tag)
    end
    -- 失焦（点了面板其他地方）= 回退收起，绝不留幽灵输入框
    local base_losefocus = edit.OnLoseFocus
    edit.OnLoseFocus = function(w)
        base_losefocus(w)
        if self.active_edit == tag then
            self:CloseEdit(tag, false)
        end
    end
end

function BCASScreen:OpenEdit(tag, btn, value_text)
    local entry = self.edits[tag]
    if entry == nil then return end
    -- 再点一次同一个数值框 = 收起
    if self.active_edit == tag then
        self:CloseEdit(tag, false)
        return
    end
    if self.active_edit ~= nil then
        self:CloseEdit(self.active_edit, false) -- 失焦回退
    end
    self.active_edit = tag
    entry.value_text = value_text
    value_text:Hide()
    entry.edit:SetString(string.format("%.2f", entry.getter()))
    entry.edit:Show()
    entry.edit:MoveToFront()
    entry.edit:SetEditing(true) -- 内部自带 SetFocus
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
    if entry.edit.editing then
        entry.edit:SetEditing(false)
    end
    entry.edit:Hide()
    if entry.value_text ~= nil then
        entry.value_text:Show()
        entry.value_text:SetString(string.format("%.2f", entry.getter()))
    end
    if self.active_edit == tag then self.active_edit = nil end
end

function BCASScreen:OnUpdate(dt)
    -- 输入框失去焦点（点了别处）-> 自动回退显示原值
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

-- ==== 内容区 ===============================================================

function BCASScreen:BuildContent()
    for _, wgt in ipairs(self.content_children) do
        wgt:Kill()
    end
    self.content_children = {}
    self.rows = {}
    self.wb_chip_swatch = nil -- 随内容销毁，防死控件引用
    self.wb_chip_hex = nil
    -- 行输入框随行销毁，清掉注册（gain 输入框在弹窗里，保留）
    for tag in pairs(self.edits) do
        if string.sub(tag, 1, 4) ~= "gain" then
            self.edits[tag] = nil
        end
    end
    self.active_edit = nil

    local rows = TAB_ROWS[self.tab]
    for i, key in ipairs(rows) do
        self:BuildRow(key, Y_ROW0 - (i - 1) * ROW_STEP)
    end

    -- 说明文字：永远放在该页最后一行之下
    local note_y = Y_ROW0 - #rows * ROW_STEP - 20

    if self.tab == 1 then
        local note = self:Label(self.content, -(ROW_W - 20) / 2, note_y, ROW_W - 20, 13, STR.SHARP_NOTE, C.BROWN_SOFT, ANCHOR_LEFT, 60)
        table.insert(self.content_children, note)
    elseif self.tab == 2 then
        local note = self:Label(self.content, -(ROW_W - 20) / 2, note_y, ROW_W - 20, 13,
            "进阶参数与旧 fx 同名项一一对应；改乱可按行尾 R 复位，或切预设回正。", C.BROWN_SOFT, ANCHOR_LEFT, 40)
        table.insert(self.content_children, note)
    elseif self.tab == 3 then
        self:BuildWBLaunch(note_y)
    elseif self.tab == 5 then
        local info = self:Label(self.content, -(ROW_W - 20) / 2, note_y, ROW_W - 20, 13, STR.ATMO_NOTE, C.BROWN_SOFT, ANCHOR_LEFT, 110)
        table.insert(self.content_children, info)
    end
end

-- 色彩页底部：调色轮入口（带当前色色块）
function BCASScreen:BuildWBLaunch(y)
    local row = self.content:AddChild(Widget("wb_launch"))
    row:SetPosition(0, y)
    table.insert(self.content_children, row)

    local bg = row:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(ROW_W, 40)
    bg:SetTint(C.CREAM[R], C.CREAM[G], C.CREAM[B], 1)
    -- 橄榄绿描边 + 左侧竖条：告诉用户这整块是个入口
    self:FrameRect(row, 0, 0, ROW_W, 40, C.OLIVE, 2)
    local accent = row:AddChild(Image("images/global.xml", "square.tex"))
    accent:ScaleToSize(6, 36)
    accent:SetPosition(-ROW_W / 2 + 7, 0)
    accent:SetTint(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)

    local btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
    btn:SetPosition(0, 0)
    btn:ForceImageSize(ROW_W, 40)
    btn.scale_on_focus = false
    btn.move_on_click = false
    btn:SetImageNormalColour(1, 1, 1, 0) -- 全透明，只负责点击
    btn:SetImageFocusColour(1, 1, 1, 0)
    btn:SetOnClick(function() self:OpenWBPopup() end)

    local swatch = row:AddChild(Image("images/global.xml", "square.tex"))
    swatch:ScaleToSize(26, 26)
    swatch:SetPosition(-ROW_W / 2 + 27, 0)
    self.wb_chip_swatch = swatch

    self:Label(row, -ROW_W / 2 + 47, 0, 250, 15, STR.WB_LAUNCH, C.BROWN, ANCHOR_LEFT)

    local r, g, b = GainsFromParams()
    local cr, cg, cb = GainsToDisplay(r, g, b)
    swatch:SetTint(cr, cg, cb, 1)
    self.wb_chip_hex = self:Label(row, ROW_W / 2 - 12, 0, 84, 13, FmtHex(cr, cg, cb), C.BROWN_SOFT, ANCHOR_RIGHT)
end

function BCASScreen:RefreshWBChip()
    if self.wb_chip_swatch ~= nil then
        local r, g, b = GainsFromParams()
        local cr, cg, cb = GainsToDisplay(r, g, b)
        self.wb_chip_swatch:SetTint(cr, cg, cb, 1)
    end
    if self.wb_chip_hex ~= nil then
        local r, g, b = GainsFromParams()
        local cr, cg, cb = GainsToDisplay(r, g, b)
        self.wb_chip_hex:SetString(FmtHex(cr, cg, cb))
    end
end

-- ==== 底部 =================================================================

function BCASScreen:BuildFooter()
    local apply = self:Chip(self.chrome, -70, Y_BTNS, 168, 36, STR.APPLY, true, function() self:Apply() end)
    apply:SetImageNormalColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    apply:SetImageFocusColour(C.OLIVE_DK[R], C.OLIVE_DK[G], C.OLIVE_DK[B], 1)
    apply.text:SetColour(C.CREAM_TXT[R], C.CREAM_TXT[G], C.CREAM_TXT[B], 1)
    self:Chip(self.chrome, 92, Y_BTNS, 104, 36, STR.CANCEL, false, function() self:Cancel() end)
    self:Label(self.chrome, 0, Y_HINT, PANEL_W - 24, 12, STR.HINT, C.BROWN_SOFT, ANCHOR_MIDDLE)
end

-- ==== 白平衡调色轮弹窗 ======================================================
-- 弹窗局部坐标（中心原点，470x520）：
--   [260 头 46] 色相环中心(-130,55) 半径78 | SV 方格 14x9 @格20 中心(85,115)
--   RGB 增益行 y=-60/-104/-148 | 预设 y=-196 | 提示 y=-232

local HUE_N = 48
local SV_COLS, SV_ROWS, SV_CELL = 20, 14, 14
local RING_CX, RING_CY, RING_R = -130, 55, 72
local GRID_CX, GRID_CY = 95, 113
local GAIN_MIN, GAIN_MAX = 0.55, 1.85

function BCASScreen:BuildWBPopup()
    self.wb_popup = self.root:AddChild(Widget("wb_popup"))
    self.wb_popup:SetPosition(PANEL_X, -10)
    self.wb_popup:Hide()

    local W, H = PANEL_W, 520

    self:PopupRect(W, H)

    -- 色相环：48 块色砖按钮（7.5 度一档，体素风细粒度）。
    -- 判定走引擎的按钮命中测试，任何窗口/全屏/DPI 模式都零漂移
    -- （绝对坐标换算方案在小窗口下受窗口偏移影响，已弃用）。
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
    self.hue_marker = self:FrameRect(self.wb_popup, 0, 0, 22, 22, C.PAPER, 2)

    -- 环心：当前颜色预览 + HEX
    self:FrameRect(self.wb_popup, RING_CX, RING_CY, 62, 62, C.LINE, 2)
    self.wb_preview = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    self.wb_preview:ScaleToSize(56, 56)
    self.wb_preview:SetPosition(RING_CX, RING_CY)
    self.wb_hex = self:Label(self.wb_popup, RING_CX, RING_CY - 44, 90, 12, "#FFFFFF", C.BROWN_SOFT, ANCHOR_MIDDLE)

    -- SV 方格：20x14 按钮（饱和 5% 一档 / 明度 7% 一档，视觉近似无级）
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
    self.sv_marker = self:FrameRect(self.wb_popup, 0, 0, 20, 20, C.PAPER, 2)
    self:Label(self.wb_popup, GRID_CX, GRID_CY - (SV_ROWS * SV_CELL) / 2 - 16, 240, 12, STR.WB_AXIS, C.BROWN_SOFT, ANCHOR_MIDDLE)

    -- RGB 增益行
    self:Label(self.wb_popup, -W / 2 + 14, -34, 300, 13, "RGB 增益（映射到色温/色调）", C.OLIVE, ANCHOR_LEFT)
    self.gain_rows = {}
    local names = {"R", "G", "B"}
    for i = 1, 3 do
        local y = -60 - (i - 1) * 44
        local row = self.wb_popup:AddChild(Widget("gain_" .. names[i]))
        row:SetPosition(0, y)

        local chip = self:Chip(row, -W / 2 + 32, 0, 28, 26, names[i], true, nil, 14)
        local chr_, cgg_, cbb_ = hsv2rgb(i == 1 and 0 or (i == 2 and 0.33 or 0.66), 0.55, 1)
        chip:SetImageNormalColour(chr_, cgg_, cbb_, 1)
        chip.text:SetColour(0.12, 0.09, 0.06, 1)

        -- 增益标尺：11 格从 GAIN_MIN 到 GAIN_MAX
        local cells = {}
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
            cells[ci] = cell
        end
        local marker = row:AddChild(Image("images/global.xml", "square.tex"))
        marker:ScaleToSize(4, 32)
        marker:SetPosition(-160, 0)
        marker:SetTint(C.BROWN[R], C.BROWN[G], C.BROWN[B], 1)

        local value_btn = row:AddChild(ImageButton("images/global.xml", "square.tex"))
        value_btn:SetPosition(VAL_X, 0)
        value_btn:ForceImageSize(86, 26)
        value_btn.scale_on_focus = false
        value_btn.move_on_click = false
        value_btn:SetImageNormalColour(C.PAPER[R], C.PAPER[G], C.PAPER[B], 1)
        value_btn:SetImageFocusColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
        local value_text = value_btn:AddChild(Text(F_CLEAN, 15, "1.00"))
        value_text:SetRegionSize(86, 26)
        value_text:SetPosition(0, 0)
        value_text:SetHAlign(ANCHOR_MIDDLE)
        value_text:SetVAlign(ANCHOR_MIDDLE)
        value_text:SetColour(C.BROWN[R], C.BROWN[G], C.BROWN[B], 1)

        self:MakeGainEdit(row, i, value_text)

        -- 拖动微调 + 单击键入（与主面板数值行同一套交互）
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
            local v = math.clamp(gdrag.start_v + (TheFrontEnd.lastx - gdrag.start_x) / 220, GAIN_MIN, GAIN_MAX)
            v = v - v % 0.01
            if v ~= self.wb_gain[i] then
                self.wb_gain[i] = v
                self:SyncFromGains()
            end
        end)
        value_btn:SetOnClick(function()
            gdrag.active = false
            TheFrontEnd:LockFocus(false)
            if not gdrag.moved then
                self:OpenEdit("gain" .. i, value_btn, value_text)
            end
        end)

        local reset_btn = self:Chip(row, RST_X, 0, 26, 26, "R", true, nil, 12)
        reset_btn:SetOnClick(function()
            self.wb_gain[i] = 1.0
            self:SyncFromGains()
        end)

        self.gain_rows[i] = {text = value_text, marker = marker}
    end

    -- 快捷预设
    for i, p in ipairs(STR.WB_PRESETS) do
        self:Chip(self.wb_popup, -PANEL_W / 2 + 33 + (i - 1) * 72, -196, 66, 26, p.label, false, function()
            self.wb_gain = {p.v[1], p.v[2], p.v[3]}
            self:SyncFromGains()
        end, 13)
    end
    self:Chip(self.wb_popup, PANEL_W / 2 - 40, -196, 62, 26, STR.WB_RESET, false, function()
        self.wb_gain = {1.0, 1.0, 1.0}
        self:SyncFromGains()
    end, 13)

    -- 底部提示
    local tip = self:Label(self.wb_popup, 0, -236, W - 40, 12, STR.WB_TIP, C.BROWN_SOFT, ANCHOR_MIDDLE)
    tip:SetVAlign(ANCHOR_MIDDLE)
end

function BCASScreen:PopupRect(W, H)
    local bg1 = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    bg1:ScaleToSize(W + 4, H + 4)
    bg1:SetTint(C.BROWN[R], C.BROWN[G], C.BROWN[B], 1)
    local bg2 = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    bg2:ScaleToSize(W, H)
    bg2:SetTint(C.CREAM[R], C.CREAM[G], C.CREAM[B], 1)

    local header = self.wb_popup:AddChild(Image("images/global.xml", "square.tex"))
    header:ScaleToSize(W, 46)
    header:SetPosition(0, H / 2 - 23)
    header:SetTint(C.BROWN[R], C.BROWN[G], C.BROWN[B], 1)

    self:Label(self.wb_popup, -W / 2 + 14, H / 2 - 23, 280, 17, STR.WB_TITLE, C.CREAM_TXT, ANCHOR_LEFT)
    self:Label(self.wb_popup, 155, H / 2 - 23, 100, 13, STR.WB_SUB, C.OLIVE, ANCHOR_RIGHT)

    local close = self:Chip(self.wb_popup, W / 2 - 46, H / 2 - 23, 64, 28, STR.WB_CLOSE, true, function()
        self.wb_popup:Hide()
    end, 14)
    close:SetImageNormalColour(C.OLIVE[R], C.OLIVE[G], C.OLIVE[B], 1)
    close.text:SetColour(C.CREAM_TXT[R], C.CREAM_TXT[G], C.CREAM_TXT[B], 1)
end

-- 增益行输入框（0.55..1.85）
function BCASScreen:MakeGainEdit(parent, i, value_text)
    local edit = parent:AddChild(TextEdit(F_CLEAN, 15, "", {0.18, 0.137, 0.09, 1}))
    edit:SetPosition(VAL_X, 0)
    edit:SetRegionSize(78, 26)
    edit:SetHAlign(ANCHOR_MIDDLE)
    edit:SetEditCursorColour(0.30, 0.42, 0.13, 1)
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
    edit.OnLoseFocus = function(w)
        base_losefocus(w)
        if self.active_edit == tag then
            self:CloseEdit(tag, false)
        end
    end
end

-- 从 HSV 取色 -> 增益 -> Temp/Tint，刷新整个弹窗
function BCASScreen:SyncWheel(sv_changed)
    local r, g, b = hsv2rgb(self.wb_h, self.wb_s, self.wb_v)
    if self.wb_v < 0.04 then r, g, b = 1, 1, 1 end -- 近黑只改色相无意义
    SetGainsFromColor(r, g, b)
    self.wb_gain = {GainsFromParams()}
    self:SyncWheelUI()
    self:MakeDirty()
end

-- 增益被直接修改（标尺/预设/输入）-> Temp/Tint -> 刷新
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

-- 只刷 UI（不动参数）
function BCASScreen:SyncWheelUI()
    -- 预览 + HEX
    local cr, cg, cb = GainsToDisplay(self.wb_gain[1], self.wb_gain[2], self.wb_gain[3])
    self.wb_preview:SetTint(cr, cg, cb, 1)
    self.wb_hex:SetString(FmtHex(cr, cg, cb))

    -- SV 方格重着色（跟随色相）
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

    -- 标记位置
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

    -- 增益行
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
    -- 从当前 Temp/Tint 反推增益与 HSV（外部改动也能正确显示）
    self.wb_gain = {GainsFromParams()}
    local cr, cg, cb = GainsToDisplay(self.wb_gain[1], self.wb_gain[2], self.wb_gain[3])
    self.wb_h, self.wb_s, self.wb_v = rgb2hsv(cr, cg, cb)
    self:SyncWheelUI()
    self.wb_popup:Show()
    self.wb_popup:MoveToFront()
end

-- ==== 行为 =================================================================

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
            if v ~= nil then
                State.SetParam(key, v)
            end
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
