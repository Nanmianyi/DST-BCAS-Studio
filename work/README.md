# work/ —— 离线工作台（不启动游戏就能验证渲染）

这里是本项目的"试验台"：所有**渲染效果先在这里离线复现/量化/出图**，确认无误再进游戏
实测。好处是改一个数值就能立刻看到结果，而且能把"观感问题"变成可以测量的数字。

## 运行前提

脚本直接读本机安装的《饥荒：联机版》美术资源（默认按
`J:/SteamLibrary/steamapps/common/Don't Starve Together/data/...`，路径在脚本顶部常量里改），
不需要启动游戏，只需要装了游戏本体 + `pip install pillow`。

```bash
python work/sim_glint.py          # 例：离线渲染海面波光的一帧
python tools/shadow_preview.py    # 例：影子剪影"旧 vs 新"对比图
```

## 影子剪影验证（本目录的重点）

生成脚本在 `../tools/`（都是离线跑、出图到本目录）：

| 脚本 | 做什么 |
|---|---|
| `shadow_alpha_audit.py` | 统计真实图集的 alpha 分布 → 定 alpha 硬裁剪阈值（0.30） |
| `shadow_faint_map.py` | 把"内部淡像素"可视化，确认它们是抗锯齿软边而非独立笔画 |
| `shadow_mask_audit.py` | 整页图集掩膜审计：旧实现"吃图/画到别人身上" vs 新实现 |
| `shadow_silhouette_sim.py` | 复现 GPU 采样（mip 金字塔 + 点/线性过滤）下的剪影映射 |
| `shadow_layers_demo.py` | 演示"多层叠加为什么会一块深一块浅"，以及单层混合为什么平 |
| `shadow_fill_sim.py` / `shadow_final_sim.py` | 填充映射的离线验收 |
| `shadow_preview.py` / `shadow_before_after.py` | 出"旧/新"对比图，进游戏前肉眼确认 |
| `silhouette_overlap_check.py` | 证明"只改 alpha 映射消不掉重叠线"（决定性实验） |

产出的证据图（已入库）：`_crop_*.png`（美术裁剪）、`_diag_shadow_zoom.png`、
`_shadow_before_after.png`、`_shadow_layers_demo.png`、`_shadow_wilson_alpha.png`、
`_sisim_*.png`（剪影模拟）、`_faint_*.png`、`_gapcheck.png`。

原理、三次根因与数值标定见 [`../docs/SHADOW_SILHOUETTE.md`](../docs/SHADOW_SILHOUETTE.md)。

## 其它内容

| 文件 | 做什么 |
|---|---|
| `sim*.py` | 海面波光 / 焦散 / 沙尘 / 辉光的离线仿真（按代数迭代，`sim_final.py` 是定版） |
| `mock_panel.py`、`atlas_render_check.py` | 设置面板与 UI 图集的离线预览（照 `bcas_screen.lua` 的坐标/配色） |
| `luacheck.py` | 独立 Lua 语法检查 |
| `retired_shadow_shader/` | 已废弃的自写影子着色器（存档，避免重走） |
| `_engine_shaders/`、`gs/`、`_dyn/`、`font_final/` | 本机素材解包产物 / 大件渲染产物 —— **不入库**（见 `.gitignore`），脚本可重新生成 |
