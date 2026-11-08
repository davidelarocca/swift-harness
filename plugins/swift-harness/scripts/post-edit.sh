#!/bin/bash
# PostToolUse (Edit|Write|MultiEdit): format the edited Swift file, lint it, and give
# Claude the result next to the tool output. The edit has already happened: this hook
# reports problems, it cannot undo them. With lintBlocking, failing files are also
# recorded so the Stop check re-lints them before the turn can end.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0

file="$(sh_in '.tool_input.file_path')"
# A protected file edited through Edit or Write (#11): the guard asked the user first, so
# protected-watch.sh does not report this state of the file at the end of the turn. Recorded
# on exit, after the formatter, whichever way this script ends.
record_protected_edit() {
  local prel pstate
  [ -n "$file" ] && [ -f "$file" ] || return 0
  jq -e '(.protectedPaths // []) | length > 0' "$SH_CONFIG" >/dev/null 2>&1 || return 0
  prel="$(sh_relpath "$file")"
  pstate="$(sh_state_path)"
  [ -n "$prel" ] && [ -d "$pstate/sessions" ] || return 0
  # Every session open on the project (#61): the user was asked, in whichever session it was.
  sh_protected_list | awk -v p="$prel" 'substr($0, index($0, " ") + 1) == p' |
    sh_sessions_append "$pstate" protected-edited protected-start
}
trap record_protected_edit EXIT
[[ "$file" == *.swift ]] || exit 0
[ -f "$file" ] || exit 0
# Only files inside this project: never format or lint a file elsewhere on disk.
rel="$(sh_relpath "$file")"
[ -n "$rel" ] || exit 0
path="$SH_ROOT/$rel"

notes=""
add_note() { notes="${notes:+$notes

}$1"; }

# ---- Format ----
# A missing formatter is reported once by SessionStart, not on every edit.
formatter="$(sh_cfg '.format' 'swiftformat')"
fmt_cmd=()
case "$formatter" in
  swiftformat)
    command -v swiftformat >/dev/null 2>&1 && fmt_cmd=(swiftformat --quiet "$path")
    ;;
  swift-format)
    if xcrun --find swift-format >/dev/null 2>&1; then
      fmt_cmd=(xcrun swift-format format --in-place "$path")
    elif command -v swift-format >/dev/null 2>&1; then
      fmt_cmd=(swift-format format --in-place "$path")
    fi
    ;;
esac
if [ "${#fmt_cmd[@]}" -gt 0 ]; then
  original="$(mktemp -t swift-harness-original.XXXXXX)"
  cp "$path" "$original"
  fmt_err="$(mktemp -t swift-harness-format.XXXXXX)"
  (cd "$SH_ROOT" && "${fmt_cmd[@]}" >/dev/null 2>"$fmt_err")
  fmt_status=$?
  if ! cmp -s "$original" "$path"; then
    # Show what the formatter changed, so it is not confused with the edit itself.
    changes="$(diff -U0 "$original" "$path" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ')"
    total="$(printf '%s\n' "$changes" | grep -c .)"
    shown="$(printf '%s\n' "$changes" | head -12)"
    [ "$total" -le 12 ] || shown="$shown
... $((total - 12)) more changed lines"
    add_note "The formatter rewrote $rel. Re-read it before editing it again. Formatter changes (- your edit as written, + after formatting; the formatter changed only these lines):
$shown"
  fi
  rm -f "$original"
  if [ "$fmt_status" -ne 0 ]; then
    add_note "$formatter failed on $rel (exit $fmt_status), so the file may not be formatted. Usually a syntax error in the edit:
$(grep -v '^[[:space:]]*$' "$fmt_err" | head -10)"
  fi
  rm -f "$fmt_err"
fi

# ---- Lint ----
blocking="$(sh_cfg '.lintBlocking' 'false')"
if [ "$(sh_cfg '.lint' 'swiftlint')" = "swiftlint" ]; then
  sh_swiftlint "$path"

  case "$SH_LINT_RESULT" in
    clean) add_note "SwiftLint: no issues in $rel." ;;
    excluded) add_note "SwiftLint: $rel is excluded by .swiftlint.yml, so it was not linted." ;;
    warnings | errors)
      count="$(printf '%s\n' "$SH_LINT_OUTPUT" | grep -cE ': (warning|error):')"
      add_note "SwiftLint: $count issue(s) in $rel. Fix the ones on lines you wrote or changed; leave pre-existing ones unless the task covers them.
$SH_LINT_OUTPUT"
      ;;
  esac
  if [ "$SH_LINT_RESULT" = broken ] && [ "$SH_LINT_STATUS" -eq 0 ]; then
    add_note "SwiftLint reported a configuration problem while linting $rel, so some rules were not applied. Check .swiftlint.yml:
$SH_LINT_ERRORS"
  elif [ "$SH_LINT_RESULT" = broken ]; then
    add_note "SwiftLint did not run correctly on $rel (exit $SH_LINT_STATUS), so its rules were not fully applied. Check .swiftlint.yml:
${SH_LINT_ERRORS:-no error output}${SH_LINT_OUTPUT:+
$SH_LINT_OUTPUT}"
  fi

  if [ "$blocking" = "true" ]; then
    state="$(sh_state_dir)"
    case "$SH_LINT_RESULT" in
      errors)
        [ -z "$state" ] || sh_lint_pending_add "$state" "$rel"
        printf '%s\n\nThe edit is applied, but %s has SwiftLint errors and lintBlocking is on. Fix the errors on lines you wrote or changed. If an error is on a line that was already there before your edit and the task does not cover it, leave it and say so in one line: the turn will then end as failed so the user can decide.\n' "$notes" "$rel" >&2
        exit 2
        ;;
      broken)
        [ -z "$state" ] || sh_lint_pending_add "$state" "$rel"
        printf '%s\n\nThe edit is applied, but SwiftLint is not working correctly and lintBlocking is on. This usually comes from .swiftlint.yml, not from your edit: do not change .swiftlint.yml unless the task covers it, and tell the user what SwiftLint reported. The turn will end as failed until it is fixed.\n' "$notes" >&2
        exit 2
        ;;
      clean | warnings | excluded)
        [ -z "$state" ] || sh_lint_pending_remove "$state" "$rel"
        ;;
    esac
  fi
fi

# ---- Component registry (#7) ----
# Not blocking: a reminder next to the edit. Wrong entries block at the end of the turn.
if sh_registry_on; then
  registry="$(sh_registry)"
  missing="$("$(dirname "$0")/registry.sh" missing "$SH_ROOT" "$rel" | cut -f1 | paste -sd, - | sed 's/,/, /g')"
  [ -z "$missing" ] || add_note "Component registry: $rel declares shared UI that $registry does not list: $missing. Add an entry in the same change, or list it under Internal if it is not meant for reuse."
  entries="$("$(dirname "$0")/registry.sh" entries "$SH_ROOT" "$rel" | paste -sd, - | sed 's/,/, /g')"
  [ -z "$entries" ] || add_note "Component registry: $rel is the file of $entries in $registry. If you changed its API, variants, behavior or callers, update the entry in the same change."
fi

# ---- Layout contract (#34) ----
# Not blocking: the sizes a screen in this file must hold. The layout tests measure them.
if sh_layout_on; then
  screens="$("$(dirname "$0")/layout.sh" entries "$SH_ROOT" "$rel" | paste -sd ';' - | sed 's/;/; /g')"
  [ -z "$screens" ] || add_note "Layout contract: $rel draws $screens in $(sh_layout). If you changed its layout, it must still fit at those sizes (LayoutContract.check in the tests measures it); update the contract in the same change if the sizes or the compact behavior changed."
fi

# ---- Architecture contracts (#13) ----
# An edited manifest is checked at once. dump-package runs Package.swift, so only with the
# approved verify command, like the end-of-turn check.
if [ "${rel##*/}" = "Package.swift" ] && [ -f "$SH_ROOT/$SH_CONTRACT" ] &&
  [ "$(sh_cfg '.verify.enabled' 'true')" = "true" ] &&
  sh_verify_approved "$(sh_cfg '.verify.command' 'scripts/verify.sh fast')" "$(sh_state_dir)"; then
  if ! contract_out="$("$(dirname "$0")/contracts.sh" "$SH_ROOT" 2>&1)"; then
    printf '%s%s\n\nThe edit is applied, but the end-of-turn check will fail until the package matches the contract.\n' \
      "${notes:+$notes

}" "$contract_out" >&2
    exit 2
  fi
  [ -z "$contract_out" ] || add_note "$contract_out"
fi

[ -n "$notes" ] || exit 0

jq -n --arg ctx "$notes" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
exit 0
