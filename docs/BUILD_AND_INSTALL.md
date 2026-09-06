# 构建与安装指南

## 安装（玩家）

1. 把整个 `BCAS-Studio/` 文件夹复制到游戏的 mods 目录：
   `...\SteamLibrary\steamapps\common\Don't Starve Together\mods\BCAS-Studio`
2. 启动 DST → 主菜单「模组」→ 勾选「BCAS Studio 画质增强」→ 应用
   （建议配置里预设选「standard 特调方案」、高清字体保持开启）。
3. 进入世界后：
   - `Home` 打开画质工作室面板（键位可在 mod 配置改）
   - `PgDn` 保存并关闭面板（`ESC` 放弃更改并回滚快照）
   - `P` 快速开/关整条后处理管线
4. 面板顶部三套一键预设：**# 特调方案**（作者定版）· **# 轻量画质** · **# 电影胶片**。

## 验证是否加载成功

看日志 `...\Klei\DoNotStarveTogether\client_log.txt`，搜索 `BCAS`：

```
[BCAS] 后处理效果注册成功 (id=…)
[BCAS] uniform BCAS_GRADE_A handle = …
[BCAS] 已载入保存的设置
```

## 从源码构建着色器

本 Mod 的 ksh 不需要外部编译器：`tools/build_ksh.py` 把 GLSL ES 源码
直接组装为引擎可加载的 `.ksh` 容器。

```bash
python tools/build_ksh.py          # 构建 src_shaders/ 下全部着色器
python tools/build_ksh.py 源.ps 输出.ksh   # 单独构建一个
python tools/make_modicon.py       # 模组图标 → KTEX(DXT5 全 mip 链)
python tools/build_sarasa_font.py  # 高清字体打包
```

产物直接写入 `BCAS-Studio/shaders/`，构建后把 `BCAS-Studio/` 复制到
游戏 mods 目录（或使用目录联接）即可生效。

### 构建管线要点（踩坑沉淀，改代码前必读）

- **ksh 容器**：`[名称][条目表][vs 源][ps 源][尾块]`。尾块 =
  `[vs 引用数][索引...][ps 引用数][索引...]`，索引指向条目表——
  自定义 VS 的 uniform 必须登记进 vs_refs。
- **后处理 pass 有 ~4096 字节源码缓冲限制**：GLSL 必须经
  `minify_glsl` 压成单行 + NUL 尾，超线会静默编译失败（注册成功但无效果）。
- **实体 effect handle 路线无此限制**：多行 CRLF + NUL 尾即可。
- **uniform 必须在源码中真实使用**：只声明不使用会被编译器优化掉，
  引擎查 uniform 索引得 0xFFFFFFFF 直接原生断言闪退。
- **KTEX 纹理布局**：`[8B 头][全部 mip 元数据依次][全部 mip 数据依次]`，
  元数据与数据绝不交错；mip 链必须完整到 1×1，断链 / 交错都会
  `HWTexture::DeserializeTexture failed (0x501)`。
- **GLSL 源码纯 ASCII**：ANGLE 编译器拒绝任何非 ASCII 字符（含注释）。
- **实体 effect 的 SetXXXEffect 接口只吃 VFS 绝对路径**：
  传裸相对路径会触发引擎资源句柄原生断言（pcall 拦不住），
  必须先过 `resolvefilepath`。

### 常见故障

| 症状 | 原因与处置 |
| --- | --- |
| 面板一开就闪退 | Lua 字符串字面量里混入真实换行（`unfinished string`），改用 `\n` 转义 |
| 进世界后贴图黑块/报 0x501 | KTEX 布局或 mip 链不完整，见上 |
| 效果注册成功但画面无变化 | 后处理源码超 ~4096 字节被截断，压缩源码 |
| 开着 mod 冷启动必崩 | 字体 fallback 挂载过早（须在引擎 LoadFonts 之后，见 modmain 注释） |

## 目录结构

```
BCAS-Studio/                 ← Mod 本体
├── modinfo.lua              ← 元信息 + 启动配置（预设/高清字体/热键）
├── modmain.lua              ← 官方钩子接入、热键、面板入口、字体整合
├── scripts/
│   ├── bcas_state.lua       ← 参数状态机：40+ 参数 / 预设 / 持久化（单一数据源）
│   ├── bcas_screen.lua      ← 画质工作室面板（7 页签 + 白平衡色轮弹窗）
│   ├── bcas_sun_emitter.lua ← 动态太阳：日晷模型 / 剪影投影 / 透云光束
│   └── bcas_ocean.lua       ← 海洋地皮调色（世界生成烘焙）
├── shaders/                 ← 构建产物（.ksh，勿手改）
├── fonts/                   ← 更纱黑体（SIL OFL，见 ATTRIBUTION.txt）
└── anim/                    ← 投影剪影动画
src_shaders/                 ← 全部 GLSL ES 源码（cinema/studio/glow×5）
tools/                       ← build_ksh / ksh_parse / make_modicon 等
docs/                        ← 架构 / 能力矩阵 / 本文件 / 工坊文案
```
