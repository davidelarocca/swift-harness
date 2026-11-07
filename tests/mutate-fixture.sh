#!/bin/bash
# Check sensitivity with real builds (#79): scripts/mutate.sh --verify on two fixtures, with
# the setup templates and a generated scripts/verify.sh. Each operator must be killed by the
# check it targets. Needs Xcode and SwiftLint; takes several minutes.
#
#   tests/mutate-fixture.sh             the package fixture (lint, keyboard, layout sizes, snapshots)
#   tests/mutate-fixture.sh --ui        also the accessibility fixture (an app with UI tests)
#
# The snapshot baseline is approved on this machine first, so it is compared here.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN="$HERE/../plugins/swift-harness"
SCRIPTS="$PLUGIN/scripts"
TEMPLATES="$PLUGIN/skills/setup/templates"
# In the repository's .build (ignored by git), not the system temporary folder: its path goes
# through a symbolic link, and there SwiftLint baselines match nothing.
mkdir -p "$HERE/../.build"
TMP="$(cd "$(mktemp -d "$HERE/../.build/mutate-fixture.XXXXXX")" && pwd -P)"
[ "${SWIFT_HARNESS_MUTATE_KEEP:-}" = 1 ] || trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_DATA="$TMP/data"
UI=false
[ "${1:-}" = --ui ] && UI=true

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
nok() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' | tail -30
}
expect() { # $1 name, $2 regex, $3 output
  if grep -qE -- "$2" <<<"$3"; then ok "$1"; else nok "$1" "$3"; fi
}

# $1 project, $2 container flag, $3 scheme, $4 packages, $5 platforms
verify_script() {
  mkdir -p "$1/scripts"
  sed -e "s|{{XCODE_CONTAINER_FLAG}}|$2|" -e "s/{{SCHEME}}/$3/" -e "s|{{LOCAL_PACKAGES}}|$4|" \
    -e "s/{{PLATFORMS}}/$5/" -e 's/{{IOS_SIMULATOR}}//' "$TEMPLATES/verify.sh" >"$1/scripts/verify.sh"
  chmod +x "$1/scripts/verify.sh"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm "$2"; }

# ---------- package: lint, keyboard, layout sizes, snapshots ----------

P="$TMP/package"
cp -RL "$HERE/fixtures/mutate-verify" "$P"
for t in KeyboardCheck LayoutContract Screenshot Snapshot; do cp "$TEMPLATES/tests/$t.swift" "$P/Tests/ComponentsTests/"; done
# The tokens file is the design system: the hardcoded value rules leave it alone.
sed "s#{{DS_EXCLUDED_REGEX}}#Sources/Components/Tokens\\\\.swift#" "$TEMPLATES/swiftlint.yml" >"$P/.swiftlint.yml"
verify_script "$P" "" "" '"."' '"macOS"'
git -C "$P" init -q && commit "$P" fixture

# First run: the snapshot has no baseline yet. Approve it as the user would, then it passes.
(cd "$P" && scripts/verify.sh full) >"$TMP/first.log" 2>&1
digest="$("$SCRIPTS/snapshots.sh" --status --project "$P" | sed -n 's/^Digest: //p')"
"$SCRIPTS/snapshots.sh" --approve "$digest" --project "$P" >/dev/null 2>&1
commit "$P" "approved snapshots"
out="$(cd "$P" && scripts/verify.sh full 2>&1)"
code=$?
if [ "$code" -eq 0 ]; then ok "package: verify full passes once the snapshot is approved"
else nok "package: verify full passes once the snapshot is approved" "$out"; fi

out="$("$SCRIPTS/mutate.sh" --project "$P" --verify 2>&1)"
printf '%s\n' "$out" >"$TMP/package-report.md"
expect "package: the run without mutations passes verify" 'Without mutations: .*verify pass' "$out"
for op in lint-literal:lint keyboard-shortcut:keyboard layout-wide:layout-size snapshot-padding:snapshot; do
  expect "package: ${op%%:*} is killed by the ${op#*:} check" "^\| ${op%%:*} \| [^|]+ \| ${op#*:} \| killed \| [^|]*${op#*:}" "$out"
done
expect "package: a11y-label has no site (no accessibility label)" '^\| a11y-label \| - \| accessibility \| no site' "$out"
printf '%s\n' "$out" | grep -E '^\|' | sed 's/^/      /'

# ---------- app with UI tests: accessibility ----------

if [ "$UI" = true ]; then
  A="$TMP/a11y"
  cp -RL "$HERE/fixtures/accessibility" "$A"
  verify_script "$A" "-project A11yFixture.xcodeproj" A11yFixture '' '"macOS"'
  # An existing app: the violations already there go into a baseline, as setup suggests.
  sed "s#{{DS_EXCLUDED_REGEX}}#NONE#" "$TEMPLATES/swiftlint.yml" >"$A/.swiftlint.yml"
  (cd "$A" && swiftlint lint --quiet --write-baseline .swiftlint-baseline.json >/dev/null 2>&1)
  sed -i '' 's|^LINT_BASELINE=""|LINT_BASELINE=".swiftlint-baseline.json"|' "$A/scripts/verify.sh"
  git -C "$A" init -q && commit "$A" fixture
  out="$("$SCRIPTS/mutate.sh" --project "$A" --verify --only a11y-label 2>&1)"
  printf '%s\n' "$out" >"$TMP/a11y-report.md"
  expect "app: the run without mutations passes verify" 'Without mutations: .*verify pass' "$out"
  expect "app: a11y-label is killed by the accessibility check" '^\| a11y-label \| [^|]+ \| accessibility \| killed \| [^|]*accessibility' "$out"
  printf '%s\n' "$out" | grep -E '^\|' | sed 's/^/      /'
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
