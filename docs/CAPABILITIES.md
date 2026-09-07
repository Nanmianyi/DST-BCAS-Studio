# BCAS Studio 能力矩阵（V6）

> 全部能力均在《饥荒：联机版》实机验证，无占位、无未上线条目。

## 渲染管线

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 双 pass 后处理链 | ✅ | cinema（调色）→ studio（锐化终合成），官方 Mod 着色器链注册 |
| 辉光子管线 | ✅ | Kawase pre/2/4/8 + 双合成 pass，BloomOn 时完全替代原生 Bloom |
| 参数总线 | ✅ | 17 个 vec4 uniform、40+ 参数，改动即下发、自动持久化 |
| 快照回滚 | ✅ | 打开面板时快照，ESC 回滚，PgDn 落盘 |

## 锐化与修复（bcas_studio.ksh）

| 能力 | 参数 |
| --- | --- |
| 双边自适应锐化（YCoCg + MAD4 活动量 + σ 自适应核） | Strength / RangeSigma / SpatialSigma / CenterWeight |
| 细节层压缩与噪声基底 | NoiseFloor / NoiseReduce |
| 逆卷积墨线收敛（边缘法向 + 双边门控 + 暗部穿透） | DeconvStrength / DeconvGate / DeconvPenetr |
| AURA 包络抗过冲（亮/暗双通道 + 边缘阈值） | AR_Threshold / AR_L·D_Overshoot |
| 色度保护 / 暗部保护 / 软限幅 | ChromaProtect / DarkProtect |
| 8-bit 加固（TPDF 抖动 / 2LSB 底限 / 软底 EOTF） | 内建 |

## 电影调色（bcas_cinema.ksh）

| 能力 | 参数 |
| --- | --- |
| 曝光 / 明度 / 对比度 / Gamma | ExposureEV / Lightness / Contrast / Gamma |
| 白平衡光学色轮（HSV ↔ 色温/色调解析映射） | Temp / Tint |
| 饱和度 / 自然饱和 | Saturation / Vibrance |
| CDL 一级（斜率/偏移/幂 ×RGB） | SlopeR·G·B / OffsetR·G·B / PowerR·G·B |
| CDL 二级 + 原画混合 | SecSlope·Offset·Power / OriginalMix |
| ACES 胶片曲线混合（软底 EOTF） | Filmic |
| 高光去饱和 | HL_Desat |
| 官方调色强度（引擎色块 lerp 缩放接管） | VanillaGrade |

## 氛围（bcas_studio.ksh ATMO 通道）

| 能力 | 参数 |
| --- | --- |
| 暗角 | Vignette |
| 动态胶片颗粒（8Hz 时钟驱动） | Grain |

## 辉光（kawase ×4 + bcas_glow / bcas_glow2）

| 能力 | 参数 |
| --- | --- |
| 原生 Bloom 置空接管 | BloomOn |
| Kawase 四层金字塔 + 软膝预滤 | GlowIntensity / GlowThreshold / GlowKnee |
| 宽环扩散 / 暖色偏移 / 辉光饱和 | GlowSpread / GlowWarmth / GlowSat |
| 光晕长尾（对数消散） | GlowTail |
| 光包裹（暖光沁入阴影） | LightWrap |
| 轮廓光（光源邻近勾边） | GlowRim |
| 透云光束（云隙光斑状态机 + 引擎勾边） | GodRays |
| Reinhard 高光压缩 | GlowCompress |

## 动态太阳光影（bcas_sun_emitter.lua）

| 能力 | 说明 |
| --- | --- |
| 日晷模型太阳 | 单一解析式输出影长/旋角/透明度/色温，全局共享 |
| 剪影地面投影 | 角色 + 大型地物，动画/皮肤/骑乘跟随，逐帧相位同步 |
| 全角色/皮肤/装备镜像 | 影子 build 跟随 GetSkinBuild（DLC 角色 wortox/wurt/wanda/walter 与皮肤体系全部正确）；装备 override 逐符号镜像（swap_object 手杖 / swap_hat 帽子 / swap_body 衣服），equip/unequip/换肤事件强刷——AnimState 的 C++ 状态直接可读，不依赖调用方 |
| 全天扫动 | 白天无级扫动、黄昏拉长、满月月光影（染蓝）、雨雪衰减 |
| 实体规模边界 | 纯客户端实体（dedicated 服务端零开销）；entitysleep 弃影子 + 还原原生投影、entitywake 补挂；远距静态距离门（92u）——影子实体数 = 玩家周边活跃规模 |
| 帧预算调度 | 移动实体逐帧 / 静态实体距离分层错峰；clip 哈希快路径（稳态每影每帧 0 次 IsCurrentAnimation 扫描）；监听器一次性绑定（closure 动态取引用，杜绝 sleep/wake 循环累积） |
| 太阳全局光 | 屏幕空间太阳位置驱动天光方向（SunFill） |
| 水面波光 | 温泉等水体引擎光源点缀（AttachWaterFX） |

## 海洋（bcas_ocean.lua）

| 能力 | 说明 |
| --- | --- |
| 海洋地皮调色 | 8 种海洋地块 primary/secondary/昼夜变体 |
| 小地图配色 | 同步烘焙 |
| 零运行时开销 | 世界生成时烘焙，原版渲染路径呈现（改动需重进世界） |

## 原版滤镜接管（引擎函数包装，可逆）

| 能力 | 参数 |
| --- | --- |
| 低精神保色 | SanityColourOn |
| 失真消除（精神晃动 → 原图） | DistortFree |
| 积雪上限（0=无雪 ~ 3=原版） | SnowCap |
| 风沙遮罩过滤 | SandFilter |

## UI 与字体

| 能力 | 说明 |
| --- | --- |
| 画质工作室面板 | 7 页签 / 40+ 参数 / 拖拽+键入+R 复位 / 实时预览 |
| 白平衡光学色轮 | HSV 三维取色 ↔ 色温色调解析映射 |
| 三套预设 | 特调方案（定版）/ 轻量画质 / 电影胶片 |
| 高清字体 | 思源黑体 85px 视网膜重铸版内置，三重挂载点对抗引擎字体重置 |
