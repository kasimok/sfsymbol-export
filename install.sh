#!/bin/sh
# Symlink the skill into the user-level skill folders of Claude Code and Codex.
#   ./install.sh            both
#   ./install.sh claude     ~/.claude/skills only
#   ./install.sh codex      ~/.agents/skills only (Codex's documented user-level location)
# A symlink keeps the installed skill in step with this checkout; `git pull` is the update.
set -eu

name=sfsymbol-export
src="$(cd "$(dirname "$0")" && pwd)/skills/$name"

case "${1:-all}" in
  all) targets="$HOME/.claude/skills $HOME/.agents/skills" ;;
  claude) targets="$HOME/.claude/skills" ;;
  codex) targets="$HOME/.agents/skills" ;;
  *) echo "usage: $0 [all|claude|codex]" >&2; exit 64 ;;
esac

for dir in $targets; do
  mkdir -p "$dir"
  dst="$dir/$name"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    echo "$dst exists and is not a symlink; move it away first" >&2
    exit 1
  fi
  ln -s "$src" "$dst"
  echo "linked $dst -> $src"
done
