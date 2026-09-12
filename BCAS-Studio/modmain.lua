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
    Asset("SHADER", "shaders/bcas_glow.ksh"),
    Asset("SHADER", "shaders/bcas_bloom_pre.ksh"),
    Asset("SHADER", "shaders/bcas_bloom_d1.ksh"),
    Asset("SHADER", "shaders/bcas_bloom_d2.ksh"),
    Asset("SHADER", "shaders/bcas_bloom_d3.ksh"),
    Asset("ANIM", "anim/lightrays.zip"),
    Asset("ANIM", "anim/pbr_water.zip"),
    Asset("SHADER", "shaders/bcas_glint.ksh"),

    -- 影子剪影着色器（tools/make_silhouette_shader.py 从引擎 anim.ksh 派生）。
    -- 三个固定变体，各带一份 _skinned 备用（SHADOW_SKINNED_FALLBACK 切换）：
    --   bcas_silhouette*      可见层：alpha 硬压平 + 深度前推 LAYER_BIAS
    --   bcas_silhouette_write* 写深度孪生体：压平 + 输出 alpha 0（只写深度）
    --   bcas_silhouette_fx*   装备克隆：压平可见，整体后撤 FX_BACKOFF
    -- 变体是固定逻辑、不读运行时哨兵 —— 上一版挂在 FLOAT_PARAMS.z 上，
    -- 引擎一清就静默全失效（线条/闪烁/缺块，且日志无痕），故废弃该方案。
    Asset("SHADER", "shaders/bcas_silhouette.ksh"),
    Asset("SHADER", "shaders/bcas_silhouette_skinned.ksh"),
    Asset("SHADER", "shaders/bcas_silhouette_write.ksh"),
    Asset("SHADER", "shaders/bcas_silhouette_write_skinned.ksh"),
    Asset("SHADER", "shaders/bcas_silhouette_fx.ksh"),
    Asset("SHADER", "shaders/bcas_silhouette_fx_skinned.ksh"),

    -- BCAS Studio 设置面板图集（圆角面板/卡片/胶囊/旋钮，由 tools/build_ui_atlas.py 生成）。
    -- 必须在此声明：mod 图集不声明 Asset，引擎不会加载，面板会整块透明只剩文字。
    Asset("ATLAS", "images/bcas_ui.xml"),
}

local State = require "bcas_state"
local SunSystem = require "bcas_sun_emitter"
local OceanLook = require "bcas_ocean"
local Glint = require "bcas_glint"

-- 海面波光（水面 caustics 高光层；不动原版海洋渲染，可独立开关）
local GLINT_LEVELS = { soft = 0.6, standard = 1.0, bright = 1.6 }
Glint.Apply(AddPrefabPostInit,
    GetModConfigData("OCEANGLINT") == "on",
    GLINT_LEVELS[GetModConfigData("OCEANGLINT_LEVEL") or "standard"] or 1.0)

local ENABLE_LIGHTING = GetModConfigData("LIGHTING") ~= "off"
State.LightingHardOff = not ENABLE_LIGHTING
if not ENABLE_LIGHTING then
    SunSystem.SetMasterEnabled(false)
end

State.boot_preset = GetModConfigData("PRESET") or "standard"
-- MERGED_PASS 探针（4096 上限实验）：仅在配置为 on 时把 6.5KB 源码的
-- bcas_merged.ksh 插进资产表 —— Asset 声明即加载，引擎读 ksh 源码用定长
-- 缓冲，超限直接炸，与链路是否注册无关，所以默认必须不声明。
State.merged_pass = GetModConfigData("MERGED_PASS") == "on"
if State.merged_pass then
    -- 内置默认：调色+锐化+辉光合并为单个全分辨率 pass（架构优化，2 -> 1）。
    -- 引擎实测喂给编译器的是完整源码（历史 ~4096 限制为误判），7.5KB 可跑。
    table.insert(Assets, Asset("SHADER", "shaders/bcas_merged_glow.ksh"))
end
-- Ocean TILE colours + TUNING.OCEAN_SHADER must be patched before the
-- world is generated (gamelogic reads them once). HUD init is too late.
OceanLook.Apply(true)

-- 原生 Bloom 开关接管（2026-09 v2，尽早安装）：
-- 引擎在玩家改画质设置 / 进世界时经 PostProcessor:SetBloomEnabled 反复
-- 重开原生辉光。钩子包装该方法（见 bcas_state.HookNativeBloom）：
-- 我们辉光接管期间强制关官方辉光，关掉我们后恢复玩家的原生偏好。
-- 顶层安装失败也没关系：State.InitShader（AddModShadersInit 时）会重试。
State.HookNativeBloom()

-- 原版滤镜接管（滤镜RR 3115280970 移植，2026-09）：低SAN保色 / 失真消除
-- / 积雪上限 / 过滤风沙 四个实时开关，全部可逆包装（见
-- bcas_state.HookVanillaFilters）。同样由 InitShader 兜底重试。
-- ⚠ AddPrefabPostInit / AddClassPostConstruct 是 modutil.lua 注入"模组
-- 环境"（env.xxx）的函数，不是游戏全局：bcas_state 经 require 加载跑在
-- 游戏全局的严格环境里，rawget(_G) 永远拿不到（2026-09 实测：积雪/风沙
-- 两钩子因此静默失效），必须先经 ProvideModHooks 显式传入。
State.ProvideModHooks(AddPrefabPostInit, AddClassPostConstruct)
State.HookVanillaFilters()

-- ==========================================================================
-- 高清字体整合（思源黑体，SIL OFL 1.1，见 fonts/ATTRIBUTION.txt；
-- 字体接入结构改编自 workshop-2403997762 / TsAIM 的高清字体 mod）
-- ==========================================================================

local ENABLE_HDFONT = GetModConfigData("HDFONT") ~= "off"

local MODROOT_ = MODROOT
local FONT_PREFAB = "cn_fonts_bcasstudio"
-- HDFONT 关闭时面板字体用的独立名字：绝不覆盖引擎的 normalfont，
-- 只给我们自己的面板单独提供一份高清无描边字体。
local PANEL_FONT_NAME = "bcaspanelfont"
local panel_font_loaded = false

-- 字体 zip 必须经预制件注册才会被引擎挂载（TheSim:LoadFont 才找得到文件）
local function EnsureFontZip()
    local TheSim = GLOBAL.TheSim
    TheSim:UnloadPrefabs({FONT_PREFAB})
    GLOBAL.RegisterPrefabs(GLOBAL.Prefab("common/" .. FONT_PREFAB, nil, {
        GLOBAL.Asset("FONT", MODROOT_ .. "fonts/normal.zip"),
        GLOBAL.Asset("FONT", MODROOT_ .. "fonts/normal_outline.zip"),
    }))
    TheSim:LoadPrefabs({FONT_PREFAB})
end

-- 设置面板字体：【无条件】用我们自带的高清无描边字体，与 HDFONT 开关无关。
-- 起因：有的用户用描边字体 / 原版低清字体（或别的字体 mod），面板是浅底小字，
-- 跟着他们的字体走就会糊、看不清（"字看不清"的反馈基本都来自这里）。
-- 面板是我们自己的界面，字体自给自足最省事，不依赖任何全局字体常量：
--   HDFONT 开 -> 复用已加载的 normalfont（同一个 zip，不重复加载）
--   HDFONT 关 -> 独立名字 bcaspanelfont 单独加载一份（完全不动引擎字体）
local function ApplyPanelFont()
    if not ENABLE_HDFONT then
        local TheSim = GLOBAL.TheSim
        if panel_font_loaded then
            TheSim:UnloadFont(PANEL_FONT_NAME)
        end
        EnsureFontZip()
        TheSim:LoadFont(MODROOT_ .. "fonts/normal.zip", PANEL_FONT_NAME)
        panel_font_loaded = true
    end
    -- strict.lua 会拦截"函数体内给未声明新全局赋值"，必须 rawset 绕过 __newindex；
    -- 读取方 bcas_screen 用 rawget(_G, ...) 对应。
    GLOBAL.rawset(GLOBAL, "BCAS_FONT_CLEAN",
        ENABLE_HDFONT and "normalfont" or PANEL_FONT_NAME)
end

-- 面板字体先挂上（与 HDFONT 无关）；游戏重建预制件时会重置字体，
-- 重挂点见下方两个分支。
ApplyPanelFont()

if ENABLE_HDFONT then
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

    local function ApplyHDFonts()
        local TheSim = GLOBAL.TheSim
        TheSim:UnloadFont("normalfont")
        TheSim:UnloadFont("normalfont_outline")
        EnsureFontZip()

        TheSim:LoadFont(MODROOT_ .. "fonts/normal.zip", "normalfont")
        TheSim:LoadFont(MODROOT_ .. "fonts/normal_outline.zip", "normalfont_outline")

        -- v3.8.1 字体定版：fonts/normal.zip、normal_outline.zip = 工坊
        -- 1418746242（Chinese++）的 zip 原样照搬（fnt+tex 成对，多年实机
        -- 验证零毛病）。此前自铸字模太细淡，自研"增强+小字模"路线两轮
        -- 都引入游戏内乱码（对第三方 tex 的块排布理解有盲区，解码-回写
        -- 不安全），整体弃用——只搬不修，接线模式与 CN++ 完全一致。
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
        GLOBAL.CHATFONT_OUTLINE = "normalfont_outline"
        -- v3.6.3：补齐此前遗漏的四个字体常量——NUMBERFONT/SMALLNUMBERFONT
        -- 是设置页、加载页数字与标签的主力字体（原版 stint-ucr 50px 字模
        -- 拉伸必糊，中文再 fallback 到低清字体雪上加霜），正是用户反馈的
        -- "设置/加载字体模糊"根因；两个 NPC 对话字体顺手覆盖。
        GLOBAL.NUMBERFONT = "normalfont"
        GLOBAL.SMALLNUMBERFONT = "normalfont"
        GLOBAL.TALKINGFONT_HERMIT = "normalfont_outline"
        GLOBAL.TALKINGFONT_TRADEIN = "normalfont_outline"

        -- 面板字体由 ApplyPanelFont 无条件负责（HDFONT 开时它就是 normalfont）
    end

    -- ⚠ 字体历史（2026-09-09/10）：自铸字模细淡 → 自研"增强+42px 小字模"
    -- 两轮都在游戏内乱码，全部弃用。加载页小字（CHATFONT_OUTLINE@25/
    -- HEADERFONT@35）曾想用 AddClassPostConstruct 换回原版字体修模糊，也
    -- 两炸黑屏（构造沙箱环境连 GetFont/pcall 都不可见）。最终定版 = 整包
    -- 照搬工坊 1418746242 的字体 zip（上方 ApplyHDFonts），只搬不修。

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
        ApplyPanelFont()
        ApplyHDFonts()
        ApplyFontFallbacks()
    end

    local oldRegisterPrefabs = GLOBAL.ModManager.RegisterPrefabs
    GLOBAL.ModManager.RegisterPrefabs = function(self, ...)
        oldRegisterPrefabs(self, ...)
        ApplyPanelFont()
        ApplyHDFonts()
        ApplyFontFallbacks()
    end

    local oldStart = GLOBAL.Start
    GLOBAL.Start = function(...)
        ApplyPanelFont()
        ApplyHDFonts()
        ApplyFontFallbacks()
        return oldStart(...)
    end

    ApplyPanelFont()
    ApplyHDFonts()
else
    -- ── HDFONT 关闭：完全不碰游戏全局字体，只保证【设置面板】用我们的高清字体 ──
    -- 面板是浅底小字，跟着用户的描边字体/原版低清字体走就会糊；用户关掉高清字体
    -- 只是想改游戏观感，没理由让他连我们自己的面板都看不清。
    -- 同样只在 LoadFonts 之后的重挂点里设 fallback（见上方崩溃记录）。
    local function ApplyPanelFallbacks()
        GLOBAL.TheSim:SetupFontFallbacks(PANEL_FONT_NAME, GLOBAL.DEFAULT_FALLBACK_TABLE)
    end

    local SimIndex = GLOBAL.getmetatable(GLOBAL.TheSim).__index
    local oldUnregisterAllPrefabs = SimIndex.UnregisterAllPrefabs
    SimIndex.UnregisterAllPrefabs = function(self, ...)
        oldUnregisterAllPrefabs(self, ...)
        ApplyPanelFont()
        ApplyPanelFallbacks()
    end

    local oldRegisterPrefabs = GLOBAL.ModManager.RegisterPrefabs
    GLOBAL.ModManager.RegisterPrefabs = function(self, ...)
        oldRegisterPrefabs(self, ...)
        ApplyPanelFont()
        ApplyPanelFallbacks()
    end

    local oldStart = GLOBAL.Start
    GLOBAL.Start = function(...)
        ApplyPanelFont()
        ApplyPanelFallbacks()
        return oldStart(...)
    end
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




-- 全生物全地物长影工厂（洞穴自动静默，地表全量覆盖）

AddPlayerPostInit(function(inst)
    if not ENABLE_LIGHTING then return end
    inst:DoTaskInTime(0.1, function()
        if inst:IsValid() and SunSystem ~= nil then
            SunSystem.Attach(inst)
        end
    end)
end)

-- Trees get the "tree" tag after SetPrefabName in their own PostInit, so
-- attach on entitywake (and a short delay) rather than only at spawn.
local TREE_PREFABS = {
    "evergreen", "evergreen_sparse", "evergreen_short", "evergreen_normal", "evergreen_tall",
    "evergreen_sparse_short", "evergreen_sparse_normal", "evergreen_sparse_tall",
    "deciduoustree", "deciduoustree_short", "deciduoustree_normal", "deciduoustree_tall",
    "deciduoustree_burnt", "deciduoustree_stump",
    "twiggytree", "twiggy_short", "twiggy_normal", "twiggy_tall", "twiggy_old",
    "marsh_tree", "moon_tree", "moon_tree_short", "moon_tree_normal", "moon_tree_tall",
}

local function AttachLater(inst, delay)
    if not ENABLE_LIGHTING then return end
    inst:DoTaskInTime(delay or 0.15, function()
        if inst:IsValid() and SunSystem ~= nil then
            SunSystem.AttachEntity(inst)
        end
    end)
    inst:DoTaskInTime(1.0, function()
        if inst:IsValid() and SunSystem ~= nil then
            SunSystem.AttachEntity(inst)
        end
    end)
    inst:ListenForEvent("entitywake", function()
        if inst:IsValid() and SunSystem ~= nil then
            SunSystem.AttachEntity(inst)
        end
    end)
end

for _i, name in ipairs(TREE_PREFABS) do
    AddPrefabPostInit(name, AttachLater)
end

local WATER_PREFABS = { "hotspring" }
for _i, name in ipairs(WATER_PREFABS) do
    AddPrefabPostInit(name, function(inst)
        if not ENABLE_LIGHTING then return end
        inst:DoTaskInTime(0.2, function()
            if inst:IsValid() and SunSystem ~= nil then
                SunSystem.AttachWater(inst)
            end
        end)
    end)
end

local function OnWorldEntitySpawn(inst)
    if not ENABLE_LIGHTING then return end
    if GLOBAL.TheWorld and GLOBAL.TheWorld:HasTag("cave") then return end
    if inst.AnimState == nil or inst.Transform == nil then return end
    if inst:HasTag("player") then return end
    if inst:HasTag("FX") or inst:HasTag("INLIMBO") or inst:HasTag("DECOR") then return end

    inst:DoTaskInTime(0.15, function()
        if not inst:IsValid() or SunSystem == nil then return end
        if SunSystem.ShouldHaveShadow and SunSystem.ShouldHaveShadow(inst) then
            SunSystem.AttachEntity(inst)
        elseif SunSystem.IsMover(inst) then
            SunSystem.AttachEntity(inst)
        end
    end)
end

AddPrefabPostInitAny(OnWorldEntitySpawn)

AddClassPostConstruct("screens/playerhud", function(self)
    -- 挂载主角 3D 动态太阳长影（SetMainCharacter 注入时确保必定触发）
    local old_SetMainCharacter = self.SetMainCharacter
    self.SetMainCharacter = function(hud, maincharacter, ...)
        if old_SetMainCharacter ~= nil then
            old_SetMainCharacter(hud, maincharacter, ...)
        end
        if maincharacter ~= nil and ENABLE_LIGHTING then
            SunSystem.Attach(maincharacter)
        end
    end
    if self.owner ~= nil and ENABLE_LIGHTING then
        SunSystem.Attach(self.owner)
    end

    -- 启动全局高性能太阳阴影批处理调度器
    if ENABLE_LIGHTING then
        SunSystem.Init()
    end
    OceanLook.Apply((State.params.OceanOn or 1) > 0.5)

    -- 全局太阳阴影由 SunSystem 统一管理

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

    -- 动画统一驱动（8Hz，Lua 算好标量，GPU 零额外开销）：
    -- 1) 颗粒：TIME uniform 驱动胶片颗粒闪动（静止 TIME 只是一层死噪点）。
    -- 2) 辉光光晕呼吸：慢速多频正弦合成 0.92..1.08 标量，经 BCAS_GLOW2.w
    --    只调制光晕层——光源核心保持稳定，"活光"感不显廉价。
    self.inst:DoPeriodicTask(0.125, function()
        -- 必须 GLOBAL.PostProcessor：mod 环境启动时拷到的是 nil 空壳，
        -- 裸 PostProcessor 永远读不到引擎后来赋的真对象。
        local PP = GLOBAL.PostProcessor
        if PP == nil then return end
        -- GetTime 是游戏全局函数（mainfunctions.lua），TheSim 没有这个方法。
        local t = GLOBAL.GetTime()
        if State.handles.BCAS_ATMO ~= nil
            and ((State.params.Grain or 0) > 0
                or ((State.params.OceanOn or 1) > 0.5 and State.enabled ~= false)) then
            local v = State.PackUniform("BCAS_ATMO")
            PP:SetUniformVariable(
                State.handles.BCAS_ATMO, v[1], v[2], t % 64, v[4])
        end
        if State.handles.BCAS_GLOW2 ~= nil then
            -- 彻底关闭呼吸灯正弦晃动！省去计算，光照保持绝对沉稳舒适不闪烁！
            State.flicker = 1.0
            local v = State.PackUniform("BCAS_GLOW2")
            PP:SetUniformVariable(
                State.handles.BCAS_GLOW2, v[1], v[2], v[3], v[4])
        end
        -- 太阳在屏幕上的落点：驱动 cinema 天光方向 + glow 丁达尔/遮挡描边。
        local su, sv = SunSystem.GetSunScreenUV()
        State.sun_u, State.sun_v = su, sv
        if State.handles.BCAS_EXTRA ~= nil then
            local v = State.PackUniform("BCAS_EXTRA")
            PP:SetUniformVariable(
                State.handles.BCAS_EXTRA, v[1], v[2], v[3], v[4])
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
