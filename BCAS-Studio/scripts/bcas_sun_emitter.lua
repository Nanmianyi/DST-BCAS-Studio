--[[
    BCAS Studio -- world-space sun shadows, water sparkle, cloud-break shafts.

    Shadows:
      * Gnomon sun (day/dusk/moon). Never camera heading.
      * OnGround splat. Movers: NoFaced + world follow. Static: EightFaced + parent.
      * Scenery gets a ground splat except rocks / firepits / water / FX.
      * Movers copy anim by NAME then percent every tick (beefalo idle must snap).

    Water: oasis-style OnGround sparkle + cheap cyan Light. No ocean shader replace.

    Shafts: world-space ground patches + engine Light (real occluder rim).
      Positions drift like cloud breaks. Not a screen-space streak.
]]

local _G = rawget(_G, "GLOBAL") or _G
local CreateEntity = _G.CreateEntity
local ANIM_ORIENTATION = _G.ANIM_ORIENTATION
local LAYER_BACKGROUND = _G.LAYER_BACKGROUND
local DEGREES = _G.DEGREES or (math.pi / 180)
local FRAMES = _G.FRAMES or (1 / 30)
local SunSystem = {}

local shadows_enabled = true
local ocean_enabled = true
local shafts_amount = 1.0
local master_enabled = true


local SHADOW_MAX_LENGTH = 2.4
local SHADOW_MIN_LENGTH = 0.8
local TWICE_MAX = 2.0 * SHADOW_MAX_LENGTH
local DUSK_HYPOT = math.sqrt(SHADOW_MAX_LENGTH * SHADOW_MAX_LENGTH + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
local DUSK_ROTATION = math.deg(math.atan(SHADOW_MAX_LENGTH / SHADOW_MIN_LENGTH))
local FADE = 10 / 480
local NEAR_SQ = 40 * 40
local FAR_SQ = 62 * 62
local STATIC_HIDE_SQ = 46 * 46
local STATIC_NEAR_SQ = 18 * 18
local STATIC_MID_SQ = 30 * 30

local dynamic_shadows = setmetatable({}, { __mode = "k" })
local static_shadows = setmetatable({}, { __mode = "k" })
local water_fx = setmetatable({}, { __mode = "k" })
local shaft_ents = {}
-- 静态影子近距花名册：0.5s 任务重建（≤46u），逐帧任务只扫它做姿态插值，
-- 避免每帧 pairs 全量静态表（几百个）+ GetWorldPosition 的开销。
local static_roster = {}
local roster_n = 0

local function DropAllShadowEntities()
    for shadow, ent in pairs(dynamic_shadows) do
        if shadow:IsValid() then
            shadow:Remove()
        end
        if ent and ent:IsValid() and ent._bcas_shadow == shadow then
            ent._bcas_shadow = nil
        end
        if ent and ent:IsValid() and ent.DynamicShadow ~= nil then
            pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, true)
        end
        dynamic_shadows[shadow] = nil
    end
    for shadow, ent in pairs(static_shadows) do
        if shadow:IsValid() then
            shadow:Remove()
        end
        if ent and ent:IsValid() and ent._bcas_shadow == shadow then
            ent._bcas_shadow = nil
        end
        static_shadows[shadow] = nil
    end
    for i = 1, #shaft_ents do
        local e = shaft_ents[i]
        if e and e:IsValid() then
            if e.Light then e.Light:Enable(false) end
            e:Remove()
        end
        shaft_ents[i] = nil
    end
    for i = 1, #static_roster do
        static_roster[i] = nil
    end
    roster_n = 0
end

-- 重新开启：给世界存量实体一次性补挂剪影（O(n) 单帧，实体已按条件过滤）。
-- 没有这一步，开关回 ON 后只有新刷实体有影子，存量树/建筑要等 sleep/wake。
-- ShouldHaveShadow 必须前置声明：函数体在其定义之前引用它，若不做局部
-- 前向声明，闭包会退化为全局查找——strict.lua 环境下运行时报错（3.6.1
-- 的 OFF 向崩溃同源，这次是 ON 向：拨回 ON 的瞬间必炸）。
local ShouldHaveShadow
local function RescanAttachAll()
    local Ents = _G.Ents
    if Ents == nil then return end
    for _, ent in pairs(Ents) do
        if ent ~= nil and ent:IsValid() and ent.AnimState ~= nil and ent.Transform ~= nil then
            if ent:HasTag("player") or ShouldHaveShadow(ent) then
                SunSystem.AttachShadowToEntity(ent)
            end
        end
    end
end


local HEIGHT_SCALES = {
    cookpot = 0.50, icebox = 0.50, researchlab = 0.85, researchlab2 = 0.85,
    pighouse = 1.0, tent = 0.70, chest = 0.34, dragonflychest = 0.38,
    evergreen = 1.0, evergreen_sparse = 1.0,
    grass = 0.42, sapling = 0.52, berrybush = 0.50, berrybush2 = 0.50,
    berrybush_juicy = 0.50, marsh_bush = 0.40, reeds = 0.45,
    flower = 0.28, flower_evil = 0.30, succulent_plant = 0.30,
    carrot_planted = 0.30, plant_meat = 0.30,
    deciduoustree = 1.0, deciduoustree_tall = 1.0, deciduoustree_normal = 1.0, deciduoustree_short = 1.0,
    twiggytree = 1.0, twiggy_tall = 1.0, twiggy_normal = 1.0, twiggy_short = 1.0, twiggy_old = 1.0,
    marsh_tree = 0.90, moon_tree = 1.0,
}

local NO_SHADOW_PREFABS = {
    rock1 = true, rock2 = true, rock_flintless = true, rock_moon = true,
    rock_ice = true, rock_petrified_tree = true, rock_moon_shell = true,
    firepit = true, campfire = true, coldfirepit = true, nightlight = true,
    pigtorch = true, lava_pond = true,
}

local NO_SHADOW_TAGS = {
    "FX", "DECOR", "INLIMBO", "pond", "watersource", "boat",
    "antlion_sinkhole", "shadowcreature", "nightmarecreature",
    -- 水生生物不打地面影子（在水里投影太违和）：鱼/龙虾/饼干切割机等
    "swimming", "oceanfish", "pondfish", "fish", "cookiecutter",
    "wobster", "waterplant", "aquatic", "oceanfishinghookable",
    -- 暗影棋子（三基佬）：透明 Boss，不该有影子。三形态同一 prefab，
    -- 一个 shadowchesspiece tag 全覆盖（战车/骑士/主教）。
    "shadowchesspiece",
    -- 阿比盖尔：幽灵，整体漂浮，不该有地面影子（本体带 abigail 标签）。
    "abigail",
}

-- 部分水生生物没有专属 tag，用 prefab 名兜底（shark/wobster/lobster/...）
local NO_SHADOW_PREFAB_HINTS = {
    "fish", "lobster", "wobster", "cookiecutter", "shark",
    "starfish", "jellyfish", "waterplant", "crabking",
    -- 暗影棋子三个 prefab（tag 之外的兜底，含可能的 ruins 变体）
    "shadow_rook", "shadow_knight", "shadow_bishop",
    -- 阿比盖尔各形态（本体 abigail / 竞技场 lavaarena_abigail 等）
    "abigail",
}

local WATER_PREFABS = {
    hotspring = true,
}

local _cache = { scale_y = 1.5, rot = 45, a = 0.65, r = 0, g = 0, b = 0, key = nil }
local nearby_movers = 0
local nearby_movers_last = 0

local function HasAnyTag(ent, tags)
    for i = 1, #tags do
        if ent:HasTag(tags[i]) then
            return true
        end
    end
    return false
end

local function IsMover(ent)
    if ent == nil or not ent:IsValid() then return false end
    if ent:HasTag("plant") or ent:HasTag("tree") or ent:HasTag("boulder")
        or ent:HasTag("structure") or ent:HasTag("DECOR") or ent:HasTag("FX") then
        return false
    end
    if ent:HasTag("player") or ent:HasTag("locomotor") then return true end
    if ent:HasTag("character") or ent:HasTag("animal") or ent:HasTag("monster") then return true end
    if ent:HasTag("smallcreature") or ent:HasTag("largecreature") then return true end
    if ent.replica and ent.replica.locomotor ~= nil then return true end
    return false
end

local function ShouldHaveShadowImpl(ent)
    if ent == nil or not ent:IsValid() then return false end
    if ent._isshadow then return false end
    if NO_SHADOW_PREFABS[ent.prefab] then return false end
    if ent:HasTag("boulder") then return false end
    if HasAnyTag(ent, NO_SHADOW_TAGS) then return false end
    -- 水生生物（无专属 tag 的用 prefab 名兜底）一律不投影
    local _pf = ent.prefab
    if type(_pf) == "string" then
        for i = 1, #NO_SHADOW_PREFAB_HINTS do
            if string.find(_pf, NO_SHADOW_PREFAB_HINTS[i], 1, true) then
                return false
            end
        end
    end
    if ent:HasTag("inventoryitem") and not IsMover(ent) then return false end
    if ent.Transform == nil or ent.AnimState == nil then return false end
    if ent:HasTag("player") or IsMover(ent) then return true end
    -- Trees yes. Grass / flowers / saplings / bushes: no (they are the lag).
    if ent:HasTag("tree") then return true end
    if ent:HasTag("structure") or ent:HasTag("shelter") then return true end
    if HEIGHT_SCALES[ent.prefab] ~= nil then return true end
    if ent:HasTag("deciduoustree") or ent:HasTag("birchnut") or ent:HasTag("twiggytree") then
        return true
    end
    local prefab = ent.prefab
    if type(prefab) == "string" then
        if string.find(prefab, "deciduous", 1, true) or string.find(prefab, "twiggy", 1, true) then
            return true
        end
    end
    return false
end
ShouldHaveShadow = ShouldHaveShadowImpl

local function GetSunParams()
    local W = _G.TheWorld
    if not W or not W.state then
        return _cache.scale_y, _cache.rot, _cache.a, _cache.r, _cache.g, _cache.b
    end
    if W:HasTag("cave") then
        _cache.scale_y, _cache.rot, _cache.a = 1.0, 0.0, 0.0
        _cache.r, _cache.g, _cache.b = 0, 0, 0
        return 1.0, 0.0, 0.0, 0, 0, 0
    end

    local state = W.state
    local phase = state.phase or "day"
    local progress = state.timeinphase or 0.5
    local time = state.time or 0.5
    local moon = state.isfullmoon and 1 or 0
    -- 缓存键 6 位小数：%.3f 会把太阳参数量化成 ~0.3s 一跳（白天 300s 时
    -- progress 每变 0.001 需 0.3s），影子逐帧扫描用的仍是台阶值；6 位后
    -- 重算频率≈sim tick，计算本身只是几次三角函数，可忽略。
    local key = phase .. ":" .. string.format("%.6f", progress) .. ":" .. moon

    if key ~= _cache.key then
        if _cache.key and _cache.progress and _cache.progress > 0.9 and progress < 0.1
            and phase == (_cache.phase or phase) then
            progress = 1
        end
        _cache.key = key
        _cache.phase = phase
        _cache.progress = progress

        local scale_y, rot, a = 0, 0, 0
        local r, g, b = 0, 0, 0
        if phase == "day" then
            local leg1 = TWICE_MAX * (progress - 0.5)
            scale_y = math.sqrt(leg1 * leg1 + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
            rot = math.deg(math.atan(leg1 / SHADOW_MIN_LENGTH))
            a = 0.55 * math.min(1, time / FADE)
        elseif phase == "dusk" then
            scale_y = DUSK_HYPOT
            rot = DUSK_ROTATION
            a = 0.55 * (1 - progress)
        elseif phase == "night" and moon == 1 then
            local leg1 = TWICE_MAX * (progress - 0.5)
            scale_y = math.sqrt(leg1 * leg1 + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
            rot = math.deg(math.atan(leg1 / SHADOW_MIN_LENGTH))
            a = 0.40 * math.min(1, progress / FADE)
            r, g, b = 0.10, 0.15, 0.30
        end
        if state.season == "winter" then a = a * 0.85
        elseif state.season == "summer" then a = a * 1.10 end
        if state.precipitation == "rain" or state.precipitation == "snow" then
            a = a * 0.80
        end
        _cache.scale_y, _cache.rot, _cache.a = scale_y, rot, a
        _cache.r, _cache.g, _cache.b = r, g, b
    end
    return _cache.scale_y, _cache.rot, _cache.a, _cache.r, _cache.g, _cache.b
end

function SunSystem.GetSunScreenUV()
    local scale_y, rot = GetSunParams()
    local heading = 45
    local cam = _G.TheCamera
    if cam ~= nil then
        if cam.GetHeading then
            heading = cam:GetHeading() or heading
        elseif cam.heading then
            heading = cam.heading
        end
    end
    local rel_angle = (rot + 180.0 - heading) * DEGREES
    local radius = 0.72 + 0.35 * math.min(scale_y, 2.5)
    local u = 0.5 + radius * math.sin(rel_angle)
    local v = 0.42 - radius * math.cos(rel_angle)
    return u, v
end

-- Loop policy + clip name scan order. MUST sit above CopyFrame/CopyAnim:
-- strict.lua turns a forward reference into an undeclared-global error.
local LOOP_ANIMS = {
    idle_loop = true, idle = true, idle_inaction = true, idle_sit = true,
    idle_scared = true, idle_walk = true, sleep_loop = true, graze = true,
    graze_empty = true, walk_loop = true, run_loop = true,
    lookup_loop = true, lookdown_loop = true,
    sway1_loop = true, sway2_loop = true, sway_loop = true,
    idle_short = true, idle_normal = true, idle_tall = true, idle_old = true,
    sway1_loop_short = true, sway2_loop_short = true,
    sway1_loop_normal = true, sway2_loop_normal = true,
    sway1_loop_tall = true, sway2_loop_tall = true,
    sway1_loop_old = true, sway2_loop_old = true,
    sway_loop_agro = true,
}

-- 一次性剪辑（播完定格，不该循环播放）：影子按「源实体当前剪辑是否属于这里」
-- 决定循环与否。否则 grow / picked 这类一次性动画会被无限循环播放，看起来就是
-- "影子在萎靡与生长之间疯狂循环"。
local ONESHOT_ANIMS = {
    "grow", "picking", "picked", "dead_to_empty", "empty_to_dead", "full_to_dead",
    "grass_part", "fallleft", "fallright", "chop", "stump", "chop_burnt",
    "burning", "burnt", "idle_chop_burnt", "hit", "atk", "eat", "death",
    "dismount", "hop", "hop_pre", "hop_pst",
    "walk_pre", "walk_pst", "run_pre", "run_pst",
    "lookup_pre", "lookdown_pre", "lookup_pst", "lookdown_pst",
    "taunt", "shake", "graze", "graze_empty", "sleep",
}

local MOVER_ANIMS = {
    "idle_loop", "idle", "idle_inaction", "idle_sit", "idle_scared",
    "lookup_loop", "lookdown_loop", "lookup_pre", "lookdown_pre",
    "lookup_pst", "lookdown_pst",
    "walk_loop", "walk", "walk_pre", "walk_pst",
    "run_loop", "run", "run_pre", "run_pst",
    "hop", "hop_pre", "hop_pst",
    "idle_walk", "atk", "hit", "eat", "sleep", "sleep_loop", "death",
    "graze", "graze_empty", "shake", "taunt", "mount", "dismount",
    "idle_loop_pst",
    "sway1_loop", "sway2_loop", "sway_loop",
    "idle_short", "idle_normal", "idle_tall", "idle_old",
    "sway1_loop_short", "sway2_loop_short",
    "sway1_loop_normal", "sway2_loop_normal",
    "sway1_loop_tall", "sway2_loop_tall",
    "sway1_loop_old", "sway2_loop_old",
    "sway_loop_agro",
}

local function CopyFrame(pa, sa, shadow, allow_restart)
    if pa == nil or sa == nil then return end
    if pa.GetCurrentAnimationFrame and sa.SetFrame and sa.GetCurrentAnimationNumFrames then
        local frame = pa:GetCurrentAnimationFrame()
        if frame ~= nil then
            -- Source clip RESTARTED (frame jumped backwards): mirror the
            -- restart so hop-cadence creatures replays match 1:1. MOVERS
            -- only: a tree's looping sway wraps all the time, and after a
            -- sleep the stale _last_frame made every wake restart the splat
            -- (the "choppy sway" bug).
            if allow_restart ~= false
                and shadow._last_frame ~= nil and frame < shadow._last_frame - 2
                and shadow._last_anim_name ~= nil then
                sa:PlayAnimation(shadow._last_anim_name, LOOP_ANIMS[shadow._last_anim_name] == true)
                shadow._last_frame = nil
                return
            end
            if frame ~= shadow._last_frame then
                shadow._last_frame = frame
                local num = sa:GetCurrentAnimationNumFrames()
                if num and num > 0 then
                    sa:SetFrame(frame % num)
                end
            end
        end
    end
end

local function DetectAnimName(pa, shadow)
    if pa.IsCurrentAnimation then
        local names = shadow._anim_try
        if names == nil then
            names = MOVER_ANIMS
            shadow._anim_try = names
        end
        for i = 1, #names do
            local n = names[i]
            if pa:IsCurrentAnimation(n) then
                return n
            end
        end
    end
    return nil
end

local function CopyLeaves(pa, sa, shadow, force)
    if pa.GetSymbolOverride == nil then return end
    local leaf_build, leaf_sym = pa:GetSymbolOverride("swap_leaves")
    local key = tostring(leaf_build) .. ":" .. tostring(leaf_sym)
    if not force and key == shadow._last_leaf then
        return
    end
    shadow._last_leaf = key
    if leaf_build then
        sa:OverrideSymbol("swap_leaves", leaf_build, leaf_sym or "swap_leaves")
    elseif shadow._is_birch then
        -- Winter / barren: no canopy. Keep trunk-only splat.
        sa:ClearOverrideSymbol("swap_leaves")
    end
end

-- DLC 角色影子的正解（2026-09-09，抄自工坊 3794362938 DST Shadows 的成熟
-- 实现）：**不猜任何 build 名**。每帧把 sa:GetBuild() 镜像到影子（SetBuild
-- 不打断动画），皮肤 build 用 ss:SetSkin(skin, base_build) 镜像——DLC 角色
-- （wurt/wortox/wormwood/wanda/walter）的基础美术全走皮肤系统，GetBuild()
-- 报 "wilson"（共享 bank 的基础 build），美术本体在 GetSkinBuild() 里，
-- 影子必须同样走 SetSkin 才能立起来。此前 SetBuild(角色名) 静默失败的
-- 根因：皮肤 build 不经 SetSkin 路径不渲染。

-- Equipment swap slots the body's AnimState can carry. Used ONLY by the
-- non-player path (SyncOverrides below): animals don't change gear, so
-- GetSymbolOverride readback is enough for them. Players go through
-- SyncPlayerEquipment (replica + skin table) instead.

local SWAP_SYMBOLS = {
    "swap_object", "swap_hat", "swap_hat_open", "swap_hat_snow",
    "swap_hat_rain", "swap_hat_top", "swap_body", "swap_body_open",
    "swap_body_short", "swap_body_tall", "swap_arm",
}

-- 2026-09 装备镜像重建（照抄工坊 3794362938 DST Shadows 的实现）：
--   * 带皮肤的手持/护甲由引擎经 OverrideItemSkinSymbol（皮肤表）上装，
--     该表无任何读回——GetSymbolOverride 只能看到普通表，普通表在换装时
--     冻结，这就是"影子拿上一次的工具/开局空手"的根因；
--   * 权威客户端数据源 = 装备实体本身：item:GetSkinBuild() 给皮肤 build，
--     手持物的 swap 数据在 components.floater.swap_data（sym_name/sym_build）；
--   * 槽位符号约定：HANDS -> "swap_object"，其余 -> "swap_"..槽名；
--   * 服务器卸下手持物时不清 swap_object 覆盖（只切 ARM 图层），所以
--     "空手"判定必须走 inventory replica，并且影子要自己切 ARM_carry/
--     ARM_normal 图层；
--   * 皮肤装备占用的符号进 reserved 集，普通表镜像跳过，避免被 nil 清掉。
local PLAYER_EQUIP_SYMBOLS = {
    "swap_hat", "swap_body", "swap_body_tall", "swap_face", "swap_hands",
    "swap_lantern", "swap_compass", "swap_umbrella", "swap_oar", "swap_fishingrod",
    "swap_net", "swap_torch", "swap_shield", "swap_spear", "swap_staffs", "swap_slingshot",
    "swap_trident", "swap_bedroll", "swap_balloon", "swap_antler_red", "swap_klaus_antler",
    "swap_light", "swap_flower", "swap_mushroom", "swap_rope", "swap_saddle", "swap_boulder",
    "swap_chain", "swap_statue", "swap_remote", "swap_offering", "swap_rack", "swap_dumbbell",
    "swap_deploytoss_object", "swap_fan", "swap_gem", "swap_moon", "swap_pocket_scale_body",
    "swap_spear_wathgrithr_lightning", "swap_lucy_axe", "swap_neck_collar", "swap_object_bernie",
    "swap_toad_frozen", "swap_goo", "swap_float", "swap_frozen", "swap_food", "swap_cooked",
    "swap_spice", "swap_garnish", "swap_follow", "swap_item", "swap_item2", "swap_normal",
    "swap_number", "swap_number1", "swap_card", "swap_card1", "swap_suit", "swap_suit1",
    "swap_band_btm", "swap_band_top", "swap_chain_link", "swap_chain_lock", "swap_hattop",
    "swap_goosplat", "swap_dried", "swap_grown", "swap_handle", "swap_plate", "swap_frame",
    "swap_meter", "swap_scarecrow_face",
}

local function GetItemEquipSkinData(item, slot_sym)
    -- 原版姿势（torch/hats 等 prefab 的 onequip 照抄）：
    --   手持: owner:OverrideItemSkinSymbol("swap_object", skin_build, "swap_"..prefab, GUID, "swap_"..prefab)
    --   帽子/护甲: owner:OverrideItemSkinSymbol("swap_hat"/"swap_body", skin_build, "swap_hat"/"swap_body", GUID, fname)
    -- 第三参是皮肤 build 内部的【源符号名】。此前误传 item.AnimState:GetBuild()
    -- （那是个 build 名不是符号名），引擎在皮肤 build 里找不到该符号 →
    -- 皮肤手持物永远空气。手持物绝大多数符合 "swap_"..prefab 规律。
    if slot_sym ~= "swap_object" then
        return slot_sym, slot_sym
    end
    local sym = item ~= nil and item.prefab ~= nil and ("swap_" .. item.prefab) or nil
    if sym == nil or sym == "" then
        return slot_sym, slot_sym
    end
    return sym, sym
end

-- 衣物部位符号（聚合自原版 scripts/clothing.lua 的 CLOTHING.symbol_overrides）。
-- 上衣/裤子/手套等衣物皮肤由引擎 skinner 经 OverrideSkinSymbol 覆盖在身体
-- 部位符号上，GetSymbolOverride 可读回；SetSkin(skin_build) 只带角色皮肤
-- 不带衣物——不镜像这些符号影子就永远"穿着空气"。
local CLOTHING_SYMBOLS = {
    "arm_lower", "arm_lower_cuff", "arm_skin", "arm_upper", "arm_upper_skin",
    "foot", "hand", "hand_idle_wormwood", "hand_wickerbottom",
    "leg", "skirt", "tail", "torso", "torso_pelvis",
}

-- 手持/帽子等核心符号的写入日志（临时诊断，量少直接打）。
local function LogSwapWrite(shadow, tag, sym, b, s)
    if sym ~= "swap_object" and sym ~= "swap_hat" and sym ~= "swap_body" then return end
    shadow._swap_logs = (shadow._swap_logs or 0) + 1
    if shadow._swap_logs <= 10 then
        print("[BCAS] 影子写入[" .. tag .. "] " .. sym .. " <- " .. tostring(b) .. "," .. tostring(s))
    end
end

-- 装备的皮肤 build：优先 GetSkinBuild()；个别手持物在客户端返回空，但皮肤
-- build 已经写在物品实体 AnimState 上（≠ prefab、也 ≠ swap_prefab）——用它
-- 兜底，避免"换了皮肤的影子被还原成默认原皮"。
local function EquipSkinBuild(item)
    if item == nil then return nil end
    local sb = item.GetSkinBuild ~= nil and item:GetSkinBuild() or nil
    if sb ~= nil and sb ~= "" then return sb end
    if item.AnimState ~= nil and item.AnimState.GetBuild ~= nil then
        local hb = item.AnimState:GetBuild()
        local pf = item.prefab
        if hb ~= nil and hb ~= "" and type(pf) == "string"
            and hb ~= pf and hb ~= ("swap_" .. pf) then
            return hb
        end
    end
    return nil
end

local function SyncPlayerEquipment(source, pa, sa, shadow)
    local inv = source.replica ~= nil and source.replica.inventory or nil

    -- SetBuild/SetSkin 会清空影子整个覆盖表：脏标记必须在节流 gate 之前
    -- 消费——被抹掉的那一帧就立刻全量重涂，绝不留空窗。
    if shadow._eq_dirty then
        shadow._eq_dirty = nil
        shadow._equip_cache = nil
        shadow._sym_cache = nil
        shadow._cloth_cache = nil
        shadow._hbh_want = nil
        shadow._vis_key = nil
    end

    -- 覆盖类扫描节流：5 帧扫一次（与参考 3794362938 的
    -- shadow_override_scan_interval=5 一致），大幅减轻逐符号压力
    local counter = (shadow._equip_counter or 0) + 1
    shadow._equip_counter = counter
    if counter % 5 ~= 1 then return end

    local eq_cache = shadow._equip_cache or {}
    shadow._equip_cache = eq_cache
    local sym_cache = shadow._sym_cache or {}
    shadow._sym_cache = sym_cache
    local cloth_cache = shadow._cloth_cache or {}
    shadow._cloth_cache = cloth_cache

    -- 1) 头部/身体装备（帽子 / 护甲 / 背包）——与手部同构的"物品实体驱动"。
    -- 旧方案两处硬伤（2026-09-11 定位）：
    --   a) pa:GetSymbolOverride 读不回引擎皮肤表 → 带皮肤的帽子/护甲永远空气；
    --   b) EquipSkinBuild 的 AnimState:GetBuild() 兜底会把普通帽子
    --      （帽子物品 build = "hat_xxx"，≠ prefab）误判成"皮肤物"，
    --      于是写了错误的 swap_hat 覆盖 → 常见的普通帽子反而消失。
    -- 改为直接读 replica 里的装备实体，用实体自身当前渲染的 build 镜像：
    --   帽子      -> OverrideSymbol("swap_hat",  build, "swap_hat")
    --   护甲/背包 -> OverrideSymbol("swap_body", build, "swap_body")
    -- 皮肤 build 内部同样携带 swap_hat/swap_body 符号，所以原皮/皮肤通吃。
    local reserved = {}
    local HEAD_BODY = { { name = "head", sym = "swap_hat" }, { name = "body", sym = "swap_body" } }
    local hb_equips = nil
    if inv ~= nil and inv.GetEquippedItem ~= nil then
        for i = 1, #HEAD_BODY do
            local slot = HEAD_BODY[i]
            local ok_i, item = pcall(inv.GetEquippedItem, inv, slot.name)
            if ok_i and item ~= nil then
                -- 取物品"当前实际渲染"的 build：套了皮肤就是皮肤 build，
                -- 否则是默认 swap build。
                local actual = nil
                if item.AnimState ~= nil and item.AnimState.GetBuild ~= nil then
                    actual = item.AnimState:GetBuild()
                end
                if actual == nil or actual == "" then
                    actual = EquipSkinBuild(item)
                end
                if actual ~= nil and actual ~= "" then
                    -- 是否套了皮肤：帽子默认 build = "hat_"..(prefab 去掉尾部 hat)，
                    -- 护甲默认 = prefab，背包默认 = "swap_"..prefab。
                    local pf = item.prefab
                    local default = nil
                    if type(pf) == "string" and pf:sub(-3) == "hat" then
                        default = "hat_" .. pf:sub(1, -4)
                    end
                    local is_skin
                    if default ~= nil then
                        is_skin = (actual ~= default)
                    else
                        is_skin = (actual ~= pf) and (actual ~= ("swap_" .. tostring(pf)))
                    end
                    hb_equips = hb_equips or {}
                    hb_equips[slot.name] = {
                        sym = slot.sym, build = actual, guid = item.GUID,
                        skin = is_skin, base = default or pf,
                    }
                    reserved[slot.sym] = true
                end
            end
        end
    end

    if hb_equips ~= nil then
        for slot_name, d in pairs(hb_equips) do
            local last = eq_cache[slot_name]
            if last == nil or last.build ~= d.build or last.guid ~= d.guid
                or last.sym ~= d.sym or last.skin ~= d.skin then
                eq_cache[slot_name] = { sym = d.sym, build = d.build, guid = d.guid, skin = d.skin }
                pcall(sa.ClearOverrideSymbol, sa, d.sym)
                local done = false
                if d.skin then
                    -- 皮肤 build 必须走引擎皮肤表：普通 OverrideSymbol 对皮肤
                    -- build 不生效（日志实证：footballhat 皮肤 build 写入后影子
                    -- 回读为 nil）。写入后用 readback 确认，失败再退回普通覆盖。
                    local ok = pcall(sa.OverrideItemSkinSymbol, sa, d.sym, d.build,
                        d.sym, d.guid, d.base or d.build)
                    if ok and sa.GetSymbolOverride ~= nil and sa:GetSymbolOverride(d.sym) ~= nil then
                        done = true
                        LogSwapWrite(shadow, "头身皮肤", d.sym, d.build, d.sym)
                    else
                        pcall(sa.ClearOverrideSymbol, sa, d.sym)
                    end
                end
                if not done then
                    pcall(sa.OverrideSymbol, sa, d.sym, d.build, d.sym)
                    LogSwapWrite(shadow, "头身", d.sym, d.build, d.sym)
                end
            end
        end
    end
    for slot_name, last in pairs(eq_cache) do
        if hb_equips == nil or hb_equips[slot_name] == nil then
            eq_cache[slot_name] = nil
            if last.sym ~= nil then pcall(sa.ClearOverrideSymbol, sa, last.sym) end
        end
    end

    -- 1b-pre) 全盔检测：原角色普通覆盖表里若有 headbase_hat → 这顶是全覆盖盔，
    -- 1c 据此决定 HAIR / HEAD_HAT 图层（皮肤全盔读不回时会当作普通帽，也能显示）。
    local head_equipped = hb_equips ~= nil and hb_equips["head"] ~= nil
    local head_is_fullhelm = false
    if head_equipped and pa.GetSymbolOverride ~= nil then
        local hb_build = pa:GetSymbolOverride("headbase_hat")
        head_is_fullhelm = hb_build ~= nil
    end
    -- 1b) headbase_hat 换头路径在影子上不生效（非 player AnimState，见 1c），
    -- 统一清掉；head_is_fullhelm 仍用于 1c 决定 HAIR / HEAD_HAT 图层。
    if shadow._hbh_cleared ~= true then
        shadow._hbh_cleared = true
        pcall(sa.ClearOverrideSymbol, sa, "headbase_hat")
    end

    -- 1c) 图层显隐镜像（2026-09-11 关键修复）。
    -- 影子只镜像"符号覆盖"，从不复制原角色的 Show/Hide 图层状态；手部能显示
    -- 全靠 step4 显式切了 ARM_carry。帽子/护甲的符号所在的图层默认是隐藏的
    -- （HAT / HEAD_HAT_HELM / swap_body 等），所以覆盖写了也画不出来——
    -- 这正是"功能帽(swap_hat 走默认可见层)显示、全盔与护甲/背包不显示"的原因。
    -- 这里按装备情况把图层状态复刻成与原版 onequip 一致。
    local body_has = hb_equips ~= nil and hb_equips["body"] ~= nil
    local vis_key = (head_equipped and "1" or "0") .. (head_is_fullhelm and "f" or "n")
        .. (body_has and "1" or "0")
    if shadow._vis_key ~= vis_key then
        shadow._vis_key = vis_key
        if head_equipped and head_is_fullhelm then
            -- 全盔：原版走 headbase_hat 换头并把 HAT 层 Hide；但换头机制在
            -- 影子（非 player AnimState）上不生效，Hide HAT 会让已写好的
            -- swap_hat 帽子一起消失（虚空风帽"头没了帽子也没有"的根因）。
            -- 影子改为普通帽子路线：显示 HAT 层 + 我们的 swap_hat 覆盖，
            -- 头盔美术本身自带整头造型，再 Hide HEAD 即可。
            pcall(sa.Show, sa, "HAT"); pcall(sa.Hide, sa, "HAIR_HAT")
            pcall(sa.Hide, sa, "HAIR_NOHAT"); pcall(sa.Hide, sa, "HAIR")
            pcall(sa.Hide, sa, "HEAD")
            pcall(sa.Show, sa, "HEAD_HAT")
            pcall(sa.Show, sa, "HEAD_HAT_NOHELM")
            pcall(sa.Show, sa, "HEAD_HAT_HELM")
            pcall(sa.UseHeadHatExchange, sa, false)
            pcall(sa.HideSymbol, sa, "face"); pcall(sa.HideSymbol, sa, "swap_face")
            pcall(sa.HideSymbol, sa, "beard"); pcall(sa.HideSymbol, sa, "cheeks")
        elseif head_equipped then
            pcall(sa.Show, sa, "HAT"); pcall(sa.Hide, sa, "HAIR_HAT")
            pcall(sa.Show, sa, "HAIR_NOHAT"); pcall(sa.Show, sa, "HAIR")
            pcall(sa.Hide, sa, "HEAD")
            pcall(sa.Show, sa, "HEAD_HAT")
            pcall(sa.Show, sa, "HEAD_HAT_NOHELM")
            pcall(sa.Hide, sa, "HEAD_HAT_HELM")
            pcall(sa.UseHeadHatExchange, sa, false)
            pcall(sa.ShowSymbol, sa, "face"); pcall(sa.ShowSymbol, sa, "swap_face")
            pcall(sa.ShowSymbol, sa, "beard"); pcall(sa.ShowSymbol, sa, "cheeks")
        else
            pcall(sa.Hide, sa, "HAT")
            pcall(sa.Show, sa, "HEAD"); pcall(sa.Show, sa, "HAIR")
            pcall(sa.Show, sa, "HAIR_NOHAT")
            pcall(sa.Hide, sa, "HEAD_HAT"); pcall(sa.Hide, sa, "HEAD_HAT_HELM")
            pcall(sa.UseHeadHatExchange, sa, false)
            pcall(sa.ShowSymbol, sa, "face"); pcall(sa.ShowSymbol, sa, "swap_face")
            pcall(sa.ShowSymbol, sa, "beard"); pcall(sa.ShowSymbol, sa, "cheeks")
        end
        if body_has then
            pcall(sa.Show, sa, "swap_body")
            pcall(sa.ShowSymbol, sa, "swap_body")
            pcall(sa.Show, sa, "backpack")
        end
    end

    -- 1d) 诊断（临时）：本地玩家每 ~2 秒回读源/影子的关键符号，定位"写了没生效"。
    if shadow._is_player and source == _G.ThePlayer then
        local sc = (shadow._scan_count or 0) + 1
        shadow._scan_count = sc
        if sc % 24 == 0 then
            local function rbs(a, sym)
                if a == nil or a.GetSymbolOverride == nil then return "noapi" end
                local b, s = a:GetSymbolOverride(sym)
                return tostring(b) .. "|" .. tostring(s)
            end
            local rl = {}
            for k in pairs(reserved) do rl[#rl + 1] = k end
            print(string.format(
                "[BCAS] 装回读 源 hat=%s body=%s hbh=%s obj=%s || 影 hat=%s body=%s hbh=%s obj=%s | res={%s}",
                rbs(pa, "swap_hat"), rbs(pa, "swap_body"), rbs(pa, "headbase_hat"), rbs(pa, "swap_object"),
                rbs(sa, "swap_hat"), rbs(sa, "swap_body"), rbs(sa, "headbase_hat"), rbs(sa, "swap_object"),
                table.concat(rl, ",")))
        end
    end

    -- 2) 普通装备镜像（照抄 3794362938 成熟实现）：从原角色的 pa:GetSymbolOverride 读回！
    -- 原版斧头/手杖/木甲装备时，服务端把 swap_axe/swap_cane/armor_wood 写进了原角色的普通覆盖表。
    -- pa:GetSymbolOverride(sym) 能正确读出真实的 swap build 与 symbol！
    local function MirrorOne(sym)
        if reserved[sym] then return end
        if pa.GetSymbolOverride == nil then return end
        local sb, ssym = pa:GetSymbolOverride(sym)
        local last = sym_cache[sym]
        if sb ~= nil then
            if last == nil or last[1] ~= sb or last[2] ~= ssym then
                sym_cache[sym] = { sb, ssym }
                LogSwapWrite(shadow, "槽位", sym, sb, ssym or sym)
                sa:OverrideSymbol(sym, sb, ssym or sym)
            end
        elseif last ~= nil then
            sym_cache[sym] = nil
            LogSwapWrite(shadow, "清除", sym, nil, nil)
            sa:ClearOverrideSymbol(sym)
        end
    end

    -- 镜像所有身体/帽子等装备槽符号
    for i = 1, #PLAYER_EQUIP_SYMBOLS do
        MirrorOne(PLAYER_EQUIP_SYMBOLS[i])
    end

    -- 2b) 衣物部位镜像（"穿着空气"修复，照抄 3794362938 MirrorSkinSymbols）：
    -- 引擎 skinner 把衣物皮肤用 OverrideSkinSymbol 覆盖在身体部位符号上
    -- （torso/arm_upper/leg/foot...），GetSymbolOverride 可读回。注意必须
    -- 用 OverrideSkinSymbol 复刻——普通 OverrideSymbol 对皮肤部位不渲染。
    for i = 1, #CLOTHING_SYMBOLS do
        local sym = CLOTHING_SYMBOLS[i]
        local sb, ssym = pa:GetSymbolOverride(sym)
        local last = cloth_cache[sym]
        if sb ~= nil and sb ~= "" then
            if last == nil or last[1] ~= sb or last[2] ~= ssym then
                cloth_cache[sym] = { sb, ssym }
                pcall(sa.OverrideSkinSymbol, sa, sym, sb, ssym or sym)
            end
        elseif last ~= nil then
            cloth_cache[sym] = nil
            pcall(sa.ClearOverrideSymbol, sa, sym)
        end
    end

    -- 3) 手持装备判定（权威）：
    -- 服务器卸下手持物时不会清除 swap_object 覆盖（只切 ARM 图层），
    -- 所以不能单靠 swap_object 判断。本地玩家用 inventory replica（权威，卸载立即生效）。
    local has_hand_item = false
    if source == _G.ThePlayer then
        has_hand_item = inv ~= nil and inv:GetEquippedItem(_G.EQUIPSLOTS ~= nil and _G.EQUIPSLOTS.HANDS or "hands") ~= nil
    else
        has_hand_item = (pa.GetSymbolOverride ~= nil and pa:GetSymbolOverride("swap_object") ~= nil) or (reserved["swap_object"] == true)
    end

    -- swap_object 手持物【item-driven 自实现】（2026-09-09 定案）：
    -- 读回方案被证伪——参考 mod 3794362938 自己的手部就是空气，v3.6.4 读回
    -- 也时灵时不灵。原版 onequip 写的覆盖完全可从背包实体直接推导：
    --   工具/武器 prefab 构造时 SetBuild("swap_axe")，onequip 写
    --   OverrideSymbol("swap_object", "swap_axe", "swap_axe")——即
    --   build=实体AnimState build，symbol="swap_"..prefab。
    -- 带皮肤武器走上面步骤 1 的 OverrideItemSkinSymbol（reserved 排除）。
    if reserved["swap_object"] then
        -- 皮肤手持由步骤 1 的 OverrideItemSkinSymbol 管理
    elseif has_hand_item then
        local hand = nil
        if inv ~= nil and inv.GetEquippedItem ~= nil then
            hand = inv:GetEquippedItem(_G.EQUIPSLOTS ~= nil and _G.EQUIPSLOTS.HANDS or "hands")
        end
        local written = false
        if hand ~= nil and hand.prefab ~= nil then
            -- 原版 onequip 的权威数据源 = floater.swap_data.sym_build / sym_name
            -- （axe.lua: { sym_build="swap_axe", sym_name="swap_axe" }）。
            -- 物品实体自身的 build 是【背包图标 build】（"axe"），不是手持 build
            -- （"swap_axe"）——旧代码拿 GetBuild() 当手持 build 去比对，工具因此
            -- 被判成"皮肤物品"、走 OverrideItemSkinSymbol 的错路 = 影子拿空气。
            -- 手杖/火把的背包 build 恰好就是 swap_*，所以它们能显示、工具不能。
            local swd = hand.components ~= nil and hand.components.floater ~= nil
                and hand.components.floater.swap_data or nil
            local swap_build = (swd ~= nil and swd.sym_build)
                or ("swap_" .. tostring(hand.prefab))
            local sym_name = (swd ~= nil and swd.sym_name) or swap_build
            local skin = EquipSkinBuild(hand)
            if swap_build ~= nil and swap_build ~= "" then
                local last = sym_cache["swap_object"]
                if skin ~= nil and skin ~= "" then
                    -- 带皮肤手持：引擎皮肤表路径（先清普通残留再写皮肤覆盖）
                    if last == nil or last[1] ~= skin or last[2] ~= sym_name then
                        sym_cache["swap_object"] = { skin, sym_name }
                        pcall(sa.ClearOverrideSymbol, sa, "swap_object")
                        local ok, err = pcall(sa.OverrideItemSkinSymbol, sa, "swap_object",
                            skin, sym_name, hand.GUID, swap_build)
                        LogSwapWrite(shadow, ok and "手持皮肤" or "手持皮肤拒绝",
                            "swap_object", skin, sym_name .. " err=" .. tostring(err))
                        if not ok then
                            sa:OverrideSymbol("swap_object", swap_build, sym_name)
                        end
                    end
                else
                    -- 原皮手持（工具/武器/火把）：完全复刻原版
                    -- owner.AnimState:OverrideSymbol("swap_object", swap_build, sym_name)
                    if last == nil or last[1] ~= swap_build or last[2] ~= sym_name then
                        sym_cache["swap_object"] = { swap_build, sym_name }
                        pcall(sa.ClearOverrideSymbol, sa, "swap_object")
                        LogSwapWrite(shadow, "手持", "swap_object", swap_build, sym_name)
                        sa:OverrideSymbol("swap_object", swap_build, sym_name)
                    end
                end
                written = true
            end
        end
        if not written and pa.GetSymbolOverride ~= nil then
            -- 实体信息拿不到时退回读回方案（双值接收，不能写成 and/or 链）
            local sb, ssym = pa:GetSymbolOverride("swap_object")
            if sb ~= nil then
                local last = sym_cache["swap_object"]
                if last == nil or last[1] ~= sb or last[2] ~= ssym then
                    sym_cache["swap_object"] = { sb, ssym }
                    LogSwapWrite(shadow, "手持读回", "swap_object", sb, ssym or "swap_object")
                    sa:OverrideSymbol("swap_object", sb, ssym or "swap_object")
                end
            end
        end
    elseif sym_cache["swap_object"] ~= nil then
        sym_cache["swap_object"] = nil
        sa:ClearOverrideSymbol("swap_object")
    end

    -- 4) 手臂图层：有手部装备 → Show ARM_carry / Hide ARM_normal；否则反之。
    if has_hand_item ~= shadow._arm_carry then
        shadow._arm_carry = has_hand_item
        if has_hand_item then
            sa:Show("ARM_carry")
            sa:Hide("ARM_normal")
        else
            sa:Hide("ARM_carry")
            sa:Show("ARM_normal")
        end
    end

    -- 5) 装备探针（临时诊断，发布前移除）：equip/unequip 事件触发一轮，
    --    把"源读回→占用→写入缓存→影子状态"全链路打进 client_log，
    --    一次测试实锤"空气手持/帽子弹回"的断链点。
    if shadow._diag_next then
        shadow._diag_next = nil
        local function rb(sym)
            if pa.GetSymbolOverride == nil then return "noapi" end
            local b, s = pa:GetSymbolOverride(sym)
            return tostring(b) .. "|" .. tostring(s)
        end
        local parts = {}
        if inv ~= nil and inv.GetEquippedItem ~= nil then
            local slots = _G.EQUIPSLOTS or { HANDS = "hands", HEAD = "head", BODY = "body" }
            for _, slot_name in pairs(slots) do
                local ok_i, it = pcall(inv.GetEquippedItem, inv, slot_name)
                if ok_i and it ~= nil then
                    local sn = it.GetSkinName ~= nil and tostring(it:GetSkinName()) or "?"
                    local sk = it.GetSkinBuild ~= nil and tostring(it:GetSkinBuild()) or "?"
                    local bd = it.AnimState ~= nil and it.AnimState.GetBuild ~= nil
                        and tostring(it.AnimState:GetBuild()) or "?"
                    parts[#parts + 1] = slot_name .. "=" .. tostring(it.prefab)
                        .. " 皮肤:" .. sn .. "/" .. sk .. " 实体build:" .. bd
                end
            end
        end
        local res, eqc, syc = {}, {}, {}
        for k in pairs(reserved) do res[#res + 1] = k end
        for k, v in pairs(eq_cache) do
            eqc[#eqc + 1] = k .. ":" .. tostring(v.skin or v.guid) .. "@" .. tostring(v.sym)
        end
        for k, v in pairs(sym_cache) do syc[#syc + 1] = k .. ":" .. tostring(v[1]) end
        print(string.format(
            "[BCAS] 探针[%s]: 读回 obj=(%s) hat=(%s) body=(%s) | 占用={%s} | 背包: %s"
            .. " | sym缓存: %s | eq缓存: %s | 影build=%s 影skin=%s",
            tostring(source == _G.ThePlayer and "本地" or "远端"),
            rb("swap_object"), rb("swap_hat"), rb("swap_body"),
            table.concat(res, ","),
            #parts > 0 and table.concat(parts, " ;; ") or "空手",
            table.concat(syc, ","),
            table.concat(eqc, ","),
            tostring(sa.GetBuild ~= nil and sa:GetBuild() or "?"),
            tostring(sa.GetSkinBuild ~= nil and sa:GetSkinBuild() or "?")))
    end
end

-- Mirror every equipment override + the skin build from the body's AnimState.
-- Skin = an override build applied engine-side on the client (SetPlayerSkin
-- netvar); GetSkinBuild() reads what is actually rendered, which on DLC
-- characters (wortox/wurt/wanda/walter) is the only reliable source -- their
-- GetBuild() can return the base build while a skin is showing.
local function SyncOverrides(pa, sa, shadow)
    if pa == nil or sa == nil or pa.GetSymbolOverride == nil then return end
    -- swap_object/hat/body for PLAYERS now come from the replica (above);
    -- plain-table mirroring of those would resurrect stale data. Non-player
    -- entities (no replica) still mirror everything from the plain table.
    local skip_core = shadow._is_player == true
    for i = 1, #SWAP_SYMBOLS do
        local sym = SWAP_SYMBOLS[i]
        if not (skip_core and (sym == "swap_object" or sym == "swap_hat" or sym == "swap_body")) then
            local b, s = pa:GetSymbolOverride(sym)
            local kb, ks = "_ovb_" .. sym, "_ovs_" .. sym
            if shadow[kb] ~= b or shadow[ks] ~= s then
                shadow[kb] = b
                shadow[ks] = s
                if b ~= nil then
                    sa:OverrideSymbol(sym, b, s or sym)
                else
                    sa:ClearOverrideSymbol(sym)
                end
            end
        end
    end
end

local function CopyAnim(pa, sa, shadow, force, src_ent)
    if pa == nil or sa == nil then return end

    -- Bank: hash first (workshop 3794362938). Name fallback for older clients.
    -- 引擎态对比（影子 sa:GetBankHash vs 源 pa:GetBankHash）：force 不再
    -- 绕过对比，事件风暴（newstate/equip → sync_now）不会反复重放 SetBank。
    if pa.GetBankHash and sa.GetBankHash then
        local bank_hash = pa:GetBankHash()
        if bank_hash and bank_hash ~= sa:GetBankHash() then
            sa:SetBank(bank_hash)
            shadow._last_bank_hash = bank_hash
            shadow._last_bank = nil
            shadow._last_leaf = nil
        end
    else
        local bank = pa.GetCurrentBankName and pa:GetCurrentBankName()
        if shadow._lock_bank then
            bank = shadow._lock_bank
        elseif shadow._is_birch then
            bank = "tree_leaf"
        elseif shadow._is_twiggy then
            bank = bank or "twiggy"
        end
        if bank and (force or bank ~= shadow._last_bank) then
            shadow._last_bank = bank
            sa:SetBank(bank)
            shadow._last_leaf = nil
        end
    end

    -- Build + 皮肤 build 镜像（2026-09-09，方案照抄工坊 3794362938）：
    -- **引擎态对比**：SetBuild 只在影子实际 build 与源不一致时执行。
    -- 此前 force 时无条件 SetBuild——newstate/equip 事件风暴每次都把影子
    -- 覆盖表整个抹掉，装备符号反复蒸发（"空气装备"直接根源之一）。
    -- GetBuild() 直接镜像（SetBuild 不打断动画），皮肤 build 用
    -- SetSkin(skin, base) 镜像。DLC 角色基础美术在皮肤系统里，影子只有
    -- 走同样的 SetSkin 才能渲染出正确轮廓——SetBuild(角色名) 会静默失败
    -- （皮肤 build 不经 SetSkin 路径不渲染，"DLC 影子消失"回归的根因）。
    local build = pa.GetBuild and pa:GetBuild()
    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        shadow._last_leaf = nil
        -- SetBuild 清空影子覆盖表：标记装备扫描强制重涂
        shadow._eq_dirty = true
    end
    if pa.GetSkinBuild ~= nil and sa.SetSkin ~= nil then
        local sb = pa:GetSkinBuild()
        if sb ~= nil and sb ~= "" then
            -- 源驱动对比（2026-09-10 装备空气第二根因）：引擎对 skin build
            -- 有内部归一化，SetSkin 的入参与 GetSkinBuild 的回读值可能永不相
            -- 等——逐帧引擎对比恒为"变了"→ 每帧 SetSkin → 每帧清空覆盖表 →
            -- 装备符号刚涂上就被抹（"拿空气"+重涂那帧"切换闪一下"）。改为
            -- 只对比源上一次的皮肤值：源真换肤才 SetSkin；失败最多重试 3 次。
            if sb ~= shadow._last_skin or (shadow._skin_tries or 0) < 3 then
                if sb ~= shadow._last_skin then
                    shadow._last_skin = sb
                    shadow._skin_tries = 0
                end
                shadow._skin_tries = (shadow._skin_tries or 0) + 1
                shadow._skin_sets = (shadow._skin_sets or 0) + 1
                if shadow._is_player and shadow._skin_sets == 10 then
                    print("[BCAS] 哨兵: 影子SetSkin已累计10次 源skin="
                        .. tostring(sb) .. " 影回读=" .. tostring(sa:GetSkinBuild())
                        .. "（若持续增长说明回读不匹配，装备会被每帧抹除）")
                end
                pcall(sa.SetSkin, sa, sb, build or "")
                shadow._eq_dirty = true
            end
            shadow._had_skin = true
        elseif shadow._had_skin then
            -- 皮肤卸下：重放基础 build 还原（SetBuild 同样清覆盖表 → 脏标记）
            shadow._had_skin = nil
            shadow._last_skin = nil
            shadow._skin_tries = 0
            if build ~= nil then
                sa:SetBuild(build)
                shadow._last_build = build
                shadow._last_leaf = nil
                shadow._eq_dirty = true
            end
        end
    end
    -- Equipment/skin overrides AFTER SetBuild/SetSkin: 二者都会清 OverrideSymbol。
    -- 玩家走装备槽权威镜像（皮肤表 + replica，见 SyncPlayerEquipment 注释）；
    -- 非玩家仍用普通表镜像（动物不换装），force 时全量重刷。
    if shadow._is_player then
        SyncPlayerEquipment(src_ent, pa, sa, shadow)
    elseif force then
        SyncOverrides(pa, sa, shadow)
    end
    -- Leaves AFTER SetBuild: SetBuild wipes OverrideSymbol.
    CopyLeaves(pa, sa, shadow, force)

    -- 动画镜像：以【引擎哈希】为准——比较"影子当前动画哈希"与"源当前动画哈希"，
    -- 不同就按源哈希重放。不再猜动画名（旧的 DetectAnimName 只认 mover 名表，
    -- 会把 picked / idle_dead / 树桩这些植物与树木状态漏掉），也不再用
    -- _last_anim_name + anti-flap 缓存（那套在状态间来回写会让影子定格或横跳）。
    -- 直接对比影子自身的哈希是自纠正的：PlayAnimation 没生效时下一轮还会重试。
    local anim_hash = pa.GetCurrentAnimationHash and pa:GetCurrentAnimationHash() or nil
    if anim_hash ~= nil then
        local sa_hash = sa.GetCurrentAnimationHash and sa:GetCurrentAnimationHash() or nil
        if sa_hash ~= anim_hash then
            -- 一次性剪辑不循环（grow/picked/砍树…），循环剪辑（idle/sway…）
            -- 才循环；否则影子会反复重播一次性动画。
            local loop = true
            if pa.IsCurrentAnimation ~= nil then
                for i = 1, #ONESHOT_ANIMS do
                    if pa:IsCurrentAnimation(ONESHOT_ANIMS[i]) then
                        loop = false
                        break
                    end
                end
            end
            pcall(sa.PlayAnimation, sa, anim_hash, loop)
            shadow._last_anim = anim_hash
            shadow._last_anim_hash = anim_hash
            shadow._last_anim_name = nil
            shadow._last_frame = nil
        end
    end
    CopyFrame(pa, sa, shadow, shadow._is_mover == true)
    end

local function ParentHidden(ent)
    if not ent:IsValid() then return true end
    if ent:HasTag("INLIMBO") then return true end
    if ent.IsInLimbo and ent:IsInLimbo() then return true end
    -- 直接 pcall(f, e)：旧写法 pcall(function() ... end) 每次调用都新建一个
    -- 闭包，逐帧 × 几百个影子 = 持续 GC 压力（卡顿来源之一）。传函数+参数
    -- 不分配闭包，行为一致。
    local e = ent.entity
    local f = e ~= nil and e.IsVisible or nil
    if f == nil then return false end
    local ok, vis = pcall(f, e)
    return ok and vis == false
end

local function ApplyPose(shadow, ent, scale_y, rot, r, g, b, a, follow)
    local sa = shadow.AnimState
    if sa == nil then return end
    local hf = shadow._height_factor or 1
    local hs = 1
    if follow then
        local px, py, pz = ent.Transform:GetWorldPosition()
        hs = 1 + math.max(0, py) * 0.01
        shadow.Transform:SetPosition(px, 0.002, pz)
        a = a * math.max(0, 1 - math.max(0, py) / 20)
        local target_rot = ent.Transform:GetRotation() or 0
        local delta = (rot - target_rot) % 360
        local flip = delta > 90 and delta < 270
        if flip ~= shadow._last_flip then
            shadow._last_flip = flip
            sa:SetScale(flip and -1 or 1, 1)
        end
    else
        -- 静态影子挂在父实体下（SetParent），本地坐标恒定；逐帧
        -- SetPosition(0,0.002,0) 是每帧×几百静态的浪费，设一次即可。
        if not shadow._pos_done then
            shadow._pos_done = true
            shadow.Transform:SetPosition(0, 0.002, 0)
        end
    end

    -- 量化姿态输入（性能）：太阳约 1.2 度/秒，逐帧对微小增量刷 SetScale/
    -- SetRotation/SetMultColour 是纯引擎调用浪费（几百个影子 × 每帧 3 次）。
    -- 1/8 度、约 0.8% 缩放、1/64 透明度的台阶肉眼不可察，却能砍掉数倍调用。
    -- 玩家自己的影子例外：直接原值，满帧刷新（就一个实体，开销可忽略，
    -- 但玩家对自身影子的跟随最敏感）。
    local rotq, syq, aq, rq
    if shadow._is_player then
        rotq = rot
        syq  = scale_y * hf * hs
        aq   = a
        rq   = r
    else
        rotq = math.floor(rot * 8.0 + 0.5)
        syq  = math.floor(scale_y * hf * hs * 128.0 + 0.5)
        aq   = math.floor(a * 64.0 + 0.5)
        rq   = math.floor(r * 64.0 + 0.5)
    end

    if syq ~= shadow._last_syq then
        shadow._last_syq = syq
        shadow.Transform:SetScale(hs, scale_y * hf * hs, hs)
    end
    if rotq ~= shadow._last_rotq then
        shadow._last_rotq = rotq
        shadow.Transform:SetRotation(rot)
    end
    if aq <= 0 then
        if shadow._last_a ~= 0 then
            shadow._last_a = 0
            shadow._last_aq = 0
            sa:SetMultColour(0, 0, 0, 0)
        end
        return
    end
    if aq ~= shadow._last_aq or rq ~= shadow._last_rq then
        shadow._last_aq, shadow._last_rq = aq, rq
        shadow._last_a, shadow._last_r = a, r
        sa:SetMultColour(r, g, b, a)
    end
end

-- 事件监听一次性绑定：closure 动态读 ent._bcas_shadow。影子会随实体
-- sleep 休眠销毁、wake 重建（性能边界），静态注册会导致监听器随
-- 挂载循环无限累积（每次 attach 加一组）。绑定与挂载解耦：远距静态
-- 被距离门挡掉时也已绑定，实体唤醒（玩家靠近）时由 wake 分支补挂。
local function BindShadowListeners(ent)
    if ent._bcas_bound == true then return end
    ent._bcas_bound = true

    local function drop_bound()
        local sh = ent._bcas_shadow
        if sh ~= nil then
            dynamic_shadows[sh] = nil
            static_shadows[sh] = nil
            if sh:IsValid() then
                sh:Remove()
            end
            ent._bcas_shadow = nil
        end
    end
    ent:ListenForEvent("onremove", drop_bound)

    -- 休眠（远离玩家）即弃影子、还原本体原生投影；唤醒时再补挂。
    -- 影子实体数量被压到玩家周边活跃实体规模。玩家实体从不 sleep，
    -- 此分支天然只命中树/建筑/生物。
    ent:ListenForEvent("entitysleep", function()
        if ent:IsValid() and not ent:HasTag("player") then
            drop_bound()
            if ent.DynamicShadow ~= nil then
                pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, true)
            end
        end
    end)

    local function sync_now()
        if not ent:IsValid() then return end
        local sh = ent._bcas_shadow
        if sh == nil or not sh:IsValid() then return end
        if ParentHidden(ent) then
            sh:Hide()
            return
        end
        sh:Show()
        -- 事件驱动的强制重同步：清装备扫描节流计数，5 帧内立刻全量重涂
        sh._equip_counter = 0
        CopyAnim(ent.AnimState, sh.AnimState, sh, true, ent)
        ent:DoTaskInTime(0, function()
            if ent:IsValid() then
                local sh2 = ent._bcas_shadow
                if sh2 ~= nil and sh2:IsValid() then
                    sh2._equip_counter = 0
                    CopyAnim(ent.AnimState, sh2.AnimState, sh2, true, ent)
                end
            end
        end)
    end
    ent:ListenForEvent("picked", sync_now)
    ent:ListenForEvent("worked", sync_now)
    ent:ListenForEvent("workfinished", sync_now)
    ent:ListenForEvent("harvested", sync_now)
    ent:ListenForEvent("onignite", sync_now)
    ent:ListenForEvent("onextinguish", sync_now)
    -- NO animover/animqueueover listeners: they fire after every sub-clip and
    -- force-restarted clips (rabbit walk replays). Frame scrubbing in the
    -- scheduler already keeps motion in sync; newstate covers clip switches.
    ent:ListenForEvent("newstate", sync_now)
    if ent:HasTag("player") then
        -- Equipment / skin changes: force a full re-mirror (SetBuild wipes
        -- overrides, so the splat must re-apply swap symbols after any
        -- wardrobe/equip change; unequip must clear the old swap).
        -- _diag_next：只对装备类事件开一轮探针（临时诊断，发布前移除）。
        local function sync_now_diag()
            local sh = ent._bcas_shadow
            if sh ~= nil and sh:IsValid() then sh._diag_next = true end
            sync_now()
        end
        ent:ListenForEvent("equip", sync_now_diag)
        ent:ListenForEvent("unequip", sync_now_diag)
        ent:ListenForEvent("ms_playerchangeclothing", sync_now_diag)
        ent:ListenForEvent("skinmaxchanged", sync_now)
    end

    -- Wake: no shadow -> (re)attach; tree shadow -> phase lock via
    -- CopyFrame only (replays here were the old wake-resync hitch);
    -- everything else -> force re-copy.
    ent:ListenForEvent("entitywake", function()
        if not ent:IsValid() then return end
        if ent:HasTag("player") then return end
        local sh = ent._bcas_shadow
        if sh == nil or not sh:IsValid() then
            SunSystem.AttachShadowToEntity(ent)
            return
        end
        if ent:HasTag("tree") then
            CopyFrame(ent.AnimState, sh.AnimState, sh, false)
        else
            sh:Show()
            CopyAnim(ent.AnimState, sh.AnimState, sh, true, ent)
        end
    end)
end

function SunSystem.AttachShadowToEntity(ent)
    if not master_enabled or not shadows_enabled then
        return
    end
    if not ShouldHaveShadow(ent) then
        return
    end
    local W = _G.TheWorld
    if W and W:HasTag("cave") then
        return
    end
    if ent._bcas_shadow ~= nil then
        if ent._bcas_shadow:IsValid() then
            return
        end
        ent._bcas_shadow = nil
    end
    BindShadowListeners(ent)
    -- 影子是纯客户端视觉实体：dedicated 服务端（ThePlayer == nil）不创建、
    -- 不调度，服务端零实体零开销。各客户端各自为可视范围创建本地剪影。
    local ThePlayer = _G.ThePlayer
    if ThePlayer == nil then
        return
    end
    local is_player = ent:HasTag("player")
    local is_mover = is_player or IsMover(ent)
    -- 远距静态先不挂：树/建筑此刻 asleep，实体唤醒（玩家靠近）时由一次性
    -- wake 监听补挂，static_shadows 从全图规模压到玩家周边规模。
    if not is_mover and ThePlayer:IsValid() and ThePlayer.Transform ~= nil
        and ent.Transform ~= nil then
        local ex, _, ez = ent.Transform:GetWorldPosition()
        local px, _, pz = ThePlayer.Transform:GetWorldPosition()
        local dx, dz = ex - px, ez - pz
        if dx * dx + dz * dz > STATIC_HIDE_SQ * 4 then
            return
        end
    end

    if ent.DynamicShadow ~= nil then
        pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, false)
    end

    local shadow = CreateEntity()
    shadow.entity:AddTransform()
    shadow.entity:AddAnimState()
    -- NEVER sleep: a sleeping splat freezes mid-sway and stutters when it
    -- wakes. Shadows are cheap; waking trees re-freeze them every crossing.
    shadow.entity:SetCanSleep(false)
    shadow.persists = false
    shadow._isshadow = true
    shadow._is_player = is_player
    shadow._is_mover = is_mover
    shadow._prefab = ent.prefab
    local prefab = ent.prefab or ""
    shadow._is_birch = ent:HasTag("deciduoustree") or ent:HasTag("birchnut")
        or (type(prefab) == "string" and string.find(prefab, "deciduous", 1, true) ~= nil)
    shadow._is_twiggy = ent:HasTag("twiggytree")
        or (type(prefab) == "string" and string.find(prefab, "twiggy", 1, true) ~= nil)
    local hf = HEIGHT_SCALES[ent.prefab]
    if hf == nil then
        if is_mover then
            hf = 1.0
        elseif ent:HasTag("tree") then
            hf = 1.0
        elseif ent:HasTag("structure") then
            hf = 0.85
        else
            hf = 0.55
        end
    end
    shadow._height_factor = hf
    shadow._budget_offset = math.random(0, 7)
    shadow._last_flip = nil

    shadow.AnimState:SetMultColour(0, 0, 0, 0)
    shadow.AnimState:SetManualBB(0, 0, 0, 0)
    shadow.AnimState:UsePointFiltering(true)
    shadow.AnimState:SetLayer(LAYER_BACKGROUND)
    shadow.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    pcall(shadow.AnimState.Hide, shadow.AnimState, "mouseover")
    if is_mover then
        shadow.Transform:SetNoFaced()
    else
        shadow.Transform:SetEightFaced()
        shadow.entity:SetParent(ent.entity)
    end

    shadow:AddTag("FX")
    shadow:AddTag("NOBLOCK")
    shadow:AddTag("DECOR")
    shadow:AddTag("NOCLICK")

    ent._bcas_shadow = shadow
    shadow._parent_ent = ent

    -- 挂载即首次全量同步：bank/build/皮肤 build/装备 override/当前 clip
    CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
    if shadow._is_birch or shadow._is_twiggy then
        ent:DoTaskInTime(0.3, function()
            if ent:IsValid() and shadow:IsValid() then
                CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
            end
        end)
    end

    local scale_y, rot, a, r, g, b = GetSunParams()
    ApplyPose(shadow, ent, scale_y, rot, r, g, b, a, is_mover)
    shadow.AnimState:SetMultColour(r, g, b, a)
    shadow._last_a = a

    if is_mover then
        dynamic_shadows[shadow] = ent
    else
        static_shadows[shadow] = ent
    end
end

-- ---------------------------------------------------------------------------
-- Oasis / hotspring style water: native tile + cyan Light + light-override
-- (no extra mesh overlay -- that is what made ponds look dirty)
-- ---------------------------------------------------------------------------

function SunSystem.AttachWaterFX(ent)
    if ent == nil or not ent:IsValid() or ent.Transform == nil then return end
    if not WATER_PREFABS[ent.prefab] then return end
    if ent.prefab == "lava_pond" then return end
    if ent._bcas_water then return end
    ent._bcas_water = true

    local as = ent.AnimState
    if as and as.SetLightOverride then
        as:SetLightOverride(ent.prefab == "hotspring" and 0.55 or 0.32)
    end
    if ent.prefab == "hotspring" and as and as.SetBloomEffectHandle then
        pcall(as.SetBloomEffectHandle, as, "shaders/anim.ksh")
    end

    local radius = (ent.prefab == "oasislake" and 7.5)
        or (ent.prefab == "hotspring" and 3.4) or 2.2
    if ent.Light == nil then
        pcall(function() ent.entity:AddLight() end)
    end
    if ent.Light == nil then
        return
    end
    if ent.prefab == "hotspring" then
        ent.Light:SetColour(0.12, 1.35, 1.7)
        ent.Light:SetIntensity(0.55)
        ent.Light:SetFalloff(0.65)
        ent.Light:SetRadius(radius)
    else
        ent.Light:SetColour(0.20, 0.90, 1.05)
        ent.Light:SetIntensity(0.42)
        ent.Light:SetFalloff(0.72)
        ent.Light:SetRadius(radius)
    end
    ent.Light:Enable(ocean_enabled)
    water_fx[ent] = true
end

-- ---------------------------------------------------------------------------
-- Cloud-break shafts: ground patches + engine Light (occluder rims for free)
-- ---------------------------------------------------------------------------

local SHAFT_COUNT = 3

-- GROUND ids (constants.lua): ROAD=2, SAVANNA=5, GRASS=6, DESERT_DIRT=31.
-- These palettes sit near-white under sun; shaft Light + patch stack on
-- them clipped to pure white (user report). Halve the shaft on these only.
local BRIGHT_GROUND_TILES = {
    [2] = true, [5] = true, [6] = true, [31] = true,
}

local function SunDirXZ()
    local scale_y, rot = GetSunParams()
    local rad = (rot + 180) * DEGREES
    return math.sin(rad), math.cos(rad), rot, scale_y
end

local function ShowRandomRays(inst)
    for i = 1, 11 do
        inst.AnimState:Hide("lightray" .. i)
    end
    local pool = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
    local n = math.random(2, 3)
    for _i = 1, n do
        local k = math.random(1, #pool)
        inst.AnimState:Show("lightray" .. pool[k])
        table.remove(pool, k)
    end
end

local function MakeShaft()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddLight()
    inst.persists = false
    inst:AddTag("FX")
    inst:AddTag("NOBLOCK")
    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")
    inst:AddTag("lightrays")
    inst.Transform:SetNoFaced()
    inst.AnimState:SetBank("lightrays")
    inst.AnimState:SetBuild("lightrays")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:SetMultColour(1.0, 0.94, 0.84, 0.0)
    if inst.AnimState.SetLightOverride then
        inst.AnimState:SetLightOverride(0.25)
    end
    ShowRandomRays(inst)
    inst.Light:SetRadius(8)
    inst.Light:SetIntensity(0.0)
    inst.Light:SetFalloff(0.7)
    inst.Light:SetColour(1.0, 0.93, 0.80)
    inst.Light:Enable(false)
    inst._tx, inst._tz = nil, nil
    inst._life = math.random() * 20
    inst._hold = 4 + math.random() * 5
    inst._gap = 8 + math.random() * 16
    inst._phase = "gap"
    inst._alpha = 0
    inst._vis = 0
    return inst
end

local function PickShaftPos(player, sx, sz)
    local px, py, pz = player.Transform:GetWorldPosition()
    local dist = 8 + math.random() * 16
    local side = (math.random() - 0.5) * 20
    local x = px + sx * dist + sz * side
    local z = pz + sz * dist - sx * side
    local map = _G.TheWorld and _G.TheWorld.Map
    if map ~= nil then
        if map.IsOceanAtPoint and map:IsOceanAtPoint(x, 0, z, false) then
            return nil, nil
        end
        if map.GetTileCenterPoint then
            local ok, wx, wz = pcall(function()
                local tx, tz = map:GetTileCoordsAtPoint(x, 0, z)
                local cx, cy, cz = map:GetTileCenterPoint(tx, tz)
                return cx, cz
            end)
            if ok and wx then
                x, z = wx, wz
            end
        end
    end
    return x, z
end

local function ApplyShaftVisual(e, vis, rot)
    e._vis = vis
    -- 亮地块压制系数更严格：防止浅色麦田/草地/白地块反光过曝
    local damp = e._bright_tile and 0.30 or 0.65
    if vis <= 0.01 then
        e:Hide()
        e.Light:Enable(false)
        e.AnimState:SetMultColour(1.0, 0.94, 0.84, 0)
        return
    end
    e:Show()
    e.Transform:SetRotation(rot or 0)
    -- 光柱本身整体降低透明度（0.45 -> 0.28），颜色加深为温暖琥珀金，拒绝惨白！
    e.AnimState:SetMultColour(1.05, 0.90, 0.70, 0.28 * vis * damp)
    -- 额外附加点光源亮度大幅下调（0.30 -> 0.15），彻底消除和本体光晕“左脚踩右脚”的过度叠加！
    e.Light:SetIntensity(0.15 * vis * damp)
    e.Light:SetColour(255 / 255, 220 / 255, 160 / 255) -- 纯粹柔和暖金光
    e.Light:SetRadius(3 + 4 * vis)
    e.Light:Enable(true)
end

local function UpdateShafts(dt)
    local player = _G.ThePlayer
    local W = _G.TheWorld
    dt = dt or (1 / 30)
    if player == nil or not player:IsValid() or W == nil or W:HasTag("cave") then
        for i = 1, #shaft_ents do
            local e = shaft_ents[i]
            if e and e:IsValid() then
                ApplyShaftVisual(e, 0, 0)
            end
        end
        return
    end
    local scale_y, rot, a = GetSunParams()
    local amount = shafts_amount * (a / 0.55)
    if amount < 0.02 or a <= 0.01 then
        for i = 1, #shaft_ents do
            local e = shaft_ents[i]
            if e and e:IsValid() then
                ApplyShaftVisual(e, 0, rot)
            end
        end
        return
    end
    local sx, sz = SunDirXZ()
    for i = 1, #shaft_ents do
        local e = shaft_ents[i]
        if e and e:IsValid() then
            e._life = (e._life or 0) + dt
            local phase = e._phase or "gap"
            if phase == "gap" then
                if e._life >= (e._gap or 10) then
                    local tx, tz = PickShaftPos(player, sx, sz)
                    if tx ~= nil then
                        e._tx, e._tz = tx, tz
                        e.Transform:SetPosition(tx, 0, tz)
                        -- Bright-tile probe at spawn (Map:GetTileAtPoint):
                        -- savanna/grass/road/desert read as bright palettes
                        -- and clip under the patch + Light stack.
                        local map = W.Map
                        e._bright_tile = false
                        if map ~= nil and map.GetTileAtPoint ~= nil then
                            local ok, tile = pcall(map.GetTileAtPoint, map, tx, 0, tz)
                            if ok and tile ~= nil and BRIGHT_GROUND_TILES[tile] then
                                e._bright_tile = true
                            end
                        end
                        ShowRandomRays(e)
                        e._phase = "in"
                        e._life = 0
                        e._hold = 3.5 + math.random() * 4.5
                    else
                        e._life = 0
                    end
                end
                ApplyShaftVisual(e, 0, rot)
            elseif phase == "in" then
                local vis = math.min(1, e._life / 2.4) * math.min(1, amount)
                if e._tx then
                    e.Transform:SetPosition(e._tx, 0, e._tz)
                end
                ApplyShaftVisual(e, vis, rot)
                if e._life >= 2.4 then
                    e._phase = "hold"
                    e._life = 0
                end
            elseif phase == "hold" then
                -- 彻底关闭太阳光柱的呼吸晃动！锁定恒定沉稳光照，杜绝忽明忽暗像呼吸灯！
                local vis = math.min(1, amount)
                if e._tx then
                    e.Transform:SetPosition(e._tx, 0, e._tz)
                end
                ApplyShaftVisual(e, vis, rot)
                if e._life >= (e._hold or 4) then
                    e._phase = "out"
                    e._life = 0
                end
            else
                local vis = (1 - math.min(1, e._life / 2.8)) * math.min(1, amount)
                ApplyShaftVisual(e, vis, rot)
                if e._life >= 2.8 then
                    e._phase = "gap"
                    e._life = 0
                    e._gap = 10 + math.random() * 22
                    e._tx, e._tz = nil, nil
                end
            end
        end
    end
end

local function EnsureShafts()
    if #shaft_ents > 0 then return end
    for i = 1, SHAFT_COUNT do
        shaft_ents[i] = MakeShaft()
    end
end


-- ---------------------------------------------------------------------------
-- Schedulers
-- ---------------------------------------------------------------------------

local scheduler_started = false
local function StartGlobalScheduler()
    local W = _G.TheWorld
    if W == nil or scheduler_started then return end
    scheduler_started = true
    local tick = 0
    EnsureShafts()

    W:DoPeriodicTask(0, function()
        if not master_enabled or not shadows_enabled then
            return
        end
        tick = tick + 1
        local scale_y, rot, a, r, g, b = GetSunParams()
        local player = _G.ThePlayer
        local ppx, ppy, ppz = 0, 0, 0
        if player and player:IsValid() and player.Transform then
            ppx, ppy, ppz = player.Transform:GetWorldPosition()
        end

        nearby_movers = 0
        local mover_budget = 1
        if nearby_movers_last > 80 then mover_budget = 4
        elseif nearby_movers_last > 40 then mover_budget = 2 end

        for shadow, ent in pairs(dynamic_shadows) do
            if ent:IsValid() and shadow:IsValid() then
                if not shadows_enabled or a <= 0.01 or (not shadow._is_player and ParentHidden(ent)) then
                    shadow:Hide()
                else
                    local px, py, pz = ent.Transform:GetWorldPosition()
                    local dist_sq = (px - ppx) * (px - ppx) + (pz - ppz) * (pz - ppz)
                    if dist_sq > FAR_SQ and not shadow._is_player then
                        shadow:Hide()
                    else
                        shadow:Show()
                        if dist_sq <= NEAR_SQ or shadow._is_player then
                            nearby_movers = nearby_movers + 1
                        end
                        -- 原生投影只在挂载/休眠两个时机切换，逐帧 pcall
                        -- Enable(false) 是 30Hz×N 实体的纯浪费。

                        -- Player + nearby movers: full anim name+percent every tick.
                        -- Far crowd: percent only, name on budget. Idle snap never skipped
                        -- for the local player / mount.
                        -- Always detect clip changes (idle <-> run). Budget only
                        -- skips CopyFrame seeks, never the clip switch itself.
                        if shadow._is_player then
                            local rider = ent.replica and ent.replica.rider
                            local riding = rider and rider.IsRiding and rider:IsRiding()
                            if riding then
                                local mount = rider.GetMount and rider:GetMount()
                                if mount and mount:IsValid() then
                                    if mount._bcas_shadow and mount._bcas_shadow:IsValid() then
                                        mount._bcas_shadow:Hide()
                                    end
                                    -- Rider visual is bank wilsonbeefalo + beefalo
                                    -- override build. CopyAnim may still see the
                                    -- wilson bank if replica lags; force it here.
                                    local sa = shadow.AnimState
                                    shadow._lock_bank = "wilsonbeefalo"
                                    if sa and shadow._last_bank ~= "wilsonbeefalo" then
                                        sa:SetBank("wilsonbeefalo")
                                        shadow._last_bank = "wilsonbeefalo"
                                        shadow._last_anim_name = nil
                                        shadow._last_anim = nil
                                    end
                                    if mount.AnimState and mount.AnimState.GetBuild then
                                        local m_build = mount.AnimState:GetBuild()
                                        if m_build and m_build ~= shadow._last_mount_build then
                                            if shadow._last_mount_build then
                                                pcall(sa.ClearOverrideBuild, sa, shadow._last_mount_build)
                                            end
                                            pcall(sa.AddOverrideBuild, sa, m_build)
                                            shadow._last_mount_build = m_build
                                        end
                                    end
                                end
                                shadow._height_factor = 1.2
                            else
                                shadow._height_factor = 1.0
                                if shadow._last_mount_build and shadow.AnimState then
                                    pcall(shadow.AnimState.ClearOverrideBuild, shadow.AnimState, shadow._last_mount_build)
                                    shadow._last_mount_build = nil
                                end
                                shadow._lock_bank = nil
                                if shadow._last_bank == "wilsonbeefalo" then
                                    shadow._last_bank = nil
                                    shadow._last_anim_name = nil
                                    shadow._last_anim = nil
                                end
                            end
                        end
                        -- 远处群体按 mover_budget 节流 CopyAnim（引擎读回贵）：
                        -- 近处与玩家逐帧；拥挤时（mover_budget=2/4）远的每
                        -- 2/4 帧一次。姿态仍逐帧（ApplyPose 已量化）、位置
                        -- 跟随不停，视觉无差。
                        local is_far = (not shadow._is_player) and dist_sq > NEAR_SQ
                        if (not is_far)
                            or ((tick + (shadow._budget_offset or 0)) % mover_budget == 0) then
                            CopyAnim(ent.AnimState, shadow.AnimState, shadow, false, ent)
                        end

                        ApplyPose(shadow, ent, scale_y, rot, r, g, b, a, true)
                    end
                end
            else
                dynamic_shadows[shadow] = nil
                -- 父实体已失效（被移除/换 prefab）：影子实体一并销毁，
                -- 否则残留一具"砍了还在"的鬼影。
                if shadow:IsValid() then shadow:Remove() end
            end
        end

        -- 静态影子姿态逐帧扫描（树、草、浆果、建筑）。太阳转动约 1.2 度/秒，
        -- 旧版 0.5s 一跳在长树影的末端是肉眼可见的顿挫；逐帧后与移动实体
        -- 一样连续。开销受控：只扫 0.5s 任务重建的近距花名册（≤46u），
        -- 远档每 3 帧一次（0.077 度/步，不可感知），夜间/关闭直接跳过。
        if shadows_enabled and a > 0.01 and roster_n > 0 then
            for i = 1, roster_n do
                local shadow = static_roster[i]
                if shadow:IsValid() then
                    local ent = shadow._parent_ent
                    if ent ~= nil and ent:IsValid() then
                        local do_pose = not shadow._roster_far
                            or (tick + (shadow._budget_offset or 0)) % 3 == 0
                        if do_pose then
                            -- 近距逐帧检测源剪辑/构建变化：砍树 / 采集 / 燃烧
                            -- 这类即时反应不再等 0.5s 轮询（"砍了好一会影子才晃"）。
                            if not shadow._roster_far then
                                local pa = ent.AnimState
                                local sa3 = shadow.AnimState
                                if pa ~= nil and sa3 ~= nil
                                    and pa.GetCurrentAnimationHash ~= nil
                                    and sa3.GetCurrentAnimationHash ~= nil then
                                    if pa:GetCurrentAnimationHash() ~= sa3:GetCurrentAnimationHash()
                                        or (pa.GetBuild ~= nil and sa3.GetBuild ~= nil
                                            and pa:GetBuild() ~= sa3:GetBuild()) then
                                        CopyAnim(pa, sa3, shadow, false, ent)
                                    end
                                end
                            end
                            ApplyPose(shadow, ent, scale_y, rot, r, g, b, a, false)
                        end
                    end
                end
            end
        end

        nearby_movers_last = nearby_movers
        if tick % 2 == 0 then
            UpdateShafts(2 / 30)
        end
    end)

    local static_tick = 0
    W:DoPeriodicTask(0.5, function()
        if not master_enabled or not shadows_enabled then
            return
        end
        static_tick = static_tick + 1
        local _scale_y, _rot, a = GetSunParams()
        local player = _G.ThePlayer
        local ppx, ppz = 0, 0
        if player and player:IsValid() and player.Transform then
            local px_, py_, pz_ = player.Transform:GetWorldPosition()
            ppx, ppz = px_, pz_
        end
        roster_n = 0
        for shadow, ent in pairs(static_shadows) do
            if ent:IsValid() and shadow:IsValid() then
                if not shadows_enabled or ParentHidden(ent) or a <= 0.01 then
                    shadow:Hide()
                else
                    local px, py, pz = ent.Transform:GetWorldPosition()
                    local dist_sq = (px - ppx) * (px - ppx) + (pz - ppz) * (pz - ppz)
                    if dist_sq > STATIC_HIDE_SQ then
                        shadow:Hide()
                    else
                        shadow:Show()
                        -- Pose is swept every frame in the frame-tied
                        -- scheduler below; this task only maintains the
                        -- roster (near = every frame, far = 1/3 of frames).
                        shadow._roster_far = dist_sq > STATIC_MID_SQ
                        roster_n = roster_n + 1
                        static_roster[roster_n] = shadow
                        -- Tree splats: detect CLIP SWITCHES and STAGE BUILDS
                        -- only. IsCurrentAnimation/GetBuild are cheap compares;
                        -- the splat free-runs the same clip in phase after the
                        -- initial lock, so no per-tick frame scrubbing --
                        -- scrubbing every 0.5s was what made tree shadows
                        -- visibly tick between sway poses (like dragging a
                        -- scrub bar) while grass/saplings stayed smooth.
                        -- Build compare keeps growth stages in sync (short ->
                        -- tall keeps the same clip name on some trees, so a
                        -- clip-only check would strand the splat on the old
                        -- stage); the 1.5s anti-flap gate inside CopyAnim
                        -- caps the old stage-flicker failure mode.
                        -- 复发检测对所有静态影子（不只树）：草/树枝/浆果被
                        -- 采集→枯萎→再生 会换 clip（picked/withered 不在 mover
                        -- 表里，靠 CopyAnim 的 hash 回放分支镜像）或换 build；
                        -- 树也会换阶段 build。只比 hash/build（廉价），变了才
                        -- CopyAnim。此前只有 tree 分支做这件事，所以植物被采后
                        -- 影子永远停在枝繁叶茂态（历史遗留 bug）。
                        local pa = ent.AnimState
                        local sa2 = shadow.AnimState
                        -- 自纠正：直接比"影子当前动画哈希"与"源当前动画哈希"
                        -- （不再依赖缓存字段，PlayAnimation 没生效时下一轮自动重试）
                        local hash_diff = pa.GetCurrentAnimationHash ~= nil
                            and sa2.GetCurrentAnimationHash ~= nil
                            and pa:GetCurrentAnimationHash() ~= sa2:GetCurrentAnimationHash()
                        local build_changed = pa.GetBuild ~= nil
                            and pa:GetBuild() ~= shadow._last_build
                        if hash_diff or build_changed then
                            CopyAnim(pa, sa2, shadow, false, ent)
                        elseif (static_tick + shadow._budget_offset) % 8 == 0 then
                            -- Gentle 4s drift re-lock (single SetFrame, no replay)
                            CopyFrame(pa, sa2, shadow, false)
                        end
                        if shadow._is_birch
                            and (static_tick + shadow._budget_offset) % 16 == 0 then
                            CopyLeaves(ent.AnimState, shadow.AnimState, shadow, false)
                        end
                    end
                end
            else
                static_shadows[shadow] = nil
                -- 同上：砍掉的树/被铲植物，父实体没了就销毁影子实体
                if shadow:IsValid() then shadow:Remove() end
            end
        end
        for i = roster_n + 1, #static_roster do
            static_roster[i] = nil
        end
        for ent, _flag in pairs(water_fx) do
            if ent:IsValid() and ent.Light then
                ent.Light:Enable(ocean_enabled and not ParentHidden(ent))
            else
                water_fx[ent] = nil
            end
        end
    end)
end

local native_shadow_hooked = false

-- 全局压死引擎原生投影：原生影子是「暗化实体」、会带出实体的描边轮廓，和我们
-- 的纯色剪影叠在一起很难看。我们的剪影生效期间（master + shadows 均开）一律把
-- 原生 Enable 改成 false；关闭我们的投影时自动放行，原生恢复。
local function HookNativeShadow()
    if native_shadow_hooked then return end
    local DS = _G.DynamicShadow
    if type(DS) ~= "table" or type(DS.Enable) ~= "function" then
        print("[BCAS] 警告：DynamicShadow 结构异常，原生投影只能逐实体关闭")
        return
    end
    local orig = DS.Enable
    DS.Enable = function(self, enabled)
        if master_enabled and shadows_enabled then
            enabled = false
        end
        return orig(self, enabled)
    end
    native_shadow_hooked = true
    print("[BCAS] 已接管原生投影（自定义剪影期间 DynamicShadow 恒关）")
end

function SunSystem.Init()
    HookNativeShadow()
    StartGlobalScheduler()
end

function SunSystem.SetMasterEnabled(enabled)
    enabled = enabled == true
    if master_enabled == enabled then return end  -- 翻转守卫：幂等调用零成本
    master_enabled = enabled
    if not master_enabled then
        DropAllShadowEntities()
    else
        RescanAttachAll()
    end
end

function SunSystem.IsMasterEnabled()
    return master_enabled
end

function SunSystem.SetShadowsEnabled(enabled)
    shadows_enabled = enabled == true
    if not shadows_enabled or not master_enabled then
        for shadow, ent in pairs(dynamic_shadows) do
            if shadow:IsValid() then shadow:Hide() end
            if ent and ent:IsValid() and ent.DynamicShadow ~= nil then
                pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, true)
            end
        end
        for shadow, _ent in pairs(static_shadows) do
            if shadow:IsValid() then shadow:Hide() end
        end
        for i = 1, #shaft_ents do
            local e = shaft_ents[i]
            if e and e:IsValid() then
                e:Hide()
                if e.Light then e.Light:Enable(false) end
            end
        end
    end
end

function SunSystem.SetOceanEnabled(enabled)
    ocean_enabled = enabled == true
    -- v3.6 定版：水面 = 地皮调色（世界生成烘焙）+ 原版渲染，无运行时覆盖。
    -- OceanOn 只切换地皮定义，重进世界重烘焙后生效（UI 第 7 页已注明）。
    local OceanLook = _G.package.loaded["bcas_ocean"]
    if OceanLook ~= nil and OceanLook.Apply ~= nil then
        OceanLook.Apply(ocean_enabled)
    end
    for ent, _flag in pairs(water_fx) do
        if ent:IsValid() and ent.Light then
            ent.Light:Enable(ocean_enabled)
        end
        if ent:IsValid() and ent.AnimState and ent.AnimState.SetLightOverride then
            ent.AnimState:SetLightOverride(ocean_enabled and 0.32 or 0)
        end
    end
end

-- 0..1: how strong sunlight is right now (0 at night / cave).
function SunSystem.GetDayFactor()
    local _scale_y, _rot, a = GetSunParams()
    local f = a / 0.55
    if f > 1 then f = 1 end
    if f < 0 then f = 0 end
    return f
end

function SunSystem.SetShaftsAmount(amount)
    shafts_amount = amount or 0
    if shafts_amount < 0.02 then
        for i = 1, #shaft_ents do
            local e = shaft_ents[i]
            if e and e:IsValid() then
                e:Hide()
                e.Light:Enable(false)
            end
        end
    end
end

return {
    Attach = function(player) SunSystem.AttachShadowToEntity(player) end,
    AttachEntity = SunSystem.AttachShadowToEntity,
    AttachWater = SunSystem.AttachWaterFX,
    Init = SunSystem.Init,
    GetSunScreenUV = SunSystem.GetSunScreenUV,
    -- 日晷参数原始值（scale_y=影长, rot=影子方向）：海面折射组件据此推
    -- 太阳方位/仰角，波光永远与地面投影同源
    GetSunParams = GetSunParams,
    IsMover = IsMover,
    ShouldHaveShadow = ShouldHaveShadow,
    SetMasterEnabled = SunSystem.SetMasterEnabled,
    IsMasterEnabled = SunSystem.IsMasterEnabled,
    SetShadowsEnabled = SunSystem.SetShadowsEnabled,
    SetOceanEnabled = SunSystem.SetOceanEnabled,
    SetShaftsAmount = SunSystem.SetShaftsAmount,
    GetDayFactor = SunSystem.GetDayFactor,
}
