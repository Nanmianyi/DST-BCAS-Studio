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

local function ShouldHaveShadow(ent)
    if ent == nil or not ent:IsValid() then return false end
    if ent._isshadow then return false end
    if NO_SHADOW_PREFABS[ent.prefab] then return false end
    if ent:HasTag("boulder") then return false end
    if HasAnyTag(ent, NO_SHADOW_TAGS) then return false end
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

local function CopyAnim(pa, sa, shadow, force, src_ent)
    if pa == nil or sa == nil then return end

    -- Bank: hash first (workshop 3794362938). Name fallback for older clients.
    if pa.GetBankHash and sa.GetBankHash then
        local bank_hash = pa:GetBankHash()
        if bank_hash and (force or bank_hash ~= shadow._last_bank_hash) then
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

    local build = pa.GetBuild and pa:GetBuild()
    if shadow._is_birch then
        build = build or "tree_leaf_trunk_build"
    end
    if build and (force or build ~= shadow._last_build) then
        shadow._last_build = build
        sa:SetBuild(build)
        shadow._last_leaf = nil
    end
    -- Leaves AFTER SetBuild: SetBuild wipes OverrideSymbol.
    CopyLeaves(pa, sa, shadow, force)

    -- Trees: mirror the tree's own stage clip from inst.anims. Wake idles
    -- are IGNORED (body plays idle then pushes sway; switching splat to idle
    -- and back is what made trees flicker between stages). Unknown clips
    -- keep the current splat instead of guessing.
    local is_tree = src_ent ~= nil and src_ent:IsValid() and not shadow._is_player
        and (shadow._is_birch or shadow._is_twiggy or src_ent:HasTag("tree"))
    local name
    local anim_hash = pa.GetCurrentAnimationHash and pa:GetCurrentAnimationHash()
    if is_tree then
        local an = src_ent.anims
        if an ~= nil and pa.IsCurrentAnimation then
            local keys = { "stump", "burnt", "burning", "chop_burnt",
                "idle_chop_burnt", "chop", "fallleft", "fallright",
                "sway1", "sway2" }
            for i = 1, #keys do
                local nm = an[keys[i]]
                if nm and pa:IsCurrentAnimation(nm) then
                    name = nm
                    break
                end
            end
        end
        if name == nil then
            local detected = DetectAnimName(pa, shadow)
            if detected ~= nil and not string.find(detected, "idle", 1, true) then
                name = detected
            end
        end
        -- Follow the body's CURRENT sway variant (sway1 vs sway2). The two
        -- variants have different rhythms: locking one while the body plays
        -- the other makes the splat drift in and out of phase with its tree,
        -- which reads as constant jerking. Frame-scrub in the static
        -- scheduler keeps the phase locked.
        if name == nil then
            -- Wake idle / unknown one-shot: hold the current splat AND pin
            -- the hash so the fallback below cannot yank it to idle (that
            -- sway->idle->sway yank was the per-wake stutter).
            anim_hash = shadow._last_anim
        end
    else
        name = DetectAnimName(pa, shadow)
    end
    -- Restart ONLY on a genuine clip change. force refreshes bank/build/leaves
    -- but must NEVER replay the same clip: animover/locomote storms were
    -- making stopped rabbits re-run and tree splats pop between stages.
    -- Anti-flap (the recurring "shadow flickers between tree stages" bug):
    -- periodic re-detection must not rapid-fire clip switches if anything
    -- unexpected flaps; hold the current splat for 1.5s between switches.
    -- Event sync (force=true: picked/worked/ignite) bypasses the gate.
    if name ~= nil and is_tree and force ~= true
        and shadow._last_switch_t ~= nil then
        local now = _G.GetTime ~= nil and _G.GetTime() or 0
        if (now - shadow._last_switch_t) < 1.5 then
            name = nil
            anim_hash = shadow._last_anim
        end
    end
    if name ~= nil then
        if name ~= shadow._last_anim_name then
            if is_tree then
                shadow._last_switch_t = _G.GetTime ~= nil and _G.GetTime() or 0
            end
            sa:PlayAnimation(name, LOOP_ANIMS[name] == true or is_tree)
            shadow._last_anim_name = name
            shadow._last_anim = anim_hash
            shadow._last_frame = nil
        end
    elseif anim_hash and anim_hash ~= shadow._last_anim then
        pcall(sa.PlayAnimation, sa, anim_hash, true)
        shadow._last_anim = anim_hash
        shadow._last_anim_name = nil
        shadow._last_frame = nil
    end
        CopyFrame(pa, sa, shadow, shadow._is_mover == true)
    end

local function ParentHidden(ent)
    if not ent:IsValid() then return true end
    if ent:HasTag("INLIMBO") then return true end
    if ent.IsInLimbo and ent:IsInLimbo() then return true end
    local ok, vis = pcall(function()
        return ent.entity:IsVisible()
    end)
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
        shadow.Transform:SetPosition(0, 0.002, 0)
    end
    shadow.Transform:SetScale(hs, scale_y * hf * hs, hs)
    if rot ~= shadow._last_rot then
        shadow.Transform:SetRotation(rot)
    end
    if a <= 0.01 then
        if shadow._last_a ~= 0 then
            shadow._last_a = 0
            sa:SetMultColour(0, 0, 0, 0)
        end
        return
    end
    if scale_y ~= shadow._last_sy or rot ~= shadow._last_rot
        or a ~= shadow._last_a or r ~= shadow._last_r then
        shadow._last_sy, shadow._last_rot = scale_y, rot
        shadow._last_a, shadow._last_r = a, r
        sa:SetMultColour(r, g, b, a)
    end
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

    if ent.DynamicShadow ~= nil then
        pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, false)
    end
    local is_player = ent:HasTag("player")
    local is_mover = is_player or IsMover(ent)
    local is_tree_static = not is_mover and ent:HasTag("tree")

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
        -- Player must never sleep: otherwise the splat vanishes after a
        -- camera pan / chunk swap until the entity wakes again.
        shadow.entity:SetCanSleep(false)
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
    local function drop()
        dynamic_shadows[shadow] = nil
        static_shadows[shadow] = nil
        if shadow:IsValid() then
            shadow:Remove()
        end
        if ent._bcas_shadow == shadow then
            ent._bcas_shadow = nil
        end
    end
    ent:ListenForEvent("onremove", drop)

    local function sync_now()
        if not ent:IsValid() or not shadow:IsValid() then return end
        if ParentHidden(ent) then
            shadow:Hide()
            return
        end
        shadow:Show()
        CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
        ent:DoTaskInTime(0, function()
            if ent:IsValid() and shadow:IsValid() then
                CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
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
    if is_mover then
        ent:ListenForEvent("newstate", sync_now)
    end
    if not is_mover then
        if is_tree_static then
            -- Trees: one-shot PHASE LOCK on wake, never a replay. The splat
            -- never sleeps (SetCanSleep(false)) so it kept swaying while the
            -- tree entity slept -> drift. CopyAnim here would RESTART the
            -- clip (the old "wake resync reads as a hitch"); CopyFrame only
            -- SetFrames to the body's current frame: one invisible snap at
            -- the screen edge where wakes actually happen.
            ent:ListenForEvent("entitywake", function()
                if ent:IsValid() and shadow:IsValid() then
                    CopyFrame(ent.AnimState, shadow.AnimState, shadow, false)
                end
            end)
        else
            ent:ListenForEvent("entitywake", function()
                if ent:IsValid() and shadow:IsValid() then
                    CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
                end
            end)
        end
    else
        ent:ListenForEvent("entitywake", function()
            if shadow:IsValid() then
                shadow:Show()
                CopyAnim(ent.AnimState, shadow.AnimState, shadow, true, ent)
            end
        end)
    end

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
    if vis <= 0.01 then
        e:Hide()
        e.Light:Enable(false)
        e.AnimState:SetMultColour(1.0, 0.94, 0.84, 0)
        return
    end
    e:Show()
    e.Transform:SetRotation(rot or 0)
    e.AnimState:SetMultColour(1.0, 0.94, 0.84, 0.55 * vis)
    e.Light:SetIntensity(0.38 * vis)
    e.Light:SetRadius(4 + 6 * vis)
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
                local vis = (0.82 + 0.18 * math.sin(e._life * 0.55 + i)) * math.min(1, amount)
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
                        if ent.DynamicShadow ~= nil then
                            pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, false)
                        end

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
                        CopyAnim(ent.AnimState, shadow.AnimState, shadow, false, ent)

                        ApplyPose(shadow, ent, scale_y, rot, r, g, b, a, true)
                    end
                end
            else
                dynamic_shadows[shadow] = nil
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
                        if ent:HasTag("tree") then
                            local pa = ent.AnimState
                            local clip_changed = shadow._last_anim_name ~= nil
                                and pa.IsCurrentAnimation ~= nil
                                and not pa:IsCurrentAnimation(shadow._last_anim_name)
                            local build_changed = pa.GetBuild ~= nil
                                and pa:GetBuild() ~= shadow._last_build
                            if clip_changed or build_changed then
                                CopyAnim(pa, shadow.AnimState, shadow, false, ent)
                            elseif shadow._last_anim_name ~= nil
                                and (static_tick + shadow._budget_offset) % 8 == 0 then
                                -- Gentle 4s drift re-lock (single SetFrame,
                                -- no replay): corrects post-sleep drift.
                                CopyFrame(pa, shadow.AnimState, shadow, false)
                            end
                        end
                        if shadow._is_birch
                            and (static_tick + shadow._budget_offset) % 16 == 0 then
                            CopyLeaves(ent.AnimState, shadow.AnimState, shadow, false)
                        end
                    end
                end
            else
                static_shadows[shadow] = nil
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

function SunSystem.Init()
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
