#!/bin/bash
# The guided configuration (/swift-harness:configure): a few answers, written into
# .claude/swift-harness.json as the keys they stand for. Every other key stays as it is.
#
#   configure.sh --show [--project DIR]               the current answer to each question
#   configure.sh --apply [--project DIR] ANSWER...    write answers, given as question=choice:
#
#     strictness=light|normal|strict   light: a failing check is reported, never blocks
#                                      (verify.maxAttempts 1); normal: blocks up to 3 times;
#                                      strict: up to 5 times, and SwiftLint errors block (lintBlocking)
#     stop=turn|commit                 when the checks run (verify.when): at the end of each turn
#                                      that changed code, or before a commit
#     snapshots=fail|collect           a new or changed image fails its test, or waits for one
#                                      approval (snapshots.pending)
#     tolerance=NUMBER                 the fraction of pixels a snapshot may differ by, 0 up to 1
#                                      (snapshots.tolerance)
#     approvals=weakening|always       the approval commands ask only when something weakens a
#                                      check, or every time (approvals.ask)
#     moves=approve|pass               a security setting moved to another file waits for an
#                                      approval, or is no change (security.moves)
#     direction=mac|ios-planned|porting   where the app goes (porting.direction)
#     docs=blocking|observed|off       the docs reference check (docs.enabled, docs.blocking)
#     recap=off|text|md|html           a recap of the checks at the end of each turn (recap)
#
# A default answer removes its key, so the file holds only what differs from the defaults.
# Written through a temp file renamed over the config. Run by the user through the skill.

usage() {
  echo "usage: configure.sh --show [--project DIR] | --apply [--project DIR] question=choice..." >&2
  exit 2
}
action="${1:-}"
case "$action" in --show | --apply) shift ;; *) usage ;; esac
dir="$PWD"
if [ "${1:-}" = "--project" ]; then
  [ -n "${2:-}" ] || usage
  dir="$2"
  shift 2
fi
[ "$action" = --show ] && [ $# -gt 0 ] && usage
[ "$action" = --apply ] && [ $# -eq 0 ] && usage

. "$(dirname "$0")/lib.sh" </dev/null
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}' 2>/dev/null)"
sh_init || { echo "swift-harness: no .claude/swift-harness.json in $dir (or jq is missing): run /swift-harness:setup first." >&2; exit 1; }
jq -e 'type == "object"' "$SH_CONFIG" >/dev/null 2>&1 || { echo "swift-harness: $SH_CONFIG is not a JSON object: fix it first (/swift-harness:doctor)." >&2; exit 1; }

# The current answers, read back from the keys.
show() {
  jq -r '
    "strictness: " + (if .lintBlocking == true then "strict" elif (.verify.maxAttempts? // 3) == 1 then "light" else "normal" end),
    "stop: " + (.verify.when? // "turn"),
    "snapshots: " + (.snapshots.pending? // "fail"),
    "tolerance: " + ((.snapshots.tolerance? // 0) | tostring),
    "approvals: " + (.approvals.ask? // "weakening"),
    "moves: " + (.security.moves? // "approve"),
    "direction: " + (.porting.direction? // "mac"),
    "docs: " + (if .docs.enabled? == false then "off" elif .docs.blocking? == false then "observed" else "blocking" end),
    "recap: " + (.recap? // "off")' "$SH_CONFIG"
}

if [ "$action" = --show ]; then
  show
  exit 0
fi

# One jq program from the answers, checked before anything is written.
program="."
notes=""
for answer in "$@"; do
  q="${answer%%=*}"
  a="${answer#*=}"
  [ "$q" != "$answer" ] || { echo "swift-harness: '$answer' is not question=choice." >&2; exit 2; }
  bad() { echo "swift-harness: '$a' is not an answer to $q ($1)." >&2; exit 2; }
  case "$q" in
    strictness)
      case "$a" in
        light) program="$program | del(.lintBlocking) | .verify.maxAttempts = 1" ;;
        normal) program="$program | del(.lintBlocking) | del(.verify.maxAttempts)" ;;
        strict) program="$program | .lintBlocking = true | .verify.maxAttempts = 5"
          notes="$notes- strict: SwiftLint errors in an edited file block the end of the turn; SwiftLint must be installed.
" ;;
        *) bad "light, normal or strict" ;;
      esac ;;
    stop)
      case "$a" in
        turn) program="$program | del(.verify.when)" ;;
        commit) program="$program | .verify.when = \"commit\""
          notes="$notes- stop=commit: the end of a turn runs nothing; a git commit made by Claude is refused until the checks pass on its code (Claude runs them with check.sh). Your own commits are not stopped: to check them too, add a git pre-commit hook that runs \"$(cd "$(dirname "$0")" && pwd)/check.sh\" --project \"$SH_ROOT\".
" ;;
        *) bad "turn or commit" ;;
      esac ;;
    snapshots)
      case "$a" in
        fail) program="$program | del(.snapshots.pending)" ;;
        collect) program="$program | .snapshots.pending = \"collect\""
          notes="$notes- snapshots=collect: scripts/verify.sh from a template older than this version does not fail on waiting images in full mode: update it from the setup template and approve it again.
" ;;
        *) bad "fail or collect" ;;
      esac ;;
    tolerance)
      [[ "$a" =~ ^(0|0?\.[0-9]+)$ ]] || bad "a number from 0 up to 1, such as 0.001"
      if [[ "$a" =~ ^0?\.?0*$ ]]; then program="$program | del(.snapshots.tolerance)"
      else program="$program | .snapshots.tolerance = ${a/#./0.}"; fi ;;
    approvals)
      case "$a" in
        weakening) program="$program | del(.approvals.ask)" ;;
        always) program="$program | .approvals.ask = \"always\"" ;;
        *) bad "weakening or always" ;;
      esac ;;
    moves)
      case "$a" in
        approve) program="$program | del(.security.moves)" ;;
        pass) program="$program | .security.moves = \"pass\""
          notes="$notes- moves=pass weakens the security check, so it is itself a change to approve: run /swift-harness:approve-security.
" ;;
        *) bad "approve or pass" ;;
      esac ;;
    direction)
      case "$a" in
        mac) program="$program | del(.porting.direction)" ;;
        ios-planned) program="$program | .porting.direction = \"ios-planned\""
          notes="$notes- direction=ios-planned: /swift-harness:port-to-ios writes a read-only plan of what is shared and what is macOS-only, when you want it.
" ;;
        porting) program="$program | .porting.direction = \"porting\""
          [ -f "$SH_ROOT/$(sh_ratchet)" ] || notes="$notes- direction=porting: no porting ratchet yet. Record the modules that already build for iOS, so they keep building: porting.sh ratchet --record (the doctor and /swift-harness:port-to-ios say how).
" ;;
        *) bad "mac, ios-planned or porting" ;;
      esac ;;
    docs)
      case "$a" in
        blocking) program="$program | del(.docs.enabled) | del(.docs.blocking)" ;;
        observed) program="$program | del(.docs.enabled) | .docs.blocking = false" ;;
        off) program="$program | .docs.enabled = false | del(.docs.blocking)" ;;
        *) bad "blocking, observed or off" ;;
      esac ;;
    recap)
      case "$a" in
        off) program="$program | del(.recap)" ;;
        text | md | html) program="$program | .recap = \"$a\"" ;;
        *) bad "off, text, md or html" ;;
      esac ;;
    *) echo "swift-harness: no question named '$q'." >&2; exit 2 ;;
  esac
done
# Objects left empty by a removal go too.
program="$program | with_entries(select((.value | type) != \"object\" or (.value | length) > 0))"

[ ! -L "$SH_CONFIG" ] || { echo "swift-harness: $SH_CONFIG is a link: not written through it." >&2; exit 1; }
before="$(show)"
tmp="$SH_CONFIG.configure.$$"
if ! jq "$program" "$SH_CONFIG" >"$tmp" 2>/dev/null || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"
  echo "swift-harness: could not write the answers. Nothing changed." >&2
  exit 1
fi
mv -f "$tmp" "$SH_CONFIG"
after="$(show)"
changed="$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> //p')"
if [ -z "$changed" ]; then
  echo "Nothing changed: the configuration already gives these answers."
else
  printf 'Written to %s:\n%s\n' "${SH_CONFIG#"$SH_ROOT"/}" "$(printf '%s\n' "$changed" | sed 's/^/  /')"
fi
[ -z "$notes" ] || printf '\nTo know:\n%s' "$notes"
sh_catch "configuration" changed "$(printf '%s\n' "$changed" | paste -sd';' - | sed 's/;/; /g')"
exit 0
