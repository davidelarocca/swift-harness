#!/bin/bash
# Drift score (#80): how coherent the project is, per commit. Run by the user (and the evals of
# #8), never by a hook; it sources no hook code.
#
#   drift.sh score   [--project DIR] [--exclude ERE] [--json]
#       the working tree, with the details
#   drift.sh history <range> [--every N] [--project DIR] [--exclude ERE] [--json]
#       one line (or JSON object) per commit of a git range, oldest first (main~20..main);
#       --every N keeps one commit in N, and the last one, for a long history
#
# Measured in the UI code (Swift files outside tests, and outside the files the SwiftLint
# padding rule excludes, usually the design system package, and outside paths matching
# --exclude, for a project without that SwiftLint config):
# - Design values: padding, stack spacing, corner radius and font size, each use classed as a
#   literal number or a token (any other expression: Spacing.m, theme.gap). Literal values are
#   counted as distinct values and uses; the token share is tokens / (tokens + literals).
#   `.padding()`, an edge alone, and `spacing: 0` are neither. Colors made from components
#   (Color(red:), Color(hex:), NSColor(red:), #colorLiteral) are counted as literals; there is
#   no token count for colors, since named and system colors cannot be told apart from text.
# - Near-duplicate components: a View or ViewModifier not in docs/COMPONENT_REGISTRY.md
#   (registry.sh missing, under registry.sources) whose role, the last word of its name, is
#   the role of a registered component (StatusPill and Pill). Listed for a person to confirm.
# - Problems reported by registry.sh, layout.sh, docs.sh and contracts.sh (contracts.sh
#   evaluates Package.swift, code from the repository, once per commit).
#
# The score is the number of things to fix: literal uses (colors included), near-duplicates
# and problems. Lower is better; its direction over commits is what matters. It grows with the
# code, so a growing app also gets the literal uses per 1000 non-empty UI lines, and the token
# share: those two compare across sizes.
#
# Exit 0: printed. Exit 2: usage error, not a git repository (history), or a missing tool.

set -uo pipefail
export LC_ALL=C

here="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: drift.sh score [--project DIR] [--exclude ERE] [--json] | drift.sh history <range> [--every N] [--project DIR] [--exclude ERE] [--json]" >&2
  exit 2
}

mode="${1:-}"
[ -n "$mode" ] && shift
case "$mode" in score | history) ;; *) usage ;; esac
range=""
project="."
json=false
every=1
exclude=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
    --exclude) [ $# -ge 2 ] || usage; exclude="$2"; shift 2 ;;
    --every)
      [ $# -ge 2 ] || usage
      case "$2" in '' | *[!0-9]* | 0) usage ;; esac
      every="$2"; shift 2 ;;
    --json) json=true; shift ;;
    -*) usage ;;
    *) [ "$mode" = history ] && [ -z "$range" ] || usage; range="$1"; shift ;;
  esac
done
[ "$mode" = score ] || [ -n "$range" ] || usage
command -v jq >/dev/null 2>&1 || { echo "drift: jq is required (brew install jq)." >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "drift: git is required." >&2; exit 2; }
project="$(cd "$project" 2>/dev/null && pwd -P)" || { echo "drift: no such folder." >&2; exit 2; }

work="$(mktemp -d -t swift-harness-drift.XXXXXX)" || exit 2
trap 'rm -rf "$work"' EXIT

# ---- measures, on a folder ----

# $1 root: the UI Swift files, relative to it.
ui_files() {
  local root="$1" excluded files
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    files="$(git -C "$root" -c core.quotepath=off ls-files -co --exclude-standard -- '*.swift' 2>/dev/null)"
  else
    files="$(cd "$root" && find . -name '*.swift' -not -path '*/.build/*' | sed 's#^\./##')"
  fi
  files="$(printf '%s\n' "$files" | grep -v '/\.build/' | grep -vE '(^|/)[^/]*Tests?/|Tests?\.swift$|(^|/)Package\.swift$' | sort)"
  excluded="$(awk '/^  ds_hardcoded_padding:/ { r = 1; next } r && /^  [a-z_]+:/ { exit }
    r && /^    excluded:/ { sub(/^    excluded:[ \t]*/, ""); gsub(/^'"'"'|'"'"'$/, ""); print; exit }' "$root/.swiftlint.yml" 2>/dev/null)"
  case "$excluded" in '' | *'{{'*) ;; *) files="$(grep -vE -- "$excluded" <<<"$files")" ;; esac
  [ -z "$exclude" ] || files="$(grep -vE -- "$exclude" <<<"$files")"
  printf '%s\n' "$files" | grep -v '^$'
}

# $1 root: "<kind>\t<literal|token>\t<value>" per use, in the UI files.
design_values() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      function number(s) { return s ~ /^-?[0-9]+(\.[0-9]+)?$/ }
      function out(kind, v) { v = trim(v); if (number(v)) print kind "\tliteral\t" (v + 0); else print kind "\ttoken\t" v }
      /^[ \t]*\/\// { next }
      {
        s = $0
        while (match(s, /\.padding\(([^()]|\([^()]*\))*\)/)) {
          a = substr(s, RSTART + 9, RLENGTH - 10); s = substr(s, RSTART + RLENGTH)
          a = trim(a)
          if (a == "" || a ~ /^EdgeInsets/) continue
          n = split(a, p, ","); last = trim(p[n])
          if (n == 1 && (last ~ /^\./ || last ~ /^\[/)) continue
          out("padding", last)
        }
        s = $0
        while (match(s, /[^A-Za-z]spacing:[ \t]*[^,)]+/)) {
          v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^.spacing:[ \t]*/, "", v); v = trim(v)
          if (v == "nil" || (number(v) && v + 0 == 0)) continue
          out("spacing", v)
        }
        s = $0
        while (match(s, /cornerRadius(:[ \t]*|\([ \t]*)[^,)]+/)) {
          v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^cornerRadius(:[ \t]*|\([ \t]*)/, "", v)
          out("radius", v)
        }
        s = $0
        while (match(s, /\.font\(([^()]|\([^()]*\))*\)/)) {
          a = substr(s, RSTART + 6, RLENGTH - 7); s = substr(s, RSTART + RLENGTH)
          if (match(a, /size:[ \t]*-?[0-9]+(\.[0-9]+)?/)) { v = substr(a, RSTART + 5, RLENGTH - 5); out("font", v) }
          else out("font", a)
        }
        s = $0
        while (match(s, /(ofSize:|\.custom\([^)]*size:)[ \t]*[0-9]+(\.[0-9]+)?/)) {
          v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^.*size:[ \t]*/, "", v)
          if (index(substr($0, 1, RSTART), ".font(") == 0) out("font", v)
        }
        s = $0
        while (match(s, /(Color\((red|hue|white|hex):[^)]*\)|NSColor\((red|calibratedRed|srgbRed|deviceRed|white|calibratedWhite):[^)]*\)|#colorLiteral\([^)]*\))/)) {
          v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          gsub(/[ \t]+/, "", v)
          # Components computed from variables (Color(red: r, ...)) are not a hardcoded color.
          if (v ~ /[0-9]/ || v ~ /^#colorLiteral/) print "color\tliteral\t" v
        }
      }' "$root/$f"
  done <<<"$(ui_files "$root")"
}

# The last word of a CamelCase name: StatusPill -> Pill, Badge -> Badge.
role() { printf '%s' "$1" | sed -E 's/.*([A-Z][a-z0-9]*)$/\1/'; }

# $1 root: "<name>\t<file:line>\t<registered name>" per near-duplicate.
near_duplicates() {
  local root="$1" doc="$1/docs/COMPONENT_REGISTRY.md" names missing name where r reg
  [ -f "$doc" ] || return 0
  names="$(awk -F'|' '
    function trim(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
    /^#+[ \t]/ { h = $0; sub(/^#+[ \t]+/, "", h); sec = (trim(h) == "Components"); col = 0; sep = 0; next }
    sec && /^[ \t]*\|/ {
      if (!col) { for (i = 1; i <= NF; i++) if (trim($i) == "Name") col = i; next }
      if (!sep) { sep = 1; next }
      v = trim($col); sub(/\(.*/, "", v); if (v != "") print v
    }' "$doc")"
  [ -n "$names" ] || return 0
  missing="$("$here/registry.sh" missing "$root" 2>/dev/null </dev/null)"
  while IFS=$'\t' read -r name where; do
    [ -n "$name" ] || continue
    r="$(role "$name")"
    while IFS= read -r reg; do
      [ -n "$reg" ] && [ "$reg" != "$name" ] || continue
      if [ "$(role "$reg")" = "$r" ]; then printf '%s\t%s\t%s\n' "$name" "$where" "$reg"; break; fi
    done <<<"$names"
  done <<<"$missing"
}

# $1 root, $2 check: the number of problems it reports ("- " lines), 0 when it has nothing to check.
problems() {
  local out
  case "$2" in
    contracts) [ -f "$1/docs/architecture-contracts.json" ] || { echo 0; return; }; out="$("$here/contracts.sh" "$1" 2>&1 </dev/null)" ;;
    *) out="$("$here/$2.sh" check "$1" 2>&1 </dev/null)" ;;
  esac
  printf '%s\n' "$out" | grep -c '^- '
}

# $1 root, $2 commit, $3 date: one JSON object.
measure() {
  local root="$1"
  design_values "$root" >"$work/values"
  ui_lines="$(cd "$root" && ui_files "$root" | while IFS= read -r f; do cat "$f"; done | grep -c .)"
  near_duplicates "$root" >"$work/dupes"
  jq -n --arg commit "$2" --arg date "$3" --argjson lines "${ui_lines:-0}" \
    --rawfile values "$work/values" --rawfile dupes "$work/dupes" \
    --argjson registry "$(problems "$root" registry)" --argjson layout "$(problems "$root" layout)" \
    --argjson docs "$(problems "$root" docs)" --argjson contracts "$(problems "$root" contracts)" '
    def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
    (rows($values)) as $v
    | (rows($dupes) | map({name: .[0], file: .[1], like: .[2]})) as $d
    | def kind($k): ($v | map(select(.[0] == $k))) as $u
        | {literal: ($u | map(select(.[1] == "literal")) | length),
           token: ($u | map(select(.[1] == "token")) | length),
           values: ($u | map(select(.[1] == "literal") | .[2] | tonumber) | unique)};
    {padding: kind("padding"), spacing: kind("spacing"), radius: kind("radius"), font: kind("font")} as $tokens
    | ([$tokens[] | .literal] | add) as $lit | ([$tokens[] | .token] | add) as $tok
    | ($v | map(select(.[0] == "color")) | {literal: length, values: (map(.[2]) | unique)}) as $colors
    | {registry: $registry, layout: $layout, docs: $docs, contracts: $contracts} as $checks
    | {commit: $commit, date: $date,
       score: ($lit + $colors.literal + ($d | length) + ([$checks[]] | add)),
       token_share: (if $lit + $tok == 0 then null else (($tok * 100 / ($lit + $tok)) | round) end),
       ui_lines: $lines,
       literals_per_kloc: (if $lines == 0 then null else ((($lit + $colors.literal) * 10000 / $lines | round) / 10) end),
       tokens: $tokens, colors: $colors, near_duplicates: $d, checks: $checks}'
}

# One JSON object -> one text line.
line() {
  jq -r '
    def k($n): "\($n) \(.tokens[$n].values | length)/\(.tokens[$n].literal)";
    "\(.commit) \(.date)  score \(.score)  tokens \(if .token_share == null then "-" else "\(.token_share)%" end)"
    + "  literals per 1k UI lines \(.literals_per_kloc // "-") (\(.ui_lines) lines)"
    + "  literals (values/uses): \(k("padding")), \(k("spacing")), \(k("radius")), \(k("font")), color \(.colors.values | length)/\(.colors.literal)"
    + "  near-duplicates \(.near_duplicates | length)"
    + "  problems: registry \(.checks.registry), layout \(.checks.layout), docs \(.checks.docs), contracts \(.checks.contracts)"'
}

# ---- run ----

if [ "$mode" = score ]; then
  result="$(measure "$project" working-tree "$(date -u +%Y-%m-%d)")"
  if [ "$json" = true ]; then printf '%s\n' "$result"; exit 0; fi
  printf '%s\n' "$result" | line
  printf '%s\n' "$result" | jq -r '
    (.tokens | to_entries[] | select(.value.values | length > 0) | "  \(.key) literal values: \(.value.values | map(tostring) | join(", "))"),
    (if (.colors.values | length) > 0 then "  colors from components: \(.colors.values | join(", "))" else empty end),
    (.near_duplicates[] | "  near-duplicate: \(.name) (\(.file)) has the role of \(.like): confirm, then reuse \(.like) or register it")'
  exit 0
fi

git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || { echo "drift: $project is not a git repository." >&2; exit 2; }
commits="$(git -C "$project" rev-list --reverse "$range" 2>/dev/null)" || { echo "drift: not a range git knows: $range" >&2; exit 2; }
[ -n "$commits" ] || { echo "drift: no commits in $range." >&2; exit 0; }
if [ "$every" -gt 1 ]; then
  commits="$(printf '%s\n' "$commits" | awk -v n="$every" '{ cur = $0 } (NR - 1) % n == 0 { print } END { if ((NR - 1) % n) print cur }')"
fi
while IFS= read -r sha; do
  tree="$work/tree"
  rm -rf "$tree" && mkdir -p "$tree"
  git -C "$project" archive "$sha" | tar -xf - -C "$tree"
  git -C "$tree" init -q 2>/dev/null
  result="$(measure "$tree" "$(git -C "$project" rev-parse --short "$sha")" "$(git -C "$project" show -s --format=%cs "$sha")")"
  if [ "$json" = true ]; then printf '%s\n' "$result" | jq -c .; else printf '%s\n' "$result" | line; fi
done <<<"$commits"
