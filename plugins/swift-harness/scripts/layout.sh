#!/bin/bash
# Layout contract (#34): check that docs/LAYOUT_CONTRACT.md is complete and true.
#
# Reads the Markdown contract and searches Swift files as text; runs no code from the
# repository, so the hooks call it without the verify approval. The sizes themselves are
# measured by the project's tests, through LayoutContract.check (template
# skills/setup/templates/tests/LayoutContract.swift), which the verify command runs.
#
# The "Screens" table needs View, File and Min columns, found by their header (Screen,
# Window, Default, Max and Compact below are optional). View is the screen's content, Window
# the view its window shows, when the row is a window. Sizes are "<width>x<height>" or
# "<width>" in points; "-" or an empty cell means none. A literal pipe is written \|.
#
# Usage: layout.sh check   <project root>
#          Exit 0: no contract, or no problem. Exit 1: problems, printed for Claude.
#          Exit 3: no Screens table with View, File and Min columns (printed, never blocks).
#        layout.sh summary <project root>          one line for doctor.sh
#        layout.sh entries <project root> <file>   rows whose File is the file, one per line
#        layout.sh records <project root>          the records below, for weaken-watch.sh (#146)

set -u

mode="${1:-}"
root="${2:?usage: layout.sh check|summary|entries <project root> [file]}"
shift 2
config="$root/.claude/swift-harness.json"

cfg() { # $1 jq path, $2 default
  local v
  v="$(jq -r "$1 | if . == null then empty else . end" "$config" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}

rel="$(cfg '.layout.path' 'docs/LAYOUT_CONTRACT.md')"
rel="${rel#./}"
contract="$root/$rel"
[ -f "$contract" ] || exit 0

# One record per Screens row, fields separated by \037 (a tab would merge empty cells in read):
#   S <line> <screen> <view> <file> <window> <min> <default> <max> <compact>
#   H   no Screens table with View, File and Min columns
parse() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function cell(i) { return i ? c[i] : "" }
    /^##[ \t]/ { sec = tolower(trim(substr($0, 3))); intable = 0; next }
    /^[ \t]*\|/ {
      row = $0
      gsub(/\\\|/, "\001", row)
      sub(/^[ \t]*\|/, "", row); sub(/\|[ \t]*$/, "", row)
      n = split(row, c, "|")
      for (i = 1; i <= n; i++) { c[i] = trim(c[i]); gsub("\001", "|", c[i]); gsub(/`/, "", c[i]) }
      if (!intable) {
        intable = 1
        if (sec ~ /^screens/) {
          si = vi = fi = ki = mi = di = xi = ci = 0
          for (i = 1; i <= n; i++) {
            h = tolower(c[i])
            if (h == "screen") si = i
            else if (h == "view") vi = i
            else if (h == "file") fi = i
            else if (h == "window") ki = i
            else if (h == "min") mi = i
            else if (h == "default") di = i
            else if (h == "max") xi = i
            else if (h == "compact below") ci = i
          }
          ok = (vi && fi && mi)
          if (ok) found = 1
        }
        next
      }
      if (c[1] ~ /^:?-+:?$/) next
      if (sec ~ /^screens/ && ok)
        printf "S\037%d\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", NR, cell(si), cell(vi), cell(fi), cell(ki), cell(mi), cell(di), cell(xi), cell(ci)
      next
    }
    { intable = 0 }
    END { if (!found) print "H" }
  ' "$contract"
}

# The identifier a View cell names: a leading dot and call parentheses dropped.
name_of() { printf '%s' "$1" | sed -E 's/^[^A-Za-z_]*//; s/[^A-Za-z0-9_].*//'; }
path_of() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/:[0-9]+$//; s#^\./##'; }

declares() { # $1 file, $2 name
  grep -qE "(^|[^A-Za-z0-9_])(struct|class|enum)[[:space:]]+$2([^A-Za-z0-9_]|$)" "$1"
}

# A size cell: prints "<width> <height>" (height empty when not given), nothing for none,
# fails when the cell is not a size. Accepts x, X or the multiplication sign.
size_of() {
  local s
  s="$(printf '%s' "$1" | sed -E 's/×/x/g; s/[[:space:]]//g; s/pt$//')"
  case "$s" in "" | - | none | None) return 0 ;; esac
  printf '%s' "$s" | grep -qE '^[0-9]+(\.[0-9]+)?([xX][0-9]+(\.[0-9]+)?)?$' || return 1
  printf '%s' "$s" | tr 'xX' '  ' | awk '{ print $1, $2 }'
}

less() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# grep -ohE $1 over the Swift files of the project, one grep for all of them.
grep_swift() {
  (
    cd "$root" || exit
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git ls-files -z -co --exclude-standard -- '*.swift' 2>/dev/null
    else
      find . -name '*.swift' -not -path '*/.build/*' -not -path '*DerivedData*' -print0
    fi | xargs -0 grep -ohE -- "$1" /dev/null 2>/dev/null
  )
}

records="$(parse)"

case "$mode" in
  check)
    if grep -qx 'H' <<<"$records"; then
      printf 'Layout contract (%s): not checked, it has no "## Screens" table with View, File and Min columns. Use the table of the swift-harness template.\n' "$rel"
      exit 3
    fi
    tests="$(grep_swift 'LayoutContract\.check\([[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' | sed -E 's/.*"([^"]*)"/\1/' | sort -u)"
    types="$(grep_swift '(^|[^A-Za-z0-9_])(struct|class|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | awk '{ print $NF }' | sort -u)"
    problems=""
    problem() { problems="$problems- $rel:$1: $2"$'\n'; }
    views=""
    while IFS=$'\037' read -r kind line screen view_cell file_cell window_cell min_cell def_cell max_cell compact_cell; do
      [ "$kind" = S ] || continue
      view="$(name_of "$view_cell")"
      # The template's empty example row.
      [ -n "$view$file_cell$window_cell$min_cell" ] || continue
      label="${screen:+$screen }(${view:-no view})"
      if [ -z "$view" ]; then
        problem "$line" "$label: the View cell has no Swift type name."
      else
        grep -qxF -- "$view" <<<"$views" && problem "$line" "$label: the view $view is listed more than once."
        views="$views$view"$'\n'
      fi
      path="$(path_of "$file_cell")"
      if [ -z "$path" ]; then
        problem "$line" "$label: the File cell is empty."
      elif [ ! -f "$root/$path" ]; then
        problem "$line" "$label: $path does not exist (moved, renamed or deleted?)."
      elif [ -n "$view" ] && ! declares "$root/$path" "$view"; then
        problem "$line" "$label: $view is not declared in $path (renamed or moved?)."
      fi
      window="$(name_of "$window_cell")"
      if [ -n "$window" ] && [ "$window" != "$view" ] && ! grep -qxF -- "$window" <<<"$types"; then
        problem "$line" "$label: the window view $window is not declared in any Swift file (renamed or removed?)."
      fi
      min="" def="" max="" compact=""
      if [ -z "$min_cell" ] || [ "$min_cell" = - ]; then
        problem "$line" "$label: Min is empty: give the smallest size the screen must hold, as <width>x<height>."
      elif ! min="$(size_of "$min_cell")"; then
        problem "$line" "$label: Min '$min_cell' is not a size, expected <width>x<height> or <width> in points."
      fi
      def="$(size_of "$def_cell")" || problem "$line" "$label: Default '$def_cell' is not a size."
      max="$(size_of "$max_cell")" || problem "$line" "$label: Max '$max_cell' is not a size."
      compact="$(size_of "$compact_cell")" || problem "$line" "$label: Compact below '$compact_cell' is not a width."
      min_w="${min%% *}" def_w="${def%% *}" max_w="${max%% *}" compact_w="${compact%% *}"
      if [ -n "$min_w" ] && [ -n "$def_w" ] && less "$def_w" "$min_w"; then
        problem "$line" "$label: Default width $def_w is smaller than Min width $min_w."
      fi
      if [ -n "$min_w" ] && [ -n "$max_w" ] && less "$max_w" "$min_w"; then
        problem "$line" "$label: Max width $max_w is smaller than Min width $min_w."
      fi
      if [ -n "$def_w" ] && [ -n "$max_w" ] && less "$max_w" "$def_w"; then
        problem "$line" "$label: Max width $max_w is smaller than Default width $def_w."
      fi
      if [ -n "$compact_w" ] && [ -n "$min_w" ] && ! less "$min_w" "$compact_w"; then
        problem "$line" "$label: Compact below $compact_w is not above Min width $min_w, so the compact layout is never used."
      fi
      for measured in $view $window; do
        grep -qxF -- "$measured" <<<"$tests" ||
          problem "$line" "$label: no test measures $measured. Add one that calls LayoutContract.check(\"$measured\") { ... } (helper: swift-harness template tests/LayoutContract.swift)."
      done
    done <<<"$records"
    [ -n "$problems" ] || exit 0
    printf 'Layout contract (%s) does not match the code:\n%s' "$rel" "$problems"
    printf 'Update the contract in the same change as the code: fix the View or File of a moved or renamed screen, remove a deleted one, add the missing layout test. If the code is wrong instead, fix the code.\n'
    exit 1
    ;;

  summary)
    count=0
    while IFS=$'\037' read -r kind _ _ view_cell file_cell window_cell min_cell _; do
      [ "$kind" = S ] || continue
      [ -n "$(name_of "$view_cell")$file_cell$window_cell$min_cell" ] || continue
      count=$((count + 1))
    done <<<"$records"
    printf '%s: %s screens\n' "$rel" "$count"
    ;;

  entries)
    target="${1:?usage: layout.sh entries <project root> <file>}"
    target="${target#"$root"/}"
    while IFS=$'\037' read -r kind _ screen view_cell file_cell _ min_cell _ _ compact_cell; do
      [ "$kind" = S ] || continue
      [ "$(path_of "$file_cell")" = "$target" ] || continue
      view="$(name_of "$view_cell")"
      printf '%s (%s, min %s%s)\n' "${screen:-$view}" "$view" "$min_cell" \
        "$([ -n "$compact_cell" ] && [ "$compact_cell" != - ] && printf ', compact below %s' "$compact_cell")"
    done <<<"$records"
    ;;

  records)
    printf '%s\n' "$records"
    ;;

  *)
    echo "usage: layout.sh check|summary|entries|records <project root> [file]" >&2
    exit 2
    ;;
esac
