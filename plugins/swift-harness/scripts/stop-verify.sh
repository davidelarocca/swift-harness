#!/bin/bash
# Stop: run the project's fast verification before Claude ends a turn, but only when
# build inputs changed since the session started and since the last successful run.
# With lintBlocking, also re-lint the files that failed SwiftLint after an edit. On failure,
# block the stop and hand the output to Claude. If Claude tries to stop again without
# changing anything, or after maxAttempts failures, let it stop and warn the user instead.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0

git -C "$SH_ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
state="$(sh_state_dir)" || exit 0
# This session's starting code and failure count (#61); results and approvals are per project.
sess="$(sh_session_dir "$state")" || exit 0

verify_enabled="$(sh_cfg '.verify.enabled' 'true')"
lint_gate=false
lint_missing=false
if [ "$(sh_cfg '.lintBlocking' 'false')" = "true" ] && [ "$(sh_cfg '.lint' 'swiftlint')" = "swiftlint" ]; then
  [ -s "$state/lint-pending" ] && lint_gate=true
  # Strict mode: edits that could not be linted are not a passing lint (#17).
  command -v swiftlint >/dev/null 2>&1 || lint_missing=true
fi
# Component registry (#7): reads Markdown only, so it needs no approval.
run_registry=false
sh_registry_on && run_registry=true
# Layout contract (#34): the same, Markdown and Swift files read as text.
run_layout=false
sh_layout_on && run_layout=true
# Security settings (#32): entitlements, ATS and signing build settings read as text, compared
# with the state the user approved; recorded at session start, so no approval of code is needed.
run_security=false
# Whenever a baseline exists: turning security.enabled off is itself a change to approve.
[ -f "$state/security-approved" ] && run_security=true
[ "$verify_enabled" = "true" ] || [ "$lint_gate" = "true" ] || [ "$lint_missing" = "true" ] || [ "$run_registry" = "true" ] || [ "$run_layout" = "true" ] || [ "$run_security" = "true" ] || exit 0

command_line="$(sh_cfg '.verify.command' 'scripts/verify.sh fast')"
max_attempts="$(sh_cfg '.verify.maxAttempts' '3')"
# The verify command comes from the repository: run it only once the user approved it (#6).
run_verify=false
if [ "$verify_enabled" = "true" ]; then
  sh_verify_approved "$command_line" "$state" && run_verify=true
fi
# Architecture contracts (#13): read the graph with `swift package dump-package`, which runs
# Package.swift, so only together with the approved verify command.
run_contracts=false
[ "$run_verify" = "true" ] && [ -f "$SH_ROOT/$SH_CONTRACT" ] && run_contracts=true
checks=""
[ "$run_verify" = "true" ] && checks="$command_line"
[ "$run_contracts" = "true" ] && checks="$checks + architecture contracts"
[ "$run_registry" = "true" ] && checks="${checks:+$checks + }component registry"
[ "$run_layout" = "true" ] && checks="${checks:+$checks + }layout contract"
[ "$run_security" = "true" ] && checks="${checks:+$checks + }security settings"
{ [ "$lint_gate" = "true" ] || [ "$lint_missing" = "true" ]; } && checks="${checks:+$checks + }SwiftLint (lintBlocking)"

fp="$(sh_identity)"
[ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ] && exit 0
[ "$fp" = "$(cat "$sess/baseline" 2>/dev/null)" ] && exit 0

failed_fp="$(cat "$state/failed" 2>/dev/null)"
failures="$(cat "$sess/failures" 2>/dev/null)"
failures="${failures:-0}"

warn_user() {
  jq -n --arg msg "$1" '{systemMessage: $msg}'
}

# Tell the user once per code state that the verify command did not run.
warn_unapproved() {
  [ "$verify_enabled" = "true" ] && [ "$run_verify" = "false" ] || return 0
  [ "$fp" = "$(cat "$sess/unapproved-warned" 2>/dev/null)" ] && return 0
  printf '%s' "$fp" >"$sess/unapproved-warned"
  warn_user "swift-harness: the end-of-turn check did not run '$command_line', because this project's verify command is new or changed since you last approved it. These changes are not verified. Review the command and the files it runs, then type /swift-harness:approve-verify."
}

if [ -z "$checks" ]; then
  warn_unapproved
  exit 0
fi

# The same checks already passed on this code without the verify command (SH130-01).
[ "$(printf '%s\n%s' "$fp" "$checks")" = "$(cat "$state/checked" 2>/dev/null)" ] && exit 0

# Re-lint the files that failed SwiftLint under lintBlocking. Prints the problems, keeps
# only the files that still fail in the pending list, and returns 1 if any does.
recheck_lint() {
  local rel still="" result=0
  while IFS= read -r rel; do
    [ -n "$rel" ] && [ -f "$SH_ROOT/$rel" ] || continue
    sh_swiftlint "$SH_ROOT/$rel"
    case "$SH_LINT_RESULT" in
      errors) printf 'SwiftLint errors in %s:\n%s\n\n' "$rel" "$SH_LINT_OUTPUT" ;;
      broken)
        if [ "$SH_LINT_STATUS" -eq 0 ]; then
          printf 'SwiftLint reported a configuration problem while linting %s, so some rules were not applied:\n%s\n\n' "$rel" "$SH_LINT_ERRORS"
        else
          printf 'SwiftLint did not run correctly on %s (exit %s):\n%s\n\n' "$rel" "$SH_LINT_STATUS" "${SH_LINT_ERRORS:-no error output}"
        fi
        ;;
      missing) printf 'swiftlint not found: cannot re-check %s, which failed SwiftLint earlier.\n\n' "$rel" ;;
      *) continue ;;
    esac
    still="$still$rel"$'\n'
    result=1
  done <"$state/lint-pending"
  printf '%s' "$still" >"$state/lint-pending"
  return "$result"
}

# Nothing changed since the last failed run: never re-run on the same code.
# If this stop follows a block, Claude chose to stop: tell the user.
if [ "$fp" = "$failed_fp" ]; then
  if [ "$(sh_in '.stop_hook_active')" = "true" ]; then
    printf '0' > "$sess/failures"
    warn_user "swift-harness: '$checks' is still failing. Claude stopped without fixing it."
  fi
  exit 0
fi

out="$(mktemp -t swift-harness-verify.XXXXXX)"
status=0
result=""
if [ "$run_verify" = "true" ]; then
  (cd "$SH_ROOT" && bash -c "$command_line") >"$out" 2>&1
  status=$?
  # The result line can only lower the outcome (SH160-01): "failed" with exit 0 is a failure.
  result="$(sh_verify_result "$out")"
  if [ "$status" -eq 0 ] && [ "${result%%$'\t'*}" = failed ]; then
    printf '\n(The verify command exited 0, but its result line says failed.)\n' >>"$out"
    status=1
  fi
elif [ "$verify_enabled" = "true" ]; then
  not_checked="the build and tests were not checked"
  [ -f "$SH_ROOT/$SH_CONTRACT" ] && not_checked="the build, tests and architecture contracts were not checked"
  printf '== %s ==\nNot run: the user has not approved this verify command yet (/swift-harness:approve-verify), so %s. Do not run the approval yourself.\n' "$command_line" "$not_checked" >>"$out"
fi
if [ "$lint_missing" = "true" ]; then
  printf '\n== SwiftLint (lintBlocking) ==\nSwiftLint is not installed, but lintBlocking is on: the Swift files changed in this session were not linted. Tell the user to install it (brew install swiftlint) or to turn lintBlocking off; do not try to work around it.\n' >>"$out"
  [ "$status" -ne 0 ] || status=1
elif [ "$lint_gate" = "true" ]; then
  printf '\n== SwiftLint (lintBlocking) ==\n' >>"$out"
  recheck_lint >>"$out" || { [ "$status" -ne 0 ] || status=1; }
fi
if [ "$run_contracts" = "true" ]; then
  printf '\n== Architecture contracts ==\n' >>"$out"
  "$(dirname "$0")/contracts.sh" "$SH_ROOT" >>"$out" 2>&1 || { [ "$status" -ne 0 ] || status=1; }
fi

if [ "$run_registry" = "true" ]; then
  registry_out="$("$(dirname "$0")/registry.sh" check "$SH_ROOT" 2>&1)"
  # Exit 3: a registry in another format is reported by doctor, never blocks.
  if [ $? -eq 1 ]; then
    printf '\n== Component registry ==\n%s\n' "$registry_out" >>"$out"
    [ "$status" -ne 0 ] || status=1
  fi
fi

if [ "$run_layout" = "true" ]; then
  layout_out="$("$(dirname "$0")/layout.sh" check "$SH_ROOT" 2>&1)"
  # Exit 3: a contract in another format is reported by doctor, never blocks.
  if [ $? -eq 1 ]; then
    printf '\n== Layout contract ==\n%s\n' "$layout_out" >>"$out"
    [ "$status" -ne 0 ] || status=1
  fi
fi

if [ "$run_security" = "true" ]; then
  if ! security_out="$("$(dirname "$0")/security.sh" check --project "$SH_ROOT" 2>&1)"; then
    printf '\n== Security settings ==\n%s\n' "$security_out" >>"$out"
    [ "$status" -ne 0 ] || status=1
  fi
fi

if [ "$status" -eq 0 ]; then
  # "passed" means the verify command ran and passed (SH130-01). Lint, contracts or the
  # registry or the layout contract alone are recorded apart, with the checks that ran, so doctor can say so and an
  # approval given later still runs the verify command on this code.
  if [ "$run_verify" = "true" ]; then
    printf '%s' "$fp" > "$state/passed"
    rm -f "$state/checked"
    # What the pass covered (SH160-01), when the command says it.
    rm -f "$state/coverage"
    if [ -n "$result" ]; then
      IFS=$'\t' read -r r_outcome r_checked r_tested r_unchecked <<<"$result"
      printf '%s\noutcome: %s\nchecked: %s\ntested: %s\nnot checked: %s\n' "$fp" "$r_outcome" "$r_checked" "$r_tested" "$r_unchecked" >"$state/coverage"
      if [ "$r_outcome" = partial ]; then
        # Told once: this code is now recorded as passed, so the next Stop on it exits early.
        printf '0' > "$sess/failures"
        rm -f "$state/failed" "$out"
        msg="'$command_line' passed on this code, but $r_unchecked was not checked (PARTIAL): only $r_checked is verified. Do not report $r_unchecked as verified."
        jq -n --arg user "swift-harness: $msg" --arg claude "swift-harness: $msg Nothing to fix for this; say so in your answer if it matters." \
          '{systemMessage: $user, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $claude}}'
        exit 0
      fi
    fi
  else
    printf '%s\n%s' "$fp" "$checks" > "$state/checked"
  fi
  printf '0' > "$sess/failures"
  rm -f "$state/failed" "$out"
  warn_unapproved
  exit 0
fi

failures=$((failures + 1))
printf '%s' "$fp" > "$state/failed"

if [ "$failures" -ge "$max_attempts" ]; then
  printf '0' > "$sess/failures"
  rm -f "$out"
  warn_user "swift-harness: '$checks' failed $max_attempts times in a row. Stopping so you can decide."
  exit 0
fi
printf '%s' "$failures" > "$sess/failures"

{
  printf 'Verification failed (attempt %s of %s): %s\n\n' "$failures" "$max_attempts" "$checks"
  tail -n 60 "$out"
  printf '\nFix the failures caused by your changes, then finish. If a failure is unrelated to your work, or you stopped on purpose to ask the user something, say so in one line and stop again without editing: the check will not block twice on the same code.\n'
} >&2
rm -f "$out"
exit 2
