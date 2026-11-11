#!/bin/bash
# Guest mode (#71): set swift-harness up on a project that has its own agent rules, docs and
# checks, adding only two files. Run by /swift-harness:setup guest, after the user confirmed
# the commands; never by a hook.
#
#   setup-guest.sh --fast "<command>" [--full "<command>"] [--project DIR] [--no-docs | --docs-command "<command>"]
#                  [--owned PATH]... [--retry-failed] [--docs-observe] [--local]
#                  [--lint-command "<command>" [--lint-observe]] [--format-command "<command>" [--format-observe]]
#   setup-guest.sh --from DIR [--project DIR] [--local]
# --docs-observe runs the project's docs check without ever blocking (docs.blocking false).
# --local keeps both files out of the repository: they go into .git/info/exclude, which every
# worktree of the repository shares, so neither git nor other agents see them.
# --from DIR copies both files from another checkout of the same project (a new worktree).
# --codex [--data DIR] also writes .codex/hooks.json and a launcher, .codex/swift-harness-hook.sh
# (#122): Codex runs the same hooks, through codex-hook.sh, with the same plugin data folder as
# Claude Code (--data, else CLAUDE_PLUGIN_DATA, else the only swift-harness data folder), so one
# approval covers both agents. Codex asks to trust project hooks once (/hooks).
# --ui-isolation ARG (repeatable) declares the launch arguments that keep UI tests off the
# user's real data (uiTests.isolation, #68), so doctor checks every UI test that launches the app.
# --retry-failed sets verify.retryFailed (#108): a failing verify command runs once more, and a
# pass on the rerun is recorded as unstable instead of blocking.
#
# Writes .claude/swift-harness.json ("guest": true) and scripts/verify.sh, which runs the
# project's own commands: the fast one at the end of each turn, the full one (or the fast one)
# before merging. Nothing else in the project changes: no CLAUDE.md, rules, docs, templates.
# The formatter and SwiftLint stay off unless the project already has their config, so its
# code is never rewritten in another style. --docs-command runs the project's own docs check
# instead of the harness's (docs.command, #105); --no-docs turns the docs check off.
# --lint-command and --format-command run the project's own lint or format check at the end of a
# turn, instead of SwiftLint and the formatter after each edit (#125); --lint-observe and
# --format-observe record them without ever blocking.
# The project's agent rules that exist (CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, .claude/rules/)
# and each --owned path (docs only some people may edit) become protectedPaths (#109): the guard
# asks before Claude edits them, and a shell edit is reported at the end of the turn.
#
# Exit 0: written (both paths printed). Exit 1: one of the files exists (nothing written).
# Exit 2: usage.

set -uo pipefail

usage() {
  echo "usage: setup-guest.sh --fast \"<command>\" [--full \"<command>\"] [--project DIR] [--no-docs | --docs-command \"<command>\" [--docs-observe]] [--owned PATH]... [--retry-failed] [--ui-isolation ARG]... [--local] [--lint-command \"<command>\" [--lint-observe]] [--format-command \"<command>\" [--format-observe]]" >&2
  echo "       setup-guest.sh --from DIR [--project DIR] [--local]" >&2
  exit 2
}

dir="."
fast=""
full=""
docs=true
docs_command=""
lint_command=""
format_command=""
lint_observe=false
format_observe=false
owned=""
retry=false
isolation=""
codex=false
data=""
observe=false
local_only=false
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) [ $# -ge 2 ] && [ -n "$2" ] || usage; fast="$2"; shift 2 ;;
    --full) [ $# -ge 2 ] && [ -n "$2" ] || usage; full="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --no-docs) docs=false; shift ;;
    --docs-command) [ $# -ge 2 ] && [ -n "$2" ] || usage; docs_command="$2"; shift 2 ;;
    --owned) [ $# -ge 2 ] && [ -n "$2" ] || usage; owned="$owned$2"$'\n'; shift 2 ;;
    --retry-failed) retry=true; shift ;;
    --ui-isolation) [ $# -ge 2 ] && [ -n "$2" ] || usage; isolation="$isolation$2"$'\n'; shift 2 ;;
    --docs-observe) observe=true; shift ;;
    --lint-command) [ $# -ge 2 ] && [ -n "$2" ] || usage; lint_command="$2"; shift 2 ;;
    --format-command) [ $# -ge 2 ] && [ -n "$2" ] || usage; format_command="$2"; shift 2 ;;
    --lint-observe) lint_observe=true; shift ;;
    --format-observe) format_observe=true; shift ;;
    --local) local_only=true; shift ;;
    --from) [ $# -ge 2 ] || usage; from="$2"; shift 2 ;;
    --codex) codex=true; shift ;;
    --data) [ $# -ge 2 ] && [ -n "$2" ] || usage; data="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$fast" ] || [ -n "$from" ] || usage
command -v jq >/dev/null 2>&1 || { echo "setup-guest: jq is required (brew install jq)." >&2; exit 2; }
root="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "setup-guest: no such folder: $dir" >&2; exit 2; }
config="$root/.claude/swift-harness.json"
# A folder named Scripts (or any case) is the same folder on a default macOS volume: write
# into it under its own name, so git and the verify command agree on the path.
sdir=scripts
for d in "$root"/[sS][cC][rR][iI][pP][tT][sS]; do
  [ -d "$d" ] && { sdir="${d##*/}"; break; }
done
verify="$root/$sdir/verify.sh"

exists=""
[ -e "$config" ] && exists="$exists .claude/swift-harness.json"
[ -e "$verify" ] && exists="$exists $sdir/verify.sh"
if [ "$codex" = true ]; then
  # -L as well: a link that points nowhere fails -e, and writing would go through it.
  for file in .codex/hooks.json .codex/swift-harness-hook.sh; do
    if [ -e "$root/$file" ] || [ -L "$root/$file" ]; then exists="$exists $file"; fi
  done
fi
# The plugin data folder the Codex launcher uses, found before anything is written.
if [ "$codex" = true ] && [ -z "$data" ]; then
  data="${CLAUDE_PLUGIN_DATA:-}"
  if [ -z "$data" ]; then
    c="$(ls -d "$HOME"/.claude/plugins/data/swift-harness-* 2>/dev/null)"
    [ "$(printf '%s\n' "$c" | grep -c .)" -eq 1 ] && data="$c"
  fi
  [ -n "$data" ] || { echo "setup-guest: --codex needs the plugin data folder Claude Code uses: pass --data DIR" >&2; exit 1; }
fi
if [ -n "$exists" ]; then
  echo "setup-guest: already there:$exists. Nothing written: merge by hand, or remove them first." >&2
  exit 1
fi

# Keep the two files out of the repository (all its worktrees share .git/info/exclude).
exclude_locally() {
  local common file
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || { echo "setup-guest: --local needs a git repository" >&2; return 1; }
  common="$(cd "$root" && cd "$common" && pwd -P)" || return 1
  mkdir -p "$common/info" && touch "$common/info/exclude"
  for file in .claude/swift-harness.json "$sdir/verify.sh" ${codex_files:-}; do
    grep -qxF "/$file" "$common/info/exclude" || printf '/%s\n' "$file" >>"$common/info/exclude"
  done
}

# A new worktree: the same two files as another checkout of the project.
if [ -n "$from" ]; then
  src="$(cd "$from" 2>/dev/null && pwd -P)" || { echo "setup-guest: no such folder: $from" >&2; exit 2; }
  ssdir=scripts
  for d in "$src"/[sS][cC][rR][iI][pP][tT][sS]; do [ -d "$d" ] && { ssdir="${d##*/}"; break; }; done
  [ -f "$src/.claude/swift-harness.json" ] && [ -f "$src/$ssdir/verify.sh" ] || { echo "setup-guest: $src has no guest setup to copy" >&2; exit 2; }
  # Refuse before the first copy if any destination artifact already exists, a link included: cp
  # follows a link and would overwrite its target, which may sit outside the project.
  copy_codex=false
  [ -f "$src/.codex/hooks.json" ] && [ -f "$src/.codex/swift-harness-hook.sh" ] && copy_codex=true
  exists=""
  for file in .claude/swift-harness.json "$sdir/verify.sh" $([ "$copy_codex" = true ] && echo .codex/hooks.json .codex/swift-harness-hook.sh); do
    { [ -e "$root/$file" ] || [ -L "$root/$file" ]; } && exists="$exists $file"
  done
  if [ -n "$exists" ]; then
    echo "setup-guest: already there:$exists. Nothing copied: merge by hand, or remove them first." >&2; exit 1
  fi
  mkdir -p "$root/.claude" "$root/$sdir" || exit 1
  cp "$src/.claude/swift-harness.json" "$config" && cp -p "$src/$ssdir/verify.sh" "$verify" || exit 1
  if [ "$copy_codex" = true ]; then
    mkdir -p "$root/.codex" && cp "$src/.codex/hooks.json" "$root/.codex/hooks.json" && cp -p "$src/.codex/swift-harness-hook.sh" "$root/.codex/swift-harness-hook.sh" || exit 1
    codex_files=".codex/hooks.json .codex/swift-harness-hook.sh"
  fi
  [ "$local_only" = false ] || exclude_locally || exit 1
  printf '%s\n%s\n' "$config" "$verify"
  [ -z "${codex_files:-}" ] || printf '%s\n%s\n' "$root/.codex/hooks.json" "$root/.codex/swift-harness-hook.sh"
  exit 0
fi

# The project's own formatter and SwiftLint, if it has their config; off otherwise.
format=none
if [ -f "$root/.swiftformat" ]; then format=swiftformat
elif [ -f "$root/.swift-format" ]; then format=swift-format; fi
lint=none
[ -f "$root/.swiftlint.yml" ] && lint=swiftlint

# The project's own rules, and the paths it owns, are asked about before an edit (#109).
protect="$(for p in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do [ -f "$root/$p" ] && printf '%s\n' "$p"; done
  [ -d "$root/.claude/rules" ] && printf '.claude/rules/\n'
  printf '%s' "$owned" | while IFS= read -r p; do
    p="${p#./}"
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || { echo "setup-guest: --owned $p does not exist; left out" >&2; continue; }
    printf '%s\n' "$p"
  done)"
mkdir -p "$root/.claude" "$root/$sdir" || exit 1
jq -n --arg format "$format" --arg lint "$lint" --argjson docs "$docs" --arg cmd "$sdir/verify.sh fast" --arg dcmd "$docs_command" \
  --arg protect "$protect" --argjson retry "$retry" --argjson observe "$observe" --arg isolation "$isolation" \
  --arg lcmd "$lint_command" --arg fcmd "$format_command" --argjson lobs "$lint_observe" --argjson fobs "$format_observe" '
  {guest: true, format: $format, lint: $lint, verify: ({command: $cmd, maxAttempts: 3} + (if $retry then {retryFailed: true} else {} end))}
  + (($protect | split("\n") | map(select(length > 0))) as $p | if ($p | length) > 0 then {protectedPaths: $p} else {} end)
  + (($isolation | split("\n") | map(select(length > 0))) as $i | if ($i | length) > 0 then {uiTests: {isolation: $i}} else {} end)
  + (if $docs then (if $dcmd == "" then {} else {docs: ({command: $dcmd} + (if $observe then {blocking: false} else {} end))} end) else {docs: {enabled: false}} end)
  + (if $lcmd == "" then {} else {lint: ({command: $lcmd} + (if $lobs then {blocking: false} else {} end))} end)
  + (if $fcmd == "" then {} else {format: ({command: $fcmd} + (if $fobs then {blocking: false} else {} end))} end)' >"$config" || exit 1

# The commands go in as single-quoted shell words, so nothing in them is expanded here.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf '#!/bin/bash\n'
  printf '# Project verification for swift-harness in guest mode (#71): it runs the project'"'"'s own\n'
  printf '# commands. Edit them freely; the end-of-turn check runs "fast" once you approve it.\n'
  printf '#   scripts/verify.sh fast   at the end of a turn\n'
  printf '#   scripts/verify.sh full   before merging\n'
  printf 'set -uo pipefail\n'
  printf 'cd "$(dirname "$0")/.." || exit 1\n'
  printf 'FAST=%s\n' "$(quote "$fast")"
  printf 'FULL=%s\n' "$(quote "${full:-$fast}")"
  printf 'case "${1:-fast}" in\n'
  printf '  fast) bash -c "$FAST" ;;\n'
  printf '  full) bash -c "$FULL" ;;\n'
  printf '  *) printf '"'"'verify: unknown mode "%%s". Use fast or full.\\n'"'"' "$1"; exit 2 ;;\n'
  printf 'esac\n'
} >"$verify" || exit 1
chmod +x "$verify"

# Codex (#122): the same hooks, through a launcher that finds the plugin and the data folder.
if [ "$codex" = true ]; then
  plugin="$(cd "$(dirname "$0")/.." && pwd -P)"
  mkdir -p "$root/.codex" || exit 1
  {
    printf '#!/bin/bash\n'
    printf '# swift-harness for Codex hooks, written by setup-guest.sh --codex (#122). It finds the plugin\n'
    printf '# (the installed one, else the folder recorded at setup) and uses the plugin data folder of\n'
    printf '# Claude Code, so one approval of the verify command covers both agents.\n'
    printf 'plugin="$(jq -r %s "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null)"\n' "'.plugins[\"swift-harness@swift-harness\"][0].installPath // empty'"
    printf '[ -x "$plugin/scripts/codex-hook.sh" ] || plugin=%s\n' "$(quote "$plugin")"
    printf 'export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-%s}"\n' "$data"
    printf 'exec "$plugin/scripts/codex-hook.sh" "$@"\n'
  } >"$root/.codex/swift-harness-hook.sh" && chmod +x "$root/.codex/swift-harness-hook.sh" || exit 1
  launch='bash "$(git rev-parse --show-toplevel)/.codex/swift-harness-hook.sh"'
  jq -n --arg l "$launch" '
    def h($s; $t): {type: "command", command: "\($l) \($s)", timeout: $t};
    {description: "swift-harness checks (guest mode), written by setup-guest.sh --codex",
     hooks: {
       SessionStart: [{hooks: [h("session-start.sh"; 60)]}],
       PreToolUse: [{matcher: "^(apply_patch|Edit|Write)$", hooks: [h("guard.sh"; 30)]}],
       PostToolUse: [{matcher: "^(apply_patch|Edit|Write)$", hooks: [h("post-edit.sh"; 120)]}],
       Stop: [{hooks: [h("stop-verify.sh"; 900), h("docs-watch.sh"; 60), h("scope-watch.sh"; 30),
                       h("contract-watch.sh"; 30), h("snapshot-watch.sh"; 30), h("protected-watch.sh"; 30)]}]}}' \
    >"$root/.codex/hooks.json" || exit 1
  codex_files=".codex/hooks.json .codex/swift-harness-hook.sh"
fi
[ "$local_only" = false ] || exclude_locally || exit 1

printf '%s\n%s\n' "$config" "$verify"
[ "$codex" = false ] || printf '%s\n%s\n' "$root/.codex/hooks.json" "$root/.codex/swift-harness-hook.sh"
