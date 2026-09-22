--[[
    BCAS Studio -- sun dial, water sparkle, cloud-break shafts.

    Sun dial:
      * Gnomon model (day/dusk/moon) -> (shadow length, shadow direction,
        density, moon tint). Never camera heading.
      * GetSunParams() is the single source every consumer shares: the surface
        light (bcas_surface_light), the sky/grade uniforms (BCAS_EXTRA) and the
        shafts all read the same numbers, so direction/tint never drift apart
        between systems.

    Shadows (v11): NOT drawn here at all. v10 的屏幕空间高度场/光线步进已整体
      删除（见 docs/SHADOW_V11_PLAN.md §6）；实体立体光照在 bcas_surface_light，
      哑元投影在阶段二。引擎自带的软块阴影（DynamicShadow）现在**保留**当兜底，
      不再强制关闭。

    Water: oasis-style OnGround sparkle + cheap cyan Light. No ocean shader replace.

    Shafts: world-space ground patches + engine Light (real occluder rim).
      Positions drift like cloud breaks. Not a screen-space streak.
]]

local _G = rawget(_G, "GLOBAL") or _G
local CreateEntity = _G.CreateEntity
local DEGREES = _G.DEGREES or (math.pi / 180)
local SunSystem = {}

local shadows_enabled = true
local ocean_enabled = true
local shafts_amount = 1.0
local master_enabled = true

-- 日晷参数（影长 0.8~2.4 与浓度 0.50/0.38）：
-- 影长系数 scale_y = 1/tan(太阳高度角)，正午最短（0.8）日出日落最长（2.4）。
local SHADOW_MAX_LENGTH = 2.4
local SHADOW_MIN_LENGTH = 0.8
local SHADOW_MAX_ALPHA = 0.50
local SHADOW_MOON_ALPHA = 0.38
local SHADOW_TINT_DAY   = { 0.040, 0.055, 0.095 }
local SHADOW_TINT_DUSK  = { 0.070, 0.050, 0.060 }
local SHADOW_TINT_MOON  = { 0.050, 0.070, 0.130 }

local TWICE_MAX = 2.0 * SHADOW_MAX_LENGTH
local DUSK_HYPOT = math.sqrt(SHADOW_MAX_LENGTH * SHADOW_MAX_LENGTH
    + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
local DUSK_ROTATION = math.deg(math.atan(SHADOW_MAX_LENGTH / SHADOW_MIN_LENGTH))
local FADE = 10 / 480

local WATER_PREFABS = {
    hotspring = true,
}

local water_fx = {}
local shaft_ents = {}

local _cache = { scale_y = 1.5, rot = 45, a = 0.65, r = 0, g = 0, b = 0, key = nil }


-- ---------------------------------------------------------------------------
-- Gnomon sun model: TheWorld.state -> (shadow length, direction, density, tint)
-- ---------------------------------------------------------------------------
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
            a = SHADOW_MAX_ALPHA * math.min(1, time / FADE)
            r, g, b = SHADOW_TINT_DAY[1], SHADOW_TINT_DAY[2], SHADOW_TINT_DAY[3]
        elseif phase == "dusk" then
            scale_y = DUSK_HYPOT
            rot = DUSK_ROTATION
            a = SHADOW_MAX_ALPHA * (1 - progress)
            r, g, b = SHADOW_TINT_DUSK[1], SHADOW_TINT_DUSK[2], SHADOW_TINT_DUSK[3]
        elseif phase == "night" and moon == 1 then
            local leg1 = TWICE_MAX * (progress - 0.5)
            scale_y = math.sqrt(leg1 * leg1 + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
            rot = math.deg(math.atan(leg1 / SHADOW_MIN_LENGTH))
            a = SHADOW_MOON_ALPHA * math.min(1, progress / FADE)
            -- 满月也是"月光色"而不是纯黑（剪影按乘性合成，冷色更自然）。
            r, g, b = SHADOW_TINT_MOON[1], SHADOW_TINT_MOON[2], SHADOW_TINT_MOON[3]
        end
        -- 季节/天气只压一点点：浓度掉得太多，影子的"落地感"就没了。
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

local function ParentHidden(ent)
    if not ent:IsValid() then return true end
    if ent:HasTag("INLIMBO") then return true end
    if ent.IsInLimbo and ent:IsInLimbo() then return true end
    -- 直接 pcall(f, e)：闭包版本每次调用都新建一个闭包，逐帧 × N 实体
    -- 是持续 GC 压力。传函数+参数不分配闭包，行为一致。
    local e = ent.entity
    local f = e ~= nil and e.IsVisible or nil
    if f == nil then return false end
    local ok, vis = pcall(f, e)
    return ok and vis == false
end


-- ---------------------------------------------------------------------------
-- Oasis / hotspring style water: native tile + cyan Light + light-override
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
    -- 这是我们**自己挂的装饰光**（温泉/绿洲湖的水色辉光），不是玩家感知里的"光源"。
    -- 影子模块按"最强点光源"投夜间长影，这种青色光算出来的权重很高
    -- （0.30·R + 0.60·G + 0.10·B ≈ 1.0，再乘 LIGHT_GAIN 1.6），半径又大 ⇒ 会把
    -- 影子拽向一片看不见的青光（"影子莫名其妙指着某个方向"的成因之一）。
    -- 标记用**我们自己的字段**（不是标签：标签要进引擎标签表，字段只在 Lua 侧）。
    ent._bcas_decor_light = true
    water_fx[ent] = true
end

-- ---------------------------------------------------------------------------
-- Cloud-break shafts: ground patches + engine Light (occluder rims for free)
-- ---------------------------------------------------------------------------

local SHAFT_COUNT = 4

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
    inst._gap = 3 + math.random() * 7
    inst._phase = "gap"
    inst._alpha = 0
    inst._vis = 0
    -- 每条光柱有自己的基准尺寸（0.8~1.5），再加上出现/消散过程的缩放，
    -- 不再是"一小束固定大小的光"。
    inst._scale = 0.8 + math.random() * 0.7
    return inst
end

local function PickShaftPos(player, sx, sz)
    local px, py, pz = player.Transform:GetWorldPosition()
    -- 出生距离收紧到 3~14 格、横向 ±7：之前 8~24 的远位在镜头拉近（视角放低）
    -- 时会落在画面外，玩家根本看不到。
    local dist = 3 + math.random() * 11
    local side = (math.random() - 0.5) * 14
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

local function ApplyShaftVisual(e, vis, rot, scale_k)
    -- ⚠ 必须是函数自己的第一道守卫：调用点虽然都写了 `if e and e:IsValid()`，
    -- 但世界切换（洞穴进出 / 分片跳变）那一刻实体已被销毁，而 _vis 缓存过
    -- 「上次可见」⇒ HideAllShafts 与 UpdateShafts 都会带着死引用进来。
    -- 在已销毁实体上碰 Transform/AnimState/Light 是引擎级硬崩
    -- （2026-09-22 工坊反馈：「从洞穴里出来时偶尔会导致崩溃」）。
    if e == nil or not e:IsValid() then return end
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
    -- 尺寸随生命周期变化（出现时张开、稳定、消散时收拢），每条还带自己的
    -- 基准尺寸——用户要的"有大小变化"。
    local sc = (e._scale or 1.0) * (scale_k or 1.0)
    e.Transform:SetScale(sc, sc, sc)
    e.AnimState:SetMultColour(1.05, 0.90, 0.70, 0.42 * vis * damp)
    local inten = 0.26 * vis * damp
    local radius = (3 + 4 * vis) * sc
    -- 引擎光源的每次参数改动都会触发光照图重建（白天 4 盏灯逐帧改半径
    -- 是卡顿来源）。只在变化超过 6% 时才下发。
    local lr, li = e._last_radius, e._last_inten
    if lr == nil or math.abs(radius - lr) > lr * 0.06 + 0.05
        or li == nil or math.abs(inten - li) > li * 0.06 + 0.01 then
        e._last_radius, e._last_inten = radius, inten
        e.Light:SetIntensity(inten)
        e.Light:SetColour(255 / 255, 220 / 255, 160 / 255) -- 纯粹柔和暖金光
        e.Light:SetRadius(radius)
    end
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
    -- 光柱可见度跟随影子浓度：用满照上限归一化（不是写死的 0.55），否则上限
    -- 一改光柱就会跟着一起变亮。
    local amount = shafts_amount * (a / SHADOW_MAX_ALPHA)
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
                local t = e._life / 2.4
                local vis = math.min(1, t) * math.min(1, amount)
                if e._tx then
                    e.Transform:SetPosition(e._tx, 0, e._tz)
                end
                -- 张开：0.55 -> 1.15 倍
                ApplyShaftVisual(e, vis, rot, 0.55 + 0.60 * math.min(1, t))
                if e._life >= 2.4 then
                    e._phase = "hold"
                    e._life = 0
                end
            elseif phase == "hold" then
                -- 恒定沉稳光照，不做呼吸晃动
                local vis = math.min(1, amount)
                if e._tx then
                    e.Transform:SetPosition(e._tx, 0, e._tz)
                end
                -- 稳定期缓慢收一点（1.15 -> 1.0），避免"死板定格"
                local hold = math.max(0.1, e._hold or 4)
                ApplyShaftVisual(e, vis, rot, 1.15 - 0.15 * math.min(1, e._life / hold))
                if e._life >= (e._hold or 4) then
                    e._phase = "out"
                    e._life = 0
                end
            else
                local t = math.min(1, e._life / 2.8)
                local vis = (1 - t) * math.min(1, amount)
                -- 收拢消散：1.0 -> 0.75 倍
                ApplyShaftVisual(e, vis, rot, 1.0 - 0.25 * t)
                if e._life >= 2.8 then
                    e._phase = "gap"
                    e._life = 0
                    e._gap = 4 + math.random() * 9
                    e._tx, e._tz = nil, nil
                end
            end
        end
    end
end

local function EnsureShafts()
    -- 光柱实体属于**创建它的那个世界**：洞穴进出/分片跳变后旧实体全部销毁，
    -- 而数组还是满的 —— 只判断 `#shaft_ents > 0` 会让新世界一根光柱都没有，
    -- 并且 UpdateShafts 会拿着死引用去 SetPosition（硬崩）。
    -- 所以判据改成「有引用且全都活着」。
    if #shaft_ents > 0 then
        local alive = true
        for i = 1, #shaft_ents do
            local e = shaft_ents[i]
            if e == nil or not e:IsValid() then alive = false break end
        end
        if alive then return end
        -- 旧的死引用一律丢掉，重建整组
        for i = #shaft_ents, 1, -1 do shaft_ents[i] = nil end
    end
    for i = 1, SHAFT_COUNT do
        shaft_ents[i] = MakeShaft()
    end
end

local function HideAllShafts()
    for i = 1, #shaft_ents do
        local e = shaft_ents[i]
        if e and e:IsValid() then
            ApplyShaftVisual(e, 0, 0)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Schedulers (光柱 + 水面灯；影子已不在这里：v11 在 bcas_surface_light)
-- ---------------------------------------------------------------------------

local scheduler_started = false
local sched_world = nil          -- 调度器绑在哪个世界上（洞穴进出会换世界对象）

-- 世界换了（洞穴进出 / 分片跳变）就把**所有跨世界状态**清干净：
-- 旧世界的实体引用全部作废，任务也随世界一起没了。不清的话：
--   ① scheduler_started 还是 true ⇒ 新世界一个周期任务都不挂（光柱/水面灯死掉）；
--   ② water_fx 里全是死引用，0.5s 那拍只是白遍历；
--   ③ shaft_ents 死引用被 UpdateShafts 拿去 SetPosition ⇒ 引擎级硬崩。
local function PurgeWorldState(W)
    sched_world = W
    scheduler_started = false
    for k in pairs(water_fx) do water_fx[k] = nil end
    for i = #shaft_ents, 1, -1 do shaft_ents[i] = nil end
end

local function StartGlobalScheduler()
    local W = _G.TheWorld
    if W == nil then return end
    if W ~= sched_world then
        PurgeWorldState(W)
        EnsureShafts()           -- 新世界的光柱现建（旧世界的已随世界销毁）
    end
    if scheduler_started then return end
    scheduler_started = true
    local tick = 0
    EnsureShafts()

    W:DoPeriodicTask(0, function()
        if not master_enabled then return end
        tick = tick + 1
        local _scale_y, _rot, a = GetSunParams()
        -- 光柱：跟随影子浓度的同一份日晷参数（夜间 a=0 自动熄灭）
        if tick % 2 == 0 then
            UpdateShafts(2 / 30)
        end
        if a <= 0.01 and tick % 30 == 0 then
            HideAllShafts()
        end
    end)

    -- 水面灯的可见性（与影子无关，跟着世界跳变刷新）
    W:DoPeriodicTask(0.5, function()
        if not master_enabled then return end
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

-- 全局压死引擎原生投影：原生影子是"暗化实体"、会带出实体的描边轮廓，
-- 与我们自己的影子叠在一起很难看。影子生效期间（master + shadows 均开）
-- 一律把原生 Enable 改成 false；关闭我们的影子时自动放行，原生恢复。
local function HookNativeShadow()
    -- v11：引擎自带软块阴影留着当兜底层，这里不再强制关闭。
    -- （v10 之所以要关它，是因为旧的剪影体系会和它叠加出双影；哑元层不需要。）
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
        HideAllShafts()
    else
        EnsureShafts()
    end
end

function SunSystem.IsMasterEnabled()
    return master_enabled
end

-- 影子开关：v11 只保留"关掉时把被压过的原生投影逐实体放行"这一条恢复路径
-- （钩子本身已是空实现，不再压制引擎软块；面板的 ShadowsOn 交给阶段二）。
function SunSystem.SetShadowsEnabled(enabled)
    shadows_enabled = enabled == true
    if shadows_enabled then return end
    local Ents = _G.Ents
    if Ents == nil then return end
    for _, ent in pairs(Ents) do
        if ent ~= nil and ent:IsValid() and ent.DynamicShadow ~= nil then
            pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, true)
        end
    end
end

function SunSystem.SetOceanEnabled(enabled)
    ocean_enabled = enabled == true
    -- 水面 = 地皮调色（世界生成烘焙）+ 原版渲染，无运行时覆盖。
    -- OceanOn 只切换地皮定义，重进世界重烘焙后生效（UI 面板已注明）。
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
    local f = a / 0.5
    if f > 1 then f = 1 end
    if f < 0 then f = 0 end
    return f
end

function SunSystem.SetShaftsAmount(amount)
    shafts_amount = amount or 0
    if shafts_amount < 0.02 then
        HideAllShafts()
    end
end

return {
    Init = SunSystem.Init,
    -- ⚠ 函数名是 AttachWaterFX（见上方定义），别写成 SunSystem.AttachWater ——
    -- 那是自引用一个不存在的字段 ⇒ 表里 AttachWater = nil ⇒ modmain 的
    -- hotspring/ 温泉 postinit 一调就崩（2026-09-22 工坊反馈：
    -- 「modmain.lua:408: attempt to call field 'AttachWater' (a nil value)」）。
    -- 导出名保持 AttachWater（modmain 的调用面），指向 AttachWaterFX。
    AttachWater = SunSystem.AttachWaterFX,
    GetSunScreenUV = SunSystem.GetSunScreenUV,
    -- 日晷参数原始值（scale_y=影长, rot=影子方向, a=浓度, rgb=影色）：
    -- 剪影投影、物体受光、海面波光、天光方向都从这里取，永远同源。
    GetSunParams = GetSunParams,
    SetMasterEnabled = SunSystem.SetMasterEnabled,
    IsMasterEnabled = SunSystem.IsMasterEnabled,
    SetShadowsEnabled = SunSystem.SetShadowsEnabled,
    SetOceanEnabled = SunSystem.SetOceanEnabled,
    SetShaftsAmount = SunSystem.SetShaftsAmount,
    GetDayFactor = SunSystem.GetDayFactor,
}
