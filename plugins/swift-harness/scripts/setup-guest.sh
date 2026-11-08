#!/bin/bash
# Guest mode (#71): set swift-harness up on a project that has its own agent rules, docs and
# checks, adding only two files. Run by /swift-harness:setup guest, after the user confirmed
# the commands; never by a hook.
#
#   setup-guest.sh --fast "<command>" [--full "<command>"] [--project DIR] [--no-docs]
#
# Writes .claude/swift-harness.json ("guest": true) and scripts/verify.sh, which runs the
# project's own commands: the fast one at the end of each turn, the full one (or the fast one)
# before merging. Nothing else in the project changes: no CLAUDE.md, rules, docs, templates.
# The formatter and SwiftLint stay off unless the project already has their config, so its
# code is never rewritten in another style. --no-docs turns off the docs reference check, for a
# project whose own docs check runs in its commands.
#
# Exit 0: written (both paths printed). Exit 1: one of the files exists (nothing written).
# Exit 2: usage.

set -uo pipefail

usage() {
  echo "usage: setup-guest.sh --fast \"<command>\" [--full \"<command>\"] [--project DIR] [--no-docs]" >&2
  exit 2
}

dir="."
fast=""
full=""
docs=true
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) [ $# -ge 2 ] && [ -n "$2" ] || usage; fast="$2"; shift 2 ;;
    --full) [ $# -ge 2 ] && [ -n "$2" ] || usage; full="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --no-docs) docs=false; shift ;;
    *) usage ;;
  esac
done
[ -n "$fast" ] || usage
command -v jq >/dev/null 2>&1 || { echo "setup-guest: jq is required (brew install jq)." >&2; exit 2; }
root="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "setup-guest: no such folder: $dir" >&2; exit 2; }
config="$root/.claude/swift-harness.json"
# A folder named Scripts (or any case) is the same folder on a default macOS volume: write
# into it under its own name, so git and the verify command agree on the path.
sdir="$(ls -1 "$root" 2>/dev/null | grep -ixm1 scripts)"
sdir="${sdir:-scripts}"
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

mkdir -p "$root/.claude" "$root/$sdir" || exit 1
jq -n --arg format "$format" --arg lint "$lint" --argjson docs "$docs" --arg cmd "$sdir/verify.sh fast" '
  {guest: true, format: $format, lint: $lint, verify: {command: $cmd, maxAttempts: 3}}
  + (if $docs then {} else {docs: {enabled: false}} end)' >"$config" || exit 1

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
