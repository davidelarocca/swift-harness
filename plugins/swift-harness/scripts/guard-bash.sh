#!/bin/bash
# PreToolUse (Bash). Three checks on the text of a shell command.
#
# 1. The commit identity, on unless "guardCommitIdentity" is false: a command that writes a
#    commit (git commit, merge, pull, cherry-pick, revert, rebase, am) is denied while the
#    identity is git's automatic one, <account>@<host name> (lib.sh, sh_git_identity). The
#    folder is the one of git -C, of a cd earlier in the command, or the session's. A command
#    that gives the identity itself (-c user.email=..., GIT_COMMITTER_EMAIL=...) is let through.
#
# 2. With "snapshots": {"pending": "collect"}: ask the user before a `git commit` in this
#    repository while snapshot images wait for approval. Collected images do not fail their
#    tests, so this is where the approval is asked, once for all of them. The user can approve
#    them first (/swift-harness:approve-snapshots) or let the commit go on.
#
# 3. Opt-in with "guardBash": true (#135): ask the user before a shell command
# that writes to a protected path, as guard.sh does for the Edit, Write and MultiEdit tools.
# The areas are guard.sh's: protectedPaths, project.pbxproj (unless guardPbxproj is false) and
# the snapshot and performance baselines.
#
# The command is read as text. It asks when the command names one of those paths together with a
# write: a redirect (> or >>) or tee into it, sed -i or perl -i on it, rm, mv, touch, ln or
# truncate on it, cp, install, rsync or ditto onto it (the last argument), git checkout,
# restore, rm, mv, reset, clean or stash on it, or an inline script that writes files
# (write_text, open(..., "w"), os.replace, shutil.move, writeFileSync...). Reading a protected
# path (cat, grep, git diff, cp from it) never asks. A path built at run time, a cd before a
# relative path, or a script file that writes are not seen: a convenience that asks first, not
# a guarantee. protected-watch.sh still reports every change at the end of the turn.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0

cmd="$(sh_in '.tool_input.command')"
[ -n "$cmd" ] || exit 0

# ---------- 1. the commit identity ----------

# git, its options before the subcommand, and a subcommand that writes a commit.
GIT_OPTION="[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?|-[a-zA-Z])"
COMMITS="(^|[^[:alnum:]_.-])git($GIT_OPTION)*[[:space:]]+(commit|merge|pull|cherry-pick|revert|rebase|am)([[:space:];&|)]|\$)"
GIVEN="(user[.]email=|GIT_COMMITTER_EMAIL=)"
found=""
[[ "$cmd" =~ $COMMITS ]] && found="${BASH_REMATCH[0]}"
# The folder a git command found in the command ($1, the text matched) works in: the one of
# git -C, of a cd earlier in the command, or the session's. Nothing when it is not a folder (named
# through a variable, or created by the command first): it is not there to ask.
commit_dir() {
  local found="$1" before dir="" re here
  before="${cmd%%"$found"*}"
  re="-C[[:space:]]+([^[:space:]]+)"
  if [[ "$found" =~ $re ]]; then
    dir="${BASH_REMATCH[1]}"
  else
    re="(^|[;&|({[:space:]])cd[[:space:]]+([^[:space:];&|)]+)"
    [[ "$before" =~ $re ]] && dir="${BASH_REMATCH[2]}"
  fi
  dir="${dir#[\"\']}"
  dir="${dir%[\"\']}"
  dir="${dir/#\~/$HOME}"
  here="$(sh_in '.cwd')"
  [ -n "$here" ] || here="$SH_ROOT"
  case "$dir" in "") dir="$here" ;; /*) ;; *) dir="$here/$dir" ;; esac
  [ -d "$dir" ] && printf '%s' "$dir"
}
if [ -n "$found" ] && [ "$(sh_cfg '.guardCommitIdentity' 'true')" != "false" ] && ! [[ "$cmd" =~ $GIVEN ]]; then
  dir="$(commit_dir "$found")"
  why=""
  [ -z "$dir" ] || why="$(sh_git_identity "$dir")"
  if [ -n "$why" ]; then
    reason="swift-harness: this command writes a commit, and $why. A commit keeps that for good: once pushed it leaves only by rewriting history. Do not run it, and do not give an identity yourself, in the command or in git config. Stop and tell the user to set theirs: git config --global user.name \"<name>\" and git config --global user.email \"<address>\" (on GitHub, the noreply address in Settings > Emails keeps their own private). To turn this check off: \"guardCommitIdentity\": false in .claude/swift-harness.json."
    sh_catch "commit identity" blocked "a commit with git's automatic identity"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

# ---------- 2. a commit while snapshot images wait ----------

COMMIT="(^|[^[:alnum:]_.-])git($GIT_OPTION)*[[:space:]]+commit([[:space:];&|)]|\$)"
if [[ "$cmd" =~ $COMMIT ]] && sh_snapshots_collect; then
  dir="$(commit_dir "${BASH_REMATCH[0]}")"
  waiting=""
  # Only a commit in the repository of this project: its images say nothing about another one.
  if [ -n "$dir" ] && [ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" = "$(git -C "$SH_ROOT" rev-parse --show-toplevel 2>/dev/null)" ]; then
    waiting="$(sh_snapshots_waiting_text)"
  fi
  if [ -n "$waiting" ]; then
    reason="swift-harness: $waiting, and this command commits. They did not fail their tests (snapshots.pending is \"collect\"), so nobody has looked at them yet: the commit would hold code whose images differ from the approved ones. Approve them first with /swift-harness:approve-snapshots (it opens a page with each image), or let this commit go on and approve later: scripts/verify.sh full fails until then."
    sh_catch "snapshot images" asked "$waiting: before a commit"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

# ---------- 3. protected paths ----------

[ "$(sh_cfg '.guardBash' 'false')" = "true" ] || exit 0

# A path token: it starts the command or follows a space, a quote, = ( or / (an absolute path or
# ./), and ends at a space, a quote, a separator or a slash (a file under a protected folder).
L="(^|[[:space:]\"'=(/])"
R="([[:space:]\"'/);,|&<>]|$)"
# The name of a command: not part of a longer word.
B="(^|[^[:alnum:]_.-])"

# Parts of a regex: text up to the next separator, and the characters of one path word.
SEG=$'[^|;&\n]*'
# The arguments between a command's name and a path, if any: the space before the path stays
# for the path's own boundary.
ARGS="([[:space:]]$SEG)?"
WORD="[^[:space:]\"'|;&<>]*"
SCRIPT_WRITE="(write_text|write_bytes|writeFile|appendFile|os[.](replace|rename|remove|unlink)|shutil[.](move|copy|copyfile|copy2|rmtree)|[.]unlink[(]|[.]rename[(]|File[.]write|fs[.](rm|unlink)|open[(][^)]*[\"'](w|a|x|r[+]|w[+]|a[+])b?[\"'])"

# "$1" is a regex for one protected path (its text escaped, or the pbxproj pattern).
writes() {
  local t="$1" p="$L$1" re
  # a redirect or tee into it
  re=">>?[|]?[[:space:]]*[\"']?($WORD/)?$t$R"; [[ "$cmd" =~ $re ]] && return 0
  re="${B}tee$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # an in-place edit
  re="${B}(g?sed|perl)${ARGS}[[:space:]](-[[:alnum:]]*i|--in-place)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # a command that removes, moves, creates or links it
  re="${B}(rm|rmdir|mv|unlink|truncate|shred|touch|ln)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # a copy onto it: the path is the last argument
  re="${B}(cp|install|rsync|ditto)$ARGS$p${WORD}[\"']?[[:space:]]*(\$|[|;&)])"; [[ "$cmd" =~ $re ]] && return 0
  # git putting it back, removing or moving it
  re="${B}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(checkout|restore|rm|mv|reset|clean|stash)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # an inline script that writes files and holds the path as a string of its own ('docs/X.md',
  # Path("docs/X.md")), not only inside a longer text it writes somewhere else
  re="[\"']($WORD/)?$t(/$WORD)?[\"']"; [[ "$cmd" =~ $re ]] && [[ "$cmd" =~ $SCRIPT_WRITE ]] && return 0
  return 1
}

escape() { printf '%s' "$1" | sed 's#[][\.*^$+?(){}|]#\\&#g'; }

# Every path is read first, then looked at (#167): stopping at the first match while the list was
# still being written left a writer on a closed pipe, and where SIGPIPE is ignored (CI runners)
# it printed "write error: Broken pipe".
candidates="$(
  jq -r '.protectedPaths[]? | strings' "$SH_CONFIG" 2>/dev/null
  sh_snapshots; echo
  sh_performance; echo
)"
hit=""
while IFS= read -r protected; do
  [ -n "$protected" ] || continue
  [[ "$protected" == *"{{"* ]] && continue
  protected="${protected#./}"
  protected="${protected%/}"
  [ -n "$protected" ] || continue
  if writes "$(escape "$protected")"; then hit="$protected"; break; fi
done <<<"$candidates"
if [ -z "$hit" ] && [ "$(sh_cfg '.guardPbxproj' 'true')" = "true" ] &&
  writes "${WORD}[.]pbxproj"; then
  hit="project.pbxproj"
fi
[ -n "$hit" ] || exit 0

reason="swift-harness: this shell command seems to write to $hit, a protected area (guardBash in .claude/swift-harness.json). Approve only if this change was explicitly requested and planned."
sh_catch "shell guard" asked "$hit: ${reason#swift-harness: }"
jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $reason
  }
}'
exit 0
