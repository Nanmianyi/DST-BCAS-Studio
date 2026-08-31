name = "BCAS Studio 画质增强"
description = [[
【BCAS Studio —— 饥荒联机版画质增强 · 全开源 (MIT)】

≡ 仓库位置（全开源）≡
GitHub: https://github.com/Nanmianyi/DST-BCAS-Studio
（含全部源码：GLSL 双 pass 着色器、参数状态机、UI、ksh 构建工具链、开发文档）
任何人都可以下载、学习、二次开发、借鉴、魔改——我没任何意见，玩得开心就好。

≡ 这是什么 ≡
饥荒联机版第一个成功打通【全自定义后处理管线】的 Mod，
也是一个真正具备实质性画质提升、具备深度后处理管线的 Mod——
不只是调色，而是真正的画质修复与增强。

≡ 锐化：来自 BCAS，与显卡滤镜有本质区别 ≡
BCAS 来自作者前些年对 AMD CAS 锐化后处理技术的改进开源算法
"BCAS"（双边自适应锐化）。核心思想：针对图形资源做超高质量的锐化处理，
同时不产生任何可见过冲与伪影，等效提升画质清晰度，并进行高质量的色彩处理。

双边锐化是一种高质量的离线锐化技术，常见于 Photoshop、达芬奇等软件，
效果自然但传统形式开销巨大。BCAS 只使用等同于 CAS 的十字形 5 采样开销，
就实现了等价双边锐化的自然效果——几乎不产生伪影与振铃过冲。
锐化是提升清晰度的好手段，但副作用令人诟病良久——
想过对画质无损的锐化是什么样的吗？就是这套：
YCoCg 色亮分离、MAD4 活动量估计、σ 自适应双边范围核、细节层压缩、
软限幅、AURA 包络抗过冲、暗部保护、色度保护与微饱和跟随，
外加 8-bit 加固（2LSB 噪声底限 / TPDF 抖动抗色带 / 软底 EOTF 防暗部坍塌）。
同占用下远超 CAS，且只锐世界画面、不碰 HUD、零 Lua 每帧开销。

≡ 这意味着什么 ≡
全自定义后处理管线一旦打通，意味着 ReShade 里你能想到的超分算法和
各种效果，理论上都可以用同样的方式接入饥荒。本 Mod 就是这条路的
先行验证：双 pass 实时管线（电影调色引擎 → 锐化与终合成），
40+ 项参数游戏内实时可调、自动保存。

≡ 调色引擎 ≡
曝光 EV / 白平衡（体素无级调色轮取色）/ CDL 一级二级（斜率·偏移·幂）/
高光去饱和 / ACES 胶片曲线（sRGB 软底 EOTF）/ 饱和·对比·亮度·Gamma，
外加暗角、动态胶片颗粒（8Hz 闪动）、原版昼夜滤镜开关，
以及内置思源黑体高清字体——不用再订阅字体 Mod。

≡ 使用 ≡
进世界后按 Home 打开画质工作室，预设选「作者特调」即为作者实机调校的
发布画质；拖数值 / 点数值键入 / 行尾 R 复位，实时预览自动保存。
热键：Home 开关面板 · PgDn 保存 · ESC 放弃 · P 开关滤镜。
字体 Mod 二选一（本 Mod 已内置思源黑体）。

作者：楠眠已 | 开源协议：MIT（字体资源归其原作者所有）
]]
author = "楠眠已"
version = "3.0.1"

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
        hover = "内置思源黑体（SIL OFL 1.1）。启用后请关闭其他字体 mod 以免冲突。全局生效，含主菜单。",
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
