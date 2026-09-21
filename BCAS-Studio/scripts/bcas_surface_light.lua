--[[ BCAS Studio —— 物体立体光照（v11 阶段一）

把**引擎自己的**实体可见着色器换成 bcas_surface_light.ksh：迎光面暖亮、背光面冷暗，
晨昏偏金、正午偏中性、夜里随满月转冷。光源固定在世界里 —— 相机转，亮面会换到
朝光的那一侧（光源没有任何移动），这就是"不能转动就变"的另一半。

2026-09-17：**着色主体换成 daylight_architecture（时光建筑 v1.2.0）的那套精灵浮雕
方向光**（作者已同意搬运；DA_ApplySunlight / DA_LOCAL_METRES 逐字移植，见
tools/make_surface_light_shader.py）。它比我们上一版自写的好处：
  * 法线是"符号自己的局部度量"（离纵轴的水平偏移 + 离原点的高度），所以树冠/屋顶
    自然朝上、侧面自然朝外，不会像径向伪法线那样把整棵树当成一根圆柱；
  * 背光侧只是"克制地压暗"，并用 pigment 门保住 Klei 的墨线（贴图本来就黑的地方
    不参与提亮，不会糊上一层脏色）；
  * 强度 = 0 就完全等于原版结果，所以夜里只要把强度压到 0 就等于全还原。

**三路输入**（用户要的"根据日晷 / 光源 / 光束改变受光背光"）：
  1. 日晷（太阳）：方位 → 方向；仰角 → DA 的 elevation（低太阳=强对比+金色）；
     日晷浓度 alpha → 白天因子，夜里自然淡出。
  2. 附近光源（火堆/提灯/自己挂的辉光）：按距离平方衰减累加**照度**，只改强度
     k，**永不改方向**（2026-09-20 第二轮：影子与受光面共用 FLOAT_PARAMS，
     方向一旦被火把拉走，地面影子就跟着转 —— 见 LightStrengthFor 的说明）。
  3. 透云光束（lightrays 实体）：**它是"阳光落在这一片"，不是点光源** ——
     绝不参与方向混合（否则树会朝着光斑转），只把该处的强度抬上去
     （被光柱罩住的物体对比更强、更金）。

太阳怎么进着色器：`AnimState:SetFloatParams(x, y, z)` → 着色器里的 `FLOAT_PARAMS`（vec3）。
引擎自己对这个通道有两个分支，**都只在正值时生效**：
    VS: if (FLOAT_PARAMS.z > 0.0)   → 上下浮动（浮动文字在用）
    PS: if (FLOAT_PARAMS.y > 0.0)   → 低于 FLOAT_PARAMS.x 的高度直接 discard
所以我们的编码全部取负，天然避开这两条：FLOAT_PARAMS = (方位 az, -仰角 el, -强度 k)。

着色器由 tools/make_surface_light_shader.py 从引擎的 anim.ksh / anim_skinned.ksh 派生，
只做锚点注入，其余逐字保留（透明度/皮肤/光照贴图/发光都不受影响）。

挂载是**分批**的：一次 Sweep 只挂 MOUNT_PER_SWEEP 个。一次性给上百个实体换
DefaultEffectHandle 会让引擎在同一帧里编译大量着色器变体（卡顿甚至卡死），
所以这里宁可慢几秒挂完，也不允许单帧爆发。名单外的一律不碰。
]]

local M = {
    enabled = true,
    -- 站立物水印模式（影子豁免门的写入端，2026-09-19）：受光面被关掉但地面
    -- 影子还开着时，本模块继续给实体挂着色器 —— 换成 mark 变体（引擎 anim
    -- 逐字 + 水印位，观感逐位等于原版）。理由：实体像素上的水印是合成端
    -- 唯一能分辨"影子里面的地面 / 挡在影子前面的本体"的信息，交还引擎原版
    -- 就等于把水印擦掉，影子立刻重新盖到施影者自己身上（BUG①）。
    mark_mode = false,
    strength = 1.0,        -- 面板滑条（0~1），实际强度还要乘日晷的"白天因子"
    PREFABS = {            -- 阶段一先按名单验证（一棵树、一个箱子），稳定后再放开
        "evergreen", "evergreen_sparse",
        "evergreen_short", "evergreen_normal", "evergreen_tall",
        "evergreen_sparse_short", "evergreen_sparse_normal", "evergreen_sparse_tall",
        "deciduoustree", "deciduoustree_normal", "deciduoustree_tall",
        "chest", "icebox", "cookpot", "tent", "treasurechest",
    },
    -- ==== 每次扫描最多挂几个（2026-09-19 三轮实机：用户要"当场就丝滑"）====
    -- 原话："我带上光源，树木和物体是先整体亮了，过一两秒才出来背光和受光，
    -- 转动也是变化有延迟，你这个得出来就丝滑的变才对。"
    --
    -- 那 1~2 秒的来源是**三处叠加**（都在这一个挂载链上）：
    --   ① RebuildLights（发现灯）每 4 次 8Hz 才跑一次 ⇒ 2Hz ⇒ 最坏 0.5s
    --   ② 每次只挂 MOUNT_PER_SWEEP 个 ⇒ 原来 2 个 × 2Hz = 每秒 4 个实体
    --      （玩家一举灯，视野里几十棵树要十几秒才全部换上着色器 —— 最致命的一环）
    --   ③ 刚挂上的实体要等下一拍才推参数 ⇒ 再多 0.125s，而这一帧它渲染的是
    --      没有受光信息的默认值（看起来就是"先整体亮、之后才出明暗"）
    -- ① 改到每次（去掉 % 4）、② 提到 12、③ 见 M.Apply 里"挂上即推一次"。
    -- 为什么不能无限提：一次性给上百个实体换 DefaultEffectHandle 会让引擎在
    -- 同一帧编译大量着色器变体（卡顿甚至卡死，文件头有记录）。12 个/次 × 2Hz
    -- = 每秒 24 个，几十个实体的场景 2~3 秒内铺满，和影子模块同量级
    -- （那边是 PER_SWEEP=12、SWEEP_FRAMES=15），而单帧负担仍然受控。
    MOUNT_PER_SWEEP = 12,
    MAX_MOUNTED = 400,     -- 总量保险丝
    RADIUS = 45,           -- 只挂玩家附近（阶段三换成视锥）
    MAX_FAILS = 5,         -- 连续挂载失败到这个次数就整个关掉（宁可没有，不要崩）
    -- 附近光源参与"该朝哪边亮"的方向混合（触及范围；引擎真实照亮仍按 Light 半径）
    -- ==== 光源的影响范围（2026-09-19 三轮实机：用户要"圆形、别像手电筒"）====
    -- 原话："光应该是圆形影响范围而且没怎么短了，你这个就变成了手电筒逻辑，
    -- 光不是完全直射的。"
    --
    -- 旧值 6×2.2 = 13.2 码：火把（半径 4）在 8 码外就完全不影响受光面了，
    -- 而玩家在游戏里隔着十几码看一棵树是很平常的视角 —— 于是"走近才有反应、
    -- 远了完全没光照"，读起来就像一支手电筒（只有正对着的那一小块亮）。
    -- 现在把保底半径提到 9、倍率提到 2.6：火把 → 23.4 码，火堆（半径 ~7）→ 18.2 码。
    -- 数值上限受引擎自己照亮范围约束（Light 半径之外引擎本来也不照亮），
    -- 这里给的是"受光面朝向"的影响域，所以可以比引擎的照亮半径宽。
    LIGHT_MIN_REACH = 9,
    LIGHT_REACH_MUL = 2.6,
    LIGHT_GAIN = 1.6,
    LIGHT_MAX_TRACK = 6,   -- 每次上报最多跟几个光源（按权重取前几名）
    LIGHT_MOVE_EPS = 1.0,  -- 玩家移动超过这个距离就立刻重选跟踪的光源
    -- 方向参与量（LIGHT_DAY_MIN / SuppressOf）已**整条退役**（2026-09-20 第三轮）：
    -- 光源对方向的参与量与白天因子相乘的那套写法，无论下限取多少，都只是把
    -- "影子朝向随火把转"的量调小 —— 黄昏、洞穴、以及 shadow_day 读不到的路径上
    -- 仍然会转（用户一开关受光面就看见）。现在光源**只进强度 k**，方向恒等于太阳，
    -- 与白天因子/shadow_day 完全无关。
    -- 透云光束（lightrays）：不参与方向，只把"被光柱罩住"的物体的对比抬起来。
    -- 强度 = 面板 × 白天因子 × (1 + BEAM_GAIN × 光柱可见度)，上限 DA 的 1.5。
    BEAM_GAIN = 0.55,
    BEAM_RADIUS_MUL = 1.0, -- 光柱 Light 半径的倍数（8 × 1.0 = 8 码内算"罩住"）
    K_MAX = 1.5,           -- 强度上限（DA 那套公式的适用范围）
    -- 均匀曝光增益（2026-09-18 二轮反馈"两个辉光源互相抢"）：多盏灯**从不同方向**
    -- 照到同一个物体时，受光面不该只认最强那一盏（会互相抢、还会左右跳），
    -- 而应该整体均匀提亮。做法见 LightDirFor：累加各灯方向向量，两盏对面灯
    -- 自然抵消（coh→0），抵消掉的那部分能量改加到**强度**上，于是"哪都被照到"
    -- 变成"整个都被均匀曝光"。单灯时 coh=1，这一项恒为 0（不影响既有观感）。
    UNIFORM_GAIN = 0.85,
    -- 参数没变就不推的阈值（**都是弧度** / 强度）；见 RefreshImpl 铁律②
    -- 0.0087 rad ≈ 0.5°，0.005 rad ≈ 0.3°。
    -- 注意 PUSH_EPS_AZ 现在是**角度**阈值：旧编码里 az 是 [-1,1] 的余弦分量，
    -- 同一个 0.0087 在那里是"约 0.5°"的近似（近 0 处余弦变化慢），
    -- 换成真正的角度之后它才是精确的 0.5°。数值不用改，语义变清晰了。
    PUSH_EPS_AZ = 0.0087,
    PUSH_EPS_EL = 0.005,
    PUSH_EPS_K = 0.004,
}

local _G = rawget(_G, "GLOBAL") or _G
local DEG = _G.DEGREES or (math.pi / 180)
local mounted = setmetatable({}, { __mode = "k" })   -- AnimState -> entry
local mount_count = 0        -- 累计成功挂载次数
local fail_count = 0
local sweep_tick = 0
local last_push = nil
local logged_enabled = nil
local warned = {}            -- 每个入口只报一次内部错误，避免刷屏

-- ==== 让位协议（观察式） ===================================================
-- 从"只挂 16 个 prefab 的白名单"放开到"全部实体"之后，最大的风险不是画错，
-- 而是**把别人的特效顶掉**：FLOAT_PARAMS / effect handle 是共享通道，
-- 浮空物品（components/floater.lua 会写 SetFloatParams(-0.05,1,percent)）、
-- 其它模组的实体着色器都要用。以前白名单小，撞上的概率低；现在必须正面处理。
--
-- 做法直接照搬 daylight_architecture 的 Controller:InstallHooks（已在它源码里
-- 验证过的路子）：把 AnimState 的三个 setter 包一层，**只做观测** —— 外部任何
-- 写入都记进 external 弱键表；我们自己的写入一律走捕获下来的原始函数，
-- 所以不会把自己记成"外部写入"。发现自己占用的实体被外部改过，立刻交还。
--
-- 为什么比"注册表 + pcall"更彻底：注册表只能防**已知**的几种抢占者，
-- 而这三个 setter 是唯一的入口，包住它们就等于"任何"外部写入都看得见。
local external = setmetatable({}, { __mode = "k" })  -- AnimState -> {effect,x,y,z}
local raw_setfx, raw_clearfx, raw_params
local hooks_installed = false
local yield_count = 0        -- 因为被外部抢占而交还的次数（Info 里报，便于排查）
local ours_rescue = 0        -- 认出"自己人残留"而放行挂载的次数（Info 里报，便于排查）
local bus_self = 0           -- "自己人正在写总线"的深度（影子模块进出时 ±1）

-- ==== 共享总线的"自己人残留"台账（弱键：实体消失自动回收）================
--
-- 病因（2026-09-20 实机，用户第二次报"开关不生效"）：FLOAT_PARAMS 是**两家共用**
-- 的一条通道 —— 影子模块读它的 x/y 当方向，受光面写它。而这套协议里**谁都不许
-- 写零**（写零会把影子的方向永久甩到 theta=0，见 PushSunTriple 的注释），于是
-- "关掉受光面"这个动作本身就会在原位留下一笔**非零**浮参：
--   SetEnabled(false) → PushSunTriple(as, inst) 写回共识方向 → mounted 表清空
-- 紧接着再打开开关，Sweep 重新扫到这些实体，而 MountOK 只看到"浮参非零"，
-- 就把**我们自己刚刚交还的那一笔**当成外人占线，一条都挂不回来
-- —— 开关从此对这一整批实体永久失效，只有等它们死掉（AnimState 重建）才恢复。
--
-- 同一个坑影子模块早就踩过并修好了（bcas_shadow_proj.lua 的 BusIsOurs，注释：
-- "认不出来 = 开关一开一关之后这些实体永远挂不回来"）—— 受光面这边当时漏了。
-- 于是**同一条判据在这里补上**，并且做成**两家共用**的一份（M.FloatsAreOurs），
-- 免得两个模块各自演化又跑偏。
--
-- 判据里**没有任何开关**（只比对"当前世界状态算出来的方向"），这一点是硬要求：
-- 一旦开关进了方向算式，就会出现"关掉受光面影子朝向跟着变"那类症状。
local bus_res = setmetatable({}, { __mode = "k" })   -- AnimState -> {x,y}

-- 记下我们（本模块）对这条总线写的最后一笔。所有对外写入都必须经过
-- OurParams / PushSunTriple，所以这一个入口就够了。
function M.NoteBusWrite(as, x, y)
    if as == nil or type(x) ~= "number" or type(y) ~= "number" then return end
    local rec = bus_res[as]
    if rec == nil then
        rec = { x = x, y = y }
        bus_res[as] = rec
    else
        rec.x, rec.y = x, y
    end
end

-- 影子模块写 FLOAT_PARAMS 之前/之后各调一次（它抓到的 raw 有可能就是我们这一层，
-- 取决于两家谁先装钩子；那种情况下它必须自报家门，否则我们会把自己人的写入
-- 记成"外部抢占" ⇒ 整片受光面让位 ⇒ 水印丢失 ⇒ 影子重新盖回本体 = BUG①）。
--
-- ⚠ 为什么不能再用"共享全局标记"（老写法 `_G.BCAS_BUS_SELF`，2026-09-20 实机炸掉的原因）：
-- DST 的 scripts/strict.lua 给 _G 挂了 __index/__newindex ——
--   · **读**一个没声明过的全局：当场 `error("variable 'X' is not declared")`。
--     受光面这边就是在钩子里读到它，错误冒到 update.lua，客户端直接重启（用户报"炸了"）；
--   · **写**一个没声明过的全局：同样 error（"assign to undeclared variable"）。
--     影子那边那笔写在 pcall 里，于是**静默失败**：标记永远是 nil ⇒ 这条防线
--     在实机上从来没有生效过（冒烟台当时没抓到，因为桩引擎里根本没有 AnimState 表，
--     钩子装不上、这一整段代码没被执行过）。
-- 计数器放在模块表上：只有真正的字段读写，任何环境都不可能抛错；而且它只认
-- "影子和受光面是同一个模组的两个模块"这一件事，不往游戏全局命名空间里塞名字。
function M.BusSelfEnter()
    bus_self = bus_self + 1
end

function M.BusSelfLeave()
    if bus_self > 0 then bus_self = bus_self - 1 end
end

-- 只给测试用：进出必须成对，收尾时必须是 0（漏掉 Leave 会让受光面永远看不见抢占）。
function M.BusSelfDepth()
    return bus_self
end

-- 环形比较（角度跨 ±π）
local function Ring(a, b)
    local d = a - b
    if d > math.pi then d = d - 2 * math.pi
    elseif d < -math.pi then d = d + 2 * math.pi end
    return d
end

-- 这一笔浮参是"我们自己人"留下的，还是外人在用这条总线？
--   ① 影子模块正管着这条实体 —— 它写的是与受光面**逐位相同**的共识方向
--      （影子那边也是调 M.WorldDirFor + M.EncodeWorld，同一条路径）。
--      判据是"模块归属表"，不是开关：影子关掉时它的 mounted 会清空，
--      这时落到 ②/③/④ 继续认。
--   ② 逐位等于本模块上一次写的那一笔（关开关留下的残留走这条）。
--   ③ 方向位等于**现算的共识方向**（太阳 × 白天因子 与 附近光源 的混合）——
--      与 PushSunTriple / ComputeEntry 同一个算式，且不吃任何开关。
--   ④ 方向位等于**纯太阳方向** —— 影子那边给的判据里有这一条，两边保持一致。
-- 四条都不成立才认定是外人（floater 的 (-0.05,1,percent)、别的模组的着色器）。
--
-- 注：floater 写的是 y = +1（float 百分比），而我们这边的 y = -仰角 恒 ≤ 0，
-- 所以④不会把它误认成自己人。
function M.FloatsAreOurs(as, fx, fy, inst)
    if type(fx) ~= "number" or type(fy) ~= "number" then return false end
    -- ① 影子模块的归属表
    local SP = _G.package.loaded["bcas_shadow_proj"]
    if SP ~= nil and SP.IsMounted ~= nil and inst ~= nil then
        local okm, m = pcall(SP.IsMounted, inst)
        if okm and m == true then return true end
    end
    -- ② 我们自己上一笔（弱键表；关/开一轮之后靠它认领）
    --    ⚠ 2026-09-22：x 槽改成打包整数（见 M.PackX），rec.x 记的也是打包整数，
    --    所以这里按**整数**比。老的 Ring(fx, rec.x) 是"当角度比"，打包值上万、
    --    取模之后没有意义，会把我们自己写的那一笔判成外人 ⇒ 交还引擎、水印丢失。
    local rec = bus_res[as]
    if rec ~= nil
        and math.abs(fx - rec.x) < 0.5 and math.abs(fy - rec.y) < 0.02 then
        return true
    end
    if inst == nil then return false end
    -- 先把 x 解回影子方位角（量化步长 0.088 度，远小于下面的 0.05 弧度容差）
    local ftheta = M.DecodeTheta(fx)
    -- ③ 现算共识方向（太阳 + 附近光源，白天因子加权）
    if M.SunWorldDir ~= nil and M.WorldDirFor ~= nil and M.EncodeWorld ~= nil then
        local oka, sx, sy, sz, day = pcall(M.SunWorldDir)
        if oka and type(sx) == "number" then
            local okb, wx, wy, wz = pcall(M.WorldDirFor, inst, sx, sy, sz, day)
            if okb and type(wx) == "number" then
                local okc, t, e = pcall(M.EncodeWorld, wx, wy, wz)
                if okc and type(t) == "number" and type(e) == "number"
                    and math.abs(Ring(ftheta, t)) < 0.05 and math.abs(fy + e) < 0.05 then
                    return true
                end
            end
        end
    end
    -- ④ 纯太阳方向（影子那边 BusIsOurs 的第三条，口径一致）
    local oks, theta, el = pcall(M.SunParams)
    if oks and type(theta) == "number" and type(el) == "number" then
        return math.abs(Ring(ftheta, theta)) < 0.05 and math.abs(fy + el) < 0.05
    end
    return false
end

-- 共享总线（FLOAT_PARAMS）的"复位"写法：**方向只由太阳决定**。
--
-- 前向声明：函数体写在文件后半（它要用 LightStrengthFor 与 M.SunParams），而
-- 上面的 YieldTo 与文件末尾的 SetEnabled / SetMarkMode 都要用它。必须写成
-- `PushSunTriple = function` 而不是 `local function` —— 后者会另起一个新的
-- 局部变量，把这个前向声明遮成永远为 nil（tools/check_forward_refs.py 会报）。
local PushSunTriple

local function ExtRec(as)
    local rec = external[as]
    if rec == nil then
        rec = { effect = nil, x = 0, y = 0, z = 0 }
        external[as] = rec
    end
    return rec
end

-- 我们自己的写入：带上 raw_* 走，不进 external。
-- 句柄没捕获到（引擎不开放 AnimState 表）时**退回实例方法** —— 同一个道理
-- 在 M.Apply 里已经做过（`raw_setfx or as.SetDefaultEffectHandle`）。少了这条
-- 回退，"挂得上去、摘不下来"就会真的发生：切换开关时本次交还静默失败，
-- 实体永远留着我们的着色器 —— 用户报的"很多开关功能去不掉"里就有它一份。
local function OurSetFx(as, path)
    if raw_setfx ~= nil then return raw_setfx(as, path) end
    local m = as.SetDefaultEffectHandle
    if m ~= nil then return m(as, path) end
    return nil
end
local function OurClearFx(as)
    if raw_clearfx ~= nil then return raw_clearfx(as) end
    local m = as.ClearDefaultEffectHandle
    if m ~= nil then return m(as) end
    return nil
end
local function OurParams(as, x, y, z)
    -- 记进"自己人残留"台账（M.NoteBusWrite）：关掉受光面时交还的这一笔非零方向
    -- 就是靠它认回来的（否则再打开开关，MountOK 会把我们自己的旧值当成外人）。
    -- 写在 pcall 之外不行、写在里面也不行：只有真写成功了才该记账 ——
    -- 所以放在调用返回之后、且在调用方 pcall 之外（调用方一出错就整条跳过）。
    local ok, a, b, c
    if raw_params ~= nil then
        ok, a, b, c = pcall(raw_params, as, x, y, z)
    else
        local m = as.SetFloatParams
        if m == nil then return nil end
        ok, a, b, c = pcall(m, as, x, y, z)
    end
    if not ok then error(a, 0) end
    M.NoteBusWrite(as, x, y)
    return a, b, c
end

local hook_fail_logged = false

-- 辉光体台账（BUG③，2026-09-20 第四轮实机定位）：
--   「辉光变黑的毛病我好像发现是开启物体立体光照就会这样，暗面精灵似乎跑到了
--     辉光灯光上」
-- 引擎/预制体会给"自己就是光"的实体挂 bloom 句柄（鬼魂、阿比盖尔、月眼守卫…），
-- 它们的精灵本身就是辉光来源。受光面一开，DA 的明暗乘法就加到这块精灵上 ⇒
-- 辉光被压暗 = 用户看到的"变黑"。判据见 M.IsGlowSource。
--
-- 观察方式与影子模块的 external_bloom 同一套路（链式包装，各自调用前一层），
-- 且**必须是链式**：谁先装钩子都能工作。写入端只有我们的影子投影句柄会被过滤掉
-- （影子模块用 raw_setbloom 写，但如果它比我们后装，那个 raw 就是我们的包装）。
local glow_src = setmetatable({}, { __mode = "k" })
local glow_filtered_warned = false

-- 这个实体是不是"光本身"（自发光）？两条判据，都刻意保守：
--   ① 引擎 bloom 句柄：只有引擎/预制体自己挂得出来的东西（anim_bloom_ghost 之类）
--      才进台账 —— 精灵即光源，任何情况下都不该被加暗面。
--   ② 引擎灯（inst.entity:AddLight() ⇒ inst.Light）+ **不是玩家/鬼魂**：玩家的
--      playerlight 是引擎给的行走照明，玩家的精灵仍然要受光面（主角最显眼，
--      误伤它比漏判一个灯笼严重得多）。
function M.IsGlowSource(inst)
    if inst == nil then return false end
    local as = inst.AnimState
    if as ~= nil and glow_src[as] == true then return true end
    if inst.Light ~= nil then
        if inst.HasTag ~= nil then
            if inst:HasTag("player") or inst:HasTag("playerghost") then return false end
        end
        return true
    end
    return false
end

-- 注意：这里**不能**用 Log（它声明在文件后面，读到的是 nil —— 正是 v11 实机
-- 崩溃的同一类错误，check_forward_refs.py 会当场报红）。同一句话不会刷屏
-- （hook_fail_logged 只放行一次），直接 print 即可。
local function HookFailNote()
    if hook_fail_logged then return end
    hook_fail_logged = true
    print("[BCAS] 物体光照: 未接管 AnimState setter（引擎不开放）："
        .. "改走实例方法，让位协议不可用（功能不受影响）")
end

local function InstallHooks()
    if hooks_installed then return true end
    local api = _G.AnimState
    if type(api) ~= "table" then
        HookFailNote()
        return false
    end
    local setfx, clearfx, setparams =
        api.SetDefaultEffectHandle, api.ClearDefaultEffectHandle, api.SetFloatParams
    if type(setfx) ~= "function" or type(clearfx) ~= "function"
        or type(setparams) ~= "function" then
        HookFailNote()
        return false
    end
    raw_setfx, raw_clearfx, raw_params = setfx, clearfx, setparams
    api.SetDefaultEffectHandle = function(anim, path, ...)
        local rec = ExtRec(anim)
        rec.effect = path
        -- 我们正占着这个 AnimState（说明它自己也在挂）→ 记下来，下一拍交还
        rec.stolen = true
        return setfx(anim, path, ...)
    end
    api.ClearDefaultEffectHandle = function(anim, ...)
        local rec = ExtRec(anim)
        rec.effect = nil
        rec.stolen = true
        return clearfx(anim, ...)
    end
    api.SetFloatParams = function(anim, x, y, z, ...)
        -- 自己人写的总线不算"被外部抢占"：影子模块每次推方向都会经过这里
        -- （它抓到的 raw 可能就是我们这一层，取决于谁先装钩子），它在写之前
        -- 会调 M.BusSelfEnter()、写完调 M.BusSelfLeave()。少了这一条，影子推一次
        -- 方向就会被判成抢占 ⇒ 整片受光面让位 ⇒ 水印丢失 ⇒ 影子重新盖回本体（BUG①）。
        -- ⚠ 这里以前读的是全局 `_G.BCAS_BUS_SELF` —— 在 strict.lua 下**读**未声明的
        -- 全局会当场抛错（2026-09-20 实机：bcas_glint 每次写浮参都 LUA ERROR 刷屏），
        -- 现在改成模块表上的深度计数（见 M.BusSelfEnter 上的注释）。
        if bus_self > 0 then
            return setparams(anim, x, y, z, ...)
        end
        local rec = ExtRec(anim)
        rec.x, rec.y, rec.z = x or 0, y or 0, z or 0
        rec.stolen = true
        return setparams(anim, x, y, z, ...)
    end
    hooks_installed = true
    -- 辉光体观察（BUG③）：链式包装 bloom 句柄 setter。过滤掉**我们自己的**
    -- 影子投影句柄，否则影子挂上去的实体会被误判成辉光体（那样它们的受光面
    -- 会全部关掉）—— 无论两个模块谁先装钩子都要成立。
    local setbloom, clearbloom = api.SetBloomEffectHandle, api.ClearBloomEffectHandle
    if type(setbloom) == "function" then
        api.SetBloomEffectHandle = function(anim, path, ...)
            local ours = path == "shaders/bcas_shadow_proj.ksh"
                or path == "shaders/bcas_shadow_proj_skinned.ksh"
            if path ~= nil and not ours then
                glow_src[anim] = true
            end
            return setbloom(anim, path, ...)
        end
    elseif not glow_filtered_warned then
        glow_filtered_warned = true
        print("[BCAS] 物体光照: 引擎不开放 SetBloomEffectHandle，辉光体只靠 Light 判据")
    end
    if type(clearbloom) == "function" then
        api.ClearBloomEffectHandle = function(anim, ...)
            glow_src[anim] = nil
            return clearbloom(anim, ...)
        end
    end
    return true
end

-- 让位：把 effect handle 与浮参还给对方（用原始函数写，不再触发观测）
--
-- ⚠ 交还的是**句柄**，不是"影子朝向"。FLOAT_PARAMS 是受光面与影子共用的总线，
-- 影子的顶点着色器只读 x/y（太阳方位），所以交还时写回去的必须仍是纯太阳参数。
-- 旧版这里把观测到的外部值（rec.x/y/z）原样写回 —— 等于让"抢占者手里的那个数"
-- 决定影子朝向（可能是 (0,0,0)，也可能是别人动画的别的语义：floater 组件就写
-- (-0.05, 1, percent)）。这是"开关一下/被抢占一下，影子朝向就变了"的最后一条来源。
--
-- 失效实体一律不碰（铁律①）：对已经离开世界的 AnimState 每次调用都会刷一行
-- Stale Component Reference，旧版这里无条件写参数，正是那条日志的一个来源。
local function YieldTo(as)
    local entry = mounted[as]
    local inst = entry ~= nil and entry.inst or nil
    mounted[as] = nil
    external[as] = nil
    if inst ~= nil and inst.IsValid ~= nil and inst:IsValid() then
        pcall(OurClearFx, as)
        PushSunTriple(as, inst)
    end
    yield_count = yield_count + 1
end

local function Log(msg)
    print("[BCAS] 物体光照: " .. tostring(msg))
end

-- 兜底：模块对外入口一律不许把错误抛给调用方。
-- 调用点在 playerhud 构造和 8Hz 周期任务里，这两处的错会一路冒到
-- update.lua（strict.lua 的老账：未声明的全局写入），客户端直接崩 —— 宁可
-- 功能降级并留一行日志，也不能崩。
local function Guard(name, fn)
    local ok, a, b = pcall(fn)
    if not ok then
        if not warned[name] then
            warned[name] = true
            Log("内部错误（已兜住，只降级本功能）: " .. name .. ": " .. tostring(a))
        end
        return false, nil
    end
    return true, a, b
end

-- 受光面挂载判据（2026-09-18 起**不再用 prefab 白名单**）。
--
-- 用户当时的要求是"全部实体都要有受光背光"，白名单（原来只有 16 个 prefab：
-- 常青树/桦树/箱子/冰箱/锅/帐篷）显然做不到 —— 日志里"累计挂载 145"就是白名单
-- 铺满的上限。现在的判据改成**按类别排除**（和影子模块、以及 daylight_architecture
-- 自己的 `Controller:Eligible` 同一个思路）：默认全都要，只把"不该换着色器的"剔掉。
--
-- 排除项逐个都有理由：
--   FX / INLIMBO      —— 特效件、已经离场的；INLIMBO 的 AnimState 推参数会刷日志
--   DECOR / placer    —— 纯装饰、蓝图预览（跟着鼠标跑，不该受太阳影响）
--   inventoryitem     —— 背包里的物品（不在世界里，渲染路径也不同）
--   playerghost       —— 灵魂态（原版刻意让它半透明无光照）
--   burnt / burning   —— 烧毁/燃烧中的物件：引擎自己会改它的着色与颜色
--   NOCLICK 不再排除（引擎自己会给一些正常物件加它，排掉会漏一堆）
--   "player" 也**不排除**：用户明确要求人物有受光面，而且它的 AnimState 路径
--     和生物一样（B4 之后玩家在影子那边也是走普通路径）。
-- 另外还有一条**运行时**排除（在 MountOK 里）：实体已经挂了别人的 effect handle
-- 就不碰 —— FLOAT_PARAMS 是共享通道，抢过来会把对方的效果顶掉（DA 也这么做）。
-- 「船」黑名单（用户 2026-09-21：「"船"这个实体，他部件非常多，我们应该把实体光照
-- 黑名单给他，不然很怪」）。
--
-- 标签取自游戏自己的 prefab 源码（scripts.zip / prefabs/*.lua 里的 AddTag，逐个核过）：
--   boat.lua        -> boat, boatbuilder, CLASSIFIED, NOBLOCK, NOCLICK, ...
--   mast.lua        -> mast, boat_accessory, deploykititem, structure, ...
--   boat_bumpers    -> boatbumper, mustforceattack, walkableperipheral
--   boat_cannon     -> boatcannon        boat_leak    -> boatleak
--   boat_magnet     -> boatmagnet        boatpatch    -> boat_patch
--   boatrace_*      -> boatracecheckpoint / boatrace_proximitychecker /
--                      boatrace_proximitybeacon
-- 所以既有"整条船的一部分"标签，也有名字前缀兜底（见 EXCLUDE_PREFAB_PREFIX）：
-- 以后新增的 boat_* 部件不改这里也能被拦住。锚（anchor.lua）只带 structure，
-- 靠名字前缀 anchor 拦。
M.EXCLUDE_TAGS = { "FX", "INLIMBO", "DECOR", "placer", "inventoryitem",
                   "playerghost", "burnt", "burning",
                   -- 船与船的部件（多部件各画一层受光面会互相打架 = "很怪"）
                   "boat", "boatbuilder", "boat_accessory", "boatbumper",
                   "boatcannon", "boatleak", "boatmagnet", "boatmagnetbeacon",
                   "boat_patch", "mast",
                   "boatracecheckpoint", "boatrace_proximitychecker",
                   "boatrace_proximitybeacon" }

-- 名字前缀兜底：船体与部件的 prefab 名都在这些前缀下（boat/mast/sail/anchor/
-- keel/boatpatch），新增部件不改标签表也能拦住。
M.EXCLUDE_PREFAB_PREFIX = { "boat", "mast", "sail", "anchor", "keel" }

-- 这个实体适不适合换受光面着色器（纯判据，不写引擎）
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
    -- 名字前缀兜底（船体/桅/帆/锚/龙骨，见 EXCLUDE_PREFAB_PREFIX 的说明）
    for _i, pre in ipairs(M.EXCLUDE_PREFAB_PREFIX) do
        if string.sub(inst.prefab, 1, #pre) == pre then return false end
    end
    -- 已经挂了别人的特效/浮参就不抢（FLOAT_PARAMS 共享；floater 组件、
    -- 以及其它模组都会写它）。两条都是"读得到才判"：引擎没暴露 getter 时
    -- 这两个 if 直接跳过，真正的兜底交给让位协议（挂上之后被抢占就交还）。
    if inst.AnimState.GetDefaultEffectHandle ~= nil then
        local okh, h = pcall(inst.AnimState.GetDefaultEffectHandle, inst.AnimState)
        if okh and h ~= nil then return false end
    end
    -- ⚠ 浮参非零**不能**等同"外人占线"：我们自己交还时写回的就是一笔非零的
    -- 共识方向（协议上不许写零，见 PushSunTriple），影子模块也往同一条通道写
    -- 它的方向。旧版这里直接 `return false`，于是"关一次再打开"或"影子先挂上"
    -- 的实体**永远**挂不回来 —— 用户报的正是它：
    --   「很多开关功能去不掉」「开关不生效（物体立体光照精灵、新进入的影子）」
    -- 所以先问 M.FloatsAreOurs："这一笔是自己人留的吗？" 只有确认是外人才拒。
    if inst.AnimState.GetFloatParams ~= nil then
        local okf, fx, fy, fz = pcall(inst.AnimState.GetFloatParams, inst.AnimState)
        if okf and (fx ~= 0 or fy ~= 0 or fz ~= 0) then
            if not M.FloatsAreOurs(inst.AnimState, fx, fy, inst) then return false end
            ours_rescue = ours_rescue + 1
        end
    end
    return true
end

local function MountedCount()
    local n = 0
    for _ in pairs(mounted) do n = n + 1 end
    return n
end

local function PlayerPos()
    local p = _G.ThePlayer
    if p == nil or p.Transform == nil then return nil end
    local ok, x, _y, z = pcall(p.Transform.GetWorldPosition, p.Transform)
    if not ok then return nil end
    return x, z
end

function M.HandlePath()
    return _G.resolvefilepath("shaders/bcas_surface_light.ksh")
end

-- mark 变体（水印专用）：引擎 anim/skinned 逐字 + 蓝通道 ±4/255 屏幕棋盘水印，
-- 不注入任何光照。见 M.SetMarkMode 与 tools/make_surface_light_shader.py。
function M.MarkPath()
    return _G.resolvefilepath("shaders/bcas_surface_mark.ksh")
end

-- 是否处在"会往实体上挂着色器"的状态：受光面开着，或者水印模式（受光面关、
-- 影子还开着）。挂载/补挂/换着色器一律以它为准。
local function MountingActive()
    return M.enabled == true or M.mark_mode == true
end

-- 把已挂载的实体整体换成另一套着色器（受光面 ↔ mark）。已经离开世界的直接
-- 除名（铁律①：绝不再碰失效 AnimState）。参数版本作废，下一拍按需重推。
--
-- 走 OurSetFx（带"引擎不开放 AnimState 表"时的实例方法回退）。旧写法是
-- `if raw_setfx == nil then return end` + 裸调 raw_setfx：没有钩子的环境里
-- **整批换不成**（静默 no-op），于是"关受光面 ⇒ 换水印"这条路断掉 ——
-- 水印没了，影子又盖回本体（BUG① 的回归入口），甚至 pcall 吞掉后毫无痕迹。
local function SwapMountedPath(path)
    for as, entry in pairs(mounted) do
        local inst = entry.inst
        if inst == nil or inst.IsValid == nil or not inst:IsValid() then
            mounted[as] = nil
        else
            pcall(OurSetFx, as, path)
            entry.pv = nil
        end
    end
end

-- 给一个实体换上立体光照着色器（幂等；重复调用只记一次）
-- ==== 挂上就得当帧生效（2026-09-19 三轮实机："先整体亮，过一两秒才出背光和受光"）====
--
-- 病因：挂载与上报本来是分开的两件事 —— Sweep 里给实体换上新着色器，但它要等
-- **下一拍** 8Hz 才拿到自己的 (θ, el, k)。那一拍里它渲染的是引擎默认值，也就是
-- 用户看到的"先整体亮一下，之后才出现明暗"。
--
-- 治法：挂载的同一个函数里就把这一条算好推上去，出场第一帧就是正确的受光/背光。
-- 那个"算一条"的函数体写在文件后面（它要用 LightDirFor / EncodeDir / SunRaw，
-- 而它们都定义在本行之后）—— 所以这里只做**前向声明**，与 SweepImpl 同一个套路。
-- 直接在这里调用会读到 nil：那是 v11 实机崩溃的同一类错误，
-- tools/check_forward_refs.py 会当场报出来。
local PushEntryNow

function M.Apply(inst)
    if not MountingActive() then return false end
    if not MountOK(inst) then return false end
    local as = inst.AnimState
    if mounted[as] then return false end
    if not hooks_installed then InstallHooks() end
    -- 用**原始** setter 写入（OurSetFx），这样不会被自己的钩子记成"外部写入"；
    -- 钩子没装上（引擎不给改 AnimState 表）时它自己退回实例方法 —— 功能照旧，
    -- 只是拿不到让位协议（那种环境里本来也没有别的抢占者）。
    -- 受光面关着（水印模式）时挂 mark 变体：参数 k=0 由 SunParams 保证，
    -- 着色器只带水印位，观感 = 原版 + 合成端可见的站立物标记。
    local path = M.enabled and M.HandlePath() or M.MarkPath()
    local ok, err = pcall(OurSetFx, as, path)
    if not ok then
        fail_count = fail_count + 1
        if fail_count <= M.MAX_FAILS then
            Log("挂载失败(" .. fail_count .. "/" .. M.MAX_FAILS .. "): " .. tostring(err))
        end
        if fail_count >= M.MAX_FAILS then
            M.enabled = false
            Log("连续挂载失败，已整个停用物体光照（不影响其它功能）")
        end
        return false
    end
    -- 存条目（不直接存实体）：推参数时要按它算"附近光源"的方向，
    -- 同时记下上一次推过的值，值没变就整条跳过（见 RefreshImpl 里的两条铁律）
    local entry = { inst = inst }
    mounted[as] = entry
    -- 这一条我们从"空白"接管，所以清掉它可能残留的观测记录：
    -- 否则入场那一刻看到的自己人（external 里的旧账）会被判成"被抢占"而立刻交还。
    external[as] = nil
    mount_count = mount_count + 1
    -- **当帧就把参数推上去**：否则这一条要等到下一拍 8Hz 才有受光信息，
    -- 那一帧渲染的是引擎默认值 —— 用户看到的"先整体亮、过一两秒才出明暗"。
    -- 出错只影响这一条（推不上去就等下一拍照旧补），绝不冒给调用方。
    if PushEntryNow ~= nil then pcall(PushEntryNow, as, entry) end
    return true
end

-- 这一条的参数跟上一次比，变了没有？（太阳方位按环形比较）
-- 阈值取得很小（0.5° / 0.3° / 0.004），肉眼看不出来，但白天不动时能整片跳过。
local function NearEnough(entry, az, el, k)
    local daz = math.abs(az - entry.az)
    if daz > math.pi then daz = 2 * math.pi - daz end
    return daz <= M.PUSH_EPS_AZ
        and math.abs(el - entry.el) <= M.PUSH_EPS_EL
        and math.abs(k - (entry.k or 0)) <= M.PUSH_EPS_K
end

-- 相机 heading（度）。拿不到就退回 45（引擎自己的默认值）—— 方向略偏，但绝不失效。
-- 抽成单独函数是因为现在有**两个**地方要用它：相机右轴（左右）与相机朝向（顺逆光），
-- 两处必须读**同一个** heading，否则同一个物体上"左右"和"前后"会来自两个不同的机位。
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

-- 相机右轴（世界（x,z）分量）。取法直接照抄引擎自己：
--   followcamera.lua:GetRightVec() = (cos(heading+90°), 0, sin(heading+90°))
local function CameraRightXZ()
    local r = (CameraHeading() + 90.0) * DEG
    return math.cos(r), math.sin(r)
end

-- 世界水平方向 → **相机坐标下的方位角 θ**（弧度，[0, 2π)）。
--
-- ==== 为什么传角度，而不是投影分量（2026-09-19）====
-- 旧编码只传 `sun_x = dot(S, 相机右轴)` —— 太阳方向在**一根**轴上的投影，
-- **丢掉了"朝里/朝外"那一维**。后果就是用户报的：
-- "光在物体后面、我把视角转到物体这边，受光应该看不见、整个都背光，但现在是
--  依然会左边或者右边受光" —— 着色器只有左右信息，永远不知道自己在看背光面。
--
-- 相机右轴 R 与"朝观察者"轴 D 是**正交**的，而 θ 一个角就把两个分量都给全了：
--     cos θ = dot(S, R) = sun_x        （左右）
--     sin θ = dot(S, D) = facing       （正 = 光在相机这侧 = 看见受光面；
--                                       负 = 光在物体另一侧 = **逆光**）
-- 而且 cos²+sin² ≡ 1，两个分量**永远自洽**，不会"左右对了、前后错了"。
-- 仿真里逐角核对：cos θ 与旧 sun_x 误差 1.3e-15，sin θ 与 dot(S,GetDownVec) 1.4e-15。
--
-- 为什么不"位打包一个符号位"：GLSL ES 1.00 没有位运算，解包要用 floor/mod 拼算术，
-- 又丑又易错；传角度在着色器里只要 cos/sin 两个内建函数，且不受 [-1,1] 量程截断影响。
--
-- ⚠ 别再用日晷的 GetSunScreenUV 反推相机轴。它返回的是 `u = 0.5 + radius*sin(rot+180−heading)`,
-- 那是**表盘指针的摆位**（HUD 上那个太阳指针画在哪），不是太阳在屏幕上的投影。
-- 两者只在离散的特殊角巧合相等（rot=45+180k 或 heading=−45+180k 时）——
-- 2026-09-18 的"斜轴受光面不转"就是踩了这个坑：参照值恰好在 rot=45° 上与真值同值，
-- 于是符号翻反也一路绿灯。正道只有一条：**用引擎自己的相机基算**。
--
-- 顺带修好一处陈年小瑕疵：NearEnough 里的环形比较（`daz > π` 那段）在旧口径
-- （sun_x ∈ [-1,1]，范围不足 π）下是**死代码**；换成角度后它才真正起作用。
-- 世界水平方向 → **相机坐标下的太阳方位角 θ**（弧度，[0, 2π)）。
--
-- ==== 为什么改成传角度，而不是继续传 sun_x（2026-09-19）====
-- 旧编码只传 `sun_x = dot(S, 相机右轴)` —— 那是太阳方向在**二维**里的一根轴上的
-- 投影，**丢掉了"朝里/朝外"这一维**。后果就是用户报的：
-- "光在物体后面、我把视角转到物体这边，受光应该看不见、整个都背光，但现在是
--  依然会左边或者右边受光" —— 着色器只有左右信息，永远不知道自己在看背光面。
--
-- 关键：相机右轴 R 与"朝观察者"轴 D 是**正交**的，而 θ 一个角就把两个分量都给全了：
--     cos θ = dot(S, R) = sun_x        （左右）
--     sin θ = dot(S, D) = facing       （正 = 光在相机这侧 = 看见受光面；
--                                       负 = 光在物体另一侧 = **逆光**）
-- 而且 cos²+sin² ≡ 1，所以两个分量**永远自洽**，不会出现"左右对了、前后错了"。
-- 仿真里逐角核对过：cos θ 与旧 sun_x 误差 1.3e-15，sin θ 与 dot(S,GetDownVec) 误差 1.4e-15。
--
-- 为什么不"位打包一个符号位"：GLSL ES 1.00 **没有位运算**，解包得用 floor/mod 拼算术，
-- 又丑又容易错；而传角度在着色器里只要 cos/sin 两个内建函数，
-- 且天然没有量程截断问题（angle 不受 clamp 到 [-1,1] 的影响）。
--
-- D 用引擎权威定义：followcamera.lua:GetDownVec() = (cos h, sin h)（由场景指向相机）。
-- （独立交叉验证：视线 view = (−cos h, −sin h)，dot(S,view) = −facing，严格互反。）
--
-- 顺带修好一处陈年小瑕疵：NearEnough 里的环形比较（`daz > π` 那段）在旧口径
-- （sun_x ∈ [-1,1]）下是**死代码**；换成角度后它才真正起作用。
local function ThetaOf(wx, wz)
    local hl = math.sqrt(wx * wx + wz * wz)
    if hl < 1e-6 then return 0.0 end
    local ux, uz = wx / hl, wz / hl
    local rx, rz = CameraRightXZ()
    local h = CameraHeading()
    local hr = h * DEG
    local dx, dz = math.cos(hr), math.sin(hr)     -- = GetDownVec()
    local sun_x = ux * rx + uz * rz               -- 左右分量
    local facing = ux * dx + uz * dz              -- 顺逆光分量
    local t = math.atan2(facing, sun_x)
    if t < 0 then t = t + 2 * math.pi end
    return t
end

-- 日晷原始参数（影长系数 scale_y / 影子方向 rot / 浓度 alpha），带兜底。
-- 单独拎出来是为了让"太阳编码"与"光源混合"两处读的是**同一份**原始值 ——
-- 两边各读一次的话，一旦日晷中途换参，同一帧里会算出两个不同的太阳方向。
local function SunRaw()
    local SunSystem = _G.package.loaded["bcas_sun_emitter"]
    local scale_y, rot, alpha = 1.5, 45, 0
    if SunSystem ~= nil and SunSystem.GetSunParams ~= nil then
        local ok, sy, r, a = pcall(SunSystem.GetSunParams)
        if ok then
            if type(sy) == "number" and sy > 0 then scale_y = sy end
            if type(r) == "number" then rot = r end
            if type(a) == "number" then alpha = a end
        elseif not warned["sun"] then
            -- 日晷抛错时这里会**静默**退回默认参数（alpha=0 ⇒ 强度 0 ⇒ 整条效果消失）。
            -- 只降级不报错是对的，但一声不响就没法查了：面板看着"开着"却毫无变化，
            -- 现场只能靠猜。所以留一行（只报一次），把"为什么没效果"写进日志。
            warned["sun"] = true
            Log("日晷取参失败，本帧退回默认（物体光照暂时无效）: " .. tostring(sy))
        end
    end
    return scale_y, rot, alpha
end

-- 太阳 → 着色器参数。返回 theta, el, k, day
--   theta = **相机坐标系下的太阳方位角**（弧度）。旧版这里返回的是 sun_x
--           （屏幕横向分量，-1..1）；2026-09-19 换成角度，因为 sun_x 丢掉了
--           "顺光/逆光"那一维，导致逆光时物体仍然左右受光。着色器用
--           cos(theta)/sin(theta) 同时拿到左右与顺逆光 —— 见 ThetaOf 的完整说明。
--   el    = 太阳仰角：日晷的影长系数 scale_y = 1/tan(el)（这条关系已由冒烟台核对）
--   k     = 强度 = 面板滑条 × 白天因子（夜里淡出；满月仍有月光方向）
--   day   = 白天因子（0=夜，1=正午）
--
-- 为什么必须在 Lua 算（2026-09-18 实机反馈"斜角不转、只有东南西北转"）：
--   上一版把**方位角**传下去，让着色器自己用"精灵自身的右轴"折算出屏幕横向分量。
--   但多面向/四面向实体的精灵右轴是**量化**的（只取 4 个朝向），相机停在斜角时
--   它纹丝不动 ⇒ 受光面卡在上一档；转到正东南西北才跳一下。实机现象完全吻合。
--   而且像素舞台这条路上**拿不到任何相机矩阵**：anim.ksh 的 PS 名单里没有
--   CAMERARIGHT 也没有 MatrixV（MatrixV 只在顶点舞台绑定；anim_skinned.ksh 连
--   顶点舞台都没有它）。所以"在着色器里还原相机右轴"根本无解 —— 唯一正解就是
--   在 Lua 侧算好，这也正是 DA 自己的做法。
function M.SunParams()
    local scale_y, rot, alpha = SunRaw()
    local el = math.atan(1.0 / scale_y)
    local day = alpha / 0.50                      -- 0.5 = 日晷的白天满档
    if day > 1 then day = 1 elseif day < 0 then day = 0 end
    local k = (M.strength or 1.0) * day
    if not M.enabled then k = 0 end
    -- 世界太阳的水平方向：日晷的 rot 是**影子**指向，太阳在反方向（+180°）
    local a = (rot + 180.0) * DEG
    return ThetaOf(math.sin(a), math.cos(a)), el, k, day
end

-- 前向声明：RefreshImpl 里要用 SweepImpl，声明不能晚于使用点。
-- 注意：下面**必须**写 `function SweepImpl()` 而不是 `local function SweepImpl()`
-- —— 后者会再声明一个新的局部变量把这里遮掉，前向声明永远是 nil
-- （Refresh 里的自动补挂就会一直报 "attempt to call upvalue 'SweepImpl'"）。
local SweepImpl

-- 附近光源扫描（火堆/灯笼/辉光/自己挂的辉光源）：一次遍历 Ents，只收开着灯的。
-- 存的是**实体**（不是坐标快照）—— 位置每次上报都现读，所以举着火把走近，
-- 物体受光面在下一拍（8Hz ≈ 0.125s）就转过去。重活（遍历 Ents）仍然 2Hz 一次。
-- 注意：DS 里的火把 Light:GetRadius() 很小（≈4），直接拿它当"有效半径"会导致
-- 举着火把"没反应"，所以触及半径取 max(半径, LIGHT_MIN_REACH) * LIGHT_REACH_MUL。
-- 这只影响**方向混合**，引擎真实照亮仍按 Light 自己的半径走。
local lights = {}            -- { inst=光源实体, r=触及半径, w=权重 }
local tracked = {}           -- 每次上报要读位置的光源（≤ LIGHT_MAX_TRACK 个）
local beams = {}             -- 透云光柱：只给强度增益，绝不进方向池
local last_pick = { x = nil, z = nil }

-- 这条实体是不是"透云光束"（我们自己在 bcas_sun_emitter 里造的 lightrays）。
-- 判据用引擎标签，不认 prefab 名 —— 光束/光源都可能是模组加进来的。
local function IsBeam(inst)
    if inst == nil or inst.HasTag == nil then return false end
    local ok, yes = pcall(inst.HasTag, inst, "lightrays")
    return ok and yes == true
end

-- 读一条光柱的位置与"这一刻有多亮"（_vis，光柱在明灭）。
-- 重建时立刻读一次：否则新建的光柱要等下一拍才有坐标，罩在里面的实体会
-- 每 2 秒闪一下（1.5 ↔ 1.0 强度跳变）。
local function ReadBeam(b)
    local linst = b.inst
    if linst == nil or linst.Transform == nil
        or linst.IsValid == nil or not linst:IsValid() then
        b.x = nil
        return
    end
    local oko, lx, _ly, lz = pcall(linst.Transform.GetWorldPosition, linst.Transform)
    if oko and lx ~= nil then
        b.x, b.z = lx, lz
    else
        b.x = nil
    end
    if type(linst._vis) == "number" then b.vis = linst._vis end
end

local function RebuildLights()
    for i = #lights, 1, -1 do lights[i] = nil end
    for i = #beams, 1, -1 do beams[i] = nil end
    local Ents = _G.Ents
    if Ents == nil then return end
    for _, inst in pairs(Ents) do
        local L = inst ~= nil and inst.Light or nil
        if L ~= nil and inst.Transform ~= nil and inst.IsValid ~= nil and inst:IsValid() then
            local on = true
            if L.IsEnabled ~= nil then
                local oke, en = pcall(L.IsEnabled, L)
                if oke then on = en ~= false end
            end
            if on then
                local r = 4
                if L.GetRadius ~= nil then
                    local okr, rr = pcall(L.GetRadius, L)
                    if okr and type(rr) == "number" and rr > 0 then r = rr end
                end
                if IsBeam(inst) then
                    -- 透云光柱：它是"阳光落在这一片"，方向归太阳。只登记位置/半径，
                    -- 供 BeamGain 用；绝不进 lights（否则树会朝着光斑转过去）。
                    local b = { inst = inst, r = r * M.BEAM_RADIUS_MUL, vis = 1 }
                    ReadBeam(b)
                    beams[#beams + 1] = b
                else
                    local br = 1
                    if L.GetColour ~= nil then
                        local okc, cr, cg, cb = pcall(L.GetColour, L)
                        if okc and type(cr) == "number" and type(cg) == "number" then
                            br = 0.30 * cr + 0.60 * cg + 0.10 * (cb or cg)
                        end
                    end
                    if br > 0.02 then
                        local reach = math.max(r, M.LIGHT_MIN_REACH) * M.LIGHT_REACH_MUL
                        lights[#lights + 1] = { inst = inst, r = reach, w = br * M.LIGHT_GAIN }
                    end
                end
            end
        end
    end
    last_pick.x, last_pick.z = nil, nil      -- 逼 PickTracked 立刻重选
end

-- 选出这次要跟的光源：离玩家够近 + 按权重取前几名（每帧位置现读，重活只做一次）
local function PickTracked(px, pz)
    for i = #tracked, 1, -1 do tracked[i] = nil end
    if #lights == 0 then return end
    local cand, nc = {}, 0
    for i = 1, #lights do
        local l = lights[i]
        local linst = l.inst
        if linst ~= nil and linst.Transform ~= nil and linst:IsValid() then
            local oko, lx, ly, lz = pcall(linst.Transform.GetWorldPosition, linst.Transform)
            if oko and lx ~= nil then
                local near = true
                if px ~= nil then
                    local dx, dz = lx - px, lz - pz
                    local reach = l.r + M.RADIUS
                    near = dx * dx + dz * dz <= reach * reach
                end
                if near then
                    nc = nc + 1
                    cand[nc] = { inst = linst, x = lx, y = ly, z = lz, r = l.r, w = l.w }
                end
            end
        end
    end
    table.sort(cand, function(a, b) return a.w > b.w end)
    local n = 0
    for i = 1, nc do
        if n >= M.LIGHT_MAX_TRACK then break end
        n = n + 1
        tracked[n] = cand[i]
    end
end

local function RefreshTracked()
    for i = 1, #tracked do
        local t = tracked[i]
        local linst = t.inst
        if linst ~= nil and linst.Transform ~= nil and linst:IsValid() then
            local oko, lx, ly, lz = pcall(linst.Transform.GetWorldPosition, linst.Transform)
            if oko and lx ~= nil then
                t.x, t.y, t.z = lx, ly, lz
            end
        else
            t.x = nil
        end
    end
    -- 光柱位置与可见度同样每拍现读（光柱在漂、在明灭）
    for i = 1, #beams do
        ReadBeam(beams[i])
    end
end

-- ==== 灯位"当帧化"：逐帧把这个跟踪表刷成**当前**位置 =========================
--
-- 病根（2026-09-21 用户第二次报："带着辉光源移动的时候他转换的时候一卡一卡
-- 不丝滑，包括晚上影子跟随辉光产生移动的时候也不丝滑"）：
--
-- 灯位原来只在 8Hz 那一拍读一次（RefreshImpl → RefreshTracked）。而玩家手里的
-- 火把/提灯是**连续移动**的，于是"灯 → 物体"的方向被量化成每秒 8 格 —— 逐帧那
-- 一路（M.TickFrame）虽然每帧都在跑，手里拿的却是上一拍缓存下来的**世界方向**
-- （它只重投影屏幕角，见 TickFrame 里的说明），所以横向转视角是平滑的，灯一移动
-- 就是一顿一顿的。这不是刷新率不够，是**数据源本身是陈旧的**：把 8Hz 的采样插值
-- 到 60Hz 也补不回那 0.125 秒里丢掉的相位。
--
-- 治法：把"读跟踪光源的位置"提到逐帧。它只有 ≤ M.LIGHT_MAX_TRACK 次
-- GetWorldPosition，是这条链上最便宜的一段；真正贵的**遍历 Ents / 重选跟踪目标**
-- （RebuildLights / PickTracked）仍然留在 8Hz 那一拍，一步不动。
--
-- 帧戳：受光面与影子两个模块都会调这个入口（影子那边每帧 PushAll 也要吃新鲜
-- 灯位），谁先跑都行，同一帧最多刷一次。
local light_stamp = nil
function M.SyncLights()
    if #tracked == 0 then return end
    local t = nil
    if _G.GetTime ~= nil then
        local ok, v = pcall(_G.GetTime)
        if ok and type(v) == "number" then t = v end
    end
    if t ~= nil then
        if t == light_stamp then return end
        light_stamp = t
    end
    RefreshTracked()
end

-- 这个坐标被光柱罩住了多少（0~1，"罩住"= 在光柱 Light 半径内）。
-- 注意：只用来抬强度，不参与方向 —— 见文件头"三路输入"第 3 条。
local function BeamGain(x, z)
    local g = 0
    for i = 1, #beams do
        local b = beams[i]
        if b.x ~= nil then
            local dx, dz = b.x - x, b.z - z
            if dx * dx + dz * dz <= b.r * b.r then
                local v = b.vis or 1
                if v > g then g = v end
            end
        end
    end
    return g
end

-- 给一个实体算"该有多亮"（照度 nk）与"光在哪一边"（合矢量方向）。
--
-- 2026-09-20 第三轮定稿 —— 两条用户反馈必须**同时**成立：
--   ① "我让你把那个跟随受光背光判断影子的去掉你没去！开关物体立体光照影子朝向会变！"
--   ② "哦对，之前那个是有根据玩家举着的火把或者其他辉光源来给影子朝向的，
--       那个不用删，那个效果还挺好"
-- 看着矛盾，其实指向同一件事：**方向可以跟光源走，但绝不能跟开关走**。
-- 第二轮为了满足①把方向里的光源权重整个删了，等于连②一起删掉；现在按
-- "权重只吃世界状态"重做：
--
--   · 方向权重 = LightWeight(白天因子) × coh，**纯世界函数**。白天因子来自日晷
--     （alpha/0.5，洞穴里日晷本身就是 0），coh 来自光源几何。影子/受光/水印/
--     夜间影子这些**开关**一律不出现在这条路径上。旧版的 (1-day)*(1-shadow_day)
--     里的 shadow_day 就是病灶：它随开关变，方向随它跳。
--   · 这条方向的唯一解算入口是 M.WorldDirFor，受光面（ComputeEntry）与地面影子
--     （bcas_shadow_proj 的 PushAll）都调它 ⇒ 写进 FLOAT_PARAMS 的 x/y **逐位相同**，
--     谁先谁后、哪个开关开着，结果都一样。
--   · 白天权重 0 ⇒ 正午举火把方向不动（"影子像风车"不复现）；日落后太阳淡出、
--     火光自然接管 ⇒ 用户要的"举火把给朝向"回来了。
--
-- 注意：这里累加的是**世界空间**的矢量和，屏幕量一律由调用方用相机基现投影 ——
-- 相机轴只在 Lua 侧拿得到，着色器里没有。
local function LightStrengthFor(inst, k)
    if #tracked == 0 then return nil end
    local ok, ex, ey, ez = pcall(inst.Transform.GetWorldPosition, inst.Transform)
    if not ok or ex == nil then return nil end
    -- **矢量和**，不是"取最强那一盏"。
    --
    -- 2026-09-18 二轮反馈：'如果有两个辉光源的话逻辑会不对，它会互相抢，
    -- 要么左边要么右边要么中间直接覆盖，但是如果它哪都被照到，
    -- 它应该是直接整个都被均匀曝光。'
    -- 旧实现是 `if w > bw then bw = w; dir = 这一盏` —— 只留**一盏**的朝向，
    -- 于是两盏灯一左一右时受光面只会指向更强的那一边（"互相抢"）；
    -- 而且当两盏一样强时会随浮点抖动来回换边（画面跳）。
    --
    -- 物理上正确的做法是把各灯的贡献**累加**：
    --   · 累加方向向量 → 两盏对面灯互相抵消 ⇒ 没有朝向偏好（不再抢）；
    --   · 同时记下总照度 → 抵消时照度仍然很大 ⇒ 整个物体**均匀提亮**。
    -- 于是"哪都被照到"自然变成"整体均匀曝光"，正是要的行为。
    -- coh（相干度 = 合矢量长度 ÷ 总照度）就是"有多偏向一边"：
    -- 单灯 ≈ 1，对面两灯 ≈ 0。
    local ax, ay, az, tw = 0.0, 0.0, 0.0, 0.0
    for i = 1, #tracked do
        local l = tracked[i]
        if l.x ~= nil then
            local dx, dz = l.x - ex, l.z - ez
            local d2 = dx * dx + dz * dz
            if d2 <= l.r * l.r then
                local dist = math.sqrt(d2)
                -- **平滑衰减，不是线性削到 0**（2026-09-19 三轮实机）。
                -- 线性衰减 + 平方之后，2/3 半径处的权重只剩 ~0.11 —— 视觉上就是
                -- "只有贴到跟前才亮"，也就是用户说的手电筒感。真实点光源的照度是
                -- 1/d²，但在"物体 + 几码外一盏灯"这个尺度上直接用 1/d² 又会衰减
                -- 得太快，所以取一条**慢于线性**的曲线：smoothstep 到 0.45 处，
                -- 之后走一条尾巴，保证"最后几个码"是渐隐而不是断崖（断崖会让
                -- 玩家走过某个半径时看到物体"啪"地换个亮法）。
                local t = dist / l.r
                local near_k = 1.0 - (t * t * (3 - 2 * t) * 0.72 + t * 0.28)
                if near_k < 0 then near_k = 0 end
                local w = l.w * near_k * near_k             -- 仍平方一次：权重是"照度"，不是朝向
                if w > 1e-4 then
                local dy = (l.y - ey) + 0.5               -- 抬一点，别正好在同一个高度
                    local ll = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if ll > 1e-4 then
                        ax = ax + (dx / ll) * w
                        ay = ay + (dy / ll) * w
                        az = az + (dz / ll) * w
                        tw = tw + w
                    end
                end
            end
        end
    end
    if tw <= 1e-4 then return nil end
    local alen = math.sqrt(ax * ax + ay * ay + az * az)
    local coh = alen / tw                    -- 0 = 四面均匀, 1 = 单灯偏向
    if coh > 1 then coh = 1 end
    -- 照度 = 太阳强度 + 附近光源总权重；四面都有光时再补一项"均匀曝光"
    -- （coh 越小越该整体提亮而不是只亮一边）。
    local nk = k + tw + (1 - coh) * tw * M.UNIFORM_GAIN
    if nk > 1 then nk = 1 end
    -- **同时**把合矢量的单位方向交出去（"朝光源"的方向，世界空间，与太阳同口径）。
    -- 这里只负责回答"光在哪一边"，**混不混、混多少由调用方按白天因子决定**
    -- （LightWeight + MixWorldDir）—— 所以"方向不吃开关"这条不变量与这张光源表无关，
    -- 表只提供世界事实。
    -- alen ≈ 0（对面两盏灯互相抵消）时方向没有意义：返回 nil，调用方按太阳处理。
    if alen > 1e-6 then
        return nk, ax / alen, ay / alen, az / alen, coh
    end
    return nk, nil, nil, nil, coh
end

-- 世界方向 → 着色器参数 (theta, el, k)。
-- theta 与太阳那条同口径（都是相机坐标系下的方位角），所以"白天锁太阳 / 夜里跟火把"
-- 在画面上是连续的：不会出现白天用一套、夜里用另一套。
-- 注意光源走的是**同一套相机基**（右轴 + 朝观察者轴），所以"火光在物体背后"
-- 一样会被正确判成逆光 —— 这不是只给太阳做的特例。
local function EncodeDir(wx, wy, wz, k)
    local el = math.asin(math.max(-1.0, math.min(1.0, wy)))
    return ThetaOf(wx, wz), el, k
end

-- 点光源参与**方向**的权重：白天 0（方向锁太阳），夜里 1（点火的光接管）。
--
-- **只吃白天因子这一个数** —— 这就是本轮的不变量：方向 = f(太阳, 光源表, 实体位置)，
-- 与任何开关（物体立体光照 / 影子 / 夜间影子 / 水印模式 / bcas_state 读得到与否）
-- 全都无关。旧版这里叫 SuppressOf，算的是 (1-day)*(1-shadow_day)：shadow_day 来自
-- bcas_state，随手影与夜间影子的开关变，于是"一开关影子就转"。删掉那个因子即可，
-- 光源自己的效用一点没少（用户要的举火把定向回来了）。
-- 白天相位闸门：**白天火把一律不许带方向**（2026-09-20 用户反馈
-- "那个跟随火把的要白天不生效"）。
--
-- 为什么光靠 alpha 斜坡不够：day = alpha/0.50 只有**正午那一会儿**才是 1.0，
-- 上午/下午 alpha 一掉档，LightWeight 就已经开了 —— 大清早点着火把，影子在
-- 玩家毫无察觉的情况下被拽偏 30%。"白天"对玩家来说是 day 相位（TheWorld.state），
-- 不是 alpha 曲线上的某个点，所以闸门必须钉在相位上。
--
-- 只看**世界事实**（相位），不看任何开关 ⇒ 仍属于不变量里的"白天因子"那一项，
-- 不是新的耦合：受光面、影子、水印模式四个开关怎么拨，这里读到的都是同一个值。
local function DayPhase(day)
    local w = _G.TheWorld
    if w ~= nil then
        -- 洞穴没有太阳：日晷桩在洞穴里返回 a=0（见 bcas_sun_emitter 的 cave 分支），
        -- 所以这里必须让闸门失效。否则洞穴的"白天"相位（isday 仍为 true）会把方向
        -- 重新钉回一颗**不存在的太阳** —— 逐实体解算照跑（day=0 < SUN_LOCK），
        -- 算出来的却还是太阳方向。用户 2026-09-21 要的正是
        -- 「洞穴也应该把影子开启，但是只开启跟随辉光面出影子的逻辑」。
        -- 浓度不受这里影响：洞穴浓度由 bcas_state 的"无太阳"支按附近照度给。
        if w.HasTag ~= nil then
            local okc, cave = pcall(w.HasTag, w, "cave")
            if okc and cave == true then return 0.0 end
        end
        local st = w.state
        if st ~= nil then
            if st.isday == true then return 1.0 end     -- 白天：压制关死，方向锁太阳
            if st.isnight == true then return 0.0 end   -- 夜里：完全交给附近光源
        end
    end
    return day or 0     -- 黄昏/没有相位读数：退回 alpha 斜坡（平滑交接）
end

local function LightWeight(day)
    local w = 1 - (DayPhase(day) or 0)
    if w < 0 then w = 0 elseif w > 1 then w = 1 end
    return w
end

-- 世界方向插值：太阳方向 (sx,sy,sz) 与"朝光源方向"(ux,uy,uz) 之间按 ww 混合再归一化。
-- 必须在**世界空间**混、最后才投影成屏幕角：各投一次再混会让"屏幕横向"和"世界方向"
-- 两套语义打架，光源一旦在物体正前后方，算出的朝向就和影子对不上。
local function MixWorldDir(sx, sy, sz, ux, uy, uz, ww)
    local mx = sx + (ux - sx) * ww
    local my = sy + (uy - sy) * ww
    local mz = sz + (uz - sz) * ww
    local ml = math.sqrt(mx * mx + my * my + mz * mz)
    if ml < 1e-5 then return sx, sy, sz end     -- 正对着互相抵消 ⇒ 退回太阳
    return mx / ml, my / ml, mz / ml
end

-- 太阳的**世界单位方向** + 白天因子：一次取全，给两家共用。
-- 影子模块自己没有日晷读数（它手里只有 theta/el），要做方向插值就必须拿到同一份
-- 原始值 —— 各读一次的话，日晷参数万一在中途换了一档，两家会算出不同的方向，
-- 而它们写的是同一条总线，结果就是打架。
function M.SunWorldDir()
    local _th, el, _k, day = M.SunParams()
    el = el or 0
    local _sy0, sun_rot = SunRaw()
    local a = ((sun_rot or 0) + 180.0) * DEG
    return math.cos(el) * math.sin(a), math.sin(el), math.cos(el) * math.cos(a), day or 0
end

-- **权威方向解算器**（受光面 + 地面影子共用，2026-09-20 第三轮）。
--
-- 影子模块（bcas_shadow_proj.PushAll）在夜里调的就是这一个函数 ⇒ 两个模块推给
-- FLOAT_PARAMS 的 x/y 是**逐位相同**的值：谁先写谁后写、哪个开关开着，
-- 结果都一样。这就是"开关物体立体光照影子朝向会变"的根治点。
--
-- 入参：实体、太阳的世界单位方向、白天因子。
-- 返回：世界单位方向（朝光源的方向，太阳与点光源同一条口径）。没有附近光源、
-- 或者还在白天时，原样返回太阳方向 —— 调用方不需要任何分支。
function M.WorldDirFor(inst, sx, sy, sz, day)
    local ww = LightWeight(day)
    if ww <= 1e-4 or #tracked == 0 then return sx, sy, sz end
    if inst == nil or inst.Transform == nil then return sx, sy, sz end
    local _k, ux, uy, uz, coh = LightStrengthFor(inst, 0)
    if ux == nil then return sx, sy, sz end
    ww = ww * (coh or 1)       -- 对面两盏灯抵消（coh→0）⇒ 不偏不倚，仍按太阳
    if ww <= 1e-4 then return sx, sy, sz end
    return MixWorldDir(sx, sy, sz, ux, uy, uz, ww)
end

-- 世界方向 → 总线口径 (theta, el)：**两条模块唯一的编码入口**。
-- 影子模块自己不折角，调这个函数（bcas_shadow_proj 的 EntityDir）——
-- "同一个方向算出来要写同一个数"这件事，只要编码路径也共用一条就不会跑偏。
function M.EncodeWorld(wx, wy, wz)
    local theta, el = EncodeDir(wx, wy, wz, 0)
    return theta, el
end

-- ===========================================================================
-- 总线下发值的**打包**（2026-09-21）
-- ===========================================================================
--
-- 起因（用户原话）：
--   「受光面和背光面随玩家辉光源移动的逻辑只在晚上生效，理应全时段生效，
--     但白天影子跟随不要跟过来」＋「受光和背光我打算有冷暖滑条和黑白对比滑条」
--
-- 难点：逐实体着色器只有 **一条** 模组可写的浮点通道 FLOAT_PARAMS(vec3)：
--   · y / z 能装，但必须保持**负数**，否则引擎自己的两个分支会醒来
--     （`y>0` = 片元丢弃、`z>0` = 顶点浮动 —— 见 components/floater.lua 的调用）；
--   · 一个 float32 的尾数只有 24 位 ⇒ 两个槽一共 48 位精确整数。
--
-- 第 11 页那两把背光滑条（背光冷暖 / 背光黑白）又要 12 位，而 y/z 只剩 5 位空隙
-- 可挤 —— 挤不出来（48 位的预算里 10/10/6/6/6/5/5 任何切法都到不了一槽 24 位）。
-- 于是**征用 x 槽**：以前认为 x 不能装数据，理由是"引擎拿它当世界高度阈值"。
-- 2026-09-22 逐处核过本体 shaders.zip（work/_recon12.py）：`FLOAT_PARAMS.x` 全库
-- 只有 7 处读取，**每一处都在 `if(FLOAT_PARAMS.y > 0.0)` 里面**；我们的 y 恒为负，
-- 那 7 个分支永远不执行 ⇒ x 对引擎完全沉睡，可以整段装数据。
--
-- 最终布局（**着色器、本文件、tools/bus_pack_proof.py 三处必须逐字一致**）：
--   x = cool_q + 64*dark_q + 4096*f_q           24 位（最大 2^24-1，精确可表示）
--       cool_q  6 位  背光冷暖 = (cool_q+1)/64     q=31 -> 恰好 0.5（出厂观感精确）
--       dark_q  6 位  背光黑白 = (dark_q+1)/64     q=31 -> 恰好 0.5
--       f_q    12 位  影子方位角 θ = f_q/4096*2pi - pi   步长 0.088 度
--                     （300 像素长的影子最坏横向偏 0.46 像素）
--   y = -(el_q + 2^11*(warm_q + 64*con_q))      23 位
--       el_q   11 位  el   = el_q/2047*(pi/2)      步长 0.000767 rad
--       warm_q  6 位  warm = (warm_q+1)/64         q=31 -> 恰好 0.5（出厂观感精确）
--       con_q   6 位  con  = (con_q+1)/64          q=31 -> 恰好 0.5
--   z = -(thb_q + 2^12*str_q)                   20 位
--       thb_q  12 位  θ_blend = thb_q/4096*2pi-pi   步长 0.088 度
--       str_q   8 位  strength = str_q/255*1.5      步长 0.0059
--
-- 为什么受光面要**单独一份**方位角（θ_blend）：影子白天必须锁太阳（"大白天影子跟着
-- 火把走"是错的），受光面却要全时段跟灯 —— 两个消费者要不同的值，这就是第二份角度
-- 存在的理由。θ_blend 用的是**同一套** MixWorldDir 算式，只是不吃相位闸门。
--
-- tool 证明过的五件事（tools/bus_pack_proof.py，不过就不许改这里）：
--   ① 三槽最大打包值 < 2^24 ⇒ float32 精确可表示（全量遍历）
--   ② 打包 -> float32 -> 解包，字段逐位还原（全量遍历）
--   ③ 方位角 12 位量化：受光量最坏偏差 0.114 个 8bit 色阶；仰角 11 位量化：
--      影子长度最坏偏差 0.22%
--   ④ 冷暖/对比端点关于 0.5 对称 ⇒ 出厂值解出来精确是 (1.0, 1.0, 1.0)
--   ⑤ x 槽的 12 位方位角量化（影子口径）：300 像素长影子的横向最坏偏差 < 0.5 像素
-- ⚠ Lua 5.1 **没有 `<<` / `>>` 位运算符**（本文件第一次写出来就是 `unexpected symbol
-- near '<'`，lua_syntax.py 当场报出来），所以位移全部写成十进制常量，
-- 常量名里的 2^N 是注释而不是运算。
local EL_MAX = math.pi / 2.0
local X_COOL_MAXV = 63        -- 2^6 - 1
local X_DARK_MAXV = 63        -- 2^6 - 1
local X_FQ_MOD = 4096         -- 2^12   （影子方位角的档数）
local X_DARK_MUL = 64         -- 2^6    （dark_q 的权重）
local X_FQ_MUL = 4096         -- 2^12   （f_q 的权重）
local X_COOL_A = 64           -- 2^6    （cool_q 的基数）
local X_DARK_A = 64           -- 2^6
local Y_EL_MAXV = 2047        -- 2^11 - 1
local Y_WARM_MAXV = 63        -- 2^6 - 1
local Y_CON_MAXV = 63         -- 2^6 - 1
local Y_WARM_MUL = 2048       -- 2^11   （warm_q 的权重）
local Y_CON_MUL = 131072      -- 2^17   （con_q 的权重）
local Z_THB_MOD = 4096        -- 2^12   （θ_blend 的档数）
local Z_STR_MAXV = 255        -- 2^8 - 1
local Z_STR_MUL = 4096        -- 2^12   （str_q 的权重）
local Y_WARM_A = 64           -- 2^6    （warm_q 的基数）
local Y_CON_A = 64            -- 2^6

-- 面板滑条（bcas_state 的参数表；不占 uniform，随总线打包下发）
local function Slider(name)
    local St = _G.package ~= nil and _G.package.loaded["bcas_state"] or nil
    if St ~= nil and St.params ~= nil then
        local v = St.params[name]
        if type(v) == "number" then
            if v < 0 then return 0 elseif v > 1 then return 1 end
            return v
        end
    end
    return 0.5
end

-- x 槽：背光冷暖 + 背光黑白 + 影子方位角（24 位）。**不取负** —— 引擎对 x 的 7 处
-- 读取全在 `if(FLOAT_PARAMS.y > 0.0)` 的 y>0 分支里（我们的 y 恒为负 ⇒ 永不执行），
-- 所以 x 可以整段当载荷；这一点是逐处核过本体 shaders.zip 的（work/_recon12.py）。
function M.PackX(theta, scool, sdark)
    theta = tonumber(theta) or 0
    scool = tonumber(scool) or 0.5
    sdark = tonumber(sdark) or 0.5
    -- 折到 [0, 2pi) 再定量化档（与 PackZ 的 θ_blend 同一套折法）
    local a = (theta + math.pi) % (2.0 * math.pi)
    if a < 0 then a = a + 2.0 * math.pi end
    local f_q = math.floor(a / (2.0 * math.pi) * X_FQ_MOD + 0.5) % X_FQ_MOD
    local cool_q = math.floor(scool * X_COOL_A - 1 + 0.5)
    local dark_q = math.floor(sdark * X_DARK_A - 1 + 0.5)
    if cool_q < 0 then cool_q = 0 elseif cool_q > X_COOL_MAXV then cool_q = X_COOL_MAXV end
    if dark_q < 0 then dark_q = 0 elseif dark_q > X_DARK_MAXV then dark_q = X_DARK_MAXV end
    return cool_q + dark_q * X_DARK_MUL + f_q * X_FQ_MUL
end

-- x 槽 → 影子方位角（弧度）。凡是"拿 fx 跟角度比"判据（M.FloatsAreOurs、影子模块的
-- BusIsOurs）都必须先过这道换算：x 现在是打包整数，直接跟角度比会永远判成"外人"，
-- 后果是实体被交还引擎、水印丢失 ⇒ 影子重新盖回本体。
function M.DecodeTheta(x)
    x = tonumber(x) or 0
    -- ⚠ 方位角在**高 12 位**（低 12 位是背光冷暖/黑白两把滑条）。这里原来写的是
    -- `x % X_FQ_MUL` —— 那是把滑条那 12 位当角度用（出厂滑条解出 -0.05 弧度），
    -- 于是 ③共识/④纯太阳 两条归属判据永远判 false ⇒ 自家残留被判成外人占线 ⇒
    -- 实体被交还引擎、开关关一次就再也挂不回来。与影子 VS 的 floor(x/4096) 同源。
    local f_q = math.floor(x / X_FQ_MUL) % X_FQ_MOD
    return (f_q / X_FQ_MOD) * 2.0 * math.pi - math.pi
end

-- y 槽：仰角 + 冷暖 + 对比（23 位）。返回负数（引擎的 `y>0` 丢弃分支必须继续沉睡）。
function M.PackY(el, warm, con)
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

-- z 槽：受光面方位角 θ_blend + 强度（20 位）。同样返回负数（`z>0` 顶点浮动分支沉睡）。
function M.PackZ(theta_blend, strength)
    theta_blend = tonumber(theta_blend) or 0
    strength = tonumber(strength) or 0
    if strength < 0 then strength = 0 elseif strength > 1.5 then strength = 1.5 end
    -- 折到 [-pi, pi) 再折到 [0, 2pi)
    local a = (theta_blend + math.pi) % (2.0 * math.pi)
    if a < 0 then a = a + 2.0 * math.pi end
    local thb_q = math.floor(a / (2.0 * math.pi) * Z_THB_MOD + 0.5) % Z_THB_MOD
    local str_q = math.floor(strength / 1.5 * Z_STR_MAXV + 0.5)
    if str_q < 0 then str_q = 0 elseif str_q > Z_STR_MAXV then str_q = Z_STR_MAXV end
    return -(thb_q + str_q * Z_STR_MUL)
end

-- 受光面专用方位角：**不吃相位闸门**的混合方向（灯一律参与，权重 = 相干度）。
-- 与 M.WorldDirFor 的唯一差别就是 `ww` 不吃 LightWeight(day)：白天也跟灯。
local function ShadeThetaFor(inst)
    local sx, sy, sz = M.SunWorldDir()
    if inst == nil or inst.Transform == nil or #tracked == 0 then
        return (EncodeDir(sx, sy, sz, 0))
    end
    local _k, ux, uy, uz, coh = LightStrengthFor(inst, 0)
    if ux == nil then return (EncodeDir(sx, sy, sz, 0)) end
    local ww = coh or 1
    if ww <= 1e-4 then return (EncodeDir(sx, sy, sz, 0)) end
    local mx, my, mz = MixWorldDir(sx, sy, sz, ux, uy, uz, ww)
    return (EncodeDir(mx, my, mz, 0))
end

-- **两个模块共用的唯一编码入口**：给一条实体的总线值 (x, y, z)。
--   theta   = 影子口径的方位角（白天锁太阳）
--   el      = 仰角（两家共用）
--   k_fresh = 调用方**刚算出来**的强度；传 nil 才回落到自己存的那份（再没有就是 0）
--
-- ⚠ 优先级必须是"新算的 > 存着的"。第一版写成"存着的 > 新算的"，当场被冒烟台
-- 抓到：夜里火把/小火把那条路新算出的 k=1.0 被上一拍存下的 0 盖掉，实体整片
-- 失去夜色补光（现象是"夜里举火把物体不再发亮"，而白天路径完全正常）。
function M.BusTriple(inst, theta, el, k_fresh)
    local warm, con = Slider("ShadeWarm"), Slider("ShadeContrast")
    -- 背光侧那两把（第 11 页新增：只动背光面的冷暖与黑白，受光面不受它们影响）
    local scool, sdark = Slider("ShadeCool"), Slider("ShadeDark")
    local strength = tonumber(k_fresh)
    if strength == nil then strength = M.BusStrength(inst) end
    if strength == nil then strength = 0 end
    if M.IsGlowSource ~= nil then
        local okg, isglow = pcall(M.IsGlowSource, inst)
        if okg and isglow == true then strength = 0 end
    end
    -- x 槽装的是指纹那一支的方位角（影子口径，白天锁太阳）+ 两把背光滑条；
    -- y/z 与 2026-09-21 的布局逐位相同，一个都没动。
    return M.PackX(theta, scool, sdark), M.PackY(el, warm, con), M.PackZ(ShadeThetaFor(inst), strength)
end

-- **唯一的写入口**：把 (θ, el, k) 打包后经 OurParams 下发。
-- 三个下发点（PushEntryNow 首帧 / RefreshImpl 8Hz / PushIfMoved 逐帧）都走这里 ——
-- 漏掉任何一处的后果是解包端把 -el 当成打包值读，画面上表现为影子长度乱跳、
-- 受光面方位角错乱，而且只在"某一条路径"上出现，极难从现象反推。
local function WriteBusPacked(as, inst, az, el, k)
    local bx, by, bz = M.BusTriple(inst, az, el, k)
    return pcall(OurParams, as, bx, by, bz)
end

-- "算一条实体的参数" + "当场推上去"（前向声明在文件上半部，见那里的说明）。
--
-- 只依赖模块级的太阳/光源缓存与该实体的世界位置，没有别的副作用；
-- 供两处复用：M.Apply（挂上即生效）与 RefreshImpl（8Hz 例行上报）。
--
-- **方向 = M.WorldDirFor 的那套算式**（不变量，2026-09-20 第三轮）：权重由
-- 白天因子 × 相干度决定，纯世界函数。白天只有太阳；夜里附近的火把/灯笼/辉光
-- 把方向接管过去（用户要的效果）。因为影子模块调的是同一个算式，两边写进
-- FLOAT_PARAMS 的 x/y 逐位一致 —— 开关物体立体光照时影子朝向**不动**。
local function ComputeEntry(inst, entry, sx, sy, sz, k, day)
    local ww = LightWeight(day)
    local wx, wy, wz = sx, sy, sz                  -- 世界方向：默认太阳
    local p_k = k
    local w_k = k
    local from_light = false
    if #tracked > 0 then
        -- 一次把"照度"与"朝光源的方向"都取回来（同一次光源遍历，别算两遍）。
        local lk, ux, uy, uz, coh = LightStrengthFor(inst, k)
        if lk ~= nil then
            w_k = lk
            p_k = lk
            from_light = true
            if ux ~= nil and ww > 1e-4 then
                local lww = ww * (coh or 1)
                if lww > 1e-4 then
                    wx, wy, wz = MixWorldDir(sx, sy, sz, ux, uy, uz, lww)
                end
            end
        end
    end
    local p_x, p_el = EncodeDir(wx, wy, wz, 0)
    -- 缓存**世界方向**，供逐帧那一路重新投影（见 M.TickFrame）：
    -- 相机一转屏幕角就变，而世界方向在下一拍之前几乎不变。
    -- from_light 记住这条方向里有没有灯的贡献 —— 逐帧那一路要据此选择
    -- "重新投影缓存"（有灯：重算方向太贵）还是"用最新的太阳参数"（只有太阳：
    -- 太阳仍在动，而且那一套是全局量，现算几乎免费）。
    -- 白天 ww = 0 ⇒ 缓存里就是太阳方向，from_light 只剩"强度里有没有灯"这层含义；
    -- 那个分支仍然有用（强度变了要重推）。
    entry.wx, entry.wy, entry.wz = wx, wy, wz
    entry.wk = w_k
    entry.w_light = from_light
    -- 辉光体不做受光面（BUG③，2026-09-20 第四轮实机）：
    --   「辉光变黑的毛病是开启物体立体光照就会这样，暗面精灵似乎跑到了辉光灯光上」
    -- k = 0 ⇒ DA_ApplySunlight 的每一项都带 strength 因子 ⇒ 逐位还原引擎像素
    -- （见 make_surface_light_shader.py 的 DA 公式），而水印写入端**不受 strength
    -- 影响** ⇒ 影子照样不会盖到这块精灵上。方向照旧写进 x/y（影子模块读的是它，
    -- 动了方向 = 影子朝向跳，这条不能碰）。
    if M.IsGlowSource(inst) then
        p_k = 0
        w_k = 0
        entry.wk = 0
    end
    return p_x, p_el, p_k
end

-- 挂载时调用：把这一刻的参数直接推给刚换上着色器的实体。
--
-- 与 RefreshImpl 里那一段是同一套算式（都走 ComputeEntry + SunRaw/SunParams），
-- 所以"当场推的值"与"下一拍会推的值"逐位一致 —— 不会出现首帧闪一下再跳到正确值。
PushEntryNow = function(as, entry)
    if _G.TheWorld == nil or entry == nil or entry.inst == nil then return end
    -- 太阳的世界单位方向 + 白天因子：**一次取全**（分几次调的话每次都会重读日晷，
    -- 中途换一档两家就会算出不同的方向）。这里调的就是影子模块调的那个函数。
    RefreshTracked()
    local sx, sy, sz, day = M.SunWorldDir()
    local _theta, _el, k = M.SunParams()
    local p_x, p_el, p_k = ComputeEntry(entry.inst, entry, sx, sy, sz, k, day)
    -- 走 OurParams（不是 raw_params）：只有经过它那一笔才会被记进"自己人残留"
    -- 台账，关掉再打开时 MountOK 才认得出这是我们自己写的（见 M.FloatsAreOurs）。
    local ok = WriteBusPacked(as, entry.inst, p_x, p_el, p_k)
    if ok then entry.az, entry.el, entry.k = p_x, p_el, p_k end
end

-- 共享总线的"复位"推送：**与 ComputeEntry 完全同一条方向**（白天=太阳，
-- 夜里=太阳×白天因子 与 附近光源 的世界混合），强度按 LightStrengthFor。
--
-- 只用在三条"这条实体的总线不再由受光面主导"的路径上：
--   ① 被外部写入者抢占（YieldTo）
--   ② 关掉物体光照、真正把着色器交还引擎（SetEnabled）
--   ③ 退出水印模式、真正交还（SetMarkMode）
--
-- 为什么不能写 (0,0,0)（旧版就是这样，两处）：影子端只读总线的 x/y 当方向，
-- 而它又有"值没变就不推"的优化 —— 一次清零之后它可能再也不推，于是所有实体
-- 的影子被**永久**甩到 theta=0 的方向上。用户原话：
--   「开关物体立体光照影子朝向会变！」
-- 这个函数存在的唯一目的就是让那三条路径写回去的仍是"当前共识方向"，
-- 而且必须与影子模块各自算出的值逐位相同（同一个 M.WorldDirFor 算式）。
PushSunTriple = function(as, inst)
    local sx, sy, sz, day = M.SunWorldDir()
    local _theta, _el, k = M.SunParams()
    k = k or 0
    local p_k = k
    if inst ~= nil then
        local lk = LightStrengthFor(inst, k)
        if lk ~= nil then p_k = lk end
        -- 辉光体：交还的也必须是"零强度"（同 ComputeEntry 的 BUG③ 说明）——
        -- 这条路径写回去的是"共识方向 + 当前强度"，强度不清零就等于又给辉光
        -- 体加了一次暗面。
        if M.IsGlowSource(inst) then p_k = 0 end
    end
    local wx, wy, wz = M.WorldDirFor(inst, sx, sy, sz, day)
    local p_x, p_el = EncodeDir(wx, wy, wz, 0)
    -- 打包下发：y 槽 = 仰角 + 冷暖/对比滑条，z 槽 = 受光面方位角 θ_blend + 强度
    -- （布局与理由见 M.PackY 上面的长注释；M.BusTriple 是两个模块共用的编码入口）
    local bx, by, bz = M.BusTriple(inst, p_x, p_el, p_k)
    pcall(OurParams, as, bx, by, bz)
end

-- 8Hz 上报：把太阳/光源参数写进所有已挂载实体；每一拍都顺带补挂一批新实体
--
-- 光源怎么参与（2026-09-20 第三轮定稿：**权重只吃世界状态**）：
--   · 强度：举着火把走到物体背光面 ⇒ 物体的 k 变大 ⇒ 整体被**提亮**（背光面不再死黑）。
--   · 方向：白天因子 × 相干度决定光源占多少 —— 正午权重 0（方向锁太阳，举火把不会
--     让影子转），日落后太阳淡出、火光接管（用户要的"举火把给朝向"）。
--   · 开关（物体立体光照 / 影子 / 夜间影子 / 水印模式）一律不出现在这条路径上，
--     见 LightWeight 上面的不变量说明。影子模块算的是同一个 M.WorldDirFor。
--   · 亮度本身（引擎的真实照亮）仍由引擎的 Light 决定，这里只管朝向与受光面强度。
local function RefreshImpl()
    if _G.TheWorld == nil then return end
    -- 太阳的世界单位方向 + 白天因子（三家共用同一份原始值，别各读一次）
    local sx, sy, sz, day = M.SunWorldDir()
    local sun_x, el, k = M.SunParams()
    -- 光源位置每次上报都现读（8Hz）：举着火把走出去，物体当拍就转向火把。
    -- 重活（遍历 Ents、选跟踪目标）仍然 2Hz 一次，玩家明显移动时也补一次。
    local px, pz = PlayerPos()
    local moved = true
    if px ~= nil and last_pick.x ~= nil then
        local dx, dz = px - last_pick.x, pz - last_pick.z
        moved = dx * dx + dz * dz > M.LIGHT_MOVE_EPS * M.LIGHT_MOVE_EPS
    end
    if moved and #lights > 0 then
        last_pick.x, last_pick.z = px, pz
        PickTracked(px, pz)
    end
    RefreshTracked()
    local pushed = 0
    -- 逐条派发。**两条铁律**（都是真实事故换来的，见 SHADOW_V11_PLAN 事故 2）：
    --   ① 实体已经不在世界里（被拾取/烧掉/换图）就绝不再推参数 —— 引擎会对每个
    --      失效 AnimState 打一行 "Stale Component Reference"，8Hz × 几百条能把
    --      C 盘写满（实测一晚上 855MB / 一千万行，最后游戏都起不来）。发现即除名。
    --   ② 值没变就不推。8Hz × 上百个实体的 Lua↔C++ 调用才是真正的开销，
    --      白天光源不动时绝大多数实体每一轮的参数是同一个。
    for as, entry in pairs(mounted) do
        local inst = entry.inst
        -- 让位协议：这一条在我们占用期间被**外部**写过（别人的着色器/浮参、
        -- floater 组件的浮动、其它模组）→ 立刻交还，别把自己的效果压在人家上面。
        -- 放在最前面判，交还之后本轮不再推它。
        local rec = external[as]
        if rec ~= nil and rec.stolen == true then
            YieldTo(as)
        elseif inst == nil or inst.IsValid == nil or not inst:IsValid() then
            mounted[as] = nil
        else
            -- 光源参与方向混合（世界方向）→ 再折算成屏幕量。
            -- **与 M.Apply 的首帧走同一个函数**（ComputeEntry）：这样"刚挂上推的值"
            -- 与"下一拍推的值"是同一套算式，不会首帧闪一下再跳到正确值。
            -- 注意它内部是**先混世界方向、最后一步才投影**：反过来（各投一次再混）
            -- 会让"屏幕横向"和"世界方向"两套语义混在一起，光源一旦在物体正前后方
            -- 就会算出与影子不一致的朝向。
            local p_x, p_el, p_k = ComputeEntry(inst, entry, sx, sy, sz, k, day)
            -- 透云光束：只抬强度、绝不动方向（它在哪一片落下不改变太阳从哪来）。
            -- 极限值跟 DA 一样 clamp 在 1.5，避免强度滑出它那套公式的适用范围。
            if #beams > 0 and inst.Transform ~= nil then
                local okp, ex, _ey, ez = pcall(inst.Transform.GetWorldPosition, inst.Transform)
                if okp and ex ~= nil then
                    local bg = BeamGain(ex, ez)
                    if bg > 0 then
                        p_k = p_k * (1 + M.BEAM_GAIN * bg)
                        if p_k > M.K_MAX then p_k = M.K_MAX end
                    end
                end
            end
            if entry.az == nil or not NearEnough(entry, p_x, p_el, p_k) then
                -- 同样走**原始** setter：否则我们每次推参数都会把自己记成
                -- "外部写入"，下一拍就被让位协议判成被抢占而全部交还。
                -- （OurParams 内部走的就是 raw_params，并额外记一笔"自己人残留"
                --   台账；见 M.FloatsAreOurs。）
                local ok = WriteBusPacked(as, entry.inst, p_x, p_el, p_k)
                if ok then
                    entry.az, entry.el, entry.k = p_x, p_el, p_k
                    pushed = pushed + 1
                else
                    mounted[as] = nil      -- 推失败（多半已经失效）→ 直接除名
                end
            end
        end
    end
    last_push = { az = sun_x, el = el, k = k, n = pushed, lights = #lights, tracked = #tracked,
                  beams = #beams }

    -- **每 2 拍重建光源表 + 补挂**（原来这里是 % 4）。
    -- 用户实测"过一两秒才出来"的延迟里，这条链上有三环，这是前两环：
    --   ① 发现灯：原来 2Hz ⇒ 最坏 0.5s；现在 4Hz ⇒ 最坏 0.25s
    --   ② 给实体换着色器：原来 2 个/次 ⇒ 每秒 4 个（最致命：几十棵树要十几秒）；
    --      现在见 M.MOUNT_PER_SWEEP = 12，@4Hz ⇒ 每秒 48 个
    --   ③ 挂上后等下一拍才有参数 ⇒ 见 M.Apply 里的"挂上即推"
    -- 为什么不是每一拍：RebuildLights 会遍历整个 Ents 并重建两张表（有分配开销），
    -- 8Hz 做这件事的收益只有 0.125s，却把这项开销翻倍。4Hz 已经让它不再是人眼
    -- 能察觉的延迟，同时和影子模块的补挂节奏（PER_SWEEP=12）保持同量级。
    sweep_tick = sweep_tick + 1
    if sweep_tick % 2 == 0 then
        RebuildLights()
        SweepImpl()
    end
end

-- ==== 逐帧平滑上报（用户 2026-09-19 实机反馈"档位感"）====================
--
-- 病因：受光面的方向原来只在 8Hz 那一拍更新（modmain 的 0.125s 任务）。
-- 举着火把走、或者转视角时，屏幕上的受光面于是每 0.125 秒"跳一格" ——
-- 用户原话："跟那个档位切换似的……闪现的档位似切换，不自然"。
--
-- 治法：把**上报**提到每帧，但只做最便宜的那一段 ——
--   · 方向的计算（尤其是遍历 Ents、读光源位置）仍旧 8Hz，不动；
--   · 每帧只做：算一次太阳参数（几次三角函数）→ 逐条比较 → 变了才推。
-- 关键判据是"**真的变了才推**"：白天太阳不动、玩家不动时，绝大多数帧**一个
-- Lua↔C++ 调用都不发**；只有正在转/正在走的那几帧才逐条推。于是开销随
-- "画面里有没有在变"自然伸缩，而不是把 8Hz 的活整体乘以帧率。
--
-- 平滑的是**方向角本身**：theta 是角度，逐帧推进时受光面就是平滑旋转的；
-- 8Hz 那一拍负责把"漂了很远"的真值拉回来。
--
-- 阈值**必须与 8Hz 那一拍的 PUSH_EPS_* 相同**：8Hz 会故意跳过小于 0.5° 的变化
-- （那是它省调用的手段），于是 entry 里记的可能是"最多差 0.5° 的旧值"。逐帧这
-- 一路要是用更严的阈值，就会把这个差值当成"变了"而推一次 —— 稳态下白白多发
-- 一次引擎调用（每个实体每帧都可能发一次，正是这条路径最该避免的事）。
-- 用同一个阈值，就等于"8Hz 认为不用推的变化，逐帧也不推"，两边口径一致。
-- 观感上不受影响：0.5° 的台阶在 30fps 下看不出来，而它已经比原来好 8 倍细。
local function PushIfMoved(entry, as, az, el, k)
    -- 角度走环形最短距离（跨 ±π 时线性差会算出 2π，于是每帧都判"变了"）
    local daz = math.abs(az - (entry.az or az))
    if daz > math.pi then daz = 2 * math.pi - daz end
    if entry.az ~= nil and daz <= M.PUSH_EPS_AZ
        and math.abs(el - (entry.el or el)) <= M.PUSH_EPS_EL
        and math.abs(k - (entry.k or k)) <= M.PUSH_EPS_K then
        return false
    end
    -- 同上：一律经 WriteBusPacked（内含 OurParams），好把它记进"自己人残留"台账
    local ok = WriteBusPacked(as, entry.inst, az, el, k)
    if ok then
        entry.az, entry.el, entry.k = az, el, k
        return true
    end
    return nil          -- nil = 推失败（多半已失效）→ 调用方除名
end

-- 逐帧任务调这个：**所有**已挂载条目都走这里。
--
-- 两段路（2026-09-21 重定，上一版的"只重投影缓存世界方向"是错的那一半）：
--   · 灯没参与的条目（绝大多数）：方向 = 太阳 = 全局量，每帧现算几次三角函数 →
--     逐条比较 → 变了才推。白天太阳走得慢，这一路稳态下一个引擎调用都不发。
--   · 灯参与过的条目（entry.w_light）：**按当帧的灯位重算**，不再拿 8Hz 那一拍
--     缓存下来的世界方向去重投影。
--
-- 上一版为什么不够：它只重投影屏幕角，理由是"灯动的方向逐帧算太贵"。但相机一转
-- 屏幕角要跟着变，**灯一移动世界方向本身就在变** —— 缓存住的那一份是 8Hz 的旧值，
-- 于是灯连续移动时方向每 0.125 秒跳一格。用户报的"举着灯走的时候转换一卡一卡、
-- 夜里影子跟着辉光走不丝滑"就是这个。
--
-- 代价可控：只有 w_light 为真的条目会走重算（那需要读该实体位置 + 遍历最多
-- M.LIGHT_MAX_TRACK 盏灯），而 w_light 只在"这条实体真的有灯在照"时才为真
-- （ComputeEntry 里由 LightStrengthFor 决定）—— 也就是玩家身边那几十条，
-- 不是全表。灯位本身按帧刷新一次（M.SyncLights，≤6 次读位置）。
function M.TickFrame()
    if _G.TheWorld == nil or not M.enabled then return 0 end
    -- 太阳参数每帧现算：太阳是全局一个角，几次三角函数可以忽略；
    -- 没缓存过世界方向的条目（刚挂上、还没轮到 8Hz）就退化成太阳，与原行为一致。
    local sun_az, el, k = M.SunParams()
    -- 灯位当帧化（与影子模块同帧只刷一次，见 M.SyncLights）
    M.SyncLights()
    -- 太阳的世界方向 + 白天因子：只在真的碰到"有灯的条目"时才取（惰性，见下）
    local sx, sy, sz, day
    local pushed = 0
    for as, entry in pairs(mounted) do
        local inst = entry.inst
        if inst == nil or inst.IsValid == nil or not inst:IsValid() then
            mounted[as] = nil
        else
            local az, ae, ak = sun_az, el, k
            if entry.w_light == true then
                -- 灯参与过：**按当帧的灯位与实体位置重算**（ComputeEntry 内部走
                -- LightStrengthFor；灯的权重仍由白天因子决定，与任何开关无关）。
                -- 方向、强度、缓存三者一起更新，所以下一帧读到的也是当帧事实。
                if sx == nil then sx, sy, sz, day = M.SunWorldDir() end
                az, ae, ak = ComputeEntry(inst, entry, sx, sy, sz, k, day)
            end
            -- 灯没参与时保持用**现算**的太阳参数（上面那三个初值）：
            -- 太阳一直在走，用缓存会把它的连续运动退化成 8Hz 的台阶；
            -- 而太阳参数是全局量，每帧现算只是几次三角函数。
            -- 透云光束的强度增益是逐实体的，缓存里没有它，这里照旧现算一次
            -- （只在真的存在光柱时才读写位置，绝大多数帧这一支根本不进）。
            if #beams > 0 and inst.Transform ~= nil then
                local okp, ex, _ey, ez = pcall(inst.Transform.GetWorldPosition, inst.Transform)
                if okp and ex ~= nil then
                    local bg = BeamGain(ex, ez)
                    if bg > 0 then
                        ak = ak * (1 + M.BEAM_GAIN * bg)
                        if ak > M.K_MAX then ak = M.K_MAX end
                    end
                end
            end
            local r = PushIfMoved(entry, as, az, ae, ak)
            if r == nil then
                mounted[as] = nil
            elseif r then
                pushed = pushed + 1
            end
        end
    end
    return pushed
end

function M.Refresh()
    Guard("Refresh", RefreshImpl)
end

-- 扫一遍场上实体（新生成的、进世界前就存在的都能补上），按距离从近到远、
-- 每次只挂 MOUNT_PER_SWEEP 个（见文件头的说明）。
-- 2026-09-18 起判据不再是 prefab 白名单，而是 MountOK（按类别排除 + 不抢别人的）。
function SweepImpl()
    if not MountingActive() then return 0 end
    local Ents = _G.Ents
    if Ents == nil then return 0 end
    if MountedCount() >= M.MAX_MOUNTED then return 0 end
    local px, pz = PlayerPos()
    local r2 = M.RADIUS * M.RADIUS
    local cand, ncand = {}, 0
    for _, inst in pairs(Ents) do
        if inst ~= nil and not mounted[inst.AnimState] and MountOK(inst) then
            local ok, x, _y, z = pcall(inst.Transform.GetWorldPosition, inst.Transform)
            if ok then
                local d2 = 0
                if px ~= nil then
                    local dx, dz = x - px, z - pz
                    d2 = dx * dx + dz * dz
                end
                if d2 <= r2 then
                    ncand = ncand + 1
                    cand[ncand] = { inst = inst, d2 = d2 }
                end
            end
        end
    end
    table.sort(cand, function(a, b) return a.d2 < b.d2 end)
    local n = 0
    for i = 1, ncand do
        if n >= M.MOUNT_PER_SWEEP or not MountingActive() then break end
        if MountedCount() >= M.MAX_MOUNTED then break end
        if M.Apply(cand[i].inst) then n = n + 1 end
    end
    -- **不许在这里逐轮打日志**：8Hz~2Hz 的分批挂载会让这一行在每次挂新实体时
    -- 重复出现，一次会话实测 1680 行（tools/log_spam_check.py 抓到的刷屏之一）。
    -- 累计数在 mount_count 里，要看看 Info()。
    return n
end

function M.Sweep()
    local ok, n = Guard("Sweep", SweepImpl)
    return ok and n or 0
end

-- 本模块是否正在推 FLOAT_PARAMS（影子投影模块据此判断能否复用同一条总线）。
-- 口径 = "我们是不是挂载实体总线的唯一写入者"：只要 MountingActive（受光面开
-- 或水印模式），每拍都会写 (theta, -el, k)。**不要**改成"亮度非零"——滑条拉到
-- 0 时旧判据会翻成 false，影子便对同一批实体再写一遍，触发我们的观察钩子、
-- 整批让位、水印丢失，影子重新盖回本体（BUG① 的另一种入口）。
function M.IsPushing()
    return MountingActive()
end

-- 这个实体的 FLOAT_PARAMS 是否由本模块负责。
--
-- ⚠ 2026-09-20 起**方向不再按归属分担**：影子端自己保证方向（只读总线的 x/y
-- = 太阳方位），两条模块写进去的方向逐位相同，谁先谁后都无所谓。这个查询
-- 只剩两个用途：① 挂载时的"外人浮参"过滤；② M.BusZ（强度口径）。
function M.IsMounted(inst)
    if inst == nil or inst.AnimState == nil then return false end
    return mounted[inst.AnimState] ~= nil
end

-- 共享总线 z 分量（强度位）的口径：**影子端推方向时必须写同一个数**。
--
-- 为什么：FLOAT_PARAMS 是每个 AnimState 一份的共享槽，影子端每推一次方向就会
-- 把 z 一起覆盖掉。影子顶点着色器根本不读 z（只读 x/y 当方向），但受光面读它
-- 当亮度 —— 两边各写各的（受光面写"受光强度"、影子写"昼夜浓度"）就会出现
-- "开关影子顺手把受光面亮度改了"这种开关互相串味，也就是用户说的
-- 「很多开关功能去不掉」。返回 nil = 这条实体不归本模块管，影子端用太阳
-- 强度即可（它自己也只信太阳）。
function M.BusZ(inst)
    if inst == nil or inst.AnimState == nil then return nil end
    local entry = mounted[inst.AnimState]
    if entry == nil or entry.k == nil then return nil end
    return -entry.k
end

-- 强度口径（正值）。打包之后强度住在 z 槽里，这里只作为"取强度"的读数口：
-- M.BusZ 仍是那条槽的**原始口径**（负的强度），别在别处再解释一遍。
function M.BusStrength(inst)
    local z = M.BusZ(inst)
    if z == nil then return nil end
    return -z
end

function M.SetEnabled(on)
    local want = on == true
    if want == M.enabled and logged_enabled == want then return end
    local was = M.enabled
    M.enabled = want
    if not M.enabled then
        if M.mark_mode then
            -- **影子还开着**：绝不能交还句柄 —— 实体像素上的水印是合成端分辨
            -- "影子里面的地面 / 本体"的唯一信息，交还引擎原版等于把水印擦掉，
            -- 影子立刻重新盖到施影者自己身上（BUG①）。换成 mark 变体：引擎
            -- anim 逐字，观感逐位等于原版，只多一个 ±4/255 的蓝通道棋盘水印。
            SwapMountedPath(M.MarkPath())
        else
            -- 关掉时**把实体的着色器恢复回引擎默认**（不是只把强度清零）：
            -- 从白名单放开到"全部实体"之后，还挂着我们的 effect handle 就等于
            -- 整片世界的实体都还在用我们的着色器，只是参数是 0 —— 那既不是原版观感，
            -- 也让"关掉"这件事名不副实。所以这里彻底交还（ClearDefaultEffectHandle
            -- + 浮参交还太阳方向，都走原始 setter）。
            -- 已经离开世界的实体直接除名（**不要**再碰它的 AnimState，见铁律①）
            for as, entry in pairs(mounted) do
                local inst = entry.inst
                if inst == nil or inst.IsValid == nil or not inst:IsValid() then
                    mounted[as] = nil
                else
                    pcall(OurClearFx, as)
                    -- ⚠ 浮参**绝不能归零**（旧版这里写 (0,0,0)，是硬伤）：影子与
                    -- 受光面共用同一个 FLOAT_PARAMS，影子顶点着色器读它的 x/y 当
                    -- 方向，而且带"值没变就不推"的优化 —— 这里清零就等于把影子
                    -- 永久甩到 theta=0 的方向上。用户原话：
                    --   「开关物体立体光照影子朝向会变！」
                    -- 交还的是**句柄**，不是影子朝向：方向一律写回太阳。
                    PushSunTriple(as, inst)
                end
            end
            mounted = setmetatable({}, { __mode = "k" })
            external = setmetatable({}, { __mode = "k" })
        end
    elseif not was and M.mark_mode then
        -- 从水印模式回到受光面：还挂着的换回受光面变体（参数下一拍自然恢复
        -- 非零强度）。从"全关"启用时上一段已经清空了表，这里是空循环。
        SwapMountedPath(M.HandlePath())
    end
    if logged_enabled ~= want then
        logged_enabled = want
        Log("已" .. (M.enabled and "启用" or "停用")
            .. ((not M.enabled and M.mark_mode)
                and "（影子仍开：实体保留水印着色器，观感=原版）" or "")
            .. "（已挂载 " .. tostring(MountedCount()) .. " 个）")
    end
end

-- 站立物水印模式（影子豁免门的写入端）：由 State.ApplyEnhancements 随
-- 「影子是否在画」同步。受光面开着时水印由受光面着色器自带（无需切换）；
-- 受光面关着而影子开着时，实体改挂 mark 变体继续供水印；两者都关时真正交还。
function M.SetMarkMode(on)
    local want = on == true
    if M.mark_mode == want then return end
    local was = M.mark_mode
    M.mark_mode = want
    if was and not want then
        -- 影子不画了，水印没有读者：若受光面也关着，把实体真正交还引擎原版
        -- —— 这是"完整关掉"的最后一段（此前它们挂的是 mark 变体）。
        if not M.enabled then
            for as, entry in pairs(mounted) do
                local inst = entry.inst
                if inst == nil or inst.IsValid == nil or not inst:IsValid() then
                    mounted[as] = nil
                else
                    pcall(OurClearFx, as)
                    -- ⚠ 浮参**绝不能归零**（旧版这里写 (0,0,0)，是硬伤）：影子与
                    -- 受光面共用同一个 FLOAT_PARAMS，影子顶点着色器读它的 x/y 当
                    -- 方向，而且带"值没变就不推"的优化 —— 这里清零就等于把影子
                    -- 永久甩到 theta=0 的方向上。用户原话：
                    --   「开关物体立体光照影子朝向会变！」
                    -- 交还的是**句柄**，不是影子朝向：方向一律写回太阳。
                    PushSunTriple(as, inst)
                end
            end
            mounted = setmetatable({}, { __mode = "k" })
            external = setmetatable({}, { __mode = "k" })
            Log("水印模式关闭：实体已全部交还引擎原版")
        end
    elseif not was and want then
        Log(M.enabled and "水印模式开启：受光面自带水印，无需切换"
            or "水印模式开启：受光面关着，实体由 mark 着色器接管（观感=原版）")
        -- 立刻扫一批（而不是等下一个 8Hz 周期）：ApplyEnhancements 里
        -- SetEnabled(false) 先把实体全交还了，紧接着 SetMarkMode(true) 才走到这里
        -- —— 中间那一拍 mounted 是空的，影子会趁空印到本体上（开关瞬间的 BUG①）。
        -- 只有真正翻转 mark_mode 时才会执行到这里（上面有提前 return），
        -- 所以不会每帧都扫；Sweep 自带 Guard、每轮上限 MOUNT_PER_SWEEP，不卡帧。
        M.Sweep()
    end
end

function M.SetStrength(v)
    M.strength = math.max(0, math.min(1, tonumber(v) or 1.0))
end

function M.Info()
    local theta, el, k = M.SunParams()
    -- 面板/日志仍然用"屏幕横位"表达左右（人看得懂），但**同时**报出 sin(theta)
    -- 也就是顺逆光分量：排查"逆光没变全暗"时，这一项才是关键读数
    -- （sin>0 = 看见受光面，sin<0 = 逆光看背光面，≈0 = 纯侧光）。
    local sun_x = math.cos(theta)
    local facing = math.sin(theta)
    local line = string.format(
        "启用=%s 水印=%s 强度=%.2f 已挂载=%d（累计 %d 让位 %d 认领 %d）| 太阳屏幕横位=%+.3f 顺逆光=%+.3f 仰角=%.1f° 输出强度=%.3f",
        tostring(M.enabled), tostring(M.mark_mode), M.strength or 1, MountedCount(), mount_count, yield_count,
        ours_rescue, sun_x, facing, el / DEG, k)
    print("[BCAS] 物体光照自检: " .. line)
    if last_push ~= nil then
        print(string.format("[BCAS] 物体光照上次上报: 屏幕横位=%+.3f 顺逆光=%+.3f 仰角=%.1f° 强度=%.3f 目标=%d 附近光源=%d（跟踪 %d）光柱=%d",
            math.cos(last_push.az), math.sin(last_push.az), last_push.el / DEG, last_push.k,
            last_push.n, last_push.lights or 0, last_push.tracked or 0, last_push.beams or 0))
    end
    return line
end

-- 实机手调：光柱对受光对比的加成（0 = 光柱完全不影响受光背光）
function M.SetBeamGain(v)
    M.BEAM_GAIN = math.max(0, math.min(2, tonumber(v) or 0))
    Log(string.format("光柱强度增益 = %.2f", M.BEAM_GAIN))
end

-- 附近有没有光（0..1）：**夜间影子浓度的唯一来源**（2026-09-20 第五轮实机：
-- 「那个白天跟随太阳，除此之外跟随辉光源朝向的逻辑你恢复它」）。
--
-- 第一性原理：影子的**存在**取决于有没有光，方向取决于光从哪来。
--   · 白天：光 = 太阳  ⇒ 浓度 = 日晷因子（bcas_state 里已有，一动没动）。
--   · 夜里：光 = 附近辉光源（火把/灯笼/火堆）⇒ 浓度 = 这里返回的照度。
-- 没有光就没有影子 —— 这是物理事实。旧版拿太阳 alpha 当夜间光强，而 alpha 在夜里
-- 恒 0 ⇒ 浓度精确为 0，于是"晚上没影子、朝向也看不出跟光源走"（方向解算其实一直
-- 是对的，只是被浓度乘成了 0）。
--
-- 复用 LightStrengthFor 的同一条 near_k 曲线（不是另写一套）：这样"影子浓度"与
-- "受光面亮度"同源，站在同一盏灯下时两者一起变，不会一个亮了一个还没影子。
function M.LightPresence()
    if #tracked == 0 then return 0 end
    local px, pz = PlayerPos()
    if px == nil then return 0 end
    local best = 0
    for i = 1, #tracked do
        local l = tracked[i]
        if l.x ~= nil then
            local dx, dz = l.x - px, l.z - pz
            local d2 = dx * dx + dz * dz
            if d2 <= l.r * l.r then
                local t = math.sqrt(d2) / l.r
                local near_k = 1.0 - (t * t * (3 - 2 * t) * 0.72 + t * 0.28)
                if near_k < 0 then near_k = 0 end
                local w = l.w * near_k * near_k   -- 与 LightStrengthFor 同源（那边也平方一次）
                if w > best then best = w end
            end
        end
    end
    if best > 1 then best = 1 end
    return best
end

-- 灯表规模（探针用）：LightPresence 为 0 有两种完全不同的原因 —— "附近真没光"
-- 与"灯表本身是空的（tracked 没建起来）"，只看返回值分不出来（2026-09-21）。
function M.LightCount()
    return #tracked
end

-- 背光面接触影（B5）：**没有**运行时旋钮，这是有意的。
-- 它的深度常量（BCAS_LF_CONTACT = 0.38）在着色器里编译死了，因为
-- FLOAT_PARAMS 三个槽已经排满（方位 / 仰角 / 强度），再加一个"接触影深度"就没有
-- 地方放了 —— 硬加一个 setter 只会变成一个**看起来能调、其实到不了着色器**的假旋钮。
-- 要改深度就改 tools/make_surface_light_shader.py 顶部的常量并重新生成（和 A3 那三个
-- 常量一样的流程），同时 tools/surfacelight_sim.py 里会有一致性检查逼着两边同步。
-- 实机上"这条效果要不要 / 要多强"用面板强度条就行：它乘在接触影上，
-- 强度 = 0 时逐像素等于原版（夜里/洞穴完全还原）。
-- 想彻底关掉受光面这套：面板的 SurfaceLight 开关。

return M
