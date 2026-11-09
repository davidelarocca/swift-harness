#!/bin/bash
# Shared helpers for swift-harness hooks. Sourced, not executed.
# shellcheck disable=SC2034 # SH_* result variables are read by the scripts that source this file
# Every hook is a no-op unless the project contains .claude/swift-harness.json.

# GUI-launched sessions often miss Homebrew on PATH. Append these folders when missing, so
# tools already on PATH keep their order. SWIFT_HARNESS_EXTRA_PATH overrides the list
# (colon-separated, empty for none).
sh_old_ifs="$IFS"
IFS=:
for sh_dir in ${SWIFT_HARNESS_EXTRA_PATH-/opt/homebrew/bin:/usr/local/bin}; do
  [ -n "$sh_dir" ] || continue
  case ":$PATH:" in *":$sh_dir:"*) ;; *) PATH="$PATH:$sh_dir" ;; esac
done
IFS="$sh_old_ifs"
unset sh_dir sh_old_ifs
export PATH

SH_INPUT="$(cat)"

sh_has_jq() { command -v jq >/dev/null 2>&1; }

# Read a field from the hook input JSON. Empty string when missing.
sh_in() { printf '%s' "$SH_INPUT" | jq -r "$1 // empty" 2>/dev/null; }

# Project root: git top level of the hook's cwd (follows worktrees), else CLAUDE_PROJECT_DIR.
# Always a physical path (symlinks resolved), like the output of sh_realpath.
sh_root() {
  local cwd root
  cwd="$(sh_in '.cwd')"
  [ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root="${CLAUDE_PROJECT_DIR:-$cwd}"
  (cd "$root" 2>/dev/null && pwd -P) || printf '%s' "$root"
}

# Remove ".", ".." and repeated slashes from an absolute path without touching the disk,
# the same way Claude Code's file tools resolve a path before writing.
sh_normpath() {
  local part
  local -a parts kept=()
  IFS=/ read -ra parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      "" | .) ;;
      ..) [ "${#kept[@]}" -eq 0 ] || unset "kept[$((${#kept[@]} - 1))]" ;;
      *) kept+=("$part") ;;
    esac
  done
  local IFS=/
  printf '/%s' "${kept[*]-}"
}

# Physical absolute path of a file that may not exist yet: normalise the path, resolve the
# deepest existing folder with pwd -P, and follow a symlink in the last component.
sh_realpath() {
  local path dir rest link hops=0
  case "$1" in /*) path="$1" ;; *) path="$SH_ROOT/$1" ;; esac
  while :; do
    path="$(sh_normpath "$path")"
    dir="$path"
    rest=""
    while [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
      rest="/${dir##*/}$rest"
      dir="${dir%/*}"
      [ -n "$dir" ] || dir="/"
    done
    dir="$(cd "$dir" 2>/dev/null && pwd -P)" || dir="/"
    path="${dir%/}$rest"
    [ -L "$path" ] && [ "$hops" -lt 16 ] || break
    link="$(readlink "$path")"
    case "$link" in /*) path="$link" ;; *) path="${path%/*}/$link" ;; esac
    hops=$((hops + 1))
  done
  printf '%s' "$path"
}

# Path relative to the project root, symlinks resolved. Empty when outside the project.
sh_relpath() {
  local path
  path="$(sh_realpath "$1")"
  case "$path" in
    "$SH_ROOT"/*) printf '%s' "${path#"$SH_ROOT"/}" ;;
  esac
}

# True when the resolved path $1 is the protected path $2, or (when $2 is a folder) sits under it,
# compared by filesystem identity. So a case-variant name on a case-insensitive disk, or a symlink
# alias, still matches, where a plain string compare would miss it. Both must exist for a match.
sh_same_or_under() { # $1 resolved path, $2 protected path
  local anc
  [ -e "$2" ] || return 1
  [ "$1" -ef "$2" ] && return 0
  [ -d "$2" ] || return 1
  anc="$(dirname "$1")"
  while [ "$anc" != "/" ] && [ "$anc" != "." ] && [ -n "$anc" ]; do
    [ "$anc" -ef "$2" ] && return 0
    case "$anc" in "$SH_ROOT"/*) ;; *) return 1 ;; esac
    anc="$(dirname "$anc")"
  done
  return 1
}

# Read a value from the project config, with a default.
sh_cfg() {
  local value
  value="$(jq -r "$1 | if . == null then empty else . end" "$SH_CONFIG" 2>/dev/null)"
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$2"
}

# Per-project state directory (survives plugin updates). sh_state_path only computes it,
# for read-only callers such as doctor.sh; sh_state_dir also creates it.
sh_state_path() {
  local base key
  base="${CLAUDE_PLUGIN_DATA:-$HOME/.cache/swift-harness}"
  key="$(printf '%s' "$SH_ROOT" | shasum | cut -c1-16)"
  printf '%s' "$base/state/$key"
}
sh_state_dir() {
  local dir
  dir="$(sh_state_path)"
  mkdir -p "$dir" && printf '%s' "$dir"
}

# Catch log (#86): one JSON line per thing a hook caught and per way it ended, in the
# project's state folder; it never leaves the machine. report.sh summarises it.
#   kind: blocked (the turn or the edit was stopped), asked (the user was asked first),
#         reported (told, not blocked), skipped (a check did not run), fixed (passed after a
#         block), approved (the user approved it), left-failing (Claude stopped on a failure)
# Never fails the hook: a log that cannot be written is skipped.
# A hook that knows the code identity (the end-of-turn check) sets SH_CATCH_CODE, and a check
# that ran passes its duration in seconds (#110).
# The agent the hooks run for, by name, for messages (#122): SH_AGENT is set by codex-hook.sh and
# check.sh, and is Claude Code otherwise.
sh_agent_name() {
  case "${SH_AGENT:-claude}" in claude) printf 'Claude' ;; codex) printf 'Codex' ;; *) printf 'the agent' ;; esac
}

# How the user approves the verify command, for messages: a slash command exists only in Claude
# Code. This names the script, never a digest: the approval stays the user's to give.
sh_approve_how() {
  case "${SH_AGENT:-claude}" in
    claude) printf 'type /swift-harness:approve-verify' ;;
    *) printf "use /swift-harness:approve-verify in Claude Code, or approve-verify.sh in the user's own terminal (README, \"Codex runs the same hooks\")" ;;
  esac
}

sh_catch() { # $1 check, $2 kind, $3 what, $4 seconds (optional)
  local dir line
  dir="$(sh_state_dir 2>/dev/null)" || return 0
  line="$(jq -nc --arg check "$1" --arg kind "$2" --arg what "${3:-}" --arg session "$(sh_session_id)" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg code "${SH_CATCH_CODE:-}" --arg seconds "${4:-}" --arg agent "${SH_AGENT:-claude}" '
    {time: $time, session: $session, agent: $agent, check: $check, kind: $kind, what: $what}
    + (if $code == "" then {} else {code: $code} end)
    + (if ($seconds | test("^[0-9]+$")) then {seconds: ($seconds | tonumber)} else {} end)' 2>/dev/null)" || return 0
  printf '%s\n' "$line" >>"$dir/catches.jsonl" 2>/dev/null || true
}

# Per-session state (#61): what a session compares with at the end of each turn (the code,
# protected files, snapshot baselines, contract and approved security settings as they were
# when it started, and the notices already shown) lives in sessions/<session_id>/ inside the
# project's state folder, so two sessions on one folder do not overwrite each other's lists.
# Approvals, the security baseline, the last verification result and lint-pending stay per
# project: they are shared on purpose. Without a session_id (older Claude Code) every session
# uses sessions/none, as one shared folder did before.
SH_SESSION_MAX_DAYS=14
sh_session_id() {
  local id
  id="$(sh_in '.session_id' | LC_ALL=C tr -cd 'A-Za-z0-9_-' | cut -c1-64)"
  printf '%s' "${id:-none}"
}
sh_session_path() { printf '%s/sessions/%s' "$1" "$(sh_session_id)"; } # $1 state folder
# Creates it and refreshes its date, which the cleanup at session start goes by.
sh_session_dir() {
  local dir
  dir="$(sh_session_path "$1")"
  mkdir -p "$dir" && touch "$dir" && printf '%s' "$dir"
}
# Append standard input to <file> in every session folder that has <marker>: a guarded edit
# or an approval concerns every session open on the project, not just the one that made it.
sh_sessions_append() { # $1 state folder, $2 file, $3 marker
  local lines dir
  lines="$(cat)"
  [ -n "$lines" ] || return 0
  for dir in "$1"/sessions/*/; do
    [ -f "$dir$3" ] && printf '%s\n' "$lines" >>"$dir$2"
  done
  return 0
}

# Files that can change the result of a build or test run. Git pathspecs: "*" also matches "/".
# Everything under a SwiftPM Sources/ or Tests/ folder counts: a target's resources and test
# fixtures can live in any subfolder. Xcode per-user state and Finder metadata do not.
SH_BUILD_INPUTS=(
  '*.swift' '*Package.resolved' '*.xcworkspacedata'
  '*.pbxproj' '*.xcconfig' '*.xcscheme' '*.xctestplan' '*.plist' '*.entitlements'
  '*.xcassets/*' '*.xcstrings' '*.strings' '*.stringsdict' '*.xib' '*.storyboard'
  '*.xcdatamodeld/*' '*.xcmappingmodel/*' '*.metal' '*.h' '*.m' '*.mm' '*.c'
  '*/Resources/*' '*__Snapshots__/*'
  'Sources/*' '*/Sources/*' 'Tests/*' '*/Tests/*'
  '.swiftlint.yml' '.swiftformat' '.swift-format' '.claude/swift-harness.json' 'scripts/*'
  'docs/architecture-contracts.json'
  ':!.build/*' ':!*/.build/*' ':!*DerivedData/*' ':!*xcuserdata/*' ':!*.DS_Store'
)

# Architecture contract (#13), checked by contracts.sh. Also a build input above.
SH_CONTRACT="docs/architecture-contracts.json"

# Component registry (#7), checked by registry.sh. Part of the fingerprint, so a registry
# fixed after a failed check is checked again.
sh_registry() { local p; p="$(sh_cfg '.registry.path' 'docs/COMPONENT_REGISTRY.md')"; printf '%s' "${p#./}"; }
sh_registry_on() { [ "$(sh_cfg '.registry.enabled' 'true')" = "true" ] && [ -f "$SH_ROOT/$(sh_registry)" ]; }

# Layout contract (#34), checked by layout.sh and measured by the project's tests. Part of the
# fingerprint: the tests read it, so an edited contract can change their result.
sh_layout() { local p; p="$(sh_cfg '.layout.path' 'docs/LAYOUT_CONTRACT.md')"; printf '%s' "${p#./}"; }
sh_layout_on() { [ "$(sh_cfg '.layout.enabled' 'true')" = "true" ] && [ -f "$SH_ROOT/$(sh_layout)" ]; }

# What a pass of the verify command covered (SH160-01). The generated verify.sh ends with
#   swift-harness-result/1: <passed|partial|failed>; checked: <platforms>; tested: <platforms>; not checked: <platforms>
# (lists ", "-separated or "none"); before 1.6.1 it printed only
#   verify <mode>: PARTIAL (passed on ...; not checked on <platforms>: ...)
# The last such line counts, and it can only lower the exit code's outcome: an exit other than 0
# is a failure whatever it says. The Stop hook keeps the pass in <state>/coverage:
#   <fingerprint> / outcome: <passed|partial> / checked: / tested: / not checked:
# so doctor, the checkpoint and later reports read the same thing. A custom command with no such
# line leaves no coverage: its pass is a pass, with its platforms unknown.
sh_verify_result() { # $1 verify output (a file); prints "outcome\tchecked\ttested\tnot checked", or nothing
  local line legacy
  line="$(grep -E '^swift-harness-result/1: (passed|partial|failed)(;|$)' "$1" | tail -1)"
  if [ -n "$line" ]; then
    printf '%s' "${line#swift-harness-result/1: }" | awk -F'; ' '{
      o = $1; c = t = n = "?"
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^checked: /) c = substr($i, 10)
        else if ($i ~ /^tested: /) t = substr($i, 9)
        else if ($i ~ /^not checked: /) n = substr($i, 14)
      }
      printf "%s\t%s\t%s\t%s", o, c, t, n
    }'
    return
  fi
  legacy="$(sed -n -E 's/^verify (fast|full): PARTIAL \(passed on ([^;]*); not checked on ([^:]+):.*$/\2\t\3/p' "$1" | tail -1)"
  [ -n "$legacy" ] && printf 'partial\t%s\t?\t%s' "${legacy%%$'\t'*}" "${legacy#*$'\t'}"
}
# The field $3 (outcome, checked, tested, not checked) of the coverage recorded for fingerprint
# $2 in state folder $1, or nothing when there is none for it.
sh_verify_coverage() {
  [ "$(sed -n 1p "$1/coverage" 2>/dev/null)" = "$2" ] || return 0
  sed -n "s/^$3: //p" "$1/coverage" | head -1
}

# Docs references (#70), checked by docs.sh at the end of each turn (docs-watch.sh) and by
# doctor. Not part of the fingerprint: it reads Markdown only, so a docs edit never re-runs the
# build. sh_docs_keys turns its problem lines into keys without line numbers (and without the
# sizes of the session budget), so a problem that only moved is not new.
sh_docs_on() { [ "$(sh_cfg '.docs.enabled' 'true')" = "true" ]; }

# Adapter for the project's own docs check (#105): docs.command runs instead of docs.sh, at the
# end of a turn when the docs changed, inside stop-verify.sh. It is the project's code, so it is
# part of the verify approval. docs.blocking false records it without ever blocking.
sh_docs_command() { sh_docs_on && sh_cfg '.docs.command' ''; }
sh_docs_blocking() { [ "$(sh_cfg '.docs.blocking' 'true')" != "false" ]; }
# The docs it reads (docs.paths: CLAUDE.md, AGENTS.md and docs/ by default), as one digest.
sh_docs_fingerprint() {
  local p
  {
    jq -r '.docs.paths // ["CLAUDE.md", "AGENTS.md", "docs"] | .[] | strings' "$SH_CONFIG" 2>/dev/null | while IFS= read -r p; do
      p="${p#./}"; p="${p%/}"
      if [ -f "$SH_ROOT/$p" ]; then printf '%s\n' "$p"
      elif [ -d "$SH_ROOT/$p" ]; then (cd "$SH_ROOT" && find "$p" -type f -not -path '*/.build/*' | sort); fi
    done | while IFS= read -r p; do printf '%s %s\n' "$p" "$(shasum <"$SH_ROOT/$p" | cut -d' ' -f1)"; done
  } | shasum | cut -d' ' -f1
}
# The output of a project check as keys: line numbers removed, sorted, so a problem that only
# moved is not new.
sh_adapter_keys() { sed -E 's/:[0-9]+(:[0-9]+)?(:|$)/\2/g' | grep -v '^[[:space:]]*$' | sort -u; }
sh_docs_keys() {
  grep '^- ' | sed -E 's/^- ([^:]+):[0-9]+: /\1: /; s/: the files read into every session are .*/: the files read into every session are over the budget/' | LC_ALL=C sort -u
}

# Approved snapshot baselines (#9): compared by the project's tests, written only by
# /swift-harness:approve-snapshots. Part of the fingerprint: a changed baseline changes the
# test result. New images wait in SH_SNAPSHOT_CANDIDATES.
sh_snapshots() { local p; p="$(sh_cfg '.snapshots.path' 'snapshots')"; p="${p#./}"; printf '%s' "${p%/}"; }
SH_SNAPSHOT_CANDIDATES=".build/swift-harness/snapshots"
# Approved performance baselines (#33): compared by the project's budget tests, written only by
# /swift-harness:approve-performance. Part of the fingerprint like the snapshot baselines.
sh_performance() { local p; p="$(sh_cfg '.performance.path' 'performance')"; p="${p#./}"; printf '%s' "${p%/}"; }
SH_PERFORMANCE_CANDIDATES=".build/swift-harness/performance"
# "<sha256> <path>" for every file in the baselines folder, sorted, for snapshot-watch.sh.
sh_snapshot_list() {
  [ -d "$SH_ROOT/$1" ] || return 0
  (cd "$SH_ROOT" && find "$1" -type f ! -name .DS_Store -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null) |
    sed 's/  / /' | LC_ALL=C sort
}

# "<sha256> <path>" for every file under the protected paths, sorted, for protected-watch.sh
# (#11). Placeholders and paths that do not exist are skipped.
sh_protected_list() {
  local p
  jq -r '.protectedPaths[]? // empty' "$SH_CONFIG" 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] && [[ "$p" != *"{{"* ]] || continue
    p="${p#./}"
    p="${p%/}"
    [ -e "$SH_ROOT/$p" ] || continue
    # -H: a protected path that is itself a symlink is followed, as the guard resolves it.
    (cd "$SH_ROOT" && find -H "$p" -type f ! -name .DS_Store -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null)
  done | sed 's/  / /' | LC_ALL=C sort -u
}

# "<sha256> <path>" for every modified or untracked file, "deleted <path>" for deleted ones,
# sorted: what differs from HEAD, for the checkpoint after a compaction (#10).
sh_dirty_list() {
  (
    cd "$SH_ROOT" || exit 0
    git ls-files -m -o --exclude-standard -z 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | sed 's/  / /'
    git ls-files -d 2>/dev/null | sed 's/^/deleted /'
  ) | LC_ALL=C sort -u
}

# Plugin version, from the manifest next to these scripts.
SH_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null | head -1)"

# What a verification result is about (#18): the code state and the plugin version. The
# project's policy (lintBlocking, verify.command, ...) is part of the code state, since
# .claude/swift-harness.json and scripts/ are build inputs. A plugin update can make the
# checks stricter or change the defaults, so a result recorded by another version does not
# count: unchanged code is verified again once.
sh_identity() {
  printf '%s\nswift-harness %s\n' "$(sh_fingerprint)" "${SH_VERSION:-unknown}" | shasum | cut -d' ' -f1
}

# Fingerprint of the code state: HEAD, uncommitted changes to build inputs (including
# deletions), and the content of untracked build inputs.
sh_fingerprint() {
  {
    git -C "$SH_ROOT" rev-parse HEAD 2>/dev/null
    git -C "$SH_ROOT" diff HEAD -- "${SH_BUILD_INPUTS[@]}" "$(sh_registry)" "$(sh_layout)" "$(sh_snapshots)" "$(sh_performance)" 2>/dev/null
    git -C "$SH_ROOT" ls-files -z --others --exclude-standard -- "${SH_BUILD_INPUTS[@]}" "$(sh_registry)" "$(sh_layout)" "$(sh_snapshots)" "$(sh_performance)" 2>/dev/null |
      while IFS= read -r -d '' f; do shasum "$SH_ROOT/$f" 2>/dev/null; done
  } | shasum | cut -d' ' -f1
}

# Lint one file with SwiftLint and classify the result in SH_LINT_RESULT:
#   clean | warnings | errors | broken | excluded | missing
# "errors" means serious violations (SwiftLint exits 2). "broken" means SwiftLint did not
# apply its rules correctly: a non-zero exit without violations, or a configuration problem
# on stderr (SwiftLint skips a rule with an invalid configuration or regex and exits 0).
# "excluded" is a file left out by the `excluded` list (--force-exclude finds no files).
# Also sets SH_LINT_STATUS, SH_LINT_OUTPUT (violations, root-relative) and SH_LINT_ERRORS
# (stderr), both bounded.
sh_swiftlint() {
  local err
  SH_LINT_STATUS=0
  SH_LINT_OUTPUT=""
  SH_LINT_ERRORS=""
  if ! command -v swiftlint >/dev/null 2>&1; then
    SH_LINT_RESULT=missing
    return
  fi
  err="$(mktemp -t swift-harness-lint.XXXXXX)"
  SH_LINT_OUTPUT="$(cd "$SH_ROOT" && swiftlint lint --quiet --force-exclude "$1" 2>"$err")"
  SH_LINT_STATUS=$?
  SH_LINT_ERRORS="$(grep -v '^[[:space:]]*$' "$err" | head -20)"
  rm -f "$err"
  SH_LINT_OUTPUT="$(printf '%s\n' "$SH_LINT_OUTPUT" | grep -E ': (warning|error):' | head -20)"
  # Keep the prefix in a variable: bash 3.2 treats a literal "/" inside a quoted
  # ${var//pattern/} pattern as the separator.
  local prefix="$SH_ROOT/"
  SH_LINT_OUTPUT="${SH_LINT_OUTPUT//"$prefix"/}"

  if [ "$SH_LINT_STATUS" -ne 0 ] && grep -q 'No lintable files found' <<<"$SH_LINT_ERRORS"; then
    SH_LINT_RESULT=excluded
  elif [ "$SH_LINT_STATUS" -ne 0 ] && ! grep -q ': error:' <<<"$SH_LINT_OUTPUT"; then
    SH_LINT_RESULT=broken
  elif grep -qiE 'invalid|error:|fatal|could not' <<<"$SH_LINT_ERRORS"; then
    SH_LINT_RESULT=broken
  elif [ "$SH_LINT_STATUS" -ne 0 ]; then
    SH_LINT_RESULT=errors
  elif [ -n "$SH_LINT_OUTPUT" ]; then
    SH_LINT_RESULT=warnings
  else
    SH_LINT_RESULT=clean
  fi
}

# Files that failed SwiftLint under lintBlocking. The Stop check re-lints them, so a
# blocked edit cannot end the turn as verified.
sh_lint_pending_add() {
  local list="$1/lint-pending"
  grep -qxF -- "$2" "$list" 2>/dev/null || printf '%s\n' "$2" >>"$list"
}
sh_lint_pending_remove() {
  local list="$1/lint-pending"
  [ -f "$list" ] || return 0
  grep -vxF -- "$2" "$list" >"$list.tmp"
  mv "$list.tmp" "$list"
}

# ---------- verify command approval (#6) ----------
# The Stop hook runs verify.command, which comes from the repository. It runs only after the
# user approves it with /swift-harness:approve-verify. The approval lives in the per-project
# state folder, outside the repository, and covers the project path, the command text,
# the content of every file the command names (scripts/verify.sh, or a script passed to an
# interpreter) and of every file or folder listed in verify.inputs. The command is split on
# spaces, not parsed as shell: with quotes or shell syntax, the files it runs may not be
# found, and sh_verify_unparsed says so. Files read without being named are not covered.

# Characters that make the command more than space-separated words.
sh_verify_unparsed() { [[ "$1" == *[\"\'\`\$\;\|\&\<\>\(\)\\]* ]]; }

# What an approval covers, one line each: "root", "command", "file <word> <sha256>", then
# "input<TAB><path><TAB><sha256 | missing | outside>" for verify.inputs.
sh_verify_manifest() {
  local word path input rel sha
  local -a words
  printf 'root %s\ncommand %s\n' "$SH_ROOT" "$1"
  # The docs adapter (#105) runs the project's code too: its command and files are covered.
  local docs_cmd
  docs_cmd="$(jq -r '.docs.command // empty | strings' "$SH_CONFIG" 2>/dev/null)"
  [ -z "$docs_cmd" ] || printf 'docs-command %s\n' "$docs_cmd"
  read -ra words <<<"$1${docs_cmd:+ $docs_cmd}"
  for word in ${words[@]+"${words[@]}"}; do
    word="${word#[\"\']}"
    word="${word%[\"\']}"
    case "$word" in
      "") continue ;;
      "$SH_ROOT"/*) path="$word" ;;
      /*) continue ;; # outside the project: the repository cannot change it
      *) path="$SH_ROOT/$word" ;;
    esac
    [ -f "$path" ] || continue
    printf 'file %s %s\n' "$word" "$(shasum -a 256 <"$path" | cut -d' ' -f1)"
  done
  while IFS= read -r input; do
    [ -n "$input" ] || continue
    rel="$(sh_relpath "$input")"
    if [ -z "$rel" ]; then
      sha=outside
    elif [ -d "$SH_ROOT/$rel" ]; then
      sha="$(sh_verify_folder "$rel")"
    elif [ -f "$SH_ROOT/$rel" ]; then
      sha="$(shasum -a 256 <"$SH_ROOT/$rel" | cut -d' ' -f1)"
    else
      sha=missing
    fi
    printf 'input\t%s\t%s\n' "$input" "$sha"
  done < <(jq -r '.verify.inputs // [] | if type == "array" then .[] | strings else empty end' "$SH_CONFIG" 2>/dev/null)
}

# Scripts an approved file names, in the project, that the approval does not cover (#127): if one
# changes, the new version runs and nothing asks again. A reading of the approved files as text:
# nothing runs, a name in a comment counts, and a path built at run time is not seen, so this is
# a hint, never a proof of coverage. Prints "<script>\t<named in>", one per line.
sh_verify_uncovered() { # $1 command
  local line word path sha kind token cand rel covered=() named_from=() f c hit
  while IFS= read -r line; do
    case "$line" in
      "file "*)
        read -r _ word sha <<<"$line"
        case "$word" in "$SH_ROOT"/*) path="$word" ;; *) path="$SH_ROOT/$word" ;; esac
        covered+=("$path"); named_from+=("$path")
        ;;
      input$'\t'*)
        IFS=$'\t' read -r kind word sha <<<"$line"
        rel="$(sh_relpath "$word")"
        [ -n "$rel" ] || continue
        covered+=("$SH_ROOT/$rel")
        [ ! -f "$SH_ROOT/$rel" ] || named_from+=("$SH_ROOT/$rel")
        ;;
    esac
  done < <(sh_verify_manifest "$1")
  for f in ${named_from[@]+"${named_from[@]}"}; do
    [ "$(wc -c <"$f" 2>/dev/null || echo 0)" -le 1048576 ] || continue
    while IFS= read -r token; do
      token="${token#./}"
      hit=""
      for cand in "$SH_ROOT/${token#/}" "$(dirname "$f")/${token#/}"; do
        [ -f "$cand" ] && { hit="$cand"; break; }
      done
      [ -n "$hit" ] || continue
      rel="$(sh_relpath "$hit")"
      [ -n "$rel" ] || continue
      # -ef, not the text: on a case-insensitive disk scripts/x.sh and Scripts/x.sh are one file.
      for c in ${covered[@]+"${covered[@]}"}; do
        # Both the resolved path and the named one: a covered folder may reach the script by a link.
        if [ "$hit" -ef "$c" ] || { [ -d "$c" ] && { [[ "$SH_ROOT/$rel" == "$c"/* ]] || [[ "$hit" == "$c"/* ]]; }; }; then rel=""; break; fi
      done
      [ -z "$rel" ] || printf '%s\t%s\n' "$rel" "$(sh_relpath "$f")"
    done < <(LC_ALL=C grep -IoE '[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(sh|bash|zsh|py|rb|pl|js|mjs)\b' "$f" 2>/dev/null | sort -u)
  done | sort -u
}

# Digest of a verify.inputs folder: names and contents of every file, so added and removed
# files count, and every link with its target and the content it points to (SH130-04).
# "outside" when a link inside resolves outside the project. "linkdir" when a link points to
# another folder: a folder reached by a link cannot be hashed safely (aliases can blow a walk up
# exponentially), so the approval is refused and the user lists the real folder in verify.inputs.
# A link to a file is covered by its target's content, through `shasum <link` below.
sh_verify_folder() {
  local link res
  while IFS= read -r -d '' link; do
    res="$SH_ROOT/$1/${link#./}"
    [ -n "$(sh_relpath "$res")" ] || { printf 'outside'; return; }
    [ ! -d "$res" ] || { printf 'linkdir'; return; }
  done < <(cd "$SH_ROOT/$1" && find . -type l -print0)
  (
    cd "$SH_ROOT/$1" || exit
    find . -type f -print0 | sort -z | xargs -0 shasum -a 256
    find . -type l -print0 | sort -z | while IFS= read -r -d '' link; do
      printf 'link %s -> %s %s\n' "$link" "$(readlink "$link")" "$(shasum -a 256 <"$link" 2>/dev/null | cut -d' ' -f1)"
    done
  ) | shasum -a 256 | cut -d' ' -f1
}

# SH130-02: a command with quotes or shell syntax and no verify.inputs may run files the
# approval does not cover. Approved, but not fully covered.
sh_verify_partial() {
  sh_verify_unparsed "$1" && [ -z "$(jq -r '.verify.inputs // [] | if type == "array" then .[] | strings else empty end' "$SH_CONFIG" 2>/dev/null)" ]
}

sh_verify_digest() { sh_verify_manifest "$1" | shasum -a 256 | cut -d' ' -f1; }

# Approval across worktrees (#107). Worktrees of one repository share its git common
# directory. An approval given in one is also recorded under that repository, by a digest of
# the command and file contents without the project path, so another worktree with the same
# command and identical files inherits it. Any difference asks again; another repository
# (another common directory, even a clone with the same files) never inherits.
sh_repo_key() {
  local common
  common="$(git -C "$SH_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  common="$(cd "$SH_ROOT" && cd "$common" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "$common" | shasum | cut -c1-16
}
sh_verify_content_digest() { sh_verify_manifest "$1" | sed 1d | shasum -a 256 | cut -d' ' -f1; }
sh_repo_approvals() { local key; key="$(sh_repo_key)" || return 1; printf '%s/approvals/%s' "${CLAUDE_PLUGIN_DATA:-$HOME/.cache/swift-harness}" "$key"; }
# Records the approval of this worktree for the others. $1 command.
sh_verify_share_approval() {
  local dir
  dir="$(sh_repo_approvals)" || return 0
  mkdir -p "$dir" && printf '%s\n%s\n' "$SH_ROOT" "$(date -u +%Y-%m-%d)" >"$dir/$(sh_verify_content_digest "$1")"
}
# Where the approval of $1 comes from: "this path", "worktree <path>", or nothing. $2 state folder.
sh_verify_approval_source() {
  local dir file
  if [ -n "$2" ] && [ "$(sh_verify_digest "$1")" = "$(cat "$2/verify-approved" 2>/dev/null)" ]; then printf 'this path'; return 0; fi
  dir="$(sh_repo_approvals)" || return 1
  file="$dir/$(sh_verify_content_digest "$1")"
  [ -f "$file" ] || return 1
  printf 'worktree %s' "$(head -n 1 "$file")"
}
# $1 command, $2 state folder. Succeeds when the user approved exactly this command, here or in
# another worktree of the same repository with identical files.
sh_verify_approved() {
  [ -n "$2" ] && sh_verify_approval_source "$1" "$2" >/dev/null
}

# Platforms the project declares, read as text, never by running anything (#40): one
# "<platform>\t<file>" line each, the first file that declares it, in a fixed order.
# Sources: SUPPORTED_PLATFORMS and SDKROOT in project.pbxproj, platforms: in Package.swift.
sh_platforms() { # $1 project root
  local file sdk p found=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    for sdk in $(sed -n -e 's/.*SUPPORTED_PLATFORMS = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' -e 's/.*SDKROOT = "\{0,1\}\([a-z]*\)"\{0,1\};.*/\1/p' "$1/$file"); do
      case "$sdk" in
        macosx) p=macOS ;;
        iphoneos | iphonesimulator) p=iOS ;;
        xros | xrsimulator) p=visionOS ;;
        appletvos | appletvsimulator) p=tvOS ;;
        watchos | watchsimulator) p=watchOS ;;
        *) continue ;;
      esac
      found="$found$p	$file
"
    done
  done <<<"$(git -C "$1" ls-files -co --exclude-standard '*.xcodeproj/project.pbxproj' 2>/dev/null)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    for p in $(grep -oE '\.(macOS|iOS|tvOS|watchOS|visionOS|macCatalyst)\(' "$1/$file" | tr -d '.('); do
      [ "$p" = macCatalyst ] && p="Mac Catalyst"
      found="$found$p	$file
"
    done
  done <<<"$(git -C "$1" ls-files -co --exclude-standard 'Package.swift' '*/Package.swift' 2>/dev/null)"
  printf '%s' "$found" | awk -F'\t' '
    BEGIN { n = split("macOS,iOS,Mac Catalyst,visionOS,tvOS,watchOS", order, ",") }
    NF && !($1 in line) { line[$1] = $0 }
    END { for (i = 1; i <= n; i++) if (order[i] in line) print line[order[i]] }'
}

# A worktree without swift-harness's files, in a repository set up with guest mode --local
# (#71): the files are kept out of git, so a new worktree starts without them, and every hook
# would do nothing in silence. Tell the user and Claude, with the command that prepares it.
# Writes nothing.
sh_guest_missing_notice() {
  local common src w msg
  [ -n "${SH_ROOT:-}" ] || return 0
  common="$(git -C "$SH_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
  common="$(cd "$SH_ROOT" && cd "$common" 2>/dev/null && pwd -P)" || return 0
  grep -qxF '/.claude/swift-harness.json' "$common/info/exclude" 2>/dev/null || return 0
  src="$(git -C "$SH_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r w; do
    w="$(cd "$w" 2>/dev/null && pwd -P)" || continue
    [ "$w" != "$SH_ROOT" ] && [ -f "$w/.claude/swift-harness.json" ] && { printf '%s' "$w"; break; }
  done)"
  msg="swift-harness: this repository uses swift-harness with its files kept out of git (guest mode, --local), and this worktree does not have them, so no check runs here: no build or tests at the end of a turn, no evidence record. To prepare it: \"$(dirname "${BASH_SOURCE[0]}")/setup-guest.sh\" --project \"$SH_ROOT\" --from \"${src:-<a checkout that has them>}\" --local, then approve the verify command."
  jq -n --arg msg "$msg" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
}

# Initialise SH_ROOT and SH_CONFIG. Returns 1 when the project has not opted in.
sh_init() {
  sh_has_jq || return 1
  SH_ROOT="$(sh_root)"
  SH_CONFIG="$SH_ROOT/.claude/swift-harness.json"
  [ -f "$SH_CONFIG" ]
}
