# sfsymbol-export

An agent skill for **Claude Code** and **Codex** that exports Apple SF Symbols as true-vector SVG and answers
questions about the SF Symbols catalog. It is built on `sfsymbols`, the command-line tool inside SF Symbols.app
(Xcode 27 era).

- **Look up symbols**: search by keyword, exact name, codepoint or glyph; OS availability per rendering mode;
  old names of renamed symbols.
- **Export SVG**: the symbol renderer's own outlines, in any weight, scale (small/medium/large) and rendering mode
  (monochrome, hierarchical, palette, multicolor). Tints become `currentColor`, the viewBox is tight, and monochrome
  output is a single overlap-free path, so both fill rules render it correctly.
- **Self-checking**: every SVG is rendered back and compared with the CLI's own PNG of the same symbol. The run also
  writes a side-by-side contact sheet.

Symbols with cut-outs come out of the CLI as bitmaps. The exporter rebuilds them from another rendering mode's
vector layers, or falls back to the SF Pro glyph. On 360 random symbols, 353 exported cleanly.

## Requirements

- macOS with **SF Symbols.app** that contains `Contents/Executables/sfsymbols`, and **SF Pro** installed
- Swift toolchain (the script runs with `swift export.swift`; no package build)

## Install

```sh
git clone https://github.com/kasimok/sfsymbol-export.git
cd sfsymbol-export
./install.sh          # links into ~/.claude/skills and ~/.agents/skills (Codex)
./install.sh claude   # Claude Code only
./install.sh codex    # Codex only
```

The install is a symlink, so `git pull` updates it.

Claude Code can also install it as a plugin:

```
/plugin marketplace add kasimok/sfsymbol-export
/plugin install sfsymbol-export@sfsymbol-export
```

## Use

Ask the agent, e.g. "export play.tv and checkmark.circle.fill as SVG", "which iOS version added
document.on.document?". Or run the script directly:

```sh
swift skills/sfsymbol-export/scripts/export.swift [--weight W] [--scale S] [--mode M] <outDir> <name>...
```

Details, CLI quirks and limits are in [`skills/sfsymbol-export/SKILL.md`](skills/sfsymbol-export/SKILL.md)
(written in Chinese).

## Test

```sh
./tests/smoke.sh
claude plugin validate --strict .
```
