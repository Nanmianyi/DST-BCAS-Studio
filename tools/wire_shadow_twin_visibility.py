"""接线脚本 2：写深度孪生体的可见性镜像。

孪生体只写深度，所以它必须和可见影子同开同关：影子被裁掉（视锥外/太远/夜里
alpha=0）时孪生体还留着写深度，会把别的东西裁出洞。这里把状态接起来：
  * 影子的 Hide/Show（两处裁剪循环）
  * 影子的 alpha（ApplyPose 里 aq<=0 的夜间分支）
  * 开关关闭时的统一隐藏
用上下文锚点定位（同样的缩进出现多次，纯缩进锚点会撞车）。
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
        print(f'[FAIL] 期望 {cnt} 处，实际 {got} 处:\n{old[:240]}')
        sys.exit(1)
    s = s.replace(old, new)
    n += cnt


# 0) 助手（定义在 MakeWriteTwin 之前）
rep("-- 把可见影子的引擎态镜像到孪生体。what = \"all\" 时用影子侧缓存值一次性重建",
    """-- 孪生体的显隐 = 影子可见 且 影子 alpha 不为 0。只在状态翻转时下发。
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

-- 把可见影子的引擎态镜像到孪生体。what = "all" 时用影子侧缓存值一次性重建""")

# 1) 孪生体建好先隐藏
rep("""    tw.entity:SetParent(shadow.entity)
    shadow._wtwin = tw
    MirrorTwin(shadow, "all")
    return tw""",
    """    tw.entity:SetParent(shadow.entity)
    shadow._wtwin = tw
    -- 先关着：等首轮姿态/alpha 同步确认后再亮，避免拿空状态写深度
    pcall(tw.Hide, tw)
    shadow._twin_shown = false
    MirrorTwin(shadow, "all")
    return tw""")

# 2) ApplyPose：alpha=0（夜里/日出前）→ 孪生体也关；恢复 → 打开
rep("""    if aq <= 0 then
        if shadow._last_a ~= 0 then
            shadow._last_a = 0
            shadow._last_aq = 0
            sa:SetMultColour(0, 0, 0, 0)
        end
        return
    end""",
    """    if aq <= 0 then
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
    end""")

# 3) 动态影子裁剪：隐藏/显示
rep("""                if not shadows_enabled or a <= 0.01 or (not shadow._is_player and ParentHidden(ent)) then
                    shadow:Hide()""",
    """                if not shadows_enabled or a <= 0.01 or (not shadow._is_player and ParentHidden(ent)) then
                    shadow:Hide()
                    shadow._shown = false
                    UpdateTwinVisible(shadow)""")

rep("""                    if dist_sq > FAR_SQ and not shadow._is_player then
                        shadow:Hide()
                    else
                        shadow:Show()""",
    """                    if dist_sq > FAR_SQ and not shadow._is_player then
                        shadow:Hide()
                        shadow._shown = false
                        UpdateTwinVisible(shadow)
                    else
                        shadow:Show()
                        shadow._shown = true
                        UpdateTwinVisible(shadow)""")

# 4) 静态影子裁剪：隐藏/显示
rep("""                if not shadows_enabled or ParentHidden(ent) or a <= 0.01 then
                    shadow:Hide()""",
    """                if not shadows_enabled or ParentHidden(ent) or a <= 0.01 then
                    shadow:Hide()
                    shadow._shown = false
                    UpdateTwinVisible(shadow)""")

rep("""                    if dist_sq > STATIC_HIDE_SQ then
                        shadow:Hide()
                    else
                        shadow:Show()""",
    """                    if dist_sq > STATIC_HIDE_SQ then
                        shadow:Hide()
                        shadow._shown = false
                        UpdateTwinVisible(shadow)
                    else
                        shadow:Show()
                        shadow._shown = true
                        UpdateTwinVisible(shadow)""")

# 5) 开关关闭时的统一隐藏
rep("""            if shadow:IsValid() then shadow:Hide() end""",
    """            if shadow:IsValid() then
                shadow:Hide()
                shadow._shown = false
                UpdateTwinVisible(shadow)
            end""", 2)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('edits applied:', n)
