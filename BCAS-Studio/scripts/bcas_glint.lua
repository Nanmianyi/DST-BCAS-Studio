--[[
    海面波光层（程序化 caustics 光网 overlay）。2026-09-11 v6。

    叠在原版水体之上的自研波光层：单纯形噪声铺沙底底色 + chained caustics
    锐化成光网，再经域扭曲与 gate 打散成散点粼粼。不改原版海洋渲染。

    特性：
      * 散开式 caustics：域扭曲揉散规则六角网格 + 大尺度 gate 成片抹除；
      * 沙底质感：低频沙丘明暗 + 稀疏细沙颗粒，混成半透明青调；
      * 深度 = 离岸距离（引擎海水遮罩双环采样，昼夜无关）：浅滩金色通透，
        中海 caustics 各向异性拉长成长浪带，深海消退交还原版青色与海浪；
      * 黄昏加速（潮汐感）：太阳越低海面流动越快（环境光驱动时间缩放），
        沙面反光随环境光自然退去；
      * 盐堆浅滩：给邻近 saltstack 按簇合并成少量大 quad（FLOAT_PARAMS.y<0
        强制浅滩），在盐堆周围生成不规则浅滩；
      * 水陆遮罩（海洋纹理 alpha）+ 夜晚衰减；逐像素陆地早退。

    uniform 通道（实体 anim shader 无空闲槽位，全部塞进引擎已有 uniform）：
      FLOAT_PARAMS.x       强度（叠加不透明度）
      FLOAT_PARAMS.y       增益（caustic 亮度）；<0 = 盐堆补丁
      FLOAT_PARAMS.z       颗粒（caustic 频率倍率）| 盐堆补丁半径
      OCEAN_BLEND_PARAMS.x 海色融合量
      SetMultColour.g      环境光倍率（夜晚变暗 + 潮汐加速驱动）
]]

local _G = rawget(_G, "GLOBAL") or _G

local LAYER_BELOW_GROUND = _G.LAYER_BELOW_GROUND
local ANIM_SORT_ORDER_BELOW_GROUND = _G.ANIM_SORT_ORDER_BELOW_GROUND
local ANIM_ORIENTATION = _G.ANIM_ORIENTATION

local enabled = false
local strength = 1.0
local world_inst = nil
local glint_ent = nil

-- 面板参数读取（State.VEC 里的 Glint* 项）。state 不 require 本模块，
-- 无循环依赖；面板改值 → SetParam 直接落 State.params → 这里每帧读到。
local State = require "bcas_state"

-- 盐堆浅滩补丁：按 prefab 名找 saltstack，把邻近的盐堆**聚类成几块大浅滩**
-- （一个盐堆一块 quad 会因重叠过绘卡爆），每块用一个廉价分支的 quad 渲染，
-- FLOAT_PARAMS.z 传该块的半径。
local SALT_PREFAB = "saltstack"
local SALT_RANGE = 52          -- 只在镜头附近这一圈找盐堆
local SALT_CLUSTER_R = 26      -- 聚类半径（世界单位）
local SALT_MAX_CLUSTERS = 6    -- 同时存在的浅滩块上限
local SALT_PAD = 12            -- 浅滩在盐堆包络外再扩一圈
local SALT_MIN_R, SALT_MAX_R = 18, 46
local SALT_SCAN_INTERVAL = 0.6
local SALT_RESCAN_DIST2 = 12 * 12   -- 只要镜头没挪动超过 12 格就不重扫
local salt_patches = {}        -- 池：i -> 客户端 quad
local salt_list = {}           -- 最近一次扫描到的盐堆簇
local salt_scan_t = -1.0
local salt_scan_cx, salt_scan_cz = nil, nil

local function GetKnobs()
    local p = State.params
    local function num(k, fallback)
        local v = p ~= nil and p[k] or nil
        return type(v) == "number" and v or fallback
    end
    local on = num("GlintOn", 1) >= 0.5
    return on,
        (num("GlintStrength", 0.55)) * strength,   -- modinfo 档位当总倍率
        num("GlintDensity", 0.93),
        num("GlintGrain", 1.0),
        num("GlintSoft", 0.45)
end

-- 生成一块波光 quad（主海面 / 盐堆补丁共用）。
local function MakeSurface(scale)
    local inst = _G.CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:SetCanSleep(false)
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")
    inst:AddTag("CLASSIFIED")

    inst.AnimState:SetBank("pbr_water")
    inst.AnimState:SetBuild("pbr_water")
    inst.AnimState:PlayAnimation("idle", false)
    inst.AnimState:SetFloatParams(0.55, 0.93, 1.0)
    inst.AnimState:SetScale(scale, scale, scale)
    -- 贴地平铺；LAYER_BELOW_GROUND + UNDERWATER 排序让高光叠在原版水面之上
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BELOW_GROUND)
    inst.AnimState:SetSortOrder(ANIM_SORT_ORDER_BELOW_GROUND.UNDERWATER)
    inst.AnimState:SetDefaultEffectHandle(_G.resolvefilepath("shaders/bcas_glint.ksh"))
    inst.persists = false
    inst:Hide()
    return inst
end

-- 惰性生成主海面 quad；被外部移除后下一帧自动重建。
local function EnsureSurface()
    if glint_ent ~= nil and glint_ent:IsValid() then
        return glint_ent
    end
    glint_ent = MakeSurface(100)
    return glint_ent
end

-- 摄像机视觉中心在地表平面（y=0）上的落点（照抄 3794362938 的射线求交）。
local function GetCameraGroundCenter()
    local cam = _G.TheCamera
    if cam ~= nil and cam.camera_pos ~= nil and cam.currentpos ~= nil then
        local camx, camy, camz = cam.camera_pos:Get()
        local lookx, looky, lookz = cam.currentpos:Get()
        local dx, dy, dz = lookx - camx, looky - camy, lookz - camz
        if dy < 0 then
            local t = -camy / dy
            if t > 0 then
                return camx + dx * t, 0, camz + dz * t
            end
        end
    end
    local fp = _G.TheFocalPoint
    if fp ~= nil and fp.Transform ~= nil then
        local x, _, z = fp.Transform:GetWorldPosition()
        return x, 0, z
    end
    return nil
end

-- 环境光倍率：白天≈1（满波光），夜晚≈0（波光变暗），线性过渡。
local function GetAmbientMult()
    local r, g, b = _G.TheSim:GetAmbientColour()
    return math.max(0, math.min(1, ((r + g + b) / 3.0) / 213.6667))
end

local function HideGlint()
    if glint_ent ~= nil and glint_ent:IsValid() then
        glint_ent:Hide()
    end
end

local function HideAllPatches()
    for i = 1, #salt_patches do
        local inst = salt_patches[i]
        if inst ~= nil and inst:IsValid() then
            inst:Hide()
        end
    end
end

-- 扫描镜头附近的 saltstack，贪心聚类成几个大浅滩（中心 + 半径）。
local function ScanSaltClusters(cx, cz)
    local found = _G.TheSim:FindEntities(cx, 0, cz, SALT_RANGE)
    local pts = {}
    for i = 1, #found do
        local e = found[i]
        if e ~= nil and e.prefab == SALT_PREFAB and e.Transform ~= nil then
            local x, _, z = e.Transform:GetWorldPosition()
            pts[#pts + 1] = { x = x, z = z }
        end
    end

    local clusters = {}
    local used = {}
    local r2 = SALT_CLUSTER_R * SALT_CLUSTER_R
    for i = 1, #pts do
        if not used[i] then
            used[i] = true
            local members = { pts[i] }
            for j = i + 1, #pts do
                if not used[j] then
                    local dx, dz = pts[j].x - pts[i].x, pts[j].z - pts[i].z
                    if dx * dx + dz * dz <= r2 then
                        used[j] = true
                        members[#members + 1] = pts[j]
                    end
                end
            end
            local sx, sz = 0, 0
            for k = 1, #members do sx = sx + members[k].x; sz = sz + members[k].z end
            local mx, mz = sx / #members, sz / #members
            local maxd = 0
            for k = 1, #members do
                local dx, dz = members[k].x - mx, members[k].z - mz
                local d = math.sqrt(dx * dx + dz * dz)
                if d > maxd then maxd = d end
            end
            local rad = math.max(SALT_MIN_R, math.min(SALT_MAX_R, maxd + SALT_PAD))
            clusters[#clusters + 1] = { x = mx, z = mz, r = rad }
            if #clusters >= SALT_MAX_CLUSTERS then break end
        end
    end
    return clusters
end

-- 把浅滩块摆到池里的 quad 上；多余的隐藏。每块一个大 quad，靠
-- FLOAT_PARAMS.y = -1（强制浅滩）+ FLOAT_PARAMS.z（半径）驱动。
local function UpdateSaltPatches(cx, cz, p_strength, p_soft, ambient)
    local now = _G.GetTime ~= nil and _G.GetTime() or 0
    local moved2 = 0
    if salt_scan_cx ~= nil then
        local dx, dz = cx - salt_scan_cx, cz - salt_scan_cz
        moved2 = dx * dx + dz * dz
    end
    -- 只在「时间到」或「镜头走远了」时重扫：站着不动/打怪时完全不调
    -- FindEntities（大半径扫描是这块的主要 CPU 开销）
    if now - salt_scan_t > SALT_SCAN_INTERVAL or moved2 > SALT_RESCAN_DIST2
        or now < salt_scan_t then
        salt_scan_t = now
        salt_scan_cx, salt_scan_cz = cx, cz
        salt_list = ScanSaltClusters(cx, cz)
    end

    local n = #salt_list
    for i = 1, n do
        local c = salt_list[i]
        local inst = salt_patches[i]
        if inst == nil or not inst:IsValid() then
            inst = MakeSurface(1)
            salt_patches[i] = inst
        end
        inst:Show()
        -- 抬高一点点，避免和主海面 quad 共面被深度测试吃掉
        inst.Transform:SetPosition(c.x, 0.02, c.z)
        inst.AnimState:SetScale(c.r * 2.1, c.r * 2.1, c.r * 2.1)
        inst.AnimState:SetFloatParams(p_strength, -1.0, c.r)
        inst.AnimState:SetOceanBlendParams(p_soft)
        inst.AnimState:SetMultColour(1, ambient, 1, 1)
    end
    for i = n + 1, #salt_patches do
        local inst = salt_patches[i]
        if inst ~= nil and inst:IsValid() then
            inst:Hide()
        end
    end
end

local function OnWallUpdate()
    if world_inst == nil or not world_inst:IsValid() then
        HideGlint()
        HideAllPatches()
        return
    end
    local p_on, p_strength, p_density, p_grain, p_soft = GetKnobs()
    if not enabled or not p_on then
        HideGlint()
        HideAllPatches()
        return
    end
    if not (world_inst:HasTag("forest") and world_inst.has_ocean) then
        HideGlint()
        HideAllPatches()
        return
    end
    local x, _, z = GetCameraGroundCenter()
    if x == nil then
        return
    end
    local ambient = GetAmbientMult()
    local inst = EnsureSurface()
    if inst == nil or inst.Transform == nil then
        return
    end
    inst:Show()
    inst.Transform:SetPosition(x, 0, z)
    if inst.AnimState ~= nil then
        -- x=强度 y=增益/密度 z=颗粒倍率（与 bcas_glint.ps 的约定）
        inst.AnimState:SetFloatParams(p_strength, p_density, p_grain)
        inst.AnimState:SetOceanBlendParams(p_soft)
        inst.AnimState:SetMultColour(1, ambient, 1, 1)
    end
    UpdateSaltPatches(x, z, p_strength, p_soft, ambient)
end

-- modmain 接线：addprefabpostinit = modutil 注入的 AddPrefabPostInit，
-- is_enabled = modinfo 配置，lv = 强度倍率（soft 0.6 / standard 1.0 / bright 1.6）。
local function Apply(addprefabpostinit, is_enabled, lv)
    enabled = is_enabled == true
    strength = lv or 1.0
    if not enabled or addprefabpostinit == nil then
        return
    end
    addprefabpostinit("world", function(inst)
        if _G.TheNet ~= nil and _G.TheNet:IsDedicated() then
            return
        end
        world_inst = inst
        inst:StartWallUpdatingComponent({
            inst = inst,
            OnWallUpdate = OnWallUpdate,
        })
    end)
end

return {
    Apply = Apply,
}
