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
-- 影子浓度（半透明）。0.50 = 比最早的 0.55 再透一点点
-- （日出那段仍是 0→满分 的淡入，不受影响）。
-- 注意：引擎是"逐张美术图分别混合"的，同一实体自身重叠处（帽子压头发、
-- 树干叠树冠）浓度会叠加变深，这是引擎行为、不是 bug，别用提高浓度去压
-- （上一版试过，影子会变得死黑）。
local SHADOW_MAX_ALPHA = 0.50
-- 满月夜影子的上限（仍然纯黑：影子只能有一个颜色，见 GetSunParams）。
local SHADOW_MOON_ALPHA = 0.38

-- ---------------------------------------------------------------------------
-- 影子剪影着色器：纯色 + 均匀透明度（"没有描边"的真正来源）
-- ---------------------------------------------------------------------------
-- 影子是实体美术的黑色副本，所以**美术本身就是问题**：DST 的明暗/质感是一笔
-- 笔画出来的，每个部件的边缘还带 1~2px 的半透明软边。在半透明混合下，软边
-- 叠在另一个部件的实心上就加深成一条"黑色轮廓线"，内部的排线/网纹则显成浅色
-- 线条 —— 这正是"人物有一层黑色轮廓线"。（rgb 恒 0 只能消掉彩色，消不掉
-- alpha 差。）
--
-- 解法（本项目自研，实测结论）：引擎允许实体级自写着色器 —— AnimState 的
-- SetDefaultEffectHandle 可以挂任意随模组发布的 .ksh，且对实体类型没有限制；
-- 这是整套方案的前提。分两步：
--
--  1) 硬 alpha 测试（bcas_silhouette.ksh，固定逻辑、不依赖运行时开关）：
--     >=0.30 一律抬成实心
--     （整块影子只剩一个浓度），<0.30 的软边【丢弃】——不丢的话软边会混进
--     混合、叠到别的部件上加深成线。
--  2) 单层混合：影子被压到地面后"美术上下位置 = 远近"，所以同像素上不同部件
--     的深度不一样。给每个影子再配一个【写深度孪生体】（同一 bank/build/动画/
--     姿态，但不可见、只写深度），它先画（低一层），把每个像素最靠前那层的
--     深度写进深度缓冲；可见影子后画并开启深度测试，于是同像素只有最靠前的
--     那一层能落笔 —— 重叠不再叠加变深，用户截图里那些 1~2px 深色轮廓线才会
--     真正消失。（只压平不做这一步的话，重叠加深与映射无关：离线实测三种
--     alpha 映射的重叠加深带完全一样，约 30/255。）
--
-- 着色器由 tools/make_silhouette_shader.py 从**引擎自带 anim.ksh** 派生：
-- uniform 表与 trailer 原样保留（引擎按名字喂 uniform、按 trailer 的
-- vs_refs/ps_refs 绑槽位；表不一致会 ANGLE 断言硬闪退），只有 PS 多一段
-- 哨兵控制的分支、VS 多一段哨兵控制的深度错位。哨兵 = FLOAT_PARAMS.z
-- （SetFloatParams 第三个参数）：只有我们的影子设 2.0（可见层）/ 3.0（写深度
-- 层），普通实体恒为 0，因此这段逻辑对普通实体永不生效。
-- 三个固定变体（tools/make_silhouette_shader.py 从引擎 anim.ksh 派生）：
--   visible = 本体可见剪影（alpha 压平 + 前推 LAYER_BIAS）
--   write   = 写深度孪生体（alpha 压平 + 输出 alpha 0 + 前推 0）
--   fx      = 装备克隆（可见，整体后撤 FX_BACKOFF）
-- 【为什么不用哨兵】上一版把整套逻辑挂在一个运行时 uniform（FLOAT_PARAMS.z）
-- 上，引擎一旦把它清掉/没喂到，压平与深度错位就【静默】全失效 —— 表现就是
-- 线条一直在、疯狂闪、缺块，而且怎么调数值都没用。现在每个变体都是固定逻辑，
-- 不读任何哨兵，也不依赖 SetFloatParams 是否成功。
local SHADOW_FLAT_ENABLED = true
-- 写深度孪生体总开关（性能不够时可单独关掉：只剩硬 alpha 压平）。
local SHADOW_WRITE_TWIN = true
-- 万一某个实体的影子出现"顶点碎成一块块"（说明引擎对这个实体用了 skinned
-- 顶点布局，非 skinned 版就会这样），把这里改成 true 即可切到照抄引擎
-- anim_skinned.ksh 的备用变体（六个 ksh 都随模组发布）。
local SHADOW_SKINNED_FALLBACK = false
-- 每个符号一个离散深度档（见着色器里 PARAMS.y 的用法）：同一像素上高度几乎
-- 相同的两个部件（脸贴在头上、帽子压在头发上）靠它分胜负。它只是加分项 ——
-- 着色器的深度错位主要来自顶点属性（美术高度/图集 u/图集页），即使这个编号
-- 一个都没生效，也不会退化成"打平 -> 两层都画 -> 线条"。
local SHADOW_SYMBOL_KEY = true
-- 部件名候选：通用名 + prefab_/build_ 前缀。用 BuildHasSymbol 过滤，结果按
-- build 缓存（每个 build 只算一次）。覆盖 DST 角色/生物/建筑常见符号名。
local SYMBOL_CANDIDATES = {
    "body", "head", "hair", "face", "beard", "hand", "arm", "leg", "foot",
    "torso", "tail", "nose", "ear", "hat", "skirt", "cheek", "eye", "eyebrow",
    "mouth", "pupil", "horn", "wing", "tusk", "collar", "pouch", "saddle",
    "saddlebag", "mane", "spike", "shell", "fin", "claw", "tooth", "jaw",
    "tongue", "stem", "leaf", "petal", "root", "trunk", "branch", "canopy",
    "fruit", "flower", "gem", "light", "glow", "emblem", "strap", "belt",
    "cape", "scarf", "mask", "crown", "helmet", "shield", "beak", "snout",
    "hoof", "paw", "finger", "thumb", "shoulder", "knee", "elbow", "belly",
    "chest", "back", "headbase_hat", "swap_object", "swap_hat", "swap_body",
}
local SYMBOL_KEY_MAX = 40
local symbol_key_cache = {}

-- 可见影子 AnimState -> 写深度孪生体 AnimState（弱键：实体销毁后自动回收）
local twin_as_of = setmetatable({}, { __mode = "k" })

-- 【唯一入口】把一次"符号级"AnimState 调用同时下发到可见层与写深度孪生体。
-- 孪生体是"每像素只留最近一层"的关键，它必须与可见层【几何完全一致】：
-- 只要有一处显隐/覆盖只落在可见层，孪生体就会在那些像素上照旧画出那块美术，
-- 写下比可见层更近的深度，把可见层整块拒掉 —— 表现就是"影子缺一大块 + 边缘
-- 狂闪"。2026-09-12 实测：戴帽/全盔时可见层 Hide("face")/Hide("HAIR")、
-- Hide("swap_body")，孪生体没跟着藏，人物的脸就这样整块没了。
-- 注意：图层/深度/着色器这些【两边本就不同】的设置不要走这里。
local function BothAS(sa, method, ...)
    if sa == nil then return end
    local fn = sa[method]
    if fn ~= nil then pcall(fn, sa, ...) end
    local tas = twin_as_of[sa]
    if tas ~= nil then
        local fn2 = tas[method]
        if fn2 ~= nil then pcall(fn2, tas, ...) end
    end
end

-- 返回该 build 上"存在的符号 -> 编号"表（编号 1..40，按候选表顺序稳定分配）
local function GetSymbolKeys(sa, build)
    if not SHADOW_SYMBOL_KEY or sa == nil or sa.BuildHasSymbol == nil then
        return nil
    end
    if type(build) ~= "string" or build == "" then return nil end
    local cached = symbol_key_cache[build]
    if cached ~= nil then return cached end
    symbol_key_cache[build] = {}   -- 先占位：失败时缓存空表，不重复扫
    local out = symbol_key_cache[build]
    local k = 0
    local prefab = build
    -- ipairs：编号必须跨会话稳定（pairs 顺序由哈希决定，换一次运行可能换一套档）
    for _, name in ipairs(SYMBOL_CANDIDATES) do
        local ok, has = pcall(sa.BuildHasSymbol, sa, name)
        if ok and has then
            k = k + 1
            out[name] = k
        end
        local pname = prefab .. "_" .. name
        local ok2, has2 = pcall(sa.BuildHasSymbol, sa, pname)
        if ok2 and has2 then
            k = k + 1
            out[pname] = k
        end
        if k >= SYMBOL_KEY_MAX then break end
    end
    return out
end

-- 把编号表刷到"可见影子 + 写深度孪生体"两边，且【孪生体先刷】：
-- 孪生体没接受的编号，可见层也一并清掉（档位必须两边一致）。方向不能反 ——
-- 可见层的档位只要比孪生体小一点点，那个部件就会被孪生体的深度整块拒掉。
-- （BuildHasSymbol/SetSymbolLightOverride 都是引擎调用，出错只影响深度档，
-- 所以全部 pcall。）
local function ApplySymbolKeys(sa, build)
    if sa == nil or sa.SetSymbolLightOverride == nil then return end
    local keys = GetSymbolKeys(sa, build)
    if keys == nil then return end
    local tas = twin_as_of[sa]
    for name, k in pairs(keys) do
        local ok = false
        if tas ~= nil then
            ok = pcall(tas.SetSymbolLightOverride, tas, name, k)
        end
        if ok or tas == nil then
            pcall(sa.SetSymbolLightOverride, sa, name, k)
        else
            -- 孪生体没接受：可见层也不给这个编号，两边都退回默认档
            pcall(sa.SetSymbolLightOverride, sa, name, 0)
        end
    end
end

-- 三个通道（旧代码里的 MODE_* 现在就是变体名，调用点不用改）
local SHADOW_MODE_VISIBLE = "visible"   -- 本体可见剪影
local SHADOW_MODE_WRITE = "write"       -- 写深度孪生体
local SHADOW_MODE_VISIBLE_FX = "fx"     -- 装备克隆
local SHADOW_SHADER_FILES = {
    visible = "shaders/bcas_silhouette.ksh",
    write = "shaders/bcas_silhouette_write.ksh",
    fx = "shaders/bcas_silhouette_fx.ksh",
}
local SHADOW_SHADER_FILES_SKINNED = {
    visible = "shaders/bcas_silhouette_skinned.ksh",
    write = "shaders/bcas_silhouette_write_skinned.ksh",
    fx = "shaders/bcas_silhouette_fx_skinned.ksh",
}
-- kind -> 解析结果（nil 未解析 / false 失败）
local shadow_shader_paths = {}
-- 一次性自检：第一个影子建出来时把"着色器是否真的挂上了"打进日志。
-- 这类静默失效以前排查过好几轮（渲染不对但日志干净），留一条现场证据。
local shader_selftest_done = false
-- kind -> 最近一次 SetDefaultEffectHandle 是否成功（自检用）
local shader_apply_ok = {}

local function ResolveShadowShader(kind)
    local cached = shadow_shader_paths[kind]
    if cached ~= nil then return cached end
    shadow_shader_paths[kind] = false
    local name = (SHADOW_SKINNED_FALLBACK and SHADOW_SHADER_FILES_SKINNED
        or SHADOW_SHADER_FILES)[kind] or SHADOW_SHADER_FILES.visible
    local ok, p = pcall(_G.resolvefilepath, name)
    if ok and type(p) == "string" and p ~= "" then
        shadow_shader_paths[kind] = p
    else
        print("[BCAS] 剪影着色器路径解析失败，影子回退引擎默认着色器: " .. tostring(name))
    end
    return shadow_shader_paths[kind]
end

-- kind: SHADOW_MODE_VISIBLE / SHADOW_MODE_WRITE / SHADOW_MODE_VISIBLE_FX
local function ApplyShadowShader(sa, kind)
    if not SHADOW_FLAT_ENABLED then return false end
    if sa == nil or sa.SetDefaultEffectHandle == nil then return false end
    kind = kind or SHADOW_MODE_VISIBLE
    local path = ResolveShadowShader(kind)
    if path == false then return false end
    -- SetBuild / SetSkin 会把默认 effect 打回 build 自带的那套，所以每次换
    -- build / 皮肤之后都要重挂一次（只在变化时调用，不逐帧）。
    local ok = pcall(sa.SetDefaultEffectHandle, sa, path)
    shader_apply_ok[kind] = ok
    -- FLOAT_PARAMS 归零：着色器拿它的 .y 当"美术上界"（0 -> 512 默认），
    -- .z 必须为 0，否则引擎会给顶点加 ±0.025 的浮动（floater 用的）。
    if sa.SetFloatParams ~= nil then
        pcall(sa.SetFloatParams, sa, 0, 0, 0)
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- 写深度孪生体（单层混合的关键）
-- ---------------------------------------------------------------------------
-- 影子被 ANIM_ORIENTATION.OnGround 压到地面后，"美术上下位置"就变成了世界远近，
-- 所以同一个像素上不同部件的深度并不相同。孪生体与可见影子同 bank/build/动画/
-- 姿态，但【不可见、只写深度】，而且放在更早的图层先画：每个像素被它写上
-- "最靠前那一层"的深度；可见影子后画并开深度测试，于是同一像素只有最靠前的
-- 一层能落笔 —— 重叠不再叠加变深。
--
-- 孪生体的显隐 = 影子可见 且 影子 alpha 不为 0。只在状态翻转时下发。
local function UpdateTwinVisible(shadow)
    local tw = shadow._wtwin
    if tw == nil or not tw:IsValid() then return end
    local want = shadow._shown ~= false and shadow._alpha_on ~= false
    if want ~= shadow._twin_shown then
        shadow._twin_shown = want
        if want then
            pcall(tw.Show, tw)
        else
            pcall(tw.Hide, tw)
        end
    end
end

-- 把可见影子的引擎态镜像到孪生体。what = "all" 时用影子侧缓存值一次性重建
-- （建孪生体时用）；其余情况传引擎方法名与参数，只在状态变化处调用。
local function MirrorTwin(shadow, what, ...)
    local tw = shadow._wtwin
    if tw == nil or not tw:IsValid() then return end
    local as = tw.AnimState
    if what ~= "all" then
        local fn = as[what]
        if fn ~= nil then pcall(fn, as, ...) end
        -- SetBuild / SetSkin 会把默认 effect 打回 build 自带的那套：镜像完必须
        -- 重挂一次，否则孪生体会用引擎着色器整块 quad 写深度（全都不拒绝，
        -- 重叠线条照旧，正是"猪屋没事、人物还有线"的原因）。
        ApplyShadowShader(as, SHADOW_MODE_WRITE)
        return
    end
    if shadow._last_bank_hash ~= nil and as.SetBank ~= nil then
        pcall(as.SetBank, as, shadow._last_bank_hash)
    end
    if shadow._last_build ~= nil and as.SetBuild ~= nil then
        pcall(as.SetBuild, as, shadow._last_build)
    end
    if shadow._last_skin ~= nil and as.SetSkin ~= nil then
        pcall(as.SetSkin, as, shadow._last_skin, shadow._last_build or "")
    end
    if shadow._last_anim_hash ~= nil and as.PlayAnimation ~= nil then
        pcall(as.PlayAnimation, as, shadow._last_anim_hash,
            shadow._last_anim_loop ~= false)
    end
    if shadow._last_frame ~= nil and as.SetFrame ~= nil then
        local okn, num = pcall(as.GetCurrentAnimationNumFrames, as)
        if okn and num and num > 0 then
            pcall(as.SetFrame, as, shadow._last_frame % num)
        end
    end
    if as.SetScale ~= nil then
        pcall(as.SetScale, as, shadow._last_flip and -1 or 1, 1)
    end
    ApplyShadowShader(as, SHADOW_MODE_WRITE)
end

-- 安全性：孪生体是可见影子的子实体（位置/旋转/缩放自动继承），镜像只用影子侧
-- 已缓存的值（不多读源实体）。
-- 【2026-09-12 修正】孪生体必须与可见层【几何逐像素一致】：符号显隐、符号覆盖、
-- override build 现在全部经 BothAS 同时下发两边。之前"少一块几何只会少拒绝一点
-- 重叠"的判断是错的 —— 孪生体多画出来的那块（例如可见层已经 Hide 掉的头发/脸、
-- 已经换掉的 bank）会在那些像素上写下更近的深度，把可见层整块拒掉，正是
-- "人物脸没了 + 边缘狂闪"的来源。着色器没解析出来时不建孪生体。
local function MakeWriteTwin(shadow)
    if not SHADOW_FLAT_ENABLED or not SHADOW_WRITE_TWIN then return nil end
    if ResolveShadowShader(SHADOW_MODE_WRITE) == false then return nil end
    local tw = CreateEntity()
    tw.entity:AddTransform()
    tw.entity:AddAnimState()
    tw.entity:SetCanSleep(false)
    tw.persists = false
    tw._is_shadow_twin = true
    -- 乘色 alpha 用 0.001 而不是 0：alpha 恒 0 的实体有被引擎整块跳过绘制的风险，
    -- 那样一个深度都不会写、"每像素只留最近一层"直接失效。着色器的 WRITE 档
    -- 会把输出 alpha 拍成 0，所以它依然完全不可见，这 0.001 只是让引擎照常画它。
    tw.AnimState:SetMultColour(0, 0, 0, 0.001)
    pcall(tw.AnimState.SetManualBB, tw.AnimState, 0, 0, 0, 0)
    tw.AnimState:UsePointFiltering(false)
    -- 早于可见影子所在的 LAYER_WORLD_BACKGROUND，保证"先写深度、后画可见层"
    tw.AnimState:SetLayer(LAYER_BACKGROUND)
    tw.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    -- 只写深度：测试【开】+ 写入开 —— 测试开是关键：引擎按美术 z 序画部件，
    -- 而我们的地面投影里"后画的部件更远"（美术高度已经变成远近），若不做测试，
    -- 缓冲最后留下的是"最后画的那层"，可见层就全都放行（线条照旧）。开了测试，
    -- 缓冲里只留每像素最近那层的深度；可见层再往前推一点点（shader 里的
    -- LAYER_BIAS），于是只有最近那层能落笔。孪生体自身靠 WRITE 档输出 alpha 0。
    pcall(tw.AnimState.SetDepthWriteEnabled, tw.AnimState, true)
    pcall(tw.AnimState.SetDepthTestEnabled, tw.AnimState, true)
    ApplyShadowShader(tw.AnimState, SHADOW_MODE_WRITE)
    if shadow._is_mover then
        tw.Transform:SetNoFaced()
    else
        tw.Transform:SetEightFaced()
    end
    tw:AddTag("FX")
    tw:AddTag("NOBLOCK")
    tw:AddTag("DECOR")
    tw:AddTag("NOCLICK")
    tw.entity:SetParent(shadow.entity)
    shadow._wtwin = tw
    -- 登记进"可见层 -> 孪生体"表：此后所有符号级调用（BothAS）都会同时下发，
    -- 保证两边几何逐像素一致 —— 这是"不带描边又不缺块"的前提。
    twin_as_of[shadow.AnimState] = tw.AnimState
    -- 先关着：等首轮姿态/alpha 同步确认后再亮，避免拿空状态写深度
    shadow._alpha_on = true
    if shadow._shown == nil then shadow._shown = true end
    pcall(tw.Hide, tw)
    shadow._twin_shown = false
    MirrorTwin(shadow, "all")
    UpdateTwinVisible(shadow)
    return tw
end

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

-- 清掉写深度孪生体（DropAllShadowEntities 在 DestroyShadow 之前定义，
-- 这里内联做同样的事，避免前向引用）
local function DropShadowTwin(shadow)
    local tw = shadow._wtwin
    shadow._wtwin = nil
    if shadow.AnimState ~= nil then twin_as_of[shadow.AnimState] = nil end
    if tw ~= nil and tw:IsValid() then tw:Remove() end
end

local function DropAllShadowEntities()
    for shadow, ent in pairs(dynamic_shadows) do
        DropShadowTwin(shadow)
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
        DropShadowTwin(shadow)
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
            a = SHADOW_MAX_ALPHA * math.min(1, time / FADE)
        elseif phase == "dusk" then
            scale_y = DUSK_HYPOT
            rot = DUSK_ROTATION
            a = SHADOW_MAX_ALPHA * (1 - progress)
        elseif phase == "night" and moon == 1 then
            local leg1 = TWICE_MAX * (progress - 0.5)
            scale_y = math.sqrt(leg1 * leg1 + SHADOW_MIN_LENGTH * SHADOW_MIN_LENGTH)
            rot = math.deg(math.atan(leg1 / SHADOW_MIN_LENGTH))
            a = SHADOW_MOON_ALPHA * math.min(1, progress / FADE)
            -- 影子只能有一个颜色：满月也不染色。染色会乘进美术 RGB，
            -- 把白色描边/眼睛图案从影子里透出来（用户反复反馈的那个）。
        end
        -- 季节/天气只压一点点：浓度一旦掉回 0.8 出头，多层叠加的深浅块就会
        -- 重新露出来（见 SHADOW_MAX_ALPHA 的说明），所以这里不再大幅下调。
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
                MirrorTwin(shadow, "PlayAnimation", shadow._last_anim_name,
                    LOOP_ANIMS[shadow._last_anim_name] == true)
                shadow._last_frame = nil
                return
            end
            if frame ~= shadow._last_frame then
                shadow._last_frame = frame
                local num = sa:GetCurrentAnimationNumFrames()
                if num and num > 0 then
                    sa:SetFrame(frame % num)
                    MirrorTwin(shadow, "SetFrame", frame % num)
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
        BothAS(sa, "OverrideSymbol", "swap_leaves", leaf_build, leaf_sym or "swap_leaves")
    elseif shadow._is_birch then
        -- Winter / barren: no canopy. Keep trunk-only splat.
        BothAS(sa, "ClearOverrideSymbol", "swap_leaves")
    end
end

-- DLC 角色影子的正解（2026-09-09）：**不猜任何 build 名**。每帧把
-- sa:GetBuild() 镜像到影子（SetBuild
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

-- 2026-09 装备镜像重建：
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
    -- 原版写法（torch/hats 等 prefab 的 onequip 惯例）：
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

-- 手持/帽子等核心符号的写入日志开关。默认静默（发布版日志干净）；
-- 排查影子装备问题时把 DEBUG_SWAP_LOG 改成 true，每个影子最多打 10 行。
local DEBUG_SWAP_LOG = false
local function LogSwapWrite(shadow, tag, sym, b, s)
    if not DEBUG_SWAP_LOG then return end
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

-- 【离线实证 · 2026-09-12】这些 build 里没有装备槽要写的那个符号。
-- 判据来源：解析游戏 anim 文件（tools/build_symbols.py + anim_fullscan.py），
-- 用已知可用的 pickaxe_lunarplant / hat_football 反推出 Klei 的符号哈希
-- （sdbm）后逐一核对：
--   staff_lunarplant  缺 swap_staff_lunarplant（只有 _broken_float 变体）
--   sword_lunarplant  缺 swap_sword_lunarplant
--   scythe_voidcloth  缺 swap_scythe
--   hat_lunarplant    缺 swap_hat
--   hat_voidcloth     缺 swap_hat
--   armor_voidcloth   缺 swap_body
--   boomerang_voidcloth 缺 swap_boomerang
-- 写了这种覆盖的后果：引擎会退而渲染该 build 的默认符号（残缺美术）——
-- 这正是"戴盔后影子脑袋变小"的真凶。这些装备一律不写覆盖，改走物品美术克隆。
local NO_SWAP_SYMBOL_BUILDS = {
    staff_lunarplant = true,
    sword_lunarplant = true,
    scythe_voidcloth = true,
    hat_lunarplant = true,
    hat_voidcloth = true,
    armor_voidcloth = true,
    boomerang_voidcloth = true,
    nightmare_axe = true,
}

-- 替补符号表：上面的 build 里没有装备槽那个符号，但【有别的符号装着本体】。
-- 帽子两个 build 里都有 hat01（离线扫描 ascii+hash 双证），那才是盔体；
-- 原版头盔本体走引擎的换头机制（headbase_hat），FX 只画辉光——所以照 FX 做的
-- 克隆只能画出特效，看着像没戴。改把 hat01 挂到 swap_hat 位置上就对了。
local ITEM_SYMBOL_FALLBACK = {
    hat_lunarplant = "hat01",
    hat_voidcloth = "hat01",
}

-- ============================================================================
--  物品美术克隆（FX 克隆）
--  离线实证（2026-09-12 解析 anim 文件）：裂隙装备的 build 里【没有】swap_* 符号 ——
--    staff_lunarplant / sword_lunarplant / scythe_voidcloth / hat_lunarplant /
--    hat_voidcloth 的 build 不含 swap_staff_lunarplant / swap_sword_lunarplant /
--    swap_scythe / swap_hat 这些名字（对照组 pickaxe / shovel / hat_football
--    都含，所以它们一直正常）。原版这些装备靠【独立 FX 实体】显示，而且不少是
--    【多条剪辑拼装、一条剪辑一个实体】：镰刀的刀身/柄/布/辉光分属
--    swap_loop_1 / _6 / _7 / _8 四条剪辑——只播一条就只出一部分
--    （"暗影镰刀只显示镰刀柄"就是这么来的）。
--  影子没有这些 FX，写符号覆盖只会是空气。这里按同一机制给影子生成克隆：
--    bank/build 取自物品实体，剪辑按下面的表（逐条抄自原版 FX_DEFS），
--    跟随影子符号位，明暗与影子同步，耐久状态（broken 标签）镜像。
-- ============================================================================
local CLONE_ANIMS = { "swap_loop", "idle", "anim" }
-- 帽子：原版头盔 FX（hats.lua lunarplanthat_CreateFxFollowFrame）用 idle1/2/3
-- （按朝向三档）。"anim" 是展示动画，播出来是空的。
local CLONE_ANIMS_HAT = { "idle1", "idle2", "idle3", "anim" }
local CLONE_ANIMS_BROKEN = { "broken" }

-- 需要【多实体拼装】的 build → 剪辑表。每条 = {剪辑, frame_begin, frame_end}，
-- 逐条抄自原版 FX_DEFS：frame_begin/frame_end 是【该部件在拼装动画里的帧位】，
-- 原版把它俩传给 FollowSymbol。不传的话部件按默认帧位摆放 ——
-- "镰刀多出一条往下挂的刀头 / 战斧重合一把镐" 就是这么来的。
local CLONE_CLIPS = {
    -- voidcloth_scythe.lua FX_DEFS
    scythe_voidcloth = {
        { "swap_loop_1", 0, 2 },
        { "swap_loop_6", 5 },
        { "swap_loop_7", 6 },
        { "swap_loop_8", 7 },
    },
    -- sword_lunarplant.lua：blade1(0-3) + blade2(5-8)
    sword_lunarplant = {
        { "swap_loop1", 0, 3 },
        { "swap_loop2", 5, 8 },
    },
    -- voidcloth_boomerang.lua FX_DEFS
    boomerang_voidcloth = {
        { "swap_loop_f1", 0, 2 },
    },
    -- shadow_battleaxe.lua FX_DEFS（"swap_level"..level.."_"..anim，默认 level 1）
    nightmare_axe = {
        { "swap_level1_f1", 0, 2 },
        { "swap_level1_f4", 3 },
        { "swap_level1_f6", 5 },
        { "swap_level1_f7", 6 },
        { "swap_level1_f8", 7 },
    },
    -- 帽子：原版 SpawnFollowFxForOwner 建 idle1/idle2/idle3 三个实体
    -- （framebegin=1, frameend=3）。只建一个 = 只出一部分。
    hat_lunarplant = {
        { "idle1" }, { "idle2" }, { "idle3" },
    },
    hat_voidcloth = {
        { "idle1" }, { "idle2" }, { "idle3" },
    },
}

-- 带【等级】的装备（暗影战斧）：动画名形如 swap_level<N>_fM，物品自身动画是
-- idle_level<N>。等级 = 耐久状态，必须镜像，否则部件来自不同等级 = 看着像
-- 两把武器叠在一起（"战斧重合一把镐"）。f4 那条原版写死 forcelevel=1。
local CLONE_CLIPS_LEVELED = {
    nightmare_axe = function(lvl)
        return {
            { "swap_level" .. lvl .. "_f1", 0, 2 },
            { "swap_level1_f4", 3 },
            { "swap_level" .. lvl .. "_f6", 5 },
            { "swap_level" .. lvl .. "_f7", 6 },
            { "swap_level" .. lvl .. "_f8", 7 },
        }
    end,
}

-- 在临时实体上试播 idle_level1..4，与物品当前动画哈希对上的那一级就是它的等级。
local function ResolveItemLevel(bank, build, item)
    if item == nil or item.AnimState == nil
        or item.AnimState.GetCurrentAnimationHash == nil then
        return 1
    end
    local want = item.AnimState:GetCurrentAnimationHash()
    if want == nil then return 1 end
    local probe = CreateEntity()
    probe.entity:AddTransform()
    probe.entity:AddAnimState()
    pcall(probe.AnimState.SetBank, probe.AnimState, bank)
    pcall(probe.AnimState.SetBuild, probe.AnimState, build)
    local lvl = 1
    for L = 1, 4 do
        local name = "idle_level" .. L
        pcall(probe.AnimState.PlayAnimation, probe.AnimState, name, true)
        if probe.AnimState.IsCurrentAnimation ~= nil
            and probe.AnimState.GetCurrentAnimationHash ~= nil
            and probe.AnimState:IsCurrentAnimation(name)
            and probe.AnimState:GetCurrentAnimationHash() == want then
            lvl = L
            break
        end
    end
    if probe:IsValid() then probe:Remove() end
    return lvl
end

local function KillItemFx(shadow, slot)
    local list = shadow["_itemfx_" .. slot]
    if list ~= nil then
        shadow["_itemfx_" .. slot] = nil
        shadow["_itemfx_key_" .. slot] = nil
        for i = 1, #list do
            if list[i] ~= nil and list[i]:IsValid() then list[i]:Remove() end
        end
    end
end

-- 建一个克隆实体并播放指定剪辑；该剪辑不存在（验证不过）就返回 nil。
-- fb/fe = 该部件在拼装动画里的帧位，原版经 FollowSymbol 传入。
-- 外层 pcall：这段是引擎 API 用得最野的地方（任意 bank/build 的 SetBank /
-- FollowSymbol），而调用它的路径跑在 DoPeriodicTask 里 —— DST 的调度器遇到
-- 未捕获错误会【直接杀掉那个周期任务】（scheduler.lua Scheduler:Run →
-- KillTask），一次出错就是整局所有影子不再更新（表现=影子全没了，且存盘
-- 也修不回来，只能重进）。这里出错只丢这一个克隆，其余照常。
local function MakeCloneEntInner(shadow, bank, build, clip, follow_sym, frame, fb, fe)
    local fx = CreateEntity()
    fx.entity:AddTransform()
    fx.entity:AddAnimState()
    fx.entity:AddFollower()
    fx.entity:SetCanSleep(false)
    fx.AnimState:SetBank(bank)
    fx.AnimState:SetBuild(build)
    pcall(fx.AnimState.PlayAnimation, fx.AnimState, clip, true)
    if fx.AnimState.IsCurrentAnimation == nil
        or not fx.AnimState:IsCurrentAnimation(clip) then
        if fx:IsValid() then fx:Remove() end
        return nil
    end
    if frame ~= nil and fx.AnimState.SetFrame ~= nil then
        pcall(fx.AnimState.SetFrame, fx.AnimState, frame)
    end
    -- 剪影着色器 + 哨兵：装备影子也要纯色压平，否则会和本体影子风格不一致
    -- （装备边缘的软边仍会显成线条）。必须在 SetBuild 之后挂（见函数注释）。
    ApplyShadowShader(fx.AnimState, SHADOW_MODE_VISIBLE_FX)
    -- 与影子本体同样的采样方式（线性 + mip）：物品克隆也常被压扁绘制，
    -- 点采样会把刀身/杖头的细部件打成虚线（见影子创建处的同一处说明）。
    fx.AnimState:UsePointFiltering(false)
    -- 装备克隆在 LAYER_WORLD_BACKGROUND（晚于写深度孪生体的 LAYER_BACKGROUND）：
    -- 本体孪生体先把深度写进去，装备影子与本体重叠的部分（在更远处）会被深度
    -- 测试挡掉，不再和本体叠加变深。深度测试开、写入关（只挡别人、不改深度）。
    fx.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    fx.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    pcall(fx.AnimState.SetDepthTestEnabled, fx.AnimState, true)
    pcall(fx.AnimState.SetDepthWriteEnabled, fx.AnimState, false)
    -- 必须显式给颜色：新建 AnimState 的默认乘色可能全 0（=完全透明），
    -- 那样克隆存在也不可见。先按影子当前浓度给一个，后面每轮同步。
    local cr, cg, cb, ca = 0, 0, 0, SHADOW_MAX_ALPHA
    if shadow.AnimState.GetMultColour ~= nil then
        local okc, r0, g0, b0, a0 = pcall(shadow.AnimState.GetMultColour, shadow.AnimState)
        if okc and r0 ~= nil then cr, cg, cb, ca = r0, g0, b0, a0 end
    end
    fx.AnimState:SetMultColour(cr, cg, cb, ca)
    fx.Transform:SetNoFaced()
    fx.persists = false
    fx.entity:SetParent(shadow.entity)
    fx:AddTag("FX")
    fx:AddTag("NOCLICK")
    pcall(fx.Follower.FollowSymbol, fx.Follower, shadow.GUID, follow_sym,
        nil, nil, nil, true, nil, fb, fe)
    return fx
end

local clone_error_reported = false
local function MakeCloneEnt(shadow, bank, build, clip, follow_sym, frame, fb, fe)
    local ok, fx = pcall(MakeCloneEntInner, shadow, bank, build, clip,
        follow_sym, frame, fb, fe)
    if not ok then
        if not clone_error_reported then
            clone_error_reported = true
            print("[BCAS] 装备影子克隆失败（已忽略，不影响其它影子）: " .. tostring(fx))
        end
        return nil
    end
    return fx
end

local function SyncItemFx(shadow, slot, item, follow_sym, anims)
    anims = anims or CLONE_ANIMS
    if item == nil or item.AnimState == nil then
        KillItemFx(shadow, slot)
        return false
    end
    local bank = item.AnimState.GetCurrentBankName ~= nil
        and item.AnimState:GetCurrentBankName() or nil
    local build = item.AnimState.GetBuild ~= nil and item.AnimState:GetBuild() or nil
    if type(bank) ~= "string" or bank == "" or type(build) ~= "string" or build == "" then
        KillItemFx(shadow, slot)
        return false
    end
    local want_broken = item.HasTag ~= nil and item:HasTag("broken")
    -- 帽子：全覆盖盔的 FX 在原版跟随 headbase_hat（hats.lua SpawnFollowFxForOwner
    -- 里 isfullhelm → "headbase_hat"），没有该符号时才退回 swap_hat。
    if slot == "head" and shadow.AnimState ~= nil
        and shadow.AnimState.BuildHasSymbol ~= nil then
        local okh, has = pcall(shadow.AnimState.BuildHasSymbol,
            shadow.AnimState, "headbase_hat")
        if okh and has then follow_sym = "headbase_hat" end
    end
    -- 剪辑选择：损坏态 → broken；带等级的（战斧）→ 按物品当前等级取；
    -- 多实体拼装表 → 逐条全建；其余（法杖等单体）→ 候选列表逐个试。
    local clips, one_only, lvl_tag
    local clip_fn = CLONE_CLIPS_LEVELED[build]
    if want_broken then
        clips, one_only = CLONE_ANIMS_BROKEN, true
    elseif clip_fn ~= nil then
        local lvl = ResolveItemLevel(bank, build, item)
        clips, one_only, lvl_tag = clip_fn(lvl), false, "|L" .. tostring(lvl)
    elseif CLONE_CLIPS[build] ~= nil then
        clips, one_only = CLONE_CLIPS[build], false
    else
        clips, one_only = anims, true
    end
    local key = build .. "|" .. tostring(follow_sym) .. "|" .. tostring(slot)
        .. (want_broken and "|b" or "|n") .. (lvl_tag or "")
    if shadow["_itemfx_key_" .. slot] ~= key then
        KillItemFx(shadow, slot)
        -- 不套用"物品自身动画的帧号"：部件动画与物品动画帧数不同，套上去
        -- 会让部件停在错位的帧（帽子最明显）。所有部件在同一轮创建、从同一帧
        -- 起同步播放即可（原版套帧是为了跟手上动作对齐，影子不需要）。
        local list = {}
        for i = 1, #clips do
            local entry = clips[i]
            local clip, fb, fe
            if type(entry) == "table" then
                clip, fb, fe = entry[1], entry[2], entry[3]
            else
                clip = entry
            end
            local fx = MakeCloneEnt(shadow, bank, build, clip, follow_sym, nil, fb, fe)
            if fx ~= nil then
                list[#list + 1] = fx
                if one_only then break end
            end
        end
        if #list > 0 then
            shadow["_itemfx_" .. slot] = list
            shadow["_itemfx_key_" .. slot] = key
        end
    end
    local list = shadow["_itemfx_" .. slot]
    if list == nil then return false end
    -- 每轮：颜色同步 + 跟随兜底
    local cr, cg, cb, ca
    if shadow.AnimState.GetMultColour ~= nil then
        local okc, r0, g0, b0, a0 = pcall(shadow.AnimState.GetMultColour, shadow.AnimState)
        if okc and r0 ~= nil then cr, cg, cb, ca = r0, g0, b0, a0 end
    end
    for i = 1, #list do
        local fx = list[i]
        if fx:IsValid() then
            if cr ~= nil and fx.AnimState.SetMultColour ~= nil then
                pcall(fx.AnimState.SetMultColour, fx.AnimState, cr, cg, cb, ca)
            end
            fx._age = (fx._age or 0) + 1
            if fx._follow_ok == nil and fx._age >= 2 then
                local px, py, pz = fx.Transform:GetWorldPosition()
                fx._follow_ok = not (px == 0 and py == 0 and pz == 0)
            end
            if fx._follow_ok == false and shadow.Transform ~= nil then
                pcall(fx.Transform.SetPosition, fx.Transform,
                    shadow.Transform:GetWorldPosition())
            end
        end
    end
    return true
end

-- 影子销毁：连同它的物品美术克隆一起收掉（克隆是父级到影子的独立实体，
-- 影子没了不清就会留下悬空 FX）。
local function DestroyShadow(shadow)
    if shadow == nil then return end
    KillItemFx(shadow, "swap_object")
    KillItemFx(shadow, "head")
    KillItemFx(shadow, "body")
    -- 写深度孪生体跟着影子一起销毁：留着会继续往深度缓冲写"已经没有影子"的形状
    DropShadowTwin(shadow)
    if shadow:IsValid() then shadow:Remove() end
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
        shadow._vis_key = nil
    end

    -- 覆盖类扫描节流：5 帧扫一次，大幅减轻逐符号压力
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
                    -- 是否套了皮肤：按"实际 build ≠ 默认 build"判断。
                    -- 不能用 GetSkinName()：客户端物品实体的皮肤名常常是空的，
                    -- 日志实证 armor_marble_rockabs / backpack_dragonfly_fire
                    -- 这类皮肤 build 会被判成 skin=false → 走普通覆盖 = 空气。
                    local is_skin
                    if default ~= nil then
                        is_skin = (actual ~= default)
                    else
                        is_skin = (actual ~= pf) and (actual ~= ("swap_" .. tostring(pf)))
                    end
                    hb_equips = hb_equips or {}
                    hb_equips[slot.name] = {
                        sym = slot.sym, build = actual, guid = item.GUID,
                        skin = is_skin, base = default or pf, ent = item,
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
                BothAS(sa, "ClearOverrideSymbol", d.sym)
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
                        BothAS(sa, "ClearOverrideSymbol", d.sym)
                    end
                end
                if not done then
                    local fb_sym = ITEM_SYMBOL_FALLBACK[d.build]
                    if NO_SWAP_SYMBOL_BUILDS[d.build] and fb_sym == nil then
                        -- 这个 build 里没有该符号、也没有替补：写覆盖会让引擎
                        -- 渲染默认符号（残缺美术），一律不写，交克隆。
                        BothAS(sa, "ClearOverrideSymbol", d.sym)
                    else
                        -- 有替补符号（帽子用 hat01）就把替补挂到装备槽位置；
                        -- 否则按原样写。不要用 BuildHasSymbol 做守卫：日志实证
                        -- 连源玩家自己在皮肤下对该 API 都返回 false，它不反映
                        -- 装备符号是否存在，用它拦会把能显示的覆盖一起拦掉。
                        BothAS(sa, "OverrideSymbol", d.sym, d.build, fb_sym or d.sym)
                        LogSwapWrite(shadow, "头身", d.sym, d.build, fb_sym or d.sym)
                    end
                end
            end
        end
    end
    for slot_name, last in pairs(eq_cache) do
        if hb_equips == nil or hb_equips[slot_name] == nil then
            eq_cache[slot_name] = nil
            if last.sym ~= nil then BothAS(sa, "ClearOverrideSymbol", last.sym) end
        end
    end

    -- 1b-pre) 全盔检测：原角色普通覆盖表里若有 headbase_hat → 这顶是全覆盖盔。
    local head_equipped = hb_equips ~= nil and hb_equips["head"] ~= nil
    local head_is_fullhelm = false
    if head_equipped and pa.GetSymbolOverride ~= nil then
        local hb_build = pa:GetSymbolOverride("headbase_hat")
        head_is_fullhelm = hb_build ~= nil
    end
    -- 1b) headbase_hat 换头路径依赖 player AnimState 的 UseHeadHatExchange，
    -- 影子（复制实体）用不了，统一清掉。全盔也走 swap_hat —— 在影子 build
    -- 正确的前提下这条路能出完整盔型（"以前虚空风帽能显示"即此路径）。
    if shadow._hbh_cleared ~= true then
        shadow._hbh_cleared = true
        BothAS(sa, "ClearOverrideSymbol", "headbase_hat")
    end

    -- 1b-2) 头/身美术兜底（每轮）：符号覆盖写进去后引擎是否真的接受？
    -- 裂隙装备的 build 里没有 swap_* 符号（见 SyncItemFx 注释），覆盖会被丢弃，
    -- 表现为"日志写了但画面空气"。没被接受时改用物品美术克隆兜底。
    shadow._head_art = false
    if hb_equips ~= nil then
        for slot_name, d in pairs(hb_equips) do
            local applied = false
            if d.skin == true then
                applied = true   -- 皮肤走引擎皮肤表，另有回读确认，这里不重复判
            elseif NO_SWAP_SYMBOL_BUILDS[d.build] and ITEM_SYMBOL_FALLBACK[d.build] == nil then
                applied = false  -- 离线实证：该 build 无此符号、也无替补 → 必须用克隆
            elseif d.ent ~= nil and sa.GetSymbolOverride ~= nil then
                applied = sa:GetSymbolOverride(d.sym) ~= nil
            end
            if applied then
                SyncItemFx(shadow, slot_name, nil)
                if slot_name == "head" then
                    -- 用替补符号画出来的盔体：保留头与头发，只显示 HAT 层
                    shadow._head_art = (ITEM_SYMBOL_FALLBACK[d.build] ~= nil) and "fb" or true
                end
            else
                -- 帽子用 idle1/idle2/idle3（原版头盔 FX 的动画），
                -- 手持/身体用 swap_loop/idle。
                SyncItemFx(shadow, slot_name, d.ent, d.sym,
                    slot_name == "head" and CLONE_ANIMS_HAT or CLONE_ANIMS)
            end
        end
    else
        SyncItemFx(shadow, "head", nil)
        SyncItemFx(shadow, "body", nil)
    end

    -- 1c) 图层显隐镜像（2026-09-11 关键修复）。
    -- 影子只镜像"符号覆盖"，从不复制原角色的 Show/Hide 图层状态；手部能显示
    -- 全靠 step4 显式切了 ARM_carry。帽子/护甲的符号所在的图层默认是隐藏的
    -- （HAT / HEAD_HAT_HELM / swap_body 等），所以覆盖写了也画不出来——
    -- 这正是"功能帽(swap_hat 走默认可见层)显示、全盔与护甲/背包不显示"的原因。
    -- 这里按装备情况把图层状态复刻成与原版 onequip 一致。
    local body_has = hb_equips ~= nil and hb_equips["body"] ~= nil
    local head_art = shadow._head_art
    local vis_key = (head_equipped and "1" or "0") .. (head_is_fullhelm and "f" or "n")
        .. (body_has and "1" or "0")
        .. (head_art == true and "a" or (head_art == "fb" and "b" or "-"))
    if shadow._vis_key ~= vis_key then
        shadow._vis_key = vis_key
        if head_equipped and head_art == "fb" then
            -- 替补符号画出的盔体（hat01 挂在 swap_hat 上）：盔体完整覆盖头部，
            -- 头/头发一律藏掉——实测保留头发会把盔顶掉一片。脸的部件也收起，
            -- 免得从盔壳里穿出来。HAT 层显示（盔体就在 swap_hat 上）。
            BothAS(sa, "Show", "HAT")
            BothAS(sa, "Hide", "HAIR_HAT")
            BothAS(sa, "Hide", "HAIR_NOHAT"); BothAS(sa, "Hide", "HAIR")
            BothAS(sa, "Hide", "HEAD")
            BothAS(sa, "Show", "HEAD_HAT")
            BothAS(sa, "Hide", "HEAD_HAT_NOHELM")
            BothAS(sa, "Show", "HEAD_HAT_HELM")
            BothAS(sa, "UseHeadHatExchange", false)
            BothAS(sa, "HideSymbol", "face"); BothAS(sa, "HideSymbol", "swap_face")
            BothAS(sa, "HideSymbol", "beard"); BothAS(sa, "HideSymbol", "cheeks")
        elseif head_equipped and not head_art then
            -- 头盔美术走克隆（build 里没有 swap_hat 符号，比如亮茄头盔/虚空风帽）：
            -- 保留角色原本的头与头发，帽子的美术由克隆实体画在上层。
            -- 这里绝不 Hide("HEAD")，否则就是"戴盔把头吃掉"。
            BothAS(sa, "Hide", "HAT")
            BothAS(sa, "Show", "HEAD"); BothAS(sa, "Show", "HAIR")
            BothAS(sa, "Show", "HAIR_NOHAT")
            BothAS(sa, "Hide", "HEAD_HAT"); BothAS(sa, "Hide", "HEAD_HAT_HELM")
            BothAS(sa, "UseHeadHatExchange", false)
            BothAS(sa, "ShowSymbol", "face"); BothAS(sa, "ShowSymbol", "swap_face")
            BothAS(sa, "ShowSymbol", "beard"); BothAS(sa, "ShowSymbol", "cheeks")
        elseif head_equipped and head_is_fullhelm then
            -- 全盔：完全照抄原版 fullhelm_onequip 的玩家分支（hats.lua:122）：
            -- Hide HAT/HAIR*/HEAD，Show HEAD_HAT/HEAD_HAT_HELM，隐藏 face/beard，
            -- 换头由上面的 headbase_hat 覆盖完成。不要再走 swap_hat —— 那不是
            -- 全覆盖盔的路线。
            BothAS(sa, "Hide", "HAT"); BothAS(sa, "Hide", "HAIR_HAT")
            BothAS(sa, "Hide", "HAIR_NOHAT"); BothAS(sa, "Hide", "HAIR")
            BothAS(sa, "Hide", "HEAD")
            BothAS(sa, "Show", "HEAD_HAT")
            BothAS(sa, "Hide", "HEAD_HAT_NOHELM")
            BothAS(sa, "Show", "HEAD_HAT_HELM")
            BothAS(sa, "UseHeadHatExchange", false)
            BothAS(sa, "HideSymbol", "face"); BothAS(sa, "HideSymbol", "swap_face")
            BothAS(sa, "HideSymbol", "beard"); BothAS(sa, "HideSymbol", "cheeks")
        elseif head_equipped then
            BothAS(sa, "Show", "HAT"); BothAS(sa, "Hide", "HAIR_HAT")
            BothAS(sa, "Show", "HAIR_NOHAT"); BothAS(sa, "Show", "HAIR")
            BothAS(sa, "Hide", "HEAD")
            BothAS(sa, "Show", "HEAD_HAT")
            BothAS(sa, "Show", "HEAD_HAT_NOHELM")
            BothAS(sa, "Hide", "HEAD_HAT_HELM")
            BothAS(sa, "UseHeadHatExchange", false)
            BothAS(sa, "ShowSymbol", "face"); BothAS(sa, "ShowSymbol", "swap_face")
            BothAS(sa, "ShowSymbol", "beard"); BothAS(sa, "ShowSymbol", "cheeks")
        else
            BothAS(sa, "Hide", "HAT")
            BothAS(sa, "Show", "HEAD"); BothAS(sa, "Show", "HAIR")
            BothAS(sa, "Show", "HAIR_NOHAT")
            BothAS(sa, "Hide", "HEAD_HAT"); BothAS(sa, "Hide", "HEAD_HAT_HELM")
            BothAS(sa, "UseHeadHatExchange", false)
            BothAS(sa, "ShowSymbol", "face"); BothAS(sa, "ShowSymbol", "swap_face")
            BothAS(sa, "ShowSymbol", "beard"); BothAS(sa, "ShowSymbol", "cheeks")
        end
        if body_has then
            BothAS(sa, "Show", "swap_body")
            BothAS(sa, "ShowSymbol", "swap_body")
            BothAS(sa, "Show", "backpack")
        else
            -- 脱下护甲/背包：把身体图层与符号一并收起（只 Show 不 Hide
            -- 会让上一件装备的轮廓留在影子上）。
            BothAS(sa, "Hide", "swap_body")
            BothAS(sa, "HideSymbol", "swap_body")
            BothAS(sa, "Hide", "backpack")
        end
    end

    -- 2) 普通装备镜像：从原角色的 pa:GetSymbolOverride 读回！
    -- 原版斧头/手杖/木甲装备时，服务端把 swap_axe/swap_cane/armor_wood 写进了原角色的普通覆盖表。
    -- pa:GetSymbolOverride(sym) 能正确读出真实的 swap build 与 symbol！
    -- 槽位读回镜像。两条硬伤（2026-09-12 日志实证）：
    --   1) pa:GetSymbolOverride 经常返回【引擎内部哈希】（数字），拿它当 build
    --      名写进去画不出任何东西（日志：swap_body <- 1806374379,3067666734）；
    --   2) 源读回 nil 时清掉影子符号 —— 但穿皮肤/换装时源读回 nil 是正常的
    --      （引擎把覆盖收进内部表），这会把我们刚用物品实体写好的覆盖抹掉
    --      （日志：swap_body <- armor_marble_rockabs 之后紧跟 清除 nil,nil）。
    -- 因此：只接受字符串 build；读不到不动影子符号，清理由 item-driven 路径负责。
    local function MirrorOne(sym)
        if reserved[sym] then return end
        if pa.GetSymbolOverride == nil then return end
        local sb, ssym = pa:GetSymbolOverride(sym)
        if type(sb) ~= "string" or sb == "" then return end
        if type(ssym) ~= "string" or ssym == "" then ssym = sb end
        local last = sym_cache[sym]
        if last == nil or last[1] ~= sb or last[2] ~= ssym then
            sym_cache[sym] = { sb, ssym }
            LogSwapWrite(shadow, "槽位", sym, sb, ssym)
            BothAS(sa, "OverrideSymbol", sym, sb, ssym)
        end
    end

    -- 镜像其余装备槽符号。核心三符号（手持/帽/身）一律不走这条：
    -- 它们由物品实体驱动（步骤 1/3）唯一负责，读回路径掺和进来只会用哈希
    -- 覆盖或清掉正确值（日志实证：swap_body <- armor_marble_rockabs 之后
    -- 紧跟 槽位 1806374379 与 清除 nil,nil，护甲/背包因此不显示）。
    local CORE_SYMS = { swap_object = true, swap_hat = true, swap_body = true }
    for i = 1, #PLAYER_EQUIP_SYMBOLS do
        local sym = PLAYER_EQUIP_SYMBOLS[i]
        if not CORE_SYMS[sym] then
            MirrorOne(sym)
        end
    end

    -- 2b) 衣物部位镜像（"穿着空气"修复）：
    -- 引擎 skinner 把衣物皮肤用 OverrideSkinSymbol 覆盖在身体部位符号上
    -- （torso/arm_upper/leg/foot...），GetSymbolOverride 可读回。注意必须
    -- 用 OverrideSkinSymbol 复刻——普通 OverrideSymbol 对皮肤部位不渲染。
    -- 同样只接受字符串（读回哈希/空一律跳过，不清影子）。
    for i = 1, #CLOTHING_SYMBOLS do
        local sym = CLOTHING_SYMBOLS[i]
        local sb, ssym = pa:GetSymbolOverride(sym)
        if type(sb) == "string" and sb ~= "" then
            if type(ssym) ~= "string" or ssym == "" then ssym = sym end
            local last = cloth_cache[sym]
            if last == nil or last[1] ~= sb or last[2] ~= ssym then
                cloth_cache[sym] = { sb, ssym }
                BothAS(sa, "OverrideSkinSymbol", sym, sb, ssym)
            end
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

    -- 3b 兜底需要用到的手持信息（在下面的分支里填充）
    local _hand_item = nil
    local _hand_skin_used = false
    local _hand_build = nil

    -- swap_object 手持物【item-driven 自实现】（2026-09-09 定案）：
    -- 读回方案被证伪——v3.6.4 用读回也时灵时不灵（普通覆盖表在换装时冻结，
    -- 影子常拿到上一次的工具或开局空手）。原版 onequip 写的覆盖完全可从
    -- 背包实体直接推导：
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
        _hand_item = hand
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
            -- 原版 onequip 的权威数据源：swap_data.sym_build / sym_name，
            -- 缺 sym_name 时二者同名（cane 的 swap_data 只有 sym_build）。
            -- 不做任何后缀加工 —— 之前按 "_float" 截断把损坏态武器
            -- （swap_staff_BROKEN_FORGEDITEM_float / scythe_base_broken_float）
            -- 的符号名砍废了，法杖与收割者因此拿空气。
            local swap_build = swd ~= nil and swd.sym_build or nil
            local sym_name = swd ~= nil and swd.sym_name or nil
            if swap_build == nil then
                local ent_build = hand.AnimState ~= nil and hand.AnimState.GetBuild ~= nil
                    and hand.AnimState:GetBuild() or nil
                swap_build = (type(ent_build) == "string" and ent_build ~= "") and ent_build
                    or ("swap_" .. tostring(hand.prefab))
            end
            sym_name = sym_name or swap_build
            -- 皮肤手持：以 EquipSkinBuild 为准（GetSkinBuild 优先，实体 build
            -- 兜底）。唯一要排除的情况是"皮肤 build 与手持 build 相同"——那不是
            -- 皮肤而是原皮，走普通覆盖即可。不要额外要求 GetSkinName 非空：
            -- classified 物品的皮肤名与 build 关系不规整，加了这道门手杖皮肤
            -- 会整批掉回原皮。
            local skin = EquipSkinBuild(hand)
            if skin == swap_build then
                skin = nil
            end
            if swap_build ~= nil and swap_build ~= "" then
                _hand_build = swap_build
                local last = sym_cache["swap_object"]
                if skin ~= nil and skin ~= "" then
                    _hand_skin_used = true
                    -- 带皮肤手持：引擎皮肤表路径（先清普通残留再写皮肤覆盖）
                    if last == nil or last[1] ~= skin or last[2] ~= sym_name then
                        sym_cache["swap_object"] = { skin, sym_name }
                        BothAS(sa, "ClearOverrideSymbol", "swap_object")
                        local ok, err = pcall(sa.OverrideItemSkinSymbol, sa, "swap_object",
                            skin, sym_name, hand.GUID, swap_build)
                        LogSwapWrite(shadow, ok and "手持皮肤" or "手持皮肤拒绝",
                            "swap_object", skin, sym_name .. " err=" .. tostring(err))
                        if not ok then
                            BothAS(sa, "OverrideSymbol", "swap_object", swap_build, sym_name)
                        end
                    end
                else
                    -- 原皮手持（工具/武器/火把）：完全复刻原版
                    -- owner.AnimState:OverrideSymbol("swap_object", swap_build, sym_name)
                    if NO_SWAP_SYMBOL_BUILDS[swap_build] then
                        -- 该 build 里没有这个符号（离线实证）：写覆盖会让引擎
                        -- 渲染默认符号（残缺美术），一律不写，交物品美术克隆。
                        sym_cache["swap_object"] = nil
                        BothAS(sa, "ClearOverrideSymbol", "swap_object")
                    elseif last == nil or last[1] ~= swap_build or last[2] ~= sym_name then
                        sym_cache["swap_object"] = { swap_build, sym_name }
                        BothAS(sa, "ClearOverrideSymbol", "swap_object")
                        LogSwapWrite(shadow, "手持", "swap_object", swap_build, sym_name)
                        BothAS(sa, "OverrideSymbol", "swap_object", swap_build, sym_name)
                    end
                end
                written = true
            end
        end
        if not written and pa.GetSymbolOverride ~= nil then
            -- 退回读回方案（双值接收，不能写成 and/or 链）。读回的常常是引擎
            -- 内部哈希（数字），拿哈希当 build 名写进去画不出任何东西
            -- （日志实证：swap_object <- 717536814,3733248833 → 手杖消失），
            -- 所以只接受字符串，否则宁可不写。
            local sb, ssym = pa:GetSymbolOverride("swap_object")
            if type(sb) ~= "string" or sb == "" then sb = nil end
            if sb ~= nil then
                if type(ssym) ~= "string" or ssym == "" then ssym = sb end
                local last = sym_cache["swap_object"]
                if last == nil or last[1] ~= sb or last[2] ~= ssym then
                    sym_cache["swap_object"] = { sb, ssym }
                    LogSwapWrite(shadow, "手持读回", "swap_object", sb, ssym)
                    BothAS(sa, "OverrideSymbol", "swap_object", sb, ssym)
                end
            elseif sym_cache["swap_object"] ~= nil then
                -- 原角色已无手持覆盖（FX 类武器 / 空手）：影子一并清掉，防残留上一件
                sym_cache["swap_object"] = nil
                BothAS(sa, "ClearOverrideSymbol", "swap_object")
            end
        end
    elseif sym_cache["swap_object"] ~= nil then
        sym_cache["swap_object"] = nil
        BothAS(sa, "ClearOverrideSymbol", "swap_object")
    end

    -- 3b) 手持美术兜底（每轮）：符号覆盖若没被引擎接受（裂隙武器的 build 里
    -- 没有 swap_* 符号，原版靠独立 FX 实体显示），改用物品美术克隆兜底，
    -- 跟随影子的 swap_object 符号位。接受了就收掉克隆，避免双重显示。
    if has_hand_item and _hand_item ~= nil and not _hand_skin_used
        and _hand_build ~= nil and _hand_build ~= "" then
        local applied = (not NO_SWAP_SYMBOL_BUILDS[_hand_build])
            and sa.GetSymbolOverride ~= nil
            and sa:GetSymbolOverride("swap_object") ~= nil
        if applied then
            SyncItemFx(shadow, "swap_object", nil)
        else
            SyncItemFx(shadow, "swap_object", _hand_item, "swap_object")
        end
    else
        SyncItemFx(shadow, "swap_object", nil)
    end

    -- 4) 手臂图层：有手部装备 → Show ARM_carry / Hide ARM_normal；否则反之。
    if has_hand_item ~= shadow._arm_carry then
        shadow._arm_carry = has_hand_item
        if has_hand_item then
            BothAS(sa, "Show", "ARM_carry")
            BothAS(sa, "Hide", "ARM_normal")
        else
            BothAS(sa, "Hide", "ARM_carry")
            BothAS(sa, "Show", "ARM_normal")
        end
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
            -- 非字符串一律视为无效（读回哈希的情况），不清影子符号
            if type(b) ~= "string" or b == "" then
                b = nil
            elseif type(s) ~= "string" or s == "" then
                s = b
            end
            local kb, ks = "_ovb_" .. sym, "_ovs_" .. sym
            if shadow[kb] ~= b or shadow[ks] ~= s then
                shadow[kb] = b
                shadow[ks] = s
                if b ~= nil then
                    BothAS(sa, "OverrideSymbol", sym, b, s)
                else
                    BothAS(sa, "ClearOverrideSymbol", sym)
                end
            end
        end
    end
end


local function CopyAnim(pa, sa, shadow, force, src_ent)
    if pa == nil or sa == nil then return end

    -- Bank: hash first. Name fallback for older clients.
    -- 引擎态对比（影子 sa:GetBankHash vs 源 pa:GetBankHash）：force 不再
    -- 绕过对比，事件风暴（newstate/equip → sync_now）不会反复重放 SetBank。
    if pa.GetBankHash and sa.GetBankHash then
        local bank_hash = pa:GetBankHash()
        if bank_hash and bank_hash ~= sa:GetBankHash() then
            sa:SetBank(bank_hash)
            MirrorTwin(shadow, "SetBank", bank_hash)
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
            MirrorTwin(shadow, "SetBank", bank)
            shadow._last_leaf = nil
        end
    end

    -- Build + 皮肤镜像。
    -- 【根因 · 2026-09-12 实证】皮肤名不是 build：anim 目录里只有 wilson.zip，
    -- 没有 wilson_nature。皮肤由引擎经皮肤表索引到真实 build，所以
    -- SetBuild("wilson_nature") 会让影子渲染一个不存在的空 build —— 该 build
    -- 里任何符号（swap_object / swap_hat / swap_body / headbase_hat）都解析不到，
    -- 表现就是"所有装备一起空气 + 全套盔把头吃没"。日志佐证：影子
    -- GetBuild()=wilson_nature 时，BuildHasSymbol 对三个核心符号全为 false。
    -- 正确做法（官方 widgets/skinspuppet_beefalo.lua:76 范式）：
    --   SetBuild(基础build) → SetSkin(皮肤名, 基础build) → 复制符号覆盖
    -- 绝不用 SetBuild 传皮肤名。
    local build = pa.GetBuild and pa:GetBuild()
    local src_skin = pa.GetSkinBuild ~= nil and pa:GetSkinBuild() or nil
    if src_skin == build then
        build = nil   -- 皮肤名冒充 build：这一步必须让给 SetSkin
    end
    -- 剪影着色器在 SetBuild / SetSkin 后会被打回 build 自带的默认着色器，
    -- 所以这一轮只要碰过 build/皮肤，结束时就重挂一次（不是逐帧调用）。
    local shader_dirty = false
    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        MirrorTwin(shadow, "SetBuild", build)
        -- SetBuild 会清掉符号覆盖（包括我们的编号），必须重刷。
        -- ApplySymbolKeys 内部就是【孪生体先刷、可见层后刷】，不会再出现两边档位不一致。
        ApplySymbolKeys(sa, build)
        shadow._last_leaf = nil
        -- SetBuild 清空影子覆盖表：标记装备扫描强制重涂
        shadow._eq_dirty = true
        shader_dirty = true
    end
    if pa.GetSkinBuild ~= nil and sa.SetSkin ~= nil then
        local sb = pa:GetSkinBuild()
        if sb ~= nil and sb ~= "" then
            -- SetSkin 第二个实参是【基础 build】（官方 skinspuppet_beefalo.lua:72
            -- 传 prefabname.."_none"，skinner.lua:44 传 default_build），
            -- 不能传皮肤名。取角色 prefab 名：源实体无 prefab 时回退到
            -- 源 GetBuild() 里去掉皮肤名后的值，再不行给空串（引擎容错）。
            local base = pa.prefab
            if type(base) ~= "string" or base == "" or base == sb then
                local gb = pa.GetBuild ~= nil and pa:GetBuild() or nil
                base = (gb ~= nil and gb ~= sb) and gb or ""
            end
            -- 源驱动对比：引擎对 skin build 有内部归一化，SetSkin 的入参与
            -- GetSkinBuild 的回读值可能永不相等——若逐帧对比就会每帧 SetSkin →
            -- 每帧清空覆盖表 → 装备符号刚涂上就被抹（"拿空气"+"闪一下"）。
            -- 因此只认"源皮肤值变化"这一个触发条件，不重试（重试同样是每帧清表）。
            if sb ~= shadow._last_skin then
                shadow._last_skin = sb
                pcall(sa.SetSkin, sa, sb, base)
                MirrorTwin(shadow, "SetSkin", sb, base)
                -- SetSkin 同样会清掉符号覆盖（ApplySymbolKeys 会同时刷两边）
                ApplySymbolKeys(sa, sb)
                -- SetSkin 清空影子覆盖表：标记装备扫描立刻重涂
                shadow._eq_dirty = true
                shader_dirty = true
            end
            shadow._had_skin = true
        elseif shadow._had_skin then
            -- 皮肤卸下：重放基础 build 还原（SetBuild 同样清覆盖表 → 脏标记）
            shadow._had_skin = nil
            shadow._last_skin = nil
            local base = pa.prefab
            if type(base) == "string" and base ~= "" then
                sa:SetBuild(base)
                MirrorTwin(shadow, "SetBuild", base)
                shadow._last_build = base
                shadow._last_leaf = nil
                shadow._eq_dirty = true
                shader_dirty = true
            end
        end
    end
    if shader_dirty then
        ApplyShadowShader(sa, SHADOW_MODE_VISIBLE)
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
            MirrorTwin(shadow, "PlayAnimation", anim_hash, loop)
            shadow._last_anim = anim_hash
            shadow._last_anim_hash = anim_hash
            shadow._last_anim_loop = loop
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
            MirrorTwin(shadow, "SetScale", flip and -1 or 1, 1)
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
        if shadow._alpha_on ~= false then
            shadow._alpha_on = false
            UpdateTwinVisible(shadow)
        end
        if shadow._last_a ~= 0 then
            shadow._last_a = 0
            shadow._last_aq = 0
            sa:SetMultColour(0, 0, 0, 0)
        end
        return
    end
    if shadow._alpha_on == false then
        shadow._alpha_on = true
        UpdateTwinVisible(shadow)
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
        ent:ListenForEvent("equip", sync_now)
        ent:ListenForEvent("unequip", sync_now)
        ent:ListenForEvent("ms_playerchangeclothing", sync_now)
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

-- 一次性自检：把"着色器挂上没有 / 孪生体在不在 / 符号档刷了几档"写进日志。
-- 这几样以前都是静默失效 —— 画面不对但日志干干净净，只能靠猜。留一条现场证据。
local function ShaderSelfTest(shadow)
    if shader_selftest_done then return end
    shader_selftest_done = true
    local tw = shadow._wtwin
    local tw_ok = tw ~= nil and tw:IsValid()
    local n, kmax = 0, 0
    local keys = GetSymbolKeys(shadow.AnimState, shadow._last_build)
    if keys ~= nil then
        for _, k in pairs(keys) do
            n = n + 1
            if k > kmax then kmax = k end
        end
    end
    local function flag(k) return shader_apply_ok[k] and "OK" or "失败" end
    print(string.format(
        "[BCAS] 剪影自检: 挂载 可见=%s 写深度=%s 克隆=%s | 孪生体=%s | 符号档=%d档(最大%s) | 头=%s",
        flag(SHADOW_MODE_VISIBLE), flag(SHADOW_MODE_WRITE), flag(SHADOW_MODE_VISIBLE_FX),
        tw_ok and "OK" or "缺失", n, tostring(kmax),
        tostring(shadow._last_build)))
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

    -- 纯色剪影：黑色乘色 + 剪影着色器。
    -- rgb 恒 0（美术里的白色描边/眼睛图案乘 0 后不可能显出来），alpha 用
    -- 引擎原样的 0.50/0.38；"没有描边"由 ApplyShadowShader 挂上的
    -- bcas_silhouette.ksh 完成（把美术的半透明软边/排线压成单一浓度）。
    shadow.AnimState:SetMultColour(0, 0, 0, 0)
    shadow.AnimState:SetManualBB(0, 0, 0, 0)
    -- 深度测试开、写入关：靠写深度孪生体（更早的图层）挡住同像素上更远的部件，
    -- 实现"每像素只混合一次"。可见影子自己不写深度，不会裁掉后面的世界物体。
    pcall(shadow.AnimState.SetDepthTestEnabled, shadow.AnimState, true)
    pcall(shadow.AnimState.SetDepthWriteEnabled, shadow.AnimState, false)
    -- 线性 + mip 采样（= 引擎默认，与普通实体美术一致）。点采样在影子被压扁
    -- （scale 0.44~1.0）时是"最近邻缩小"：细笔画（叶尖/羽毛/发丝）会被整片
    -- 跳过，剪影边缘和小细节变成点阵/虚线段（"影子全是碎的"有一半来自这里）。
    shadow.AnimState:UsePointFiltering(false)
    -- 图层必须晚于写深度孪生体（LAYER_BACKGROUND），保证"先写深度、后画可见层"
    shadow.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    shadow.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    -- 剪影着色器 + 哨兵。这里先挂一次（源 build 为空时下方 CopyAnim 不会重挂），
    -- 之后每次 SetBuild / SetSkin 变化时由 CopyAnim 重挂。
    ApplyShadowShader(shadow.AnimState, SHADOW_MODE_VISIBLE)
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
    -- 写深度孪生体：同 bank/build/动画/姿态，不可见，只写深度（单层混合的关键）
    MakeWriteTwin(shadow)
    -- 每个符号一个离散深度档（滑不滑由 build 决定，缓存）
    ApplySymbolKeys(shadow.AnimState, shadow._last_build)

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
    ShaderSelfTest(shadow)
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
    -- 可见度提高：光柱透明度 0.28 -> 0.42，点光源 0.15 -> 0.26，
    -- 半径加大，让光对地面/遮挡物的交互看得见。
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
    -- 一改（0.55 → 0.96）光柱就会跟着一起变亮 1.75 倍。
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
                -- 彻底关闭太阳光柱的呼吸晃动！锁定恒定沉稳光照，杜绝忽明忽暗像呼吸灯！
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
                    shadow._shown = false
                    UpdateTwinVisible(shadow)
                else
                    local px, py, pz = ent.Transform:GetWorldPosition()
                    local dist_sq = (px - ppx) * (px - ppx) + (pz - ppz) * (pz - ppz)
                    if dist_sq > FAR_SQ and not shadow._is_player then
                        shadow:Hide()
                        shadow._shown = false
                        UpdateTwinVisible(shadow)
                    else
                        shadow:Show()
                        shadow._shown = true
                        UpdateTwinVisible(shadow)
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
                                        -- 孪生体必须一起换 bank：两边几何（骨骼/部件）不一致时，
                                        -- 孪生体会在可见层自己那块上写下更近的深度，整块拒掉
                                        MirrorTwin(shadow, "SetBank", "wilsonbeefalo")
                                        shadow._last_bank = "wilsonbeefalo"
                                        shadow._last_anim_name = nil
                                        shadow._last_anim = nil
                                    end
                                    if mount.AnimState and mount.AnimState.GetBuild then
                                        local m_build = mount.AnimState:GetBuild()
                                        if m_build and m_build ~= shadow._last_mount_build then
                                            if shadow._last_mount_build then
                                                BothAS(sa, "ClearOverrideBuild", shadow._last_mount_build)
                                            end
                                            BothAS(sa, "AddOverrideBuild", m_build)
                                            shadow._last_mount_build = m_build
                                            -- 覆盖 build 变化同样重挂一次剪影着色器（只在变化时）
                                            ApplyShadowShader(sa, SHADOW_MODE_VISIBLE)
                                        end
                                    end
                                end
                                shadow._height_factor = 1.2
                            else
                                shadow._height_factor = 1.0
                                if shadow._last_mount_build and shadow.AnimState then
                                    pcall(shadow.AnimState.ClearOverrideBuild, shadow.AnimState, shadow._last_mount_build)
                                    MirrorTwin(shadow, "ClearOverrideBuild", shadow._last_mount_build)
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
                DestroyShadow(shadow)
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
        if tick % 5 == 0 then
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
                    shadow._shown = false
                    UpdateTwinVisible(shadow)
                else
                    local px, py, pz = ent.Transform:GetWorldPosition()
                    local dist_sq = (px - ppx) * (px - ppx) + (pz - ppz) * (pz - ppz)
                    if dist_sq > STATIC_HIDE_SQ then
                        shadow:Hide()
                        shadow._shown = false
                        UpdateTwinVisible(shadow)
                    else
                        shadow:Show()
                        shadow._shown = true
                        UpdateTwinVisible(shadow)
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
                DestroyShadow(shadow)
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
            if shadow:IsValid() then
                shadow:Hide()
                shadow._shown = false
                UpdateTwinVisible(shadow)
            end
            if ent and ent:IsValid() and ent.DynamicShadow ~= nil then
                pcall(ent.DynamicShadow.Enable, ent.DynamicShadow, true)
            end
        end
        for shadow, _ent in pairs(static_shadows) do
            if shadow:IsValid() then
                shadow:Hide()
                shadow._shown = false
                UpdateTwinVisible(shadow)
            end
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
