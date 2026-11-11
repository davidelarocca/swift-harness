#!/bin/bash
# SessionStart (startup|resume|clear): record the current code state as the session
# baseline, so the Stop hook only verifies what changes during the session, and report
# missing tools. The baseline is a starting point, not a verification result: if the last
# check failed on this exact code, say so.

. "$(dirname "$0")/lib.sh"

if ! sh_has_jq; then
  [ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/swift-harness.json" ] &&
    echo "swift-harness: jq is not installed, so its quality hooks are inactive. Tell the user to run: brew install jq"
  exit 0
fi
if ! sh_init; then
  sh_guest_missing_notice
  exit 0
fi

verify_cmd="$(sh_cfg '.verify.command' 'scripts/verify.sh fast')"

# After a compaction (#10): give Claude the facts the hooks know, which a summary can lose or
# get wrong, and keep the session baseline as it is. Repository docs stay the source of truth.
if [ "$(sh_in '.source')" = "compact" ]; then
  git -C "$SH_ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  state="$(sh_state_path)"
  [ -d "$state" ] || exit 0
  "$(dirname "$0")/checkpoint.sh" "$SH_ROOT" "$state" "$verify_cmd" "$(sh_session_path "$state")"
  exit 0
fi

if git -C "$SH_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  state="$(sh_state_dir)" && sess="$(sh_session_dir "$state")" && {
    # Session folders untouched for SH_SESSION_MAX_DAYS days, and the per-session files that
    # lived in the project folder before #61.
    find "$state/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +"$SH_SESSION_MAX_DAYS" -exec rm -rf {} + 2>/dev/null
    (cd "$state" && rm -f baseline failures verified unapproved-warned contract-start.json contract-start.none \
      contract-warned snapshots-start snapshots-warned snapshots-approved protected-start protected-warned \
      protected-edited session-head session-dirty security-start security-start-unreviewed security-approval-warned)
    fp="$(sh_identity)"
    # A resumed session keeps what it recorded when it started (#143): a turn interrupted before
    # its end left edits that no Stop has seen, and taking the code as it is now would turn them
    # into the starting code, never verified and never reported. Only the docs list is taken
    # again below: that check blocks, and must not blame the session for what changed meanwhile.
    resumed=false
    [ "$(sh_in '.source')" = resume ] && [ -s "$sess/baseline" ] && resumed=true
    if [ "$resumed" = false ]; then
      printf '%s' "$fp" > "$sess/baseline"
      printf '0' > "$sess/failures"
      # The contract as it was at session start, for contract-watch.sh (#13).
      rm -f "$sess/contract-start.json" "$sess/contract-start.none" "$sess/contract-warned"
      if [ -f "$SH_ROOT/$SH_CONTRACT" ]; then
        cp "$SH_ROOT/$SH_CONTRACT" "$sess/contract-start.json"
      else
        : >"$sess/contract-start.none"
      fi
      # The snapshot baselines as they were at session start, for snapshot-watch.sh (#9).
      rm -f "$sess/snapshots-warned" "$sess/snapshots-approved"
      sh_snapshot_list "$(sh_snapshots)" >"$sess/snapshots-start"
      # The performance baselines too (#33), for the same notice.
      rm -f "$sess/performance-warned" "$sess/performance-approved"
      sh_snapshot_list "$(sh_performance)" >"$sess/performance-start"
      # What the checks stand on (tests, assertions, skips, lint), for weaken-watch.sh (#146).
      rm -f "$sess/weaken-warned"
      sh_weaken_list >"$sess/weaken-start"
      # The project's own lint and format checks (#125): their problems at session start, when
      # approved, and the code they stand on, so the end of a turn runs them only after a change.
      for kind in lint format; do
        rm -f "$sess/$kind-start" "$sess/$kind-adapter" "$sess/$kind-adapter-blocked" "$sess/$kind-adapter-observed"
        a_cmd="$(sh_adapter_command "$kind")"
        [ -n "$a_cmd" ] || continue
        if sh_verify_approved "$verify_cmd" "$state"; then
          (cd "$SH_ROOT" && bash -c "$a_cmd" 2>&1 </dev/null) | sh_adapter_keys >"$sess/$kind-start"
        else
          : >"$sess/$kind-start"
        fi
        printf '%s\n%s: %s\tnot run\tno build input changed in this session\n' "$fp" "$kind" "$a_cmd" >"$sess/$kind-adapter"
      done
    fi
    # The docs problems already there at session start, for docs-watch.sh (#70).
    rm -f "$sess/docs-start" "$sess/docs-blocked" "$sess/docs-warned"
    rm -f "$sess/docs-adapter" "$sess/docs-adapter-blocked"
    docs_cmd="$(sh_docs_command)"
    if [ -n "$docs_cmd" ]; then
      # The project's own docs check (#105): its problems at session start, when approved.
      if sh_verify_approved "$verify_cmd" "$state"; then
        (cd "$SH_ROOT" && bash -c "$docs_cmd" 2>&1 </dev/null) | sh_adapter_keys >"$sess/docs-start"
      else
        : >"$sess/docs-start"
      fi
    else
      sh_docs_on && "$(dirname "$0")/docs.sh" check "$SH_ROOT" 2>/dev/null | sh_docs_keys >"$sess/docs-start"
    fi
    if [ "$resumed" = false ]; then
      # Protected files as they were at session start, for protected-watch.sh (#11).
      rm -f "$sess/protected-warned" "$sess/protected-edited"
      sh_protected_list >"$sess/protected-start"
      # Where the session started, for the checkpoint after a compaction (#10).
      git -C "$SH_ROOT" rev-parse HEAD >"$sess/session-head" 2>/dev/null || : >"$sess/session-head"
      sh_dirty_list >"$sess/session-dirty"
      # The security settings as they are the first time, the baseline the user can approve (#32).
      [ "$(sh_cfg '.security.enabled' 'true')" = "true" ] &&
        "$(dirname "$0")/security.sh" --record --project "$SH_ROOT" >/dev/null 2>&1
      # The approved security state at session start: an approval made during the session is
      # shown to the user at the end of the turn (protected-watch.sh), whoever ran it.
      rm -f "$sess/security-start" "$sess/security-start-unreviewed" "$sess/security-approval-warned"
      [ -f "$state/security-approved" ] && cp "$state/security-approved" "$sess/security-start"
      [ -f "$state/security-unreviewed" ] && : >"$sess/security-start-unreviewed"
    fi
    if [ -n "$fp" ] && [ "$fp" = "$(cat "$state/failed" 2>/dev/null)" ]; then
      echo "swift-harness: the last verification ('$verify_cmd') failed on the current code and has not passed since. Treat the project as not verified."
    fi
    if [ "$(sh_cfg '.verify.enabled' 'true')" = "true" ] && ! sh_verify_approved "$verify_cmd" "$state"; then
      echo "swift-harness: the verify command '$verify_cmd' is not approved for this project (it is new, or it or a file it runs changed since the last approval). The end-of-turn check does not run it, so code changes are not verified. Ask the user to review it and $(sh_approve_how). Do not run the approval yourself."
    fi
    # Files blocked by lintBlocking are re-linted when the code changes; say so now, since
    # unchanged code is not re-checked.
    if [ "$(sh_cfg '.lintBlocking' 'false')" = "true" ] && [ -s "$state/lint-pending" ]; then
      pending="$(head -5 "$state/lint-pending" | paste -sd, - | sed 's/,/, /g')"
      echo "swift-harness: lintBlocking is on and these files failed SwiftLint at the last check: $pending. They are linted again at the end of the next turn that changes code."
    fi
  }
fi

missing=()
case "$(sh_cfg '.format' 'swiftformat')" in
  swiftformat) command -v swiftformat >/dev/null 2>&1 || missing+=("swiftformat") ;;
  swift-format) xcrun --find swift-format >/dev/null 2>&1 || command -v swift-format >/dev/null 2>&1 || missing+=("swift-format") ;;
esac
[ "$(sh_cfg '.lint' 'swiftlint')" = "swiftlint" ] && { command -v swiftlint >/dev/null 2>&1 || missing+=("swiftlint"); }

verify_bin="${verify_cmd%% *}"
if [ "$(sh_cfg '.verify.enabled' 'true')" = "true" ] && [[ "$verify_bin" == */* ]] && [ ! -x "$SH_ROOT/$verify_bin" ]; then
  echo "swift-harness: verify command '$verify_bin' is missing or not executable. The Stop check will fail until it exists."
fi

# Guest mode (#71): say once per session that the project's own rules come first.
if [ "$(sh_cfg '.guest' 'false')" = true ] && [ "$(sh_in '.source')" != compact ]; then
  echo "swift-harness: guest mode. This project's own agent rules and docs (CLAUDE.md, AGENTS.md and what they point to) are the source of truth; swift-harness adds only its end-of-turn checks. Do not add swift-harness files, templates or rules to the project unless the user asks."
fi
# swift-format without a config file uses 2-space indentation and rewrites whole files.
if [ "$(sh_cfg '.format' 'swiftformat')" = "swift-format" ] && [ ! -f "$SH_ROOT/.swift-format" ]; then
  echo "swift-harness: format is swift-format but the project has no .swift-format file, so swift-format applies its defaults (2-space indentation) to every file Claude edits. Tell the user; /swift-harness:setup ships a template with 4 spaces."
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "swift-harness: not installed: ${missing[*]}. Those checks are skipped. Install with: brew install ${missing[*]}"
  if [ "$(sh_cfg '.lintBlocking' 'false')" = "true" ] && [[ " ${missing[*]} " == *" swiftlint "* ]]; then
    echo "swift-harness: lintBlocking is on, so the end-of-turn check fails after code changes until SwiftLint is installed."
  fi
fi
exit 0
