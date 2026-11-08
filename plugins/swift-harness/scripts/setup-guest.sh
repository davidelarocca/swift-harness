#!/bin/bash
# Guest mode (#71): set swift-harness up on a project that has its own agent rules, docs and
# checks, adding only two files. Run by /swift-harness:setup guest, after the user confirmed
# the commands; never by a hook.
#
#   setup-guest.sh --fast "<command>" [--full "<command>"] [--project DIR] [--no-docs | --docs-command "<command>"]
#                  [--owned PATH]...
#
# Writes .claude/swift-harness.json ("guest": true) and scripts/verify.sh, which runs the
# project's own commands: the fast one at the end of each turn, the full one (or the fast one)
# before merging. Nothing else in the project changes: no CLAUDE.md, rules, docs, templates.
# The formatter and SwiftLint stay off unless the project already has their config, so its
# code is never rewritten in another style. --docs-command runs the project's own docs check
# instead of the harness's (docs.command, #105); --no-docs turns the docs check off.
# The project's agent rules that exist (CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, .claude/rules/)
# and each --owned path (docs only some people may edit) become protectedPaths (#109): the guard
# asks before Claude edits them, and a shell edit is reported at the end of the turn.
#
# Exit 0: written (both paths printed). Exit 1: one of the files exists (nothing written).
# Exit 2: usage.

set -uo pipefail

usage() {
  echo "usage: setup-guest.sh --fast \"<command>\" [--full \"<command>\"] [--project DIR] [--no-docs | --docs-command \"<command>\"] [--owned PATH]..." >&2
  exit 2
}

dir="."
fast=""
full=""
docs=true
docs_command=""
owned=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) [ $# -ge 2 ] && [ -n "$2" ] || usage; fast="$2"; shift 2 ;;
    --full) [ $# -ge 2 ] && [ -n "$2" ] || usage; full="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --no-docs) docs=false; shift ;;
    --docs-command) [ $# -ge 2 ] && [ -n "$2" ] || usage; docs_command="$2"; shift 2 ;;
    --owned) [ $# -ge 2 ] && [ -n "$2" ] || usage; owned="$owned$2"$'\n'; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$fast" ] || usage
command -v jq >/dev/null 2>&1 || { echo "setup-guest: jq is required (brew install jq)." >&2; exit 2; }
root="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "setup-guest: no such folder: $dir" >&2; exit 2; }
config="$root/.claude/swift-harness.json"
# A folder named Scripts (or any case) is the same folder on a default macOS volume: write
# into it under its own name, so git and the verify command agree on the path.
sdir=scripts
for d in "$root"/[sS][cC][rR][iI][pP][tT][sS]; do
  [ -d "$d" ] && { sdir="${d##*/}"; break; }
done
verify="$root/$sdir/verify.sh"

exists=""
[ -e "$config" ] && exists="$exists .claude/swift-harness.json"
[ -e "$verify" ] && exists="$exists $sdir/verify.sh"
if [ -n "$exists" ]; then
  echo "setup-guest: already there:$exists. Nothing written: merge by hand, or remove them first." >&2
  exit 1
fi

# The project's own formatter and SwiftLint, if it has their config; off otherwise.
format=none
if [ -f "$root/.swiftformat" ]; then format=swiftformat
elif [ -f "$root/.swift-format" ]; then format=swift-format; fi
lint=none
[ -f "$root/.swiftlint.yml" ] && lint=swiftlint

# The project's own rules, and the paths it owns, are asked about before an edit (#109).
protect="$(for p in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do [ -f "$root/$p" ] && printf '%s\n' "$p"; done
  [ -d "$root/.claude/rules" ] && printf '.claude/rules/\n'
  printf '%s' "$owned" | while IFS= read -r p; do
    p="${p#./}"
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || { echo "setup-guest: --owned $p does not exist; left out" >&2; continue; }
    printf '%s\n' "$p"
  done)"
mkdir -p "$root/.claude" "$root/$sdir" || exit 1
jq -n --arg format "$format" --arg lint "$lint" --argjson docs "$docs" --arg cmd "$sdir/verify.sh fast" --arg dcmd "$docs_command" \
  --arg protect "$protect" '
  {guest: true, format: $format, lint: $lint, verify: {command: $cmd, maxAttempts: 3}}
  + (($protect | split("\n") | map(select(length > 0))) as $p | if ($p | length) > 0 then {protectedPaths: $p} else {} end)
  + (if $docs then (if $dcmd == "" then {} else {docs: {command: $dcmd}} end) else {docs: {enabled: false}} end)' >"$config" || exit 1

# The commands go in as single-quoted shell words, so nothing in them is expanded here.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf '#!/bin/bash\n'
  printf '# Project verification for swift-harness in guest mode (#71): it runs the project'"'"'s own\n'
  printf '# commands. Edit them freely; the end-of-turn check runs "fast" once you approve it.\n'
  printf '#   scripts/verify.sh fast   at the end of a turn\n'
  printf '#   scripts/verify.sh full   before merging\n'
  printf 'set -uo pipefail\n'
  printf 'cd "$(dirname "$0")/.." || exit 1\n'
  printf 'FAST=%s\n' "$(quote "$fast")"
  printf 'FULL=%s\n' "$(quote "${full:-$fast}")"
  printf 'case "${1:-fast}" in\n'
  printf '  fast) bash -c "$FAST" ;;\n'
  printf '  full) bash -c "$FULL" ;;\n'
  printf '  *) printf '"'"'verify: unknown mode "%%s". Use fast or full.\\n'"'"' "$1"; exit 2 ;;\n'
  printf 'esac\n'
} >"$verify" || exit 1
chmod +x "$verify"

printf '%s\n%s\n' "$config" "$verify"
