#!/bin/bash
# Security settings contract (#32): sandbox, hardened runtime, capabilities and App Transport
# Security, read from the real files, compared with the state the user approved.
#
#   security.sh state     [--project DIR]            the current state, one line per setting
#   security.sh check     [--project DIR]            exit 1 with the changes since the approval
#   security.sh --status  [--project DIR]            the changes and a digest (for the user)
#   security.sh --approve DIGEST [--project DIR]     record the current state as approved
#   security.sh --record  [--project DIR]            record it only if nothing is recorded yet,
#                                                    marked as not reviewed until the user approves it
#   security.sh relaxed   [--project DIR]            the current settings that weaken protection
#
# Sources, read without running project code: every *.entitlements plist (plutil), the
# NSAppTransportSecurity dictionary of *Info.plist files, and code-signing and capability build
# settings in project.pbxproj and *.xcconfig files (each value with how many configurations set
# it). The approved state lives in the plugin data folder, outside the project, so a change in
# the repository cannot approve itself. Approving is for the user, through
# /swift-harness:approve-security.

usage() {
  echo "usage: security.sh state|check|--status|--record [--project DIR] | --approve DIGEST [--project DIR]" >&2
  exit 2
}
action="${1:-}"
digest=""
case "$action" in
  state | check | --status | --record | relaxed) shift ;;
  --approve)
    digest="${2:-}"
    [ -n "$digest" ] || usage
    shift 2
    ;;
  *) usage ;;
esac
dir="$PWD"
if [ "${1:-}" = "--project" ]; then
  [ -n "${2:-}" ] || usage
  dir="$2"
  shift 2
fi
[ $# -eq 0 ] || usage

. "$(dirname "$0")/lib.sh" </dev/null
export LC_ALL=C
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}' 2>/dev/null)"
sh_init || { echo "swift-harness: no .claude/swift-harness.json in $dir (or jq is missing)." >&2; exit 2; }

EXCLUDE=(':!.build/*' ':!*/.build/*' ':!*DerivedData/*' ':!Pods/*' ':!Carthage/*' ':!*/checkouts/*')
files() { git -C "$SH_ROOT" -c core.quotepath=off ls-files -co --exclude-standard -- "$@" "${EXCLUDE[@]}" 2>/dev/null; }
SETTINGS='CODE_SIGN_IDENTITY|CODE_SIGNING_ALLOWED|CODE_SIGNING_REQUIRED|ENABLE_HARDENED_RUNTIME|ENABLE_APP_SANDBOX|CODE_SIGN_ENTITLEMENTS|CODE_SIGN_INJECT_BASE_ENTITLEMENTS|OTHER_CODE_SIGN_FLAGS|ENABLE_USER_SELECTED_FILES|ENABLE_INCOMING_NETWORK_CONNECTIONS|ENABLE_OUTGOING_NETWORK_CONNECTIONS|ENABLE_FILE_ACCESS_[A-Z_]+|ENABLE_RESOURCE_ACCESS_[A-Z_]+|RUNTIME_EXCEPTION_[A-Z_]+|AUTOMATION_APPLE_EVENTS|ENABLE_LIBRARY_VALIDATION|DISABLE_LIBRARY_VALIDATION'

# One line per setting: "<file>: <key> = <value>", sorted.
current_state() {
  local f json
  {
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if json="$(plutil -convert json -o - "$SH_ROOT/$f" 2>/dev/null)"; then
        printf '%s' "$json" | jq -r --arg f "$f" \
          'paths(scalars) as $p | "\($f): \($p | map(tostring) | join(".")) = \(getpath($p))"'
        [ "$json" != "{}" ] || printf '%s: (no entitlements)\n' "$f"
      else
        printf '%s: (not a readable plist)\n' "$f"
      fi
    done <<<"$(files '*.entitlements')"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      json="$(plutil -extract NSAppTransportSecurity json -o - "$SH_ROOT/$f" 2>/dev/null)" || continue
      printf '%s' "$json" | jq -r --arg f "$f" \
        'paths(scalars) as $p | "\($f): NSAppTransportSecurity.\($p | map(tostring) | join(".")) = \(getpath($p))"'
    done <<<"$(files '*Info.plist')"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -oE "^[[:space:]]*($SETTINGS)(\\[[^]]*\\])?[[:space:]]*=[^;]*" "$SH_ROOT/$f" |
        sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]*=[[:space:]]*/ = /' -e 's/[[:space:]]+$//' -e 's/"//g' |
        sort | uniq -c | awk -v f="$f" '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s: %s%s\n", f, $0, (c > 1 ? " (" c " configurations)" : "") }'
    done <<<"$(files '*.pbxproj' '*.xcconfig')"
    # Turning the check off is a change to approve like any other (#32).
    printf '.claude/swift-harness.json: security.enabled = %s\n' "$(sh_cfg '.security.enabled' 'true')"
    # Letting moves pass is a weaker check, so it is approved too. Recorded only when set, so a
    # project without it keeps the state it approved.
    [ "$(sh_cfg '.security.moves' 'approve')" != pass ] || printf '.claude/swift-harness.json: security.moves = pass\n'
  } | sort
}

state_dir="$(sh_state_path)"
approved="$state_dir/security-approved"
# Present while the baseline is the one recorded automatically at the first session, never
# reviewed: a new clone, Mac or worktree starts from what is on its branch.
unreviewed="$state_dir/security-unreviewed"
# Settings that weaken protection, pointed out wherever they appear.
RELAXED='cs\.(disable-library-validation|allow-jit|allow-unsigned-executable-memory|allow-dyld-environment-variables|disable-executable-page-protection|debugger) = true|temporary-exception|app-sandbox = false|NSAllowsArbitraryLoads[A-Za-z]* = true|NSExceptionAllowsInsecureHTTPLoads = true|ENABLE_HARDENED_RUNTIME = NO|ENABLE_APP_SANDBOX = NO|CODE_SIGNING_ALLOWED = NO|DISABLE_LIBRARY_VALIDATION = YES|RUNTIME_EXCEPTION_[A-Z_]+ = YES|security\.enabled = false|security\.moves = pass'
changes() { # "+ line" for added or changed, "- line" for removed
  diff "$approved" <(current_state) | sed -n -e 's/^> /+ /p' -e 's/^< /- /p'
}
# Settings whose removal weakens protection, when nothing with the same value replaces them.
PROTECTIVE='app-sandbox = true|ENABLE_HARDENED_RUNTIME = YES|ENABLE_APP_SANDBOX = YES|ENABLE_LIBRARY_VALIDATION = YES|security\.enabled = true'
# The changes ($1, from changes) sorted out for a rename: a setting removed from one file and the
# same "key = value" added in another is a move, not a change. The entitlements path in a build
# setting that follows a moved entitlements file is part of the move too. Prints one line each:
#   moved<TAB><old file><TAB><new file><TAB><count><TAB><note>
#   change<TAB><+ or - line>
sort_changes() {
  printf '%s\n' "$1" | awk '
    function strip(v) { sub(/ \([0-9]+ configurations\)$/, "", v); return v }
    function configs(v) { return match(v, / \([0-9]+ configurations\)$/) ? substr(v, RSTART) : "" }
    function ends(s, t) { return t != "" && length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
    /^[+-] / {
      sign = substr($0, 1, 1); line = substr($0, 3)
      i = index(line, ": "); if (i == 0) { other[++n] = $0; next }
      file = substr(line, 1, i - 1); rest = substr(line, i + 2)
      if (sign == "-") { mi = ++m; mf[mi] = file; mr[mi] = rest } else { pi = ++q; pf[pi] = file; pr[pi] = rest }
    }
    END {
      # Pair each removed line with an added one of the same setting and value in another file.
      for (a = 1; a <= m; a++) for (b = 1; b <= q; b++) {
        if (usedp[b] || mr[a] != pr[b] || mf[a] == pf[b]) continue
        usedm[a] = usedp[b] = 1; key = mf[a] SUBSEP pf[b]; moved[key]++; break
      }
      # An entitlements path that follows a moved entitlements file.
      for (a = 1; a <= m; a++) if (!usedm[a] && mr[a] ~ /^CODE_SIGN_ENTITLEMENTS(\[[^]]*\])? = /) {
        split(mr[a], x, " = "); oldv = strip(x[2])
        for (b = 1; b <= q; b++) {
          if (usedp[b] || pr[b] !~ /^CODE_SIGN_ENTITLEMENTS(\[[^]]*\])? = /) continue
          split(pr[b], y, " = "); newv = strip(y[2])
          if (configs(mr[a]) != configs(pr[b])) continue
          follows = 0
          for (k in moved) { split(k, f, SUBSEP); if (f[1] ~ /\.entitlements$/ && ends(f[1], oldv) && ends(f[2], newv)) follows = 1 }
          if (!follows) continue
          usedm[a] = usedp[b] = 1; key = mf[a] SUBSEP pf[b]; moved[key]++
          note[key] = "among them the entitlements path, which follows the moved entitlements file"
          break
        }
      }
      for (k in moved) { split(k, f, SUBSEP); printf "moved\t%s\t%s\t%d\t%s\n", f[1], f[2], moved[k], note[k] }
      for (a = 1; a <= m; a++) if (!usedm[a]) printf "change\t- %s: %s\n", mf[a], mr[a]
      for (b = 1; b <= q; b++) if (!usedp[b]) printf "change\t+ %s: %s\n", pf[b], pr[b]
      for (i = 1; i <= n; i++) printf "change\t%s\n", other[i]
    }' | LC_ALL=C sort
}
# The changes that are not moves, as "+ line" and "- line".
real_changes() { sort_changes "$1" | sed -n 's/^change\t//p'; }
# The real changes that weaken protection: a weakening setting added, or a protective one removed.
weakening() {
  local real
  real="$(real_changes "$1")"
  grep -E "^\+ .*($RELAXED)" <<<"$real"
  grep -E "^- .*($PROTECTIVE)( \([0-9]+ configurations\))?\$" <<<"$real"
  return 0
}
# How many settings are recorded, the check's own switch apart.
recorded() { grep -vEc '^\.claude/swift-harness\.json: security\.(enabled|moves) = ' "$approved" 2>/dev/null || echo 0; }
digest_of() { { cat "$approved" 2>/dev/null; printf -- '--\n'; current_state; } | shasum -a 256 | cut -d' ' -f1; }
# For the user's eyes only: the line of the check's own switch says when its value is the
# default, with no security.enabled key in the file to look for. The recorded line stays as it
# is: it is part of what is approved, and changing it would ask everyone to approve again.
shown() {
  if jq -e '(.security | type) == "object" and (.security | has("enabled"))' "$SH_CONFIG" >/dev/null 2>&1; then
    cat
  else
    sed 's|\(\.claude/swift-harness\.json: security\.enabled = true\)$|\1 (the default: the file has no security.enabled key)|'
  fi
}

case "$action" in
  state)
    current_state
    ;;
  relaxed)
    current_state | grep -E "$RELAXED"
    exit 0
    ;;
  check)
    [ -f "$approved" ] || exit 0 # nothing recorded yet: session start records it
    # Off, and the user approved it off: nothing to compare.
    if [ "$(sh_cfg '.security.enabled' 'true')" = "false" ] && grep -qxF '.claude/swift-harness.json: security.enabled = false' "$approved"; then
      exit 0
    fi
    out="$(changes)"
    [ -z "$out" ] && exit 0
    # A rename moves settings between files without changing them. With security.moves "pass"
    # that is no change; with "approve", the default, the user records the new paths, with no
    # question asked (the status says there is nothing to decide).
    real="$(real_changes "$out")"
    if [ -z "$real" ]; then
      [ "$(sh_cfg '.security.moves' 'approve')" != pass ] || exit 0
      printf 'Security settings moved to other files, values unchanged (a rename):\n%s\n' \
        "$(sort_changes "$out" | awk -F'\t' '$1 == "moved" && $2 == $3 { printf "  %s: the entitlements path follows the moved entitlements file\n", $2; next }
          $1 == "moved" { printf "  %s -> %s: %s setting(s)\n", $2, $3, $4 }' | head -30)"
      printf 'Nothing was relaxed. The user records the new paths by typing /swift-harness:approve-security (no question to answer); tell them so. Do not run it yourself.\n'
      exit 1
    fi
    [ "$(sh_cfg '.security.moves' 'approve')" != pass ] || out="$real"
    printf 'Security settings changed since the user approved them:\n%s\n' "$(printf '%s\n' "$out" | head -30)"
    printf 'If you relaxed a setting to make something work, revert it and find another way. If the change is needed, stop and tell the user why: only they approve it, by typing /swift-harness:approve-security. Do not run it yourself.\n'
    exit 1
    ;;
  --record)
    [ -f "$approved" ] && exit 0
    mkdir -p "$state_dir" && current_state >"$approved" && date -u +%Y-%m-%d >"$unreviewed"
    ;;
  --status | --approve)
    [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || {
      echo "swift-harness: CLAUDE_PLUGIN_DATA is not set. Run this through /swift-harness:approve-security." >&2
      exit 1
    }
    if [ ! -f "$approved" ]; then
      out="$(current_state | sed 's/^/+ /')"
    else
      out="$(changes)"
    fi
    if [ "$action" = "--status" ]; then
      if [ -f "$unreviewed" ]; then
        printf 'The baseline was recorded automatically on %s, at the first session in this folder, and you have not reviewed it. Settings in it:\n%s\n' \
          "$(cat "$unreviewed")" "$(sed 's/^/  /' "$approved" | shown)"
        relaxed="$(grep -E "$RELAXED" "$approved")"
        [ -z "$relaxed" ] || printf 'Of these, weakening protection:\n%s\n' "$(printf '%s\n' "$relaxed" | sed 's/^/  /')"
        printf '\n'
      fi
      if [ -z "$out" ]; then
        printf 'No change since the last approval (%s setting(s) recorded).\n' "$(recorded)"
        decide=""
      else
        sorted="$(sort_changes "$out")"
        moves="$(printf '%s\n' "$sorted" | awk -F'\t' '$1 == "moved" && $2 == $3 { printf "  %s: the entitlements path follows the moved entitlements file\n", $2; next }
          $1 == "moved" { printf "  %s -> %s: %s setting(s) moved%s\n", $2, $3, $4, ($5 != "" ? ", " $5 : "") }')"
        real="$(printf '%s\n' "$sorted" | sed -n 's/^change\t//p')"
        if [ -n "$moves" ]; then
          printf 'Moved to another file, values unchanged (a rename):\n%s\n' "$moves"
          if [ "$(sh_cfg '.security.moves' 'approve')" = pass ]; then
            printf '(security.moves is "pass": these do not fail the end-of-turn check; approving records the new paths.)\n'
          else
            printf '(security.moves is "approve", the default: these fail the end-of-turn check until approved, with no question to answer.)\n'
          fi
        fi
        if [ -n "$real" ]; then
          printf 'Changes since the last approval (+ added or new value, - removed or old value):\n%s\n' "$(printf '%s\n' "$real" | shown)"
        else
          printf 'No setting changed its value.\n'
        fi
        decide="$(weakening "$out")"
      fi
      # What the user has to decide: the skill asks only when this names something.
      if [ -f "$unreviewed" ] && [ -n "$(grep -E "$RELAXED" "$approved")" ]; then
        printf 'To decide: the baseline was never reviewed and holds settings that weaken protection (listed above).\n'
      elif [ -n "$decide" ]; then
        printf 'To decide: these changes weaken protection:\n%s\n' "$(printf '%s\n' "$decide" | sed 's/^/  /')"
      elif [ -n "$out" ] || [ -f "$unreviewed" ]; then
        printf 'Nothing to decide: no change weakens protection.\n'
      fi
      printf 'Digest: %s\n' "$(digest_of)"
      exit 0
    fi
    if [ "$digest" != "$(digest_of)" ]; then
      echo "Nothing approved: the security settings changed since the list was shown. List them again." >&2
      exit 1
    fi
    mkdir -p "$state_dir" && current_state >"$approved" && rm -f "$unreviewed"
    # The approved state is outside the repository, so approving does not change the code
    # identity: drop the failure recorded for this code, and the next Stop checks it again (#141).
    rm -f "$state_dir/failed"
    printf 'Approved: %s setting(s) recorded as the security baseline, and security.enabled.\n' "$(recorded)"
    sh_catch "security settings" approved "$(recorded) setting(s)"
    ;;
esac
