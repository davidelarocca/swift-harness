#!/bin/bash
# Stop: block the end of a turn when the docs gained a broken reference in this session (#70):
# a link, a path or a section that does not exist, an import of a missing file, or the files
# read into every session over their budget. docs.sh reads Markdown only, so this runs without
# the verify approval and does not touch the verify fingerprint: editing docs never re-runs
# the build. Problems already there when the session started are not new: doctor reports them,
# the turn is not blocked. Blocks once per set of new problems; if Claude stops again without
# fixing them, the user is told instead. The session-start list is taken by session-start.sh.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0
sh_docs_on || exit 0
# The project's own docs check runs instead, from stop-verify.sh (#105).
[ -z "$(sh_docs_command)" ] || exit 0
state="$(sh_state_dir)" || exit 0
sess="$(sh_session_dir "$state")" || exit 0

out="$("$(dirname "$0")/docs.sh" check "$SH_ROOT" 2>&1)"
code=$?
start="$sess/docs-start"
if [ ! -f "$start" ]; then
  # The session started before this check was installed: what is there now is its start.
  printf '%s\n' "$out" | sh_docs_keys >"$start"
  exit 0
fi
if [ "$code" -ne 1 ]; then
  rm -f "$sess/docs-blocked" "$sess/docs-warned"
  exit 0
fi

new="$(printf '%s\n' "$out" | sh_docs_keys | LC_ALL=C comm -23 - "$start")"
if [ -z "$new" ]; then
  # Catch log (#86): problems that blocked are gone.
  if [ -s "$sess/docs-blocked" ]; then sh_catch "docs references" fixed "the references broken in this session were fixed"; rm -f "$sess/docs-blocked"; fi
  exit 0
fi
lines="$(printf '%s\n' "$out" | grep '^- ' | while IFS= read -r l; do
  k="$(printf '%s\n' "$l" | sh_docs_keys)"
  printf '%s\n' "$new" | grep -qxF -- "$k" && printf '%s\n' "$l"
done)"
sum="$(printf '%s' "$new" | shasum | cut -d' ' -f1)"

if [ "$sum" = "$(cat "$sess/docs-blocked" 2>/dev/null)" ]; then
  [ "$sum" = "$(cat "$sess/docs-warned" 2>/dev/null)" ] && exit 0
  printf '%s' "$sum" >"$sess/docs-warned"
  sh_catch "docs references" left-failing "Claude stopped without fixing them; the user was told"
  jq -n --arg msg "swift-harness: references broken in this session are still in the docs; Claude stopped without fixing them:
$(printf '%s\n' "$lines" | head -20)" '{systemMessage: $msg}'
  exit 0
fi

printf '%s' "$sum" >"$sess/docs-blocked"
sh_catch "docs references" blocked "$(printf '%s\n' "$lines" | grep -c .) reference(s) broken in this session"
{
  printf 'Docs references broken in this session:\n'
  printf '%s\n' "$lines" | head -40
  printf '\nFix the docs, or the reference, then finish. If a file or section is named before it exists on purpose, say so in one line and stop again without editing: the check does not block twice on the same problems.\n'
} >&2
exit 2
