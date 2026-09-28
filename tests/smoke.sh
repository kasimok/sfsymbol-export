#!/bin/sh
# End-to-end check of scripts/export.swift against the installed SF Symbols CLI.
# Needs macOS with SF Symbols.app (the one that ships Contents/Executables/sfsymbols) and SF Pro.
# Symbols are picked to cover every code path; each must come back OK (IoU ≥ 0.98 against the
# CLI's own PNG, under both fill rules for monochrome).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/skills/sfsymbol-export/scripts/export.swift"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
fail=0

run() {  # run <label> <export args...>
  label=$1; shift
  if log=$(swift "$script" "$@" 2>/dev/null); then
    echo "$log" | grep -E '^(OK|CHECK|FAIL)' | sed "s/^/[$label] /"
  else
    echo "$log" | grep -E '^(OK|CHECK|FAIL)' | sed "s/^/[$label] /"
    echo "[$label] expected every symbol OK" >&2
    fail=1
  fi
}

# vector PDF · knockout rebuilt from a donor mode · SF Pro glyph · old name · crossing strokes (evenodd safety)
run monochrome "$out/mono" play.tv checkmark.circle.fill lightbulb.2 doc.on.doc plus xmark
run hierarchical --mode hierarchical "$out/hier" play.tv person.crop.circle.badge.plus
run multicolor --mode multicolor "$out/multi" cloud.sun.rain.fill
run small-bold --scale small --weight bold "$out/small" square.and.arrow.up gearshape.2

# An unknown name must fail loudly.
if swift "$script" "$out/bad" no.such.symbol >/dev/null 2>&1; then
  echo "[unknown-name] expected a non-zero exit" >&2
  fail=1
else
  echo "[unknown-name] fails as expected"
fi

[ $fail -eq 0 ] && echo "smoke test passed" || { echo "smoke test FAILED" >&2; exit 1; }
