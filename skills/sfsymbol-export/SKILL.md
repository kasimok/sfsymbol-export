---
name: sfsymbol-export
description: Export Apple SF Symbols as true-vector SVG (the symbol renderer's own outlines, via Apple's `sfsymbols` CLI inside SF Symbols.app), and look up symbol names, codepoints, OS availability and renames with the same CLI. Use when a design task needs faithful SF Symbol icons as SVG — reproducing app screens in claude.ai/design, HTML mockups, refreshing the Cineo design project's icon data (`screens/sf-icons.js`, `player/icons.js`) — or when you need to check whether a symbol exists, which OS version introduced it, or what it used to be called.
---

# SF Symbols 命令行 + 真矢量 SVG 导出

Xcode 27 这一代起，SF Symbols.app 自带命令行 `sfsymbols`。它能按名字精确查符号、导出官方矢量。别用「枚举 SF Pro 字形 + 位图比对」去猜名字对应的编码：相似符号会认错（internaldrive.fill 会被认成 externaldrive.fill），编码直接用 `search --json` 查。

```bash
S="/Applications/SF Symbols.app/Contents/Executables/sfsymbols"   # 不在 PATH 里
"$S" help search ; "$S" help export
```

## search — 查名字、编码、可用性、改名

| 要做的事 | 命令 |
|---|---|
| 按关键词找（按名字分词、别名、标签匹配，默认最多 50 条，`--limit 0` 不限） | `"$S" search play tv` |
| 精确查一个名字 + 编码 + 各平台起始版本 | `"$S" search --match-style exactName heart.fill --show-codepoint --show-availability --show-glyph` |
| 机器可读 | `"$S" search --json --match-style exactName heart.fill` → `[{name, codepoint:"U+1002B5", availability:{monochrome:{iOS:"13.0",…}, multicolor:{…}}}]` |
| 编码或字形反查名字 | `"$S" search U+1002B5`，或 `"$S" search 􀊵` |
| 只要部署目标上已有的符号 | `"$S" search --min-platform iOS16 --min-platform macOS13 <词>`（可重复，须全部满足） |
| 按分类 | `--category-filter health`（也有 transportation、media 等） |
| 列出整个目录（约 7200 个名字） | `"$S" search --limit 0 ''` |

实测要点：
- **查不到也返回 0、输出为空**——判断存在与否看输出，别看退出码。
- `--match-style exactName` 只认现名；`export` 却接受旧名。
- `--min-platform` 碰到改过名的符号会输出**旧名**加 `(renamed to: 新名)`——部署目标低于改名版本时，代码里要写旧名。
- `--show-availability` 显示的是 monochrome 的版本；JSON 按渲染模式分列，其他模式往往更晚（checkmark.circle.fill：monochrome iOS 13、multicolor 14、hierarchical/palette 15）。
- **今年（iOS 27）新增的符号在 JSON 里没有 `codepoint`**：已安装的 SF Pro 字体里还没有它们。

## export — 三种格式的真实面目

`"$S" export <名字> --format svg|png|pdf（可逗号并列） --output F | --output-dir D --weight W --symbol-scale small|medium|large --rendering-mode automatic|monochrome|hierarchical|palette|multicolor --color C --point-size N --image-scale N`

| 格式 | 实际内容 | 能否直接用 |
|---|---|---|
| `svg` | SF Symbols 的**编辑模板**：3300×2200 画布，只有 Ultralight-S / Regular-S / Black-S 三个母版 + 参考线和注释 | 不能直接放进页面。**忽略** weight/scale/mode。有用的是 `<style>` 里每种模式的分层规则：`.monochrome-1 {opacity:0.0;-sfsymbols-clear-behind:true}`、`.hierarchical-0:secondary`、`.multicolor-0:systemBlueColor` |
| `pdf` | 渲染器按所选字重/大小/模式输出的矢量 | 每层写成「按轮廓裁剪 + 填一个覆盖矩形」；页面框不等于图形外框（trash.fill 下方多出 9.5pt）；**只要该模式下有「擦除下层」的层，整页就是一张嵌入的位图** |
| `png` | 位图，尺寸 = 页面框 × image-scale | 用来做比对的标准答案 |

坑（2026-09-28 在 macOS 27 上实测）：
- 一次只能导一个名字（多给一个 → exit 64）；名字不存在 → exit 1，提示 `not found in the SF Symbols catalog`。
- **`--image-scale` 会把 PDF 的页面框放大，内容却不放大**（内容缩在左下角）→ 只对 png 用。
- 默认 `--color label` 是黑色 85% 透明度；要干净的颜色值就传 `--color black`。
- hierarchical 各层透明度（配 `--color black`）：primary 1、secondary 0.5、tertiary 0.18。
- palette 只能给一个 `--color`，其余层保持 CLI 默认色（如 systemBlue #007AFF）。
- 会变成位图的符号：monochrome 下凡是有镂空的（内部带图形的 `*.circle.fill`、带角标的 `.badge.*`），随机 200 个里有 65 个；hierarchical/palette 下主要是带角标的；multicolor 约 5%。
- 每次调用约 1.2 秒、只吃一个核 → 批量时要并行。
- 打开这些 PDF 时 stderr 会出现 `CoreGraphics PDF has logged an error`，是文档释放时的日志噪音，无害。

## 导出页面可用的 SVG — export.swift

脚本在本 skill 目录下的 `scripts/export.swift`（Claude Code 调用 skill 时会给出 skill 的 base directory，Codex 会给出 SKILL.md 的路径）：

```bash
swift <skill 目录>/scripts/export.swift [--weight W] [--scale S] [--mode M] <outDir> <名字>...
# 默认 regular / medium / monochrome；200 个符号约 1 分钟
# 产出 <outDir>/<名字>.svg，外加对照图 <outDir>/_sheet.png
```

每个符号的处理流程：
1. 导出 PDF，取每层的裁剪轮廓；黑色 → `currentColor`，层透明度 → `fill-opacity`。
2. PDF 是位图 → 从另一个仍是矢量的模式（依次试 hierarchical / multicolor / palette / monochrome）借同一套分层轮廓，按模板里目标模式的规则重建：`clear-behind` 层做路径减法，`opacity:0` 层丢弃。支持 monochrome 和 hierarchical。输出行标注 `knockout←<借用的模式>`。
3. 所有模式都是位图（如 lightbulb.2、sun.haze、align.vertical.center）→ 仅限 monochrome + medium：用 `search --json` 拿到精确编码，从 SF Pro（`SFPro-<字重>`）取字形轮廓。标注 `font-glyph`。字形和渲染器输出相差约 0.3pt（按 100pt 计）。旧名也能处理：`exactName` 查不到时，取宽松搜索的前 5 个候选，导出 PNG 与原名逐像素一致的就是现名（doc.on.doc → document.on.document）。
4. 自检：把写出的 SVG 读回来渲染，与 CLI 的 2 倍 PNG 比 alpha 的 IoU（交并比）；monochrome 另按奇偶规则（evenodd）再比一次，取较低分。

读输出：
- `OK <名字> <宽>x<高> layers=N iou=0.99xx [knockout←… | font-glyph]`
- `CHECK …`：IoU < 0.98 → 看 `_sheet.png`（左 = CLI 的 PNG，右 = 我们的 SVG）。已知误报：细虚线符号走 font-glyph 时分数偏低（circle.dotted.and.circle 0.975，形状是对的）。
- `FAIL <名字>: <原因>`
- 实测（2026-09-28，字体版本 22.0d5e4）：随机 200 个 monochrome，199 OK + 1 CHECK（即上面那个误报）；hierarchical 97/100；multicolor 57/60。

## 输出格式

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W H" width="W" height="H" data-sfsymbol="name" data-weight="regular" data-scale="medium" data-mode="monochrome">
<path d="M…C…Z" fill="currentColor"/>
</svg>
```
- **monochrome 永远只有一个 `<path>`，且已去掉轮廓重叠**：各层用路径布尔运算合并。不能简单拼接 `d` 字符串——两层重叠且绕向相反时，非零填充规则会把重叠处抵消成洞。单层也要去重叠：渲染器的原始轮廓依赖非零规则，加号、叉号、箭头这类交叉笔画用 `fill-rule="evenodd"` 画会在交叉处出洞。去重叠后两种规则画出来一样，消费方写死 evenodd 也安全。
- hierarchical：每层一个 path，`currentColor` + `fill-opacity`。
- multicolor：固定色写成十六进制；跟随强调色的层写成 `currentColor`；白色层是 `#ffffff`（白底上看不见，属正常）。
- 坐标 y 向下，viewBox 紧贴图形外框，单位是 100pt 字号下的 pt → **尺寸换算**：在 `.font(.system(size: N))` 下显示的符号 = viewBox × N/100 CSS px。紧贴外框会丢掉符号之间共用的基线，并排时需按视觉对齐。
- 已用 rsvg-convert（非 Apple 渲染器）交叉验证，浏览器里显示正确。
- SF Pro 字体里的字形不总等于 app 里的画法：photo 的字体版底部是双边框，渲染器版是山形填到底。本脚本以渲染器为准（font-glyph 兜底除外）。

## 做不到的情况（输出 FAIL）

- palette / multicolor 下有擦除层：没有补救路径 → 改用 monochrome/hierarchical 导出，再手动改色。
- hierarchical 下所有模式都是位图（约 3%，如 building.2、party.popper.fill）。
- small/large 大小下所有模式都是位图：字形补救只有 medium（large 不是 medium 等比放大：约 1.26–1.28 倍，且各大小的笔画粗细单独调过）。
- iOS 27 新符号且所有模式都是位图（没有字体编码），如 creditcard.badge.plus.fill。

## 相关

- Cineo 设计项目（claude.ai/design）里符号数据的格式约定、禁换项和备份位置：见 `references/cineo.md`。改那个项目的图标前先读。
