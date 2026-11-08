#!/bin/bash
# Stop: the branch scope contract (#72). A long-running branch (a port) must change only its
# own files and take the base branch's work, never push shared files the other way. With
# "scope" in .claude/swift-harness.json:
#
#   "scope": [{"branch": "ios-port", "paths": ["App-iOS/", "Sources/Shared/Platform/"], "base": "main"}]
#
# ("branch" may end with * for a prefix, "base" defaults to main), at the end of a turn on a
# matching branch: the files changed on the branch since it left the base, committed or not
# (shell changes included), that are outside "paths"; and the base's commits not merged into
# the branch yet. Each is said once until it changes, to the user and to Claude. Never blocks.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0
git -C "$SH_ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
branch="$(git -C "$SH_ROOT" symbolic-ref --short -q HEAD 2>/dev/null)" || exit 0
[ -n "$branch" ] || exit 0

entry="$(jq -c --arg b "$branch" '
  [.scope[]? | select(type == "object" and (.branch | type) == "string")
   | .branch as $p | select($p == $b or (($p | endswith("*")) and ($b | startswith($p | rtrimstr("*")))))]
  | first // empty' "$SH_CONFIG" 2>/dev/null)"
[ -n "$entry" ] || exit 0
base="$(jq -r '.base // "main"' <<<"$entry")"
git -C "$SH_ROOT" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || exit 0
state="$(sh_state_dir)" || exit 0
sess="$(sh_session_dir "$state")" || exit 0

fork="$(git -C "$SH_ROOT" merge-base "$base" HEAD 2>/dev/null)" || exit 0
changed="$({ git -C "$SH_ROOT" diff --name-only "$fork" 2>/dev/null
  git -C "$SH_ROOT" ls-files --others --exclude-standard 2>/dev/null; } | sort -u | grep -v '^$')"
outside="$(printf '%s\n' "$changed" | jq -Rr --argjson e "$entry" '
  select(length > 0) as $f
  | if any($e.paths[]? | strings; . as $p | $f == ($p | rtrimstr("/")) or ($f | startswith(($p | rtrimstr("/")) + "/")))
    then empty else $f end')"
behind="$(git -C "$SH_ROOT" rev-list --count "HEAD..$base" 2>/dev/null || echo 0)"

msg=""
if [ -n "$outside" ]; then
  key="$(printf '%s' "$outside" | shasum | cut -d' ' -f1)"
  if [ "$key" != "$(cat "$sess/scope-outside" 2>/dev/null)" ]; then
    printf '%s' "$key" >"$sess/scope-outside"
    n="$(printf '%s\n' "$outside" | grep -c .)"
    msg="swift-harness: branch $branch changed $n file(s) outside its scope ($(jq -r '.paths | join(", ")' <<<"$entry")) since it left $base:
$(printf '%s\n' "$outside" | head -15 | sed 's/^/- /')$([ "$n" -le 15 ] || printf '\n- and %s more' "$((n - 15))")
Shared files change on $base and come into this branch by merging $base, never the other way. Revert them here unless the user asked for the change."
    sh_catch "branch scope" reported "$n file(s) outside the scope of $branch"
  fi
fi
if [ "${behind:-0}" -gt 0 ] && [ "$behind" != "$(cat "$sess/scope-behind" 2>/dev/null)" ]; then
  printf '%s' "$behind" >"$sess/scope-behind"
  msg="${msg:+$msg
}swift-harness: $base has $behind commit(s) not merged into $branch yet. Merge $base into $branch when the user agrees."
fi
[ -n "$msg" ] || exit 0
jq -n --arg msg "$msg" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $msg}}'
exit 0
