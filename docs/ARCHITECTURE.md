# BCAS Studio 架构（V6）

## 目录结构

```
BCAS-Studio/                 ← Mod 本体（整体复制到 DST mods 目录即可用）
├── modinfo.lua              ← 元信息 + 启动配置（预设/高清字体/双热键）
├── modmain.lua              ← 官方钩子接入、热键、面板入口、高清字体整合
├── scripts/
│   ├── bcas_state.lua       ← 参数状态机：VEC 定义 / 预设 / 打包下发 / 持久化
│   ├── bcas_screen.lua      ← 画质工作室面板：8 页签 / 拖拽行 / 白平衡色轮
│   ├── bcas_sun_emitter.lua ← 动态太阳：日晷模型 / 透云光束
│   ├── bcas_shadow_proj.lua ← 地面投影 v14：顶点斜投影（接管引擎 bloom 那一遍绘制）
│   ├── bcas_glint.lua       ← 海面波光层（程序化 caustics 光网 quad）
│   └── bcas_ocean.lua       ← 海洋地皮调色（世界生成时烘焙）
├── shaders/                 ← 构建产物（调色/辉光/Bloom 链 + bcas_shadow_proj 顶点斜投影，勿手改）
├── fonts/                   ← 思源黑体 85px 视网膜字模（取自 Chinese++，见 ATTRIBUTION.txt）
└── anim/                    ← 资源：lightrays（游戏本体提取）/ bcas_surface（自建空白方块载体）
src_shaders/                 ← 全部 GLSL ES 源码
├── bcas_cinema.ps           ← PASS 1 电影调色引擎
├── bcas_studio.ps           ← PASS 2 锐化与终合成
├── bcas_glow.ps             ← 辉光合成（mip 金字塔四级一次合成）
├── bcas_bloom_pre.ps        ← 辉光金字塔头：软膝高光提取 + 软化
├── bcas_bloom_down.ps       ← mip 逐级下采样（三个尺寸实例）
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
  │     注册主链 pass（默认 bcas_merged_glow：调色+锐化+辉光单 pass）+ mip 金字塔
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
原生 Bloom：钩住 SetBloomEnabled，mod 启用期间恒关（BloomOn 关掉 = 真的无辉光）
主链（默认 MERGED_PASS=on）：全分辨率只 1 个 pass
  bcas_merged_glow  调色 + 锐化 + 辉光合成 一次完成
    金字塔（4 个 sampler，1/4 → 1/32）：
      bloom_pre   软膝高光提取 + 4 抽头软化
      bloom_d1/2/3  mip 逐级 2x 下采样
    SAMPLER[1..4] 由 Lua 按 AddSampler 顺序挂到主 pass
回退（MERGED_PASS=off）：cinema -> studio -> bcas_glow 独立合成 pass
```
性能：全分辨率 pass 从 3（cinema/studio/glow）一路降到 **1**；金字塔每级仅
4 抽头、尺寸逐级减半，无稀疏大步长采样（无方块/斜向拖影）。

## 体积影子（v10：屏幕空间高度场 + 穿透判定行进）

```
scripts/bcas_shadow_proj.lua —— 地面投影 v14：顶点斜投影
  ├─ 调度层（沿用 v11 阶段二，与渲染出口无关）
  │    相机矩形裁切（进出滞回）/ 0.2s 淡入淡出 / 静态施影者睡眠
  │    / 原版椭圆影（DynamicShadow）接管与还原
  ├─ 光源层（沿用 V13，一条没改）
  │    方向池 / 冲淡池分离、主光滞回、副光稀释、投影死区、
  │    装饰光与透云光柱排除、WashoutAt 线段距离冲淡 + 时间域低通
  ├─ 几何层（v14 新）
  │    影长 = AnimState:GetVisualBB 高度 × 实体缩放 × 日晷影长系数 L
  │    根半径 = 物理半径 / 视觉半宽 / 按高度估（三级兜底，两级 clamp）
  └─ 渲染出口（v14 新）
       每施影者一个 quad（载体与海面波光共用 anim/bcas_surface.zip）
       SetScale(side, side, side)   side = 影长 × CONE_QUAD_PAD（正方形 ⇒ 旋转不可能裁到锥）
       SetFloatParams(根半径, 方向x, 方向z)
       SetOceanBlendParams(柔度, 消散, 梢率, 呼吸)
       SetMultColour(1,1,1,浓度)    ← 着色器读 COLOUR_XFORM[3][3]

shaders/bcas_shadow_cone.ksh（src_shaders/bcas_shadow_cone.{vs,ps}）
  VS  从 MatrixW 读回 quad 的真实世界轴（含长度）⇒ 不假设引擎怎么压平 OnGround
      也不假设美术单位；把片元坐标投影成"横向 / 沿影子"两个世界单位分量
  PS  解析胶囊：扫掠段半径 mix(根, 梢, t) + 两端圆帽
      接触硬化半影 feather = max(soft·(0.30+1.70t), 0.10) · max(r, 0.55)
      影色 = 世界光照贴图的缩放副本（夜里淡出 / 火把旁染色）
      水面遮罩（原版海洋上不投影）
      每个旋钮都有优雅降级：某通道没到 ⇒ 退化成物理精确的等半径胶囊

scripts/bcas_sun_emitter.lua
  └─ 只保留：日晷模型 GetSunParams / 透云光束 / 水面灯
     （旧的剪影克隆体系整体删除；影子渲染出口在 bcas_shadow_dummy.lua）
```

渲染链顺序：场景 →（影子作为贴地实体直接画进场景）→ 本模组调色/锐化/辉光 → 输出。

### 为什么不是"另画一份剪影"（也不是屏幕空间解算）

两代旧方案都已下线：

* **剪影克隆体**（SHADOW_SILHOUETTE.md，已归档）：给每个实体另建影子实体、
  逐帧镜像动画与符号，靠深度错位保证每像素只混合一次。正确性依赖一长串需要
  人工维护的镜像逻辑，并且有白名单 —— 大量物件本就没有影子。
* **屏幕空间体积解算**（SHADOW_VOLUME.md，已归档）：实体在 bloom 通道回传像素
  高度，再沿太阳方向做穿透判定。已整体删除（白名单 / 镜像漏项 / 深度博弈 /
  每帧一次全屏行进）。
* **镜像美术 + 屏幕门抖动**（v13，`tools/retired_v13/`）：把施影者的原画压扁贴地。
  一棵树 5~8 个符号压平后同深度、每个各混合一次 ⇒ 必须用抖动压并集 ⇒
  抖动等值线必然是平行直线 ⇒ 斜纹/摩尔纹。

现行方案（顶点斜投影）**不做屏幕空间解算、不写深度、不用抖动网点、不建贴地哑元、
不镜像美术**：接管引擎给每个动画实体多画的那一遍（`RENDERPASS.BLOOM`），在顶点端
沿太阳方向把几何斜投影到地面（`ground.xz = world.xz + world.y · dir / tan(el)`），
影长由每个顶点自己的世界高度决定（没有白名单）；片元把美术 alpha 写成覆盖度，
而 bloom 缓冲是 alpha 混合 ⇒ 同一像素永远只有一层（不需要抖动）。

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
