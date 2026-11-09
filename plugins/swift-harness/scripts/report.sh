#!/bin/bash
# What the checks caught (#86), from the catch log the hooks keep in the project's state
# folder (catches.jsonl, written by sh_catch in lib.sh). The log never leaves the machine.
# Run by the user through /swift-harness:report, or directly.
#
#   report.sh [--project DIR] [--days N | --since YYYY-MM-DD | --all] [--json | --html]
#
# --html (#87) writes .build/swift-harness/report.html in the project and prints its path: a
# static page from the existing outputs only (the last end-of-turn record and the catch log).
# No script, no network, nothing in it changes anything. Every status names its source, a
# check that did not run is never green, the record is marked current only when it is about
# the code as it is now, and every value from the repository or the log is HTML-escaped.
#
# Default: the last 7 days. Per check: how often it blocked, reported or asked, and how it
# ended (fixed by Claude, left failing, approved by the user); and the checks that did not
# run, with why. Exit 0: printed (also with an empty log). Exit 1: CLAUDE_PLUGIN_DATA unset
# or no config. Exit 2: usage.

set -uo pipefail
export LC_ALL=C

usage() {
  echo "usage: report.sh [--project DIR] [--days N | --since YYYY-MM-DD | --all] [--json | --html]" >&2
  exit 2
}

dir="$PWD"
days=7
since=""
json=false
html=false
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
    --html) html=true; shift ;;
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
          reported: map(select(.kind == "reported" or .kind == "observed")) | length,
          unstable: map(select(.kind == "unstable")) | length,
          asked: map(select(.kind == "asked")) | length,
          fixed: map(select(.kind == "fixed")) | length,
          left_failing: map(select(.kind == "left-failing")) | length,
          approved: map(select(.kind == "approved")) | length,
          # In observation (H2 of #105): the findings in a row, in one session, until they are
          # gone, are one episode, however often the set changed. Raw lines would count one
          # root cause many times and say it was never fixed.
          observed_episodes: (map(select(.kind == "observed" or (.kind == "fixed" and ((.what // "") | startswith("observed")))))
            | group_by(.session) | map(reduce .[] as $e ({n: 0, fixed: 0, open: false};
                if $e.kind == "observed" then (if .open then . else .n += 1 | .open = true end)
                elif .open then .fixed += 1 | .open = false else . end))),
          last: (map(select(.kind == "blocked" or .kind == "reported" or .kind == "asked")) | last | .what // null)
        }) | sort_by(-(.blocked + .reported + .asked), .check)
          # A check in observation: propose that it block only with at least 10 episodes over at
          # least 3 sessions, more than 90% fixed in their session. A fix is not proof the finding
          # was right, so the proposal says to look first, and the user decides.
          | map(. + {observed: ([.observed_episodes[].n] | add // 0), observed_fixed: ([.observed_episodes[].fixed] | add // 0),
                     observed_sessions: ([.observed_episodes[] | select(.n > 0)] | length)} | del(.observed_episodes))
          | map(if .observed == 0 then . else . + {promotion: (
              "\(.observed) episode(s) in \(.observed_sessions) session(s), \(.observed_fixed) fixed in their session" as $seen
              | if .observed < 10 or .observed_sessions < 3 then {proposal: "wait", why: "\($seen): too few to decide (10 episodes over 3 sessions needed)"}
                elif .observed_fixed * 10 > .observed * 9 then {proposal: "block", why: "\($seen). If those findings were right, not just obeyed, set docs.blocking to true"}
                else {proposal: "observe", why: "\($seen): look at the others before it blocks"} end)} end)),
        skipped: (map(select(.kind == "skipped")) | group_by(.check) | map({
          check: .[0].check, times: length, why: (map(.what) | unique)
        }))
      }' 2>/dev/null
)" || summary='{"events":0,"checks":[],"skipped":[]}'
[ -n "$summary" ] || summary='{"events":0,"checks":[],"skipped":[]}'

# The end-of-turn records of the period (#110): how many, by outcome, and the time checks took.
hist="$(sh_state_path)/evidence-history.jsonl"
turns="$({ [ -f "$hist" ] && cat "$hist"; } | jq -sc --arg since "$since" '
  map(select(type == "object" and (.time // "") >= $since))
  | {records: length, outcomes: (group_by(.outcome) | map({(.[0].outcome): length}) | add // {}),
     seconds: ([.[].checks[]?.seconds // 0] | add // 0)}' 2>/dev/null)"
[ -n "$turns" ] || turns='{"records":0,"outcomes":{},"seconds":0}'
summary="$(printf '%s' "$summary" | jq -c --argjson turns "$turns" '. + {turns: $turns}')"

if [ "$json" = true ]; then
  printf '%s\n' "$summary" | jq --arg since "$since" '{since: $since} + .'
  exit 0
fi

if [ "$html" = true ]; then
  evidence="$(sh_state_path)/evidence.json"
  ev='null'
  [ -f "$evidence" ] && ev="$(jq -c . "$evidence" 2>/dev/null || echo null)"
  # With no log yet the first command must still succeed: under pipefail, the fallback below would
  # add a second [] to the one jq printed.
  recent="$({ [ ! -f "$log" ] || cat "$log"; } | jq -sc --arg since "$since" 'map(select(type == "object" and (.time // "") >= $since)) | .[-50:] | reverse' 2>/dev/null || echo '[]')"
  out_dir="$SH_ROOT/.build/swift-harness"
  # The scripts change no file outside the project (SECURITY.md), and a link could lead there.
  for path in "$SH_ROOT/.build" "$out_dir" "$out_dir/report.html"; do
    [ ! -L "$path" ] || { echo "report: $path is a link, so the page could land outside the project. Nothing written." >&2; exit 1; }
  done
  mkdir -p "$out_dir" || { echo "report: cannot write $out_dir" >&2; exit 1; }
  jq -nr --argjson summary "$summary" --argjson ev "$ev" --argjson recent "${recent:-[]}" \
    --arg root "$SH_ROOT" --arg label "$label" --arg now "$(sh_identity)" \
    --arg head "$(git -C "$SH_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
    --arg made "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg log "$log" --arg evfile "$evidence" -f "$(dirname "$0")/report-html.jq" \
    >"$out_dir/report.html" || { echo "report: could not write the page" >&2; exit 1; }
  printf '%s\n' "$out_dir/report.html"
  exit 0
fi

printf '%s\n' "$summary" | jq -r --arg label "$label" --arg root "$SH_ROOT" '
  def n($k): [.checks[] | .[$k]] | add // 0;
  def part($v; $word): if $v > 0 then ["\($v) \($word)"] else [] end;
  "swift-harness report for \($root), \($label):",
  (if .turns.records > 0 then "End of turn: \(.turns.records) record(s) (\(.turns.outcomes | to_entries | map("\(.value) \(.key)") | join(", "))); the checks that ran took \(.turns.seconds) s." else empty end),
  (if .events == 0 then "Nothing in the catch log: no check blocked, reported, asked or was skipped."
   else
     "\(n("blocked")) block(s), \(n("reported")) report(s), \(n("asked")) question(s) before an edit; \(n("fixed")) fixed by Claude, \(n("left_failing")) left failing, \(n("approved")) approval(s) by you.",
     (if (.checks | length) > 0 then "Caught:" else empty end),
     (.checks[] | "- \(.check): " + ((part(.blocked; "blocked") + part(.reported; "reported") + part(.asked; "asked")
        + part(.unstable; "unstable (failed once, passed on a rerun)") + part(.fixed; "fixed by Claude") + part(.left_failing; "left failing") + part(.approved; "approved by you")) | join(", "))
        + (if .last then ". Last: \(.last)" else "" end)),
     (if any(.checks[]; .promotion) then "In observation (recorded, never blocking):" else empty end),
     (.checks[] | select(.promotion) | "- \(.check): \(.promotion.why).")
     ,
     (if (.skipped | length) > 0 then "Not checked:" else empty end),
     (.skipped[] | "- \(.check): \(.times) time(s), \(.why | join("; "))")
   end)'
