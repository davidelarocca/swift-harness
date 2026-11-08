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
docs_cmd="$(sh_docs_command)"
[ -n "$docs_cmd" ] || [ "$verify_enabled" = "true" ] || [ "$lint_gate" = "true" ] || [ "$lint_missing" = "true" ] || [ "$run_registry" = "true" ] || [ "$run_layout" = "true" ] || [ "$run_security" = "true" ] || exit 0

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

# Evidence summary (#81): what this turn checked, from facts this hook holds, not from Claude's
# wording. One "name<TAB>result<TAB>detail" line per check; written as JSON at every exit to
# the session folder (the checkpoint reads it) and to the project folder (doctor, the evals).
ev_lines="$sess/evidence.lines"
: >"$ev_lines"
# A check that ran gets its duration in whole seconds since ev_t0 (the shell's SECONDS).
ev_t0=$SECONDS
ev() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >>"$ev_lines"; }
ev_ran() { ev "$1" "$2" "${3:-}" "$((SECONDS - ev_t0))"; } # $1 name, $2 result, $3 detail
# Catch log lines written from here carry the code they are about (#110).
SH_CATCH_CODE="$fp"
ev_write() { # $1 outcome, $2 note
  local json
  json="$(jq -n --arg outcome "$1" --arg note "${2:-}" --arg code "$fp" --arg session "$(sh_session_id)" --arg agent "${SH_AGENT:-claude}" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --rawfile lines "$ev_lines" '
    {version: 1, time: $time, session: $session, agent: $agent, code: $code, outcome: $outcome}
    + (if $note == "" then {} else {note: $note} end)
    + {checks: ($lines | split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], result: .[1]} + (if (.[2] // "") == "" then {} else {detail: .[2]} end)
          + (if (.[3] // "") == "" then {} else {seconds: (.[3] | tonumber)} end)))}')" || return 0
  printf '%s\n' "$json" >"$sess/evidence.json.tmp" && mv "$sess/evidence.json.tmp" "$sess/evidence.json"
  printf '%s\n' "$json" >"$state/evidence.json.tmp" && mv "$state/evidence.json.tmp" "$state/evidence.json"
  ev_history "$json"
}
# History of the records (#110): one line each in evidence-history.jsonl, bounded by count
# (SWIFT_HARNESS_HISTORY_MAX, 2000) and by age (the retention of session folders). A record that
# only says nothing ran again on the code of the previous one is not repeated. Trimming takes a
# lock, so two sessions appending at once lose nothing.
ev_history() { # $1 the record as JSON
  local file="$state/evidence-history.jsonl" line max last
  line="$(printf '%s' "$1" | jq -c . 2>/dev/null)" || return 0
  if [ "$(printf '%s' "$line" | jq -r .outcome)" = unchanged ] && [ -s "$file" ]; then
    last="$(tail -n 1 "$file" | jq -r '[.code, .outcome] | join(" ")' 2>/dev/null)"
    [ "$last" = "$fp unchanged" ] && return 0
  fi
  printf '%s\n' "$line" >>"$file" 2>/dev/null || return 0
  max="${SWIFT_HARNESS_HISTORY_MAX:-2000}"
  case "$max" in '' | *[!0-9]*) max=2000 ;; esac
  local cutoff oldest
  cutoff="$(date -u -v-"${SH_SESSION_MAX_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$SH_SESSION_MAX_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"
  oldest="$(head -n 1 "$file" | jq -r '.time // ""' 2>/dev/null)"
  [ "$(wc -l <"$file" | tr -d ' ')" -gt "$max" ] || [[ "$oldest" < "$cutoff" ]] || return 0
  mkdir "$state/evidence-history.lock" 2>/dev/null || return 0
  jq -c --arg cutoff "$cutoff" 'select((.time // "") >= $cutoff)' "$file" 2>/dev/null | tail -n "$max" >"$file.tmp" && mv "$file.tmp" "$file"
  rmdir "$state/evidence-history.lock" 2>/dev/null
}
# The checks of the last record on this same code, when this turn ran nothing new.
ev_keep() {
  if [ "$(jq -r '.code // empty' "$state/evidence.json" 2>/dev/null)" = "$fp" ]; then
    jq -r '.checks[] | select(.name | startswith("docs: ") | not) | [.name, .result, (.detail // ""), (.seconds // "" | tostring)] | @tsv' "$state/evidence.json" 2>/dev/null >>"$ev_lines"
  fi
  # The docs adapter's result of this turn, whatever the code (#105).
  [ -z "${adapter_line:-}" ] || printf '%s\n' "$adapter_line" >>"$ev_lines"
}
# "name (detail), ..." of the checks that did not run this turn, or nothing.
ev_missing() {
  awk -F'\t' '$2 == "not run" || $2 == "not checked" { printf "%s%s%s", (n++ ? ", " : ""), $1, ($3 != "" ? " (" $3 ")" : "") }' "$ev_lines"
}
# Catch log (#86): one "skipped" line per check that did not run, when the user is told.
ev_log_skipped() {
  awk -F'\t' '$2 == "not run" || $2 == "not checked" { print $1 "\t" $3 }' "$ev_lines" |
    while IFS=$'\t' read -r name detail; do sh_catch "$name" skipped "$detail"; done
}
# The checks of the last block in this session, for the line saying how it ended.
ev_log_end() { # $1 kind: fixed or left-failing, $2 what
  local name
  [ -s "$sess/blocked-checks" ] || return 0
  while IFS= read -r name; do [ -n "$name" ] && sh_catch "$name" "$1" "$2"; done <"$sess/blocked-checks"
  rm -f "$sess/blocked-checks"
}
# "name, ..." of the checks that passed this turn.
ev_passed() { awk -F'\t' '$2 == "passed" || $2 == "partial" { printf "%s%s", (n++ ? ", " : ""), $1 }' "$ev_lines"; }

# Checks that cannot run this turn, from the settings and approvals alone.
if [ "$verify_enabled" != "true" ]; then
  ev "$command_line" "not run" "verify.enabled is false in .claude/swift-harness.json"
elif [ "$run_verify" != "true" ]; then
  ev "$command_line" "not run" "the verify command is not approved: /swift-harness:approve-verify"
fi
[ -f "$SH_ROOT/$SH_CONTRACT" ] && [ "$run_contracts" != "true" ] && ev "architecture contracts" "not run" "they run only with the approved verify command"
# Under lintBlocking a missing SwiftLint fails the check: the edits could not be linted (#17).
[ "$lint_missing" = "true" ] && ev "SwiftLint (lintBlocking)" failed "swiftlint is not installed, so the edited files were not linted"

# The project's own docs check, as an adapter (#105). It runs when the docs changed since its
# last run, before the early exits below: editing docs does not change the build fingerprint.
# Its problems already there at session start do not block; new ones block once per set,
# unless docs.blocking is false, then they are recorded only.
adapter_line=""
if [ -n "$docs_cmd" ]; then
  adapter_name="docs: $docs_cmd"
  if ! sh_verify_approved "$command_line" "$state"; then
    adapter_line="$adapter_name	not run	the command is not approved: /swift-harness:approve-verify"
  else
    dfp="$(sh_docs_fingerprint)"
    if [ "$dfp" = "$(sed -n 1p "$sess/docs-adapter" 2>/dev/null)" ]; then
      adapter_line="$(sed -n 2p "$sess/docs-adapter")"
    else
      a_t0=$SECONDS
      a_out="$(cd "$SH_ROOT" && bash -c "$docs_cmd" 2>&1 </dev/null)"
      a_code=$?
      a_secs=$((SECONDS - a_t0))
      a_new=""
      [ -f "$sess/docs-start" ] || : >"$sess/docs-start"
      if [ "$a_code" -gt 1 ]; then
        # Exit 1 means problems; another code means the check could not run (a crash, a missing
        # tool): not checked, and the user is told, never taken for problems already there.
        adapter_line="$adapter_name	not checked	exit $a_code: $(printf '%s\n' "$a_out" | grep -m1 . | cut -c1-120)	$a_secs"
      elif [ "$a_code" -eq 0 ]; then
        adapter_line="$adapter_name	passed	exit 0	$a_secs"
        if [ -s "$sess/docs-adapter-blocked" ]; then sh_catch "$adapter_name" fixed "passes again" "$a_secs"; rm -f "$sess/docs-adapter-blocked"; fi
      else
        a_new="$(printf '%s\n' "$a_out" | sh_adapter_keys | LC_ALL=C comm -23 - "$sess/docs-start")"
        a_n="$(printf '%s\n' "$a_new" | grep -c .)"
        if [ -z "$a_new" ]; then
          adapter_line="$adapter_name	failed	exit $a_code, only problems already there at session start	$a_secs"
          # The new problems that blocked are gone: fixed, even though old ones remain.
          if [ -s "$sess/docs-adapter-blocked" ]; then sh_catch "$adapter_name" fixed "no new problem left" "$a_secs"; rm -f "$sess/docs-adapter-blocked"; fi
        else adapter_line="$adapter_name	failed	exit $a_code, $a_n new problem line(s)	$a_secs"; fi
      fi
      printf '%s\n%s\n' "$dfp" "$adapter_line" >"$sess/docs-adapter"
      if [ -n "$a_new" ]; then
        a_key="$(printf '%s' "$a_new" | shasum | cut -d' ' -f1)"
        if ! sh_docs_blocking; then
          sh_catch "$adapter_name" observed "$a_n new problem line(s); not blocking (docs.blocking is false)" "$a_secs"
        elif [ "$a_key" = "$(cat "$sess/docs-adapter-blocked" 2>/dev/null)" ]; then
          sh_catch "$adapter_name" left-failing "the same new problems; $(sh_agent_name) stopped without fixing them" "$a_secs"
        else
          printf '%s' "$a_key" >"$sess/docs-adapter-blocked"
          sh_catch "$adapter_name" blocked "$a_n new problem line(s)" "$a_secs"
          printf '%s\n' "$adapter_line" >>"$ev_lines"
          ev_write failed "the project's docs check found new problems"
          {
            printf "The project's docs check (%s) found problems that were not there when the session started:\n\n" "$docs_cmd"
            printf '%s\n' "$a_out" | tail -n 40
            printf '\nFix the docs, or the reference, then finish. If it is intended, say so in one line and stop again without editing: the check does not block twice on the same problems.\n'
          } >&2
          exit 2
        fi
      fi
    fi
  fi
  printf '%s\n' "$adapter_line" >>"$ev_lines"
fi

if [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ]; then
  : >"$ev_lines"; ev_keep; ev_write unchanged "the code is the one that passed before: nothing ran again"
  exit 0
fi
if [ "$fp" = "$(cat "$sess/baseline" 2>/dev/null)" ]; then
  ev_write unchanged "no build input changed in this session: nothing ran, and the starting code is not verified"
  exit 0
fi

failed_fp="$(cat "$state/failed" 2>/dev/null)"
failures="$(cat "$sess/failures" 2>/dev/null)"
failures="${failures:-0}"

# The user is told what was not checked (#81) with any message they get; told is set once said.
told=false
warn_user() {
  local msg="$1" missing
  missing="$(ev_missing)"
  [ -z "$missing" ] || msg="$msg Not checked this turn: $missing."
  told=true
  printf '%s%s' "$fp" "$missing" >"$sess/missing-told"
  [ -z "$missing" ] || ev_log_skipped
  jq -n --arg msg "$msg" '{systemMessage: $msg}'
}
# With no other message: tell the user once per code what was not checked, if anything.
notify_missing() {
  local missing passed
  missing="$(ev_missing)"
  [ -n "$missing" ] && [ "$told" = false ] || return 0
  [ "$fp$missing" = "$(cat "$sess/missing-told" 2>/dev/null)" ] && return 0
  printf '%s%s' "$fp" "$missing" >"$sess/missing-told"
  ev_log_skipped
  passed="$(ev_passed)"
  jq -n --arg msg "swift-harness: ${passed:+checked this turn: $passed; }not checked: $missing." '{systemMessage: $msg}'
}

# Tell the user once per code state that the verify command did not run.
warn_unapproved() {
  [ "$verify_enabled" = "true" ] && [ "$run_verify" = "false" ] || return 0
  [ "$fp" = "$(cat "$sess/unapproved-warned" 2>/dev/null)" ] && return 0
  printf '%s' "$fp" >"$sess/unapproved-warned"
  warn_user "swift-harness: the end-of-turn check did not run '$command_line', because this project's verify command is new or changed since you last approved it. These changes are not verified. Review the command and the files it runs, then type /swift-harness:approve-verify."
}

if [ -z "$checks" ]; then
  ev_write not-verified "no check could run"
  warn_unapproved
  exit 0
fi

# The same checks already passed on this code without the verify command (SH130-01).
if [ "$(printf '%s\n%s' "$fp" "$checks")" = "$(cat "$state/checked" 2>/dev/null)" ]; then
  : >"$ev_lines"; ev_keep; ev_write unchanged "the same checks passed on this code before: nothing ran again"
  exit 0
fi

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
  : >"$ev_lines"; ev_keep; ev_write failed "the code is the one that failed before: nothing ran again"
  if [ "$(sh_in '.stop_hook_active')" = "true" ]; then
    printf '0' > "$sess/failures"
    ev_log_end left-failing "$(sh_agent_name) stopped without fixing it; the user was told"
    warn_user "swift-harness: '$checks' is still failing. $(sh_agent_name) stopped without fixing it."
  fi
  exit 0
fi

out="$(mktemp -t swift-harness-verify.XXXXXX)"
status=0
unstable=""
result=""
if [ "$run_verify" = "true" ]; then
  ev_t0=$SECONDS
  (cd "$SH_ROOT" && bash -c "$command_line") >"$out" 2>&1
  status=$?
  # The result line can only lower the outcome (SH160-01): "failed" with exit 0 is a failure.
  result="$(sh_verify_result "$out")"
  if [ "$status" -eq 0 ] && [ "${result%%$'\t'*}" = failed ]; then
    printf '\n(The verify command exited 0, but its result line says failed.)\n' >>"$out"
    status=1
  fi
  # verify.retryFailed (#108): a failure is run once more; if that passes, the failure was
  # unstable (a flaky test): recorded with the tests that failed, not blocking the turn.
  if [ "$status" -ne 0 ] && [ "$(sh_cfg '.verify.retryFailed' 'false')" = "true" ]; then
    flaky="$(grep -E '^Failing tests:|^[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*\(\)$|✘ Test |Test Case .* failed' "$out" | grep -v '^Failing tests:' |
      sed -E 's/^[[:space:]]+//; s/^✘ Test ([^ ]+).*/\1/; s/^Test Case .-\[([^]]+)\]. failed.*/\1/' | head -5 | paste -sd, - | sed 's/,/, /g')"
    out2="$(mktemp -t swift-harness-verify.XXXXXX)"
    (cd "$SH_ROOT" && bash -c "$command_line") >"$out2" 2>&1
    status2=$?
    result2="$(sh_verify_result "$out2")"
    if [ "$status2" -eq 0 ] && [ "${result2%%$'\t'*}" != failed ]; then
      mv "$out2" "$out"; status=0; result="$result2"
      unstable="failed once, passed on a rerun: unstable${flaky:+ ($flaky)}"
      sh_catch "$command_line" unstable "${flaky:-the tests that failed are not named in the output}" "$((SECONDS - ev_t0))"
    else
      rm -f "$out2"
    fi
  fi
  if [ "$status" -ne 0 ]; then ev_ran "$command_line" failed "exit $status"
  elif [ -n "$result" ]; then
    IFS=$'\t' read -r e_outcome e_checked e_tested e_unchecked <<<"$result"
    if [ "$e_outcome" = partial ]; then ev_ran "$command_line" partial "checked on $e_checked, tested on $e_tested; not checked on $e_unchecked${unstable:+; $unstable}"
    else ev_ran "$command_line" passed "checked on $e_checked, tested on $e_tested${unstable:+; $unstable}"; fi
  else
    ev_ran "$command_line" passed "exit 0; the command does not say which platforms it checked${unstable:+; $unstable}"
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
  ev_t0=$SECONDS
  if recheck_lint >>"$out"; then ev_ran "SwiftLint (lintBlocking)" passed "the files that failed after an edit"
  else ev_ran "SwiftLint (lintBlocking)" failed "files still failing: $(grep -c . "$state/lint-pending")"; [ "$status" -ne 0 ] || status=1; fi
fi
if [ "$run_contracts" = "true" ]; then
  printf '\n== Architecture contracts ==\n' >>"$out"
  ev_t0=$SECONDS
  if "$(dirname "$0")/contracts.sh" "$SH_ROOT" >>"$out" 2>&1; then ev_ran "architecture contracts" passed "$SH_CONTRACT"
  else ev_ran "architecture contracts" failed "$SH_CONTRACT"; [ "$status" -ne 0 ] || status=1; fi
fi

if [ "$run_registry" = "true" ]; then
  ev_t0=$SECONDS
  registry_out="$("$(dirname "$0")/registry.sh" check "$SH_ROOT" 2>&1)"
  # Exit 3: a registry in another format is reported by doctor, never blocks.
  case $? in
    0) ev_ran "component registry" passed ;;
    1)
      ev_ran "component registry" failed "$(grep -c '^- ' <<<"$registry_out") problem(s)"
      printf '\n== Component registry ==\n%s\n' "$registry_out" >>"$out"
      [ "$status" -ne 0 ] || status=1
      ;;
    *) ev "component registry" "not checked" "the registry has no Components table with Name and File columns" ;;
  esac
fi

if [ "$run_layout" = "true" ]; then
  ev_t0=$SECONDS
  layout_out="$("$(dirname "$0")/layout.sh" check "$SH_ROOT" 2>&1)"
  # Exit 3: a contract in another format is reported by doctor, never blocks.
  case $? in
    0) ev_ran "layout contract" passed "the contract's rows; the sizes are measured by the tests" ;;
    1)
      ev_ran "layout contract" failed "$(grep -c '^- ' <<<"$layout_out") problem(s)"
      printf '\n== Layout contract ==\n%s\n' "$layout_out" >>"$out"
      [ "$status" -ne 0 ] || status=1
      ;;
    *) ev "layout contract" "not checked" "the contract has no Screens table with View, File and Min columns" ;;
  esac
fi

if [ "$run_security" = "true" ]; then
  ev_t0=$SECONDS
  if security_out="$("$(dirname "$0")/security.sh" check --project "$SH_ROOT" 2>&1)"; then
    ev_ran "security settings" passed "unchanged since the approved state"
  else
    ev_ran "security settings" failed "changed since the approved state"
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
        ev_write partial
        missing="$(ev_missing)"
        [ -z "$missing" ] || msg="$msg Not checked this turn either: $missing."
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
  ev_log_end fixed "passed at the end of a later turn"
  if [ "$run_verify" = "true" ]; then ev_write passed
  else ev_write checked "the checks that ran passed; the build and tests did not run"; fi
  warn_unapproved
  notify_missing
  exit 0
fi

failures=$((failures + 1))
printf '%s' "$fp" > "$state/failed"
ev_write failed
# Catch log (#86): each failing check, once per block.
awk -F'\t' '$2 == "failed" { print $1 "\t" $3 "\t" $4 }' "$ev_lines" | while IFS=$'\t' read -r name detail seconds; do
  sh_catch "$name" blocked "attempt $failures of $max_attempts${detail:+: $detail}" "$seconds"
  grep -qxF -- "$name" "$sess/blocked-checks" 2>/dev/null || printf '%s\n' "$name" >>"$sess/blocked-checks"
done

if [ "$failures" -ge "$max_attempts" ]; then
  printf '0' > "$sess/failures"
  rm -f "$out"
  ev_log_end left-failing "failed $max_attempts times in a row; the user decides"
  warn_user "swift-harness: '$checks' failed $max_attempts times in a row. Stopping so you can decide."
  exit 0
fi
printf '%s' "$failures" > "$sess/failures"

{
  printf 'Verification failed (attempt %s of %s): %s\n\n' "$failures" "$max_attempts" "$checks"
  tail -n 60 "$out"
  missing="$(ev_missing)"
  [ -z "$missing" ] || printf '\nNot checked this turn: %s. Do not report these as verified.\n' "$missing"
  printf '\nFix the failures caused by your changes, then finish. If a failure is unrelated to your work, or you stopped on purpose to ask the user something, say so in one line and stop again without editing: the check will not block twice on the same code.\n'
} >&2
rm -f "$out"
exit 2
