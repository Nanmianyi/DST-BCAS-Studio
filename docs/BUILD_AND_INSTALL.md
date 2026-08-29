# 构建与安装指南

## 安装（直接用）

1. 把整个 `BCAS-Studio` 文件夹复制到游戏 mods 目录：
   `J:\SteamLibrary\steamapps\common\Don't Starve Together\mods\BCAS-Studio`
   （本仓库可能已经帮你复制好，见下文"当前状态"）。
2. 启动 DST → 主菜单「模组」→ 找到「BCAS Studio 画质增强」→ 勾选启用 → 应用。
3. 进入世界后：
   - `P` 开/关滤镜
   - `Home` 打开设置面板（与 ReShade 同键位，可在 mod 配置改）
   - `PgDn` 保存并关闭面板（`ESC` 放弃更改并回滚）

## 验证是否加载成功

看日志 `…\Don't Starve Together\client_log.txt`，搜索 `BCAS`：

```
[BCAS] 后处理效果注册成功 (id=…)
[BCAS] 已载入保存的设置
```

若出现 `[BCAS] 错误：bcas_studio.ksh 注册失败`，再向上翻引擎的着色器编译报错行。

## 重新构建着色器

改了 `src_shaders/bcas_studio.ps` 之后：

```
python tools/build_ksh.py            # 默认输入输出，含 GLSL↔条目表交叉校验
python tools/ksh_parse.py "BCAS-Studio/shaders/*.ksh"   # 字节级自检
```

依赖：Python 3（无任何第三方库）。老版 ShaderCompiler/Cg 工具链**不需要**，
其产出的旧容器格式与现役引擎不兼容（这正是上一版失败的原因，详见
`docs/CAPABILITIES.md` 第 3 节）。

## 改参数/加滑条

三处同步（详见 `docs/ARCHITECTURE.md` 的 uniform 契约）：
GLSL 声明 → `build_ksh.py` 的 `ENTRIES` → `bcas_state.lua` 的 `VEC`，
然后在 `bcas_screen.lua` 的 `ROWS` 加一行 `{key = "新参数"}` 即可。

## 排错速查

| 现象 | 排查 |
| --- | --- |
| 效果注册成功但画面毫无变化 | 在日志里搜 `Error compiling shader`。ANGLE（GLSL ES，2013 年老编译器）有两个已知雷：① 源码含任何非 ASCII 字符 → `invalid character`；② **`in`/`out` 参数限定符 → `'in' : syntax error`**。两者都会静默失效（注册/排序/启用照常返回 true）。`build_ksh.py` 已强制 ASCII 校验；参数限定符一律不用（输出用返回值/vec2 打包） |
| 注册/启用返回 false | 日志搜 `BCAS`，看 `插入渲染链` 与 `启用效果` 两行的返回值；启动后会自动打印完整状态（`BCAS.Info()` 可随时手动再打） |
| 模组列表里没有它 | modinfo.lua 语法错误（看 client_log.txt 的 mod 加载报错） |
| 启用后无变化 | 日志搜 `BCAS`；确认非专用服务器；按 P 确认滤镜处于开启态 |
| 锐化无感但调色有效 | `SCREEN_PARAMS` 未被填充（理论不应发生，zoomblur 同机制在用）；日志反馈 + 用 `reference/` 里 lunacy/zoomblur 做对照实验 |
| 画面过锐/有光晕 | 面板降「锐化强度」或升「抗振铃」 |
| 想彻底恢复默认 | 删除 `文档\Klei\DoNotStarveTogether\client_save\bcas_studio` 设置文件后重启；面板里每个滑条右侧也有单独重置小圆钮 |

## 已知风险与后续路线

1. **风险（低）**：`SCREEN_PARAMS` 是引擎魔法值，机制与 `postprocess_zoomblur.ksh`
   完全一致，但未在实机验证本 mod 本身。退化行为安全（见上表）。
2. **下一步（可选）**：
   - 利用 `components/colourcube.lua` 的 `overridecolourcube` 事件做季节 LUT 微调；
   - 颗粒动画：Lua 侧以低频（如 10Hz）`SetUniformVariable(TIME)`，代价可忽略；
   - 若要锐化 HUD：不存在官方途径（HUD 在后处理链之后），只能叠 ReShade——本 mod 定位即替代它。

## 参考材料清单（reference/）

- `dst_scripts/`、`dst_shaders/`：本机游戏解包（权威 API 依据）
- `workshop-2485714729-ColorAdjustments/`：pxl_42 的成品 mod（管线姿势范本）
- `reshade/`、`reshade-shaders/`：ReShade 源码与官方滤镜库（算法对照）
- `ktools/`：KTEX 工具（若后续做 LUT/贴图资产用）
- `glsl_extracted/`：引擎各后处理着色器的 GLSL 提取件（方言范本）
