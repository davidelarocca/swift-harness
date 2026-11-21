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
# When that top level has no config, the cwd may be inside a nested repository or a submodule
# of the project (a local package with its own .git): the repositories that enclose it are
# tried, then CLAUDE_PROJECT_DIR when it holds the cwd (#138). A worktree of the same
# repository is never passed over this way: it is a checkout of its own, set up apart, and the
# session-start notice says when it has no config.
sh_same_repository() { # $1, $2 folders: true when both are checkouts of one repository
  local a b
  a="$(cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [ "$a" = "$b" ]
}
sh_root() {
  local cwd root outer project inner hops=0
  cwd="$(sh_in '.cwd')"
  [ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root="${CLAUDE_PROJECT_DIR:-$cwd}"
  root="$( (cd "$root" 2>/dev/null && pwd -P) || printf '%s' "$root")"
  # A project in a subfolder of the repository (a monorepo: the Swift app next to other code,
  # set up from that subfolder): the nearest folder with a config from the cwd up to the top
  # level wins, also over a config at the top level, so an app's own protected paths and checks
  # are the ones used inside it.
  inner="$(cd "$cwd" 2>/dev/null && pwd -P)" || inner=""
  while [ -n "$inner" ] && [ "$inner" != "$root" ] && [[ "$inner/" == "$root"/* ]]; do
    if [ -f "$inner/.claude/swift-harness.json" ]; then
      printf '%s' "$inner"
      return
    fi
    inner="$(dirname "$inner")"
  done
  if [ ! -f "$root/.claude/swift-harness.json" ]; then
    # Else the session's project folder when it is inside this checkout.
    inner="$(cd "${CLAUDE_PROJECT_DIR:-/nonexistent}" 2>/dev/null && pwd -P)" || inner=""
    if [ -n "$inner" ] && [ "$inner" != "$root" ] && [[ "$inner/" == "$root"/* ]] && [ -f "$inner/.claude/swift-harness.json" ]; then
      printf '%s' "$inner"
      return
    fi
    outer="$root"
    while [ "$hops" -lt 8 ] && [ "$outer" != "/" ]; do
      outer="$(git -C "$(dirname "$outer")" rev-parse --show-toplevel 2>/dev/null)" || break
      outer="$(cd "$outer" 2>/dev/null && pwd -P)" || break
      sh_same_repository "$root" "$outer" && break
      if [ -f "$outer/.claude/swift-harness.json" ]; then
        printf '%s' "$outer"
        return
      fi
      hops=$((hops + 1))
    done
    project="$(cd "${CLAUDE_PROJECT_DIR:-/nonexistent}" 2>/dev/null && pwd -P)" || project=""
    if [ -n "$project" ] && [ "$project" != "$root" ] && [ -f "$project/.claude/swift-harness.json" ] &&
      [[ "$(cd "$cwd" 2>/dev/null && pwd -P)/" == "$project"/* ]] && ! sh_same_repository "$root" "$project"; then
      printf '%s' "$project"
      return
    fi
  fi
  printf '%s' "$root"
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
  local anc="$1"
  [ -e "$2" ] || return 1
  [ "$1" -ef "$2" ] && return 0
  [ -d "$2" ] || return 1
  # Walk the ancestors by stripping the last path component (no dirname subshell per step).
  while :; do
    anc="${anc%/*}"
    [ -n "$anc" ] || return 1
    [ "$anc" -ef "$2" ] && return 0
    case "$anc" in "$SH_ROOT"/*) ;; *) return 1 ;; esac
  done
}

# Why a commit made in the folder $1 would carry git's automatic identity; nothing when the
# identity is set (#2 of the 1.11 field report). Without user.email git signs with the account
# and the host name of the machine (<account>@<host name>, on a Mac ending in .local), and
# without user.name with the full name of the account. Once pushed, that leaves a repository
# only by rewriting its history. Nothing either where git refuses a commit by itself
# (user.useConfigOnly, or a host name it cannot build an address from): sh_git_refuses tells.
# The text names no value: it can end in a report pasted somewhere public.
sh_git_refuses() { ! git -C "$1" var GIT_COMMITTER_IDENT >/dev/null 2>&1; }
sh_git_identity() {
  local dir="$1" ident email
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ident="$(git -C "$dir" var GIT_COMMITTER_IDENT 2>/dev/null)" || return 0
  email="${ident#*<}"
  email="${email%%>*}"
  if [ -z "$(git -C "$dir" config user.email 2>/dev/null)" ] && [ -z "${GIT_COMMITTER_EMAIL:-}${EMAIL:-}" ]; then
    printf 'user.email is not set, so git signs commits with the account and the host name of this Mac (<account>@<host name>)'
  elif [[ "$email" == *.local || "$email" == *.localdomain || "$email" == *"(none)" ]]; then
    printf 'the email of the git identity ends in .%s: it is a host name of this Mac, not an address' "${email##*.}"
  elif [ -z "$(git -C "$dir" config user.name 2>/dev/null)" ] && [ -z "${GIT_COMMITTER_NAME:-}" ]; then
    printf 'user.name is not set, so git signs commits with the full name of the account on this Mac'
  fi
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
  sh_catch_trim "$dir/catches.jsonl"
}
# The log is bounded by count (#145): past SWIFT_HARNESS_CATCH_MAX lines (20000), the oldest
# quarter goes. Looked at only when the file is large enough to hold that many lines, and done
# under a lock, so two hooks never trim at once; a busy lock skips the trim until the next line.
sh_catch_trim() { # $1 the log
  local max lines
  max="${SWIFT_HARNESS_CATCH_MAX:-20000}"
  case "$max" in '' | *[!0-9]* | 0) max=20000 ;; esac
  [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt $((max * 60)) ] || return 0
  lines="$(wc -l <"$1" | tr -d ' ')"
  [ "$lines" -gt "$max" ] || return 0
  [ -z "$(find "$1.lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || rmdir "$1.lock" 2>/dev/null
  mkdir "$1.lock" 2>/dev/null || return 0
  tail -n "$((max - max / 4))" "$1" >"$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"
  rmdir "$1.lock" 2>/dev/null
  return 0
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
  '*.cpp' '*.cc' '*.cxx' '*.hpp' '*.hh' '*.hxx'
  '*/Resources/*' '*__Snapshots__/*'
  'Sources/*' '*/Sources/*' 'Tests/*' '*/Tests/*'
  '.swiftlint.yml' '.swiftformat' '.swift-format' '.claude/swift-harness.json' 'scripts/*'
  'project.yml' '*/project.yml' 'Podfile' '*/Podfile' 'Podfile.lock' '*/Podfile.lock' 'Cartfile' 'Cartfile.resolved'
  'docs/architecture-contracts.json'
  ':!.build/*' ':!*/.build/*' ':!*DerivedData/*' ':!*xcuserdata/*' ':!*.DS_Store'
)

# verify.watch (#177): more files whose changes make the end-of-turn check run, for what the app
# builds from other languages or tools (a Rust engine, C++ with CMake, a generated project).
# Folders, files or git pathspec globs from the project root, ":!" in front to leave something
# out. Unlike verify.inputs they are not part of the verify approval: the check runs again, the
# user is not asked again. One entry per line; entries that leave the project are dropped.
sh_watch() {
  local w neg
  jq -r '.verify.watch // [] | if type == "array" then .[] | strings else empty end' "$SH_CONFIG" 2>/dev/null |
    while IFS= read -r w; do
      neg=""
      case "$w" in ':!'*) neg=':!'; w="${w#:!}" ;; esac
      w="${w#./}"
      case "$w" in '' | /* | .. | ../* | */../* | */..) continue ;; esac
      # An entry git does not accept as a pathspec (":(glob" with no ")") would make every listing
      # fail, Swift files included: it is dropped, and the doctor names it.
      git -C "$SH_ROOT" ls-files -z -- "$neg$w" ${neg:+.} >/dev/null 2>&1 || continue
      printf '%s%s\n' "$neg" "$w"
    done
}
# The verify.watch entries that are not used: they leave the project or are not a git pathspec.
sh_watch_dropped() {
  local used w
  used="$(sh_watch)"
  jq -r '.verify.watch // [] | if type == "array" then .[] | strings else empty end' "$SH_CONFIG" 2>/dev/null |
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      grep -qxF -- "${w#./}" <<<"$used" || { [[ "$w" == ':!./'* ]] && grep -qxF -- ":!${w#:!./}" <<<"$used"; } || printf '%s\n' "$w"
    done
}
# The watch entries as pathspecs of the repository at $1 (its path from the project root, empty
# for the project itself): a nested repository or submodule gets the entries that reach into it,
# "." when an entry holds it whole, and globs as they are.
sh_watch_for() {
  local rel="$1" w neg p
  sh_watch | while IFS= read -r w; do
    neg=""
    case "$w" in ':!'*) neg=':!'; w="${w#:!}" ;; esac
    if [ -z "$rel" ]; then printf '%s%s\n' "$neg" "$w"; continue; fi
    case "$w" in
      *'*'*)
        if [[ "$w" != */* ]]; then printf '%s%s\n' "$neg" "$w"; continue; fi
        # A glob with folders ("engines/*/*.rs"): matched part by part against the path of the
        # nested repository; what is left of it is the pathspec inside.
        local gp rp i=0 fits=1 rest
        IFS=/ read -ra gp <<<"$w"
        IFS=/ read -ra rp <<<"$rel"
        while [ "$i" -lt "${#rp[@]}" ]; do
          if [ "$i" -ge "${#gp[@]}" ]; then
            [[ "${gp[${#gp[@]} - 1]}" == *'*'* ]] || fits=0 # a last "*" crosses folders
            break
          fi
          # shellcheck disable=SC2053 # the glob part is a pattern on purpose
          [[ "${rp[$i]}" == ${gp[$i]} ]] || { fits=0; break; }
          i=$((i + 1))
        done
        [ "$fits" = 1 ] || continue
        rest="$(IFS=/; printf '%s' "${gp[*]:$i}")"
        if [ -z "$rest" ]; then [ -n "$neg" ] || printf '.\n'; else printf '%s%s\n' "$neg" "$rest"; fi
        continue
        ;;
    esac
    p="${w%/}"
    case "$rel/" in "$p"/*) [ -n "$neg" ] || printf '.\n'; continue ;; esac
    case "$w" in "$rel"/*) printf '%s%s\n' "$neg" "${w#"$rel"/}" ;; esac
  done
}
# True when the path $1 (from the project root) is covered by a watch entry.
sh_watched() {
  local f="$1" w p hit=1
  while IFS= read -r w; do
    case "$w" in
      ':!'*) w="${w#:!}"; p="${w%/}"
        # shellcheck disable=SC2254 # the entry is a pattern on purpose
        case "$f" in "$p" | "$p"/* | $w) return 1 ;; esac ;;
      *) p="${w%/}"
        # shellcheck disable=SC2254
        case "$f" in "$p" | "$p"/* | $w) hit=0 ;; esac ;;
    esac
  done < <(sh_watch)
  return "$hit"
}

# One simulator or UI test run at a time on this machine (#74): simulators and UI tests are
# heavy and shared by every session of the user. The lock is a folder (mkdir is atomic) in
# /tmp/swift-harness-<uid>, or SWIFT_HARNESS_LOCK_DIR; it holds the pid, the start time and what
# runs. A lock whose process is gone is taken over.
sh_sim_lock_path() { printf '%s/simulator.lock' "${SWIFT_HARNESS_LOCK_DIR:-/tmp/swift-harness-$(id -u)}"; }
# $1 what runs. Returns 0 with the lock held (SH_SIM_LOCK set), 1 when a live run holds it
# (SH_SIM_LOCK_HOLDER says which).
sh_sim_lock_take() {
  local lock pid since what try now
  lock="$(sh_sim_lock_path)"
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  SH_SIM_LOCK=""; SH_SIM_LOCK_HOLDER=""
  for try in 1 2; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n%s\n%s\n' "$$" "$(date +%s)" "$1" >"$lock/holder"
      SH_SIM_LOCK="$lock"
      return 0
    fi
    pid="$(sed -n 1p "$lock/holder" 2>/dev/null)"; since="$(sed -n 2p "$lock/holder" 2>/dev/null)"; what="$(sed -n 3p "$lock/holder" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) pid=0 ;; esac
    case "$since" in '' | *[!0-9]*) since=0 ;; esac
    now="$(date +%s)"
    if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
      SH_SIM_LOCK_HOLDER="${what:-a run} (pid $pid, started $(((now - since) / 60)) min ago)"
      return 1
    fi
    # No holder written yet: another run is taking the lock right now.
    if [ "$pid" -eq 0 ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      SH_SIM_LOCK_HOLDER="a run that is starting"
      return 1
    fi
    rm -rf "$lock" # its process is gone
  done
  SH_SIM_LOCK_HOLDER="a run that took the lock at the same moment"
  return 1
}
sh_sim_lock_release() {
  [ -n "${SH_SIM_LOCK:-}" ] || return 0
  [ "$(sed -n 1p "$SH_SIM_LOCK/holder" 2>/dev/null)" = "$$" ] && rm -rf "$SH_SIM_LOCK"
  SH_SIM_LOCK=""
}
# $1 what runs, $2 seconds to wait (0: do not wait). Returns like sh_sim_lock_take.
sh_sim_lock_wait() {
  local waited=0
  until sh_sim_lock_take "$1"; do
    [ "$waited" -lt "${2:-0}" ] || return 1
    sleep 5
    waited=$((waited + 5))
  done
}

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

# Porting ratchet (#73), checked by porting.sh ratchet: the modules that build for iOS and the
# macOS-only uses accepted in them. Part of the fingerprint, so a recorded module is checked.
sh_ratchet() { local p; p="$(sh_cfg '.porting.ratchet' 'docs/PORTING_RATCHET.tsv')"; printf '%s' "${p#./}"; }
sh_ratchet_on() { [ -f "$SH_ROOT/$(sh_ratchet)" ]; }

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
# The same for the project's own lint and format checks (#125): "lint" or "format" as an object,
# {"command": ..., "blocking": false}, runs that command at the end of a turn when the code changed,
# instead of the harness's SwiftLint or formatter after each edit. $1 is docs, lint or format.
sh_adapter_command() {
  case "$1" in
    docs) sh_docs_command ;;
    lint | format) jq -r --arg k "$1" '.[$k] | objects | .command // empty | strings' "$SH_CONFIG" 2>/dev/null ;;
  esac
}
sh_adapter_blocking() {
  [ "$(jq -r --arg k "$1" '.[$k] | objects | .blocking | if . == false then "false" else "true" end' "$SH_CONFIG" 2>/dev/null)" != false ]
}
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
# Sorted in the C locale, as the comm that compares two such lists reads them (#139): in a UTF-8
# locale a plain sort orders case and punctuation another way, and old problems came out as new.
sh_adapter_keys() { sed -E 's/:[0-9]+(:[0-9]+)?(:|$)/\2/g' | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u; }
sh_docs_keys() {
  grep '^- ' | sed -E 's/^- ([^:]+):[0-9]+: /\1: /; s/: the files read into every session are .*/: the files read into every session are over the budget/' | LC_ALL=C sort -u
}

# Approved snapshot baselines (#9): compared by the project's tests, written only by
# /swift-harness:approve-snapshots. Part of the fingerprint: a changed baseline changes the
# test result. New images wait in SH_SNAPSHOT_CANDIDATES.
sh_snapshots() { local p; p="$(sh_cfg '.snapshots.path' 'snapshots')"; p="${p#./}"; printf '%s' "${p%/}"; }
SH_SNAPSHOT_CANDIDATES=".build/swift-harness/snapshots"
# "snapshots": {"pending": "collect"}: a new or different image does not fail its test. It
# waits, and the approval is asked once: before a commit (guard-bash.sh), and by
# `scripts/verify.sh full`, which fails while images wait. The default, "fail", fails the test.
sh_snapshots_collect() { [ "$(sh_cfg '.snapshots.pending' 'fail')" = collect ]; }
# "snapshots": {"approveNew": true}: an image with no baseline yet becomes its baseline in the
# test (Snapshot.swift), approved from "new"; one that differs from its baseline still waits.
sh_snapshots_approve_new() { [ "$(sh_cfg '.snapshots.approveNew' 'false')" = true ]; }
# The images of the last test run that are new or differ from their baseline, one name per
# line. An image made on another macOS version (not compared) is not one of them: no approval
# is owed for it on this Mac.
sh_snapshots_waiting() {
  local result name
  for result in "$SH_ROOT/$SH_SNAPSHOT_CANDIDATES"/*.result.json; do
    [ -f "$result" ] && [ -f "${result%.result.json}.png" ] || continue
    case "$(jq -r '.status // ""' "$result" 2>/dev/null)" in missing | failed) ;; *) continue ;; esac
    name="${result##*/}"
    printf '%s\n' "${name%.result.json}"
  done
}
# "3 snapshot image(s) wait for the user's approval (A, B and 1 more)", or nothing.
sh_snapshots_waiting_text() {
  local list count
  list="$(sh_snapshots_waiting)"
  [ -n "$list" ] || return 0
  count="$(printf '%s\n' "$list" | grep -c .)"
  printf "%s snapshot image(s) wait for the user's approval (%s%s)" "$count" \
    "$(printf '%s\n' "$list" | head -2 | paste -sd, - | sed 's/,/, /g')" \
    "$([ "$count" -le 2 ] || printf ' and %s more' "$((count - 2))")"
}
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

# A newer swift-harness installed for this project than the one running, as "<version>\t<scope>";
# nothing otherwise. Claude Code can load an older install of the plugin (a user-scope install
# left behind while a project-scope one was updated), and its hooks are then the old ones.
# Read from Claude Code's list of installed plugins; nothing if it cannot be read.
sh_newer_install() {
  local list="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" mine
  mine="$(jq -r '.version // empty' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null)"
  [ -n "$mine" ] && [ -f "$list" ] || return 0
  jq -r --arg mine "$mine" --arg root "$SH_ROOT" '
    def v: [splits("[.]") | tonumber? // 0];
    [(.plugins // {}) | to_entries[] | select(.key | startswith("swift-harness@")) | .value[]?
      | select(type == "object" and (.version | type) == "string")
      | select(.scope == "user" or ((.projectPath // "") as $p | $p != "" and ($root == $p or ($root | startswith($p + "/")))))
      | select((.version | v) > ($mine | v))]
    | max_by(.version | v) // empty | "\(.version)\t\(.scope // "user")"' "$list" 2>/dev/null
}

# Metadata files under a baselines folder ($1, relative to the project) whose "test" or "source"
# is an absolute path, as project-relative paths. A Snapshot.swift older than 1.12.0 wrote the
# test file as the Mac that made the image saw it, account name included, and the folder is
# committed; "source" is what a test passes as source:, absolute when the test wrote it so.
sh_snapshot_absolute() {
  [ -d "$SH_ROOT/$1" ] || return 0
  (cd "$SH_ROOT" && find "$1" -type f -name '*.json' -exec \
    jq -r 'select(type == "object" and any(.test, .source; type == "string" and startswith("/"))) | input_filename' {} + 2>/dev/null) |
    LC_ALL=C sort
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
    git -c core.quotepath=off ls-files -d 2>/dev/null | sed 's/^/deleted /'
  ) | LC_ALL=C sort -u
}

# What the checks stand on, for weaken-watch.sh (#146): "<kind>\t<path>\t<name>\t<count>" lines,
# sorted. In test files (a folder or a file name ending in Test or Tests): tests (func test...,
# @Test; always printed, so a file that goes is seen), assertions, skips (XCTSkip, .disabled(,
# #if false), and each tolerance: literal with its count; the config's snapshots.tolerance. In any Swift file: swiftlint:disable.
# In .swiftlint.yml: each rule in disabled_rules, opt_in_rules, only_rules, and each path in
# excluded. In the layout contract: the Min of each Screens row. In the registry: each
# Components row ("ID Name") and each Retired ID. Text only: lines that start as a comment are
# not counted, except for swiftlint:disable, which is one.
# The test helpers the setup copies carry a swiftlint:disable line of their own, and one skips
# with a reason when the Mac cannot run it (XCTSkip): in a file named as a helper, a line that
# is the template's, character for character, is not counted, so copying a helper as shipped
# is not a check made weaker. A rule added to that line, another line in the file, or the same
# line in a file of another name is counted.
sh_weaken_list() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (
    cd "$SH_ROOT" || exit 0
    git -c core.quotepath=off ls-files -c -o --exclude-standard -z -- '*.swift' 2>/dev/null |
      while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done |
      SH_SHIPPED_HELPERS="$(printf '%s\n' "$here"/../skills/setup/templates/tests/*.swift)" xargs -0 awk '
        BEGIN {
          count = split(ENVIRON["SH_SHIPPED_HELPERS"], helpers, "\n")
          for (i = 1; i <= count; i++) {
            helper = helpers[i]; base = helper; sub(/.*\//, "", base)
            if (helper == "") continue
            while ((getline line < helper) > 0) if (line ~ /swiftlint:disable|XCTSkip|\.disabled[ \t]*\(|^[ \t]*#if[ \t]+false/) shipped[base SUBSEP line] = 1
            close(helper)
          }
        }
        FNR == 1 { istest[FILENAME] = (FILENAME ~ /(^|\/)[^\/]*Tests?\// || FILENAME ~ /Tests?\.swift$/); name = FILENAME; sub(/.*\//, "", name) }
        { own = ((name SUBSEP $0) in shipped) }
        /swiftlint:disable/ && !own { l = $0; lint[FILENAME] += gsub(/swiftlint:disable/, "", l) }
        !istest[FILENAME] { next }
        { l = $0; sub(/^[ \t]+/, "", l) }
        l ~ /^(\/\/|\/\*|\*)/ { next }
        l ~ /^#if[ \t]+false([ \t]|$)/ && !own { skips[FILENAME]++ }
        l ~ /(^|[^A-Za-z0-9_])func[ \t]+test[A-Za-z0-9_]*[ \t]*\(/ || l ~ /^@Test([ \t(]|$)/ { tests[FILENAME]++ }
        { a = l; asserts[FILENAME] += gsub(/XCTAssert[A-Za-z]*[ \t]*\(|XCTFail[ \t]*\(|XCTUnwrap[ \t]*\(|#expect[ \t]*\(|#require[ \t]*\(/, "", a)
          a = l; if (!own) skips[FILENAME] += gsub(/XCTSkip|\.disabled[ \t]*\(/, "", a)
          a = l
          while (match(a, /tolerance:[ \t]*[0-9][0-9._]*/)) {
            v = substr(a, RSTART, RLENGTH); sub(/^tolerance:[ \t]*/, "", v); gsub(/_/, "", v)
            tol[FILENAME SUBSEP v]++; a = substr(a, RSTART + RLENGTH)
          } }
        END {
          for (k in tol) { split(k, p, SUBSEP); printf "tolerance\t%s\t%s\t%d\n", p[1], p[2], tol[k] }
          for (f in lint) if (lint[f]) printf "lint-disable\t%s\t-\t%d\n", f, lint[f]
          for (f in istest) if (istest[f]) {
            printf "tests\t%s\t-\t%d\n", f, tests[f]
            if (asserts[f]) printf "asserts\t%s\t-\t%d\n", f, asserts[f]
            if (skips[f]) printf "skips\t%s\t-\t%d\n", f, skips[f]
          }
        }' 2>/dev/null
    git -c core.quotepath=off ls-files -c -o --exclude-standard -z -- '.swiftlint.yml' '*/.swiftlint.yml' 2>/dev/null |
      while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done |
      xargs -0 awk -v q="'" '
        function out(k, v) {
          gsub(q, "", v); gsub(/"/, "", v)
          if (v == "") return
          if (k == "disabled_rules") printf "lint-off\t%s\t%s\t1\n", FILENAME, v
          else if (k == "opt_in_rules") printf "lint-optin\t%s\t%s\t1\n", FILENAME, v
          else if (k == "only_rules") printf "lint-only\t%s\t%s\t1\n", FILENAME, v
          else if (k == "excluded") printf "lint-excluded\t%s\t%s\t1\n", FILENAME, v
        }
        /^[A-Za-z_]+:/ {
          key = $0; sub(/:.*/, "", key); rest = $0; sub(/^[^:]*:[ \t]*/, "", rest); sub(/[ \t]+#.*$/, "", rest)
          if (rest ~ /^\[/) { gsub(/[][ \t]/, "", rest); n = split(rest, items, ","); for (i = 1; i <= n; i++) out(key, items[i]) }
          next
        }
        /^[ \t]+-[ \t]*[^ \t]/ { v = $0; sub(/^[ \t]+-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); out(key, v) }' 2>/dev/null
    # The layout contract's Min per row, and the registry's Components and Retired rows, read by
    # the scripts that check them.
    "$here/layout.sh" records "$SH_ROOT" 2>/dev/null | awk -F'\037' -v f="$(sh_layout)" '
      $1 == "S" { name = ($3 != "" ? $3 : $4); if (name != "") printf "layout-min\t%s\t%s\t%s\n", f, name, ($7 == "" ? "-" : $7) }'
    "$here/registry.sh" records "$SH_ROOT" 2>/dev/null | awk -F'\037' -v f="$(sh_registry)" '
      $1 == "C" && $4 != "" { printf "registry\t%s\t%s\t1\n", f, ($3 != "" ? $3 " " $4 : $4) }
      $1 == "R" && $3 != "" { printf "registry-retired\t%s\t%s\t1\n", f, $3 }'
    # The project's snapshot tolerance: a larger one lets more pixels change, like a larger
    # tolerance: in a test file.
    jq -r 'if (.snapshots.tolerance? | type) == "number" then "tolerance\t.claude/swift-harness.json\t\(.snapshots.tolerance)\t1" else empty end,
      if .snapshots.approveNew? == true then "approve-new\t.claude/swift-harness.json\t-\t1" else empty end' "$SH_CONFIG" 2>/dev/null
    # The porting ratchet's modules and accepted uses (#73): one fewer module or one more accepted
    # use is a weaker ratchet.
    [ -f "$SH_ROOT/$(sh_ratchet)" ] && awk -F'\t' -v f="$(sh_ratchet)" '
      $1 == "module" && $2 != "" { printf "ratchet-module\t%s\t%s\t1\n", f, $2 }
      $1 == "accepted" && $5 + 0 > 0 { printf "ratchet-accepted\t%s\t%s: %s (in %s)\t%d\n", f, $3, $4, $2, $5 }' "$SH_ROOT/$(sh_ratchet)"
  ) | LC_ALL=C sort
}

# Plugin version, from the manifest next to these scripts.
SH_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null | head -1)"

# What a verification result is about (#18): the code state and the plugin version. The
# project's policy (lintBlocking, verify.command, ...) is part of the code state: the
# fingerprint reads .claude/swift-harness.json and the approved verify files from disk, whether
# git shows them or not (#137). A plugin update can make the
# checks stricter or change the defaults, so a result recorded by another version does not
# count: unchanged code is verified again once.
sh_identity() {
  printf '%s\nswift-harness %s\n' "$(sh_fingerprint)" "${SH_VERSION:-unknown}" | shasum | cut -d' ' -f1
}

# Fingerprint of the code state: HEAD, uncommitted changes to build inputs (including
# deletions), and the content of untracked build inputs. It also covers what git does not show
# for the project (#137):
# - the config and the files the verify approval covers, read from disk, so they count when
#   they are kept out of git (guest mode --local, an ignored .claude/);
# - a repository with no commit yet, by the content of the build inputs in its index;
# - nested repositories and submodules under the project (a local package with its own .git),
#   each by its own HEAD and changes. One ignored by the project's .gitignore is not looked at.
sh_fingerprint_repo() { # $1 repository root, then pathspecs added to the build inputs
  local repo="$1" f
  shift
  if git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    git -C "$repo" rev-parse HEAD 2>/dev/null
    # A diff git could not make is never "unchanged": the fingerprint differs each time, so the
    # check runs instead of passing on what it could not read.
    git -C "$repo" diff HEAD -- "${SH_BUILD_INPUTS[@]}" "$@" 2>/dev/null || printf 'git diff failed %s %s\n' "$(date +%s)" "$RANDOM"
  else
    printf 'no commit yet\n'
    git -C "$repo" ls-files -z --cached -- "${SH_BUILD_INPUTS[@]}" "$@" 2>/dev/null |
      while IFS= read -r -d '' f; do
        printf '%s ' "$f"
        if [ -f "$repo/$f" ]; then shasum <"$repo/$f" 2>/dev/null; else printf 'deleted\n'; fi
      done
  fi
  # In batches: one shasum per file took a session start past its 30 seconds with ten thousand
  # untracked files.
  (cd "$repo" 2>/dev/null && git ls-files -z --others --exclude-standard -- "${SH_BUILD_INPUTS[@]}" "$@" 2>/dev/null |
    xargs -0 shasum 2>/dev/null)
}
# Nested repositories of $1, as paths from its root: links in the index (submodules, or a
# repository added as one) and untracked folders that are repositories.
sh_nested_repos() {
  {
    git -C "$1" ls-files -s -z 2>/dev/null | tr '\0' '\n' | sed -n 's/^160000 [0-9a-f]* [0-9]	//p'
    git -C "$1" ls-files -z --others --exclude-standard 2>/dev/null | tr '\0' '\n' | sed -n 's#/$##p'
  } | LC_ALL=C sort -u
}
sh_fingerprint_tree() { # $1 repository root, $2 depth, $3 its path from the project root, then pathspecs for this repository only
  local repo="$1" depth="$2" rel="$3" sub w
  local watch=()
  shift 3
  while IFS= read -r w; do [ -n "$w" ] && watch+=("$w"); done < <(sh_watch_for "$rel")
  sh_fingerprint_repo "$repo" "$@" ${watch[@]+"${watch[@]}"}
  [ "$depth" -lt 4 ] || return 0
  sh_nested_repos "$repo" | while IFS= read -r sub; do
    [ -n "$sub" ] && [ -e "$repo/$sub/.git" ] || continue
    printf 'nested %s\n' "$sub"
    sh_fingerprint_tree "$repo/$sub" $((depth + 1)) "${rel:+$rel/}$sub"
  done
}
sh_fingerprint() {
  {
    sh_fingerprint_tree "$SH_ROOT" 0 "" "$(sh_registry)" "$(sh_layout)" "$(sh_ratchet)" "$(sh_snapshots)" "$(sh_performance)"
    printf 'policy\n'
    shasum <"$SH_CONFIG" 2>/dev/null
    sh_verify_manifest "$(sh_cfg '.verify.command' 'scripts/verify.sh fast')" 2>/dev/null | sed 1d
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
  # --reporter xcode: a project whose config picks another reporter (json, csv) would give
  # output this cannot read, and a file with warnings would be called clean.
  SH_LINT_OUTPUT="$(cd "$SH_ROOT" && swiftlint lint --quiet --force-exclude --reporter xcode "$1" 2>"$err")"
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
  # The adapters (#105, #125) run the project's code too: their commands and files are covered.
  local docs_cmd lint_cmd format_cmd
  docs_cmd="$(jq -r '.docs.command // empty | strings' "$SH_CONFIG" 2>/dev/null)"
  lint_cmd="$(jq -r '.lint | objects | .command // empty | strings' "$SH_CONFIG" 2>/dev/null)"
  format_cmd="$(jq -r '.format | objects | .command // empty | strings' "$SH_CONFIG" 2>/dev/null)"
  [ -z "$docs_cmd" ] || printf 'docs-command %s\n' "$docs_cmd"
  [ -z "$lint_cmd" ] || printf 'lint-command %s\n' "$lint_cmd"
  [ -z "$format_cmd" ] || printf 'format-command %s\n' "$format_cmd"
  read -ra words <<<"$1${docs_cmd:+ $docs_cmd}${lint_cmd:+ $lint_cmd}${format_cmd:+ $format_cmd}"
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
  local -a links=()
  # Drain find fully into an array first, then test the links. Returning early from a loop that
  # reads a process substitution would abandon the find child; it keeps this function's stdout (the
  # pipe to shasum in sh_verify_digest) open, and shasum then blocks for ever on a slow machine.
  while IFS= read -r -d '' link; do links+=("$link"); done < <(cd "$SH_ROOT/$1" && find . -type l -print0)
  for link in ${links[@]+"${links[@]}"}; do
    res="$SH_ROOT/$1/${link#./}"
    [ -n "$(sh_relpath "$res")" ] || { printf 'outside'; return; }
    [ ! -d "$res" ] || { printf 'linkdir'; return; }
  done
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

# The text the user approved (the second field report on 1.11): the approval itself is a digest,
# which says that something changed, not what. A copy of the covered files is kept with it, so
# the next status can show the lines that changed since, and the Stop hook can say how many.
SH_VERIFY_TEXT_MAX=5242880 # bytes: past this the copy is not kept, and the status says so
# The covered files, as paths relative to the project, one per line: the files the commands name
# and every file under verify.inputs.
sh_verify_text_files() { # $1 command
  local line word sha input rel
  while IFS= read -r line; do
    case "$line" in
      "file "*)
        read -r _ word sha <<<"$line"
        case "$word" in "$SH_ROOT"/*) printf '%s\n' "${word#"$SH_ROOT"/}" ;; *) printf '%s\n' "$word" ;; esac
        ;;
      input$'\t'*)
        IFS=$'\t' read -r _ input sha <<<"$line"
        case "$sha" in missing | outside | linkdir) continue ;; esac
        rel="$(sh_relpath "$input")"
        [ -n "$rel" ] || continue
        if [ -d "$SH_ROOT/$rel" ]; then
          (cd "$SH_ROOT" && find "$rel" \( -type f -o -type l \) ! -name .DS_Store 2>/dev/null)
        else
          printf '%s\n' "$rel"
        fi
        ;;
    esac
  done < <(sh_verify_manifest "$1") | sed 's#^\./##' | LC_ALL=C sort -u
}
# Keeps a copy of the covered files in $2/verify-approved-text, replacing the last one. $1 command.
sh_verify_keep_text() {
  local dir="$2/verify-approved-text" f size=0
  rm -rf "$dir" "$dir.tmp"
  mkdir -p "$dir.tmp/files" || return 0
  printf '%s\n' "$1" >"$dir.tmp/command"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$SH_ROOT/$f" ] || continue
    size=$((size + $(wc -c <"$SH_ROOT/$f")))
    [ "$size" -le "$SH_VERIFY_TEXT_MAX" ] || { rm -rf "$dir.tmp"; return 0; }
    mkdir -p "$dir.tmp/files/$(dirname "$f")" && cat "$SH_ROOT/$f" >"$dir.tmp/files/$f"
  done < <(sh_verify_text_files "$1")
  mv "$dir.tmp" "$dir"
}
# What changed since the approved text, for the status: a unified diff of each file, new and
# removed files named. Prints nothing when no copy was kept. $1 command, $2 state folder.
sh_verify_text_diff() {
  local dir="$2/verify-approved-text" f
  [ -d "$dir/files" ] || return 0
  [ "$(cat "$dir/command" 2>/dev/null)" = "$1" ] || printf 'command: was "%s"\n' "$(cat "$dir/command" 2>/dev/null)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$dir/files/$f" ]; then
      printf 'new file: %s (%s lines)\n' "$f" "$(wc -l <"$SH_ROOT/$f" | tr -d ' ')"
    elif ! cmp -s "$dir/files/$f" "$SH_ROOT/$f"; then
      diff -u --label "approved/$f" --label "now/$f" "$dir/files/$f" "$SH_ROOT/$f"
    fi
  done < <(sh_verify_text_files "$1")
  (cd "$dir/files" && find . -type f | sed 's#^\./##' | LC_ALL=C sort) | LC_ALL=C comm -23 - <(sh_verify_text_files "$1") |
    sed 's/^/no longer covered: /'
}
# One line: "scripts/verify.sh (+3 -3 lines), scripts/ci.sh (new)", or nothing.
sh_verify_text_summary() { # $1 command, $2 state folder
  sh_verify_text_diff "$1" "$2" | awk '
    /^\+\+\+ now\// { f = substr($0, 9); order[++n] = f; next }
    /^--- approved\// { next }
    /^\+/ && f != "" { add[f]++; c[f] = "lines"; next }
    /^-/ && f != "" { del[f]++; c[f] = "lines"; next }
    /^new file: / { sub(/^new file: /, ""); sub(/ \([0-9]+ lines\)$/, ""); order[++n] = $0; c[$0] = "new"; f = ""; next }
    /^no longer covered: / { sub(/^no longer covered: /, ""); order[++n] = $0; c[$0] = "no longer covered"; f = ""; next }
    /^command: / { order[++n] = "the command"; c["the command"] = "changed"; f = ""; next }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]; v = c[k]
        printf "%s%s (%s)", (i > 1 ? ", " : ""), k, (v == "lines" ? "+" (add[k] + 0) " -" (del[k] + 0) " lines" : v)
      }
    }'
}

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
  done <<<"$(git -C "$1" -c core.quotepath=off ls-files -co --exclude-standard '*.xcodeproj/project.pbxproj' 2>/dev/null)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    for p in $(grep -oE '\.(macOS|iOS|tvOS|watchOS|visionOS|macCatalyst)\(' "$1/$file" | tr -d '.('); do
      [ "$p" = macCatalyst ] && p="Mac Catalyst"
      found="$found$p	$file
"
    done
  done <<<"$(git -C "$1" -c core.quotepath=off ls-files -co --exclude-standard 'Package.swift' '*/Package.swift' 2>/dev/null)"
  printf '%s' "$found" | awk -F'\t' '
    BEGIN { n = split("macOS,iOS,Mac Catalyst,visionOS,tvOS,watchOS", order, ",") }
    NF && !($1 in line) { line[$1] = $0 }
    END { for (i = 1; i <= n; i++) if (order[i] in line) print line[order[i]] }'
}

# A worktree without swift-harness's files, in a repository set up with guest mode --local
# (#71): the files are kept out of git, so a new worktree starts without them, and every hook
# would do nothing in silence. Tell the user and Claude, with the command that prepares it.
# Writes nothing.
# A session started above a project set up in a subfolder (a monorepo): no config here, so no
# check runs, and nothing would say so. Names the folders that have one.
sh_subproject_notice() {
  local subs msg
  [ -n "${SH_ROOT:-}" ] && [ ! -f "$SH_ROOT/.claude/swift-harness.json" ] || return 0
  subs="$(git -C "$SH_ROOT" -c core.quotepath=off ls-files -co --exclude-standard -- '*/.claude/swift-harness.json' 2>/dev/null |
    sed 's|/\.claude/swift-harness\.json$||' | head -5 | paste -sd, - | sed 's/,/, /g')"
  [ -n "$subs" ] || return 0
  msg="swift-harness: this session started in $SH_ROOT, which has no .claude/swift-harness.json, so no check runs here: no guard on protected paths, no build or tests at the end of a turn. The plugin is set up in: $subs. Start the session in that folder to have its checks."
  jq -n --arg msg "$msg" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
}

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
