#!/bin/bash
# Read-only diagnosis of a swift-harness setup (#12). Run by /swift-harness:doctor.
#
#   doctor.sh [project-dir]
#
# Prints a Markdown table, one row per check: PASS, WARN, FAIL or INFO, with one fix per
# problem. Exits 1 if any check fails. Changes no file: it does not create the state
# folder, and git runs without optional locks so the index is not refreshed.

export GIT_OPTIONAL_LOCKS=0
dir="${1:-$PWD}"
here="$(cd "$(dirname "$0")" && pwd -P)"
fails=0

row() { # $1 status, $2 check, $3 detail
  local detail="${3//|/\\|}"
  printf '| %s | %s | %s |\n' "$1" "$2" "$detail"
  [ "$1" != FAIL ] || fails=$((fails + 1))
}

. "$here/lib.sh" </dev/null

printf '| Status | Check | Detail |\n|---|---|---|\n'
row PASS swift-harness "plugin ${SH_VERSION:-unknown version}"

# ---------- tools ----------

if ! sh_has_jq; then
  row FAIL jq "not installed: every swift-harness hook is inactive. Fix: brew install jq"
  exit 1
fi
row PASS jq "$(jq --version 2>/dev/null)"

SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}')"
SH_ROOT="$(sh_root)"
SH_CONFIG="$SH_ROOT/.claude/swift-harness.json"

developer_dir="$(xcode-select -p 2>/dev/null)"
if [ -z "$developer_dir" ]; then
  row WARN Xcode "no developer tools selected: xcodebuild and swift are unavailable. Fix: install Xcode, then sudo xcode-select -s /Applications/Xcode.app"
elif [[ "$developer_dir" == *CommandLineTools* ]]; then
  row WARN Xcode "only the Command Line Tools are selected ($developer_dir): xcodebuild cannot build app targets. Fix: sudo xcode-select -s /Applications/Xcode.app"
else
  row PASS Xcode "$(xcodebuild -version 2>/dev/null | head -1), $(swift --version 2>/dev/null | head -1 | sed 's/ (.*//')"
fi

# ---------- configuration ----------

if git -C "$SH_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  in_git=true
  row PASS Git "$SH_ROOT"
else
  in_git=false
  row FAIL Git "$SH_ROOT is not a git repository: the end-of-turn check needs git to see what changed. Fix: git init"
fi

if [ ! -f "$SH_CONFIG" ]; then
  row FAIL Config "no .claude/swift-harness.json: the hooks are off in this project. Fix: run /swift-harness:setup"
  exit 1
fi
if ! jq -e 'type == "object"' "$SH_CONFIG" >/dev/null 2>&1; then
  row FAIL Config ".claude/swift-harness.json is not a valid JSON object: the hooks fall back to defaults for every value. Fix: $(jq . "$SH_CONFIG" 2>&1 >/dev/null | head -1)"
  exit 1
fi

unknown="$(jq -r '
  (keys - ["guest", "uiTests", "scope", "format", "lint", "lintBlocking", "guardPbxproj", "guardBash", "protectedPaths", "verify", "registry", "layout", "screenshots", "snapshots", "security", "docs", "performance"])[],
  (if (.verify | type) == "object" then (.verify | keys - ["enabled", "command", "maxAttempts", "inputs", "retryFailed"])[] | "verify." + . else empty end),
  (if (.registry | type) == "object" then (.registry | keys - ["enabled", "path", "sources"])[] | "registry." + . else empty end),
  (if (.layout | type) == "object" then (.layout | keys - ["enabled", "path"])[] | "layout." + . else empty end),
  (if (.screenshots | type) == "object" then (.screenshots | keys - ["path"])[] | "screenshots." + . else empty end),
  (if (.snapshots | type) == "object" then (.snapshots | keys - ["path"])[] | "snapshots." + . else empty end),
  (if (.security | type) == "object" then (.security | keys - ["enabled"])[] | "security." + . else empty end),
  (if (.docs | type) == "object" then (.docs | keys - ["enabled", "paths", "history", "ignore", "budget", "command", "blocking"])[] | "docs." + . else empty end),
  (if (.performance | type) == "object" then (.performance | keys - ["path"])[] | "performance." + . else empty end)
' "$SH_CONFIG" | paste -sd, - | sed 's/,/, /g')"
if [ -n "$unknown" ]; then
  row WARN "Config keys" "unknown, ignored by the hooks (typo?): $unknown"
else
  row PASS "Config keys" "all known"
fi

problems="$(jq -r '
  def check(path; ok; msg): if (getpath(path) != null) and (getpath(path) | ok | not) then msg else empty end;
  check(["guest"]; type == "boolean"; "guest must be true or false"),
  check(["scope"]; type == "array" and all(.[]; type == "object" and (.branch | type) == "string" and (.paths | type) == "array"); "scope must be a list of {branch, paths, base}"),
  check(["uiTests", "isolation"]; type == "array" and all(.[]; type == "string"); "uiTests.isolation must be a list of launch arguments or environment keys"),
  check(["uiTests", "launchHelpers"]; type == "array" and all(.[]; type == "string"); "uiTests.launchHelpers must be a list of function names"),
  check(["format"]; . == "swiftformat" or . == "swift-format" or . == "none"; "format must be swiftformat, swift-format or none"),
  check(["lint"]; . == "swiftlint" or . == "none"; "lint must be swiftlint or none"),
  check(["lintBlocking"]; type == "boolean"; "lintBlocking must be true or false"),
  check(["guardPbxproj"]; type == "boolean"; "guardPbxproj must be true or false"),
  check(["protectedPaths"]; type == "array" and all(.[]; type == "string"); "protectedPaths must be a list of paths"),
  check(["guardBash"]; type == "boolean"; "guardBash must be true or false"),
  check(["verify"]; type == "object"; "verify must be an object"),
  (if (.verify | type) == "object" then
    check(["verify", "enabled"]; type == "boolean"; "verify.enabled must be true or false"),
    check(["verify", "command"]; type == "string" and length > 0; "verify.command must be a non-empty string"),
    check(["verify", "maxAttempts"]; type == "number" and . >= 1 and floor == .; "verify.maxAttempts must be a whole number, 1 or more"),
    check(["verify", "retryFailed"]; type == "boolean"; "verify.retryFailed must be true or false"),
    check(["verify", "inputs"]; type == "array" and all(.[]; type == "string"); "verify.inputs must be a list of paths")
  else empty end),
  check(["registry"]; type == "object"; "registry must be an object"),
  (if (.registry | type) == "object" then
    check(["registry", "enabled"]; type == "boolean"; "registry.enabled must be true or false"),
    check(["registry", "path"]; type == "string" and length > 0; "registry.path must be a path"),
    check(["registry", "sources"]; type == "array" and all(.[]; type == "string"); "registry.sources must be a list of folders")
  else empty end),
  check(["layout"]; type == "object"; "layout must be an object"),
  (if (.layout | type) == "object" then
    check(["layout", "enabled"]; type == "boolean"; "layout.enabled must be true or false"),
    check(["layout", "path"]; type == "string" and length > 0; "layout.path must be a path")
  else empty end),
  check(["screenshots"]; type == "object"; "screenshots must be an object"),
  (if (.screenshots | type) == "object" then
    check(["screenshots", "path"]; type == "string" and length > 0; "screenshots.path must be a path")
  else empty end),
  check(["snapshots"]; type == "object"; "snapshots must be an object"),
  (if (.snapshots | type) == "object" then
    check(["snapshots", "path"]; type == "string" and length > 0 and (startswith("/") | not) and (("/" + . + "/") | contains("/../") | not);
      "snapshots.path must be a folder inside the project")
  else empty end),
  check(["security"]; type == "object"; "security must be an object"),
  (if (.security | type) == "object" then
    check(["security", "enabled"]; type == "boolean"; "security.enabled must be true or false")
  else empty end),
  check(["docs"]; type == "object"; "docs must be an object"),
  (if (.docs | type) == "object" then
    check(["docs", "enabled"]; type == "boolean"; "docs.enabled must be true or false"),
    check(["docs", "paths"]; type == "array" and all(.[]; type == "string"); "docs.paths must be a list of paths"),
    check(["docs", "history"]; type == "array" and all(.[]; type == "string"); "docs.history must be a list of paths"),
    check(["docs", "ignore"]; type == "array" and all(.[]; type == "string"); "docs.ignore must be a list of paths"),
    check(["docs", "budget"]; type == "number" and . > 0; "docs.budget must be a number of bytes"),
    check(["docs", "command"]; type == "string" and length > 0; "docs.command must be a command line"),
    check(["docs", "blocking"]; type == "boolean"; "docs.blocking must be true or false")
  else empty end),
  check(["performance"]; type == "object"; "performance must be an object"),
  (if (.performance | type) == "object" then
    check(["performance", "path"]; type == "string" and length > 0 and (startswith("/") | not) and (("/" + . + "/") | contains("/../") | not);
      "performance.path must be a folder inside the project")
  else empty end)
' "$SH_CONFIG" | paste -sd ';' - | sed 's/;/; /g')"
if [ -n "$problems" ]; then
  row FAIL Config "$problems. Fix: edit .claude/swift-harness.json (see the README, Configuration)"
else
  row PASS Config ".claude/swift-harness.json"
fi

format="$(sh_cfg '.format' 'swiftformat')"
lint="$(sh_cfg '.lint' 'swiftlint')"
lint_blocking="$(sh_cfg '.lintBlocking' 'false')"
verify_enabled="$(sh_cfg '.verify.enabled' 'true')"
command_line="$(sh_cfg '.verify.command' 'scripts/verify.sh fast')"

# ---------- formatter and linter ----------

case "$format" in
  swiftformat)
    if command -v swiftformat >/dev/null 2>&1; then
      row PASS Formatter "swiftformat $(swiftformat --version 2>/dev/null | head -1)"
    else
      row WARN Formatter "swiftformat not installed: edited files are not formatted. Fix: brew install swiftformat"
    fi
    ;;
  swift-format)
    if xcrun --find swift-format >/dev/null 2>&1 || command -v swift-format >/dev/null 2>&1; then
      row PASS Formatter "swift-format (Xcode)"
    else
      row WARN Formatter "swift-format not found: edited files are not formatted. Fix: install Xcode 16 or later, or brew install swift-format"
    fi
    if [ -f "$SH_ROOT/.swift-format" ]; then
      row PASS "Formatter config" ".swift-format"
    else
      row WARN "Formatter config" "no .swift-format: swift-format applies 2-space indentation to every edited file. Fix: copy the template from /swift-harness:setup"
    fi
    ;;
  none) row INFO Formatter "off (format is none)" ;;
esac

if [ "$lint" = swiftlint ]; then
  if command -v swiftlint >/dev/null 2>&1; then
    row PASS SwiftLint "$(swiftlint version 2>/dev/null | head -1)${lint_blocking:+, lintBlocking $lint_blocking}"
  elif [ "$lint_blocking" = true ]; then
    row FAIL SwiftLint "not installed and lintBlocking is on: the end-of-turn check fails after every code change. Fix: brew install swiftlint, or set lintBlocking to false"
  else
    row WARN SwiftLint "not installed: edits are not linted. Fix: brew install swiftlint"
  fi
else
  row INFO SwiftLint "off (lint is none)"
fi

# ---------- placeholders and protected paths ----------

with_placeholders=""
for f in CLAUDE.md .claude/rules/*.md docs/ARCHITECTURE.md docs/DESIGN_SYSTEM.md docs/COMPONENT_REGISTRY.md docs/LAYOUT_CONTRACT.md \
  .swiftlint.yml .swiftformat .claude/swift-harness.json scripts/verify.sh; do
  [ -f "$SH_ROOT/$f" ] && grep -qE '\{\{[A-Z_]+\}\}' "$SH_ROOT/$f" && with_placeholders="$with_placeholders${with_placeholders:+, }$f"
done
if [ -n "$with_placeholders" ]; then
  row WARN Placeholders "unfilled {{...}} in: $with_placeholders. Fix: replace them with the project's values, or run /swift-harness:setup again"
else
  row PASS Placeholders "none left in the generated files"
fi

missing_paths=""
while IFS= read -r p; do
  [ -n "$p" ] && [[ "$p" != *"{{"* ]] || continue
  [ -e "$SH_ROOT/${p#./}" ] || missing_paths="$missing_paths${missing_paths:+, }$p"
done < <(jq -r '.protectedPaths[]? | strings' "$SH_CONFIG" 2>/dev/null)
if [ -n "$missing_paths" ]; then
  row WARN "Protected paths" "not found, so nothing is protected there (typo or moved?): $missing_paths"
else
  row PASS "Protected paths" "$(jq -r '[.protectedPaths[]? | strings | select(contains("{{") | not)] | if length == 0 then "none" else join(", ") end' "$SH_CONFIG")"
fi

# ---------- verification ----------

state="$(sh_state_path)"
verify_bin="${command_line%% *}"
verify_generated=false
verify_platforms=""
if [ "$verify_enabled" != true ]; then
  row WARN "Verify script" "verify.enabled is false: code changes are not built or tested at the end of a turn"
elif [[ "$verify_bin" == */* ]] && [ ! -f "$SH_ROOT/$verify_bin" ]; then
  row FAIL "Verify script" "$verify_bin does not exist: the end-of-turn check fails. Fix: run /swift-harness:setup, or fix verify.command"
elif [[ "$verify_bin" == */* ]] && [ ! -x "$SH_ROOT/$verify_bin" ]; then
  row FAIL "Verify script" "$verify_bin is not executable: the end-of-turn check fails. Fix: chmod +x $verify_bin"
elif [ -f "$SH_ROOT/$verify_bin" ] && grep -q '^PACKAGES=(' "$SH_ROOT/$verify_bin" && grep -q '^SCHEME=' "$SH_ROOT/$verify_bin"; then
  # The script generated by /swift-harness:setup: read its settings without running it.
  settings="$(sed -n -e 's/^XCODE_CONTAINER="\([^"]*\)".*/\1/p' -e 's/^SCHEME="\([^"]*\)".*/\1/p' -e 's/^PACKAGES=(\(.*\)).*/\1/p' \
    -e 's/^PLATFORMS=(\(.*\)).*/\1/p' -e 's/^IOS_SIMULATOR="\([^"]*\)".*/\1/p' "$SH_ROOT/$verify_bin")"
  verify_generated=true
  # A script generated before 1.5.0 has no PLATFORMS line: it builds for macOS.
  if grep -q '^PLATFORMS=(' "$SH_ROOT/$verify_bin"; then
    verify_platforms="$(sed -n 's/^PLATFORMS=(\([^)]*\)).*/\1/p' "$SH_ROOT/$verify_bin" | tr -d "\"'" | xargs)"
  else
    verify_platforms=macOS
  fi
  ios_simulator="$(sed -n 's/^IOS_SIMULATOR="\([^"]*\)".*/\1/p' "$SH_ROOT/$verify_bin")"
  scheme="$(sed -n 's/^SCHEME="\([^"]*\)".*/\1/p' "$SH_ROOT/$verify_bin")"
  # Quoted or bare words, read as text (SH130-05): doctor never runs the script.
  package_list="$(sed -n 's/^PACKAGES=(\([^)]*\)).*/\1/p' "$SH_ROOT/$verify_bin")"
  packages_unreadable=false
  case "$package_list" in *'$'* | *'`'* | *'\'*) packages_unreadable=true ;; esac
  package_paths="$(printf '%s' "$package_list" | grep -oE "\"[^\"]*\"|'[^']*'|[^[:space:]\"']+" | sed -E "s/^[\"'](.*)[\"']\$/\1/")"
  packages="$(printf '%s' "$package_paths" | paste -sd, - | sed 's/,/, /g')"
  missing_packages=""
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    [ -f "$SH_ROOT/$pkg/Package.swift" ] || missing_packages="$missing_packages${missing_packages:+, }$pkg"
  done <<<"$package_paths"
  if [[ "$settings" == *"{{"* ]]; then
    row FAIL "Verify script" "$verify_bin still has {{...}} placeholders in its settings: it reports NOT CONFIGURED. Fix: set XCODE_CONTAINER, SCHEME, PACKAGES, PLATFORMS and IOS_SIMULATOR at the top"
  elif [ "$packages_unreadable" = true ]; then
    row WARN "Verify script" "$verify_bin: its PACKAGES list ($package_list) cannot be read without running the script, so the package folders were not checked"
  elif [ -z "$scheme" ] && [ -z "$packages" ]; then
    row FAIL "Verify script" "$verify_bin sets no scheme and no package: it reports NOT CONFIGURED. Fix: set SCHEME or PACKAGES at the top"
  elif [ -n "$missing_packages" ]; then
    row FAIL "Verify script" "$verify_bin lists packages with no Package.swift: $missing_packages. Fix: correct PACKAGES at the top"
  else
    row PASS "Verify script" "$verify_bin: ${scheme:+scheme $scheme}${scheme:+${packages:+, }}${packages:+packages $packages}"
  fi
else
  row PASS "Verify script" "custom command '$command_line', not inspected"
fi

# ---------- platforms (#40) ----------
# Read as text from project.pbxproj build settings and Package.swift `platforms:`, never by
# running anything, then compared with the platforms scripts/verify.sh builds and tests.

platform_sources="$(sh_platforms "$SH_ROOT")"
project_platforms="$(printf '%s' "$platform_sources" | cut -f1 | paste -sd, - | sed 's/,/, /g')"
source_of() { printf '%s' "$platform_sources" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }

if [ "$verify_enabled" = true ] && [ "$verify_generated" = true ]; then
  platform_problem=false
  unknown=""
  for p in $verify_platforms; do
    case "$p" in macOS | iOS) ;; *) unknown="$unknown${unknown:+, }$p" ;; esac
  done
  if [ -n "$unknown" ]; then
    row FAIL Platforms "$verify_bin lists platforms it cannot build: $unknown: it reports NOT CONFIGURED. Fix: use macOS or iOS in PLATFORMS"
    platform_problem=true
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case " $verify_platforms " in *" $p "*) continue ;; esac
    platform_problem=true
    case "$p" in
      macOS | iOS)
        row WARN Platforms "$p (declared in $(source_of "$p")) is not built or tested by $verify_bin: a change can break it unnoticed. Fix: add \"$p\" to PLATFORMS$([ "$p" = iOS ] && echo ' and set IOS_SIMULATOR') at the top" ;;
      *)
        row WARN Platforms "$p (declared in $(source_of "$p")) is not supported by $verify_bin yet: nothing builds it at the end of a turn. Build it yourself before merging" ;;
    esac
  done <<<"$(printf '%s' "$platform_sources" | cut -f1)"
  if [ -z "$scheme" ] && [ -n "$verify_platforms" ] && [ "$verify_platforms" != macOS ]; then
    row WARN Platforms "$verify_bin has no SCHEME, so $(printf '%s' "$verify_platforms" | sed 's/macOS//' | xargs | sed 's/ /, /g') in PLATFORMS is never built: swift test runs on this Mac only and the result is PARTIAL. Fix: set SCHEME to a scheme that builds for every platform"
    platform_problem=true
  fi
  if [ "$platform_problem" = false ]; then
    if [ -z "$project_platforms" ]; then
      row INFO Platforms "none declared in project.pbxproj or Package.swift; $verify_bin checks ${verify_platforms// /, }"
    else
      row PASS Platforms "$project_platforms: each built and tested by $verify_bin"
    fi
  fi
  case " $verify_platforms " in
    *" iOS "*)
      if [ -z "$ios_simulator" ]; then
        row FAIL "iOS simulator" "IOS_SIMULATOR is empty in $verify_bin: full mode cannot run the iOS tests. Fix: set it to a simulator from xcrun simctl list devices available"
      elif ! command -v xcrun >/dev/null 2>&1; then
        row WARN "iOS simulator" "xcrun not found, so '$ios_simulator' was not checked. Fix: install Xcode"
      elif xcrun simctl list devices available 2>/dev/null | grep -qF "    $ios_simulator ("; then
        row PASS "iOS simulator" "'$ios_simulator' is available"
      else
        row FAIL "iOS simulator" "'$ios_simulator' is not an available simulator (xcrun simctl list devices available): iOS tests in full mode fail. Fix: set IOS_SIMULATOR to one that exists, or install an iOS runtime (Xcode › Settings › Components) and create the device (Window › Devices and Simulators)"
      fi
      ;;
  esac
elif [ -n "$project_platforms" ]; then
  row INFO Platforms "$project_platforms (from project.pbxproj and Package.swift); the verify command is not the generated script, so which ones it builds was not checked"
fi

if [ "$verify_enabled" = true ]; then
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    row WARN "Verify approval" "unknown: run this check through /swift-harness:doctor so it can read the plugin data folder"
  elif sh_verify_approved "$command_line" "$state" && sh_verify_partial "$command_line"; then
    row WARN "Verify approval" "'$command_line' approved, partial coverage: it has quotes or shell syntax, so the files it runs may change without a new approval. Fix: list them in verify.inputs, then type /swift-harness:approve-verify"
  elif sh_verify_approved "$command_line" "$state"; then
    src="$(sh_verify_approval_source "$command_line" "$state")"
    if [ "$src" = "this path" ]; then row PASS "Verify approval" "'$command_line' approved for this path"
    else row PASS "Verify approval" "'$command_line' approved in another worktree of this repository (${src#worktree }), with the same command and files"; fi
  else
    row FAIL "Verify approval" "'$command_line' is not approved (new, or it or a file it runs changed): the end-of-turn check does not run it. Fix: review it, then type /swift-harness:approve-verify"
  fi
  # A hint, not a warning (#131): a name in a comment counts, so it may name a script that never
  # runs. approve-verify shows the same list when the user reviews the approval.
  uncovered="$(sh_verify_uncovered "$command_line" | awk -F'\t' '
    !($1 in named) { order[++n] = $1 }
    { named[$1] = ($1 in named) ? named[$1] ", " $2 : $2 }
    END { for (i = 1; i <= n; i++) printf "%s%s (named in %s)", (i > 1 ? "; " : ""), order[i], named[order[i]] }')"
  [ -z "$uncovered" ] || row INFO "Verify coverage" "the approved files name scripts the approval does not cover: $uncovered. Read as text, so a name in a comment counts and a path built at run time is not seen. If one of them runs, a change to it asks nothing: add it to verify.inputs in .claude/swift-harness.json, then /swift-harness:approve-verify. If it is only mentioned, nothing to do"
fi

# ---------- security settings (#32) ----------

if [ ! -f "$state/security-approved" ] && [ "$(sh_cfg '.security.enabled' 'true')" != true ]; then
  row WARN "Security settings" "security.enabled is false: entitlements, ATS and signing settings changed by Claude are not reported"
elif [ ! -f "$state/security-approved" ]; then
  row INFO "Security settings" "no baseline yet: the next session start records the current entitlements, ATS and signing settings ($("$here/security.sh" state --project "$SH_ROOT" 2>/dev/null | grep -c .) setting(s)) for /swift-harness:approve-security"
elif security_changes="$("$here/security.sh" check --project "$SH_ROOT" 2>/dev/null)" && [ "$(sh_cfg '.security.enabled' 'true')" != true ]; then
  row WARN "Security settings" "security.enabled is false, and you approved turning it off: entitlements, ATS and signing settings changed by Claude are not reported"
elif [ -z "$security_changes" ] && [ -f "$state/security-unreviewed" ]; then
  relaxed="$("$here/security.sh" relaxed --project "$SH_ROOT" 2>/dev/null | head -5 | paste -sd';' - | sed 's/;/; /g')"
  row WARN "Security settings" "baseline recorded automatically on $(cat "$state/security-unreviewed") and not reviewed by you: changes are compared with it, but what was already there was accepted as is${relaxed:+; already weakening protection: $relaxed}. Fix: type /swift-harness:approve-security to review it"
elif [ -z "$security_changes" ]; then
  row PASS "Security settings" "$(grep -c . "$state/security-approved") setting(s) unchanged since approval (entitlements, ATS, signing build settings)"
else
  row FAIL "Security settings" "changed since your approval, so the end-of-turn check fails: $(printf '%s\n' "$security_changes" | grep -E '^[+-] ' | head -5 | paste -sd';' - | sed 's/;/; /g'). Fix: revert what you did not intend, then type /swift-harness:approve-security"
fi

# ---------- test isolation (#68) ----------

iso_out="$("$here/isolation.sh" check "$SH_ROOT" 2>&1)"
case $? in
  0) [ -z "$(sh_cfg '.uiTests.isolation[0]' '')" ] || row PASS "Test isolation" "every UI test that launches the app names an isolation argument ($(jq -r '.uiTests.isolation | join(", ")' "$SH_CONFIG" 2>/dev/null)) or a launch helper that does" ;;
  1) row WARN "Test isolation" "$(printf '%s\n' "$iso_out" | grep '^- ' | head -3 | sed 's/^- //' | paste -sd ';' - | sed 's/;/; /g'). Fix: launch with the argument, or through a helper that sets it" ;;
  3) row WARN "Test isolation" "${iso_out#Test isolation: } Fix: list in uiTests.isolation the launch argument or environment key that gives the app its own test store and defaults" ;;
esac

# ---------- project structure ----------

# Guest mode (#71): the project's own agent rules and docs are the source of truth.
if [ "$(sh_cfg '.guest' 'false')" = true ]; then
  own="$(for f in CLAUDE.md AGENTS.md .claude/rules; do [ -e "$SH_ROOT/$f" ] && printf '%s\n' "$f"; done | paste -sd, - | sed 's/,/, /g')"
  row INFO "Mode" "guest: only .claude/swift-harness.json and the verify script are swift-harness's; the project's own ${own:-rules and docs} are the source of truth, and setup does not add its templates"
fi

packages_found="$(cd "$SH_ROOT" && find . -maxdepth 3 -name Package.swift -not -path '*/.build/*' 2>/dev/null |
  sed 's|^\./||' | sort | paste -sd, - | sed 's/,/, /g')"
containers="$(cd "$SH_ROOT" && find . -maxdepth 2 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -not -path '*/.build/*' \
  -not -path '*.xcodeproj/*' 2>/dev/null | sed 's|^\./||' | sort | paste -sd, - | sed 's/,/, /g')"
if [ -n "$packages_found" ]; then
  row INFO "Project structure" "SwiftPM packages: $packages_found${containers:+; Xcode: $containers}"
else
  row INFO "Project structure" "${containers:-no Xcode project found}, no SwiftPM package"
fi

# Architecture contracts (#13). Checked without running any manifest: doctor runs nothing
# from the repository.
if [ -f "$SH_ROOT/$SH_CONTRACT" ]; then
  if summary="$("$here/contracts.sh" --validate "$SH_ROOT" 2>&1)"; then
    if [ "$verify_enabled" = true ] && [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && sh_verify_approved "$command_line" "$state"; then
      row PASS "Architecture contracts" "$SH_CONTRACT: $summary, checked at the end of each turn and when Package.swift is edited"
    else
      row WARN "Architecture contracts" "$SH_CONTRACT: $summary, but not checked: reading the dependency graph runs Package.swift, so it happens only with the verify command enabled and approved"
    fi
  else
    row FAIL "Architecture contracts" "${summary#Architecture contracts ($SH_CONTRACT): }"
  fi
elif [ -n "$packages_found" ]; then
  row INFO "Architecture contracts" "none: add $SH_CONTRACT to fail the end-of-turn check when a target gains a dependency the contract does not allow"
else
  row INFO "Architecture contracts" "not available: they check the dependencies between SwiftPM targets, and this project has no SwiftPM package"
fi

# Component registry (#7). Reads Markdown and Swift files only.
registry="$(sh_registry)"
if [ "$(sh_cfg '.registry.enabled' 'true')" != true ]; then
  row INFO "Component registry" "off (registry.enabled is false)"
elif [ ! -f "$SH_ROOT/$registry" ]; then
  row INFO "Component registry" "none: $registry lists the shared components Claude must reuse; /swift-harness:setup creates it, and the end-of-turn check keeps it true"
else
  registry_out="$("$here/registry.sh" check "$SH_ROOT" 2>&1)"
  case $? in
    0)
      summary="$("$here/registry.sh" summary "$SH_ROOT")"
      missing="$("$here/registry.sh" missing "$SH_ROOT" | awk -F'\t' '{printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2}')"
      if [ -n "$missing" ]; then
        row WARN "Component registry" "$summary; not listed: $missing. Fix: add them, or list them under Internal"
      elif [ -z "$(jq -r '.registry.sources[]? | strings' "$SH_CONFIG" 2>/dev/null | grep -v '{{')" ]; then
        row PASS "Component registry" "$summary, checked at the end of each turn; set registry.sources to also find components it does not list"
      else
        row PASS "Component registry" "$summary, checked at the end of each turn"
      fi
      ;;
    3) row WARN "Component registry" "${registry_out#Component registry ($registry): }" ;;
    *) row FAIL "Component registry" "$(printf '%s\n' "$registry_out" | grep '^- ' | head -3 | sed 's/^- //' | paste -sd ';' - | sed 's/;/; /g'). Fix: update $registry" ;;
  esac
fi

# Layout contract (#34). Reads Markdown and Swift files only; the sizes are measured by the tests.
layout="$(sh_layout)"
if [ "$(sh_cfg '.layout.enabled' 'true')" != true ]; then
  row INFO "Layout contract" "off (layout.enabled is false)"
elif [ ! -f "$SH_ROOT/$layout" ]; then
  row INFO "Layout contract" "none: $layout gives each main screen the window sizes it must hold, measured by the project's tests; /swift-harness:setup creates it"
else
  layout_out="$("$here/layout.sh" check "$SH_ROOT" 2>&1)"
  case $? in
    0) row PASS "Layout contract" "$("$here/layout.sh" summary "$SH_ROOT"), checked at the end of each turn; the sizes are measured by the tests the verify command runs" ;;
    3) row WARN "Layout contract" "${layout_out#Layout contract ($layout): }" ;;
    *) row FAIL "Layout contract" "$(printf '%s\n' "$layout_out" | grep '^- ' | head -3 | sed 's/^- //' | paste -sd ';' - | sed 's/;/; /g'). Fix: update $layout" ;;
  esac
fi

# Docs references (#70). Reads Markdown only. With docs.command, the project's own check (#105).
if ! sh_docs_on; then
  row INFO "Docs references" "off (docs.enabled is false)"
elif [ -n "$(sh_docs_command)" ]; then
  mode="new problems block the end of a turn"; sh_docs_blocking || mode="observed: recorded, never blocking (docs.blocking is false)"
  if sh_verify_approved "$command_line" "$state" 2>/dev/null; then row PASS "Docs references" "the project's own check '$(sh_docs_command)' runs instead of the harness's; $mode"
  else row WARN "Docs references" "the project's own check '$(sh_docs_command)' is set, but not approved: it does not run. Fix: /swift-harness:approve-verify"; fi
else
  docs_out="$("$here/docs.sh" check "$SH_ROOT" 2>&1)"
  if [ $? -eq 0 ]; then
    row PASS "Docs references" "$("$here/docs.sh" summary "$SH_ROOT"); new broken references block the end of a turn"
  else
    count="$(printf '%s\n' "$docs_out" | grep -c '^- ')"
    row FAIL "Docs references" "$count problem(s): $(printf '%s\n' "$docs_out" | grep '^- ' | head -3 | sed 's/^- //' | paste -sd ';' - | sed 's/;/; /g'). Problems already there when a session starts do not block it; fix them in the docs"
  fi
fi

# Performance baselines (#33): approved numbers the project's budget tests compare with.
performance="$(sh_performance)"
if [ ! -d "$SH_ROOT/$performance" ]; then
  row INFO "Performance baselines" "none: $performance/ holds the numbers the performance budget tests compare with (tests/PerformanceBudget.swift from the setup templates), approved with /swift-harness:approve-performance"
else
  count="$(find "$SH_ROOT/$performance" -type f -name '*.json' | wc -l | tr -d ' ')"
  made="$(find "$SH_ROOT/$performance" -type f -name '*.json' -exec jq -r '"\(.arch // "?") macOS \(.os // "?") \(.configuration // "?")"' {} + 2>/dev/null | sort -u | paste -sd, - | sed 's/,/, /g')"
  waiting="$(find "$SH_ROOT/$SH_PERFORMANCE_CANDIDATES" -name '*.result.json' -exec jq -r 'select(.status != "passed" and .status != "unstable") | .status' {} + 2>/dev/null | grep -vc '^not-compared$')"
  waits=""
  [ "${waiting:-0}" -gt 0 ] && waits="; $waiting result(s) from the last test run wait for approval: /swift-harness:approve-performance"
  row PASS "Performance baselines" "$count budget(s) made on $made; compared only on a Mac with the same architecture, macOS version and build configuration, where instructions are counted$waits"
fi

# Snapshot baselines (#9): approved images the project's snapshot tests compare with.
snapshots="$(sh_snapshots)"
if [ ! -d "$SH_ROOT/$snapshots" ]; then
  row INFO "Snapshot baselines" "none: $snapshots/ holds the images the visual regression tests compare with (tests/Snapshot.swift from the setup templates), approved with /swift-harness:approve-snapshots"
else
  count="$(find "$SH_ROOT/$snapshots" -type f -name '*.png' | wc -l | tr -d ' ')"
  made="$(find "$SH_ROOT/$snapshots" -type f -name '*.json' -exec jq -r '.os // empty' {} + 2>/dev/null | sort -u | paste -sd, - | sed 's/,/, /g')"
  this="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1-2)"
  case "$this" in *.*) ;; ?*) this="$this.0" ;; esac
  waiting=0
  for result in "$SH_ROOT/$SH_SNAPSHOT_CANDIDATES"/*.result.json; do
    [ -f "$result" ] && [ -f "${result%.result.json}.png" ] && [ "$(jq -r .status "$result" 2>/dev/null)" != passed ] && waiting=$((waiting + 1))
  done
  waits=""
  [ "$waiting" -gt 0 ] && waits="; $waiting new image(s) from the last test run wait for approval: /swift-harness:approve-snapshots"
  if [ -z "$made" ]; then
    row WARN "Snapshot baselines" "$count image(s) in $snapshots/ without metadata: the tests cannot tell which macOS they were made on$waits"
  elif [ "$made" != "$this" ]; then
    row WARN "Snapshot baselines" "$count image(s) made on macOS $made; this Mac runs macOS ${this:-?}, so the snapshot tests report them as not compared. Compare on the Mac they were made on, or approve new ones here$waits"
  elif [ "$waiting" -gt 0 ]; then
    row WARN "Snapshot baselines" "$count image(s) made on macOS $made$waits"
  else
    row PASS "Snapshot baselines" "$count image(s) made on macOS $made, compared on this Mac; only /swift-harness:approve-snapshots replaces them"
  fi
fi

# ---------- last verification ----------

if [ "$in_git" = true ] && [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  fp="$(sh_identity)"
  outcome="$(sh_verify_coverage "$state" "$fp" outcome)"
  if [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ] && [ "$outcome" = partial ]; then
    row WARN "Last verification" "PARTIAL on the current code: the verify command passed on $(sh_verify_coverage "$state" "$fp" checked), but not checked on $(sh_verify_coverage "$state" "$fp" 'not checked') (no build or test ran for it)"
  elif [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ] && [ -n "$outcome" ]; then
    row PASS "Last verification" "the verify command passed on the current code: built on $(sh_verify_coverage "$state" "$fp" checked); tests ran on $(sh_verify_coverage "$state" "$fp" tested)"
  elif [ "$fp" = "$(cat "$state/passed" 2>/dev/null)" ]; then
    row PASS "Last verification" "the verify command passed on the current code; its output names no platforms"
  elif [ "$fp" = "$(head -1 "$state/checked" 2>/dev/null)" ]; then
    row WARN "Last verification" "only $(sed -n 2p "$state/checked") passed on the current code; build and tests were not run, because the verify command is disabled or not approved"
  elif [ "$fp" = "$(cat "$state/failed" 2>/dev/null)" ]; then
    row WARN "Last verification" "failed on the current code and has not passed since. Fix: ask Claude to fix it, or run $command_line"
  elif [ "$(jq -r 'select(.outcome == "not-finished") | .code // empty' "$state/evidence.json" 2>/dev/null)" = "$fp" ]; then
    row WARN "Last verification" "the end-of-turn check started on the current code and did not finish: the hook was stopped before its result, usually by its timeout (900 s). Fix: make $command_line shorter, or run it yourself"
  else
    row INFO "Last verification" "no result for the current code: the check runs at the end of a turn, once the code differs from what it was when the session started"
  fi
  # The last end-of-turn record (#81), when it is about the current code.
  if [ "$(jq -r '.code // empty' "$state/evidence.json" 2>/dev/null)" = "$fp" ]; then
    ev_summary="$(jq -r '[.checks[] | "\(.name): \(.result)"] | join("; ")' "$state/evidence.json" 2>/dev/null)"
    ev_missing="$(jq -r '[.checks[] | select(.result | test("^not")) | .name + (if .detail then " (" + .detail + ")" else "" end)] | join(", ")' "$state/evidence.json" 2>/dev/null)"
    if [ -n "$ev_missing" ]; then row WARN "Last turn's checks" "${ev_summary:-none}. Not checked: $ev_missing"
    elif [ -n "$ev_summary" ]; then row PASS "Last turn's checks" "$ev_summary"; fi
  fi
  if [ "$lint_blocking" = true ] && [ -s "$state/lint-pending" ]; then
    row WARN "Lint pending" "failed SwiftLint at the last check: $(head -5 "$state/lint-pending" | paste -sd, - | sed 's/,/, /g')"
  fi
fi

[ "$fails" -eq 0 ]
