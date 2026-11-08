#!/bin/bash
# The "project's own docs check" of the docs-adapter smoke scenario (#105): every repository
# path in backticks in CLAUDE.md and docs/*.md must exist. Exit 1 with one line per problem.
cd "$(dirname "$0")/.." || exit 2
problems="$(for f in CLAUDE.md docs/*.md; do
  [ -f "$f" ] || continue
  grep -noE '`Sources/[^`]+`' "$f" | while IFS=: read -r n p; do
    p="${p//\`/}"
    [ -e "$p" ] || echo "$f:$n: missing $p"
  done
done)"
[ -z "$problems" ] && exit 0
printf '%s\n' "$problems"
exit 1
