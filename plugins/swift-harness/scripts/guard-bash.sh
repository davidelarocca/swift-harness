#!/bin/bash
# PreToolUse (Bash), opt-in with "guardBash": true (#135): ask the user before a shell command
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
[ "$(sh_cfg '.guardBash' 'false')" = "true" ] || exit 0

cmd="$(sh_in '.tool_input.command')"
[ -n "$cmd" ] || exit 0

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
  re="${B}(g?sed|perl)$ARGS[[:space:]](-[[:alnum:]]*i|--in-place)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # a command that removes, moves, creates or links it
  re="${B}(rm|rmdir|mv|unlink|truncate|shred|touch|ln)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # a copy onto it: the path is the last argument
  re="${B}(cp|install|rsync|ditto)$ARGS$p$WORD[\"']?[[:space:]]*(\$|[|;&)])"; [[ "$cmd" =~ $re ]] && return 0
  # git putting it back, removing or moving it
  re="${B}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(checkout|restore|rm|mv|reset|clean|stash)$ARGS$p$R"; [[ "$cmd" =~ $re ]] && return 0
  # an inline script that writes files and holds the path as a string of its own ('docs/X.md',
  # Path("docs/X.md")), not only inside a longer text it writes somewhere else
  re="[\"']($WORD/)?$t(/$WORD)?[\"']"; [[ "$cmd" =~ $re ]] && [[ "$cmd" =~ $SCRIPT_WRITE ]] && return 0
  return 1
}

escape() { printf '%s' "$1" | sed 's#[][\.*^$+?(){}|]#\\&#g'; }

hit=""
while IFS= read -r protected; do
  [ -n "$protected" ] || continue
  [[ "$protected" == *"{{"* ]] && continue
  protected="${protected#./}"
  protected="${protected%/}"
  [ -n "$protected" ] || continue
  if writes "$(escape "$protected")"; then hit="$protected"; break; fi
done < <(
  jq -r '.protectedPaths[]? | strings' "$SH_CONFIG" 2>/dev/null
  sh_snapshots; echo
  sh_performance; echo
)
if [ -z "$hit" ] && [ "$(sh_cfg '.guardPbxproj' 'true')" = "true" ] &&
  writes "$WORD[.]pbxproj"; then
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
