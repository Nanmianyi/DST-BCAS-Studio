# 影子剪影架构与踩坑归档（V8.1）

> 目标观感：**纯正、带透明度的贴地剪影** —— 单色、均匀浓度（白天 0.50 / 满月 0.38）、
> 内部没有描边线、不叠加变深、不闪烁、不缺块。
>
> 这份文档记录达成这个观感的**原理、三次根因、数值标定与验证工具链**，
> 让后来改这块的人不用再走一遍。

---

## 一、问题本质：影子是"美术的黑色副本"

影子实体是同一份动画美术的黑色副本（`SetMultColour(0,0,0,alpha)`），所以**美术本身
就是问题**：DST 的明暗是画出来的，每个部件的边缘还带 1~2px 半透明软边。于是：

- **软边线条**：一个部件的半透明软边叠在另一个部件的实心上 → 半透明混合叠加加深
  → 一条 1~2px 的"黑色轮廓线"。
- **重叠线条**：同一实体自身重叠处（帽子压头发、树干叠树冠、身体叠四肢）浓度叠加
  → 整片内部更深，边界即"线"。
- 注意 `rgb = 0` 只能消掉彩色，**消不掉 alpha 差**：线条完全来自 alpha 的差异与叠加。

离线实测（`tools/silhouette_overlap_check.py` + `tools/shadow_alpha_audit.py`）：

| 结论 | 数值 | 意义 |
|---|---|---|
| 美术 alpha 分布 | 91~94% 像素 ≥ 0.9 | 绝大部分是实心 |
| 淡像素位置 | 93.8% 落在实心区边缘 2px 内 | 它们是抗锯齿软边，不是独立笔画 |
| 三种 alpha 映射的重叠加深量 | 完全一致（约 30/255） | **只改 alpha 映射永远消不掉线** |

→ 因此必须两步：**① 硬 alpha 测试把软边丢弃、把实心拍成单一浓度；
② 让同一像素只混合一次（单层混合）**。

---

## 二、三次根因（都是"以为生效其实没生效"）

### 根因 1：整条视觉链被一个运行时 uniform 哨兵门控（决定性）

前一版把"alpha 压平"和"逐部件深度错位"都写在**一段由 `FLOAT_PARAMS.z` 门控的
分支**里（`SetFloatParams(0,0,2/3/4)` 切模式，普通实体恒为 0 所以不受影响）。

问题：`FLOAT_PARAMS` 是引擎按实体状态喂进去的 uniform，一旦没喂到/被引擎清掉，
**那段代码整段不执行，而且没有任何报错**。表现就是：影子退回引擎原版着色器 →
软边照旧混合（**线条一直在**）+ 没有逐部件深度差（深度测试忽胜忽负 → **疯狂闪烁**）
+ 深度写入覆盖整块 quad（**随机缺块**）。这也解释了当时"怎么调数值都没用"。

**终版做法**：不再用哨兵。改为**三个各自固定的着色器变体**（可见 / 写深度 / 克隆），
从游戏本体的 `anim.ksh` 派生，压平与深度错位都是固定逻辑，不读任何运行时开关。

### 根因 2：写深度孪生体与可见层"几何不一致"

单层混合依赖：孪生体（不可见、只写深度）先画并留下**每像素最近那层**的深度，
可见层再整体前推一点点，于是同像素只有最近那层能通过深度测试。

这要求两边**逐像素几何完全一致**。前一版只镜像了 bank / build / 皮肤 / 动画 / 帧 /
镜像翻转，而**符号级状态全部只落在可见层**：`Show/Hide`（HAT / HAIR / HEAD /
HEAD_HAT…）、`HideSymbol("face"/"beard"/"cheeks")`、`OverrideSymbol` /
`OverrideSkinSymbol` / `ClearOverrideSymbol`、骑乘时的 `AddOverrideBuild` 与强制
`SetBank("wilsonbeefalo")`。

后果很直观：戴帽/全盔时可见层把脸和头发藏了，孪生体照旧画着 → 孪生体在这些像素
写下**更近**的深度 → 可见层的头脸被整块拒掉（**"人物的脸直接没了"**）；骑牛时
两边 bank 不同 → 人马影子缺块并闪烁。

**终版做法**：所有符号级调用走**唯一入口** `BothAS(sa, "方法名", ...)`，
对"可见层 + 孪生体"同时下发（93 处）；骑乘分支的 bank 切换也补上镜像。
（`tools/wire_shadow_twin_symmetry.py` 是做这次改造并自检残留的脚本。）

### 根因 3：深度错位量落在 24 位深度缓冲的量化噪声里

深度缓冲 1 个单位 ≈ 6e-8（存储值），换成 clip 空间 `z/w` ≈ 1.2e-7。前一版：

| 档 | 旧值 | 折合深度单位 | 结果 |
|---|---|---|---|
| 基础前推 `ART_FLOOR` | 2e-7 | 1.7 | 与地面的胜负由舍入决定 → 缺块 |
| 可见层 × 孪生体 `LAYER_BIAS` | 3e-7 | 2.5 | 同像素胜负抖动 → 闪烁 |
| 装备克隆 `FX_BACKOFF` | 相减后 -6e-7 | **负数** | 被推到地平面**之后**，被地面整块裁掉 |

**终版数值**（`tools/make_silhouette_shader.py`）：

| 档 | 新值 | 折合深度单位 | 作用 |
|---|---|---|---|
| `ART_K`（美术高度梯度） | 1e-7 / 厘米 | 512 → 约 430 | 不同高度部件的稳定深度序 |
| `U_KEY` / `PAGE_KEY` | 4e-7 / 1e-7 | ≤ 5 | 高度几乎相同的部件再分层（图集 u / 图集页） |
| `PARAMS_KEY`（符号档） | 2e-6 / 档 | 17 | 加分项：Lua 用 `SetSymbolLightOverride` 编号 |
| `ART_FLOOR`（公共前推） | 2e-5 | 166 | 整体抬到地平面之前，消除 z-fighting |
| `LAYER_BIAS`（可见层额外） | 6e-7 | 5 | 保证"只有最近那层"能落笔 |
| `FX_BACKOFF`（克隆后撤） | 1.5e-6 | 12 | 克隆仍在地平面之前，但被本体孪生体挡住 |
| 总错位上限 | 1.53e-4 | ≈ 1275 | 仍远小于"角色站到影子前面"的真实深度差 |

设计要点：**深度序由纯顶点属性决定**（美术高度 + 图集 u + 图集页），这些数据一定
存在、一定生效；符号档只是加分项，即使它一个都没生效也不会退化成"打平 → 两层都画
→ 线条"。

---

## 三、终版架构

```
BCAS-Studio/shaders/                      （tools/make_silhouette_shader.py 生成）
  bcas_silhouette.ksh           可见层：硬 alpha 压平（≥0.30 拍成实心、<0.30 丢弃）
                                 + 深度前推 ART_FLOOR + LAYER_BIAS
  bcas_silhouette_write.ksh     写深度孪生体：同样压平，但乘色后强制输出 alpha=0
                                 （完全不可见、只写深度），前推 ART_FLOOR
  bcas_silhouette_fx.ksh        装备克隆：压平且可见（上一版这里被拍成 alpha 0，
                                 等于克隆影子一直没画出来），整体后撤 FX_BACKOFF
  *_skinned.ksh                 以上三者的 skinned 顶点布局备用版

BCAS-Studio/scripts/bcas_sun_emitter.lua
  ├─ ResolveShadowShader(kind)   三个变体各解析一次并缓存
  ├─ ApplyShadowShader(sa, kind) 挂 effect handle + FLOAT_PARAMS 归零
  ├─ BothAS(sa, method, ...)     符号级状态唯一入口：可见层 + 孪生体同时下发
  ├─ MakeWriteTwin(shadow)       建孪生体：LAYER_BACKGROUND（早于可见层的
  │                              LAYER_WORLD_BACKGROUND）、深度测试+写入都开、
  │                              乘色 alpha 0.001（避免"alpha 恒 0 被引擎整块跳过"，
  │                              着色器再把输出压成 0，视觉上全不可见）
  └─ ShaderSelfTest(shadow)      一次性自检：把"挂载/孪生体/符号档"打进日志
```

**每帧的混合过程**：孪生体先画（低图层）→ 深度测试 + 写入，缓冲里留下每像素最近
那层的深度；可见层后画（高图层）→ 开深度测试、关深度写入，整体比孪生体更近
`LAYER_BIAS` → 只有"贴着最近那层"的片元能通过，更远的部件全部被拒 → **每像素只
混合一次，叠加线条消失**，同时保留了正常的 0.50/0.38 半透明。

另外我们的剪影 PS 里**关掉了引擎自带的 alpha 测试**（`if (ALPHA_TEST > 0.0)`
→ `if (false)`）：它按贴图原始 alpha 做 discard，与我们的硬裁剪重复，而且
`PARAMS.x` 是引擎按实体状态设的、不受我们控制 —— 关掉它，结果才只由我们的
固定裁剪决定。

---

## 四、日志自检

首个影子挂载时会打一行（排查这类"静默失效"用的现场证据）：

```
[BCAS] 剪影自检: 挂载 可见=OK 写深度=OK 克隆=OK | 孪生体=OK | 符号档=37档(最大37) | 头=wilson
```

- `挂载 …=失败` → 该变体 ksh 没挂上（路径解析失败 / `SetDefaultEffectHandle` 报错）
- `孪生体=缺失` → 单层混合不生效（会看到重叠线条）
- `符号档=0档` → `SetSymbolLightOverride` 没生效（只是少了加分项，不应出现线条）

---

## 五、验证工具链（改这块前后都跑一遍）

| 工具 | 作用 |
|---|---|
| `tools/glsl_check.py` | 用游戏自带 `libEGL/libGLESv2` 离线编译+链接所有 ksh，并检查**每个 uniform 条目都有活动 location** —— 编译器优化掉的条目会被引擎绑定成 `0xFFFFFFFF` 触发 ANGLE 断言硬闪退。当前 16/16 全绿。 |
| `tools/make_silhouette_shader.py` | 从引擎 `anim.ksh` 派生 6 个变体，自带 round-trip 与 ASCII 校验 |
| `tools/silhouette_overlap_check.py` | 离线证明"只改 alpha 映射消不掉重叠线" |
| `tools/shadow_alpha_audit.py` | 真实图集的 alpha 分布统计（裁剪阈值依据） |
| `tools/wire_shadow_twin_symmetry.py` | 把符号级调用改成双下发，并自检无残留 |
| `tools/check_local_consts.py` | 抓"本地常量裸用未声明/声明过晚" —— 游戏开了 `strict.lua`，这会**直接抛错**（曾把整条角色生成链打断） |
| `work/` | 影子/海洋/辉光的离线模拟与预览工作台（见 `work/README.md`） |

回归检查顺序：`check_lua.py` → `check_forward_refs.py` → `check_local_consts.py`
→ `glsl_check.py` → `compare_copies.py`（工作区 / 本地 mods / 工坊三份对比）。

---

## 六、开关与回退

| 开关 | 位置 | 说明 |
|---|---|---|
| `SHADOW_FLAT_ENABLED` | `bcas_sun_emitter.lua` | false = 影子回退引擎默认着色器（旧观感：软边/排线会显成线条） |
| `SHADOW_WRITE_TWIN` | 同上 | false = 不建孪生体（只剩硬 alpha 压平；重叠会重新叠加） |
| `SHADOW_SYMBOL_KEY` | 同上 | false = 不刷符号深度档（主要靠顶点属性，仍不会打平） |
| `SHADOW_SKINNED_FALLBACK` | 同上 | true = 切到 `*_skinned.ksh`（某类实体影子"顶点碎成一块块"时用） |

## 七、两条被放弃的路线（存档，避免重走）

1. **官方剪影层美术**（`anim/*_shad.zip` 挂成 override build）：Klei 的影子美术
   本身就是"剪影 + 描边"，描边 alpha 更高，所以影子反而带上一条黑轮廓，
   比原版接缝更显眼 → 作废（相关 `*_shad.zip` 已从模组移除）。
2. **运行时哨兵切换着色器模式**：见根因 1 —— 静默失效、无法自证，已整体废弃。
