#!/bin/bash
# Time candidate verify commands (#104 timing step, #108). This RUNS the project's commands:
# the setup skill asks the user first, and nothing else calls it.
#
#   time-commands.sh [--project DIR] [--runs N] [--budget SECONDS] [--json] -- "<command>"...
#
# Each command runs N times (default 2: the first is usually cold, then warm) in the project
# folder, with its output discarded; the time is wall-clock seconds (bash's time, to the
# millisecond). It reports each command's runs, median and worst time and exit codes, and
# proposes a split under the end-of-turn budget (default 120 s): "fast" takes the commands in
# the order given while their worst times fit the budget, "full" takes them all. A command that
# fails is reported and left out of the proposal.
#
# The script writes nothing itself; the commands may write what they always write (.build, a
# DerivedData folder).
#
# Exit 0: printed. Exit 2: usage.

set -uo pipefail
export LC_ALL=C

usage() {
  echo 'usage: time-commands.sh [--project DIR] [--runs N] [--budget SECONDS] [--json] -- "<command>"...' >&2
  exit 2
}
dir="."
runs=2
budget=120
json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --runs) [ $# -ge 2 ] || usage; case "$2" in '' | *[!0-9]* | 0) usage ;; esac; runs="$2"; shift 2 ;;
    --budget) [ $# -ge 2 ] || usage; case "$2" in '' | *[!0-9]* | 0) usage ;; esac; budget="$2"; shift 2 ;;
    --json) json=true; shift ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
command -v jq >/dev/null 2>&1 || { echo "time-commands: jq is required (brew install jq)." >&2; exit 2; }
root="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "time-commands: no such folder: $dir" >&2; exit 2; }

results="[]"
for cmd in "$@"; do
  times="[]"; codes="[]"
  i=0
  while [ "$i" -lt "$runs" ]; do
    i=$((i + 1))
    t="$( { TIMEFORMAT=%R; time (cd "$root" && bash -c "$cmd" >/dev/null 2>&1 </dev/null; echo "exit=$?" >&3); } 3>&1 2>&1 )"
    code="$(printf '%s\n' "$t" | sed -n 's/^exit=//p' | tail -1)"
    secs="$(printf '%s\n' "$t" | grep -E '^[0-9]+\.[0-9]+$' | tail -1)"
    times="$(jq -c --argjson s "${secs:-0}" '. + [$s]' <<<"$times")"
    codes="$(jq -c --argjson c "${code:-1}" '. + [$c]' <<<"$codes")"
  done
  results="$(jq -c --arg cmd "$cmd" --argjson times "$times" --argjson codes "$codes" '
    . + [{command: $cmd, times: $times, exits: $codes,
          median: ($times | sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end),
          worst: ($times | max), ok: ($codes | all(. == 0))}]' <<<"$results")"
done

report="$(jq -c --argjson budget "$budget" --arg root "$root" --argjson runs "$runs" '
  . as $r
  | (reduce ($r[] | select(.ok)) as $c ({fast: [], total: 0, stop: false};
      if .stop or (.total + $c.worst) > $budget then .stop = true
      else .fast += [$c.command] | .total += $c.worst end)) as $f
  | {project: $root, runs: $runs, budget: $budget, commands: $r,
     proposal: {fast: $f.fast, fast_worst: ($f.total * 1000 | round / 1000),
                full: [$r[] | select(.ok) | .command], failed: [$r[] | select(.ok | not) | .command]}}' <<<"$results")"

if [ "$json" = true ]; then printf '%s\n' "$report" | jq .; exit 0; fi
printf '%s\n' "$report" | jq -r '
  "Timed \(.commands | length) command(s) in \(.project), \(.runs) run(s) each (the first is usually cold):",
  "",
  "| Command | Runs (s) | Median | Worst | Exit |", "|---|---|---|---|---|",
  (.commands[] | "| `\(.command)` | \(.times | map(tostring) | join(", ")) | \(.median) | \(.worst) | \(.exits | map(tostring) | join(", ")) |"),
  "",
  "Proposed split, end-of-turn budget \(.budget) s:",
  "- fast: \(if (.proposal.fast | length) == 0 then "none fits the budget: choose a quicker command (a build, or a filtered test run)" else (.proposal.fast | join(" && ")) + " (worst \(.proposal.fast_worst) s)" end)",
  "- full: \(.proposal.full | join(" && "))",
  (if (.proposal.failed | length) > 0 then "- failed, left out: \(.proposal.failed | join(", ")): fix them, or check that they run from the project root" else empty end)'
