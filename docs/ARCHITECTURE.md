# BCAS Studio 架构（V6）

## 目录结构

```
BCAS-Studio/                 ← Mod 本体（整体复制到 DST mods 目录即可用）
├── modinfo.lua              ← 元信息 + 启动配置（预设/高清字体/双热键）
├── modmain.lua              ← 官方钩子接入、热键、面板入口、高清字体整合
├── scripts/
│   ├── bcas_state.lua       ← 参数状态机：VEC 定义 / 预设 / 打包下发 / 持久化
│   ├── bcas_screen.lua      ← 画质工作室面板：7 页签 / 拖拽行 / 白平衡色轮
│   ├── bcas_sun_emitter.lua ← 动态太阳：日晷模型 / 剪影投影 / 透云光束
│   └── bcas_ocean.lua       ← 海洋地皮调色（世界生成时烘焙）
├── shaders/                 ← 构建产物（bcas_cinema/studio/glow×5 .ksh，勿手改）
├── fonts/                   ← 思源黑体 85px 视网膜重铸版（见 ATTRIBUTION.txt）
└── anim/                    ← 投影剪影动画（wilson_shad / wilsonbeefalo_shad）
src_shaders/                 ← 全部 GLSL ES 源码
├── bcas_cinema.ps           ← PASS 1 电影调色引擎
├── bcas_studio.ps           ← PASS 2 锐化与终合成
├── bcas_glow.ps / glow2.ps  ← 辉光合成 A/B
├── bcas_kawase*.ps          ← Kawase 金字塔（pre/2/4/8）
└── postprocess_base.vs      ← 后处理公共顶点着色器
tools/
├── build_ksh.py             ← GLSL → .ksh 组装器（minify + 条目表交叉校验）
├── ksh_parse.py             ← .ksh 解析 / 字节级 round-trip 校验
├── make_modicon.py          ← PNG → KTEX(DXT5 全 mip 链) 编码器 + 解码回验
└── build_hanfont.py         ← 高清字体打包（栅格化 + 重铸 + 打包）
docs/                        ← 架构 / 能力矩阵 / 构建指南 / 工坊文案
```

## 数据流

```
启动: main.lua
  ├─ BuildModShaders()      → modmain.AddModShadersInit → State.InitShader()
  │     注册 bcas_cinema / bcas_studio 后处理 pass + 辉光子管线（5 个 ksh）
  │     AddUniformVariable × 17 → 套用预设（modinfo PRESET 或持久化档）
  └─ SortAndEnableShaders() → modmain.AddModShadersSortAndEnable → State.SortAndStart()
        SetPostProcessEffectAfter(effect, Lunacy) → GetPersistentString 异步读档 → 生效

游戏内: 滑条改动 → State.SetParam → 立即 SetUniformVariable（实时预览）
        应用并保存 → SetPersistentString("bcas_studio")
        ESC      → 回滚到打开面板时的快照
```

## 双 pass 后处理

```
PASS 1  bcas_cinema.ksh   电影调色引擎
        曝光 → 白平衡 → CDL 一级 → 高光去饱和 → ACES 混合
        → 饱和/对比/明度/Gamma → CDL 二级 → 原画混合
PASS 2  bcas_studio.ksh   锐化与终合成
        逆卷积墨线收敛 → 双边自适应锐化（YCoCg/MAD4/σ核/软限幅）
        → AURA 包络抗过冲 → 暗角/颗粒 → 8-bit 加固 → 输出
```

## 辉光子管线（BloomOn 接管）

```
原生 Bloom：钩住 SetBloomEnabled 强制置空（画质设置反复重开也被拦截）
辉光:      场景降采样
             → kawase_pre  软膝预滤（GlowThreshold/GlowKnee 双段门槛）
             → kawase2/4/8 三层递增步长金字塔
             → bcas_glow   核心层+中环层合成（BCAS_GLOW/GLOW2）
             → bcas_glow2  宽环+长尾+暖偏移+光包裹+轮廓光
                           +透云光束+Reinhard 压缩+与场景终合成
```

## 动态太阳光影（世界空间，非屏幕空间）

```
bcas_sun_emitter.lua
  ├─ 日晷模型 GetSunParams()：TheWorld.state → (影长, 旋角, 透明度, 月光色)
  │    单一解析式全局共享；缓存键 6 位精度，相位切换毛刺修复
  ├─ 剪影投影：角色/地物挂 OnGround 剪影实体
  │    移动实体逐帧同步（动画/皮肤/骑乘跟随）；静态实体 0.5s 距离分层错峰
  │    姿态（影长/旋角/透明度）进逐帧调度器连续扫动
  ├─ 透云光束：3 个光斑实体 gap→in→hold→out 状态机 + 引擎光源勾边
  └─ 门控：洞穴静默 / 夜晚零开销 / 距离裁剪
```

## 海洋地皮调色（世界生成烘焙）

```
modmain 加载期：bcas_ocean.Apply(true) 改写 worldtiledefs 海洋地块
  primary/secondary/昼夜变体/小地图配色（Oasis 通透青绿 8 地块）
  → 引擎在世界生成时烘焙进海洋纹理 → 原版渲染路径呈现
注意：烘焙进世界数据，改动 OCEAN 开关需重进世界生效（UI 有标注）
```

## 原版滤镜接管（可逆包装）

```
低SAN保色 / 失真消除 / 积雪上限 / 风沙过滤：
  包装引擎对应调用（色块 lerp 缩放 / DISTORTION_FACTOR / 积雪钳制 / 遮罩可见性）
  开关实时生效，关闭即还原原版行为
官方调色强度：VanillaGrade 滑杆缩放 SetColourCubeLerp 混合（0=原色 ~ 1=原版）
```

## ksh 构建链

`build_ksh.py`（依赖 `ksh_parse.py` 的容器读写）：

1. 读取 GLSL 源码 → ASCII 强制把关 → `minify_glsl` 压单行（后处理路线
   的 ~4096 字节引擎缓冲限制）或保留多行 CRLF+NUL（实体 effect 路线）；
2. 条目表交叉校验：GLSL 声明的 uniform 与条目表双向对齐，
   未使用 uniform（编译器优化掉 → 引擎断言）直接构建失败；
3. 生成尾块（vs/ps 引用索引）→ 字节级 round-trip 自检。

详见 [BUILD_AND_INSTALL.md](BUILD_AND_INSTALL.md) 的"构建管线要点"。
