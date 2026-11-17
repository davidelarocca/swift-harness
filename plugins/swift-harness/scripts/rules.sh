#!/bin/bash
# Rules and the checks that enforce them (#148). Read-only; changes no file.
#
#   rules.sh [--project DIR] [--json] [--all]
#
# A project's agent rules mix lines a check enforces with lines nothing checks. A rule names
# its check at the end of its line, in a comment the reader of the rendered file does not see:
#
#   - No raw padding values outside the design system. <!-- check: lint ds_hardcoded_padding -->
#
# Which lines are rules: every top-level list item ("- ", "* " or "1. ") of .claude/rules/*.md,
# and the top-level items under a heading with "rule" in it in CLAUDE.md and AGENTS.md (an item
# of "Commands" or "Where things are" is not a rule). Code fences are skipped.
#
# Check names (the same names the catch log uses, so /swift-harness:report can count them):
#   guard, protected paths     needs protectedPaths in the config
#   shell guard                needs "guardBash": true
#   security settings          needs security.enabled not false
#   snapshot baselines, performance baselines, weakened checks    always on
#   architecture contracts     needs docs/architecture-contracts.json
#   docs references            needs docs.enabled not false
#   component registry         needs registry.enabled and the registry file
#   verify [name]              needs verify.enabled
#   lint <rule id>             a SwiftLint rule: named in .swiftlint.yml (custom rule, opt-in,
#                              only_rules), not in disabled_rules, or a default rule of the
#                              installed swiftlint
# A link is "ok", "off" (the check exists and is turned off), "unknown" (no such check) or
# "unchecked" (cannot be told here, for example a lint rule with swiftlint not installed).
#
# Default output: the counts, then the links that are off or unknown. --all also lists the
# rules nothing checks. --json prints everything. Nothing is rewritten: the output is a list
# for the user. Exit 0: printed. Exit 1: no config or no jq. Exit 2: usage.

set -uo pipefail
export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0

usage() { echo "usage: rules.sh [--project DIR] [--json] [--all]" >&2; exit 2; }

dir="$PWD"
json=false
all=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
    --json) json=true; shift ;;
    --all) all=true; shift ;;
    *) usage ;;
  esac
done

. "$(dirname "$0")/lib.sh" </dev/null
sh_has_jq || { echo "swift-harness: jq is not installed." >&2; exit 1; }
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}')"
SH_ROOT="$(sh_root)"
SH_CONFIG="$SH_ROOT/.claude/swift-harness.json"
[ -f "$SH_CONFIG" ] || { echo "swift-harness: no .claude/swift-harness.json in $dir." >&2; exit 1; }

# ---------- the rule lines ----------

rule_lines() { # prints "file<TAB>line<TAB>text" for every rule line
  local f rel
  for f in "$SH_ROOT/CLAUDE.md" "$SH_ROOT/AGENTS.md"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    rel="${f#"$SH_ROOT"/}"
    awk -v rel="$rel" '
      /^```/ { fence = !fence; next }
      fence { next }
      /^#+[[:space:]]/ { inrules = (tolower($0) ~ /rule/); next }
      inrules && /^([-*]|[0-9]+[.)]) / { sub(/^([-*]|[0-9]+[.)]) +/, ""); printf "%s\t%d\t%s\n", rel, NR, $0 }
    ' "$f"
  done
  for f in "$SH_ROOT"/.claude/rules/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    rel="${f#"$SH_ROOT"/}"
    awk -v rel="$rel" '
      NR == 1 && /^---[[:space:]]*$/ { front = 1; next }
      front { if (/^---[[:space:]]*$/) front = 0; next }
      /^```/ { fence = !fence; next }
      fence { next }
      /^([-*]|[0-9]+[.)]) / { sub(/^([-*]|[0-9]+[.)]) +/, ""); printf "%s\t%d\t%s\n", rel, NR, $0 }
    ' "$f"
  done
}

# ---------- resolving a check name ----------

lint_yml="$SH_ROOT/.swiftlint.yml"
yaml_list() { # $1 file, $2 key: the "  - item" lines under "key:" at the top level
  [ -f "$1" ] || return 0
  awk -v k="$2" '$0 ~ "^" k ":" { f = 1; next } f && /^[[:space:]]+- / { sub(/^[[:space:]]+- /, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["\047]/, ""); print; next } f && /^[^[:space:]#]/ { exit }' "$1"
}
yaml_keys() { # $1 file, $2 key: the "  name:" keys directly under "key:"
  [ -f "$1" ] || return 0
  awk -v k="$2" '$0 ~ "^" k ":" { f = 1; next } f && /^[^[:space:]#]/ { exit } f && /^[[:space:]]+[A-Za-z0-9_]+:/ { sub(/^[[:space:]]+/, ""); sub(/:.*$/, ""); print }' "$1" | sort -u
}
in_list() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

lint_disabled="$(yaml_list "$lint_yml" disabled_rules)"
lint_optin="$(yaml_list "$lint_yml" opt_in_rules)"
lint_only="$(yaml_list "$lint_yml" only_rules)"
lint_custom="$(yaml_keys "$lint_yml" custom_rules)"
lint_builtin=""   # "id<TAB>opt-in yes|no" from `swiftlint rules`, read once and only when needed
lint_builtin_read=false

resolve_lint() { # $1 rule id -> status, why
  local id="$1" line
  if [ "$(sh_cfg '.lint' 'swiftlint')" != swiftlint ]; then status=off; why="the config does not use SwiftLint (lint is \"$(sh_cfg '.lint' 'swiftlint')\")"; return; fi
  if in_list "$lint_disabled" "$id"; then status=off; why="$id is in disabled_rules of .swiftlint.yml"; return; fi
  if [ -n "$lint_only" ]; then
    if in_list "$lint_only" "$id"; then status=ok; why="in only_rules"; else status=off; why="only_rules does not list $id, so it does not run"; fi
    return
  fi
  if in_list "$lint_custom" "$id"; then status=ok; why="custom rule of .swiftlint.yml"; return; fi
  if in_list "$lint_optin" "$id"; then status=ok; why="opt-in rule turned on"; return; fi
  if [ "$lint_builtin_read" = false ]; then
    lint_builtin_read=true
    if command -v swiftlint >/dev/null 2>&1; then
      lint_builtin="$(swiftlint rules 2>/dev/null | awk -F'|' 'NF > 5 { id = $2; opt = $3; gsub(/[[:space:]]/, "", id); gsub(/[[:space:]]/, "", opt); if (id != "" && id != "identifier") print id "\t" opt }')"
    fi
  fi
  if [ -z "$lint_builtin" ]; then status=unchecked; why="not named in .swiftlint.yml and swiftlint is not available to list its rules"; return; fi
  line="$(printf '%s\n' "$lint_builtin" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')"
  case "$line" in
    "") status=unknown; why="no SwiftLint rule or custom rule called $id" ;;
    no) status=ok; why="default rule" ;;
    *) status=off; why="$id is an opt-in rule and opt_in_rules does not turn it on" ;;
  esac
}

resolve() { # $1 marker text after "check:" -> status, why
  local name="$1" kind arg
  kind="${name%% *}"; arg=""
  [ "$kind" = "$name" ] || arg="${name#* }"
  case "$name" in
    "guard" | "protected paths")
      if [ "$(jq -r '(.protectedPaths // []) | length' "$SH_CONFIG" 2>/dev/null)" -gt 0 ] 2>/dev/null; then status=ok; why="protectedPaths is set"
      else status=off; why="protectedPaths is empty"; fi ;;
    "shell guard")
      if [ "$(sh_cfg '.guardBash' 'false')" = true ]; then status=ok; why="guardBash is on"; else status=off; why="guardBash is not turned on"; fi ;;
    "security settings")
      if [ "$(sh_cfg '.security.enabled' 'true')" = true ]; then status=ok; why="security.enabled"; else status=off; why="security.enabled is false"; fi ;;
    "snapshot baselines" | "performance baselines" | "weakened checks") status=ok; why="always on" ;;
    "architecture contracts")
      if [ -f "$SH_ROOT/docs/architecture-contracts.json" ]; then status=ok; why="docs/architecture-contracts.json exists"; else status=off; why="no docs/architecture-contracts.json"; fi ;;
    "docs references")
      if sh_docs_on; then status=ok; why="docs.enabled"; else status=off; why="docs.enabled is false"; fi ;;
    "component registry")
      if sh_registry_on; then status=ok; why="registry on"; else status=off; why="registry disabled or its file is missing"; fi ;;
    verify | "verify "*)
      if [ "$(sh_cfg '.verify.enabled' 'true')" = true ]; then status=ok; why="verify.enabled"; else status=off; why="verify.enabled is false"; fi ;;
    "lint "*)
      if [[ "$arg" =~ ^[A-Za-z0-9_]+$ ]]; then resolve_lint "$arg"; else status=unknown; why="a lint link names one SwiftLint rule id"; fi ;;
    *) status=unknown; why="no check called \"$name\"" ;;
  esac
}

# ---------- build the list ----------

rules='[]'
while IFS=$'\t' read -r file line text; do
  [ -n "$file" ] || continue
  links='[]'
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    name="$(printf '%s' "$marker" | sed -E 's/^<!--[[:space:]]*check:[[:space:]]*//; s/[[:space:]]*-->$//; s/[[:space:]]+/ /g')"
    status=""; why=""
    resolve "$name"
    links="$(jq -c --arg check "$name" --arg status "$status" --arg why "$why" '. + [{check: $check, status: $status, why: $why}]' <<<"$links")"
  done < <(printf '%s\n' "$text" | grep -oE '<!--[[:space:]]*check:[^>]*-->')
  clean="$(printf '%s' "$text" | sed -E 's/[[:space:]]*<!--[[:space:]]*check:[^>]*-->//g' | cut -c1-110)"
  rules="$(jq -c --arg file "$file" --argjson line "$line" --arg text "$clean" --argjson links "$links" '. + [{file: $file, line: $line, text: $text, links: $links}]' <<<"$rules")"
done < <(rule_lines)

result="$(jq -c '
  . as $r
  | {total: length,
     linked: map(select(.links | length > 0)) | length,
     unlinked: map(select(.links | length == 0)) | length,
     broken: [.[] | . as $rule | .links[] | select(.status == "off" or .status == "unknown") | . + {file: $rule.file, line: $rule.line, text: $rule.text}],
     unchecked: [.[] | . as $rule | .links[] | select(.status == "unchecked") | . + {file: $rule.file, line: $rule.line, text: $rule.text}],
     rules: $r}' <<<"$rules")"

if [ "$json" = true ]; then
  jq . <<<"$result"
  exit 0
fi

jq -r --argjson all "$all" '
  if .total == 0 then "No rule lines found in CLAUDE.md, AGENTS.md or .claude/rules/."
  else
    "\(.total) rule(s): \(.linked) name a check, \(.unlinked) name none.",
    (if (.broken | length) > 0 then "Links to fix (the rule says a check enforces it, but it does not):" else empty end),
    (.broken[] | "- \(.file):\(.line): \(.text) -> \(.check): \(.status), \(.why)"),
    (if (.unchecked | length) > 0 then "Links that could not be checked here:" else empty end),
    (.unchecked[] | "- \(.file):\(.line): \(.check): \(.why)"),
    (if $all and .unlinked > 0 then "Rules nothing checks (a hope, not a promise):" else empty end),
    (if $all then (.rules[] | select(.links | length == 0) | "- \(.file):\(.line): \(.text)") else empty end),
    (if (.unlinked > 0 and ($all | not)) then "Run with --all to list the rules nothing checks." else empty end)
  end' <<<"$result"
