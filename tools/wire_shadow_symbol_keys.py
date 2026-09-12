"""接线脚本 3：给每个符号一个互不相同的深度档（离散 key）。

为什么：深度错位如果跟着"美术高度"这种连续量走，两个部件高度几乎一样时深度也
几乎一样 -> 互相打架 -> 疯狂闪烁、若隐若现（用户实测：部件多的角色最明显）。
把每个【符号】编上号（1..N），错位量就是离散且互不相同的，同一像素上两个部件
的深度差至少一个档位，稳定可判，不再闪。

实现：AnimState:SetSymbolLightOverride(symbol, k)（引擎会把 k 作为 PARAMS.y 喂给
该符号那一次绘制），顶点着色器读 PARAMS.y 当深度档。符号名按"通用部件名 +
prefab_/build_ 前缀"候选，用 BuildHasSymbol 过滤，结果按 build 缓存。
"""
import io
import pathlib
import sys

P = pathlib.Path('BCAS-Studio/scripts/bcas_sun_emitter.lua')
s = io.open(P, encoding='utf-8').read()
n = 0


def rep(old, new, cnt=1):
    global s, n
    got = s.count(old)
    if got != cnt:
        print(f'[FAIL] 期望 {cnt} 处，实际 {got} 处:\n{old[:200]}')
        sys.exit(1)
    s = s.replace(old, new)
    n += cnt


# 1) 开关 + 符号候选表 + 按 build 缓存的编号逻辑（放在 ApplyShadowShader 之前）
rep("""local SHADOW_MODE_VISIBLE = 2.0   -- 本体可见层（前推最多）""",
    """-- 每个符号一个离散深度档（见 shader 里 PARAMS.y 的用法）。关掉就退回
-- "只按美术高度错位"，那种在部件很多、高度接近时会闪烁。
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
    for name in pairs(SYMBOL_CANDIDATES) do
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

-- 把编号表刷到某个 AnimState 上（BuildHasSymbol/SetSymbolLightOverride 都是
-- 引擎调用，出错只影响深度档，所以全部 pcall）
local function ApplySymbolKeys(sa, build)
    if sa == nil or sa.SetSymbolLightOverride == nil then return end
    local keys = GetSymbolKeys(sa, build)
    if keys == nil then return end
    for name, k in pairs(keys) do
        pcall(sa.SetSymbolLightOverride, sa, name, k)
    end
end

-- 影子浓度哨兵：影子实体 SetFloatParams(0, 0, MODE) 时着色器进入对应模式。""")

# 2) 建影子和孪生体时、以及 build/皮肤变化后刷编号
rep("""    shadow._art_top = nil""", """    shadow._art_top = nil""", 0)

rep("""    -- 写深度孪生体：同 bank/build/动画/姿态，不可见，只写深度（单层混合的关键）
    MakeWriteTwin(shadow)""",
    """    -- 写深度孪生体：同 bank/build/动画/姿态，不可见，只写深度（单层混合的关键）
    MakeWriteTwin(shadow)
    -- 每个符号一个离散深度档（滑不滑由 build 决定，缓存）
    ApplySymbolKeys(shadow.AnimState, shadow._last_build)""")

rep("""    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        MirrorTwin(shadow, "SetBuild", build)
        shadow._last_leaf = nil""",
    """    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        MirrorTwin(shadow, "SetBuild", build)
        -- SetBuild 会清掉符号覆盖（包括我们的编号），必须重刷
        ApplySymbolKeys(sa, build)
        ApplySymbolKeys(shadow._wtwin and shadow._wtwin:IsValid()
            and shadow._wtwin.AnimState or nil, build)
        shadow._last_leaf = nil""")

rep("""            if sb ~= shadow._last_skin then
                shadow._last_skin = sb
                pcall(sa.SetSkin, sa, sb, base)
                MirrorTwin(shadow, "SetSkin", sb, base)""",
    """            if sb ~= shadow._last_skin then
                shadow._last_skin = sb
                pcall(sa.SetSkin, sa, sb, base)
                MirrorTwin(shadow, "SetSkin", sb, base)
                -- SetSkin 同样会清掉符号覆盖
                ApplySymbolKeys(sa, sb)
                ApplySymbolKeys(shadow._wtwin and shadow._wtwin:IsValid()
                    and shadow._wtwin.AnimState or nil, sb)""")

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('edits applied:', n)
