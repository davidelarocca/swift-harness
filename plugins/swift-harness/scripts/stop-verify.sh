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
lint_cmd="$(sh_adapter_command lint)"
format_cmd="$(sh_adapter_command format)"
[ -n "$docs_cmd$lint_cmd$format_cmd" ] || [ "$verify_enabled" = "true" ] || [ "$lint_gate" = "true" ] || [ "$lint_missing" = "true" ] || [ "$run_registry" = "true" ] || [ "$run_layout" = "true" ] || [ "$run_security" = "true" ] || exit 0

command_line="$(sh_cfg '.verify.command' 'scripts/verify.sh fast')"
max_attempts="$(sh_cfg '.verify.maxAttempts' '3')"
# A run of this session that never ended (#144): its marker is still there, and its process is
# gone or it is older than any hook timeout. It goes in the catch log, and protected-watch.sh
# tells the user from the file it is moved to.
if [ -f "$sess/running" ]; then
  r_pid="$(sed -n 3p "$sess/running")"
  r_start="$(sed -n 2p "$sess/running")"
  case "$r_pid" in '' | *[!0-9]*) r_pid=0 ;; esac
  case "$r_start" in '' | *[!0-9]*) r_start="$(date +%s)" ;; esac
  r_age=$(($(date +%s) - r_start))
  if [ "$r_pid" -eq 0 ] || [ "$r_age" -gt 1000 ] || ! kill -0 "$r_pid" 2>/dev/null; then
    sh_catch "$command_line" not-finished "the checks started $((r_age / 60)) min ago and never ended: the hook was stopped before its result (its timeout is 900 s), or the session closed"
    mv -f "$sess/running" "$sess/unfinished"
  fi
fi
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
ev_write() { # $1 outcome, $2 note, $3 "now" for a record of a run in progress, kept out of the history
  local json
  json="$(jq -n --arg outcome "$1" --arg note "${2:-}" --arg code "$fp" --arg session "$(sh_session_id)" --arg agent "${SH_AGENT:-claude}" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --rawfile lines "$ev_lines" '
    {version: 1, time: $time, session: $session, agent: $agent, code: $code, outcome: $outcome}
    + (if $note == "" then {} else {note: $note} end)
    + {checks: ($lines | split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], result: .[1]} + (if (.[2] // "") == "" then {} else {detail: .[2]} end)
          + (if (.[3] // "") == "" then {} else {seconds: (.[3] | tonumber)} end)))}
    | if any(.checks[]; (.detail // "") | contains("failed once, passed on a rerun")) then . + {stability: "unstable"} else . end')" || return 0
  printf '%s\n' "$json" >"$sess/evidence.json.tmp" && mv "$sess/evidence.json.tmp" "$sess/evidence.json"
  printf '%s\n' "$json" >"$state/evidence.json.tmp" && mv "$state/evidence.json.tmp" "$state/evidence.json"
  [ "${3:-}" = now ] || ev_history "$json"
}
# History of the records (#110): one line each in evidence-history.jsonl, bounded by count
# (SWIFT_HARNESS_HISTORY_MAX, 2000) and by age (the retention of session folders). A record that
# only says nothing ran again on the code of the previous one is not repeated. The append and the
# trim both run only while this process holds the lock, so a line can never be added between the
# trim's read and its replace, where the holder's replace would erase it. A lock older than five
# minutes was left by a killed hook and is taken over. A real hold lasts milliseconds; if the lock
# is still busy after the wait (another hook is wedged), the record is skipped rather than raced.
ev_history() { # $1 the record as JSON
  local file="$state/evidence-history.jsonl" lock="$state/evidence-history.lock" line max last held="" i=0 tries
  line="$(printf '%s' "$1" | jq -c . 2>/dev/null)" || return 0
  if [ "$(printf '%s' "$line" | jq -r .outcome)" = unchanged ] && [ -s "$file" ]; then
    last="$(tail -n 1 "$file" | jq -r '[.code, .outcome] | join(" ")' 2>/dev/null)"
    [ "$last" = "$fp unchanged" ] && return 0
  fi
  [ -z "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || rmdir "$lock" 2>/dev/null
  tries="${SWIFT_HARNESS_LOCK_TRIES:-100}"
  case "$tries" in '' | *[!0-9]*) tries=100 ;; esac
  while [ "$i" -lt "$tries" ]; do
    if mkdir "$lock" 2>/dev/null; then held=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$held" ] || return 0
  printf '%s\n' "$line" >>"$file" 2>/dev/null
  max="${SWIFT_HARNESS_HISTORY_MAX:-2000}"
  case "$max" in '' | *[!0-9]*) max=2000 ;; esac
  local cutoff oldest
  cutoff="$(date -u -v-"${SH_SESSION_MAX_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$SH_SESSION_MAX_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"
  oldest="$(head -n 1 "$file" | jq -r '.time // ""' 2>/dev/null)"
  if [ "$(wc -l <"$file" | tr -d ' ')" -gt "$max" ] || [[ "$oldest" < "$cutoff" ]]; then
    jq -c --arg cutoff "$cutoff" 'select((.time // "") >= $cutoff)' "$file" 2>/dev/null | tail -n "$max" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
  rmdir "$lock" 2>/dev/null
}
# The checks of the last record on this same code, when this turn ran nothing new.
ev_keep() {
  if [ "$(jq -r '.code // empty' "$state/evidence.json" 2>/dev/null)" = "$fp" ]; then
    jq -r '.checks[] | select(.name | test("^(docs|lint|format): ") | not) | [.name, .result, (.detail // ""), (.seconds // "" | tostring)] | @tsv' "$state/evidence.json" 2>/dev/null >>"$ev_lines"
  fi
  # The adapters' results of this turn, whatever the code (#105, #125).
  [ -z "${adapter_lines:-}" ] || printf '%s' "$adapter_lines" >>"$ev_lines"
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

# The project's own checks, as adapters: docs (#105), lint and format (#125). They run before the
# early exits below: editing docs does not change the build fingerprint, and lint must run on code
# that is the same as code that passed. Each runs when what it reads changed since its last run.
# Its problems already there at session start do not block; new ones block once per set, unless
# <kind>.blocking is false, then they are recorded only.
run_adapter() { # $1 docs | lint | format, $2 command, $3 fingerprint of what it reads
  local kind="$1" cmd="$2" afp="$3" name line out code secs new n key t0 start label fix
  name="$kind: $cmd"
  start="$sess/$kind-start"
  case "$kind" in
    docs) label="docs check"; fix="Fix the docs, or the reference, then finish." ;;
    lint) label="lint check"; fix="Fix the code, then finish." ;;
    format) label="format check"; fix="Format the code the way the project's check expects, then finish." ;;
  esac
  if ! sh_verify_approved "$command_line" "$state"; then
    adapter_line "$name	not run	the command is not approved: /swift-harness:approve-verify"
    return 0
  fi
  if [ "$afp" = "$(sed -n 1p "$sess/$kind-adapter" 2>/dev/null)" ]; then
    adapter_line "$(sed -n 2p "$sess/$kind-adapter")"
    return 0
  fi
  t0=$SECONDS
  out="$(cd "$SH_ROOT" && bash -c "$cmd" 2>&1 </dev/null)"
  code=$?
  secs=$((SECONDS - t0))
  new=""
  [ -f "$start" ] || : >"$start"
  if [ "$code" -gt 1 ]; then
    # Exit 1 means problems; another code means the check could not run (a crash, a missing
    # tool): not checked, and the user is told, never taken for problems already there.
    line="$name	not checked	exit $code: $(printf '%s\n' "$out" | grep -m1 . | cut -c1-120)	$secs"
  elif [ "$code" -eq 0 ]; then
    line="$name	passed	exit 0	$secs"
    if [ -s "$sess/$kind-adapter-blocked" ]; then sh_catch "$name" fixed "passes again" "$secs"; rm -f "$sess/$kind-adapter-blocked"; fi
    if [ -s "$sess/$kind-adapter-observed" ]; then sh_catch "$name" fixed "observed problems gone: passes again" "$secs"; rm -f "$sess/$kind-adapter-observed"; fi
  else
    new="$(printf '%s\n' "$out" | sh_adapter_keys | LC_ALL=C comm -23 - "$start")"
    n="$(printf '%s\n' "$new" | grep -c .)"
    if [ -z "$new" ]; then
      line="$name	failed	exit $code, only problems already there at session start	$secs"
      # The new problems that blocked are gone: fixed, even though old ones remain.
      if [ -s "$sess/$kind-adapter-blocked" ]; then sh_catch "$name" fixed "no new problem left" "$secs"; rm -f "$sess/$kind-adapter-blocked"; fi
      if [ -s "$sess/$kind-adapter-observed" ]; then sh_catch "$name" fixed "observed problems gone: no new problem left" "$secs"; rm -f "$sess/$kind-adapter-observed"; fi
    else line="$name	failed	exit $code, $n new problem line(s)	$secs"; fi
  fi
  printf '%s\n%s\n' "$afp" "$line" >"$sess/$kind-adapter"
  if [ -n "$new" ]; then
    key="$(printf '%s' "$new" | shasum | cut -d' ' -f1)"
    if ! sh_adapter_blocking "$kind"; then
      # In observation (H2 of #105), each set of new problems is logged once, and its end
      # ("fixed", when the new problems are gone) too, so the report can tell whether the
      # check's findings get fixed and propose that it block.
      if [ "$key" != "$(cat "$sess/$kind-adapter-observed" 2>/dev/null)" ]; then
        printf '%s' "$key" >"$sess/$kind-adapter-observed"
        sh_catch "$name" observed "$n new problem line(s); not blocking ($kind.blocking is false)" "$secs"
      fi
    elif [ "$key" = "$(cat "$sess/$kind-adapter-blocked" 2>/dev/null)" ]; then
      sh_catch "$name" left-failing "the same new problems; $(sh_agent_name) stopped without fixing them" "$secs"
    else
      printf '%s' "$key" >"$sess/$kind-adapter-blocked"
      sh_catch "$name" blocked "$n new problem line(s)" "$secs"
      adapter_line "$line"
      ev_write failed "the project's $label found new problems"
      {
        printf "The project's %s (%s) found problems that were not there when the session started:\n\n" "$label" "$cmd"
        printf '%s\n' "$out" | tail -n 40
        printf '\n%s If it is intended, say so in one line and stop again without editing: the check does not block twice on the same problems.\n' "$fix"
      } >&2
      exit 2
    fi
  fi
  adapter_line "$line"
}
# An adapter's line goes in the record, and is kept for ev_keep.
adapter_lines=""
adapter_line() { printf '%s\n' "$1" >>"$ev_lines"; adapter_lines="$adapter_lines$1"$'\n'; }
[ -z "$docs_cmd" ] || run_adapter docs "$docs_cmd" "$(sh_docs_fingerprint)"
[ -z "$lint_cmd" ] || run_adapter lint "$lint_cmd" "$fp"
[ -z "$format_cmd" ] || run_adapter format "$format_cmd" "$fp"

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
# Attempts add up within one turn (#143). A Stop that does not follow a block (stop_hook_active
# false) starts a new count: after an interrupted turn the old one would make the first failure
# of the next turn the last attempt, which the agent never sees. Hosts that do not send the
# field keep one count, as before.
[ "$(printf '%s' "$SH_INPUT" | jq -r 'if .stop_hook_active == false then "new" else "" end' 2>/dev/null)" != new ] || failures=0

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
  warn_user "swift-harness: the end-of-turn check did not run '$command_line', because this project's verify command is new or changed since you last approved it. These changes are not verified. Review the command and the files it runs, then $(sh_approve_how)."
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
out2=""
trap 'rm -f "$out" ${out2:+"$out2"}' EXIT
# From here the checks run (#144). The marker and a "not-finished" record are written first, and
# replaced by the result at the end: a hook stopped in between (its timeout) leaves both, so the
# record does not keep saying what an earlier run found on other code.
printf '%s\n%s\n%s\n' "$fp" "$(date +%s)" "$$" >"$sess/running"
ev_write not-finished "the checks started and have not ended: if this stays, the hook was stopped before its result (its timeout is 900 s)" now
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
    # The result bundle's lines first (verify.sh, #147: "failed test: <id>: <message>"), else the
    # text of xcodebuild, xcbeautify or XCTest.
    flaky="$(awk 'n < 5 && /^[[:space:]]*failed test: /{ sub(/^[[:space:]]*failed test: /, ""); split($0, a, ": "); print a[1]; n++ }' "$out" |
      paste -sd, - | sed 's/,/, /g')"
    [ -n "$flaky" ] || flaky="$(grep -E '^Failing tests:|^[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*\(\)$|✘ Test |Test Case .* failed' "$out" | grep -v '^Failing tests:' |
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

rm -f "$sess/running"
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
