#!/bin/bash
# The checkpoint printed after a compaction (#10), from session-start.sh: a few lines of facts
# the hooks recorded (branch, what changed in this session, the verification result on the
# current code, what waits for the user), and the docs to reread. No transcript, no guesses.
#
#   checkpoint.sh <project root> <state folder> <verify command> <session folder>

. "$(dirname "$0")/lib.sh" </dev/null
SH_ROOT="$1"
state="$2"
verify_cmd="$3"
sess="$4"
SH_CONFIG="$SH_ROOT/.claude/swift-harness.json"
export LC_ALL=C

branch="$(git -C "$SH_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo "detached at $(git -C "$SH_ROOT" rev-parse --short HEAD 2>/dev/null)")"
start_head="$(cat "$sess/session-head" 2>/dev/null)"
commits=""
if [ -n "$start_head" ]; then
  n="$(git -C "$SH_ROOT" rev-list --count "$start_head..HEAD" 2>/dev/null || echo 0)"
  [ "$n" = 0 ] || commits="$n commit(s) since the session started; "
fi
# Files that differ from HEAD now and did not, or not this way, when the session started.
changed="$(comm -13 "$sess/session-dirty" <(sh_dirty_list) 2>/dev/null | sed -e 's/^deleted /(deleted) /' -e 's/^[0-9a-f]\{64\} //')"
n_changed="$(printf '%s' "$changed" | grep -c . || true)"
files="$(printf '%s\n' "$changed" | head -8 | paste -sd, - | sed 's/,/, /g')"
[ "$n_changed" -le 8 ] || files="$files, and $((n_changed - 8)) more"

fp="$(sh_identity)"
unchecked="$(sh_verify_coverage "$state" "$fp" 'not checked')"
if [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ] && [ "$(sh_verify_coverage "$state" "$fp" outcome)" = partial ]; then
  verified="PARTIAL on the current code ('$verify_cmd' passed on $(sh_verify_coverage "$state" "$fp" checked), not checked on $unchecked): do not report $unchecked as verified"
elif [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ]; then
  verified="passed on the current code ('$verify_cmd')"
elif [ "$fp" = "$(cat "$state/failed" 2>/dev/null)" ]; then
  verified="FAILED on the current code and not fixed since: the turn's end check reported it"
elif [ "$fp" = "$(cat "$sess/baseline" 2>/dev/null)" ]; then
  verified="no code changed since the session started"
elif [ -n "$(sed -n 1p "$state/checked" 2>/dev/null)" ] && [ "$fp" = "$(sed -n 1p "$state/checked")" ]; then
  verified="only $(sed -n 2p "$state/checked") checked on the current code, not the verify command"
else
  verified="NOT verified: the code changed since the last check, which runs at the end of the turn"
fi

pending=""
add() { pending="$pending
- $1"; }
[ -s "$state/lint-pending" ] && add "SwiftLint errors to fix (lintBlocking): $(head -5 "$state/lint-pending" | paste -sd, - | sed 's/,/, /g')"
if [ "$(sh_cfg '.verify.enabled' 'true')" = "true" ] && ! sh_verify_approved "$verify_cmd" "$state"; then
  add "the verify command is not approved by the user: it does not run (/swift-harness:approve-verify, the user's to run)"
fi
if [ "$(sh_cfg '.security.enabled' 'true')" = "true" ] && [ -f "$state/security-approved" ] &&
  ! "$(dirname "$0")/security.sh" check --project "$SH_ROOT" >/dev/null 2>&1; then
  add "security settings changed and not approved: revert them or ask the user (/swift-harness:approve-security)"
fi
[ -s "$sess/protected-warned" ] && add "protected files were changed outside Edit and Write this session: the user was told"

docs=""
for d in CLAUDE.md docs/PITFALLS.md docs/ARCHITECTURE.md docs/COMPONENT_REGISTRY.md docs/PRODUCT_MAP.md docs/LAYOUT_CONTRACT.md docs/PORTING_PLAN.md; do
  [ -f "$SH_ROOT/$d" ] && docs="$docs${docs:+, }$d"
done

printf 'swift-harness checkpoint after compaction (facts recorded by the hooks; trust them over the summary):\n'
printf -- '- Branch: %s; %s%s file(s) changed in this session%s\n' "$branch" "$commits" "$n_changed" "${files:+: $files}"
printf -- '- Verification: %s\n' "$verified"
# The last end-of-turn record on this code (#81): each check and its result.
if [ "$(jq -r '.code // empty' "$sess/evidence.json" 2>/dev/null)" = "$fp" ]; then
  checks_line="$(jq -r '[.checks[] | "\(.name): \(.result)" + (if .detail and (.result | test("not")) then " (\(.detail))" else "" end)] | join("; ")' "$sess/evidence.json" 2>/dev/null)"
  [ -z "$checks_line" ] || printf -- '- Checks at the last turn end, on this code: %s\n' "$checks_line"
fi
[ -z "$pending" ] || printf 'Waiting:%s\n' "$pending"
[ -z "$docs" ] || printf -- '- Source of truth, reread before relying on memory: %s\n' "$docs"
exit 0
