name = "BCAS Studio 光影引擎"
description = [[
【BCAS Studio V6 光影引擎 —— 饥荒联机版画质增强 · 全开源 (MIT)】

保留饥荒原本的手绘美学，然后把它调到最好。
第一个打通全自定义后处理管线的饥荒画质增强 Mod：
锐化、墨线修复、电影调色、辉光、动态太阳光影，全部游戏内实时完成。
40+ 参数实时可调、自动保存，性能开销与原版后处理相当。

≡ 动态全局光影（此前，饥荒没有光影）≡
原版的世界没有太阳：角色脚下只有一个圆形黑斑，夜晚只有光源照明，
地上的树、建筑与黑夜之间没有任何光影关系。
本 Mod 从零补上这一层——

· 世界空间太阳（日晷模型）：单一解析式输出全局共享的影子长度、
  旋角、透明度与色温。清晨影子长而淡，正午收短变实，傍晚拉长，
  太阳第一次在饥荒里走完一天。
· 剪影投影系统：角色与大型地物挂载贴地剪影，与本体动画逐帧相位同步；
  皮肤、骑乘（骑手+坐骑双剪影）、换装、树木生长阶段全部跟随；
  砍伐、燃烧、收割即时换形态。
· 满月夜月光投影（染月光蓝），雨雪衰减，冬季收敛。
· 性能架构：移动实体逐帧、静态实体距离分层帧预算 + 错峰种子、
  夜晚与洞穴零开销门控——满帧稳定。
· 透云光束：光斑按 gap→in→hold→out 状态机模拟云层开合，
  随机落在玩家周边缓缓显隐，引擎光源给遮挡物勾暖亮边。
· 太阳全局光：太阳屏幕位置驱动调色引擎的天光方向。

≡ 反卷积墨线修复 ≡
在饥荒内引入反卷积算法，对图集合成流程造成的贴图模糊做在线重置。
经典反卷积依赖点扩散函数估计，摄影场景的 PSF 逐帧变化、运动物体
需要单独建模；饥荒贴图的模糊来源则是确定量——图集合成与多级
双线性缩放的低通损耗，核可参数化为已知量，问题从估计退化为求解。
实现：边缘法向检测 + 双边门控核 + 暗部穿透补偿，
被图集流程抹糊的轮廓线重新收回笔锋状态。

≡ 双边自适应锐化 ≡
来自作者对 AMD CAS 锐化算法的改进开源算法 「BCAS」。
等同 CAS 的十字形 5 采样开销，实现离线工具级的双边锐化质量：
YCoCg 色亮分离、MAD4 活动量估计、σ 自适应双边范围核、细节层压缩
与软限幅、AURA 包络抗过冲、暗部保护、色度保护，
外加 8-bit 加固（TPDF 抖动 / 2LSB 底限 / 软底 EOTF）。
只锐游戏世界，HUD 不受影响，Lua 零每帧开销。

≡ 电影调色引擎 ≡
曝光 EV / 白平衡光学色轮（HSV ↔ 色温色调解析映射）/
CDL 一级二级校正（ASC 原语）/ 高光去饱和 / ACES 胶片曲线混合
（软底 EOTF）/ 原画混合，外加暗角与 8Hz 动态胶片颗粒。
官方调色强度接管：复用官方季节/昼夜 LUT，0=原色 ~ 1=原版。

≡ 辉光管线接管 ≡
开启辉光时原生 Bloom 完全置空，由本 Mod 全权替代：
Kawase 四层金字塔柔光 + 软膝预滤（只让真光源通过）+ 暖色偏移
+ 光晕长尾（对数消散）+ 光包裹（暖光沁入阴影）+ 轮廓光（光源勾边）
+ 透云光束 + Reinhard 高光压缩 + 呼吸微闪。
开销与原版 Bloom 相当，氛围表现不在一个量级。

≡ 海洋地皮调色 ≡
绿洲系通透青绿的海洋配色（8 地块含深浅分层与小地图配色），
世界生成时烘焙进海洋纹理，零额外渲染开销。

≡ 原版滤镜接管 ≡
低SAN保色 / 失真消除 / 积雪上限 / 风沙遮罩过滤，四个实时开关，全部可逆。

≡ 画质工作室 ≡
进世界按 Home 打开：7 页签 40+ 参数，拖动即实时预览，
行尾 R 复位，白平衡光学色轮取色，三套一键预设
（特调方案 / 轻量画质 / 电影胶片，同一基底不同强度）。
全部改动自动保存。

≡ 内置高清字体 ≡
思源黑体（Source Han Sans）85px 视网膜重铸版：
非线性对比度强化 + 灰肩边缘去雾收敛，消除 41% 的半透明发灰边缘，
笔画收敛为刀刻纯白；9940 字符 100% 契合（SIL OFL 1.1）。
无需再订阅字体 Mod（字体 Mod 二选一）。

≡ 使用 ≡
进世界后按 Home 打开画质工作室，预设选「# 特调方案」即为作者实机
调校的定版画质。热键：Home 开关面板 · PgDn 保存 · ESC 放弃 · P 开关滤镜。

≡ 性能与兼容 ≡
纯客户端 Mod（client_only_mod），专用服务器零渲染开销；
与地图类 / 角色类 Mod 无冲突；不修改任何游戏文件。

≡ 版本 ≡
v3.6.0（V6）：动态全局太阳光影与透云光束实装；反卷积墨线修复；
辉光管线接管；海洋地皮调色定版；白平衡光学色轮；三套预设重调
（同一基底不同强度）；移除实验性水面折射层。

≡ 协议 ≡
代码 MIT 开源。内置字体版权归思源黑体项目所有（SIL OFL）。
《饥荒：联机版》相关素材版权归 Klei Entertainment 所有。

作者：楠眠已 | NANMIANYI LAB
完整技术文档：https://github.com/Nanmianyi/DST-BCAS-Studio
]]
author = "楠眠已"
version = "3.6.2"

icon_atlas = "modicon.xml"
icon = "modicon.tex"

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

-- 全键盘可用按键列表 (包含 F1-F12, 常用控制键, A-Z, 0-9 等)
local KEY_OPTIONS = {
    {description = "禁用", data = "NONE"},
    -- 功能键 F1-F12
    {description = "F1", data = "KEY_F1"},
    {description = "F2", data = "KEY_F2"},
    {description = "F3", data = "KEY_F3"},
    {description = "F4", data = "KEY_F4"},
    {description = "F5", data = "KEY_F5"},
    {description = "F6", data = "KEY_F6"},
    {description = "F7", data = "KEY_F7"},
    {description = "F8", data = "KEY_F8"},
    {description = "F9", data = "KEY_F9"},
    {description = "F10", data = "KEY_F10"},
    {description = "F11", data = "KEY_F11"},
    {description = "F12", data = "KEY_F12"},
    -- 导航与控制键
    {description = "Home", data = "KEY_HOME"},
    {description = "End", data = "KEY_END"},
    {description = "PageUp", data = "KEY_PAGEUP"},
    {description = "PageDown", data = "KEY_PAGEDOWN"},
    {description = "Insert", data = "KEY_INSERT"},
    {description = "Delete", data = "KEY_DELETE"},
    {description = "Tab", data = "KEY_TAB"},
    {description = "Space", data = "KEY_SPACE"},
    {description = "Backspace", data = "KEY_BACKSPACE"},
    {description = "Pause/Break", data = "KEY_PAUSE"},
    {description = "波浪号 (~)", data = "KEY_TILDE"},
    {description = "减号 (-)", data = "KEY_MINUS"},
    {description = "等号 (=)", data = "KEY_EQUALS"},
    {description = "左方括号 ([)", data = "KEY_LEFTBRACKET"},
    {description = "右方括号 (])", data = "KEY_RIGHTBRACKET"},
    {description = "分号 (;)", data = "KEY_SEMICOLON"},
    {description = "句号 (.)", data = "KEY_PERIOD"},
    {description = "斜杠 (/)", data = "KEY_SLASH"},
    {description = "反斜杠 (\\)", data = "KEY_BACKSLASH"},
    -- 方向键
    {description = "↑ (Up)", data = "KEY_UP"},
    {description = "↓ (Down)", data = "KEY_DOWN"},
    {description = "← (Left)", data = "KEY_LEFT"},
    {description = "→ (Right)", data = "KEY_RIGHT"},
    -- 字母键 A-Z
    {description = "A", data = "KEY_A"},
    {description = "B", data = "KEY_B"},
    {description = "C", data = "KEY_C"},
    {description = "D", data = "KEY_D"},
    {description = "E", data = "KEY_E"},
    {description = "F", data = "KEY_F"},
    {description = "G", data = "KEY_G"},
    {description = "H", data = "KEY_H"},
    {description = "I", data = "KEY_I"},
    {description = "J", data = "KEY_J"},
    {description = "K", data = "KEY_K"},
    {description = "L", data = "KEY_L"},
    {description = "M", data = "KEY_M"},
    {description = "N", data = "KEY_N"},
    {description = "O", data = "KEY_O"},
    {description = "P", data = "KEY_P"},
    {description = "Q", data = "KEY_Q"},
    {description = "R", data = "KEY_R"},
    {description = "S", data = "KEY_S"},
    {description = "T", data = "KEY_T"},
    {description = "U", data = "KEY_U"},
    {description = "V", data = "KEY_V"},
    {description = "W", data = "KEY_W"},
    {description = "X", data = "KEY_X"},
    {description = "Y", data = "KEY_Y"},
    {description = "Z", data = "KEY_Z"},
    -- 数字键 0-9
    {description = "0", data = "KEY_0"},
    {description = "1", data = "KEY_1"},
    {description = "2", data = "KEY_2"},
    {description = "3", data = "KEY_3"},
    {description = "4", data = "KEY_4"},
    {description = "5", data = "KEY_5"},
    {description = "6", data = "KEY_6"},
    {description = "7", data = "KEY_7"},
    {description = "8", data = "KEY_8"},
    {description = "9", data = "KEY_9"},
}

configuration_options = {
    {
        name = "LIGHTING",
        label = "动态太阳光影总开关",
        hover = "一键启用或彻底关闭动态太阳光影系统（世界空间长影、日晷扫动、透云光束）。关闭后彻底下线所有影子实体与定时调度器，零性能开销！",
        options = {
            {description = "启用（默认）", data = "on"},
            {description = "彻底关闭", data = "off"},
        },
        default = "on",
    },
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
        hover = "内置思源黑体 (85px 视网膜重铸版)。边缘去雾提锐、纯白高透，字字如刀刻。全局生效，含主菜单。",
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
