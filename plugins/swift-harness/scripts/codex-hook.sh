#!/bin/bash
# Codex (#122): run a swift-harness hook script from a Codex hook. Codex's hooks follow Claude
# Code's model (same events, cwd and session_id on stdin, exit 2 with the reason on stderr to
# block, systemMessage and additionalContext), with two differences handled here:
# - Codex edits files with apply_patch: the paths are inside the patch (tool_input.command), not
#   in tool_input.file_path. The guard and the post-edit hook run once per file in the patch,
#   each with a Claude-shaped input.
# - Codex cannot ask the user from PreToolUse: where the guard would ask, it denies, with a
#   reason that tells Codex to stop and ask the user first. If the user agrees, they give a
#   one-time permit for that file (allow-edit.sh), and the same patch then goes through.
# Other hooks (session start, the Stop hooks) get Codex's input as it is.
#
#   codex-hook.sh <hook script>     (stdin: the Codex hook input)
#
# SH_AGENT=codex is set, so the evidence record and the catch log name the agent.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${1:?usage: codex-hook.sh <hook script>}"
# The user's one-time permit, from their own terminal: the launcher passes it here.
if [ "$script" = --allow ]; then
  shift
  exec "$here/allow-edit.sh" "$@"
fi
[ -x "$here/$script" ] || { echo "codex-hook: no hook script $script" >&2; exit 0; }
input="$(cat)"
export SH_AGENT=codex

case "$script" in
  guard.sh | post-edit.sh) ;;
  *) printf '%s' "$input" | "$here/$script"; exit $? ;;
esac

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
patch="$(printf '%s' "$input" | jq -r '.tool_input.command // empty | strings' 2>/dev/null)"
if [ -n "$file" ]; then
  paths="$file"
elif printf '%s\n' "$patch" | grep -q '^\*\*\* Begin Patch'; then
  paths="$(printf '%s\n' "$patch" | sed -nE -e 's/^\*\*\* (Update|Add|Delete) File: (.*)$/\2/p' -e 's/^\*\*\* Move to: (.*)$/\1/p')"
else
  exit 0
fi

deny="" denied="" permitted="" ctx="" err="" blocked=false
SH_PERMIT_CWD="${cwd:-$PWD}"
SH_PERMIT_SESSION="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
export SH_PERMIT_CWD SH_PERMIT_SESSION
errf="$(mktemp -t swift-harness-codex.XXXXXX)" || exit 0
trap 'rm -f "$errf"' EXIT
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in /*) abs="$p" ;; *) abs="${cwd:-$PWD}/$p" ;; esac
  # A valid permit lets this file through. It is spent only if the whole patch goes through.
  if [ "$script" = guard.sh ] && "$here/allow-edit.sh" --check "$abs" 2>/dev/null; then
    permitted="${permitted:+$permitted
}$abs"
    continue
  fi
  one="$(printf '%s' "$input" | jq -c --arg f "$abs" '.tool_name = "Edit" | .tool_input = {file_path: $f}')"
  out="$(printf '%s' "$one" | "$here/$script" 2>"$errf")"
  code=$?
  e="$(cat "$errf" 2>/dev/null)"
  if [ "$script" = guard.sh ]; then
    r="$(printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.permissionDecision == "ask") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    [ -z "$r" ] || { deny="${deny:+$deny }$r"; denied="${denied:+$denied }$p"; }
  else
    [ "$code" -ne 2 ] || { blocked=true; err="${err:+$err
}$e"; }
    c="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    [ -z "$c" ] || ctx="${ctx:+$ctx
}$c"
  fi
done <<<"$paths"

if [ "$script" = guard.sh ]; then
  if [ -z "$deny" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] || "$here/allow-edit.sh" --use "$p" 2>/dev/null
    done <<<"$permitted"
    exit 0
  fi
  jq -n --arg r "$deny Codex cannot ask the user from a hook: do not make this edit now. Stop, tell the user which file and why. If they agree, THEY run this in their own terminal, once per file: bash .codex/swift-harness-hook.sh --allow <file> (here: $denied). Then apply the same edit again. Never run that command yourself." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi
if [ "$blocked" = true ]; then printf '%s\n' "$err" >&2; exit 2; fi
[ -z "$ctx" ] || jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
