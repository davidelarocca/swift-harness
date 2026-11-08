#!/bin/bash
# PreToolUse (Edit|Write|MultiEdit): ask the user before Claude edits project.pbxproj,
# a protected path listed in .claude/swift-harness.json, or a snapshot baseline.
# Scope: only the Edit, Write and MultiEdit tools. Shell commands run through Bash are not
# intercepted, so this is a guard against accidental edits, not a sandbox.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0

file="$(sh_in '.tool_input.file_path')"
[ -n "$file" ] || exit 0
# Resolve ../ and symlinks, so an alias of a protected file is still protected.
real="$(sh_realpath "$file")"
rel="$(sh_relpath "$file")"

reason=""

if [ "$(sh_cfg '.guardPbxproj' 'true')" = "true" ] && { [[ "$file" == *.pbxproj ]] || [[ "$real" == *.pbxproj ]]; }; then
  reason="swift-harness: direct edits to project.pbxproj corrupt projects easily. Prefer adding files on disk (synchronized folders) or a local Swift package. Approve only if this edit is intended."
fi

if [ -z "$reason" ] && [ -n "$rel" ]; then
  while IFS= read -r protected; do
    [ -n "$protected" ] || continue
    [[ "$protected" == *"{{"* ]] && continue
    protected="${protected#./}"
    protected="${protected%/}"
    # A protected entry may itself be a symlink: match its real target as well.
    target="$(sh_relpath "$SH_ROOT/$protected")"
    if [ "$rel" = "$protected" ] || [[ "$rel" == "$protected"/* ]] ||
      { [ -n "$target" ] && { [ "$rel" = "$target" ] || [[ "$rel" == "$target"/* ]]; }; }; then
      reason="swift-harness: $protected is a protected area. Approve only if this change was explicitly requested and planned."
      break
    fi
  done < <(jq -r '.protectedPaths[]? // empty' "$SH_CONFIG" 2>/dev/null)
fi

# Snapshot baselines (#9): only /swift-harness:approve-snapshots writes them.
if [ -z "$reason" ] && [ -n "$rel" ]; then
  snapshots="$(sh_snapshots)"
  if [ -n "$snapshots" ] && { [ "$rel" = "$snapshots" ] || [[ "$rel" == "$snapshots"/* ]]; }; then
    reason="swift-harness: $snapshots/ holds the approved snapshot baselines. They change only when the user runs /swift-harness:approve-snapshots after looking at the new images. Approve this edit only if the user asked for it."
  fi
fi

# Performance baselines (#33): only /swift-harness:approve-performance writes them.
if [ -z "$reason" ] && [ -n "$rel" ]; then
  performance="$(sh_performance)"
  if [ -n "$performance" ] && { [ "$rel" = "$performance" ] || [[ "$rel" == "$performance"/* ]]; }; then
    reason="swift-harness: $performance/ holds the approved performance baselines. They change only when the user runs /swift-harness:approve-performance after looking at the new numbers. Approve this edit only if the user asked for it."
  fi
fi

[ -n "$reason" ] || exit 0
sh_catch guard asked "${rel:-a file}: ${reason#swift-harness: }"

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $reason
  }
}'
exit 0
