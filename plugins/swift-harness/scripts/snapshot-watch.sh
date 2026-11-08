#!/bin/bash
# Stop: tell the user when approved baselines changed in this session without their approval
# command: snapshot images (#9, /swift-harness:approve-snapshots) and performance numbers
# (#33, /swift-harness:approve-performance). The tests compare with these files, so a baseline
# replaced to make a test pass must not go unnoticed. The guard asks before Claude edits the
# folders with Edit or Write; this also catches shell commands (cp, mv, rm).
# Never blocks. The session-start lists are taken by session-start.sh; approvals are recorded
# by snapshots.sh and performance.sh.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0
export LC_ALL=C
state="$(sh_state_dir)" || exit 0
sess="$(sh_session_path "$state")"

# $1 kind (file prefix), $2 folder, $3 what the files are, $4 approval command, $5 what compares
# with them. Prints the message for this kind, or nothing.
watch() {
  local kind="$1" folder="$2" start="$sess/$1-start" now changed deleted report sum
  [ -f "$start" ] || return 0 # no list for this session
  now="$(mktemp -t swift-harness-baselines.XXXXXX)"
  sh_snapshot_list "$folder" >"$now"
  # Lines "<sha> <path>" present now and not at the start (added or changed), minus approved
  # ones; paths present at the start and gone now (deleted).
  changed="$(comm -13 "$start" "$now" | { if [ -f "$sess/$kind-approved" ]; then grep -vxF -f "$sess/$kind-approved"; else cat; fi; } | cut -d' ' -f2-)"
  deleted="$(comm -23 <(cut -d' ' -f2- "$start" | sort -u) <(cut -d' ' -f2- "$now" | sort -u))"
  rm -f "$now"
  [ -n "$changed$deleted" ] || return 0
  report="$(
    [ -n "$changed" ] && printf '%s\n' "$changed" | sed 's/^/  changed: /'
    [ -n "$deleted" ] && printf '%s\n' "$deleted" | sed 's/^/  deleted: /'
  )"
  sum="$(printf '%s' "$report" | shasum | cut -d' ' -f1)"
  [ "$sum" = "$(cat "$sess/$kind-warned" 2>/dev/null)" ] && return 0
  printf '%s' "$sum" >"$sess/$kind-warned"
  printf 'swift-harness: %s in %s/ changed in this session without %s:\n%s\n%s compare with these files: check the changes (git diff --stat -- %s/), and restore any you did not approve (git checkout -- <file>).' \
    "$3" "$folder" "$4" "$(printf '%s\n' "$report" | head -20)" "$5" "$folder"
}

msg="$(watch snapshots "$(sh_snapshots)" "snapshot baselines" /swift-harness:approve-snapshots "The snapshot tests")"
[ -z "$msg" ] || sh_catch "snapshot baselines" reported "baselines changed without /swift-harness:approve-snapshots"
perf="$(watch performance "$(sh_performance)" "performance baselines" /swift-harness:approve-performance "The performance budget tests")"
[ -n "$perf" ] && msg="${msg:+$msg

}$perf"
[ -n "$msg" ] || exit 0
[ -z "$perf" ] || sh_catch "performance baselines" reported "baselines changed without /swift-harness:approve-performance"
jq -n --arg msg "$msg" '{systemMessage: $msg}'
exit 0
