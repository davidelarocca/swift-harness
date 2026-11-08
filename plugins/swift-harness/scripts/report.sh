#!/bin/bash
# What the checks caught (#86), from the catch log the hooks keep in the project's state
# folder (catches.jsonl, written by sh_catch in lib.sh). The log never leaves the machine.
# Run by the user through /swift-harness:report, or directly.
#
#   report.sh [--project DIR] [--days N | --since YYYY-MM-DD | --all] [--json]
#
# Default: the last 7 days. Per check: how often it blocked, reported or asked, and how it
# ended (fixed by Claude, left failing, approved by the user); and the checks that did not
# run, with why. Exit 0: printed (also with an empty log). Exit 1: CLAUDE_PLUGIN_DATA unset
# or no config. Exit 2: usage.

set -uo pipefail
export LC_ALL=C

usage() {
  echo "usage: report.sh [--project DIR] [--days N | --since YYYY-MM-DD | --all] [--json]" >&2
  exit 2
}

dir="$PWD"
days=7
since=""
json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --days)
      [ $# -ge 2 ] || usage
      case "$2" in '' | *[!0-9]*) usage ;; esac
      days="$2"; since=""; shift 2 ;;
    --since)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
      since="$2"; days=""; shift 2 ;;
    --all) days=""; since="0000-00-00"; shift ;;
    --json) json=true; shift ;;
    *) usage ;;
  esac
done

if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
  echo "swift-harness: CLAUDE_PLUGIN_DATA is not set. Run this through /swift-harness:report." >&2
  exit 1
fi
. "$(dirname "$0")/lib.sh" </dev/null
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}' 2>/dev/null)"
sh_init || { echo "swift-harness: no .claude/swift-harness.json in $dir (or jq is missing)." >&2; exit 1; }
log="$(sh_state_path)/catches.jsonl"

if [ -n "$days" ]; then
  since="$(date -u -v-"${days}"d +%Y-%m-%d 2>/dev/null || date -u -d "$days days ago" +%Y-%m-%d)"
fi
label="since $since"
[ "$since" = "0000-00-00" ] && label="since the log began"

summary="$(
  { [ -f "$log" ] && cat "$log"; } | jq -sc --arg since "$since" '
    map(select(type == "object" and (.time // "") >= $since))
    | . as $all
    | {
        events: length,
        checks: (map(select(.kind != "skipped")) | group_by(.check) | map({
          check: .[0].check,
          blocked: map(select(.kind == "blocked")) | length,
          reported: map(select(.kind == "reported")) | length,
          asked: map(select(.kind == "asked")) | length,
          fixed: map(select(.kind == "fixed")) | length,
          left_failing: map(select(.kind == "left-failing")) | length,
          approved: map(select(.kind == "approved")) | length,
          last: (map(select(.kind == "blocked" or .kind == "reported" or .kind == "asked")) | last | .what // null)
        }) | sort_by(-(.blocked + .reported + .asked), .check)),
        skipped: (map(select(.kind == "skipped")) | group_by(.check) | map({
          check: .[0].check, times: length, why: (map(.what) | unique)
        }))
      }' 2>/dev/null
)" || summary='{"events":0,"checks":[],"skipped":[]}'
[ -n "$summary" ] || summary='{"events":0,"checks":[],"skipped":[]}'

if [ "$json" = true ]; then
  printf '%s\n' "$summary" | jq --arg since "$since" '{since: $since} + .'
  exit 0
fi

printf '%s\n' "$summary" | jq -r --arg label "$label" --arg root "$SH_ROOT" '
  def n($k): [.checks[] | .[$k]] | add // 0;
  def part($v; $word): if $v > 0 then ["\($v) \($word)"] else [] end;
  "swift-harness report for \($root), \($label):",
  (if .events == 0 then "Nothing in the catch log: no check blocked, reported, asked or was skipped."
   else
     "\(n("blocked")) block(s), \(n("reported")) report(s), \(n("asked")) question(s) before an edit; \(n("fixed")) fixed by Claude, \(n("left_failing")) left failing, \(n("approved")) approval(s) by you.",
     (if (.checks | length) > 0 then "Caught:" else empty end),
     (.checks[] | "- \(.check): " + ((part(.blocked; "blocked") + part(.reported; "reported") + part(.asked; "asked")
        + part(.fixed; "fixed by Claude") + part(.left_failing; "left failing") + part(.approved; "approved by you")) | join(", "))
        + (if .last then ". Last: \(.last)" else "" end)),
     (if (.skipped | length) > 0 then "Not checked:" else empty end),
     (.skipped[] | "- \(.check): \(.times) time(s), \(.why | join("; "))")
   end)'
