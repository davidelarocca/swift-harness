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
  # Images accepted as new (below) are not unapproved.
  [ "$kind" != snapshots ] || [ -z "$accepted" ] || [ -z "$changed" ] ||
    changed="$(printf '%s\n' "$changed" | grep -vxF -f <(printf '%s\n' "$accepted"))"
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

# With snapshots.approveNew: files in the baselines folder that were not there at the start of
# the session and that the test recorded as approved from "new" (the image and its metadata).
accepted=""
snapshots="$(sh_snapshots)"
if sh_snapshots_approve_new && [ -f "$sess/snapshots-start" ]; then
  accepted="$(sh_snapshot_list "$snapshots" | cut -d' ' -f2- | grep -vxF -f <(cut -d' ' -f2- "$sess/snapshots-start"; echo /) |
    while IFS= read -r f; do
      [ "$(jq -r '.approvedFrom? // empty' "$SH_ROOT/${f%.*}.json" 2>/dev/null)" = new ] && printf '%s\n' "$f"
    done)"
fi
msg="$(watch snapshots "$snapshots" "snapshot baselines" /swift-harness:approve-snapshots "The snapshot tests")"
[ -z "$msg" ] || sh_catch "snapshot baselines" reported "baselines changed without /swift-harness:approve-snapshots"
perf="$(watch performance "$(sh_performance)" "performance baselines" /swift-harness:approve-performance "The performance budget tests")"
[ -n "$perf" ] && msg="${msg:+$msg

}$perf"
# The new images accepted this session that were not told yet: one line for the user, and for
# the agent the images to look at. No approval looked at them, and a baseline is what the tests
# defend from then on: a component born with a defect would be kept with it.
look=""
if [ -n "$accepted" ]; then
  told="$sess/snapshots-new-told"
  fresh="$(printf '%s\n' "$accepted" | grep '\.png$' | grep -vxF -f <(cat "$told" 2>/dev/null; echo /))"
  if [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" >>"$told"
    count="$(printf '%s\n' "$fresh" | grep -c .)"
    names="$(printf '%s\n' "$fresh" | head -8 | sed 's|.*/||; s|\.png$||' | paste -sd, - | sed 's/,/, /g')"
    [ "$count" -le 8 ] || names="$names and $((count - 8)) more"
    sh_catch "snapshot baselines" approved "$count new image(s) recorded as baselines (snapshots.approveNew)"
    msg="${msg:+$msg

}swift-harness: $count new snapshot image(s) recorded as baselines with no approval (snapshots.approveNew is true): $names. They are in $snapshots/, to commit with the change; an image that differs from its baseline still waits for /swift-harness:approve-snapshots."
    look="swift-harness: $count new snapshot image(s) became baselines with no approval (snapshots.approveNew), and the tests now keep them as they are. Look at each image before going on:
$(printf '%s\n' "$fresh" | head -20 | sed "s|^|- $SH_ROOT/|")$([ "$count" -le 20 ] || printf '\n- and %s more in %s/' "$((count - 20))" "$snapshots")
Tell the user only what looks like a defect (text clipped or overlapping, colors wrong in dark mode, a right-to-left layout not mirrored, an empty or cut image), naming the image. A defect is fixed in the code; then delete its baseline (.png and .json) so the test records it again: the user is asked before the delete. Say nothing if they look right."
  fi
fi
[ -n "$msg" ] || exit 0
[ -z "$perf" ] || sh_catch "performance baselines" reported "baselines changed without /swift-harness:approve-performance"
if [ -n "$look" ]; then
  jq -n --arg msg "$msg" --arg look "$look" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $look}}'
else
  jq -n --arg msg "$msg" '{systemMessage: $msg}'
fi
exit 0
