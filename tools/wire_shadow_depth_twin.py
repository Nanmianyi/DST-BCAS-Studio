"""一次性接线脚本：给影子加"写深度孪生体"（单层混合）+ 深度状态/图层调整。

执行完即完成本次改动；重复执行会因为锚点数量不符而报错（幂等保护）。
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


# 1) fx 克隆：层改到 LAYER_WORLD_BACKGROUND（晚于写深度孪生体所在层）+ 深度测试
rep("""    fx.AnimState:UsePointFiltering(false)
    fx.AnimState:SetLayer(LAYER_BACKGROUND)
    fx.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)""",
    """    fx.AnimState:UsePointFiltering(false)
    -- 装备克隆在 LAYER_WORLD_BACKGROUND（晚于写深度孪生体的 LAYER_BACKGROUND）：
    -- 本体孪生体先把深度写进去，装备影子与本体重叠的部分（在更远处）会被深度
    -- 测试挡掉，不再和本体叠加变深。深度测试开、写入关（只挡别人、不改深度）。
    fx.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    fx.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    pcall(fx.AnimState.SetDepthTestEnabled, fx.AnimState, true)
    pcall(fx.AnimState.SetDepthWriteEnabled, fx.AnimState, false)""")

rep("    ApplyShadowShader(fx.AnimState)",
    "    ApplyShadowShader(fx.AnimState, SHADOW_MODE_VISIBLE)")

# 2) DestroyShadow：连孪生体一起销毁
rep("""local function DestroyShadow(shadow)
    if shadow == nil then return end
    KillItemFx(shadow, "swap_object")
    KillItemFx(shadow, "head")
    KillItemFx(shadow, "body")
    if shadow:IsValid() then shadow:Remove() end
end""",
    """local function DestroyShadow(shadow)
    if shadow == nil then return end
    KillItemFx(shadow, "swap_object")
    KillItemFx(shadow, "head")
    KillItemFx(shadow, "body")
    -- 写深度孪生体跟着影子一起销毁：留着会继续往深度缓冲写"已经没有影子"的形状
    local tw = shadow._wtwin
    shadow._wtwin = nil
    if tw ~= nil and tw:IsValid() then tw:Remove() end
    if shadow:IsValid() then shadow:Remove() end
end""")

# 3) 可见影子：深度状态 + 图层 + 建孪生体
rep("""    shadow.AnimState:SetMultColour(0, 0, 0, 0)
    shadow.AnimState:SetManualBB(0, 0, 0, 0)""",
    """    shadow.AnimState:SetMultColour(0, 0, 0, 0)
    shadow.AnimState:SetManualBB(0, 0, 0, 0)
    -- 深度测试开、写入关：靠写深度孪生体（更早的图层）挡住同像素上更远的部件，
    -- 实现"每像素只混合一次"。可见影子自己不写深度，不会裁掉后面的世界物体。
    pcall(shadow.AnimState.SetDepthTestEnabled, shadow.AnimState, true)
    pcall(shadow.AnimState.SetDepthWriteEnabled, shadow.AnimState, false)""")

rep("""    shadow.AnimState:SetLayer(LAYER_BACKGROUND)
    shadow.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)""",
    """    -- 图层必须晚于写深度孪生体（LAYER_BACKGROUND），保证"先写深度、后画可见层"
    shadow.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    shadow.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)""")

rep("    ApplyShadowShader(shadow.AnimState)",
    "    ApplyShadowShader(shadow.AnimState, SHADOW_MODE_VISIBLE)")

rep("""    ent._bcas_shadow = shadow
    shadow._parent_ent = ent""",
    """    ent._bcas_shadow = shadow
    shadow._parent_ent = ent
    -- 写深度孪生体：同 bank/build/动画/姿态，不可见，只写深度（单层混合的关键）
    MakeWriteTwin(shadow)""")

# 4) CopyAnim 镜像（引擎态变化处）
rep("""        if bank_hash and bank_hash ~= sa:GetBankHash() then
            sa:SetBank(bank_hash)
            shadow._last_bank_hash = bank_hash""",
    """        if bank_hash and bank_hash ~= sa:GetBankHash() then
            sa:SetBank(bank_hash)
            MirrorTwin(shadow, "SetBank", bank_hash)
            shadow._last_bank_hash = bank_hash""")

rep("""        if bank and (force or bank ~= shadow._last_bank) then
            shadow._last_bank = bank
            sa:SetBank(bank)""",
    """        if bank and (force or bank ~= shadow._last_bank) then
            shadow._last_bank = bank
            sa:SetBank(bank)
            MirrorTwin(shadow, "SetBank", bank)""")

rep("""    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        shadow._last_leaf = nil""",
    """    if build ~= nil and build ~= sa:GetBuild() then
        shadow._last_build = build
        sa:SetBuild(build)
        MirrorTwin(shadow, "SetBuild", build)
        shadow._last_leaf = nil""")

rep("""            if sb ~= shadow._last_skin then
                shadow._last_skin = sb
                pcall(sa.SetSkin, sa, sb, base)""",
    """            if sb ~= shadow._last_skin then
                shadow._last_skin = sb
                pcall(sa.SetSkin, sa, sb, base)
                MirrorTwin(shadow, "SetSkin", sb, base)""")

rep("""            local base = pa.prefab
            if type(base) == "string" and base ~= "" then
                sa:SetBuild(base)
                shadow._last_build = base""",
    """            local base = pa.prefab
            if type(base) == "string" and base ~= "" then
                sa:SetBuild(base)
                MirrorTwin(shadow, "SetBuild", base)
                shadow._last_build = base""")

rep("""            pcall(sa.PlayAnimation, sa, anim_hash, loop)
            shadow._last_anim = anim_hash
            shadow._last_anim_hash = anim_hash""",
    """            pcall(sa.PlayAnimation, sa, anim_hash, loop)
            MirrorTwin(shadow, "PlayAnimation", anim_hash, loop)
            shadow._last_anim = anim_hash
            shadow._last_anim_hash = anim_hash
            shadow._last_anim_loop = loop""")

rep("""    if shader_dirty then
        ApplyShadowShader(sa)
    end""",
    """    if shader_dirty then
        ApplyShadowShader(sa, SHADOW_MODE_VISIBLE)
    end""")

# 5) CopyFrame 镜像（帧必须一致，否则会拒绝掉正确的像素）
rep("""                sa:PlayAnimation(shadow._last_anim_name, LOOP_ANIMS[shadow._last_anim_name] == true)
                shadow._last_frame = nil
                return
            end
            if frame ~= shadow._last_frame then
                shadow._last_frame = frame
                local num = sa:GetCurrentAnimationNumFrames()
                if num and num > 0 then
                    sa:SetFrame(frame % num)
                end
            end""",
    """                sa:PlayAnimation(shadow._last_anim_name, LOOP_ANIMS[shadow._last_anim_name] == true)
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
            end""")

# 6) ApplyPose：翻转缩放镜像
rep("""        if flip ~= shadow._last_flip then
            shadow._last_flip = flip
            sa:SetScale(flip and -1 or 1, 1)
        end""",
    """        if flip ~= shadow._last_flip then
            shadow._last_flip = flip
            sa:SetScale(flip and -1 or 1, 1)
            MirrorTwin(shadow, "SetScale", flip and -1 or 1, 1)
        end""")

# 7) 坐骑覆盖 build 镜像
rep("""                                            pcall(sa.AddOverrideBuild, sa, m_build)
                                            shadow._last_mount_build = m_build
                                            -- 覆盖 build 变化同样重挂一次剪影着色器（只在变化时）
                                            ApplyShadowShader(sa)""",
    """                                            pcall(sa.AddOverrideBuild, sa, m_build)
                                            MirrorTwin(shadow, "AddOverrideBuild", m_build)
                                            shadow._last_mount_build = m_build
                                            -- 覆盖 build 变化同样重挂一次剪影着色器（只在变化时）
                                            ApplyShadowShader(sa, SHADOW_MODE_VISIBLE)""")

rep("""                                    pcall(shadow.AnimState.ClearOverrideBuild, shadow.AnimState, shadow._last_mount_build)
                                    shadow._last_mount_build = nil""",
    """                                    pcall(shadow.AnimState.ClearOverrideBuild, shadow.AnimState, shadow._last_mount_build)
                                    MirrorTwin(shadow, "ClearOverrideBuild", shadow._last_mount_build)
                                    shadow._last_mount_build = nil""")

if "ApplyShadowShader(sa)" in s and "ApplyShadowShader(sa, SHADOW_MODE" not in s.replace("ApplyShadowShader(sa, SHADOW_MODE", ""):
    pass
assert s.count("ApplyShadowShader(sa)") == 0, "还有未指定模式的 ApplyShadowShader 调用"

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('edits applied:', n)
