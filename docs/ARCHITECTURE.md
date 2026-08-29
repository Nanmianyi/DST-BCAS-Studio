# BCAS Studio 架构

## 目录结构

```
我大抵是没事才做饥荒mod/
├── BCAS-Studio/              ← Mod 本体（整体复制到 DST mods 目录即可用）
│   ├── modinfo.lua           ← 元信息 + 启动配置（预设/高清字体/双热键）
│   ├── modmain.lua           ← 官方钩子接入、热键、面板入口、高清字体整合
│   ├── scripts/
│   │   ├── bcas_state.lua    ← 参数状态机：预设/打包下发/持久化（单一数据源）
│   │   └── bcas_screen.lua   ← 设置面板 v3：博客风 UI + 拖拽/键入行 + 调色轮弹窗
│   ├── fonts/                ← 思源黑体（Chinese++ 1418746242 打包，见 ATTRIBUTION.txt）
│   └── shaders/
│       └── bcas_studio.ksh   ← 构建产物（勿手改）
├── src_shaders/
│   ├── bcas_studio.ps        ← 着色器源码（GLSL ES 方言）
│   └── postprocess_base.vs   ← 与引擎自带逐字节一致的顶点着色器
├── tools/
│   ├── build_ksh.py          ← GLSL → .ksh 组装器（含 GLSL↔条目表交叉校验）
│   └── ksh_parse.py          ← .ksh 解析/字节级 round-trip 校验
├── docs/                     ← 能力研究 / 旧滤镜分析 / 本文件 / 构建指南
└── reference/                ← 库与逆向材料（reshade、游戏脚本/着色器解包、pxl_42 等）
```

## 数据流

```
启动: main.lua
  ├─ BuildModShaders()      → modmain.AddModShadersInit → State.InitShader()
  │     AddPostProcessEffect(bcas_studio.ksh) → 注册 4 个 vec4 uniform → 套用预设
  └─ SortAndEnableShaders() → modmain.AddModShadersSortAndEnable → State.SortAndStart()
        SetPostProcessEffectAfter(effect, Lunacy) → GetPersistentString 异步读档 → 生效

游戏内: 滑条改动 → State.SetParam → 立即 SetUniformVariable（实时预览）
        应用并保存 → SetPersistentString("bcas_studio")
        ESC      → 回滚到打开面板时的快照

每帧:  零 Lua 开销（uniform 只在改动时下发；TIME 仅在颗粒>0 时才有意义，
        当前版本颗粒用 uv+TIME 哈希，TIME 为静态值时颗粒仍有效只是不闪动）
```

## Uniform 契约（三处必须一致，build_ksh.py 会自动校验前两处）

双 pass，渲染顺序 **cinema(调色) → studio(锐化+氛围)**（用户拍板：先调色稳定
动态范围，锐化不被二次拉伸；颗粒在锐化后生成，锐化采不到噪点）。

| pass | uniform | 打包 |
| --- | --- | --- |
| cinema | `BCAS_GRADE_A` | 曝光EV / 色温 / 色调 / 饱和度 |
| cinema | `BCAS_GRADE_B` | 自然饱和 / 对比度 / 亮度 / Gamma |
| cinema | `BCAS_EXTRA` | x=ACES 混合 |
| cinema | `BCAS_CDL_S/O/P` | 一级 CDL 斜率/偏移/幂（_S.w=二级开关，_O.w=高光去饱和） |
| cinema | `BCAS_SEC_S/O/P` | 二级 CDL 斜率/偏移/幂（_O.w=原始混合） |
| studio | `BCAS_SHARPEN` | 锐化强度 / 降噪 / 抗振铃(总开关) / 暗部保护 |
| studio | `BCAS_SHARP2` | RangeSigma / SpatialSigma / CenterWeight / NoiseFloor |
| studio | `BCAS_AURA` | 边缘阈值 / 亮部过冲 / 暗部过冲 / 色度保护 |
| studio | `BCAS_ATMO` | 暗角 / 颗粒 / TIME(Lua 8Hz 动画) |

1. `src_shaders/bcas_studio.ps` / `bcas_cinema.ps` 的 GLSL 声明
2. `tools/build_ksh.py` 的 `SHADERS`（ksh 条目表）
3. `scripts/bcas_state.lua` 的 `VEC`（打包位置）+ `EFFECT_UNIFORMS`（注册）

uniform 数量没有 4 个上限（pxl_42 绑了 9 个）；`SCREEN_PARAMS` 与 `SAMPLER`
由引擎自动绑定，**永远不要**在 Lua 注册。源码长度红线 ~4096 字节（含结尾
NUL），压缩产物超过 3900 构建直接失败。

## 着色器管线（每像素 5 次采样，无分支热点）

```
十字5采样 → YCoCg → MAD4(Y/Co/Cg) + 边缘形状描述
  → 忠实移植旧 BCAS_Workspace V1.5.fx 的锐化段:
    双边基底(RangeSigma 0.26, GradAdapt 平坦区放宽 σ) → 细节层(孤立边/均匀边压缩)
    → tanh 软限幅(上限随活动量/亮度/色度保护自适应) → 暗部保护(阈值+线性坡道)
    → AURA 抗过冲(对局部包络距离软限制, +0.003上/+0.009下, AntiRinging=0 关闭)
→ 色彩管理: 曝光EV → 白平衡 → 亮度 → 对比度 → Gamma → 胶片曲线ACES → 饱和/自然饱和
→ 氛围: 暗角 → 颗粒
```

> **教训（2026-08）：** 曾有一版把锐化"简化重写"（σ 公式、细节压缩、tanh→有理式
> 限幅、暗部保护公式全部换掉），游戏内肉眼几乎不可见。旧 fx 在 ReShade 上是用户
> 日用验证过的，**只做忠实移植，不要再动数学**。已裁剪不移植：EAA/SCAA 抗锯齿、
> 色度伪影修复组（ChromaDirMix/BlueGuard/ChromaAR）、CCE 的局部自适应曝光。

> **铁律：着色器源码必须纯 ASCII。** DST 走 ANGLE（OpenGL ES 2.0）渲染，
> 其 GLSL ES 编译器遇到非 ASCII 字符直接 `invalid character` 拒编，
> 且效果注册/排序/启用照常返回 true，静默失效（本项目踩过的真坑，
> `build_ksh.py` 已加 ASCII 强制校验）。注释一律写英文。

ACES 的正确打开方式：先 `pow(2.2)` 线性化 → ACES fitted → `pow(1/2.2)` 再编码
→ 按滑条强度混合。旧 BCAS.fx 直接在 gamma 空间套曲线，中调对比与饱和度爆炸
（"开 1.0 就是纯色"的根源）。

## 高清字体整合

改编自创意工坊 2403997762（TsAIM，GPL，`fonts/LICENSE`）：
`Asset("FONT")` 位图字体 zip → `TheSim:LoadFont` → 替换全局字体常量。
在 `Start` / `ModManager.RegisterPrefabs` / `UnregisterAllPrefabs` 三个挂点重应用，
对抗游戏启动时的字体重置。全局生效（含主菜单）。modinfo `HDFONT` 可关。
同时启用原字体 mod 会争抢 `normalfont` 名字，建议二选一。

## 兜底与诊断

- 注册失败时 `bcas_state.InitShader` 打印明确日志（搜 `BCAS`）。
- `SCREEN_PARAMS` 若因引擎版本差异未填充 → `px=0` → 全部采样退化为中心点，
  锐化安全地退化为无操作，色彩管理不受影响（不会花屏）。
- 控制台调试：`GLOBAL.BCAS` 暴露状态机，例如 `BCAS.Set("Strength", 2.2)`、
  `BCAS.ToggleEnabled()`、`BCAS.ApplyPreset("cinema", false)`。
