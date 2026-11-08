#!/bin/bash
# One engine for every agent (#106): the end-of-turn check, run from a shell, a git hook, CI or
# another agent (Codex), with the same approval, the same evidence record and the same catch
# log as Claude Code's Stop hook.
#
#   check.sh [--project DIR] [--agent NAME] [--strict] [--json]
#
# It runs stop-verify.sh as the Stop hook does, as a session named "agent-<NAME>" (default
# "agent-cli"), so its results are told apart in the record and the log. The verify command
# runs only if the user approved it (/swift-harness:approve-verify): the same approval the hook
# uses, in the plugin's data folder. CLAUDE_PLUGIN_DATA names it; without it, the folder is the
# only ~/.claude/plugins/data/swift-harness-* one, or the one that holds this project's
# approval.
#
# Like the hook, it does not run the same checks again on code that already passed: it reports
# that. The scope contract (#72) is checked too, as information.
#
# Exit 0: passed (or passed before on this code). That includes a partial result (a platform was
# not checked) and an unstable one (it failed once, then passed on a rerun): the output says so,
# by name, and --json has it in "result"; --strict exits 4 for them instead. Exit 1: a check
# failed. Exit 3: the verify command did not run (not approved, or turned off), so the build and
# tests are not verified. Exit 2: usage, no swift-harness config, or no data folder found.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: check.sh [--project DIR] [--agent NAME] [--strict] [--json]" >&2
  exit 2
}
dir="$PWD"
agent="cli"
json=false
strict=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --agent) [ $# -ge 2 ] && [ -n "$2" ] || usage; agent="$2"; shift 2 ;;
    --json) json=true; shift ;;
    --strict) strict=true; shift ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "check: jq is required (brew install jq)." >&2; exit 2; }
dir="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "check: no such folder." >&2; exit 2; }
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || root="$dir"
root="$(cd "$root" && pwd -P)"
[ -f "$root/.claude/swift-harness.json" ] || { echo "check: no .claude/swift-harness.json in $root." >&2; exit 2; }
session="agent-$(printf '%s' "$agent" | LC_ALL=C tr -cd 'A-Za-z0-9_-' | cut -c1-40)"

# The data folder the hooks use, where the approval is.
key="$(printf '%s' "$root" | shasum | cut -c1-16)"
if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
  candidates="$(ls -d "$HOME"/.claude/plugins/data/swift-harness-* 2>/dev/null)"
  if [ "$(printf '%s\n' "$candidates" | grep -c .)" -eq 1 ]; then
    CLAUDE_PLUGIN_DATA="$candidates"
  else
    CLAUDE_PLUGIN_DATA="$(printf '%s\n' "$candidates" | while IFS= read -r d; do
      [ -n "$d" ] && [ -f "$d/state/$key/verify-approved" ] && { printf '%s' "$d"; break; }; done)"
  fi
  [ -n "$CLAUDE_PLUGIN_DATA" ] || {
    if [ -z "$candidates" ]; then
      echo "check: no plugin data folder in ~/.claude/plugins/data: approve the verify command in Claude Code first, or set CLAUDE_PLUGIN_DATA to the folder that holds the approval." >&2
    else
      echo "check: cannot tell which plugin data folder the hooks use. Set CLAUDE_PLUGIN_DATA (one of: $(printf '%s\n' "$candidates" | paste -sd' ' -))." >&2
    fi
    exit 2
  }
fi
export CLAUDE_PLUGIN_DATA
export SH_AGENT="$agent"
state="$CLAUDE_PLUGIN_DATA/state/$key"

input="$(jq -nc --arg cwd "$root" --arg session "$session" '{cwd: $cwd, session_id: $session, hook_event_name: "Stop"}')"
out="$(mktemp -t swift-harness-check.XXXXXX)"
err="$(mktemp -t swift-harness-check.XXXXXX)"
trap 'rm -f "$out" "$err"' EXIT
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$root" "$here/stop-verify.sh" >"$out" 2>"$err"
code=$?
scope="$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$root" "$here/scope-watch.sh" 2>/dev/null | jq -r '.systemMessage // empty' 2>/dev/null)"
notice="$(jq -r '.systemMessage // empty' "$out" 2>/dev/null)"
record="$(cat "$state/evidence.json" 2>/dev/null)"

# Verified means the configured verify command passed (or partly passed) on this code, now or
# before: the record says, by name.
command_line="$(jq -r '.verify.command // "scripts/verify.sh fast"' "$root/.claude/swift-harness.json" 2>/dev/null)"
verified=false
printf '%s' "$record" | jq -e --arg c "$command_line" 'any(.checks[]?; .name == $c and (.result == "passed" or .result == "partial"))' >/dev/null 2>&1 && verified=true
if [ "$code" -eq 2 ]; then result=1
elif [ "$verified" = true ]; then result=0
elif printf '%s' "$record" | jq -e '.outcome == "failed"' >/dev/null 2>&1; then result=1
else result=3; fi

# What passing means here, by name: an exit status alone cannot tell (SH180-R01, SH180-R02).
case "$result" in
  1) word=failed ;;
  3) word=not-run ;;
  *)
    word=passed
    if printf '%s' "$record" | jq -e --arg c "$command_line" 'any(.checks[]?; .name == $c and .result == "partial")' >/dev/null 2>&1; then word=partial
    elif printf '%s' "$record" | jq -e '.stability == "unstable"' >/dev/null 2>&1; then word=unstable; fi
    ;;
esac
[ "$strict" = false ] || [ "$result" -ne 0 ] || [ "$word" = passed ] || result=4

if [ "$json" = true ]; then
  jq -n --argjson record "${record:-null}" --arg agent "$agent" --argjson exit "$result" --arg word "$word" --argjson strict "$strict" --arg notice "$notice" --arg scope "$scope" \
    --rawfile failure "$err" '{agent: $agent, result: $word, strict: $strict, exit: $exit, record: $record}
      + (if $notice == "" then {} else {notice: $notice} end) + (if $scope == "" then {} else {scope: $scope} end)
      + (if ($failure | length) > 0 then {failure: $failure} else {} end)'
  exit "$result"
fi

printf 'swift-harness check (%s) of %s\n' "$session" "$root"
if [ -n "$record" ]; then
  printf '%s' "$record" | jq -r '"Outcome: \(.outcome)" + (if .note then " (\(.note))" else "" end),
    (.checks[] | "- \(.name): \(.result)" + (if .detail then " (\(.detail))" else "" end))'
fi
[ ! -s "$err" ] || { printf '\n'; cat "$err"; }
[ -z "$notice" ] || printf '\n%s\n' "$notice"
[ -z "$scope" ] || printf '\n%s\n' "$scope"
case "$word" in
  passed) printf '\nResult: passed.\n' ;;
  partial) printf '\nResult: PARTIAL: what ran passed, but not everything was checked.\n' ;;
  unstable) printf '\nResult: UNSTABLE: it failed once, then passed on a rerun.\n' ;;
  failed) printf '\nResult: FAILED.\n' ;;
  not-run) printf '\nResult: NOT VERIFIED: the verify command did not run.\n' ;;
esac
exit "$result"
