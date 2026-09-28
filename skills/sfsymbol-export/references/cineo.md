# Cineo 设计项目的 SF Symbol 数据

claude.ai/design 项目 Cineo（projectId `a7922b2e-c28d-469c-918c-9cc84a2752ef`，用 DesignSync 读写）里的符号数据：
- `screens/sf-icons.js`：`window.SF_ICONS = {name: [viewBox, d]}`，227 张单页共用，`kit.js` 以 `<i class="sf" data-sf="…">` 渲染，**写死 `fill-rule="evenodd"`**。数据 = `scripts/export.swift` monochrome/regular/medium 输出，数字保留两位小数。
- `player/icons.js`（播放器原型）有两套数据：
  - `_SFX = {name: {w, h, p:[d], r:1}}`：`scripts/export.swift` medium 输出，`r:1` = evenodd。
  - `_SFD = {name: {p:[d…], o:[x,y], s}}`：small 号、模板坐标、按层分开；约定 `o` = −(外框中心)，`s` = 1.16 × 外框长边（保留一位小数）。替换时用 `--scale small` 导出，按同一公式算 `o`/`s`。**`10.arrow.trianglehead.*` 别换**：`Seek10` 旋转动画依赖它的两层（箭头/数字）和模板坐标里的圆心 (46.2402, -35.2539)。
- 2026-09-28 已用 `scripts/export.swift` 整体重导，替换前的云端版本备份在 `~/Documents/SProj/Cineo/_pre-sfsymbols-2026-09-28/`。
