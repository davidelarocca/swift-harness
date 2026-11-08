#!/bin/bash
# Adoption audit (#104), v0: what a project already has, read as text. Run by the user through
# /swift-harness:setup audit, never by a hook.
#
#   audit.sh [--project DIR] [--json]
#
# It writes nothing and runs nothing from the project: no project command, script or test, no
# `swift package dump-package` (it runs Package.swift), and not even git (a repository's config
# can make git run programs). Files are listed with find and read with grep, sed and awk;
# output goes to stdout only. Files that may hold secrets (.env files, *Secret*, *credential*,
# keys and certificates) are never opened: they are listed by path as skipped.
#
# For each capability (build, unit tests, UI tests, docs checks, lint, formatter, security
# settings, UI test isolation, agent rules, CI, platforms) it gives each source with a level:
#   declared    a document says so (README, CLAUDE.md, AGENTS.md, docs/)
#   configured  a file defines it (a CI step, a script, a test target, a config file)
#   executed    a record says it ran: the harness's own end-of-turn record, if there is one
#   observed    the audit saw the property itself in the files (an entitlement value, the
#               launch arguments a UI test sets)
#   unknown     it could not tell, with the reason (unreadable file, over the limits)
# Timing the candidate commands means running them: it is a separate step that needs the
# user's approval, so every cost here is "not measured".
#
# Limits (environment, for tests): SWIFT_HARNESS_AUDIT_MAX_FILES (files listed, 20000),
# SWIFT_HARNESS_AUDIT_MAX_BYTES (bytes read per file, 1000000), SWIFT_HARNESS_AUDIT_TIME
# (seconds, 20). Past a limit the result says "incomplete", with the numbers.
#
# Exit 0: printed. Exit 2: usage, or the folder does not exist.

set -uo pipefail
export LC_ALL=C

usage() {
  echo "usage: audit.sh [--project DIR] [--json]" >&2
  exit 2
}
dir="."
json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --json) json=true; shift ;;
    *) usage ;;
  esac
done
root="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "audit: no such folder: $dir" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "audit: jq is required (brew install jq)." >&2; exit 2; }

max_files="${SWIFT_HARNESS_AUDIT_MAX_FILES:-20000}"
max_bytes="${SWIFT_HARNESS_AUDIT_MAX_BYTES:-1000000}"
max_time="${SWIFT_HARNESS_AUDIT_TIME:-20}"
SECONDS=0
incomplete=""

rows=""     # capability \t level \t source \t detail
skipped=""  # path \t reason
files_read=0
row() { rows="$rows$1	$2	$3	$4"$'\n'; }
skip() { skipped="$skipped$1	$2"$'\n'; }
over_time() {
  if [ "$SECONDS" -gt "$max_time" ]; then
    [ -n "$incomplete" ] || incomplete="stopped after ${max_time} s"
    return 0
  fi
  return 1
}

# ---- the files, without git ----

all="$(cd "$root" && find . \( -name .git -o -name .build -o -name DerivedData -o -name node_modules -o -name Pods \
  -o -name Carthage -o -name .swiftpm -o -name '*.xcresult' \) -prune -o -type f -print 2>/dev/null | sed 's#^\./##' | sort)"
total="$(printf '%s\n' "$all" | grep -c .)"
if [ "$total" -gt "$max_files" ]; then
  incomplete="listed the first $max_files of $total files"
  all="$(printf '%s\n' "$all" | head -n "$max_files")"
fi

is_secret() {
  case "${1##*/}" in
    .env | .env.* | *.env | *[Ss]ecret* | *[Cc]redential* | *.p12 | *.p8 | *.pem | *.key | *.cer | *.mobileprovision | *.keychain*) return 0 ;;
  esac
  return 1
}

# The text of a file, or nothing (with the reason recorded) when it must not or cannot be read.
readable() { # $1 relative path
  local f="$root/$1" size
  if is_secret "$1"; then skip "$1" "may hold secrets: not opened"; return 1; fi
  [ -f "$f" ] && [ ! -L "$f" ] || { skip "$1" "not a regular file"; return 1; }
  size="$(wc -c <"$f" | tr -d ' ')"
  if [ "$size" -gt "$max_bytes" ]; then skip "$1" "$size bytes, over the $max_bytes read limit"; return 1; fi
  if [ "$size" -gt 0 ] && ! grep -Iq . "$f" 2>/dev/null; then skip "$1" "binary"; return 1; fi
  files_read=$((files_read + 1))
  return 0
}

# Secret-looking files are listed even when no probe would read them.
while IFS= read -r f; do
  [ -n "$f" ] && is_secret "$f" && skip "$f" "may hold secrets: not opened"
done <<<"$all"

pick() { printf '%s\n' "$all" | grep -E "$1" | grep -v '^$'; } # $1 ERE on the path

rules_files="$(pick '^(CLAUDE\.md|\.claude/CLAUDE\.md|CLAUDE\.local\.md|AGENTS\.md|\.claude/rules/.*\.md|\.cursorrules|\.cursor/rules/.*|\.github/copilot-instructions\.md)$')"
# Records of the past (docs.history, as for the docs check) name old commands: left out.
history="$(jq -r '.docs.history[]? | strings' "$root/.claude/swift-harness.json" 2>/dev/null)"
[ -n "$history" ] || history=$'docs/adr\ndocs/audit\ndocs/archive\ndocs/HISTORY.md\nCHANGELOG.md'
docs_files="$(pick '^(README[^/]*\.md|docs/.*\.md)$' | A_HIST="$history" awk '
  BEGIN { n = split(ENVIRON["A_HIST"], h, "\n") }
  { for (i = 1; i <= n; i++) { p = h[i]; sub(/\/$/, "", p); if (p != "" && ($0 == p || index($0, p "/") == 1)) next } print }' | head -n 200)"
script_files="$(pick '^([Ss]cripts/[^/]+|[^/]+\.sh|Makefile|Taskfile\.ya?ml|fastlane/Fastfile|ci_scripts/[^/]+)$' | grep -vE '\.(md|txt|json|png|jpe?g)$')"
ci_files="$(pick '^(\.github/workflows/[^/]+\.ya?ml|\.gitlab-ci\.yml|bitrise\.yml|\.circleci/config\.yml|Jenkinsfile|\.buildkite/[^/]+\.ya?ml)$')"
manifests="$(pick '(^|/)Package\.swift$' | awk -F/ 'NF <= 4')"
pbxprojs="$(pick '\.xcodeproj/project\.pbxproj$')"
schemes="$(pick '\.xcscheme$')"
entitlements="$(pick '\.entitlements$')"
swift_tests="$(pick '(^|/)[^/]*Tests?/.*\.swift$|Tests?\.swift$' | head -n 3000)"

# ---- probes, each reading text only ----

# Command lines in rules, docs, scripts and CI: "<capability> <level> <file:line> <command>".
scan_commands() { # $1 files, $2 level
  local f n line cmd
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    over_time && return 0
    readable "$f" || continue
    while IFS=: read -r n line; do
      [ -n "$n" ] || continue
      cmd="$(printf '%s' "$line" | grep -oE 'swift (build|test)[^;&|`"]*|xcodebuild[^;&|`"]*|swiftlint[^;&|`"]*|swiftformat[^;&|`"]*|swift-format[^;&|`"]*' | head -1 | cut -c1-90)"
      # In documents, variants of one command are one finding: keep the words up to the first
      # option and its name (swift test --filter X and --filter Y are "swift test --filter").
      [ "$2" != declared ] || cmd="$(printf '%s' "$cmd" | awk '{ out = $1; for (i = 2; i <= NF; i++) { if ($i ~ /^-/) { out = out " " $i; break } if ($i !~ /^[a-z-]+$/) break; out = out " " $i } print out }')"
      [ -n "$cmd" ] || continue
      case "$cmd" in
        "swift build"* | xcodebuild*build*) row build "$2" "$f:$n" "$cmd" ;;
      esac
      case "$cmd" in
        "swift test"* | xcodebuild*test*) row tests "$2" "$f:$n" "$cmd" ;;
        swiftlint*) row lint "$2" "$f:$n" "$cmd" ;;
        swiftformat* | swift-format*) row formatter "$2" "$f:$n" "$cmd" ;;
      esac
    done <<<"$(grep -nE 'swift (build|test)|xcodebuild|swiftlint|swiftformat|swift-format' "$root/$f" 2>/dev/null | grep -v 'mcp__' | head -n 50)"
    # Agent tools (XcodeBuildMCP) named in rules: build and test through a tool, not a shell command.
    while IFS=: read -r n line; do
      [ -n "$n" ] || continue
      cmd="$(printf '%s' "$line" | grep -oE 'mcp__[A-Za-z0-9]+__[A-Za-z0-9_-]+' | head -1)"
      case "$cmd" in
        *__build*) row build "$2" "$f:$n" "$cmd (an agent tool, not a shell command)" ;;
        *__test*) row tests "$2" "$f:$n" "$cmd (an agent tool, not a shell command)" ;;
      esac
    done <<<"$(grep -nE 'mcp__[A-Za-z0-9]+__(build|test)' "$root/$f" 2>/dev/null | head -n 20)"
    # A docs checker is named, not inferred: a script whose name says docs or links.
    [ "${SCAN_DOCS:-true}" = true ] || continue
    while IFS=: read -r n line; do
      [ -n "$n" ] || continue
      cmd="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]*(check-?docs|docs?-?check|lint-?docs|check-?links)[A-Za-z0-9_.-]*' | head -1)"
      [ -n "$cmd" ] && row "docs check" "$2" "$f:$n" "$cmd"
    done <<<"$(grep -nE 'check-?docs|docs?-?check|lint-?docs|check-?links' "$root/$f" 2>/dev/null | head -n 20)"
  done <<<"$1"
}

scan_commands "$rules_files" declared
scan_commands "$docs_files" declared
# In scripts, only the build, test and lint commands they run; a docs check is found by name.
SCAN_DOCS=false scan_commands "$script_files" configured
scan_commands "$ci_files" configured

# Scripts that exist: available, never run (V-09). One named like a docs check is one.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  printf '%s' "${f##*/}" | grep -qE 'check-?docs|docs?-?check|lint-?docs|check-?links' && row "docs check" configured "$f" "a script named like a docs check"
  if [ -x "$root/$f" ]; then row scripts configured "$f" "executable, not run by the audit"
  else row scripts configured "$f" "not executable, not run by the audit"; fi
done <<<"$script_files"

# Agent rules: the project's own, to be kept as they are.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  readable "$f" || continue
  row "agent rules" configured "$f" "$(grep -c '' "$root/$f" | tr -d ' ') lines; kept as they are"
done <<<"$rules_files"

# Config files, and whether anything runs them.
cfg_row() { # $1 capability, $2 file, $3 ERE of what runs it
  [ -f "$root/$2" ] || return 0
  if printf '%s' "$rows" | grep -q "^$1	configured	"; then row "$1" configured "$2" "config present; run by the steps listed"
  elif [ -n "$pbxprojs" ] && while IFS= read -r p; do [ -n "$p" ] && grep -qE "$3" "$root/$p" 2>/dev/null && exit 0; done <<<"$pbxprojs"; then
    row "$1" configured "$2" "config present; run by an Xcode build phase"
  else row "$1" configured "$2" "config present; nothing found that runs it"; fi
}
cfg_row lint .swiftlint.yml 'swiftlint'
# What a declarative config covers, read as text (#105, H1): a check that passes may not
# look at a class at all. Rules turned off, turned on beyond the defaults, or an only-list.
yaml_list() { # $1 file, $2 key: the "  - item" lines under "key:" at the top level
  awk -v k="$2" '$0 ~ "^" k ":" { f = 1; next } f && /^[[:space:]]+- / { sub(/^[[:space:]]+- /, ""); sub(/[[:space:]]+#.*$/, ""); print; next } f && /^[^[:space:]#]/ { exit }' "$1"
}
names() { paste -sd, - | sed 's/,/, /g' | cut -c1-160; }
if [ -f "$root/.swiftlint.yml" ] && readable .swiftlint.yml; then
  off="$(yaml_list "$root/.swiftlint.yml" disabled_rules)"; on="$(yaml_list "$root/.swiftlint.yml" opt_in_rules)"; only="$(yaml_list "$root/.swiftlint.yml" only_rules)"
  if [ -n "$only" ]; then row lint observed .swiftlint.yml "only these rules run ($(printf '%s\n' "$only" | grep -c .)): $(printf '%s\n' "$only" | names)"
  else
    [ -z "$off" ] || row lint observed .swiftlint.yml "rules turned off ($(printf '%s\n' "$off" | grep -c .)), so a passing lint does not look at them: $(printf '%s\n' "$off" | names)"
    [ -z "$on" ] || row lint observed .swiftlint.yml "opt-in rules turned on ($(printf '%s\n' "$on" | grep -c .)): $(printf '%s\n' "$on" | names)"
    [ -n "$off$on" ] || row lint observed .swiftlint.yml "the default rules, none turned off"
  fi
fi
if [ -f "$root/.swiftformat" ] && readable .swiftformat; then
  off="$(grep -oE -- '--disable[[:space:]]+[^#]*' "$root/.swiftformat" | sed -E 's/--disable[[:space:]]+//' | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$')"
  only="$(grep -oE -- '--rules[[:space:]]+[^#]*' "$root/.swiftformat" | sed -E 's/--rules[[:space:]]+//' | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$')"
  if [ -n "$only" ]; then row formatter observed .swiftformat "only these rules run: $(printf '%s\n' "$only" | names)"
  elif [ -n "$off" ]; then row formatter observed .swiftformat "rules turned off ($(printf '%s\n' "$off" | grep -c .)): $(printf '%s\n' "$off" | names)"; fi
fi
if [ -f "$root/.swift-format" ] && readable .swift-format; then
  if off="$(jq -r '.rules // {} | to_entries[] | select(.value == false) | .key' "$root/.swift-format" 2>/dev/null)"; then
    [ -z "$off" ] || row formatter observed .swift-format "rules turned off ($(printf '%s\n' "$off" | grep -c .)): $(printf '%s\n' "$off" | names)"
  else
    row formatter unknown .swift-format "not readable as JSON"
  fi
fi
cfg_row formatter .swiftformat 'swiftformat'
cfg_row formatter .swift-format 'swift-format'

# SwiftPM manifests, as text: test targets and platforms (V-15: unreadable is unknown).
pkgs=0 pkg_paths="" pkg_tests="" pkg_platforms="" tested_pkgs=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  over_time && break
  readable "$f" || { row build unknown "$f" "could not read the manifest"; continue; }
  flat="$(tr '\n' ' ' <"$root/$f")"
  if ! printf '%s' "$flat" | grep -q 'Package('; then row build unknown "$f" "no Package(...) found: not read as a manifest"; continue; fi
  pkgs=$((pkgs + 1)); pkg_paths="$pkg_paths${pkg_paths:+, }${f%/Package.swift}"
  [ "$f" != Package.swift ] || pkg_paths="${pkg_paths%Package.swift}."
  t="$(printf '%s' "$flat" | grep -oE '\.testTarget\([[:space:]]*name:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' | paste -sd, - | sed 's/,/, /g')"
  if [ -n "$t" ]; then pkg_tests="$pkg_tests${pkg_tests:+, }$t"; tested_pkgs="$tested_pkgs ${f%Package.swift}"; fi
  p="$(printf '%s' "$flat" | grep -oE '\.(macOS|iOS|visionOS|watchOS|tvOS|macCatalyst)\(' | tr -d '.(' | sort -u)"
  pkg_platforms="$(printf '%s\n%s\n' "$pkg_platforms" "$p" | grep -v '^$' | sort -u)"
done <<<"$manifests"
if [ "$pkgs" -gt 0 ]; then
  src="$(printf '%s\n' "$manifests" | head -1)"; [ "$pkgs" -eq 1 ] || src="$pkgs Package.swift files"
  row build configured "$src" "SwiftPM: $pkg_paths"
  [ -z "$pkg_tests" ] || row tests configured "$src" "test targets: $(printf '%s' "$pkg_tests" | cut -c1-200)"
  [ -z "$pkg_platforms" ] || row platforms configured "$src" "$(printf '%s\n' "$pkg_platforms" | paste -sd, - | sed 's/,/, /g')"
fi

# Xcode projects, as text.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  readable "$f" || { row build unknown "$f" "could not read the Xcode project"; continue; }
  if ! grep -q 'objects = {' "$root/$f"; then row build unknown "$f" "not a readable Xcode project file (no objects list)"; continue; fi
  row build configured "$f" "Xcode project"
  p="$(grep -oE '(SUPPORTED_PLATFORMS|SDKROOT) = "?[a-z ]+' "$root/$f" | sed -E 's/.*= "?//' | tr ' ' '\n' | grep -v '^$' |
    sed -e 's/^macosx$/macOS/' -e 's/^iphoneos$/iOS/' -e 's/^iphonesimulator$/iOS/' -e 's/^xros$/visionOS/' -e 's/^xrsimulator$/visionOS/' \
      -e 's/^appletvos$/tvOS/' -e 's/^appletvsimulator$/tvOS/' -e 's/^watchos$/watchOS/' -e 's/^watchsimulator$/watchOS/' | grep -vE '^(auto)$' | sort -u | paste -sd, - | sed 's/,/, /g')"
  [ -z "$p" ] || row platforms configured "$f" "$p"
done <<<"$pbxprojs"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  s="${f##*/}"
  row build configured "$f" "shared scheme ${s%.xcscheme}"
done <<<"$schemes"

# CI files: present, and a structural check (V-15). No YAML parser is run: brackets and quotes
# that do not close, and tabs in the indentation, make a file unreadable as YAML.
yaml_problem() { # $1 file: prints the first problem, or nothing. END runs after exit too.
  awk '
    /^[ ]*\t/ { print "a tab in the indentation (line " NR ")"; told = 1; exit }
    { line = $0; sub(/[ \t]#.*$/, "", line)
      q = gsub(/"/, "\"", line); if (q % 2) { print "a quote that does not close (line " NR ")"; told = 1; exit }
      o = gsub(/\[/, "[", line); c = gsub(/\]/, "]", line); b += o - c
      o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); b += o - c
      if (b < 0) { print "a bracket closed before it opens (line " NR ")"; told = 1; exit } }
    END { if (!told && b > 0 && NR) print "brackets that do not close" }' "$1"
}
while IFS= read -r f; do
  [ -n "$f" ] || continue
  readable "$f" || { row ci unknown "$f" "could not read it"; continue; }
  case "$f" in
    *.yml | *.yaml)
      problem="$(yaml_problem "$root/$f" | head -1)"
      if [ -n "$problem" ]; then row ci unknown "$f" "cannot be read as YAML: $problem"
      else row ci configured "$f" "workflow (structure checked, not parsed)"; fi
      ;;
    *) row ci configured "$f" "pipeline" ;;
  esac
done <<<"$ci_files"

# Platforms a document claims (V-01): declared only, never more.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  readable "$f" || continue
  p="$(grep -oE '\b(macOS|iOS|iPadOS|visionOS|watchOS|tvOS)\b' "$root/$f" | sort -u | paste -sd, - | sed 's/,/, /g')"
  [ -z "$p" ] || row platforms declared "$f" "$p mentioned"
done <<<"$(printf '%s\n' "$rules_files" | grep -E '^(CLAUDE|AGENTS)'; pick '^README[^/]*\.md$')"

# Security settings: the entitlement values themselves (observed).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  readable "$f" || { row security unknown "$f" "could not read it"; continue; }
  sandbox="$(awk '/<key>com.apple.security.app-sandbox<\/key>/ { getline; if ($0 ~ /<true\/>/) print "on"; else if ($0 ~ /<false\/>/) print "off"; exit }' "$root/$f")"
  n="$(grep -c '<key>' "$root/$f" | tr -d ' ')"
  row security observed "$f" "$n entitlement(s); app sandbox ${sandbox:-not set}"
done <<<"$entitlements"

# UI tests: what the test files show (V-07). Which screens they reach cannot be known without
# running them.
ui="$(while IFS= read -r f; do [ -n "$f" ] && grep -l 'XCUIApplication' "$root/$f" 2>/dev/null | sed "s#^$root/##"; done <<<"$swift_tests")"
nui="$(printf '%s\n' "$ui" | grep -c .)"
if [ "$nui" -gt 0 ]; then
  files_read=$((files_read + nui))
  launch="$(while IFS= read -r f; do grep -lE '\.launch\(\)' "$root/$f" 2>/dev/null; done <<<"$ui" | grep -c .)"
  args="$(while IFS= read -r f; do grep -lE 'launchArguments|launchEnvironment' "$root/$f" 2>/dev/null; done <<<"$ui" | grep -c .)"
  row "ui tests" configured "$(printf '%s\n' "$ui" | head -1 | sed 's#/[^/]*$#/#')" "$nui file(s) use XCUIApplication; $launch launch the app"
  row "ui test isolation" observed "$(printf '%s\n' "$ui" | head -1 | sed 's#/[^/]*$#/#')" "$args of $nui UI test file(s) set launch arguments or environment, $launch launch the app themselves (the others through helpers, or not at all); whether that keeps the app off real data is not known from the text"
  audit_files="$(while IFS= read -r f; do grep -lE 'performAccessibilityAudit|AccessibilityAudit\.' "$root/$f" 2>/dev/null | sed "s#^$root/##"; done <<<"$ui")"
  if [ -n "$audit_files" ]; then
    helpers="$(while IFS= read -r f; do grep -oE 'func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$root/$f" | awk '{ print $2 }' | grep -v '^test'; done <<<"$audit_files" | sort -u | paste -sd'|' -)"
    callers=0
    [ -z "$helpers" ] || callers="$(while IFS= read -r f; do grep -qxF -- "$f" <<<"$audit_files" && continue; grep -lE "(^|[^A-Za-z0-9_])($helpers)\\(" "$root/$f" 2>/dev/null; done <<<"$ui" | grep -c .)"
    row accessibility observed "$(printf '%s\n' "$audit_files" | head -1)" "an accessibility audit in $(printf '%s\n' "$audit_files" | grep -c .) file(s), called from $callers other UI test file(s)"
  fi
  row accessibility unknown "$(printf '%s\n' "$ui" | head -1 | sed 's#/[^/]*$#/#')" "which screens the UI tests open is not known without running them"
fi
# Tests gated by environment variables (#108): they run only when the variable is set, such
# as hardware or network tests. The fast command should not set them.
gated="$(while IFS= read -r f; do [ -n "$f" ] && grep -lE 'environment\[\"[A-Z][A-Z0-9_]+\"\]' "$root/$f" 2>/dev/null; done <<<"$swift_tests")"
if [ -n "$gated" ]; then
  vars="$(printf '%s\n' "$gated" | while IFS= read -r f; do grep -oE 'environment\[\"[A-Z][A-Z0-9_]+\"\]' "$f"; done | sed -E 's/.*\["([A-Z0-9_]+)"\]/\1/' | sort -u | head -8 | paste -sd, - | sed 's/,/, /g')"
  row tests observed "$(printf '%s\n' "$gated" | head -1 | sed "s#^$root/##")" "$(printf '%s\n' "$gated" | grep -c .) test file(s) read environment variables ($vars): tests gated by them run only when set; keep them out of the fast command"
fi
nunit="$(printf '%s\n' "$swift_tests" | grep -c .)"
[ "$nunit" -le "$nui" ] || row tests configured "test files" "$((nunit - nui)) Swift test file(s) besides the UI tests"

# The harness itself: its config, and its own record of what ran (executed).
if [ -f "$root/.claude/swift-harness.json" ]; then
  mode="full setup"
  jq -e '.guest == true' "$root/.claude/swift-harness.json" >/dev/null 2>&1 && mode="guest mode"
  row swift-harness configured .claude/swift-harness.json "$mode"
fi
ev=""
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  ev="$CLAUDE_PLUGIN_DATA/state/$(printf '%s' "$root" | shasum | cut -c1-16)/evidence.json"
  [ -f "$ev" ] || ev=""
fi
if [ -n "$ev" ]; then
  while IFS=$'\t' read -r name result detail time; do
    [ -n "$name" ] || continue
    if [ "$result" = passed ] || [ "$result" = partial ] || [ "$result" = failed ]; then
      row executed executed "end-of-turn record" "$name: $result at $time${detail:+ ($detail)}"
    fi
  done <<<"$(jq -r '.time as $t | .checks[]? | [.name, .result, (.detail // ""), $t] | @tsv' "$ev" 2>/dev/null)"
else
  row executed unknown "-" "no end-of-turn record of the harness for this folder: nothing is known to have run"
fi

[ "$SECONDS" -le "$max_time" ] || [ -n "$incomplete" ] || incomplete="stopped after ${max_time} s"

# ---- proposal: the project's own commands, cost not measured ----

# A shell command, preferring the project's own rules, then its scripts, then its CI.
first_cmd() { # $1 capability
  local src
  for src in rules scripts ci; do
    # Lists go through the environment: awk -v cannot hold a newline.
    printf '%s' "$rows" | A_RULES="$rules_files" A_SCRIPTS="$script_files" A_CI="$ci_files" awk -F'\t' -v c="$1" -v src="$src" '
      BEGIN { split(ENVIRON["A_RULES"], r, "\n"); for (i in r) R[r[i]] = 1; split(ENVIRON["A_SCRIPTS"], s, "\n"); for (i in s) S[s[i]] = 1
              split(ENVIRON["A_CI"], k, "\n"); for (i in k) K[k[i]] = 1 }
      $1 == c && $4 ~ /^(swift (build|test)|xcodebuild)/ {
        f = $3; sub(/:[0-9]+$/, "", f)
        if ((src == "rules" && (f in R)) || (src == "scripts" && (f in S)) || (src == "ci" && (f in K))) print $4
      }'
  done | while IFS= read -r cmd; do
    # A command for another package (a tool the CI builds) is not the project's build.
    pp="$(printf '%s' "$cmd" | sed -nE 's/.*--package-path[ =]+([^ ]+).*/\1/p' | sed 's#^\./##; s#/$##')"
    if [ -n "$pp" ] && [[ ", $pkg_paths, " != *", $pp, "* ]]; then continue; fi
    printf '%s\n' "$cmd"
    break
  done | grep .
}
fast="$(first_cmd build)" && fast_src="the project's own" || fast_src=""
full="$(first_cmd tests)" && full_src="the project's own" || full_src=""
xproj="$(printf '%s\n' "$pbxprojs" | head -1 | sed 's#/project.pbxproj$##')"
# The app's scheme: the one named like the project, else the first that is not an extension.
names="$(printf '%s\n' "$schemes" | sed -E 's#.*/##; s#\.xcscheme$##' | grep -v '^$')"
pname="${xproj##*/}"; pname="${pname%.xcodeproj}"
scheme="$(printf '%s\n' "$names" | grep -xF -- "$pname" | head -1)"
[ -n "$scheme" ] || scheme="$(printf '%s\n' "$names" | grep -viE 'extension|widget|tests?$' | head -1)"
[ -n "$scheme" ] || scheme="$(printf '%s\n' "$names" | head -1)"
if [ -z "$fast" ]; then
  if [ "$pkgs" -gt 0 ] && [ -z "$xproj" ]; then fast="swift build"; fast_src="inferred from Package.swift"
  elif [ -n "$scheme" ]; then fast="xcodebuild -project $xproj -scheme $scheme build"; fast_src="inferred from the shared scheme"; fi
fi
if [ -z "$full" ]; then
  if [ -n "$tested_pkgs" ] && [ "$pkgs" -eq 1 ]; then full="swift test"; full_src="inferred from Package.swift"
  elif [ -n "$tested_pkgs" ]; then full="swift test --package-path <each of:$(printf '%s' "$tested_pkgs" | sed 's#/ # #g; s#/$##')>"; full_src="inferred from the test targets"
  elif [ -n "$scheme" ]; then full="xcodebuild -project $xproj -scheme $scheme test"; full_src="inferred from the shared scheme"; fi
fi
mcp=false
printf '%s' "$rows" | grep -q 'an agent tool, not a shell command' && mcp=true
own_docs=false
printf '%s' "$rows" | grep -q '^docs check	configured	' && own_docs=true

if [ "$json" = true ]; then
  jq -n --arg project "$root" --rawfile rows <(printf '%s' "$rows") --rawfile skipped <(printf '%s' "$skipped") \
    --arg incomplete "$incomplete" --argjson read "$files_read" --argjson total "$total" --argjson seconds "$SECONDS" \
    --arg fast "$fast" --arg full "$full" --arg fast_src "$fast_src" --arg full_src "$full_src" --argjson own_docs "$own_docs" '
    def tsv($t; $keys): $t | split("\n") | map(select(length > 0) | split("\t") | [$keys, .] | transpose | map({(.[0]): .[1]}) | add);
    {project: $project, writes: 0, project_code_run: 0, files_listed: $total, files_read: $read, seconds: $seconds,
     incomplete: (if $incomplete == "" then null else $incomplete end),
     capabilities: tsv($rows; ["capability", "level", "source", "detail"]),
     skipped: tsv($skipped; ["path", "reason"]),
     proposal: {fast: (if $fast == "" then null else $fast end), fast_source: $fast_src,
                full: (if $full == "" then null else $full end), full_source: $full_src,
                no_docs: $own_docs, cost: "not measured"}}'
  exit 0
fi

printf 'Adoption audit of %s: read only, nothing written, no project code run.\n' "$root"
printf '%s files listed, %s file reads, %s s%s.\n\n' "$total" "$files_read" "$SECONDS" "${incomplete:+; INCOMPLETE: $incomplete}"
printf '| Capability | Level | Source | Detail |\n|---|---|---|---|\n'
# Identical findings in several places are one row: the first place, and how many.
printf '%s' "$rows" | sort -t$'\t' -k1,1 -s | awk -F'\t' '
  { k = $1 FS $2 FS $4; if ($1 == "scripts") k = k FS $3   # each script by name
    if (!(k in n)) { order[++m] = k; src[k] = $3 } n[k]++ }
  END { for (i = 1; i <= m; i++) { k = order[i]; split(k, p, FS)
    printf "| %s | %s | %s%s | %s |\n", p[1], p[2], src[k], (n[k] > 1 ? " and " (n[k] - 1) " more" : ""), p[3] } }'
if [ -n "$skipped" ]; then
  printf '\nNot read:\n'
  printf '%s' "$skipped" | sort -u | awk -F'\t' '{ printf "- %s: %s\n", $1, $2 }'
fi
printf '\nProposed guest setup (not applied):\n'
printf -- '- fast: %s%s\n- full: %s%s\n' "${fast:-not found: choose one}" "${fast_src:+ ($fast_src)}" "${full:-not found: choose one}" "${full_src:+ ($full_src)}"
$mcp && printf -- '- the project builds or tests through an agent tool (XcodeBuildMCP): verify.sh needs a shell command, so check the one above\n'
if $own_docs; then
  dcmd="$(printf '%s' "$rows" | awk -F'\t' '$1 == "docs check" && $2 == "configured" { print $3; exit }')"
  case "$dcmd" in *.py) dcmd="python3 $dcmd" ;; *.rb) dcmd="ruby $dcmd" ;; esac
  printf -- '- the project has its own docs check: run it instead of the harness'"'"'s, with --docs-command "%s" (docs.command)\n' "$dcmd"
fi
printf -- '- cost of each command: not measured. Timing runs them, which needs your approval: time-commands.sh --project . -- "<fast>" "<full>"\n'
printf '\nNext safe action: decide whether to time the commands above, then run setup guest with them.\n'
