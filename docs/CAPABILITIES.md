# DST 引擎图形能力研究结论

> 结论基于对本机 DST 客户端解包的 `scripts.zip` / `shaders.zip`（2025-07 版本）与
> 创意工坊实测可用的 mod（pxl_42 的 Color Adjustments，ID 2485714729）的交叉验证。

## 1. 结论：DST 官方支持 Mod 自定义全屏后处理着色器

这是整个项目的基石，四个环节全部有官方实锤：

| 环节 | 证据 |
| --- | --- |
| Mod 声明着色器资产 | `Asset("SHADER", "shaders/xxx.ksh")`，pxl_42 在用 |
| 注册后处理效果 | `AddModShadersInit(fn)` 钩子 → `PostProcessor:AddPostProcessEffect(resolvefilepath(...))`，`scripts/postprocesseffects.lua` 中 `BuildModShaders()` 官方调用 |
| 控制执行顺序 | `AddModShadersSortAndEnable(fn)` 钩子 → `PostProcessor:SetPostProcessEffectBefore/After(effect_id, target)` |
| 开关与参数 | `PostProcessor:EnablePostProcessEffect(id, bool)`、`AddUniformVariable(name, ncomps)`、`SetUniformVariable(handle, v1..v4)` |

引擎内置后处理链顺序（`scripts/postprocesseffects.lua` → `SortAndEnableShaders`）：

```
ZoomBlur → Bloom → Distort → ColourCube(基础,昼夜调色) → Lunacy → MoonPulse → MoonPulseGrading
```

Mod 效果用 `SetPostProcessEffectAfter(effect, PostProcessorEffects.Lunacy)` 排到
ColourCube 之后，意味着**作用于昼夜/四季色彩管理完成后的最终画面**，正是滤镜想要的位置。

## 2. 引擎魔法 uniform

- `SCREEN_PARAMS`（vec4）：引擎自动填充 `{宽, 高, 1/宽, 1/高}`。
  证据：`postprocess_zoomblur.ksh` 声明并使用它，而 `postprocesseffects.lua`
  从未为它调用 `AddUniformVariable`。**不要在 Lua 里注册它，ksh 条目表里要有它。**
- `SAMPLER`（sampler2D 数组）：后处理效果的画面输入固定绑到 `SAMPLER[0]`，
  同样不要注册。失败品 dstspjihua 曾错误地把它当 uniform 注册（`AddUniformVariable("SAMPLER",1)`），属于典型误用。

## 3. .ksh 容器格式（已逆向，字节级验证）

老版 `ShaderCompiler.exe`（NVIDIA Cg 工具链，dstspjihua 里那份）产出的是
**旧格式**（MatrixP/MatrixW 符号表结构），与现役引擎加载的**新格式**不同——
这就是旧尝试"装上没反应"的直接原因。新格式已逆向并通过 10/10 字节级
round-trip（游戏自带 8 个 postprocess ksh + combine_colour_cubes + pxl_42）：

```
[u32 namelen][name]
[u32 entry_count]
entry × entry_count:
    [u32 namelen][name][u32 0][u32 TYPE]
    TYPE == 0x2b (sampler2D): [u32 arraylen]
    其他: [u32 1][u32 分量数][分量数 × u32 0]
    TYPE 编码: 0=float 2=vec2 3=vec3 4=vec4 0x2b=sampler2D
[u32 len][vs文件名][u32 len][VS GLSL 源码]
[u32 len][ps文件名][u32 len][PS GLSL 源码]
trailer: [u32 0][u32 entry_count][0..entry_count-1]
```

GLSL 为明文内嵌，引擎加载时自行编译（GL/DX11 双后端），方言为 GLSL ES 风格：
`attribute/varying/texture2D/gl_FragColor` + `#if defined( GL_ES ) precision highp float; #endif`。
工具 `tools/ksh_parse.py`（校验）、`tools/build_ksh.py`（构建）。

## 4. 其他确认的能力（本 mod 未用，留作扩展）

- **ColourCube LUT**：`components/colourcube.lua` 按季节/时段/理智值在 3 张
  LUT（32×32×32，1024×32 图集）间插值；事件 `overridecolourcube` /
  `overridecolourmodifier` 可被 mod 干预 → 可做"天气 LUT"级别的进阶调色。
- **UI 层**：`ImageWidget` 有 `SetEffect()` 可挂引擎着色器、`SetTint` 全屏染色；
  `blendmodes`/`BLENDMODE` 常量在 `constants.lua`。可作为滤镜失效时的兜底叠加方案。
- **持久化**：`TheSim:SetPersistentString / GetPersistentString`（异步回调）。

## 5. 明确做不到的（诚实的边界）

- 像素级**锐化的对象是 3D 场景+世界的最终画面，不含 HUD**（HUD 在后处理链之后绘制）。
  这是引擎管线决定的，对 mod 无差别（ReShade 反而会连 UI 一起锐化，在饥荒里通常是缺点）。
- 无法新增引擎着色器以外的渲染特性（如自定义光照）；那些是引擎内部。
