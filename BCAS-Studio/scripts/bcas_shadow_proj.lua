--[[ BCAS Studio —— 地面投影 v14（引擎第二遍绘制 · 顶点斜投影）

影子不是我们画的东西。引擎每帧会把**每一个动画实体**在自己之外再画一遍，画进
bloom 渲染通道（`SetRenderPassDefaultEffect(RENDERPASS.BLOOM, "shaders/anim_bloom.ksh")`
—— 引擎在 gamelogic.lua:79 自己这么设）。本模块把这一次绘制接管过来：

  顶点端（bcas_shadow_proj.vs）：把几何沿太阳方向斜投影到地面
      ground.xz = world.xz + world.y * shadow_dir * (1 / tan(el))
    每个顶点用自己的世界高度，所以树冠落得远、树根落在脚边 —— 这是**真·斜投影**，
    不是把贴图压扁。皮肤/装备/骑乘/生长阶段/动画帧全部由引擎当帧的 MatrixW 承担，
    没有任何需要镜像或同步的东西。

  片元端（bcas_shadow_proj.ps）：把美术 alpha 变成灰阶覆盖度写进 bloom 缓冲。

  合成端：bcas_shadow_cap.ksh 从缓冲里把它分离出来，merged pass 乘回场景
      （浓度与影色在合成端，所以**不需要逐实体 uniform**）。

## 为什么这样就没有"叠影/接缝/斑点"了

旧体系（bcas_shadow_dummy.lua）把每个部件各画一遍贴地平铺，重叠处 `1-(1-a)^N`
越叠越深，只能用屏幕门网点去压 —— 而网点的等值线又成了斜纹/摩尔纹。
这一版的片元写 `src alpha = 覆盖度`，而 bloom 缓冲是 alpha 混合：
    dst = src + dst * (1 - src.a)
覆盖度 = 1 时 later fragment **直接替换**前者（dst = src + dst*0）⇒ 同一实体
5~8 个符号叠在同一像素上，结果仍然是**一层**。没有网点，没有条纹，没有斑点。

## 影子的方向从哪来（2026-09-20 用户定版）

方向 = **太阳世界方向** 与 **附近光源方向** 按（白天因子 × 相干度）混合出来的
一个世界向量，算式就是 bcas_surface_light.M.WorldDirFor（**同一个函数**，
两条模块各调一次 ⇒ 写进总线的角逐位相同）。于是：

- 正午权重为 0：只有太阳，火把一动不动（不会"正午举火把，影子像风车"）。
- 黄昏/夜里权重 → 1：附近的光接管朝向 —— **用户点名要保留的效果**
  （之前误删过一次："那个不用删那个效果还挺好"）。
- 权重只吃世界状态（日晷的 day 因子），**与任何开关无关**。用户原话：
  「开关物体立体光照影子朝向会变！」—— 那是旧版把朝向交给"谁在推总线"
  决定的后果，现在两边各写同一个值，谁先谁后都不影响朝向。

FLOAT_PARAMS 的三个槽是**相机空间共识方位角 theta / -仰角 / 强度位**
（与 bcas_surface_light 同一套编码）。影子顶点端只读 x/y，强度位 z 是给受光面
看的（见下方"共享总线"）。

## 与受光面共用一条总线（关键约束）

FLOAT_PARAMS 是 AnimState 级状态，**两条模块都在写**，所以口径必须完全一致：
`x = theta`（朝光源的相机空间方位角）由 M.WorldDirFor 统一算出；`y` 与 `z` 两槽
从 2026-09-21 起是**打包载荷**（y = 仰角 + 冷暖/对比滑条，z = 受光面跟光方位角 +
强度），唯一编码入口是 surface_light.M.BusTriple，布局见那边 M.PackY 的长注释。

- 两边都开（默认）：两条模块写的是同一个 x/y，不会打架。
- 受光面被用户关掉：影子自己推（同样的算式），影子照常。
- 影子关掉：受光面照常，投影 handle 交还引擎。
- 两者都关：引擎的 anim_bloom 默认着色器回到岗位，缓冲里没有光栅（见下）。

## 让位协议

bloom effect handle 是共享通道。自己会发光的实体（引擎给它挂了
SetBloomEffectHandle）一律不抢 —— 它们的 RGB 要留给辉光；挂上之后被外部
抢占就整批交还（观察式，照抄 bcas_surface_light 的成熟做法）。
]]

local M = {
    enabled = true,
    density = 1.0,          -- 合成端浓度倍率（面板「影子浓度」）
    SHADER = "shaders/bcas_shadow_proj.ksh",

    -- 施影者判据：不打标签、不列 prefab（与受光面/旧哑元同一套规则）
    EXCLUDE_TAGS = { "FX", "INLIMBO", "DECOR", "placer", "inventoryitem",
                     "playerghost", "ghost", "flying", "invisible",
                     "stalker", "shadow", "lightrays",
                     -- 2026-09-21（用户：幽灵类生物都不要有影子）——下面这些 tag 全部
                     -- 是从本体 scripts/prefabs/*.lua 里**读出来的**，不是猜的
                     -- （查证脚本 work/_recon6.py / _recon8.py / _recon10.py）：
                     --   影怪：shadowcreature（shadow_creature/shadow_leech/shadowchanneler）、
                     --         nightmarecreature（爬行恐惧/恐怖猎手等基类）、
                     --         shadowsubmissive、shadowthrall（裂隙爪牙）、
                     --         shadowminion（麦斯威尔仆从）；另有既有 tag "shadow" 兜底
                     --   暗影三基佬：shadowchesspiece（shadowchesspieces.lua）
                     --   阿比盖尔：abigail（另有 ghost/flying 双重覆盖）
                     --   月灵：brightmare（gestalt / gestalt_guard / corpse_gestalt）
                     --   海洋生物：oceanfish / oceanfishable / fish / pondfish（海鱼、塘鱼）、
                     --         squid（乌贼）、shark（海鲨）、crab_mob / crabking（蟹王系）
                     --   船只（2026-09-22 用户：船有问题，也去掉影子）：boat / boatbuilder /
                     --         boat_accessory（桅杆）/ boatbumper / boatcannon / boatleak /
                     --         boatmagnet / boatmagnetbeacon / boat_patch
                     -- ⚠ 刻意**不**收的两个 tag（_recon10.py 查到会误伤）：
                     --   shadow_aligned —— 玩家侧 player_hosted.lua / skilltree_wendy.lua
                     --                     也带它，收了会把玩家自己的影子干掉；
                     --   scarytooceanprey —— 猎犬 hound / 座狼 warglet / 宝箱怪 chest_mimic
                     --                     也带它，收了陆地怪的影子也会一起没。
                     --   上面那些具体 tag 已经覆盖用户点名的每一类，不需要这两个大网。
                     "shadowcreature", "nightmarecreature", "shadowsubmissive",
                     "shadowthrall", "shadowminion",
                     "shadowchesspiece", "abigail", "brightmare",
                     "oceanfish", "oceanfishable", "fish", "pondfish",
                     "squid", "shark", "crab_mob", "crabking",
                     "boat", "boatbuilder", "boat_accessory", "boatbumper",
                     "boatcannon", "boatleak", "boatmagnet", "boatmagnetbeacon",
                     "boat_patch",
                     -- burnt（烧毁的树/草）：受光面白名单不收，实体上没有水印，
                     -- 画了投影就会盖在自己身上（BUG① 的完好入口，2026-09-19）。
                     -- 烧焦的残干本来也没有像样的树冠可投影，直接不画。
                     "burnt" },

    -- prefab 名前缀兜底（tag 万一漏掉的同族实体）。船只 2026-09-22 起也在这里：
    -- 船部件是一大家族（boat_rotator / anchor / boatlip 这些只有 structure tag，
    -- 靠 tag 收不全，必须用名字前缀），用户明确「船的去掉影子」。
    -- miniboat 是那条小船上挂的灯；otter 是海獭（海里游的，和鱼同类处理）。
    EXCLUDE_PREFAB_PREFIX = { "oceanfish", "oceanshadowcreature", "ocean_trawler",
                              "squid", "shark", "crabking", "gestalt", "shadow",
                              "otter",
                              "boat", "mast", "sail", "anchor", "keel", "miniboat" },

    -- 挂载节奏（照抄受光面的实机调校值：一次性给上百个实体换 handle 会让
    -- 引擎在同一帧编译大量着色器变体，宁可慢几秒也不允许单帧爆发）
    MOUNT_PER_SWEEP = 12,
    MAX_MOUNTED = 400,
    RADIUS = 45,
    MAX_FAILS = 5,
    _fails = 0,             -- ⚠ 必须初始化：日志 369 行 nil 比较让每次扫描死在
                            --   第一个候选，整个会话只挂上 1 个实体（2026-09-19 实机）

    -- 权重为 0 的门槛：白天因子 ≥ 此值时就只剩太阳方向（全局一个值，不逐实体解算）。
    -- **必须与受光面的 LightWeight / WorldDirFor 门槛一致**（那边是 ww > 1e-4，
    -- 即 day < 0.9999），否则傍晚会出现在"影子按灯的朝向、受光面按太阳"的错位。
    -- 这里是"要不要逐实体算"的性能闸门，不是方向公式的开关：闸门两侧的方向
    -- 都是同一个 M.WorldDirFor 算出来的。
    SUN_LOCK = 0.9999,
}

local _G = rawget(_G, "GLOBAL") or _G
local DEG = math.pi / 180

-- 环上的角差（theta 是 0..2π 的回绕量，直接相减会在接缝处骗人：
-- 0.001 与 6.283 其实差 0.0002，直减却得到 -6.282）
local function Ring(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return d
end

local mounted = setmetatable({}, { __mode = "k" })   -- AnimState -> entry
local external = setmetatable({}, { __mode = "k" })  -- AnimState -> {effect, x, y, z}
local external_bloom = setmetatable({}, { __mode = "k" })  -- AnimState -> 辉光句柄路径（观察）
local warned = {}
local hooks_installed = false
local raw_setfx, raw_clearfx, raw_params, raw_setbloom, raw_clearbloom
local mount_count, yield_count = 0, 0
local last_push = nil
local sweep_tick = 0
local logged_enabled = nil
local night_shadows = false   -- 用户拍板：夜里/洞穴默认不要影子（V13 §B7）

local function Log(msg)
    print("[BCAS] 地面投影: " .. tostring(msg))
end

local function Guard(name, fn)
    local ok, a = pcall(fn)
    if not ok then
        if not warned[name] then
            warned[name] = true
            Log("内部错误（已兜住，只降级本功能）: " .. name .. ": " .. tostring(a))
        end
        return false, nil
    end
    return true, a
end

-- ---------------------------------------------------------------------------
-- 共享总线（FLOAT_PARAMS）的写入协议
-- ---------------------------------------------------------------------------
-- 总线的语义（2026-09-21 起 y/z 是打包载荷，见文件顶部 u 型注释）：
--   x = 相机空间共识方位角 theta（影子顶点着色器**只读这一格**当方向）
--   y = -(仰角量化 + 冷暖/对比滑条)      z = -(受光面跟光方位角 + 强度)
-- 影子顶点着色器只解 y 的低 11 位当仰角，完全不读 z。两条模块都必须写**逐位相同**
-- 的三元组，否则会出现"开关影子顺手改了受光面亮度"这种开关互相串味 ——
-- 所以统一走 BusEncode（内部首选 surface_light.M.BusTriple）。
--
-- 逐实体的"当前共识方向"解算器：**权威实现是受光面模块**（bcas_surface_light
-- 的 M.WorldDirFor，一个纯世界函数：太阳 × 附近光源，权重只吃白天因子）。
-- 影子端调同一个函数，两家写进 x/y 的角才会逐位相同 —— 这是"开关物体立体光照
-- 时影子朝向不动"这条判据的实现方式（详见 PushAll 上面那段事故台账）。
-- 实现在 ThetaOf 之后：同文件内的 local 前向引用会读到 nil（v11 实机崩溃的
-- 同一类错误，check_forward_refs.py 会当场报出来），所以这里先声明。
local EntityDir
-- 总线 z 槽的取值（2026-09-21 起 z 是**打包值**，不是原来的"负数强度"）。
--
-- 打包布局与理由写在 bcas_surface_light 的 M.PackY 长注释里，规格由
-- tools/bus_pack_proof.py 离线证明。影子模块**不自己解释格式**：一律问受光面模块
-- 要一个完整三元组（M.BusTriple），这样才能保证两个模块写进同一条通道的值逐位相同
-- （这条不变量是"开关物体立体光照时影子朝向不动"的实现方式）。
--
-- 兜底：受光面模块没加载（或老版本没有 BusTriple）时，自己按同一份布局打包。
-- 两份公式必须逐字一致 —— 这是本仓库既有的"两个模块算同一个方向"的同一类约定，
-- 改任何一边都要同时改另一边，并重跑 tools/bus_pack_proof.py。
local EL_MAX = math.pi / 2.0
local X_COOL_MAXV = 63        -- 2^6 - 1
local X_DARK_MAXV = 63        -- 2^6 - 1
local X_FQ_MOD = 4096         -- 2^12
local X_DARK_MUL = 64         -- 2^6
local X_FQ_MUL = 4096         -- 2^12
local X_COOL_A = 64           -- 2^6
local X_DARK_A = 64           -- 2^6
local Y_EL_MAXV = 2047        -- 2^11 - 1
local Y_WARM_MAXV = 63        -- 2^6 - 1
local Y_CON_MAXV = 63         -- 2^6 - 1
local Y_WARM_MUL = 2048       -- 2^11
local Y_CON_MUL = 131072      -- 2^17
local Y_WARM_A = 64           -- 2^6
local Y_CON_A = 64            -- 2^6
local Z_THB_MOD = 4096        -- 2^12
local Z_STR_MAXV = 255        -- 2^8 - 1
local Z_STR_MUL = 4096        -- 2^12

-- ⚠ Lua 5.1 没有 `<<`：位移一律写成十进制常量（与 bcas_surface_light 逐字一致）。
--
-- x 槽（2026-09-22 新增）：背光冷暖 + 背光黑白 + 影子方位角，
--   x = cool_q + 64*dark_q + 4096*f_q     （≤ 2^24-1，float32 精确）
-- 引擎对本通道 x 的 7 处读取全在 `if(y>0)` 里（y 恒为负 ⇒ 永不执行），
-- 证据见 work/_recon12.py。影子这边**只关心其中的 f_q**。
local function PackX(theta, scool, sdark)
    theta = tonumber(theta) or 0
    scool = tonumber(scool) or 0.5
    sdark = tonumber(sdark) or 0.5
    local a = (theta + math.pi) % (2.0 * math.pi)
    if a < 0 then a = a + 2.0 * math.pi end
    local f_q = math.floor(a / (2.0 * math.pi) * X_FQ_MOD + 0.5) % X_FQ_MOD
    local cool_q = math.floor(scool * X_COOL_A - 1 + 0.5)
    local dark_q = math.floor(sdark * X_DARK_A - 1 + 0.5)
    if cool_q < 0 then cool_q = 0 elseif cool_q > X_COOL_MAXV then cool_q = X_COOL_MAXV end
    if dark_q < 0 then dark_q = 0 elseif dark_q > X_DARK_MAXV then dark_q = X_DARK_MAXV end
    return cool_q + dark_q * X_DARK_MUL + f_q * X_FQ_MUL
end

-- x 槽 → 影子方位角（弧度）。BusIsOurs 里凡是要拿 fx 跟角度比的，都必须先过这里。
-- ⚠ 方位角在**高 12 位**（低 12 位是背光冷暖/黑白两把滑条）：取模等于把滑条当角度
-- （出厂档解出 -0.05 弧度），归属判据会全错。与影子 VS 的 floor(x/4096) 同源。
local function DecodeTheta(x)
    x = tonumber(x) or 0
    local f_q = math.floor(x / X_FQ_MUL) % X_FQ_MOD
    return (f_q / X_FQ_MOD) * 2.0 * math.pi - math.pi
end

local function PackY(el, warm, con)
    el = tonumber(el) or 0
    if el < 0 then el = 0 elseif el > EL_MAX then el = EL_MAX end
    warm = tonumber(warm) or 0.5
    con = tonumber(con) or 0.5
    local el_q = math.floor(el / EL_MAX * Y_EL_MAXV + 0.5)
    local warm_q = math.floor(warm * Y_WARM_A - 1 + 0.5)
    local con_q = math.floor(con * Y_CON_A - 1 + 0.5)
    if el_q < 0 then el_q = 0 elseif el_q > Y_EL_MAXV then el_q = Y_EL_MAXV end
    if warm_q < 0 then warm_q = 0 elseif warm_q > Y_WARM_MAXV then warm_q = Y_WARM_MAXV end
    if con_q < 0 then con_q = 0 elseif con_q > Y_CON_MAXV then con_q = Y_CON_MAXV end
    return -(el_q + warm_q * Y_WARM_MUL + con_q * Y_CON_MUL)
end

local function PackZ(theta_blend, strength)
    theta_blend = tonumber(theta_blend) or 0
    strength = tonumber(strength) or 0
    if strength < 0 then strength = 0 elseif strength > 1.5 then strength = 1.5 end
    local a = (theta_blend + math.pi) % (2.0 * math.pi)
    if a < 0 then a = a + 2.0 * math.pi end
    local thb_q = math.floor(a / (2.0 * math.pi) * Z_THB_MOD + 0.5) % Z_THB_MOD
    local str_q = math.floor(strength / 1.5 * Z_STR_MAXV + 0.5)
    if str_q < 0 then str_q = 0 elseif str_q > Z_STR_MAXV then str_q = Z_STR_MAXV end
    return -(thb_q + str_q * Z_STR_MUL)
end

-- 返回写进总线的三元组 (x, y, z)。优先用受光面模块的编码入口（逐位一致的唯一保证）。
--
-- 第 4 个参数**故意传 nil**：影子这边的 k 是"日晷浓度"（夜里恰好是 0），
-- 而 z 槽里的强度该由受光面按附近光源算 —— 传过去会把夜里的光强盖成 0
-- （冒烟台里就叫"夜里强度=0"那条）。只有在受光面模块缺席、我们走自己的兜底
-- 公式时，才用这个 k。
local function BusEncode(inst, theta, el, k_fallback)
    local SL = _G.package.loaded["bcas_surface_light"]
    if SL ~= nil and SL.BusTriple ~= nil then
        local okb, bx, by, bz = pcall(SL.BusTriple, inst, theta, el, nil)
        if okb and type(bx) == "number" and type(by) == "number" and type(bz) == "number" then
            return bx, by, bz
        end
    end
    -- 兜底：自己的公式（滑条取不到时按出厂 0.5；θ_blend 无灯时退回 θ 本身）
    local warm, con = 0.5, 0.5
    local scool, sdark = 0.5, 0.5
    local St = _G.package ~= nil and _G.package.loaded["bcas_state"] or nil
    if St ~= nil and St.params ~= nil then
        if type(St.params.ShadeWarm) == "number" then warm = St.params.ShadeWarm end
        if type(St.params.ShadeContrast) == "number" then con = St.params.ShadeContrast end
        if type(St.params.ShadeCool) == "number" then scool = St.params.ShadeCool end
        if type(St.params.ShadeDark) == "number" then sdark = St.params.ShadeDark end
    end
    local k = tonumber(k_fallback) or 0
    return PackX(theta, scool, sdark), PackY(el, warm, con), PackZ(theta, k)
end

-- 写总线。两件事缺一不可：
--   ① 走 **raw setter**（raw_params 是 InstallHooks 之前抓到的那一个）：受光面的
--      观察钩子把"我们以外的写入"判成抢占，我们若走 hook 后的入口，它就会把自己
--      的受光面整片让位 —— 水印丢失 ⇒ 影子重新盖回本体（BUG① 的另一种入口）。
--   ② 进出受光面模块的自写计数器 M.BusSelfEnter / M.BusSelfLeave：钩子安装顺序
--      万一反过来（受光面先装，它包住的就是引擎原始函数、我们抓到的 raw 反而是
--      它的包装），靠这个计数器也能让它的钩子认出"这是自己人写的"，不记抢占。
--
-- ⚠ 老写法是把共享标记写成全局 `_G.BCAS_BUS_SELF`，在实机上**两头都不成立**
-- （2026-09-20 用户报"炸了"，client_log：`bcas_surface_light.lua:334: variable
-- 'BCAS_BUS_SELF' is not declared`）：DST 的 strict.lua 给 _G 挂了元表 ——
-- 读未声明的全局当场抛错（受光面那边就这么炸的，错误冒到 update.lua ⇒ 客户端重启），
-- 写未声明的全局同样抛错（这边包在 pcall 里 ⇒ 静默失败 ⇒ 标记永远是 nil ⇒
-- 这条防线等于不存在）。现在改成调对面模块表上的函数：只有真正的字段访问，
-- 不往游戏全局命名空间里塞名字，任何环境都不会抛错。
local function SLModule()
    return _G.package.loaded["bcas_surface_light"]
end

-- 受光面模块没加载、或它没有这个函数（老版本）→ 什么都没发生，照常写。
-- 用 pcall 包住：这是"自报家门"，不该因为对面出问题而挡住影子自己的写入。
local function BusSelf(which)
    local SL = SLModule()
    if SL == nil then return false end
    local f = SL[which]
    if type(f) ~= "function" then return false end
    return pcall(f) == true
end

local function WriteBus(as, x, y, z)
    local entered = BusSelf("BusSelfEnter")
    local pushfn = raw_params or as.SetFloatParams
    local ok = pcall(pushfn, as, x, y, z)
    if entered then BusSelf("BusSelfLeave") end
    return ok
end

-- 我们写过的总线残留（弱键：实体消失自动回收）。
-- MountOK 用它区分"外人占了这条总线"与"我们自己上一次写的那一笔"：不区分的话，
-- 关一次影子再打开，这些实体带着我们自己的旧值会被当成外人，永远挂不回来
-- —— 又是一条"开关去不掉"。
local bus_written = setmetatable({}, { __mode = "k" })

-- 记一笔"我们刚写过这条总线"。除了本地台账，还写进受光面模块持有的**共享台账**
-- （M.NoteBusWrite）—— 两家 MountOK 认领残留时用的是同一份数据，免得各自演化。
-- 没有它也能工作（还有"现算方向"那两条判据），但本地台账是逐位的、不受
-- 太阳移动影响，共享之后两家的认领口径就完全一致了。
local function NoteBus(as, x, y)
    local rec = bus_written[as]
    if rec == nil then rec = {}; bus_written[as] = rec end
    rec.x, rec.y = x, y
    local SL = _G.package.loaded["bcas_surface_light"]
    if SL ~= nil and SL.NoteBusWrite ~= nil then
        pcall(SL.NoteBusWrite, as, x, y)
    end
end

-- 这一笔浮参是我们自己写的残留，还是外人在用这条总线？
--   ① 逐位等于"我们上次写的那一笔"（bus_written）；
--   ② 方向位等于**当前太阳方向** —— 受光面交还时写回来的就是它（PushSunTriple）；
--   ③ 方向位等于**当前共识方向** —— 夜里光源接管朝向时，受光面写回去的是
--      "太阳与灯光的混合"（同一个 M.WorldDirFor），与纯太阳差得可能很远，
--      只看 ② 会把它误判成外人 ⇒ 关一次开关就再也挂不回来（又一条"开关去不掉"）。
-- 三道判据都不成立才认定是外人（floater 组件的浮动、别的模组的着色器）。
-- 注意：判据里**没有任何开关**，只比对"当前世界状态算出来的值"。
local function BusIsOurs(as, fx, fy, inst)
    -- 第一判据走**共享**实现（受光面模块的 M.FloatsAreOurs）：两家认领的是同一条
    -- 总线上的同一笔残留，判据必须逐位一致。它会回头问 M.IsMounted（也就是下面
    -- 这几张表），不会递归。
    local SL = _G.package.loaded["bcas_surface_light"]
    if SL ~= nil and SL.FloatsAreOurs ~= nil then
        local oks, ours = pcall(SL.FloatsAreOurs, as, fx, fy, inst)
        if oks and ours == true then return true end
    end
    local rec = bus_written[as]
    -- ⚠ 2026-09-22：x 槽改成打包整数（PackX），rec.x 也是打包整数 ⇒ 按整数比。
    -- 老的 Ring(fx, rec.x) 是"当角度比"，打包值上万、取模之后没有意义。
    if rec ~= nil
        and math.abs(fx - rec.x) < 0.5 and math.abs(fy - rec.y) < 0.02 then
        return true
    end
    -- 先把 x 解回影子方位角（量化步长 0.088 度 ≪ 下面的 0.05 弧度容差）
    local ftheta = DecodeTheta(fx)
    if inst ~= nil then
        local lt, le = EntityDir(inst)
        if lt ~= nil and math.abs(Ring(ftheta, lt)) < 0.05
            and math.abs(fy + le) < 0.05 then
            return true
        end
    end
    local theta, el = M.SunParams()
    if type(theta) == "number" and type(el) == "number" then
        return math.abs(Ring(ftheta, theta)) < 0.05 and math.abs(fy + el) < 0.05
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 观察式让位（照抄 bcas_surface_light 的成熟结构）
-- ---------------------------------------------------------------------------
local function ExtRec(anim)
    local rec = external[anim]
    if rec == nil then
        rec = { effect = nil, x = 0, y = 0, z = 0 }
        external[anim] = rec
    end
    return rec
end

-- 辉光源记录表：谁自己挂了 bloom handle（火/萤火虫/发光皮肤），谁的颜色就
-- 必须留在 bloom 缓冲里给辉光管线用 —— 影子绝不抢它们。
-- ⚠ 引擎**没有** GetBloomEffectHandle 这个 getter（本机脚本 0 处使用），所以
-- "它有没有辉光句柄"只能靠观察：包住 setter 记下来。首轮实机"影子只在火上、
-- 灯变黑"就是这条检查缺位：火焰 FX 被当成普通实体挂上投影，辉光锥投影回
-- 自己身上，颜色又被光栅替换（2026-09-19 实机第二验）。
local function InstallHooks()
    if hooks_installed then return true end
    local api = _G.AnimState
    if type(api) ~= "table" then return false end
    local setfx, clearfx, setparams =
        api.SetDefaultEffectHandle, api.ClearDefaultEffectHandle, api.SetFloatParams
    local setbloom, clearbloom = api.SetBloomEffectHandle, api.ClearBloomEffectHandle
    if type(setfx) ~= "function" or type(clearfx) ~= "function" then return false end
    raw_setfx, raw_clearfx, raw_params = setfx, clearfx, setparams
    api.SetDefaultEffectHandle = function(anim, path, ...)
        local rec = ExtRec(anim)
        if mounted[anim] == nil then
            rec.effect = path
        end
        return setfx(anim, path, ...)
    end
    api.ClearDefaultEffectHandle = function(anim, ...)
        local rec = ExtRec(anim)
        rec.effect = nil
        return clearfx(anim, ...)
    end
    -- ⚠ 这里**故意不包** SetFloatParams：总线的观测者只能是受光面一家。
    -- 我们包一层就等于把自己的推送记成"外部写入"（受光面那边一比对就整片让位，
    -- 水印丢失 ⇒ 影子盖回本体），而且那个观察记录在本模块里没有任何读者。
    -- 保留 raw_params 只是为了 WriteBus 能绕开别人的钩子写。
    if type(setbloom) == "function" then
        raw_setbloom, raw_clearbloom = setbloom, clearbloom
        api.SetBloomEffectHandle = function(anim, path, ...)
            -- 我们自己的挂载走 raw（MountOne），走到这里的都是外部辉光源
            external_bloom[anim] = path or true
            if mounted[anim] ~= nil then
                -- 我们挂了之后它又自己挂辉光 ⇒ 让位（交还它的通道）
                local entry = mounted[anim]
                mounted[anim] = nil
                pcall(raw_clearbloom, anim)
            end
            return setbloom(anim, path, ...)
        end
        api.ClearBloomEffectHandle = function(anim, ...)
            external_bloom[anim] = nil
            return clearbloom(anim)
        end
    end
    hooks_installed = true
    return true
end

-- ---------------------------------------------------------------------------
-- 太阳参数（与 bcas_surface_light 同口径：相机空间方位角 theta）
-- ---------------------------------------------------------------------------
local function CameraHeading()
    local cam = _G.TheCamera
    if cam ~= nil then
        if cam.GetHeading ~= nil then
            local ok, h = pcall(cam.GetHeading, cam)
            if ok and type(h) == "number" then return h end
        elseif type(cam.heading) == "number" then
            return cam.heading
        end
    end
    return 45.0
end

-- 世界水平方向 → 相机坐标系下的方位角（与 surface_light.ThetaOf 逐字同口径）
local function ThetaOf(wx, wz)
    local hl = math.sqrt(wx * wx + wz * wz)
    if hl < 1e-6 then return 0.0 end
    local ux, uz = wx / hl, wz / hl
    local h = CameraHeading()
    local hr = h * DEG
    local rx, rz = math.cos((h + 90) * DEG), math.sin((h + 90) * DEG)
    local dx, dz = math.cos(hr), math.sin(hr)
    local t = math.atan2(ux * dx + uz * dz, ux * rx + uz * rz)
    if t < 0 then t = t + 2 * math.pi end
    return t
end

local function SunSystem()
    return _G.package.loaded["bcas_sun_emitter"]
end

-- 一条实体的"当前共识方向" → 总线口径 (theta, el)。
-- 算式**就是 bcas_surface_light.M.WorldDirFor**：太阳的世界单位向量 与 附近
-- 光源方向 按（白天因子 × 相干度）混合。权重只吃世界状态 ⇒ 与任何开关无关。
-- 拿不到受光面模块时返回 nil，调用方退回太阳的全局值。
EntityDir = function(inst)
    local SL = _G.package.loaded["bcas_surface_light"]
    if SL == nil or SL.SunWorldDir == nil or SL.WorldDirFor == nil then return nil end
    local oka, sx, sy, sz, day = pcall(SL.SunWorldDir)
    if not oka or type(sx) ~= "number" then return nil end
    local okb, wx, wy, wz = pcall(SL.WorldDirFor, inst, sx, sy, sz, day)
    if not okb or type(wx) ~= "number" then return nil end
    -- 角度折算也走对面的编码器：同一条路径，将来不会因为只改一边而两家跑偏。
    if SL.EncodeWorld ~= nil then
        local okc, t, e = pcall(SL.EncodeWorld, wx, wy, wz)
        if okc and type(t) == "number" and type(e) == "number" then return t, e end
    end
    if wx * wx + wz * wz < 1e-12 then return nil end
    local el = math.asin(math.max(-1.0, math.min(1.0, wy)))
    return ThetaOf(wx, wz), el
end

-- 白天：影向 = 日晷 rot（世界方位），转成 theta 后下发。
-- 返回 theta, el, day
function M.SunParams()
    local scale_y, rot, alpha = 1.5, 45, 0
    local S = SunSystem()
    if S ~= nil and S.GetSunParams ~= nil then
        local ok, sy, r, a = pcall(S.GetSunParams)
        if ok then
            if type(sy) == "number" and sy > 0 then scale_y = sy end
            if type(r) == "number" then rot = r end
            if type(a) == "number" then alpha = a end
        end
    end
    local el = math.atan(1.0 / math.max(scale_y, 0.35))
    -- 影向（世界）→ 太阳世界方向的反向 → theta
    local rad = rot * DEG
    local sx, sz = math.sin(rad), math.cos(rad)   -- 影子指向
    local theta = ThetaOf(-sx, -sz)              -- 太阳在影子的反侧
    local day = alpha / 0.50
    if day > 1 then day = 1 elseif day < 0 then day = 0 end
    if _G.TheWorld ~= nil and _G.TheWorld:HasTag("cave") then day = 0 end
    return theta, el, day
end

-- ---------------------------------------------------------------------------
-- 挂载
-- ---------------------------------------------------------------------------
local function MountOK(inst)
    if inst == nil or inst.prefab == nil then return false end
    if inst.AnimState == nil or inst.Transform == nil then return false end
    if inst.IsValid == nil or not inst:IsValid() then return false end
    if inst.IsInLimbo ~= nil then
        local okl, limbo = pcall(inst.IsInLimbo, inst)
        if okl and limbo == true then return false end
    end
    if inst.HasTag ~= nil then
        for _i, tag in ipairs(M.EXCLUDE_TAGS) do
            local okt, yes = pcall(inst.HasTag, inst, tag)
            if okt and yes == true then return false end
        end
    end
    -- prefab 名前缀兜底（同族实体 tag 收不全时的第二道）。取前缀而不是全名，
    -- 是因为海鱼/蟹王这些是一族很多个 prefab（oceanfish_small_1 …）。
    -- ⚠ 名单里**没有** boat/mast/sail：用户 2026-09-21「船不需要排除」。
    if type(inst.prefab) == "string" then
        for _i, pre in ipairs(M.EXCLUDE_PREFAB_PREFIX) do
            if string.sub(inst.prefab, 1, #pre) == pre then return false end
        end
    end
    -- 已经挂了**可见**着色器的实体不碰：那是受光面（我们自己）或其他模组；
    -- bloom 通道的 handle 是另一条通道（SetBloomEffectHandle），互不冲突。
    -- 受光面写的 FLOAT_PARAMS 正好也是本模块要的 theta/仰角口径，可以共用。
    local as = inst.AnimState
    -- 辉光源三重判定（命中任一就不碰 —— 它的颜色必须留给辉光管线）：
    --   ① 观察钩子记录过它自己挂了 bloom handle；
    --   ② 它开着一盏灯（玩家那盏默认关着不算，判据 = "这盏灯真的开着吗"）；
    --   ③（兜底）燃烧中。
    -- ⚠ 引擎没有 GetBloomEffectHandle 这个 getter，"有没有辉光句柄"只能靠
    --   InstallHooks 的观察记录 —— 首二验"影子只在火上、灯变黑"就是这里缺位：
    --   火焰 FX 被当成普通实体挂上投影，辉光锥投影回自己身上，颜色又被替换。
    if external_bloom[as] ~= nil then return false end
    if inst.Light ~= nil then
        local okl, on = pcall(inst.Light.IsEnabled, inst.Light)
        if okl and on == true then return false end
    end
    if inst.HasTag ~= nil then
        local okt, yes = pcall(inst.HasTag, inst, "burning")
        if okt and yes == true then return false end
    end
    -- 蒙皮变体没有 FLOAT_PARAMS 顶点绑定（读方向恒 0），不投
    if as.IsSkinned ~= nil then
        local oks, sk = pcall(as.IsSkinned, as)
        if oks and sk == true then return false end
    end
    -- FLOAT_PARAMS 归属：受光面管着的实体，浮参是我们这一套模块推的
    -- (theta, -el, -k)，正是投影要的口径 —— 必须挂（否则树全没影子）。
    -- 其余的实体里，只有**没人写过**的才安全：非零浮参说明有外人（floater 的
    -- 浮动、别的模组的着色器）在用这条总线，我们一写就把它顶掉，跳过。
    -- ⚠ 但必须认出**我们自己上一次留下的那一笔**（关影子/关受光面都会留下它，
    --   协议上绝不写零 —— 见 PushAll 的事故注释）：认不出来 = 开关一开一关之后
    --   这些实体永远挂不回来。判据在 BusIsOurs。
    local SunLight = _G.package.loaded["bcas_surface_light"]
    local surface_owns = false
    if SunLight ~= nil and SunLight.IsMounted ~= nil then
        local okm, m = pcall(SunLight.IsMounted, inst)
        if okm and m == true then surface_owns = true end
    end
    if not surface_owns and as.GetFloatParams ~= nil then
        local okf, fx, fy, fz = pcall(as.GetFloatParams, as)
        if okf and (fx ~= 0 or fy ~= 0 or fz ~= 0) then
            if not BusIsOurs(as, fx, fy, inst) then return false end
        end
    end
    return true
end

local function MountedCount()
    local n = 0
    for _ in pairs(mounted) do n = n + 1 end
    return n
end

-- 这条实体现在由影子模块接管吗？（受光面 MountOK 的①号判据要问它）
--
-- 两家共用同一条 FLOAT_PARAMS：影子先写下的那一笔（或受光面关掉时交还的那一笔）
-- 都是**非零**的，而"非零"正是双方 MountOK 用来认"外人占线"的信号 —— 少了归属
-- 判据，先挂上的一家会把另一家永久挡在门外（2026-09-20 用户报的"新进入的影子/
-- 立体光照精灵开关不生效"）。
function M.IsMounted(inst)
    if inst == nil or inst.AnimState == nil then return false end
    return mounted[inst.AnimState] ~= nil
end

local function MountOne(inst)
    local as = inst.AnimState
    if as == nil then return false end
    if not MountOK(inst) then return false end
    local path_ok, shader_path = pcall(_G.resolvefilepath, M.SHADER)
    if not path_ok or shader_path == nil then
        M._fails = (M._fails or 0) + 1
        return false
    end
    local ok = pcall(raw_setbloom or as.SetBloomEffectHandle, as, shader_path)
    if not ok then
        M._fails = (M._fails or 0) + 1
        if M._fails <= 3 then
            Log("挂载失败（" .. tostring(inst.prefab) .. "）")
        end
        return false
    end
    M._fails = 0
    mounted[as] = { inst = inst }
    mount_count = mount_count + 1
    return true
end

-- ---------------------------------------------------------------------------
-- 每拍：把"当前共识方向"推给已挂载的实体
-- ---------------------------------------------------------------------------
-- 方向随光源（2026-09-20 第三轮，用户指定保留的效果）：举火把/点灯笼时朝向由
-- 附近光源接管 —— 权重按世界状态（白天因子）连续加权，正午权重 0（只有太阳）。
-- 权重非零时方向**逐实体**不同（每条实体离灯远近不同），所以按实体解算，
-- 算式走受光面的 M.WorldDirFor（同一个函数 ⇒ 与受光面写进去的是同一个值）。
--
-- 省开销：白天（权重为 0）方向对所有实体是同一个全局值 ⇒ 一次算、全体推，
-- 推之前先比对上次的值（受光面那边的教训：8Hz × 上百实体的引擎调用是真实开销，
-- 也是刷日志事故的来源）。夜里关了"夜间影子"时影子根本不可见 ⇒ 整批不推。
local push_state = { theta = nil, el = nil, day = nil }
local push_tick = 0

-- 方向里**含灯贡献**的条目（8Hz 那一拍重建）。逐帧那一路只跑这几条 —— 见
-- PushAll 顶部那段"为什么逐帧只跑灯条目"。
local lit_list = {}

-- 判定"这一条方向被灯拉走了"的阈值。取得很小（0.11°）是有意的：它只是把
-- "灯到底有没有参与"这件事数字化，**不是**平滑阈值 —— 真正的推不推由
-- M.PUSH_EPS_AZ 决定。太小会把噪声当灯，太大（比如 1°）会让"灯只轻微参与"
-- 的实体掉出逐帧名单，重新变成逐格更新。
M.LIT_EPS_AZ = 0.002
M.LIT_EPS_EL = 0.002

-- 把一条实体的方向解出来并推上去。8Hz 全量与逐帧灯路径**共用这一段**，
-- 保证两条路的判据（pushing 阈值、版本号、BusZ 口径）完全一致。
--
-- per_entity：要不要为这条实体单独解算方向（读它的位置 + 混合所有灯）。
-- 返回 1 = 真的写了一次总线，0 = 没写；nil 语义不需要（失效条目在这里除名）。
local function PushOne(as, entry, theta, el, k, changed, per_entity)
    local inst = entry.inst
    if inst == nil or inst.IsValid == nil or not inst:IsValid() then
        mounted[as] = nil
        entry.lit = false
        return 0
    end
    local tx, te = theta, el
    local lit = false
    if per_entity then
        local lt, le = EntityDir(inst)
        if lt ~= nil then
            tx, te = lt, le
            -- 与太阳方向差得明显 ⇒ 这条实体的朝向被灯接管了 ⇒ 下一帧还要重算
            -- （灯在动，方向每帧都在变）。
            lit = math.abs(Ring(lt, theta)) > M.LIT_EPS_AZ
                or math.abs(le - el) > M.LIT_EPS_EL
        end
    end
    -- 只有真的逐条解算过才改这个标记：lit_only 的那条全量推（相机在转时的逐帧
    -- 兜底）对普通条目走的是"直接推全局方向"，它没有资格宣布"这条没被灯接管" ——
    -- 一旦在这里被清成 false，逐帧路径下几帧就再也不碰这条实体，夜里举灯走路
    -- 又退回每秒 8 格（用户报过的"不丝滑"）。
    if per_entity then entry.lit = lit end
    if changed or entry.pv ~= push_state.version or entry.px == nil
        or math.abs(Ring(tx, entry.px)) > M.PUSH_EPS_AZ
        or math.abs(te - (entry.py or te)) > M.PUSH_EPS_EL then
        -- z 槽 = 受光面方位角 θ_blend + 强度（打包；2026-09-21 起不再是"负数强度"）。
        -- 槽是共用的，两边必须写**逐位相同**的值：走 BusEncode（受光面模块的
        -- M.BusTriple 是唯一编码入口），y 槽同样打包（仰角 + 冷暖/对比滑条）。
        local bx, by, bz = BusEncode(inst, tx, te, k)
        if WriteBus(as, bx, by, bz) then
            -- 台账必须记**真正写进总线的那一笔**（bx/by 是打包值），不能记原始角度：
            -- 认领残留时是拿引擎读回来的 fx 跟这里逐位比的（bus_written 与共享台账
            -- bus_res 都是"总线上是什么"，不是"方向是多少"）。记原始角的话，自家的
            -- 残留会被判成外人占线 ⇒ 开关关一次就再也挂不回来。
            NoteBus(as, bx, by)
            entry.px, entry.py = tx, te
            entry.pv = push_state.version
            return 1
        end
        entry.pv = nil    -- 写失败：下一拍重试，别把版本记成"已推"
    else
        -- 本版本已核过这条实体（值没变）：记下版本，下一拍别重复解算。
        entry.pv = push_state.version
    end
    return 0
end

-- 全量推（8Hz 那一拍，以及"全局方向动了"那几帧的兜底）。两条路共用，保证
-- 判据（阈值、版本号、BusZ 口径、lit_list 重建/收尾）完全一致。
--
-- lit_only = true：逐条解算只做"方向里确实有灯"的条目，其余条目**直接推全局
-- 太阳方向**（一次 SetFloatParams，不读位置、不遍历光源）。相机在转时走的正是
-- 这条：我们要的是"theta 跟上当帧"，不是把每条实体重新解算一遍（那是 8Hz 的活，
-- 乘 60 帧就是掉帧）。
local function PushMounted(theta, el, k, changed, per_entity, lit_only)
    local n = 0
    local ln = 0
    for as, entry in pairs(mounted) do
        local pe = per_entity
        if pe and lit_only and entry.lit ~= true then pe = false end
        local r = PushOne(as, entry, theta, el, k, changed, pe)
        n = n + (r or 0)
        if entry.lit == true and entry.inst ~= nil then
            ln = ln + 1
            lit_list[ln] = entry
            entry.as = as
        end
    end
    -- 逐帧名单的尾巴要清掉（数组按下标消费，留着旧引用会让死实体一直挂在表里）
    for i = ln + 1, #lit_list do lit_list[i] = nil end
    if n > 0 then
        last_push = { theta = theta, el = el, day = k, n = n }
        push_tick = push_tick + 1
    end
    return n
end

local function PushAll(lite)
    -- FLOAT_PARAMS 是受光面与影子共用的总线。**影子端自己保证方向**：不按实体
    -- 归属分担、不读别人的状态、不看谁在推 —— 只要是我们挂着的实体，一律写
    -- 共识方向。
    --
    -- ⚠ 2026-09-20 实机事故后定版（用户原话：「开关物体立体光照影子朝向会变！」）：
    -- 旧版是"受光面管着这条实体就整个不推，交给它推"。而受光面在关掉/退出水印
    -- 模式时会往总线写 (0,0,0)（旧版那三条路径就是这么写的），影子端又有
    -- "值没变就不推"的优化 —— 于是这些实体的浮参永远停在 (0,0,0)，theta=0，
    -- 影子被甩到一个固定的错误方向再也回不来。根因不在推得对不对，而在**影子
    -- 的朝向被别人决定**。现在受光面那三条复位路径改写共识方向（PushSunTriple），
    -- 两边写进去的是同一个值，谁先谁后都无所谓。
    local theta, el, day = M.SunParams()
    -- 兜底（事故台账：日志 366 行 nil 比较）：日晷桩在任何异常路径下都不许
    -- 把 nil 送进比较/算术。
    theta, el, day = theta or 0, el or 0, day or 0
    -- 太阳落山后 k 本来就该是 0（原版口径）。旧版还挂了个 `not night_shadows`，
    -- 那是"夜间影子关着时浓度恒为 0、不值得算"时代的优化；现在夜间影子由
    -- **附近有没有光**决定（浓度在 bcas_state 算），这个开关不该再参与这里。
    local k = day
    if day <= 0.01 then k = 0 end
    local changed = push_state.theta == nil
        or math.abs(Ring(theta, push_state.theta)) > M.PUSH_EPS_AZ
        or math.abs(el - push_state.el) > M.PUSH_EPS_EL
        or math.abs(k - (push_state.day or 0)) > 0.004
    if changed then
        push_state.theta, push_state.el, push_state.day = theta, el, k
        push_state.version = (push_state.version or 0) + 1
    end
    -- 逐实体解算的时机：光源权重非零（day < M.SUN_LOCK）就逐条算。
    -- 旧版还要求 `day > 0.01 or night_shadows`：白天在阈值以上没问题，可**夜里
    -- day≈0**，这一项就退化成"必须开着夜间影子开关"，否则整批实体退回纯太阳方向 ——
    -- 用户报的"朝向完全钉死"就出在这里：方向解算一直是对的，只是被整段跳过了。
    local per_entity = day < M.SUN_LOCK

    -- ==== 逐帧模式（lite）：只跑"方向里有灯"的那几条 ====================
    --
    -- 病根（用户："带着辉光源移动…晚上影子跟随辉光产生移动的时候也不丝滑"）：
    -- 原来 PushAll 只在 8Hz 那一拍跑（modmain 只调了 Refresh），夜里举着灯走路
    -- 时"灯 → 物体"的方向被量化成每秒 8 格。
    --
    -- 但整批改成逐帧是不行的：per_entity 分支要为每一条读实体位置并遍历灯，
    -- 上百条 × 每秒 60 帧 = 把 8Hz 的活乘以 7.5。所以逐帧这一路只跑
    -- **lit_list**（方向确实被灯拉走的那些，通常是玩家身边十几条），方向=太阳的
    -- 那批由 `changed` 在 8Hz 那一拍推（太阳走得慢，8Hz 完全够）。
    --
    -- 灯位当帧化由 SL.SyncLights 负责（两个模块同帧只刷一次）。
    if lite then
        local n_lite = 0
        if #lit_list > 0 then
            local SL = _G.package.loaded["bcas_surface_light"]
            if SL ~= nil and SL.SyncLights ~= nil then pcall(SL.SyncLights) end
            for i = 1, #lit_list do
                local entry = lit_list[i]
                n_lite = n_lite + PushOne(entry.as, entry, theta, el, k, changed, true)
            end
        end
        -- 相机在转 / 太阳在走 ⇒ 全体条目手里那个 theta 都过期了 ⇒ 当帧推一遍。
        --
        -- 病根（用户："转视角会影子朝向变化"）：着色器每帧都用**当帧**的视图基
        -- 去重建 theta，而 theta 只有 8Hz 那一拍才推给这些实体 ⇒ 重建出来的世界
        -- 方向被甩了一个 (heading_now - heading_stale)，相机停下再弹回去。
        -- changed 由 M.PUSH_EPS_AZ（0.05 度）判定 ⇒ 相机不动时这条一次都不跑。
        if changed then
            n_lite = n_lite + PushMounted(theta, el, k, true, per_entity, true)
        end
        return n_lite
    end

    PushMounted(theta, el, k, changed, per_entity, false)
end

M.PUSH_EPS_AZ = 0.0009 -- 约0.05度（旧0.009=0.5度是"每3秒跳一格"的根因）
M.PUSH_EPS_EL = 0.0005 -- 约0.03度

-- ---------------------------------------------------------------------------
-- 扫描（分批挂载；照抄受光面的实机调校）
-- ---------------------------------------------------------------------------
local function SweepImpl()
    if not M.enabled then return end
    if not InstallHooks() then return end
    local player = _G.ThePlayer
    if player == nil or not player:IsValid() or _G.TheWorld == nil then return end
    local px, _py, pz = player.Transform:GetWorldPosition()
    local ents = _G.TheSim:FindEntities(px, 0, pz, M.RADIUS)
    local placed = 0
    for i = 1, #ents do
        local inst = ents[i]
        if inst ~= nil and inst.AnimState ~= nil and mounted[inst.AnimState] == nil then
            if MountOne(inst) then
                placed = placed + 1
                if placed >= M.MOUNT_PER_SWEEP then break end
            end
        end
        if MountedCount() >= M.MAX_MOUNTED then break end
        if M._fails >= M.MAX_FAILS then
            Log("连续挂载失败 " .. M.MAX_FAILS .. " 次，整体停用")
            M.enabled = false
            return
        end
    end
end

local function Sweep()
    return Guard("Sweep", SweepImpl)
end

M.Sweep = Sweep
-- modmain 顶层尽早调用：世界生成的实体在 playerhud 之前就挂辉光句柄，
-- 钩子装晚了观察不到（首二验"光源自己有影子"的根因之一）。
M.InstallHooksEarly = InstallHooks

function M.Refresh()
    return Guard("Refresh", function()
        if not M.enabled then return end
        sweep_tick = sweep_tick + 1
        if sweep_tick % 4 == 1 then SweepImpl() end
        PushAll()
    end)
end

-- 逐帧（modmain 的帧任务调）：只跑"方向里含灯"的那几条，见 PushAll 的 lite 分支。
-- 8Hz 那一拍 = M.Refresh()，跑全量并重建 lit_list。
function M.TickFrame()
    return Guard("TickFrame", function() return PushAll(true) end)
end

-- ---------------------------------------------------------------------------
-- 对外
-- ---------------------------------------------------------------------------
function M.SetEnabled(on)
    local want = on == true
    if want == M.enabled and logged_enabled == want then return end
    M.enabled = want
    if not M.enabled then
        for as, entry in pairs(mounted) do
            local inst = entry.inst
            if inst == nil or inst.IsValid == nil or not inst:IsValid() then
                mounted[as] = nil
            else
                pcall(raw_clearbloom or as.ClearBloomEffectHandle, as)
            end
        end
        mounted = setmetatable({}, { __mode = "k" })
        external = setmetatable({}, { __mode = "k" })
        for i = #lit_list, 1, -1 do lit_list[i] = nil end
        push_state.theta, push_state.el, push_state.day = nil, nil, nil
    end
    if logged_enabled ~= want then
        logged_enabled = want
        Log("已" .. (M.enabled and "启用" or "停用")
            .. "（已挂载 " .. tostring(MountedCount()) .. " 个）")
    end
end

-- 历史 API（旧版哑元池的不透明度倍率）：V16 起浓度完全在合成端
-- （State.PushShadow 每拍打包 BCAS_SHADOW.w），模块侧这个值没有消费者。
-- 保留是为了不破坏外部调试脚本与冒烟台断言；**不要**再让 State 调它。
function M.SetDensity(v)
    M.density = math.max(0, math.min(1, tonumber(v) or 1.0))
end

function M.SetNightShadows(on)
    night_shadows = on == true
    push_state.day = nil   -- 强制下一拍重推
end

function M.Info()
    local theta, el, day = M.SunParams()
    local line = string.format(
        "启用=%s 已挂载=%d（累计 %d 让位 %d）| 太阳屏幕横位=%+.3f 顺逆光=%+.3f 仰角=%.1f° 白天因子=%.3f 夜影=%s",
        tostring(M.enabled), MountedCount(), mount_count, yield_count,
        math.cos(theta), math.sin(theta), el / DEG, day,
        night_shadows and "开" or "关")
    print("[BCAS] 地面投影自检: " .. line)
    if last_push ~= nil then
        print(string.format("[BCAS] 地面投影上次上报: 实体=%d 横位=%+.3f 仰角=%.1f° 白天=%.3f",
            last_push.n or 0, math.cos(last_push.theta), last_push.el / DEG, last_push.day))
    end
    return line
end

-- 调试：把光栅直接画到屏幕上（面板 DEBUG 用；0 = 关）
function M.SetDebug(n)
    M.debug = tonumber(n) or 0
end

return M
