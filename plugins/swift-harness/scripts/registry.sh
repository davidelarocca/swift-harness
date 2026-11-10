#!/bin/bash
# Component registry (#7): check that docs/COMPONENT_REGISTRY.md is true.
#
# Reads the Markdown tables of the registry; runs no code from the repository, so the
# hooks call it without the verify approval. Columns are found by their header: the
# "Components" table needs a Name and a File column (ID is optional). File holds paths
# from the repository root, comma-separated, an optional :line suffix is ignored.
# A literal pipe inside a cell is written \|.
#
# Usage: registry.sh check   <project root>
#          Exit 0: no registry, or no problem. Exit 1: problems, printed for Claude.
#          Exit 3: the registry has no Components table with Name and File columns, so it
#          cannot be checked (printed, never blocks).
#        registry.sh summary <project root>     one line for doctor.sh
#        registry.sh missing <project root> [file ...]
#          Components declared under registry.sources (or in the given files) that the
#          registry does not list: "Name<TAB>path:line" per line. A component is a type
#          declared at top level, not private, that conforms to View, ViewModifier, Layout,
#          Shape, an AppKit or UIKit representable or a *Style protocol. Listed means: a Name under Components, or a mention under
#          Internal or To consolidate. Never fails.
#        registry.sh entries <project root> <file>
#          Registry entries whose File is the given file: "ID Name" per line.
#        registry.sh records <project root>
#          The records below, for weaken-watch.sh (#146).

set -u

mode="${1:-}"
root="${2:?usage: registry.sh check|summary|missing|entries <project root> [file ...]}"
shift 2
config="$root/.claude/swift-harness.json"

cfg() { # $1 jq path, $2 default
  local v
  v="$(jq -r "$1 | if . == null then empty else . end" "$config" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}

reg_rel="$(cfg '.registry.path' 'docs/COMPONENT_REGISTRY.md')"
reg_rel="${reg_rel#./}"
registry="$root/$reg_rel"
[ -f "$registry" ] || exit 0

# One record per table row, fields separated by \037 (with a tab, read merges empty cells,
# so a row without an ID lost a field):
#   C <line> <id> <name> <files>   a Components row
#   R <line> <id>                  a Retired row
#   K <row text>                   an Internal or To consolidate row
#   H                              no Components table with Name and File columns
parse() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^##[ \t]/ { sec = tolower(trim(substr($0, 3))); intable = 0; next }
    /^[ \t]*\|/ {
      row = $0
      gsub(/\\\|/, "\001", row)
      sub(/^[ \t]*\|/, "", row); sub(/\|[ \t]*$/, "", row)
      n = split(row, c, "|")
      for (i = 1; i <= n; i++) { c[i] = trim(c[i]); gsub("\001", "|", c[i]) }
      if (!intable) {
        intable = 1
        if (sec ~ /^components/) {
          ni = fi = ii = 0
          for (i = 1; i <= n; i++) {
            h = tolower(c[i])
            if (h == "name") ni = i
            else if (h == "file" || h == "files") fi = i
            else if (h == "id") ii = i
          }
          if (ni && fi) found = 1
        }
        next
      }
      if (c[1] ~ /^:?-+:?$/) next
      if (sec ~ /^components/ && ni && fi) printf "C\037%d\037%s\037%s\037%s\n", NR, (ii ? c[ii] : ""), c[ni], c[fi]
      else if (sec ~ /^retired/) printf "R\037%d\037%s\n", NR, c[1]
      else if (sec ~ /^(internal|to consolidate)/) { gsub(/\t/, " ", row); printf "K\037%s\n", row }
      next
    }
    { intable = 0 }
    END { if (!found) print "H" }
  ' "$registry"
}

# The identifier a Name cell names: backticks, a leading dot and call parentheses dropped.
name_of() { printf '%s' "$1" | tr -d '`' | sed -E 's/^[^A-Za-z_]*//; s/[^A-Za-z0-9_].*//'; }

# The paths of a File cell, one per line.
files_of() {
  printf '%s' "$1" | tr -d '`' | sed -E 's#<br */?>#,#g' | tr ',' '\n' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/:[0-9]+$//; s#^\./##' | grep -v '^$'
}

declares() { # $1 file, $2 name
  grep -qE "(^|[^A-Za-z0-9_])(struct|class|enum|actor|protocol|typealias|func|var|let|case|macro)[[:space:]]+$2([^A-Za-z0-9_]|$)" "$1"
}

records="$(parse)"

case "$mode" in
  check)
    if grep -qx 'H' <<<"$records"; then
      printf 'Component registry (%s): not checked, it has no "## Components" table with Name and File columns. Use the table of the swift-harness template.\n' "$reg_rel"
      exit 3
    fi
    problems=""
    problem() { problems="$problems- $reg_rel:$1: $2"$'\n'; }
    ids=""
    names=""
    while IFS=$'\037' read -r kind line id name_cell file_cell; do
      [ "$kind" = C ] || continue
      name="$(name_of "$name_cell")"
      # The template's empty example row.
      [ -n "$name" ] || [ -n "$file_cell" ] || continue
      label="${id:+$id }${name:-(no name)}"
      [ -n "$name" ] || problem "$line" "$label: the Name cell has no Swift name."
      if [ -n "$id" ]; then
        grep -qxF -- "$id" <<<"$ids" && problem "$line" "$label: the ID $id is listed more than once."
        ids="$ids$id"$'\n'
      fi
      if [ -n "$name" ]; then
        grep -qxF -- "$name" <<<"$names" && problem "$line" "$label: the name $name is listed more than once."
        names="$names$name"$'\n'
      fi
      paths="$(files_of "$file_cell")"
      if [ -z "$paths" ]; then
        problem "$line" "$label: the File cell is empty."
        continue
      fi
      all_exist=true
      declared=false
      while IFS= read -r path; do
        if [ ! -f "$root/$path" ]; then
          problem "$line" "$label: $path does not exist (moved, renamed or deleted?)."
          all_exist=false
        elif [ -n "$name" ] && declares "$root/$path" "$name"; then
          declared=true
        fi
      done <<<"$paths"
      if [ "$all_exist" = true ] && [ "$declared" = false ] && [ -n "$name" ]; then
        problem "$line" "$label: $name is not declared in $(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g') (renamed or moved?)."
      fi
    done <<<"$records"
    while IFS=$'\037' read -r kind line id _; do
      [ "$kind" = R ] && [ -n "$id" ] || continue
      grep -qxF -- "$id" <<<"$ids" && problem "$line" "$id is under Retired and still under Components."
    done <<<"$records"
    [ -n "$problems" ] || exit 0
    printf 'Component registry (%s) does not match the code:\n%s' "$reg_rel" "$problems"
    printf 'Update the registry in the same change as the code: fix the Name or File of a moved or renamed component, move a removed one to Retired. If the code is wrong instead, fix the code.\n'
    exit 1
    ;;

  summary)
    count=0
    while IFS=$'\037' read -r kind _ _ name_cell file_cell; do
      [ "$kind" = C ] || continue
      [ -n "$(name_of "$name_cell")" ] || [ -n "$file_cell" ] || continue
      count=$((count + 1))
    done <<<"$records"
    printf '%s: %s components\n' "$reg_rel" "$count"
    ;;

  missing)
    listed="$(while IFS=$'\037' read -r kind _ _ name_cell _; do
      [ "$kind" = C ] && name_of "$name_cell" && echo
    done <<<"$records")"
    known="$(grep '^K' <<<"$records")"
    sources="$(jq -r '.registry.sources[]? | strings' "$config" 2>/dev/null | grep -v '{{' | sed -E 's#^\./##; s#/+$##')"
    [ -n "$sources" ] || exit 0
    files=""
    if [ "$#" -gt 0 ]; then
      for f in "$@"; do
        rel="${f#"$root"/}"
        while IFS= read -r src; do
          case "$rel" in "$src"/*) files="$files$rel"$'\n' ;; esac
        done <<<"$sources"
      done
    else
      while IFS= read -r src; do
        [ -d "$root/$src" ] || continue
        files="$files$(cd "$root" && find "$src" -name '*.swift' -not -path '*/.build/*' | sort)"$'\n'
      done <<<"$sources"
    fi
    while IFS= read -r rel; do
      [ -n "$rel" ] && [ -f "$root/$rel" ] || continue
      # Top-level declarations only (no indentation), generic parameters removed, outside
      # block comments. A conformance list may continue on the next lines, up to the brace.
      sed -E 's/<[^<>]*>//g' "$root/$rel" | awk -v file="$rel" '
        incomment { if ($0 ~ /\*\//) incomment = 0; next }
        /^[ \t]*\/\*/ { if ($0 !~ /\*\//) incomment = 1; next }
        /^((@[A-Za-z]+(\([^)]*\))?|public|internal|package|open|final|nonisolated)[ \t]+)*(struct|class|enum|actor)[ \t]+[A-Za-z_][A-Za-z0-9_]*/ {
          start = NR; line = $0; extra = 0
          while (line !~ /\{/ && extra < 5 && (getline more) > 0) { line = line " " more; extra++ }
          sub(/\{.*/, "", line); sub(/[ \t]where[ \t].*/, "", line)
          if (index(line, ":") == 0) next
          decl = line; sub(/:.*/, "", decl); sub(/[ \t]+$/, "", decl)
          n = split(decl, w, /[ \t]+/); name = w[n]
          conf = line; sub(/^[^:]*:/, "", conf)
          if (conf ~ /(^|[^A-Za-z0-9_])(View|ViewModifier|Layout|Shape|InsettableShape|NSViewRepresentable|NSViewControllerRepresentable|UIViewRepresentable|UIViewControllerRepresentable|[A-Za-z]*Style)([^A-Za-z0-9_]|$)/) printf "%s\t%s:%d\n", name, file, start
        }'
    done <<<"$files" | while IFS=$'\t' read -r name where; do
      grep -qxF -- "$name" <<<"$listed" && continue
      grep -qE "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|$)" <<<"$known" && continue
      printf '%s\t%s\n' "$name" "$where"
    done
    exit 0
    ;;

  entries)
    target="${1:?usage: registry.sh entries <project root> <file>}"
    target="${target#"$root"/}"
    while IFS=$'\037' read -r kind _ id name_cell file_cell; do
      [ "$kind" = C ] || continue
      files_of "$file_cell" | grep -qxF -- "$target" || continue
      printf '%s\n' "${id:+$id }$(name_of "$name_cell")"
    done <<<"$records"
    ;;

  records)
    printf '%s\n' "$records"
    ;;

  *)
    echo "usage: registry.sh check|summary|missing|entries|records <project root> [file ...]" >&2
    exit 2
    ;;
esac
