#!/bin/bash
# Stop: tell the user when files under the protected paths changed since this session started,
# outside this session's Edit and Write tools (#11). The change may come from another session or
# agent on the same checkout: a change already in a commit names that commit (#135). The guard asks before Claude edits them with those tools;
# a shell command (sed, cp, mv, rm, a script, a build step) is not asked about. This reports
# it afterwards: detection, not prevention. Claude Code permission rules are the way to block
# writes. Never blocks. The session-start list is taken by session-start.sh; edits made
# through the guarded tools are recorded by post-edit.sh.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0
export LC_ALL=C
state="$(sh_state_dir)" || exit 0
sess="$(sh_session_path "$state")"
messages=""

# Security approvals made in this session (#32): the approval script can be run by anyone with
# a shell, so the user sees every approval and can tell whether it was theirs.
reviewed_now=false
[ -f "$sess/security-start-unreviewed" ] && [ ! -f "$state/security-unreviewed" ] && reviewed_now=true
if [ -f "$sess/security-start" ] && [ -f "$state/security-approved" ] && { ! cmp -s "$sess/security-start" "$state/security-approved" || [ "$reviewed_now" = true ]; }; then
  approved_diff="$(diff "$sess/security-start" "$state/security-approved" | sed -n -e 's/^> /+ /p' -e 's/^< /- /p')"
  [ "$reviewed_now" = false ] || approved_diff="${approved_diff:+$approved_diff
}(the baseline recorded automatically at the first session was marked as reviewed)"
  sum="$(printf '%s' "$approved_diff" | shasum | cut -d' ' -f1)"
  if [ "$sum" != "$(cat "$sess/security-approval-warned" 2>/dev/null)" ]; then
    printf '%s' "$sum" >"$sess/security-approval-warned"
    messages="swift-harness: the security settings baseline was approved in this session:
$(printf '%s\n' "$approved_diff" | head -15)
If you did not type /swift-harness:approve-security yourself, this approval did not come from you: check the changes (/swift-harness:doctor, git diff) and approve again only what you agree with."
  fi
fi

# An end-of-turn check of this session that started and never ended (#144): stop-verify.sh found
# its marker and left it here. Said once.
if [ -s "$sess/unfinished" ]; then
  u_start="$(sed -n 2p "$sess/unfinished")"
  case "$u_start" in '' | *[!0-9]*) u_when="" ;; *) u_when=" (it started at $(date -r "$u_start" '+%H:%M' 2>/dev/null || echo '?'))" ;; esac
  rm -f "$sess/unfinished"
  messages="${messages:+$messages

}swift-harness: an end-of-turn check of this session did not finish$u_when: the hook was stopped before its result, usually by its timeout of 900 s, so that code was not verified by it. If it happens again, make the fast check shorter (/swift-harness:doctor times it) or run it yourself."
fi

start="$sess/protected-start"
if [ ! -f "$start" ]; then # no list for this session
  [ -z "$messages" ] || jq -n --arg msg "$messages" '{systemMessage: $msg}'
  exit 0
fi

now="$(mktemp -t swift-harness-protected.XXXXXX)"
sh_protected_list >"$now"

# Lines "<sha> <path>" present now and not at the start (added or changed), minus the states
# left by a guarded edit; paths present at the start and gone now (deleted).
changed="$(comm -13 "$start" "$now" | { if [ -f "$sess/protected-edited" ]; then grep -vxF -f "$sess/protected-edited"; else cat; fi; } | cut -d' ' -f2-)"
deleted="$(comm -23 <(cut -d' ' -f2- "$start" | sort -u) <(cut -d' ' -f2- "$now" | sort -u))"
rm -f "$now"
if [ -z "$changed$deleted" ]; then
  [ -z "$messages" ] || jq -n --arg msg "$messages" '{systemMessage: $msg}'
  exit 0
fi

# #135: name the commit that holds a change made since the session started, so the user can tell
# another session's committed work from an unexpected edit. Nothing is added without a commit.
head="$(cat "$sess/session-head" 2>/dev/null)"
[ -n "$head" ] && git -C "$SH_ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1 || head=""
annotate() { # $1 kind (changed or deleted), the paths on stdin
  local p c
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    c=""
    [ -z "$head" ] || c="$(git -C "$SH_ROOT" log -1 --format='%h: %s' "$head..HEAD" -- "$p" 2>/dev/null | cut -c1-100)"
    if [ -z "$c" ]; then
      printf '  %s: %s\n' "$1" "$p"
    elif [ -n "$(git -C "$SH_ROOT" status --porcelain -- "$p" 2>/dev/null)" ]; then
      printf '  %s: %s (committed in %s; changed again since, not committed)\n' "$1" "$p" "$c"
    else
      printf '  %s: %s (committed in %s)\n' "$1" "$p" "$c"
    fi
  done
}
report="$(
  [ -n "$changed" ] && printf '%s\n' "$changed" | annotate changed
  [ -n "$deleted" ] && printf '%s\n' "$deleted" | annotate deleted
)"
sum="$(printf '%s' "$report" | shasum | cut -d' ' -f1)"
if [ "$sum" = "$(cat "$sess/protected-warned" 2>/dev/null)" ]; then
  [ -z "$messages" ] || jq -n --arg msg "$messages" '{systemMessage: $msg}'
  exit 0
fi
printf '%s' "$sum" >"$sess/protected-warned"

sh_catch "protected paths" reported "$(printf '%s\n' "$report" | grep -c .) protected file(s) changed outside Edit and Write"
note=""
case "$report" in *"(committed in "*) note="
A change already in a commit may come from another session or agent working on this checkout." ;; esac
msg="swift-harness: protected files changed since this session started, not through this session's Edit or Write, so you were not asked first:
$(printf '%s\n' "$report" | head -20)$note
Check them (git diff -- <file>, or git show <commit>) and restore any change you did not ask for (git checkout -- <file>, or git revert <commit>)."
jq -n --arg msg "${messages:+$messages

}$msg" '{systemMessage: $msg}'
exit 0
