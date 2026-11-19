#!/bin/bash
# The formatters and the files the setup copies, with the real tools (tests/run.sh uses fakes).
#
# The test helpers (templates/tests/*.swift) are kept as shipped, so that a later version can
# be compared with them: with the generated .swiftformat, and with the generated .swift-format,
# a formatter must leave every one of them as it is. Both the whole-project run
# (`swiftformat .`) and the one-file run of the post-edit hook are checked.
# Usage: tests/format-helpers.sh
# Exit: 0 all as expected, 1 a formatter would change something, 2 a tool is missing (nothing
# is reported as checked).

set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
TEMPLATES="$HERE/../plugins/swift-harness/skills/setup/templates"

command -v swiftformat >/dev/null 2>&1 || { echo "format-helpers: swiftformat is not installed (brew install swiftformat). Nothing checked." >&2; exit 2; }
if xcrun --find swift-format >/dev/null 2>&1; then apple=(xcrun swift-format)
elif command -v swift-format >/dev/null 2>&1; then apple=(swift-format)
else echo "format-helpers: swift-format is not installed (it ships with Xcode). Nothing checked." >&2; exit 2; fi

TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/swift-harness-format.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
failed=0
ok() { printf 'ok    %s\n' "$1"; }
nok() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' | head -12; }

# A project as the setup leaves it: the helpers in a test target, the formatter configs at the
# root. Every Swift language version the template is filled with behaves the same here.
project() { # $1 folder, $2 Swift version
  mkdir -p "$1/Tests/AppTests"
  cp "$TEMPLATES"/tests/*.swift "$1/Tests/AppTests/"
  sed "s/{{SWIFT_VERSION}}/$2/" "$TEMPLATES/swiftformat" >"$1/.swiftformat"
  cp "$TEMPLATES/swift-format" "$1/.swift-format"
}

for version in 5.10 6.0 6.2; do
  P="$TMP/p-$version"
  project "$P" "$version"
  out="$(cd "$P" && swiftformat . --lint 2>&1)"
  if [ $? -eq 0 ]; then ok "swiftformat . leaves the helpers as shipped (--swiftversion $version)"
  else nok "swiftformat . leaves the helpers as shipped (--swiftversion $version)" "$(printf '%s\n' "$out" | grep -E 'error:' | sed -E 's|^.*/Tests/AppTests/||' | awk -F: '{ n[$1]++ } END { for (f in n) print f ": " n[f] " line(s) would change" }' | sort)"; fi
done

# One file at a time, as the post-edit hook runs it after an edit.
P="$TMP/one"
project "$P" 6.2
changed=""
for f in "$P"/Tests/AppTests/*.swift; do
  name="$(basename "$f")"
  (cd "$P" && swiftformat --quiet "Tests/AppTests/$name" >/dev/null 2>&1)
  cmp -s "$f" "$TEMPLATES/tests/$name" || changed="$changed $name"
done
if [ -z "$changed" ]; then ok "swiftformat on one file, as the post-edit hook runs it, changes no helper"
else nok "swiftformat on one file, as the post-edit hook runs it, changes no helper" "changed:$changed"; fi

P="$TMP/apple"
project "$P" 6.2
changed=""
for f in "$P"/Tests/AppTests/*.swift; do
  name="$(basename "$f")"
  (cd "$P" && "${apple[@]}" format --in-place "Tests/AppTests/$name" >/dev/null 2>&1)
  cmp -s "$f" "$TEMPLATES/tests/$name" || changed="$changed $name"
done
if [ -z "$changed" ]; then ok "swift-format changes no helper"
else nok "swift-format changes no helper" "changed:$changed"; fi

# The markers must not hide a formatter that does nothing: the same configs do format a file
# of the project.
P="$TMP/works"
project "$P" 6.2
printf 'import Foundation\nstruct  Spaced {\n  let a = [1,2]\n}\n' >"$P/Tests/AppTests/Own.swift"
cp "$P/Tests/AppTests/Own.swift" "$TMP/own-before.swift"
(cd "$P" && swiftformat --quiet Tests/AppTests/Own.swift >/dev/null 2>&1)
if ! cmp -s "$P/Tests/AppTests/Own.swift" "$TMP/own-before.swift"; then ok "swiftformat still formats the project's own files"
else nok "swiftformat still formats the project's own files"; fi

echo
if [ "$failed" -eq 0 ]; then echo "format-helpers: all passed ($(swiftformat --version), $("${apple[@]}" --version 2>/dev/null | head -1))"; exit 0; fi
echo "format-helpers: $failed failed"
exit 1
