#!/bin/bash
# Check sensitivity (#79): plant one defect at a time in a copy of the project and record
# which checks notice it. Run by the user, never by a hook.
#
#   mutate.sh [--project DIR] [--verify] [--only OPERATOR]...   run the mutations, print the report
#   mutate.sh --list                                            the operators and the check each one targets
#
# The project itself is never changed: it is copied (without .git, .build and DerivedData)
# into a folder under its .build/swift-harness/, removed at the end, with a fresh git repository, so checks that read `git ls-files`
# see the same files. Each operator changes one file at one site, chosen the same way every
# run; the file is restored before the next operator.
#
# The checks are run once on the copy without mutations. A mutation is killed by a check
# when that check fails on it with a problem it did not report before (line numbers are
# ignored), so a check that already fails can still notice a new defect. A survived
# mutation is a finding to explain (a bug in the check, or out of its scope by design), not
# a failure of the run: the exit code is 0 whenever the report is produced.
#
# The checks that run inside the project's tests and SwiftLint (lint, keyboard, layout sizes,
# accessibility, snapshots) need --verify: it runs `scripts/verify.sh full` on the copy once
# without mutations and once per operator, a full build and test run each time. Its output is
# one block, so a failure is credited to a check by what it names: a SwiftLint rule on the
# mutated file (lint), or a test file, or a type declared in one, that calls the check's API
# (KeyboardCheck., LayoutContract.check or LayoutAudit., AccessibilityAudit. or
# performAccessibilityAudit, Snapshot.verify). Numbers are ignored when comparing with the
# run without mutations (durations, counts). A verify failure credited to none of them is
# shown as "verify" (often a mutation that does not build: say so in the report).
#
# contracts.sh evaluates Package.swift (code from the repository) through
# `swift package dump-package`; that is why this script is for the user to run.
#
# Exit 0: report printed. Exit 2: usage error, or the project cannot be copied.

set -uo pipefail
export LC_ALL=C

here="$(cd "$(dirname "$0")" && pwd)"

# operator<TAB>target check<TAB>defect it plants
OPERATORS='registry-rename	registry	a Components entry renamed, so the registry names a type the code does not declare
layout-rename	layout	a Screens row names a view the code does not declare
docs-stale-link	docs	a Markdown link (or a path in backticks) moved to a file that does not exist
security-relax	security	an entitlement relaxed (library validation off, then unsigned memory, then JIT)
contracts-forbidden	contracts	a target gains a dependency on a sibling target its contract does not allow
lint-literal	lint	a padding token replaced by a number (needs --verify)
keyboard-shortcut	keyboard	a .keyboardShortcut removed, from a view a KeyboardCheck test hosts first (needs --verify)
layout-wide	layout-size	the first Screens view made 200 pt wider than its Min width (needs --verify)
a11y-label	accessibility	an .accessibilityLabel removed (needs --verify)
snapshot-padding	snapshot	a padding made 3 pt larger, in a view a snapshot test renders (needs --verify)'
CHECKS='registry layout docs security contracts'
# Checks run by scripts/verify.sh full: credited from its output.
VCHECKS='lint keyboard layout-size accessibility snapshot'

usage() {
  echo "usage: mutate.sh [--project DIR] [--verify] [--only OPERATOR]... | --list" >&2
  exit 2
}

project="."
only=""
verify=false
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      printf '%s\n' "$OPERATORS" | awk -F'\t' '{ printf "%-20s %-10s %s\n", $1, $2, $3 }'
      exit 0
      ;;
    --project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
    --verify) verify=true; shift ;;
    --only)
      [ $# -ge 2 ] || usage
      printf '%s\n' "$OPERATORS" | cut -f1 | grep -qxF -- "$2" || { echo "mutate: unknown operator \"$2\" (see --list)" >&2; exit 2; }
      only="$only $2"
      shift 2
      ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "mutate: jq is required (brew install jq)." >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "mutate: git is required." >&2; exit 2; }
project="$(cd "$project" 2>/dev/null && pwd -P)" || { echo "mutate: no such folder." >&2; exit 2; }

# The copy lives in the project's .build folder, not in the system temporary folder: there
# the path goes through a symbolic link (/var, /tmp to /private) and SwiftLint baselines
# match nothing (measured with SwiftLint 0.65), so verify would fail on old violations.
created=""
for d in .build .build/swift-harness; do
  [ -d "$project/$d" ] || { mkdir "$project/$d" 2>/dev/null && created="$project/$d $created"; }
done
work="$(mktemp -d "$project/.build/swift-harness/mutate.XXXXXX" 2>/dev/null)" || { echo "mutate: cannot create a folder in $project/.build." >&2; exit 2; }
cleanup() {
  rm -rf "$work"
  local d
  for d in $created; do rmdir "$d" 2>/dev/null; done
}
# SWIFT_HARNESS_MUTATE_KEEP=1 keeps the copy and the outputs, to look at a result.
if [ "${SWIFT_HARNESS_MUTATE_KEEP:-}" = 1 ]; then echo "mutate: keeping $work" >&2; else trap cleanup EXIT; fi
copy="$work/project"
mkdir -p "$copy" "$work/data" "$work/base" "$work/mut" "$work/orig"
if ! (cd "$project" && tar -cf - --exclude ./.git --exclude .build --exclude DerivedData --exclude '*.xcresult' .) | (cd "$copy" && tar -xf -); then
  echo "mutate: could not copy $project." >&2
  exit 2
fi
git -C "$copy" init -q 2>/dev/null || { echo "mutate: git init failed in the copy." >&2; exit 2; }
# The checks read their settings from the config; a project without one gets the defaults.
[ -f "$copy/.claude/swift-harness.json" ] || { mkdir -p "$copy/.claude" && printf '{}\n' >"$copy/.claude/swift-harness.json"; }
copy_real="$(cd "$copy" && pwd -P)"

# ---- checks ----

# $1 check, $2 output folder: writes <check>.exit and <check>.out (line numbers removed).
run_check() {
  local c="$1" dir="$2" out code
  case "$c" in
    docs)
      # The project's own docs check (#105) instead of docs.sh: its code, so with --verify only.
      a_cmd="$(jq -r '.docs.command // empty | strings' "$copy/.claude/swift-harness.json" 2>/dev/null)"
      if [ -z "$a_cmd" ]; then out="$("$here/docs.sh" check "$copy" 2>&1 </dev/null)"
      elif [ "$verify" = true ]; then
        out="$(cd "$copy" && bash -c "$a_cmd" 2>&1 </dev/null)"
        [ $? -eq 0 ] || { printf '%s' 1 >"$dir/$c.exit"; printf '%s\n' "$out" | sed -E 's/:[0-9]+(:|$)/\1/g' | grep -v '^$' | sort -u >"$dir/$c.out"; return; }
      else out="the project's docs check (docs.command) runs the project's code: needs --verify"; printf '%s' 2 >"$dir/$c.exit"; printf '%s\n' "$out" >"$dir/$c.out"; return
      fi ;;
    registry | layout) out="$("$here/$c.sh" check "$copy" 2>&1 </dev/null)" ;;
    security) out="$(CLAUDE_PLUGIN_DATA="$work/data" "$here/security.sh" check --project "$copy" 2>&1 </dev/null)" ;;
    contracts) out="$("$here/contracts.sh" "$copy" 2>&1 </dev/null)" ;;
  esac
  code=$?
  printf '%s' "$code" >"$dir/$c.exit"
  printf '%s\n' "$out" | sed -E 's/:[0-9]+(:|$)/\1/g' | grep -v '^$' | sort -u >"$dir/$c.out"
}

# $1 output folder: verify.exit and verify.out (paths of the copy, colors and numbers removed).
run_verify() {
  local code
  (cd "$copy" && bash scripts/verify.sh full) </dev/null >"$work/verify.raw" 2>&1
  code=$?
  printf '%s' "$code" >"$1/verify.exit"
  sed -E -e "s#$copy_real/##g" -e "s#$copy/##g" -e $'s/\x1b\\[[0-9;]*m//g' -e 's/[0-9]+/#/g' "$work/verify.raw" |
    grep -v '^[[:space:]]*$' | sort -u >"$1/verify.out"
}

# Failure lines of the mutated run that the run without mutations did not print, only when
# it failed: a line that names a test that passed in both runs is not a failure. An indented
# "Name.test()" line is a test listed under "Failing tests:" by xcodebuild -quiet.
verify_new() {
  [ "$(cat "$work/mut/verify.exit")" != 0 ] || return 0
  comm -13 "$work/base/verify.out" "$work/mut/verify.out" |
    grep -iE 'error|fail|issue|violation|✘|^[[:space:]]+[A-Za-z_#][A-Za-z0-9_.#]*\(\)$' || true
}

# Swift files of the copy, split into tests and the rest (Package.swift left out).
swift_files() { git -C "$copy" ls-files -co --exclude-standard -- '*.swift' 2>/dev/null | grep -v '/\.build/' | sort; }
is_test() { grep -E '(^|/)[^/]*Tests?/|Tests?\.swift$'; }
test_files() { swift_files | is_test; }
source_files() { swift_files | grep -vE '(^|/)[^/]*Tests?/|Tests?\.swift$|(^|/)Package\.swift$'; }

# The helper types of the setup templates: their own files call their API, and their functions
# are the API, not helpers of the project.
TEMPLATE_TYPES='KeyboardCheck|LayoutContract|LayoutAudit|AccessibilityAudit|Snapshot|Screenshot|FocusOrder|PerformanceBudget'

# $1 ERE of a check's API: test files that call it, directly or through a helper function
# declared in a test file that calls it directly (an assertAccessibility() wrapping the audit).
tests_using() {
  local f direct helpers
  direct="$(while IFS= read -r f; do
    [ -n "$f" ] && grep -qE "$1" "$copy/$f" 2>/dev/null && printf '%s\n' "$f"
  done <<<"$(test_files)")"
  [ -n "$direct" ] || return 0
  printf '%s\n' "$direct"
  helpers="$(while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE "(class|struct|enum|extension)[[:space:]]+($TEMPLATE_TYPES)([^A-Za-z0-9_]|$)" "$copy/$f" && continue
    grep -oE 'func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$copy/$f" | awk '{ print $2 }' | grep -v '^test'
  done <<<"$direct" | sort -u | paste -sd'|' -)"
  [ -n "$helpers" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF -- "$f" <<<"$direct" && continue
    grep -qE "(^|[^A-Za-z0-9_])($helpers)\(" "$copy/$f" 2>/dev/null && printf '%s\n' "$f"
  done <<<"$(test_files)"
}

# $1 ERE of a check's API: an ERE matching its tests in verify output (file names and the
# types they declare), or nothing.
signature_of() {
  local f names=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    names="$names $(basename "$f" .swift | sed 's/[0-9][0-9]*/#/g')"
    names="$names $(grep -oE '(class|struct|enum|actor)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$copy/$f" | awk '{ print $2 }' | sed 's/[0-9][0-9]*/#/g' | tr '\n' ' ')"
  done <<<"$(tests_using "$1")"
  # File names can hold regex characters (XCUIApplication+Layout).
  names="$(printf '%s\n' $names | grep -v '^$' | sort -u | sed 's/[][\\.*^$+?(){}|]/\\&/g' | paste -sd'|' -)"
  [ -n "$names" ] && printf '(^|[^A-Za-z0-9_])(%s)([^A-Za-z0-9_]|$)' "$names"
}

# $1 ERE of a check's API: source files declaring a type its tests use, then the other sources.
sources_by_coverage() {
  local names f covered
  names="$(while IFS= read -r f; do [ -n "$f" ] && grep -oE '[A-Z][A-Za-z0-9_]*\(' "$copy/$f"; done <<<"$(tests_using "$1")" |
    tr -d '(' | sort -u | paste -sd'|' -)"
  covered=""
  if [ -n "$names" ]; then
    covered="$(while IFS= read -r f; do
      [ -n "$f" ] && grep -qE "(struct|class|enum|actor)[[:space:]]+($names)([^A-Za-z0-9_]|$)" "$copy/$f" && printf '%s\n' "$f"
    done <<<"$(source_files)")"
  fi
  { [ -z "$covered" ] || printf '%s\n' "$covered"; source_files | grep -vxF -- "${covered:-/}"; } | grep -v '^$'
}

# $1 verify check: the ERE that credits a new verify line to it.
credit_regex() {
  case "$1" in
    lint) printf '%s' ": (warning|error): .*\\([a-z_]+\\)[[:space:]]*$" ;;
    keyboard) signature_of 'KeyboardCheck\.' ;;
    layout-size) signature_of 'LayoutContract\.check|LayoutAudit\.' ;;
    accessibility) signature_of 'AccessibilityAudit\.|performAccessibilityAudit' ;;
    snapshot) signature_of 'Snapshot\.verify' ;;
  esac
}

# $1 verify check: why it cannot notice anything in this project (no test calls its API, or
# SwiftLint has no rule for it), or nothing.
no_check() {
  case "$1" in
    lint) grep -q 'ds_hardcoded_padding' "$copy/.swiftlint.yml" 2>/dev/null || printf 'no ds_hardcoded_padding rule in .swiftlint.yml' ;;
    keyboard) [ -n "$(tests_using 'KeyboardCheck\.')" ] || printf 'no test calls KeyboardCheck' ;;
    layout-size) [ -n "$(tests_using 'LayoutContract\.check|LayoutAudit\.')" ] || printf 'no test calls LayoutContract.check or LayoutAudit' ;;
    accessibility) [ -n "$(tests_using 'AccessibilityAudit\.|performAccessibilityAudit')" ] || printf 'no test runs an accessibility audit' ;;
    snapshot) [ -n "$(tests_using 'Snapshot\.verify')" ] || printf 'no test calls Snapshot.verify' ;;
  esac
}

# $1 check: 0 when the mutated run found a problem the run without mutations did not.
killed_by() {
  local c="$1"
  [ "$(cat "$work/mut/$c.exit")" = 1 ] || return 1
  [ "$(cat "$work/base/$c.exit")" = 1 ] || return 0
  [ -n "$(comm -13 "$work/base/$c.out" "$work/mut/$c.out")" ] || return 1
}

# ---- sites: each prints "<file>\t<line>\t<detail>" after changing the file, or nothing ----

save() { # $1 file, relative to the copy
  mkdir -p "$work/orig/$(dirname "$1")"
  cp -p "$copy/$1" "$work/orig/$1"
  printf '%s' "$1" >"$work/changed"
}

# $1 file, $2 heading, $3 column header: appends "Moved" to the first data row's cell in that
# column of the table under the heading. Prints "<line>\t<old>\t<new>" or nothing.
mutate_cell() {
  local f="$copy/$1"
  awk -F'|' -v heading="$2" -v column="$3" -v OFS='|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    !done && /^#+[ \t]/ { h = $0; sub(/^#+[ \t]+/, "", h); in_section = (trim(h) == heading); col = 0; seen_sep = 0 }
    !done && in_section && /^[ \t]*\|/ {
      line = $0; gsub(/\\\|/, "\037", line); n = split(line, cells, "|")
      if (!col) { for (i = 1; i <= n; i++) if (trim(cells[i]) == column) col = i; if (col) { print; next } }
      else if (!seen_sep) { seen_sep = 1; print; next }
      else {
        old = trim(cells[col]); name = old; gsub(/`/, "", name); name = trim(name)
        if (name != "") {
          new = name "Moved"; cell = cells[col]; j = index(cell, name)
          cells[col] = substr(cell, 1, j - 1) new substr(cell, j + length(name))
          out = cells[1]; for (i = 2; i <= n; i++) out = out "|" cells[i]; gsub("\037", "\\|", out)
          print out; printf "%d\t%s\t%s\n", NR, name, new > "/dev/stderr"; done = 1; next
        }
      }
    }
    { print }' "$f" 2>"$work/site" >"$f.mutated" || true
  [ -s "$work/site" ] || { rm -f "$f.mutated"; return 0; }
  save "$1"
  mv "$f.mutated" "$f"
  cat "$work/site"
}

site_registry_rename() {
  local doc="docs/COMPONENT_REGISTRY.md" r
  [ -f "$copy/$doc" ] || return 0
  r="$(mutate_cell "$doc" Components Name)"
  [ -n "$r" ] && printf '%s\t%s\t%s renamed %s\n' "$doc" "$(cut -f1 <<<"$r")" "$(cut -f2 <<<"$r")" "$(cut -f3 <<<"$r")"
}

site_layout_rename() {
  local doc="docs/LAYOUT_CONTRACT.md" r
  [ -f "$copy/$doc" ] || return 0
  r="$(mutate_cell "$doc" Screens View)"
  [ -n "$r" ] && printf '%s\t%s\t%s renamed %s\n' "$doc" "$(cut -f1 <<<"$r")" "$(cut -f2 <<<"$r")" "$(cut -f3 <<<"$r")"
}

# The docs docs.sh checks (docs.paths), minus records of the past (docs.history).
docs_files() {
  local config="$copy/.claude/swift-harness.json" paths history p
  if jq -e '.docs.paths | type == "array"' "$config" >/dev/null 2>&1; then
    paths="$(jq -r '.docs.paths[]' "$config")"
  else
    paths=$'CLAUDE.md\nAGENTS.md\ndocs'
  fi
  if jq -e '.docs.history | type == "array"' "$config" >/dev/null 2>&1; then
    history="$(jq -r '.docs.history[]' "$config")"
  else
    history=$'docs/adr\ndocs/audit\ndocs/archive\ndocs/HISTORY.md\nCHANGELOG.md'
  fi
  history="$(printf '%s\n' "$history" | sed -e 's#^\./##' -e 's#/$##' | grep -v '^$')"
  while IFS= read -r p; do
    p="${p#./}"; p="${p%/}"
    [ -n "$p" ] || continue
    if [ -f "$copy/$p" ]; then printf '%s\n' "$p"
    elif [ -d "$copy/$p" ]; then (cd "$copy" && find "$p" -name '*.md' -type f | sort)
    fi
  done <<<"$paths" | HIST="$history" awk '
    BEGIN { n = split(ENVIRON["HIST"], h, "\n") }
    { for (i = 1; i <= n; i++) if ($0 == h[i] || index($0, h[i] "/") == 1) next; print }'
}

# First local Markdown link whose target exists (else the first such path in backticks),
# outside fenced code: the target gets "-moved" before its extension.
site_docs_stale_link() {
  local f dir hit line old new
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    dir="$(dirname "$f")"
    hit="$(awk -v root="$copy" -v dir="$dir" '
      function exists(p,   t) { t = p; sub(/#.*/, "", t); if (t == "") return 0
        if (substr(t, 1, 1) == "/") return 0
        return (system("test -e \"" root "/" dir "/" t "\"") == 0) }
      /^[ \t]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      {
        s = $0
        while (match(s, /\]\([^) \t]+\)/)) {
          t = substr(s, RSTART + 2, RLENGTH - 3)
          if (t !~ /^[a-z]+:/ && t !~ /^#/ && exists(t)) { printf "%d\t%s\n", NR, t; exit }
          s = substr(s, RSTART + RLENGTH)
        }
        s = $0
        while (match(s, /`[A-Za-z0-9_.-]+\/[^` ]+\.[A-Za-z0-9]+`/)) {
          t = substr(s, RSTART + 1, RLENGTH - 2)
          if (!tick && system("test -e \"" root "/" t "\"") == 0) tick = NR "\t" t
          s = substr(s, RSTART + RLENGTH)
        }
      }
      END { if (tick != "") print tick }' "$copy/$f" | head -1)"
    [ -n "$hit" ] || continue
    line="$(cut -f1 <<<"$hit")"
    old="$(cut -f2 <<<"$hit")"
    case "$old" in
      *#*) new="${old%%#*}"; new="${new%.*}-moved.${new##*.}#${old#*#}" ;;
      *.*) new="${old%.*}-moved.${old##*.}" ;;
      *) new="$old-moved" ;;
    esac
    save "$f"
    awk -v n="$line" -v old="$old" -v new="$new" '
      NR == n { i = index($0, old); if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) } { print }' \
      "$work/orig/$f" >"$copy/$f"
    printf '%s\t%s\t%s now points to %s\n' "$f" "$line" "$old" "$new"
    return 0
  done <<<"$(docs_files)"
}

site_security_relax() {
  local f key line pb=/usr/libexec/PlistBuddy
  f="$(cd "$copy" && git ls-files -co --exclude-standard -- '*.entitlements' 2>/dev/null | sort | head -1)"
  [ -n "$f" ] && [ -x "$pb" ] || return 0
  # PlistBuddy separates key paths with ":", so the dots in entitlement names are safe.
  for key in com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.allow-jit; do
    [ "$("$pb" -c "Print :$key" "$copy/$f" 2>/dev/null)" = true ] && continue
    save "$f"
    "$pb" -c "Delete :$key" "$copy/$f" >/dev/null 2>&1
    "$pb" -c "Add :$key bool true" "$copy/$f" >/dev/null 2>&1 || { cp -p "$work/orig/$f" "$copy/$f"; return 0; }
    line="$(grep -nF "<key>$key</key>" "$copy/$f" | head -1 | cut -d: -f1)"
    printf '%s\t%s\t%s set to true\n' "$f" "${line:-1}" "$key"
    return 0
  done
}

# The first target T (contract order) whose Package.swift declaration has a dependencies list,
# and the first sibling U it may not depend on, that does not itself list T: adds "U" to T.
site_contracts_forbidden() {
  local contract="$copy/docs/architecture-contracts.json" pkg manifest t u line
  [ -f "$contract" ] || return 0
  while IFS= read -r pkg; do
    manifest="${pkg#./}"; manifest="${manifest%/}"
    if [ -z "$manifest" ] || [ "$manifest" = . ]; then manifest="Package.swift"; else manifest="$manifest/Package.swift"; fi
    [ -f "$copy/$manifest" ] || continue
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      u="$(jq -r --arg p "$pkg" --arg t "$t" '
        .packages[$p] as $g | ($g[$t] // []) as $allowed
        | [$g | keys_unsorted[] as $k
           | select($k != $t and (($allowed | index($k)) | not) and ((($g[$k] // []) | index($t)) | not)) | $k]
        | first // empty' "$contract")"
      [ -n "$u" ] || continue
      # The declaration line of T, then the first "dependencies: [" before the next target.
      line="$(awk -v t="$t" '
        !found && index($0, "name: \"" t "\"") && $0 ~ /\.(target|executableTarget)\(/ { found = 1 }
        found && /\.(target|executableTarget|testTarget|binaryTarget|macro|plugin)\(/ && !index($0, "name: \"" t "\"") { exit }
        found && /dependencies:[ \t]*\[/ { print NR; exit }' "$copy/$manifest")"
      [ -n "$line" ] || continue
      save "$manifest"
      awk -v n="$line" -v u="$u" 'NR == n { sub(/dependencies:[ \t]*\[/, "&\"" u "\", ") } { print }' \
        "$work/orig/$manifest" >"$copy/$manifest"
      printf '%s\t%s\t%s now depends on %s\n' "$manifest" "$line" "$t" "$u"
      return 0
    done <<<"$(jq -r --arg p "$pkg" '.packages[$p] | keys_unsorted[]' "$contract" 2>/dev/null)"
  done <<<"$(jq -r '.packages | keys_unsorted[]' "$contract" 2>/dev/null)"
}

# $1 file list (newline separated), $2 ERE: "<file>\t<line>" of the first line that matches.
first_match() {
  local f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(RE="$2" awk '/^[ \t]*\/\// { next } $0 ~ ENVIRON["RE"] { print NR; exit }' "$copy/$f")"
    [ -n "$n" ] && { printf '%s\t%s\n' "$f" "$n"; return 0; }
  done <<<"$1"
  return 1
}

# $1 file, $2 line, $3 ERE, $4 mode: changes the first match of ERE on that line and prints
# what it became. remove: deleted; literal: last argument becomes 13; plus: last argument
# gets " + 3"; any other text: the match is replaced by it.
edit_match() {
  save "$1"
  # The ERE goes through the environment: awk -v would read its backslashes as escapes.
  RE="$3" awk -v n="$2" -v mode="$4" '
    NR == n && match($0, ENVIRON["RE"]) {
      m = substr($0, RSTART, RLENGTH); pre = substr($0, 1, RSTART - 1); post = substr($0, RSTART + RLENGTH)
      if (mode == "remove") new = ""
      else if (mode == "literal" || mode == "plus") {
        inner = substr(m, 1, length(m) - 1); cut = 0
        for (i = length(inner); i > 0; i--) { c = substr(inner, i, 1); if (c == "," || c == "(") { cut = i; break } }
        arg = substr(inner, cut + 1); sub(/^[ \t]+/, "", arg)
        lead = substr(inner, 1, cut) (substr(inner, cut, 1) == "," ? " " : "")
        new = lead (mode == "literal" ? "13" : arg " + 3") ")"
      } else new = mode
      $0 = pre new post
      if ($0 ~ /^[ \t]*$/) $0 = ""
      print m "\t" new > "/dev/stderr"
    }
    { print }' "$work/orig/$1" 2>"$work/edit" >"$copy/$1"
  cat "$work/edit"
}

TOKEN_PADDING='\.padding\(([.][A-Za-z]+, *)?[A-Za-z_][A-Za-z0-9_.]*\)'
ANY_PADDING='\.padding\(([.][A-Za-z]+, *)?[A-Za-z0-9_][A-Za-z0-9_.]*\)'

site_lint_literal() {
  local files excluded hit e
  files="$(source_files)"
  # Files the padding rule excludes (the design system package) cannot be linted for it.
  excluded="$(awk '/^  ds_hardcoded_padding:/ { r = 1; next } r && /^  [a-z_]+:/ { exit }
    r && /^    excluded:/ { sub(/^    excluded:[ \t]*/, ""); gsub(/^'"'"'|'"'"'$/, ""); print; exit }' "$copy/.swiftlint.yml" 2>/dev/null)"
  case "$excluded" in '' | *'{{'*) ;; *) files="$(grep -vE -- "$excluded" <<<"$files")" ;; esac
  hit="$(first_match "$files" "$TOKEN_PADDING")" || return 0
  e="$(edit_match "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$TOKEN_PADDING" literal)"
  printf '%s\t%s\t%s became %s\n' "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$(cut -f1 <<<"$e")" "$(cut -f2 <<<"$e")"
}

site_keyboard_shortcut() {
  local re='\.keyboardShortcut\([^()]*\)' hit e
  hit="$(first_match "$(sources_by_coverage 'KeyboardCheck\.')" "$re")" || return 0
  e="$(edit_match "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$re" remove)"
  printf '%s\t%s\t%s removed\n' "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$(cut -f1 <<<"$e")"
}

site_a11y_label() {
  local re='\.accessibilityLabel\(([^()]|\([^()]*\))*\)' hit e
  hit="$(first_match "$(sources_by_coverage 'AccessibilityAudit\.|performAccessibilityAudit')" "$re")" || return 0
  e="$(edit_match "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$re" remove)"
  printf '%s\t%s\t%s removed\n' "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$(cut -f1 <<<"$e")"
}

site_snapshot_padding() {
  local names files f hit e
  [ -n "$(tests_using 'Snapshot\.verify')" ] || return 0
  # Only the sources that declare a type the snapshot tests use: a padding elsewhere is not rendered.
  names="$(while IFS= read -r f; do [ -n "$f" ] && grep -oE '[A-Z][A-Za-z0-9_]*\(' "$copy/$f"; done <<<"$(tests_using 'Snapshot\.verify')" |
    tr -d '(' | sort -u | paste -sd'|' -)"
  [ -n "$names" ] || return 0
  files="$(while IFS= read -r f; do
    [ -n "$f" ] && grep -qE "(struct|class|enum)[[:space:]]+($names)([^A-Za-z0-9_]|$)" "$copy/$f" && printf '%s\n' "$f"
  done <<<"$(source_files)")"
  hit="$(first_match "$files" "$ANY_PADDING")" || return 0
  e="$(edit_match "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$ANY_PADDING" plus)"
  printf '%s\t%s\t%s became %s\n' "$(cut -f1 <<<"$hit")" "$(cut -f2 <<<"$hit")" "$(cut -f1 <<<"$e")" "$(cut -f2 <<<"$e")"
}

# The first Screens row with a View, a File and a Min width: its body is wrapped in a frame
# 200 pt wider than Min, on the same line so line numbers do not move.
site_layout_wide() {
  local doc="$copy/docs/LAYOUT_CONTRACT.md" row view file min line wide re
  [ -f "$doc" ] || return 0
  row="$(awk -F'|' '
    function trim(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
    /^#+[ \t]/ { h = $0; sub(/^#+[ \t]+/, "", h); sec = (trim(h) == "Screens"); v = f = m = 0; sep = 0; next }
    sec && /^[ \t]*\|/ {
      line = $0; gsub(/\\\|/, "\037", line); n = split(line, c, "|")
      if (!v) { for (i = 1; i <= n; i++) { t = trim(c[i]); if (t == "View") v = i; if (t == "File") f = i; if (t == "Min") m = i }; next }
      if (!sep) { sep = 1; next }
      view = trim(c[v]); file = trim(c[f]); sub(/,.*/, "", file); sub(/:[0-9]+$/, "", file); file = trim(file)
      min = trim(c[m]); if (match(min, /^[0-9]+/) && view != "" && file != "") { print view "\t" file "\t" substr(min, 1, RLENGTH); exit }
    }' "$doc")"
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r view file min <<<"$row"
  [ -f "$copy/$file" ] || return 0
  line="$(awk -v t="$view" '
    !found && match($0, "(struct|class)[ \t]+" t "([^A-Za-z0-9_]|$)") { found = 1 }
    found && /var body: some View \{/ { print NR; exit }' "$copy/$file")"
  [ -n "$line" ] || return 0
  wide=$((min + 200))
  re='var body: some View \{'
  edit_match "$file" "$line" "$re" "var body: some View { mutantBody.frame(minWidth: $wide) }; @ViewBuilder var mutantBody: some View {" >/dev/null
  printf '%s\t%s\t%s wrapped in .frame(minWidth: %s), Min width %s\n' "$file" "$line" "$view" "$wide" "$min"
}

# ---- run ----

# The security check compares with an approved state: approve the copy as it is.
CLAUDE_PLUGIN_DATA="$work/data" "$here/security.sh" --record --project "$copy" </dev/null >/dev/null 2>&1

for c in $CHECKS; do run_check "$c" "$work/base"; done
base_summary=""
for c in $CHECKS; do
  case "$(cat "$work/base/$c.exit")" in
    0) s=pass ;;
    1) s="fails already ($(grep -c . "$work/base/$c.out") line(s))" ;;
    *) s="cannot check (exit $(cat "$work/base/$c.exit"))" ;;
  esac
  base_summary="$base_summary${base_summary:+, }$c $s"
done
verify_ready=false
if [ "$verify" = true ]; then
  if [ -f "$copy/scripts/verify.sh" ]; then
    run_verify "$work/base"
    case "$(cat "$work/base/verify.exit")" in
      0) base_summary="$base_summary, verify pass"; verify_ready=true ;;
      1) base_summary="$base_summary, verify fails already"; verify_ready=true ;;
      *) base_summary="$base_summary, verify cannot run (exit $(cat "$work/base/verify.exit"): $(grep -m1 -E 'NOT CONFIGURED|unknown|not found' "$work/verify.raw" | cut -c1-120))" ;;
    esac
  else
    base_summary="$base_summary, verify not run (no scripts/verify.sh)"
  fi
fi

printf 'Check sensitivity: %s\n' "$project"
printf 'Without mutations: %s\n\n' "$base_summary"
printf '| Operator | Site | Target | Result | Failed checks |\n|---|---|---|---|---|\n'

killed=0 survived=0 nosite=0 notrun=0 nocheck=0
while IFS=$'\t' read -r op target _; do
  [ -z "$only" ] || [[ " $only " == *" $op "* ]] || continue
  is_verify=false
  [[ " $VCHECKS " == *" $target "* ]] && is_verify=true
  if [ "$is_verify" = true ] && [ "$verify_ready" != true ]; then
    if [ "$verify" = true ]; then why="verify cannot run"; else why="needs --verify"; fi
    printf '| %s | - | %s | not run (%s) | - |\n' "$op" "$target" "$why"
    notrun=$((notrun + 1))
    continue
  fi
  if [ "$is_verify" = true ] && why="$(no_check "$target")" && [ -n "$why" ]; then
    printf '| %s | - | %s | no check (%s) | - |\n' "$op" "$target" "$why"
    nocheck=$((nocheck + 1))
    continue
  fi
  rm -f "$work/changed"
  site="$("site_${op//-/_}")"
  if [ -z "$site" ]; then
    printf '| %s | - | %s | no site | - |\n' "$op" "$target"
    nosite=$((nosite + 1))
    continue
  fi
  rm -f "$work/mut/"*
  for c in $CHECKS; do run_check "$c" "$work/mut"; done
  failed=""
  for c in $CHECKS; do killed_by "$c" && failed="$failed${failed:+, }$c"; done
  if [ "$is_verify" = true ]; then
    run_verify "$work/mut"
    verify_new >"$work/new"
    cp "$work/verify.raw" "$work/verify-$op.log"
    cp "$work/new" "$work/new-$op"
    if [ -s "$work/new" ]; then
      credited=""
      for c in $VCHECKS; do
        re="$(credit_regex "$c")"
        [ -n "$re" ] || continue
        # Lint is credited only for the mutated file.
        if [ "$c" = lint ]; then
          grep -F -- "$(sed 's/[0-9][0-9]*/#/g' "$work/changed")" "$work/new" | grep -qE -- "$re" || continue
        else
          grep -qE -- "$re" "$work/new" || continue
        fi
        credited="$credited${credited:+, }$c"
      done
      failed="$failed${failed:+, }${credited:-verify}"
    fi
  fi
  if [[ ", $failed, " == *", $target, "* ]]; then
    result=killed; killed=$((killed + 1))
  else
    result=SURVIVED; survived=$((survived + 1))
  fi
  IFS=$'\t' read -r file line detail <<<"$site"
  printf '| %s | %s:%s (%s) | %s | %s | %s |\n' "$op" "$file" "$line" "$detail" "$target" "$result" "${failed:--}"
  f="$(cat "$work/changed")"
  cp -p "$work/orig/$f" "$copy/$f"
done <<<"$OPERATORS"

printf '\n%s killed, %s survived, %s with no site%s%s.\n' "$killed" "$survived" "$nosite" \
  "$([ "$nocheck" -eq 0 ] || printf ', %s with no check' "$nocheck")" "$([ "$notrun" -eq 0 ] || printf ', %s not run' "$notrun")"
[ "$survived" -eq 0 ] || printf 'A survived mutation is a finding: explain it (a bug in the check, or out of its scope by design).\n'
exit 0
