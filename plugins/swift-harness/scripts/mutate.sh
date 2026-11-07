#!/bin/bash
# Check sensitivity (#79): plant one defect at a time in a copy of the project and record
# which checks notice it. Run by the user, never by a hook.
#
#   mutate.sh [--project DIR] [--only OPERATOR]...   run the mutations, print the report
#   mutate.sh --list                                 the operators and the check each one targets
#
# The project itself is never touched: it is copied (without .git, .build and DerivedData)
# into a temporary folder with a fresh git repository, so checks that read `git ls-files`
# see the same files. Each operator changes one file at one site, chosen the same way every
# run; the file is restored before the next operator.
#
# The checks are run once on the copy without mutations. A mutation is killed by a check
# when that check fails on it with a problem it did not report before (line numbers are
# ignored), so a check that already fails can still notice a new defect. A survived
# mutation is a finding to explain (a bug in the check, or out of its scope by design), not
# a failure of the run: the exit code is 0 whenever the report is produced.
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
contracts-forbidden	contracts	a target gains a dependency on a sibling target its contract does not allow'
CHECKS='registry layout docs security contracts'

usage() {
  echo "usage: mutate.sh [--project DIR] [--only OPERATOR]... | --list" >&2
  exit 2
}

project="."
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      printf '%s\n' "$OPERATORS" | awk -F'\t' '{ printf "%-20s %-10s %s\n", $1, $2, $3 }'
      exit 0
      ;;
    --project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
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

work="$(mktemp -d -t swift-harness-mutate.XXXXXX)" || exit 2
trap 'rm -rf "$work"' EXIT
copy="$work/project"
mkdir -p "$copy" "$work/data" "$work/base" "$work/mut" "$work/orig"
if ! (cd "$project" && tar -cf - --exclude ./.git --exclude .build --exclude DerivedData --exclude '*.xcresult' .) | (cd "$copy" && tar -xf -); then
  echo "mutate: could not copy $project." >&2
  exit 2
fi
git -C "$copy" init -q 2>/dev/null || { echo "mutate: git init failed in the copy." >&2; exit 2; }

# ---- checks ----

# $1 check, $2 output folder: writes <check>.exit and <check>.out (line numbers removed).
run_check() {
  local c="$1" dir="$2" out code
  case "$c" in
    registry | layout | docs) out="$("$here/$c.sh" check "$copy" 2>&1 </dev/null)" ;;
    security) out="$(CLAUDE_PLUGIN_DATA="$work/data" "$here/security.sh" check --project "$copy" 2>&1 </dev/null)" ;;
    contracts) out="$("$here/contracts.sh" "$copy" 2>&1 </dev/null)" ;;
  esac
  code=$?
  printf '%s' "$code" >"$dir/$c.exit"
  printf '%s\n' "$out" | sed -E 's/:[0-9]+(:|$)/\1/g' | grep -v '^$' | sort -u >"$dir/$c.out"
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
  local f="$copy/$1" result
  result="$(awk -F'|' -v heading="$2" -v column="$3" -v OFS='|' '
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
    { print }' "$f" 2>"$work/site" >"$f.mutated")" || true
  [ -s "$work/site" ] || { rm -f "$f.mutated"; return 0; }
  save "$1"
  mv "$f.mutated" "$f"
  result="$(cat "$work/site")"
  printf '%s\n' "$result"
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

printf 'Check sensitivity: %s\n' "$project"
printf 'Without mutations: %s\n\n' "$base_summary"
printf '| Operator | Site | Target | Result | Failed checks |\n|---|---|---|---|---|\n'

killed=0 survived=0 nosite=0
while IFS=$'\t' read -r op target _; do
  [ -z "$only" ] || [[ " $only " == *" $op "* ]] || continue
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

printf '\n%s killed, %s survived, %s with no site.\n' "$killed" "$survived" "$nosite"
[ "$survived" -eq 0 ] || printf 'A survived mutation is a finding: explain it (a bug in the check, or out of its scope by design).\n'
exit 0
