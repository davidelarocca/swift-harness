#!/bin/bash
# Approve the project's verify command for the Stop hook (#6). Run by the user-only skill
# /swift-harness:approve-verify, never by a hook.
#
#   approve-verify.sh --status [project-dir]          show what would be approved, and its digest
#   approve-verify.sh --approve DIGEST [project-dir]  approve, only if DIGEST is still current
#   approve-verify.sh --revoke [project-dir]          remove the approval
#
# The digest check makes the approval cover exactly what --status showed.

usage() {
  echo "usage: approve-verify.sh --status | --approve DIGEST | --revoke [project-dir]" >&2
  exit 64
}

action="${1:-}"
digest=""
case "$action" in
  --status | --revoke) shift ;;
  --approve)
    digest="${2:-}"
    [ -n "$digest" ] || usage
    shift 2
    ;;
  *) usage ;;
esac
dir="${1:-$PWD}"

# The approval must land where the hooks look for it, in the plugin's data folder.
if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
  echo "swift-harness: CLAUDE_PLUGIN_DATA is not set. Run this through /swift-harness:approve-verify." >&2
  exit 1
fi

. "$(dirname "$0")/lib.sh" </dev/null
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}' 2>/dev/null)"
if ! sh_init; then
  echo "swift-harness: no .claude/swift-harness.json in $dir (or jq is missing). Nothing to approve." >&2
  exit 1
fi
state="$(sh_state_dir)" || {
  echo "swift-harness: cannot create the state folder under $CLAUDE_PLUGIN_DATA." >&2
  exit 1
}

command_line="$(sh_cfg '.verify.command' 'scripts/verify.sh fast')"

status() {
  local line word sha path
  printf 'Project: %s\nCommand: %s\n' "$SH_ROOT" "$command_line"
  while IFS= read -r line; do
    case "$line" in
      file\ *)
        read -r _ word sha <<<"$line"
        printf 'File: %s (sha256 %s)\n' "$word" "$sha"
        ;;
      input$'\t'*)
        IFS=$'\t' read -r _ path sha <<<"$line"
        case "$sha" in
          missing) printf 'Input: %s (missing: approving again is needed once it exists)\n' "$path" ;;
          outside) printf 'Input: %s (outside the project, or links outside it: cannot be covered, so approval is refused. Remove it from verify.inputs)\n' "$path" ;;
          *) printf 'Input: %s (sha256 %s)\n' "$path" "$sha" ;;
        esac
        ;;
    esac
  done < <(sh_verify_manifest "$command_line")
  if sh_verify_unparsed "$command_line"; then
    echo "Warning: the command uses quotes or shell syntax, which swift-harness does not parse, so the files it runs may be missing from the list above. Add them to verify.inputs in .claude/swift-harness.json to cover them."
  fi
  [ "$(sh_cfg '.verify.enabled' 'true')" = "true" ] ||
    echo "Note: verify.enabled is false, so the Stop hook does not run this command."
  if sh_verify_approved "$command_line" "$state" && sh_verify_partial "$command_line"; then
    echo "Status: approved, partial coverage (the files the command runs may change without a new approval; list them in verify.inputs)"
  elif sh_verify_approved "$command_line" "$state"; then
    echo "Status: approved"
  else
    echo "Status: not approved"
  fi
  printf 'Digest: %s\n' "$(sh_verify_digest "$command_line")"
}

case "$action" in
  --status) status ;;
  --revoke)
    rm -f "$state/verify-approved"
    status
    ;;
  --approve)
    if [ "$digest" != "$(sh_verify_digest "$command_line")" ]; then
      echo "swift-harness: the verify command or its files changed since they were shown. Nothing approved; check the status again."
      status
      exit 1
    fi
    if sh_verify_manifest "$command_line" | grep -q $'^input\t.*\toutside$'; then
      echo "swift-harness: verify.inputs lists a path outside the project (or a folder with links outside it), which an approval cannot cover. Nothing approved; remove it from verify.inputs in .claude/swift-harness.json."
      status
      exit 1
    fi
    printf '%s' "$digest" >"$state/verify-approved"
    sh_catch "verify command" approved "$command_line"
    status
    ;;
esac
