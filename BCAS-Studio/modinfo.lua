name = "BCAS Studio 画质增强"
description = [[饥荒史上第一个真正实质性提升画质的深度后处理 Mod。

不再只是调颜色：双 pass 实时后处理管线（电影级调色引擎 + 双边自适应锐化），
科学补偿饥荒缺失的动态范围与色彩，显著提升动态范围、纹理质感与边缘清晰度，
效果等同甚至超越外挂 ReShade——但它是纯游戏内 Mod，一键开关、实时调参、自动保存。

双 pass 实时管线：
  · 调色引擎：曝光 EV / 白平衡(调色轮) / CDL 一级二级(斜率·偏移·幂) /
    高光去饱和 / ACES 胶片曲线 / 饱和·对比·Gamma，40+ 项深度可调；
  · 锐化管线：双边自适应锐化(MAD4 活动量估计 + σ 自适应范围核 + 细节层压缩
    + 软限幅 + AURA 包络抗过冲 + 暗部保护)，8-bit 加固(2LSB 噪声底限 +
    TPDF 抖动抗色带 + 软底 EOTF 防暗部坍塌)，只锐世界画面、不碰 HUD；
  · 氛围：暗角 / 动态胶片颗粒(8Hz 闪动) / 原版昼夜滤镜开关；
  · 高清字体：思源黑体全局替换(可关)。

游戏内 Home 打开画质工作室面板：拖数值 / 点数值键入 / 体素无级调色轮，
实时预览、自动保存。默认参数 = 作者特调(实机调校)。

热键：Home 开/关面板 · PgDn 保存并关闭 · ESC 放弃更改 · P 开关滤镜。]]
author = "楠眠已"
version = "3.0.0"

forumthread = ""

api_version = 10

dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false

-- 纯客户端渲染效果
all_clients_require_mod = false
client_only_mod = true

server_filter_tags = {}

-- 尽早加载，保证字体覆盖先于读取字体常量的其他 mod
priority = -2018

local KEY_OPTIONS = {
    {description = "禁用", data = "NONE"},
    {description = "Home", data = "KEY_HOME"},
    {description = "P", data = "KEY_P"},
    {description = "O", data = "KEY_O"},
    {description = "B", data = "KEY_B"},
    {description = "V", data = "KEY_V"},
    {description = "K", data = "KEY_K"},
    {description = "L", data = "KEY_L"},
}

configuration_options = {
    {
        name = "PRESET",
        label = "初始预设",
        hover = "首次启用时的画面风格。之后的调整以游戏内面板保存的设置为准。",
        options = {
            {description = "作者特调（默认）", data = "standard"},
            {description = "轻量", data = "light"},
            {description = "电影", data = "cinema"},
            {description = "关闭（仅装不用）", data = "off"},
        },
        default = "standard",
    },
    {
        name = "HDFONT",
        label = "高清字体",
        hover = "整合自创意工坊 2403997762（TsAIM/华康方圆体W7）。启用后请关闭原字体 mod 以免冲突。全局生效，含主菜单。",
        options = {
            {description = "启用", data = "on"},
            {description = "关闭", data = "off"},
        },
        default = "on",
    },
    {
        name = "HOTKEY_TOGGLE",
        label = "滤镜开关热键",
        hover = "游戏中一键启用/禁用整个滤镜。",
        options = KEY_OPTIONS,
        default = "KEY_P",
    },
    {
        name = "HOTKEY_UI",
        label = "设置面板热键",
        hover = "游戏中打开设置面板；面板打开时再按 = 不保存关闭。PgDn = 保存并关闭，ESC = 放弃更改。",
        options = KEY_OPTIONS,
        default = "KEY_HOME",
    },
}
