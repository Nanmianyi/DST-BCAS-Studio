--[[ BCAS Studio —— modmain

接入引擎官方 Mod 着色器链：
  Asset("SHADER") 声明 -> AddModShadersInit 注册 -> AddModShadersSortAndEnable 排序启用

另整合高清字体（思源黑体，打包资源取自创意工坊 Chinese++ 1418746242，
见 fonts/ATTRIBUTION.txt），可通过 mod 配置里的「高清字体」开关。

注意：TheFrontEnd / TheInput 在 modmain 加载时还不存在（client_log 实测
"attempt to index upvalue 'TheFrontEnd' (a nil value)"），必须在回调里
实时从 GLOBAL 取用，禁止缓存到局部变量。
]]

local TheNet = GLOBAL.TheNet

if TheNet:IsDedicated() then
    return -- 专用服务器无渲染，直接退出
end

Assets = {
    Asset("SHADER", "shaders/bcas_studio.ksh"),
    Asset("SHADER", "shaders/bcas_cinema.ksh"),
}

local State = require "bcas_state"
State.boot_preset = GetModConfigData("PRESET") or "standard"

-- ==========================================================================
-- 高清字体整合（思源黑体，SIL OFL 1.1，见 fonts/ATTRIBUTION.txt；
-- 字体接入结构改编自 workshop-2403997762 / TsAIM 的高清字体 mod）
-- ==========================================================================

local ENABLE_HDFONT = GetModConfigData("HDFONT") ~= "off"

if ENABLE_HDFONT then
    local MODROOT_ = MODROOT

    -- 备份原字体常量，方便将来做开关恢复
    local FontNames = {
        DEFAULTFONT = GLOBAL.DEFAULTFONT,
        DIALOGFONT = GLOBAL.DIALOGFONT,
        TITLEFONT = GLOBAL.TITLEFONT,
        UIFONT = GLOBAL.UIFONT,
        BUTTONFONT = GLOBAL.BUTTONFONT,
        NEWFONT = GLOBAL.NEWFONT,
        NEWFONT_SMALL = GLOBAL.NEWFONT_SMALL,
        NEWFONT_OUTLINE = GLOBAL.NEWFONT_OUTLINE,
        NEWFONT_OUTLINE_SMALL = GLOBAL.NEWFONT_OUTLINE_SMALL,
        TALKINGFONT = GLOBAL.TALKINGFONT,
        BODYTEXTFONT = GLOBAL.BODYTEXTFONT,
        CODEFONT = GLOBAL.CODEFONT,
        TALKINGFONT_WORMWOOD = GLOBAL.TALKINGFONT_WORMWOOD,
        CHATFONT = GLOBAL.CHATFONT,
        HEADERFONT = GLOBAL.HEADERFONT,
        CHATFONT_OUTLINE = GLOBAL.CHATFONT_OUTLINE,
    }

    local FONT_PREFAB = "cn_fonts_bcasstudio"

    local function ApplyHDFonts()
        local TheSim = GLOBAL.TheSim
        TheSim:UnloadFont("normalfont")
        TheSim:UnloadFont("normalfont_outline")
        TheSim:UnloadPrefabs({FONT_PREFAB})

        local assets = {
            GLOBAL.Asset("FONT", MODROOT_ .. "fonts/normal.zip"),
            GLOBAL.Asset("FONT", MODROOT_ .. "fonts/normal_outline.zip"),
        }
        GLOBAL.RegisterPrefabs(GLOBAL.Prefab("common/" .. FONT_PREFAB, nil, assets))
        TheSim:LoadPrefabs({FONT_PREFAB})

        TheSim:LoadFont(MODROOT_ .. "fonts/normal.zip", "normalfont")
        TheSim:LoadFont(MODROOT_ .. "fonts/normal_outline.zip", "normalfont_outline")

        -- 与原 mod 相同的字重分配：outline 系走描边字体，正文/按钮走普通字体
        GLOBAL.DEFAULTFONT = "normalfont_outline"
        GLOBAL.DIALOGFONT = "normalfont_outline"
        GLOBAL.TITLEFONT = "normalfont_outline"
        GLOBAL.UIFONT = "normalfont_outline"
        GLOBAL.BUTTONFONT = "normalfont"
        GLOBAL.NEWFONT = "normalfont"
        GLOBAL.NEWFONT_SMALL = "normalfont"
        GLOBAL.NEWFONT_OUTLINE = "normalfont_outline"
        GLOBAL.NEWFONT_OUTLINE_SMALL = "normalfont_outline"
        GLOBAL.TALKINGFONT = "normalfont_outline"
        GLOBAL.BODYTEXTFONT = "normalfont_outline"
        GLOBAL.CODEFONT = "normalfont"
        GLOBAL.TALKINGFONT_WORMWOOD = "normalfont_outline"
        GLOBAL.CHATFONT = "normalfont"
        GLOBAL.HEADERFONT = "normalfont"
        GLOBAL.CHATFONT_OUTLINE = "normalfont"

        -- BCAS 面板专用：浅底 UI 一律无描边（bcas_screen 读取，未注入时回落 UIFONT）
        -- strict.lua 会拦截"函数体内给未声明新全局赋值"（main chunk 例外），
        -- 必须 rawset 绕过 __newindex；读取方 bcas_screen 用 rawget(_G, ...) 对应。
        GLOBAL.rawset(GLOBAL, "BCAS_FONT_CLEAN", "normalfont")
    end

    -- fallback 链（DEFAULT_FALLBACK_TABLE）引用的 fallback_font / controllers /
    -- emoji 等字体由引擎在 GlobalInit→LoadFonts() 里加载，时机晚于 modmain。
    -- 若在 modmain 阶段调用 SetupFontFallbacks，这些字体尚不存在，引擎该 C 函数
    -- 不做防御会直接原生崩溃——不抛 Lua 错误、xpcall 拦不住，进程当场退出
    -- （client_log 实测：'dmp written' 后紧跟 [C](-1): SetupFontFallbacks）。
    -- 这就是 3.0.0「游戏内启用正常、开着 mod 冷启动必崩」的根因。
    -- 因此 fallback 设置只能放在 LoadFonts 之后的重挂点里（下方三个重挂点
    -- 均晚于 GlobalInit：Start 由引擎在 main.lua 跑完后调用，另两个在 gamelogic
    -- /世界重建期触发，而 gamelogic 本身是 Start 里 require 的）。
    local function ApplyFontFallbacks()
        local TheSim = GLOBAL.TheSim
        TheSim:SetupFontFallbacks("normalfont", GLOBAL.DEFAULT_FALLBACK_TABLE)
        TheSim:SetupFontFallbacks("normalfont_outline", GLOBAL.DEFAULT_FALLBACK_TABLE_OUTLINE)
    end

    -- 游戏会在重建预制件/开始游戏时重置字体，沿用原 mod 的三个重挂点
    -- 注意先备份再覆盖（顺序反了会备份到自己的包装函数造成无限递归）
    local SimIndex = GLOBAL.getmetatable(GLOBAL.TheSim).__index
    local oldUnregisterAllPrefabs = SimIndex.UnregisterAllPrefabs
    SimIndex.UnregisterAllPrefabs = function(self, ...)
        oldUnregisterAllPrefabs(self, ...)
        ApplyHDFonts()
        ApplyFontFallbacks()
    end

    local oldRegisterPrefabs = GLOBAL.ModManager.RegisterPrefabs
    GLOBAL.ModManager.RegisterPrefabs = function(self, ...)
        oldRegisterPrefabs(self, ...)
        ApplyHDFonts()
        ApplyFontFallbacks()
    end

    local oldStart = GLOBAL.Start
    GLOBAL.Start = function(...)
        ApplyHDFonts()
        ApplyFontFallbacks()
        return oldStart(...)
    end

    ApplyHDFonts()
end

-- ==========================================================================
-- 后处理滤镜
-- ==========================================================================

-- 热键解析：配置可能存 "NONE"（禁用），而 strict.lua 对未声明名字的
-- 全局读取会直接报错（实测 GLOBAL["NONE"] 闪退），必须 rawget 绕过。
local function ResolveHotkey(config_name, default_name)
    local v = GetModConfigData(config_name)
    if v == nil or v == "NONE" then return nil end
    return GLOBAL.rawget(GLOBAL, v) or GLOBAL.rawget(GLOBAL, default_name)
end
local KEY_TOGGLE = ResolveHotkey("HOTKEY_TOGGLE", "KEY_P")
local KEY_UI = ResolveHotkey("HOTKEY_UI", "KEY_HOME")
local KEY_CLOSE = GLOBAL.rawget(GLOBAL, "KEY_PAGEDOWN") -- 固定：PgDn 保存并关闭面板

AddModShadersInit(function()
    State.InitShader()
end)

AddModShadersSortAndEnable(function()
    State.SortAndStart()
end)

local function IsHUDActive()
    -- 实时取用：TheFrontEnd 在 modmain 加载时尚未创建
    local screen = GLOBAL.TheFrontEnd:GetActiveScreen()
    return screen ~= nil and screen.name == "HUD"
end

AddClassPostConstruct("screens/playerhud", function(self)
    -- 进世界保险式重钉（修复"第一次进世界效果不启用"）。
    -- 首次进世界时着色器编译/建链存在时序竞态（第二次进世界才生效的老毛病），
    -- Reassert 幂等且开销为零，进世界后前 30 秒内每 3 秒重钉一次兜底。
    local tries = 0
    self.bcas_reassert_task = self.inst:DoPeriodicTask(3, function()
        tries = tries + 1
        State.Reassert()
        if tries >= 10 and self.bcas_reassert_task ~= nil then
            self.bcas_reassert_task:Cancel()
            self.bcas_reassert_task = nil
        end
    end, 2)

    -- 颗粒动画：TIME uniform 以 8Hz 刷新，胶片颗粒才会像胶片一样闪动
    -- （静止的 TIME 只是一层死噪点）。仅当颗粒 > 0 时才下发，零额外开销。
    self.inst:DoPeriodicTask(0.125, function()
        -- 退世界时引擎会把 PostProcessor 置 nil，守卫住任务空窗期
        if PostProcessor == nil then return end
        if (State.params.Grain or 0) > 0 and State.handles.BCAS_ATMO ~= nil then
            local v = State.PackUniform("BCAS_ATMO")
            PostProcessor:SetUniformVariable(
                State.handles.BCAS_ATMO, v[1], v[2], GLOBAL.TheSim:GetTime() % 64, v[4])
        end
    end, 1)

    if type(KEY_TOGGLE) == "number" then
        GLOBAL.TheInput:AddKeyDownHandler(KEY_TOGGLE, function()
            if IsHUDActive() then
                State.ToggleEnabled()
            end
        end)
    end

    if type(KEY_UI) == "number" then
        GLOBAL.TheInput:AddKeyDownHandler(KEY_UI, function()
            -- 注意顺序：面板打开时活动屏幕是 BCAS_Studio 而非 HUD，
            -- 先查面板再查 HUD，否则 Home 永远关不掉面板
            local active = GLOBAL.TheFrontEnd:GetActiveScreen()
            if active ~= nil and active.name == "BCAS_Studio" then
                active:Cancel() -- Home 再按 = 不保存关闭（保存走 PgDn）
                return
            end
            if IsHUDActive() then
                self:OpenBCASScreen()
            end
        end)
    end

    if type(KEY_CLOSE) == "number" then
        GLOBAL.TheInput:AddKeyDownHandler(KEY_CLOSE, function()
            -- 只在 BCAS 面板本身处于顶层时生效，避免误关暂停菜单等
            local active = GLOBAL.TheFrontEnd:GetActiveScreen()
            if active ~= nil and active.name == "BCAS_Studio" then
                active:Apply()
            end
        end)
    end

    function self:OpenBCASScreen()
        local BCASScreen = require "bcas_screen"
        State.Snapshot()
        self.bcas_screen = BCASScreen()
        self:OpenScreenUnderPause(self.bcas_screen)
        return true
    end
end)

-- 控制台调试入口：BCAS.Set("Strength", 2.0) / BCAS.ToggleEnabled() / BCAS.params
GLOBAL.BCAS = State
