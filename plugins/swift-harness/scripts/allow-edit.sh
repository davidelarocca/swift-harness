#!/bin/bash
# One permit for one edit of a file by Codex. Codex cannot ask the user from a hook, so the guard
# refuses its edit of a protected file; once the user agrees, they run this in their own terminal,
# through the launcher setup-guest.sh --codex writes:
#
#   bash .codex/swift-harness-hook.sh --allow <file>
#
# The permit covers that file, in this checkout, for one patch within an hour. A patch that also
# touches another protected file is refused whole, and the permit stays.
#
# This keeps honest agents honest: it is not a boundary against an agent that means harm. It
# refuses to run without a terminal and asks for a typed yes, but an agent with a shell and access
# to the plugin data folder could get round that, as it could edit the file through the shell.
# Every permit and every use is in the catch log, and the Codex sandbox keeps a sandboxed agent
# out of that folder.
#
#   allow-edit.sh <file>     ask, then write the permit
#   allow-edit.sh --check <file>   (codex-hook.sh) exit 0 when a valid permit exists
#   allow-edit.sh --use <file>     (codex-hook.sh) spend it
#
# Exit 0: done. Exit 1: refused or no permit. Exit 2: usage.

set -uo pipefail
usage() {
  echo "usage: allow-edit.sh <file>" >&2
  exit 2
}
mode=allow
case "${1:-}" in
  --check) mode=check; shift ;;
  --use) mode=use; shift ;;
  -* | "") usage ;;
esac
[ $# -eq 1 ] && [ -n "$1" ] || usage
target="$1"

. "$(dirname "$0")/lib.sh" </dev/null
SH_INPUT="$(jq -nc --arg cwd "${SH_PERMIT_CWD:-$PWD}" --arg session "${SH_PERMIT_SESSION:-}" '{cwd: $cwd, session_id: $session}' 2>/dev/null)"
sh_init || { echo "swift-harness: no .claude/swift-harness.json here (or jq is missing)." >&2; exit 1; }
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || { echo "swift-harness: run this through .codex/swift-harness-hook.sh --allow." >&2; exit 1; }

case "$target" in /*) abs="$target" ;; *) abs="${SH_PERMIT_CWD:-$PWD}/$target" ;; esac
rel="$(sh_relpath "$abs")"
[ -n "$rel" ] || { echo "swift-harness: $target is outside this project." >&2; exit 1; }
dir="$(sh_state_dir)/edit-permits" || exit 1
permit="$dir/$(printf '%s' "$rel" | shasum | cut -d' ' -f1)"
max_age=3600

valid() {
  local t
  [ -f "$permit" ] || return 1
  t="$(sed -n 1p "$permit")"
  case "$t" in '' | *[!0-9]*) return 1 ;; esac
  [ "$(sed -n 2p "$permit")" = "$rel" ] && [ $(($(date +%s) - t)) -le "$max_age" ]
}

case "$mode" in
  check) valid ;;
  use)
    valid || exit 1
    rm -f "$permit"
    sh_catch guard approved "$rel: edited with a one-time permit from the user"
    ;;
  allow)
    [ -t 0 ] || { echo "swift-harness: this needs your own terminal: an agent must not give itself this permit." >&2; exit 1; }
    # Whatever was typed before the question is not an answer to it.
    while IFS= read -r -t 1 _; do :; done
    printf 'Allow one edit of %s by Codex, within the next hour? Type yes: ' "$rel"
    IFS= read -r answer
    [ "$answer" = yes ] || { echo "Nothing allowed."; exit 1; }
    mkdir -p "$dir" || exit 1
    printf '%s\n%s\n' "$(date +%s)" "$rel" >"$permit"
    SH_AGENT=user sh_catch guard approved "$rel: one-time permit given to Codex"
    echo "Allowed: one edit of $rel, within the next hour."
    ;;
esac
