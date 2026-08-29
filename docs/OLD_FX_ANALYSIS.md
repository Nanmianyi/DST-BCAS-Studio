# 旧滤镜 BCAS_Workspace V1.5.fx 分析

对象：`BCAS_Workspace V1.5.fx`（ReShade FX，约 760 行）。

## 总体判断

核心算法（双边域锐化）是扎实的，但整个文件是"大而全"取向：
在锐化主线上叠了多层对饥荒场景收益极低、ALU 开销却很高的模块，
且大量参数（40+ 个 uniform）没有清晰的功能边界。

## 模块处置清单

### ✅ 保留（移植进新着色器，有简化）

| 模块 | 评价 | 处置 |
| --- | --- | --- |
| YCoCg 空间锐化 | 只锐亮度不伤色度，方向正确 | 保留，5 点采样不变 |
| 双边基底 (BilateralY_Cross3) | 细节提取的质量核心 | 保留，σ 自适应简化 |
| MAD4 局部统计 | 边缘/平坦/噪声判别的依据 | 保留 |
| 软限幅 (soft_lim_tanh) | 防过冲关键 | 保留，换更便宜的有理饱和 `s·x/(|x|+s)` |
| 噪声门控 (NoiseFloor/Suppress) | 平坦区细节≠噪声 | 保留，合并为单个"降噪"滑条 |
| 暗部保护 (DarkProtect) | 防近黑区噪点放大 | 保留 |
| AURA 抗过冲 (AntiRinging) | 锐利而无光晕的关键 | 保留"局部范围+允许过冲"思想，砍掉压缩斜率/幂平均等 8 参数 |
| 色度跟随饱和 (saturation_scale) | 亮度提升后的自然微饱和 | 保留 |
| 色彩引擎 CCE 骨架 | 曝光EV/白平衡/饱和/对比 | 保留（显示域简化版）+ 新增自然饱和度/Gamma/亮度 |

### ❌ 砍掉（无用功）

| 模块 | 理由 |
| --- | --- |
| **SCAA / EAA 抗锯齿**（约 200 行，重灾区） | 饥荒是原生分辨率渲染的卡通画风，最终画面上做"虚拟采样重建边缘"基本无效，徒增每像素几十次 ALU 与分支；用户实测确认无感。整段移除。 |
| 色度去伪影/方向修复（ChromaDirMix/BlueGuard/ArtifactCOY/CheckerBoost 等） | 为视频缩放伪影设计的补救，饥荒渲染里不存在这些伪影。 |
| AURA 压缩斜率组（6 参数）+ 幂平均 | 对结果影响细微，参数爆炸的来源。 |
| 局部自适应曝光 (AdaptStrength/AdaptLimitEV) | 单帧无历史统计，"局部EV"实为逐像素反转亮度，画面易发灰；饥荒有自己的昼夜 colourcube 管理曝光。 |
| 二级 CDL、肤色/高光遮罩组 | 调色链过长，交互成本高于收益。 |
| 调色曲线四选一 (ACES/Hable/Reinhard/Uchimura) | ~~砍~~ **回归一项**：ACES fitted 以正确的显示域用法重生（pow2.2 线性化 → 曲线 → 再编码 → 按强度混合）。旧版直接在 gamma 空间套 ACES，中调对比与饱和度爆炸（"开到 1.0 就是纯色"的根源，0.1 才能用）。旧实现的其余三条曲线仍属域错位，不回归。 |
| fLUT、17 个调试输出模式 | ReShade 专属基础设施，DST 侧由设置面板替代。 |

## 参数收敛

旧版 40+ 个暴露参数 → 新版 **14 个滑条 + 1 个开关**，每个滑条
直接对应一个可感知的效果，全部可游戏内实时调节并持久化。

## 移植映射（旧 → 新）

| 旧 (ReShade) | 新 (bcas_studio.ps) |
| --- | --- |
| Strength / RangeSigma / SpatialSigma / CenterWeight | Strength（σ 由 MAD4 自适应，空间权重固定） |
| NoiseFloor / NoiseSuppress | NoiseReduce |
| AntiRinging / AR_* | AntiRinging |
| EnableDarkProtect / DarkProtect | DarkProtect |
| ChromaProtect / ChromaDenoise / ChromaAR / ChromaFollow | （并入门控与降噪路径） |
| OriginalMix | 删除（用强度滑条即可回退） |
| ExposureEV / WB_Temp / WB_Tint | ExposureEV / Temp / Tint |
| SatGlobal | Saturation |
| Vibrance | Vibrance（新增高饱和保护实现） |
| Contrast / ContrastPivot | Contrast（枢轴固定 0.5） |
| — | 新增 Lightness / Gamma / Vignette / Grain |
