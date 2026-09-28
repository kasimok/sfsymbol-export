# AGENTS.md

Notes for coding agents (Codex, Claude Code) working **on** this repo. Using the skill is covered by
`skills/sfsymbol-export/SKILL.md`.

## Layout

- `skills/sfsymbol-export/` — the skill, in the shared Agent Skills layout both Claude Code and Codex read:
  `SKILL.md` (frontmatter: `name` + `description` only), `scripts/export.swift`, `references/`.
- `.claude-plugin/plugin.json` + `marketplace.json` — lets Claude Code install the repo as a plugin.
- `install.sh` — symlinks the skill into `~/.claude/skills` and `~/.agents/skills` (Codex's user-level folder).
- `tests/smoke.sh` — end-to-end run of the exporter over every code path.

## Rules

- Keep SKILL.md frontmatter to `name` and `description`; both agents require them and extra keys are not portable.
  Refer to bundled files by paths relative to the skill folder, never by an install location.
- `scripts/export.swift` stays a single file that runs with `swift export.swift` (no package) and compiles in
  Swift 6 language mode: `swift -swift-version 6 skills/sfsymbol-export/scripts/export.swift /tmp/x play.tv`.
- Every exported SVG is checked against the CLI's own PNG. Don't weaken that check or the IoU threshold to make a
  symbol pass; find out why it differs.
- Monochrome output is one normalized `<path>`, so `fill-rule="evenodd"` consumers render it correctly. The self-check
  tests both fill rules; keep it that way.
- When behavior changes, update the measured numbers and limits in SKILL.md, and bump `version` in both
  `.claude-plugin` files.

## Testing

`./tests/smoke.sh` (about 30 s) needs macOS with SF Symbols.app that ships `Contents/Executables/sfsymbols`
(Xcode 27 era) and SF Pro installed. Validate the plugin manifests with `claude plugin validate --strict .`.
