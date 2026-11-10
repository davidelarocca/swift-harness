#!/bin/bash
# Test isolation (#68): UI tests must launch the app on its own data, never the user's.
# Reads Swift files as text and runs no code from the repository.
#
# Usage: isolation.sh check <project root>
#   The isolation arguments come from uiTests.isolation in .claude/swift-harness.json: the
#   launch arguments or environment keys that make the app use a test store, defaults domain
#   and support folders (for example "-UITestingSuite"). A UI test file (one that uses
#   XCUIApplication) that launches the app must name one of them, or call a launch helper
#   declared in a UI test file that names one: a function with "launch" in its name
#   (launchWithSongs(), not launch() itself, which is XCUIApplication's), or one listed in
#   uiTests.launchHelpers. Other helpers do not count: a file that calls close() is not
#   isolated because the file declaring close() is.
#   Exit 0: isolated, or no UI tests. Exit 1: files that launch without it, one
#   "- <file>:<line>: ..." per line. Exit 3: UI tests launch the app and no isolation
#   argument is declared (printed, never blocks).

set -uo pipefail
export LC_ALL=C

mode="${1:-}"
root="${2:-}"
[ "$mode" = check ] && [ -n "$root" ] || { echo "usage: isolation.sh check <project root>" >&2; exit 2; }
root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "isolation: no such folder" >&2; exit 2; }
config="$root/.claude/swift-harness.json"

args="$(jq -r '.uiTests.isolation[]? | strings' "$config" 2>/dev/null | grep -v '^$')"

if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  swift="$(git -C "$root" -c core.quotepath=off ls-files -co --exclude-standard -- '*.swift' 2>/dev/null)"
else
  swift="$(cd "$root" && find . -name '*.swift' -not -path '*/.build/*' | sed 's#^\./##')"
fi
ui="$(while IFS= read -r f; do
  [ -n "$f" ] && grep -q 'XCUIApplication' "$root/$f" 2>/dev/null && printf '%s\n' "$f"
done <<<"$(printf '%s\n' "$swift" | grep -v '/\.build/' | sort)")"
[ -n "$ui" ] || exit 0
launching="$(while IFS= read -r f; do
  [ -n "$f" ] && grep -qE '\.launch\(\)' "$root/$f" && printf '%s\n' "$f"
done <<<"$ui")"
[ -n "$launching" ] || exit 0

if [ -z "$args" ]; then
  printf 'Test isolation: %s UI test file(s) launch the app, and .claude/swift-harness.json declares no uiTests.isolation arguments, so whether they use the user'"'"'s real data was not checked.\n' "$(grep -c . <<<"$launching")"
  exit 3
fi

# Files that name an isolation argument, and the helper functions they declare.
alt="$(printf '%s\n' "$args" | sed 's/[][\\.*^$+?(){}|/]/\\&/g' | paste -sd'|' -)"
isolated="$(while IFS= read -r f; do
  [ -n "$f" ] && grep -qE -- "$alt" "$root/$f" && printf '%s\n' "$f"
done <<<"$ui")"
declared="$(jq -r '.uiTests.launchHelpers[]? | strings' "$config" 2>/dev/null)"
helpers="$(while IFS= read -r f; do
  [ -n "$f" ] && grep -oE 'func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$root/$f" | awk '{ print $2 }'
done <<<"$isolated" | sort -u | while IFS= read -r h; do
  { printf '%s' "$h" | grep -qi 'launch' && [ "$h" != launch ]; } || grep -qxF -- "$h" <<<"$declared" && printf '%s\n' "$h"
done | paste -sd'|' -)"

problems=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF -- "$f" <<<"$isolated" && continue
  if [ -n "$helpers" ] && grep -qE "(^|[^A-Za-z0-9_])($helpers)\(" "$root/$f"; then continue; fi
  line="$(grep -nE '\.launch\(\)' "$root/$f" | head -1 | cut -d: -f1)"
  problems="$problems- $f:$line: launches the app without an isolation argument ($(printf '%s\n' "$args" | paste -sd, - | sed 's/,/, /g')), so it can open the user's real data"$'\n'
done <<<"$launching"

if [ -n "$problems" ]; then
  printf 'Test isolation (uiTests.isolation):\n%s' "$problems"
  exit 1
fi
exit 0
