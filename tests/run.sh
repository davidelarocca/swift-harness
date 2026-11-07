#!/bin/bash
# Tests for the swift-harness hook scripts and the verify.sh template.
# Needs only bash, git and jq: xcodebuild and swift are replaced by fakes.
# Usage: tests/run.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN="$HERE/../plugins/swift-harness"
SCRIPTS="$PLUGIN/scripts"
TEMPLATE="$PLUGIN/skills/setup/templates/verify.sh"

# Physical path, so the symlink tests below control exactly where a symlink appears.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/swift-harness-tests.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
nok() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' | head -15
}

# $1 name, $2 expected exit code, $3 regex that must match the output,
# $4 output starting with "exit=<code>", $5 optional regex that must not match.
expect_result() {
  local code="${4%%$'\n'*}"
  code="${code#exit=}"
  if [ "$code" = "$2" ] && grep -qE -- "$3" <<<"$4" && { [ -z "${5:-}" ] || ! grep -qE -- "$5" <<<"$4"; }; then
    ok "$1"
  else
    nok "$1" "$4"
  fi
}

# ---------- fixtures ----------

# A git repo opted into swift-harness, with a protected Sources/Audio/ and a
# fake verify script driven by FAKE_VERIFY_EXIT and logging to FAKE_VERIFY_LOG.
new_project() {
  local p="$TMP/$1"
  mkdir -p "$p/.claude" "$p/Sources/Audio" "$p/Sources/AudioTools" "$p/scripts" "$p/App.xcodeproj"
  git -C "$p" init -q
  git -C "$p" config user.email test@example.com
  git -C "$p" config user.name test
  printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3},"protectedPaths":["Sources/Audio/"]}' \
    >"$p/.claude/swift-harness.json"
  echo 'let engine = 1' >"$p/Sources/Audio/Engine.swift"
  echo 'let tool = 1' >"$p/Sources/AudioTools/Tool.swift"
  echo 'let app = 1' >"$p/Sources/App.swift"
  echo 'A = 1' >"$p/Config.xcconfig"
  echo '<plist/>' >"$p/Info.plist"
  echo '# readme' >"$p/README.md"
  echo '// pbx' >"$p/App.xcodeproj/project.pbxproj"
  cat >"$p/scripts/verify.sh" <<'EOF'
#!/bin/bash
echo run >>"${FAKE_VERIFY_LOG:-/dev/null}"
echo "fake verify output"
exit "${FAKE_VERIFY_EXIT:-0}"
EOF
  chmod +x "$p/scripts/verify.sh"
  git -C "$p" add -A
  git -C "$p" commit -qm init
  approve "$p" >/dev/null
  printf '%s' "$p"
}

# Run a hook script with a JSON input. $1 script, $2 cwd, $3 extra JSON fields (object).
hook() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg cwd "$2" --argjson extra "$extra" '{cwd: $cwd, session_id: "test"} + $extra' |
    CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$2" "$SCRIPTS/$1"
}

# The user's approval of a project's verify command (#6), as /swift-harness:approve-verify
# gives it: read the status, then approve the digest that was shown.
approval() { # $1 project, then approve-verify.sh arguments
  local dir="$1"
  shift
  CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/approve-verify.sh" "$@" "$dir"
}
approve() {
  local digest
  digest="$(approval "$1" --status | sed -n 's/^Digest: *//p')"
  approval "$1" --approve "$digest"
}

edit_input() { jq -nc --arg f "$1" '{tool_name: "Edit", tool_input: {file_path: $f}}'; }

fingerprint() {
  jq -nc --arg cwd "$1" '{cwd: $cwd}' |
    bash -c '. "$0"; sh_init && sh_fingerprint' "$SCRIPTS/lib.sh"
}

# ---------- guard.sh ----------

guard_asks() { hook guard.sh "$1" "$(edit_input "$2")" | grep -q '"permissionDecision": "ask"'; }

expect_ask() {
  if guard_asks "$1" "$2"; then ok "$3"; else nok "$3" "no approval request for $2"; fi
}
expect_no_ask() {
  if guard_asks "$1" "$2"; then nok "$3" "unexpected approval request for $2"; else ok "$3"; fi
}

P="$(new_project guard)"
expect_ask "$P" "$P/Sources/Audio/Engine.swift" "guard: edit inside a protected path asks"
expect_ask "$P" "$P/Sources/Audio/New/Thing.swift" "guard: new file in a new folder inside a protected path asks"
expect_no_ask "$P" "$P/Sources/AudioTools/Tool.swift" "guard: sibling folder sharing the prefix does not ask"
expect_no_ask "$P" "$P/Sources/App.swift" "guard: unprotected file does not ask"
expect_ask "$P" "$P/App.xcodeproj/project.pbxproj" "guard: project.pbxproj asks"
expect_ask "$P" "$P/Sources/AudioTools/../Audio/Engine.swift" "guard: ../ into a protected path asks"
expect_ask "$P" "$P/Sources/Missing/../Audio/Engine.swift" "guard: ../ through a missing folder asks"

ln -s "$P" "$TMP/guard-link"
expect_ask "$TMP/guard-link" "$TMP/guard-link/Sources/Audio/Engine.swift" "guard: project opened through a symlinked path asks"

ln -s Audio "$P/Sources/AudioAlias"
expect_ask "$P" "$P/Sources/AudioAlias/Engine.swift" "guard: symlinked folder pointing into a protected path asks"

ln -s Audio/Engine.swift "$P/Sources/EngineAlias.swift"
expect_ask "$P" "$P/Sources/EngineAlias.swift" "guard: symlinked file pointing into a protected path asks"

P="$(new_project 'My Café App')"
expect_ask "$P" "$P/Sources/Audio/Engine.swift" "guard: project path with spaces and accents asks"
expect_no_ask "$P" "$P/Sources/App.swift" "guard: project path with spaces and accents, unprotected file"

P="$(new_project guard-link-entry)"
ln -s Sources/Audio "$P/Audio"
printf '%s\n' '{"protectedPaths":["Audio/"]}' >"$P/.claude/swift-harness.json"
expect_ask "$P" "$P/Sources/Audio/Engine.swift" "guard: protected entry that is a symlink protects its target"
expect_ask "$P" "$P/Audio/Engine.swift" "guard: protected entry that is a symlink protects the link path"
expect_no_ask "$P" "$P/Sources/App.swift" "guard: protected symlink entry does not protect unrelated files"

# Security settings protected file by file, as /swift-harness:setup proposes: the guard
# matches exact paths and folder prefixes, no globs.
P="$(new_project guard-security-files)"
mkdir -p "$P/App"
echo '<plist/>' >"$P/App/App.entitlements"
echo '<plist/>' >"$P/App/PrivacyInfo.xcprivacy"
printf '%s\n' '{"protectedPaths":["App/App.entitlements","App/PrivacyInfo.xcprivacy","Info.plist"]}' >"$P/.claude/swift-harness.json"
expect_ask "$P" "$P/App/App.entitlements" "guard: a protected entitlements file asks"
expect_ask "$P" "$P/App/PrivacyInfo.xcprivacy" "guard: a protected privacy manifest asks"
expect_ask "$P" "$P/Info.plist" "guard: a protected Info.plist asks"
expect_no_ask "$P" "$P/App/App.entitlements.bak" "guard: a protected file does not protect names that start like it"
expect_no_ask "$P" "$P/App/Other.entitlements" "guard: only the listed entitlements file is protected"

mkdir -p "$TMP/elsewhere/Sources/Audio"
expect_no_ask "$P" "$TMP/elsewhere/Sources/Audio/x.swift" "guard: file outside the repository does not ask"
expect_no_ask "$P" "$P/../elsewhere/Sources/Audio/x.swift" "guard: ../ out of the repository does not ask"

mkdir -p "$TMP/plain/Sources/Audio"
git -C "$TMP/plain" init -q
expect_no_ask "$TMP/plain" "$TMP/plain/Sources/Audio/x.swift" "guard: project without swift-harness.json is untouched"

# ---------- fingerprint ----------

P="$(new_project fp)"
base="$(fingerprint "$P")"

fp_changes() { # $1 test name; the caller has already changed the project
  local now
  now="$(fingerprint "$P")"
  if [ "$now" != "$base" ]; then ok "$1"; else nok "$1" "fingerprint did not change"; fi
  git -C "$P" checkout -q -- . && git -C "$P" clean -qfd
}
fp_same() {
  local now
  now="$(fingerprint "$P")"
  if [ "$now" = "$base" ]; then ok "$1"; else nok "$1" "fingerprint changed"; fi
  git -C "$P" checkout -q -- . && git -C "$P" clean -qfd
}

echo 'let app = 2' >"$P/Sources/App.swift"; fp_changes "fingerprint: edited Swift file"
echo 'let x = 1' >"$P/Sources/New File.swift"; fp_changes "fingerprint: new untracked Swift file with a space in its name"
rm "$P/Sources/App.swift"; fp_changes "fingerprint: deleted Swift file"
echo 'A = 2' >"$P/Config.xcconfig"; fp_changes "fingerprint: edited .xcconfig"
echo '<plist>x</plist>' >"$P/Info.plist"; fp_changes "fingerprint: edited Info.plist"
mkdir -p "$P/Assets.xcassets/Accent.colorset"
echo '{}' >"$P/Assets.xcassets/Accent.colorset/Contents.json"; fp_changes "fingerprint: new untracked asset"
echo '{}' >"$P/Localizable.xcstrings"; fp_changes "fingerprint: new string catalog"
echo '{"verify":{"command":"true"}}' >"$P/.claude/swift-harness.json"; fp_changes "fingerprint: edited swift-harness.json"
echo '# changed' >"$P/README.md"; fp_same "fingerprint: README edit is ignored"
mkdir -p "$P/.build/DerivedData/Build"
echo '<plist/>' >"$P/.build/DerivedData/Build/Info.plist"
echo 'let gen = 1' >"$P/.build/DerivedData/Build/Gen.swift"; fp_same "fingerprint: build output in .build is ignored"
# Coverage added for #18.
mkdir -p "$P/App.xcworkspace"
echo '<Workspace/>' >"$P/App.xcworkspace/contents.xcworkspacedata"; fp_changes "fingerprint: new workspace"
mkdir -p "$P/App.xcworkspace/xcshareddata/swiftpm"
echo '{}' >"$P/App.xcworkspace/xcshareddata/swiftpm/Package.resolved"; fp_changes "fingerprint: workspace Package.resolved"
echo '// swift-tools-version:5.9' >"$P/Package.swift"; fp_changes "fingerprint: root Package.swift"
mkdir -p "$P/Packages/Core"
echo '// swift-tools-version:5.9' >"$P/Packages/Core/Package.swift"; fp_changes "fingerprint: nested Package.swift"
mkdir -p "$P/Sources/App/Media"
echo 'x' >"$P/Sources/App/Media/sound.caf"; fp_changes "fingerprint: SwiftPM resource outside a Resources folder"
mkdir -p "$P/Packages/Core/Sources/Core/Data"
echo '{}' >"$P/Packages/Core/Sources/Core/Data/seed.json"; fp_changes "fingerprint: resource in a nested package's Sources"
mkdir -p "$P/Tests/AppTests/Fixtures"
echo '{}' >"$P/Tests/AppTests/Fixtures/sample.json"; fp_changes "fingerprint: test fixture"
rm "$P/scripts/verify.sh"; fp_changes "fingerprint: deleted verify script"
echo 'disabled_rules: []' >"$P/.swiftlint.yml"; fp_changes "fingerprint: new .swiftlint.yml"
mkdir -p "$P/App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes"
echo '<plist/>' >"$P/App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/xcschememanagement.plist"
echo 'x' >"$P/App.xcodeproj/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate"; fp_same "fingerprint: Xcode per-user state is ignored"
echo 'x' >"$P/Sources/.DS_Store"; fp_same "fingerprint: .DS_Store is ignored"
mkdir -p "$P/docs"
echo '# notes' >"$P/docs/NOTES.md"; fp_same "fingerprint: docs are ignored"

# ---------- session-start.sh / stop-verify.sh ----------

P="$(new_project stop)"
LOG="$TMP/stop-verify.log"
runs() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }

stop() { # $1 extra JSON; prints "exit=<code>" then stdout+stderr
  local out code
  out="$(FAKE_VERIFY_LOG="$LOG" hook stop-verify.sh "$P" "${1:-}" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
out="$(stop)"
if [ "$(runs)" = 0 ] && [[ "$out" == exit=0* ]]; then ok "stop: no change since session start runs nothing"
else nok "stop: no change since session start runs nothing" "$out"; fi

if [ ! -e "$TMP/data/state" ] || ! find "$TMP/data/state" -name verified -o -name passed | grep -q .; then
  ok "session-start: does not mark the starting state as verified or passed"
else
  nok "session-start: does not mark the starting state as verified or passed" "$(find "$TMP/data/state" -type f)"
fi

echo 'let app = 2' >"$P/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=1 stop)"
if [[ "$out" == exit=2* ]] && grep -q 'Verification failed (attempt 1 of 3)' <<<"$out"; then ok "stop: failing check blocks Claude"
else nok "stop: failing check blocks Claude" "$out"; fi

out="$(FAKE_VERIFY_EXIT=1 stop '{"stop_hook_active":true}')"
if [[ "$out" == exit=0* ]] && grep -q 'still failing' <<<"$out" && [ "$(runs)" = 1 ]; then
  ok "stop: second stop on the same failing code warns without re-running"
else nok "stop: second stop on the same failing code warns without re-running" "$out"; fi

out="$(hook session-start.sh "$P" '{"source":"resume"}')"
if grep -qi 'failed' <<<"$out"; then ok "session-start: resume reports the last failed check on unchanged code"
else nok "session-start: resume reports the last failed check on unchanged code" "output: ${out:-<empty>}"; fi

echo 'let app = 3' >"$P/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=0 stop)"
if [[ "$out" == exit=0* ]] && [ "$(runs)" = 2 ]; then ok "stop: passing check lets Claude stop"
else nok "stop: passing check lets Claude stop" "$out"; fi

out="$(FAKE_VERIFY_EXIT=1 stop)"
if [[ "$out" == exit=0* ]] && [ "$(runs)" = 2 ]; then ok "stop: unchanged code after a pass is not re-run"
else nok "stop: unchanged code after a pass is not re-run" "$out"; fi

hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'A = 9' >"$P/Config.xcconfig"
out="$(FAKE_VERIFY_EXIT=0 stop)"
if [ "$(runs)" = 3 ]; then ok "stop: .xcconfig change triggers verification"
else nok "stop: .xcconfig change triggers verification" "$out"; fi

# ---------- post-edit.sh ----------

PEFAKES="$TMP/pe-fakes"
NOLINT="$TMP/pe-fakes-nolint"
TOOLLOG="$TMP/tools.log"
mkdir -p "$PEFAKES" "$NOLINT"
cat >"$PEFAKES/swiftformat" <<'FAKE'
#!/bin/bash
for f; do :; done
echo "swiftformat $f" >>"$FAKE_TOOL_LOG"
case "${FAKE_FMT:-ok}" in
  rewrite) echo "// formatted" >>"$f" ;;
  fail) echo "error: Unexpected token ) at 1:1" >&2; exit 70 ;;
esac
exit 0
FAKE
cat >"$PEFAKES/xcrun" <<'FAKE'
#!/bin/bash
[ "$1" = --find ] && { echo /fake/swift-format; exit 0; }
for f; do :; done
echo "swift-format $f" >>"$FAKE_TOOL_LOG"
case "${FAKE_FMT:-ok}" in
  rewrite) echo "// formatted" >>"$f" ;;
  fail) echo "error: Unexpected token ) at 1:1" >&2; exit 1 ;;
esac
exit 0
FAKE
# Modes follow SwiftLint's real behaviour: serious violations exit 2; an invalid rule
# configuration only prints a warning on stderr and exits 0; a file excluded with
# --force-exclude fails with "No lintable files found".
cat >"$PEFAKES/swiftlint" <<'FAKE'
#!/bin/bash
for f; do :; done
echo "swiftlint $f" >>"$FAKE_TOOL_LOG"
case "${FAKE_LINT:-clean}" in
  warn) echo "$f:1:5: warning: Hardcoded Padding Violation: Use Spacing tokens (ds_hardcoded_padding)" ;;
  error) echo "$f:1:5: error: Force Unwrapping Violation: Avoid force unwrapping (force_unwrapping)"; exit 2 ;;
  badregex) echo "warning: Invalid regular expression pattern '(' used to configure 'ds_hardcoded_padding' rule." >&2 ;;
  crash) echo "Fatal error: Could not read configuration" >&2; exit 1 ;;
  excluded) echo "Error: No lintable files found at paths: '$f'" >&2; exit 1 ;;
esac
exit 0
FAKE
cp "$PEFAKES/swiftformat" "$NOLINT/swiftformat"
chmod +x "$PEFAKES"/* "$NOLINT"/*

# $1 project, $2 file, $3 optional fakes dir used with a minimal system PATH instead of the
# full one. Prints "exit=<code>" then stdout+stderr.
post_edit() {
  local out code path="$PEFAKES:$PATH"
  [ -z "${3:-}" ] || path="$3:/usr/bin:/bin"
  : >"$TOOLLOG"
  out="$(jq -nc --arg cwd "$1" --arg f "$2" '{cwd: $cwd, tool_name: "Edit", tool_input: {file_path: $f}}' |
    PATH="$path" FAKE_TOOL_LOG="$TOOLLOG" CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$1" \
      "$SCRIPTS/post-edit.sh" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
set_config() { printf '%s\n' "$2" >"$1/.claude/swift-harness.json"; }

P="$(new_project post-edit)"
F="$P/Sources/App.swift"

set_config "$P" '{"format":"swiftformat","lint":"swiftlint"}'
expect_result "post-edit: formatter rewrite asks Claude to re-read the file" 0 'Re-read' "$(FAKE_FMT=rewrite post_edit "$P" "$F")"
expect_result "post-edit: formatter note shows the lines it changed" 0 'Formatter changes \(- your edit as written, \+ after formatting[^)]*\):\\n[+]// formatted' "$(FAKE_FMT=rewrite post_edit "$P" "$F")"
expect_result "post-edit: swiftformat failure is reported" 0 'swiftformat failed.*Unexpected token' "$(FAKE_FMT=fail post_edit "$P" "$F")"
expect_result "post-edit: clean lint is reported as clean" 0 'SwiftLint: no issues in Sources/App\.swift' "$(post_edit "$P" "$F")" 'swiftformat|Re-read'
expect_result "post-edit: lint warnings are reported without blocking" 0 'SwiftLint: 1 issue' "$(FAKE_LINT=warn post_edit "$P" "$F")"
expect_result "post-edit: violation lines use project-relative paths" 0 '\\nSources/App\.swift:1:5: warning' "$(FAKE_LINT=warn post_edit "$P" "$F")" '"//|\\n/'
expect_result "post-edit: SwiftLint crash is reported" 0 'SwiftLint did not run correctly' "$(FAKE_LINT=crash post_edit "$P" "$F")"
expect_result "post-edit: invalid SwiftLint rule config (exit 0) is reported" 0 'Invalid regular expression' "$(FAKE_LINT=badregex post_edit "$P" "$F")"
expect_result "post-edit: file excluded by .swiftlint.yml is not an error" 0 'excluded by \.swiftlint\.yml' "$(FAKE_LINT=excluded post_edit "$P" "$F")" 'did not run|lintable'
expect_result "post-edit: missing swiftlint stays quiet on each edit" 0 '^exit=0$' "$(SWIFT_HARNESS_EXTRA_PATH='' post_edit "$P" "$F" "$NOLINT")" 'SwiftLint'

echo 'let v = 1' >"$P/Sources/My View.swift"
expect_result "post-edit: file name with spaces is reported by its project path" 0 'issue\(s\) in Sources/My View.swift' "$(FAKE_LINT=warn post_edit "$P" "$P/Sources/My View.swift")"

set_config "$P" '{"format":"swift-format","lint":"none"}'
expect_result "post-edit: swift-format failure is reported" 0 'swift-format failed.*Unexpected token' "$(FAKE_FMT=fail post_edit "$P" "$F")"

set_config "$P" '{"format":"none","lint":"none"}'
post_edit "$P" "$F" >/dev/null
if [ ! -s "$TOOLLOG" ]; then ok "post-edit: format and lint set to none run nothing"; else nok "post-edit: format and lint set to none run nothing" "$(cat "$TOOLLOG")"; fi

set_config "$P" '{"format":"swiftformat","lint":"swiftlint","lintBlocking":true}'
expect_result "post-edit: lintBlocking blocks on lint errors" 2 'Force Unwrapping' "$(FAKE_LINT=error post_edit "$P" "$F")"
expect_result "post-edit: lintBlocking message says what to do with pre-existing errors" 2 'already there before your edit' "$(FAKE_LINT=error post_edit "$P" "$F")" 'Fix this before continuing'
expect_result "post-edit: lintBlocking on a config problem says not to change the config on its own" 2 'do not change \.swiftlint\.yml' "$(FAKE_LINT=badregex post_edit "$P" "$F")"
expect_result "post-edit: lintBlocking blocks when SwiftLint crashes" 2 'did not run correctly' "$(FAKE_LINT=crash post_edit "$P" "$F")"
expect_result "post-edit: lintBlocking blocks on invalid SwiftLint rule config" 2 'Invalid regular expression' "$(FAKE_LINT=badregex post_edit "$P" "$F")"
expect_result "post-edit: lintBlocking does not block on warnings" 0 'SwiftLint: 1 issue' "$(FAKE_LINT=warn post_edit "$P" "$F")"
expect_result "post-edit: lintBlocking does not block on an excluded file" 0 '^exit=0$' "$(FAKE_LINT=excluded post_edit "$P" "$F")" 'did not run'
expect_result "post-edit: lintBlocking also reports a formatter failure" 2 'swiftformat failed' "$(FAKE_FMT=fail FAKE_LINT=error post_edit "$P" "$F")"

mkdir -p "$TMP/outside"
echo 'let o = 1' >"$TMP/outside/Other.swift"
out="$(FAKE_FMT=rewrite FAKE_LINT=error post_edit "$P" "$TMP/outside/Other.swift")"
if [[ "$out" == exit=0* ]] && [ ! -s "$TOOLLOG" ] && [ "$(cat "$TMP/outside/Other.swift")" = 'let o = 1' ]; then
  ok "post-edit: Swift file outside the project is not formatted or linted"
else
  nok "post-edit: Swift file outside the project is not formatted or linted" "$out / tools: $(cat "$TOOLLOG")"
fi

# ---------- lintBlocking at the Stop check ----------

LOG="$TMP/lint-gate.log"
gate_stop() { # $1 project, $2 optional extra JSON
  local out code
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  out="$(jq -nc --arg cwd "$1" --argjson extra "$extra" '{cwd: $cwd, session_id: "test"} + $extra' |
    PATH="$PEFAKES:$PATH" FAKE_TOOL_LOG="$TOOLLOG" FAKE_VERIFY_LOG="$LOG" CLAUDE_PLUGIN_DATA="$TMP/data" \
      CLAUDE_PROJECT_DIR="$1" "$SCRIPTS/stop-verify.sh" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

P="$(new_project lint-gate)"
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":true,"verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "lintBlocking on"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null

echo 'let app = x!' >"$P/Sources/App.swift"
FAKE_LINT=error post_edit "$P" "$P/Sources/App.swift" >/dev/null
expect_result "stop: lintBlocking lint errors block the stop even when the build passes" 2 'Force Unwrapping' \
  "$(FAKE_LINT=error FAKE_VERIFY_EXIT=0 gate_stop "$P")"

echo 'let app = y!' >"$P/Sources/App.swift"
expect_result "stop: lintBlocking, SwiftLint broken at the stop check blocks" 2 'did not run correctly' \
  "$(FAKE_LINT=crash FAKE_VERIFY_EXIT=0 gate_stop "$P")"

echo 'let app = 4' >"$P/Sources/App.swift"
FAKE_LINT=clean post_edit "$P" "$P/Sources/App.swift" >/dev/null
expect_result "stop: lintBlocking, clean lint and passing build let Claude stop" 0 '^exit=0' "$(FAKE_LINT=clean FAKE_VERIFY_EXIT=0 gate_stop "$P")"
before="$(wc -l <"$LOG" | tr -d ' ')"
gate_stop "$P" >/dev/null
if [ "$(wc -l <"$LOG" | tr -d ' ')" = "$before" ]; then ok "stop: lintBlocking, a pass is recorded and not re-run"
else nok "stop: lintBlocking, a pass is recorded and not re-run"; fi

echo 'let app = z!' >"$P/Sources/App.swift"
FAKE_LINT=error post_edit "$P" "$P/Sources/App.swift" >/dev/null
echo 'let app = 5' >"$P/Sources/App.swift"
expect_result "stop: lintBlocking, a file fixed outside the Edit tool is re-checked and passes" 0 '^exit=0' \
  "$(FAKE_LINT=clean FAKE_VERIFY_EXIT=0 gate_stop "$P")"

P="$(new_project lint-off)"
set_config "$P" '{"format":"none","lint":"swiftlint","verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "lint report only"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = x!' >"$P/Sources/App.swift"
FAKE_LINT=error post_edit "$P" "$P/Sources/App.swift" >/dev/null
expect_result "stop: without lintBlocking, lint errors do not block the stop" 0 '^exit=0' "$(FAKE_LINT=error FAKE_VERIFY_EXIT=0 gate_stop "$P")"

# ---------- lintBlocking without SwiftLint (#17) ----------

# A machine without SwiftLint: minimal PATH and no Homebrew fallback.
nolint_stop() { # $1 project
  local out code
  out="$(jq -nc --arg cwd "$1" '{cwd: $cwd, session_id: "test"}' |
    PATH="$NOLINT:/usr/bin:/bin" SWIFT_HARNESS_EXTRA_PATH='' FAKE_VERIFY_LOG="$TMP/nolint.log" FAKE_VERIFY_EXIT=0 \
      CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$1" "$SCRIPTS/stop-verify.sh" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

P="$(new_project nolint-strict)"
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":true,"verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "lintBlocking on"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 7' >"$P/Sources/App.swift"
expect_result "stop: lintBlocking with SwiftLint missing fails even when the build passes" 2 'SwiftLint is not installed' "$(nolint_stop "$P")"
out="$(jq -nc --arg cwd "$P" '{cwd: $cwd, source: "resume"}' | PATH="$NOLINT:/usr/bin:/bin" SWIFT_HARNESS_EXTRA_PATH='' CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$P" "$SCRIPTS/session-start.sh")"
if grep -q 'end-of-turn check fails' <<<"$out"; then ok "session-start: lintBlocking without SwiftLint says the check will fail"
else nok "session-start: lintBlocking without SwiftLint says the check will fail" "${out:-<empty>}"; fi

P="$(new_project nolint-report)"
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":false,"verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "report only"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 7' >"$P/Sources/App.swift"
expect_result "stop: without lintBlocking, missing SwiftLint does not block" 0 '^exit=0' "$(nolint_stop "$P")"

P="$(new_project nolint-off)"
set_config "$P" '{"format":"none","lint":"none","lintBlocking":true,"verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "lint none"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 7' >"$P/Sources/App.swift"
expect_result "stop: lint set to none never requires SwiftLint" 0 '^exit=0' "$(nolint_stop "$P")"

# ---------- verification identity: plugin version (#18) ----------

# The same plugin with another version number, as after an update.
PLUGIN2="$TMP/plugin-next"
cp -R "$PLUGIN" "$PLUGIN2"
sed -i '' 's/"version": *"[^"]*"/"version": "99.0.0"/' "$PLUGIN2/.claude-plugin/plugin.json"
LOG="$TMP/identity.log"
id_runs() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
stop_with() { # $1 scripts dir, $2 project, $3 verify exit code
  jq -nc --arg cwd "$2" '{cwd: $cwd, session_id: "test"}' |
    FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT="$3" CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$2" "$1/stop-verify.sh" >/dev/null 2>&1
}

P="$(new_project identity)"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 40' >"$P/Sources/App.swift"
stop_with "$SCRIPTS" "$P" 0
stop_with "$SCRIPTS" "$P" 0
if [ "$(id_runs)" = 1 ]; then ok "identity: same plugin version, a pass on unchanged code is kept"
else nok "identity: same plugin version, a pass on unchanged code is kept" "runs=$(id_runs)"; fi
stop_with "$PLUGIN2/scripts" "$P" 0
if [ "$(id_runs)" = 2 ]; then ok "identity: after a plugin update, unchanged code is verified again once"
else nok "identity: after a plugin update, unchanged code is verified again once" "runs=$(id_runs)"; fi
stop_with "$PLUGIN2/scripts" "$P" 0
if [ "$(id_runs)" = 2 ]; then ok "identity: the new version's pass is then kept"
else nok "identity: the new version's pass is then kept" "runs=$(id_runs)"; fi

P="$(new_project identity-failed)"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 41' >"$P/Sources/App.swift"
stop_with "$SCRIPTS" "$P" 1
out="$(jq -nc --arg cwd "$P" '{cwd: $cwd, source: "resume"}' | CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$P" "$PLUGIN2/scripts/session-start.sh")"
if ! grep -q 'failed on the current code' <<<"$out"; then ok "identity: a failure recorded by another plugin version is not reported as current"
else nok "identity: a failure recorded by another plugin version is not reported as current" "$out"; fi
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$PLUGIN2/scripts/doctor.sh" "$P" 2>&1)"
if grep -qE '^\| INFO \| Last verification' <<<"$out"; then ok "identity: doctor does not report another version's result as current"
else nok "identity: doctor does not report another version's result as current" "$out"; fi

# ---------- verify command approval (#6) ----------

LOG="$TMP/approval.log"
appr_runs() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
appr_stop() { # $1 project, $2 optional extra JSON
  local out code
  out="$(FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=0 hook stop-verify.sh "$1" "${2:-}" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

P="$(new_project approval)"
approval "$P" --revoke >/dev/null
out="$(approval "$P" --status)"
if grep -q '^Command: scripts/verify.sh fast' <<<"$out" && grep -q 'scripts/verify.sh' <<<"$(grep '^File' <<<"$out")" &&
  grep -q '^Status: not approved' <<<"$out"; then
  ok "approval: status shows the command, the files it runs and that it is not approved"
else nok "approval: status shows the command, the files it runs and that it is not approved" "$out"; fi

out="$(hook session-start.sh "$P" '{"source":"startup"}')"
if grep -q 'not approved' <<<"$out" && grep -q '/swift-harness:approve-verify' <<<"$out"; then
  ok "approval: session start tells Claude the verify command needs approval"
else nok "approval: session start tells Claude the verify command needs approval" "${out:-<empty>}"; fi

echo 'let app = 20' >"$P/Sources/App.swift"
out="$(appr_stop "$P")"
if [[ "$out" == exit=0* ]] && [ "$(appr_runs)" = 0 ] && grep -q 'systemMessage' <<<"$out" && grep -q 'approve-verify' <<<"$out"; then
  ok "approval: a fresh project runs nothing at the stop and tells the user how to approve"
else nok "approval: a fresh project runs nothing at the stop and tells the user how to approve" "runs=$(appr_runs) $out"; fi

expect_result "approval: the warning is not repeated on the same code" 0 '^exit=0' "$(appr_stop "$P")" 'systemMessage'

out="$(approval "$P" --approve 0000)"
if [ $? -ne 0 ] && grep -qi 'changed' <<<"$out" && grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then
  ok "approval: approving a digest that was not shown is refused"
else nok "approval: approving a digest that was not shown is refused" "$out"; fi

out="$(CLAUDE_PLUGIN_DATA='' "$SCRIPTS/approve-verify.sh" --status "$P" 2>&1)"
if [ $? -ne 0 ] && grep -q 'approve-verify' <<<"$out"; then ok "approval: the script refuses to run without the plugin data folder"
else nok "approval: the script refuses to run without the plugin data folder" "$out"; fi

approve "$P" >/dev/null
out="$(appr_stop "$P")"
if [[ "$out" == exit=0* ]] && [ "$(appr_runs)" = 1 ]; then ok "approval: once approved, the stop runs the verify command"
else nok "approval: once approved, the stop runs the verify command" "runs=$(appr_runs) $out"; fi
out="$(hook session-start.sh "$P" '{"source":"resume"}')"
if ! grep -q 'not approved' <<<"$out"; then ok "approval: session start is quiet once approved"
else nok "approval: session start is quiet once approved" "$out"; fi

printf '%s\n' 'echo extra' >>"$P/scripts/verify.sh"
out="$(appr_stop "$P")"
if [ "$(appr_runs)" = 1 ] && grep -q 'approve-verify' <<<"$out"; then ok "approval: a changed verify script needs a new approval"
else nok "approval: a changed verify script needs a new approval" "runs=$(appr_runs) $out"; fi

approve "$P" >/dev/null
cp "$P/scripts/verify.sh" "$P/scripts/check.sh"
set_config "$P" '{"verify":{"command":"bash scripts/check.sh fast"}}'
out="$(appr_stop "$P")"
if [ "$(appr_runs)" = 1 ] && grep -q 'approve-verify' <<<"$out"; then ok "approval: a changed verify command needs a new approval"
else nok "approval: a changed verify command needs a new approval" "runs=$(appr_runs) $out"; fi
if grep -q '^File.*scripts/check.sh' <<<"$(approval "$P" --status)"; then ok "approval: a script passed to an interpreter is covered"
else nok "approval: a script passed to an interpreter is covered" "$(approval "$P" --status)"; fi
approve "$P" >/dev/null
echo 'exit 1' >>"$P/scripts/check.sh"
echo 'let app = 21' >"$P/Sources/App.swift"
out="$(appr_stop "$P")"
if [ "$(appr_runs)" = 1 ] && grep -q 'approve-verify' <<<"$out"; then ok "approval: a changed script passed to an interpreter needs a new approval"
else nok "approval: a changed script passed to an interpreter needs a new approval" "runs=$(appr_runs) $out"; fi

Q="$TMP/approval-copy"
cp -R "$P" "$Q"
approve "$P" >/dev/null
hook session-start.sh "$Q" '{"source":"startup"}' >/dev/null
echo 'let app = 22' >"$Q/Sources/App.swift"
out="$(appr_stop "$Q")"
if [ "$(appr_runs)" = 1 ] && grep -q 'approve-verify' <<<"$out"; then ok "approval: an approval for one project path does not apply to another"
else nok "approval: an approval for one project path does not apply to another" "runs=$(appr_runs) $out"; fi

approval "$P" --revoke >/dev/null
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: revoke removes the approval"
else nok "approval: revoke removes the approval" "$(approval "$P" --status)"; fi

P="$(new_project approval-lint)"
approval "$P" --revoke >/dev/null
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":true,"verify":{"command":"scripts/verify.sh fast"}}'
git -C "$P" commit -qam "lintBlocking on"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = x!' >"$P/Sources/App.swift"
FAKE_LINT=error post_edit "$P" "$P/Sources/App.swift" >/dev/null
out="$(PATH="$PEFAKES:$PATH" FAKE_TOOL_LOG="$TOOLLOG" FAKE_LINT=error appr_stop "$P")"
if [[ "$out" == exit=2* ]] && grep -q 'Force Unwrapping' <<<"$out" && grep -q 'not approved' <<<"$out" && [ "$(appr_runs)" = 1 ]; then
  ok "approval: without approval, lintBlocking still blocks on lint errors and says the build did not run"
else nok "approval: without approval, lintBlocking still blocks on lint errors and says the build did not run" "runs=$(appr_runs) $out"; fi
echo 'let app = 23' >"$P/Sources/App.swift"
out="$(PATH="$PEFAKES:$PATH" FAKE_TOOL_LOG="$TOOLLOG" FAKE_LINT=clean appr_stop "$P")"
if [[ "$out" == exit=0* ]] && grep -q 'approve-verify' <<<"$out" && [ "$(appr_runs)" = 1 ]; then
  ok "approval: without approval, a clean lint lets Claude stop with a warning"
else nok "approval: without approval, a clean lint lets Claude stop with a warning" "runs=$(appr_runs) $out"; fi
approve "$P" >/dev/null
out="$(PATH="$PEFAKES:$PATH" FAKE_TOOL_LOG="$TOOLLOG" FAKE_LINT=clean appr_stop "$P")"
if [ "$(appr_runs)" = 2 ]; then ok "approval: an unverified stop is not recorded as passed"
else nok "approval: an unverified stop is not recorded as passed" "runs=$(appr_runs) $out"; fi

# SH120-01: the command line is split on spaces, not parsed as shell. A quoted path with a
# space was not covered, and the approval looked complete.
P="$(new_project approval-quoted)"
printf '#!/bin/bash\necho run >>"${FAKE_VERIFY_LOG:-/dev/null}"\n' >"$P/scripts/my verify.sh"
chmod +x "$P/scripts/my verify.sh"
set_config "$P" '{"verify":{"command":"bash \"scripts/my verify.sh\" fast"}}'
git -C "$P" add -A && git -C "$P" commit -qm quoted
out="$(approval "$P" --status)"
if grep -q '^Warning:.*quotes or shell syntax.*verify\.inputs' <<<"$out"; then ok "approval: a command with quotes says its files may not be covered"
else nok "approval: a command with quotes says its files may not be covered" "$out"; fi
if ! grep -q '^Warning' <<<"$(approval "$(new_project approval-plain)" --status)"; then ok "approval: a plain command has no warning"
else nok "approval: a plain command has no warning" "$(approval "$TMP/approval-plain" --status)"; fi

set_config "$P" '{"verify":{"command":"bash \"scripts/my verify.sh\" fast","inputs":["scripts/my verify.sh"]}}'
out="$(approval "$P" --status)"
if grep -q '^Input: scripts/my verify.sh (sha256 [0-9a-f]*)' <<<"$out"; then ok "approval: verify.inputs files are listed with their hash"
else nok "approval: verify.inputs files are listed with their hash" "$out"; fi
approve "$P" >/dev/null
echo 'echo changed' >>"$P/scripts/my verify.sh"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: a changed file in verify.inputs needs a new approval"
else nok "approval: a changed file in verify.inputs needs a new approval" "$(approval "$P" --status)"; fi

set_config "$P" '{"verify":{"command":"bash \"scripts/my verify.sh\" fast","inputs":["scripts"]}}'
approve "$P" >/dev/null
echo 'echo helper' >"$P/scripts/helper.sh"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: a new file in a verify.inputs folder needs a new approval"
else nok "approval: a new file in a verify.inputs folder needs a new approval" "$(approval "$P" --status)"; fi

set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts/later.sh"]}}'
out="$(approval "$P" --status)"
if grep -q '^Input: scripts/later.sh (missing' <<<"$out"; then ok "approval: a missing verify.inputs file is shown as missing"
else nok "approval: a missing verify.inputs file is shown as missing" "$out"; fi
approve "$P" >/dev/null
echo 'echo later' >"$P/scripts/later.sh"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: a verify.inputs file that appears needs a new approval"
else nok "approval: a verify.inputs file that appears needs a new approval" "$(approval "$P" --status)"; fi
set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":["../outside.sh"]}}'
if grep -q '^Input: \.\./outside.sh (outside the project' <<<"$(approval "$P" --status)"; then ok "approval: a verify.inputs path outside the project is shown as outside"
else nok "approval: a verify.inputs path outside the project is shown as outside" "$(approval "$P" --status)"; fi

# ---------- doctor.sh (#12) ----------

doctor() { # $1 project; prints "exit=<code>" then the report
  local out code
  out="$(PATH="$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
# $1 test name, $2 report, $3 status, $4 check name, $5 optional regex on the detail
expect_row() {
  if grep -qE -- "^\| $3 \| $4 \|.*${5:-}" <<<"$2"; then ok "$1"; else nok "$1" "$2"; fi
}
# Every file and folder, with content hashes, so any change made by doctor shows.
snapshot() { (cd "$1" && find . -print | sort && find . -type f -exec shasum {} + | sort); }

P="$(new_project doctor-ok)"
cp "$TEMPLATE" "$P/scripts/verify.sh"
sed -i '' -e 's/{{XCODE_CONTAINER_FLAG}}//' -e 's/{{SCHEME}}//' -e 's|{{LOCAL_PACKAGES}}|"Packages/Core"|' -e 's/{{PLATFORMS}}/"macOS"/' -e 's/{{IOS_SIMULATOR}}//' "$P/scripts/verify.sh"
mkdir -p "$P/Packages/Core"
echo '// swift-tools-version:5.9' >"$P/Packages/Core/Package.swift"
set_config "$P" '{"format":"swiftformat","lint":"swiftlint","lintBlocking":true,"verify":{"command":"scripts/verify.sh fast","maxAttempts":3},"protectedPaths":["Sources/Audio/"],"guardPbxproj":true}'
git -C "$P" add -A && git -C "$P" commit -qm "set up"
approve "$P" >/dev/null
before="$(snapshot "$P"; snapshot "$TMP/data")"
out="$(doctor "$P")"
after="$(snapshot "$P"; snapshot "$TMP/data")"
if [[ "$out" == exit=0* ]] && ! grep -qE '^\| FAIL' <<<"$out"; then ok "doctor: a complete setup has no FAIL and exits 0"
else nok "doctor: a complete setup has no FAIL and exits 0" "$out"; fi
expect_row "doctor: shows the plugin version" "$out" PASS 'swift-harness' '[0-9]+\.[0-9]+\.[0-9]+'
expect_row "doctor: config is valid" "$out" PASS 'Config' ''
expect_row "doctor: verify script configures a package" "$out" PASS 'Verify script' 'Packages/Core'
expect_row "doctor: approved verify command" "$out" PASS 'Verify approval' ''
expect_row "doctor: SwiftPM packages reported" "$out" INFO 'Project structure' 'Packages/Core'
expect_row "doctor: packages without a contract suggest one" "$out" INFO 'Architecture contracts' 'none: add docs/architecture-contracts\.json'
expect_row "doctor: no verification recorded yet" "$out" INFO 'Last verification' ''
if [ "$before" = "$after" ]; then ok "doctor: changes no file in the project or the plugin data folder"
else nok "doctor: changes no file in the project or the plugin data folder" "$(diff <(echo "$before") <(echo "$after") | head)"; fi

echo 'let app = 30' >"$P/Sources/App.swift"
FAKE_VERIFY_LOG=/dev/null FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$P" >/dev/null 2>&1
expect_row "doctor: a failed check on the current code is reported" "$(doctor "$P")" WARN 'Last verification' 'failed'

D2="$TMP/doctor-unset"
mkdir -p "$D2"
git -C "$D2" init -q
out="$(doctor "$D2")"
if [[ "$out" == exit=1* ]]; then expect_row "doctor: a project without config points to setup" "$out" FAIL 'Config' 'swift-harness:setup'
else nok "doctor: a project without config points to setup" "$out"; fi

P="$(new_project doctor-bad)"
printf '{"format": "swiftformat",' >"$P/.claude/swift-harness.json"
expect_row "doctor: invalid JSON fails" "$(doctor "$P")" FAIL 'Config' 'JSON'

set_config "$P" '{"format":"SwiftFormat","lint":"swiftlint","lintBlok":true,"verify":{"command":"scripts/verify.sh fast","maxAtempts":3},"protectedPaths":["{{PROTECTED_PATH}}","Sources/Gone/"]}'
out="$(doctor "$P")"
expect_row "doctor: unknown top-level key is reported" "$out" WARN 'Config keys' 'lintBlok'
expect_row "doctor: unknown verify key is reported" "$out" WARN 'Config keys' 'verify.maxAtempts'
expect_row "doctor: unsupported format value fails" "$out" FAIL 'Config' 'format'
expect_row "doctor: placeholder in protectedPaths is reported" "$out" WARN 'Placeholders' 'swift-harness.json'
expect_row "doctor: protected path that does not exist is reported" "$out" WARN 'Protected paths' 'Sources/Gone'

P="$(new_project doctor-verify)"
cp "$TEMPLATE" "$P/scripts/verify.sh"
out="$(doctor "$P")"
expect_row "doctor: verify.sh with placeholders fails" "$out" FAIL 'Verify script' 'placeholder'
expect_row "doctor: a changed verify script is not approved" "$out" FAIL 'Verify approval' 'approve-verify'
sed -i '' -e 's/{{XCODE_CONTAINER_FLAG}}//' -e 's/{{SCHEME}}//' -e 's/{{LOCAL_PACKAGES}}//' -e 's/{{PLATFORMS}}/"macOS"/' -e 's/{{IOS_SIMULATOR}}//' "$P/scripts/verify.sh"
expect_row "doctor: verify.sh with no scheme and no package fails" "$(doctor "$P")" FAIL 'Verify script' 'scheme'
sed -i '' -e 's|^PACKAGES=()|PACKAGES=("Packages/Missing")|' "$P/scripts/verify.sh"
expect_row "doctor: verify.sh listing a missing package fails" "$(doctor "$P")" FAIL 'Verify script' 'Packages/Missing'
chmod -x "$P/scripts/verify.sh"
expect_row "doctor: verify script that is not executable fails" "$(doctor "$P")" FAIL 'Verify script' 'executable'
set_config "$P" '{"verify":{"enabled":false}}'
expect_row "doctor: verification turned off is a warning" "$(doctor "$P")" WARN 'Verify script' 'enabled'

# Platforms (#40): read from project.pbxproj and Package.swift, compared with verify.sh.
SIMFAKES="$TMP/sim-fakes"
mkdir -p "$SIMFAKES"
cat >"$SIMFAKES/xcrun" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "simctl list devices" ] || exit 1
printf '== Devices ==\n-- iOS 18.2 --\n    iPhone 16 (1A2B3C4D-0000-0000-0000-000000000000) (Shutdown)\n    iPhone 16 Pro (2A2B3C4D-0000-0000-0000-000000000000) (Shutdown)\n'
EOF
chmod +x "$SIMFAKES/xcrun"
pdoctor() { # $1 project
  local out code
  out="$(PATH="$SIMFAKES:$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
platform_project() { # $1 name, $2 PLATFORMS body, $3 IOS_SIMULATOR; an Xcode project with scheme App
  local p
  p="$(new_project "$1")"
  sed -e 's/{{XCODE_CONTAINER_FLAG}}/-project App.xcodeproj/' -e 's/{{SCHEME}}/App/' -e 's/{{LOCAL_PACKAGES}}//' \
    -e "s/{{PLATFORMS}}/$2/" -e "s/{{IOS_SIMULATOR}}/$3/" "$TEMPLATE" >"$p/scripts/verify.sh"
  chmod +x "$p/scripts/verify.sh"
  set_config "$p" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast"}}'
  mkdir -p "$p/App.xcodeproj"
  printf '%s' "$p"
}
pbx() { # $1 project, then build setting lines
  local p="$1"
  shift
  printf '// !$*UTF8*$!\n{\n' >"$p/App.xcodeproj/project.pbxproj"
  printf '\t\t\t\t%s\n' "$@" >>"$p/App.xcodeproj/project.pbxproj"
  printf '}\n' >>"$p/App.xcodeproj/project.pbxproj"
}

P="$(platform_project plat-mac-only '"macOS"' '')"
pbx "$P" 'SDKROOT = macosx;' 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";'
out="$(pdoctor "$P")"
expect_row "doctor platforms: an iOS target that verify.sh does not build is a warning" "$out" WARN 'Platforms' 'iOS.*not built or tested.*PLATFORMS'
if grep -q '| iOS simulator |' <<<"$out"; then nok "doctor platforms: no simulator row without iOS in PLATFORMS" "$out"
else ok "doctor platforms: no simulator row without iOS in PLATFORMS"; fi

P="$(platform_project plat-multi '"macOS" "iOS"' 'iPhone 16')"
pbx "$P" 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";'
out="$(pdoctor "$P")"
expect_row "doctor platforms: every project platform checked by verify.sh passes" "$out" PASS 'Platforms' 'macOS, iOS'
expect_row "doctor platforms: an existing simulator passes" "$out" PASS 'iOS simulator' 'iPhone 16'

P="$(platform_project plat-nosim '"macOS" "iOS"' 'iPhone 99')"
pbx "$P" 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";'
expect_row "doctor platforms: a simulator that does not exist fails" "$(pdoctor "$P")" FAIL 'iOS simulator' 'iPhone 99.*simctl'

P="$(platform_project plat-emptysim '"iOS"' '')"
pbx "$P" 'SDKROOT = iphoneos;'
out="$(pdoctor "$P")"
expect_row "doctor platforms: SDKROOT iphoneos is detected as iOS" "$out" PASS 'Platforms' 'iOS'
expect_row "doctor platforms: iOS without IOS_SIMULATOR fails, since full mode cannot test" "$out" FAIL 'iOS simulator' 'IOS_SIMULATOR'

P="$(platform_project plat-unknown '"macOS" "Android"' '')"
pbx "$P" 'SDKROOT = macosx;'
expect_row "doctor platforms: an unknown platform in verify.sh fails" "$(pdoctor "$P")" FAIL 'Platforms' 'Android'

P="$(platform_project plat-vision '"macOS"' '')"
pbx "$P" 'SUPPORTED_PLATFORMS = "macosx xros xrsimulator";'
expect_row "doctor platforms: a platform verify.sh cannot check is named" "$(pdoctor "$P")" WARN 'Platforms' 'visionOS.*not supported'

P="$(platform_project plat-none '"macOS"' '')"
expect_row "doctor platforms: nothing declared is reported as such" "$(pdoctor "$P")" INFO 'Platforms' 'none declared.*verify.sh checks macOS'

# A package declaring iOS, verified by swift test only (host macOS).
P="$(new_project plat-pkg)"
sed -e 's/{{XCODE_CONTAINER_FLAG}}//' -e 's/{{SCHEME}}//' -e 's|{{LOCAL_PACKAGES}}|"Packages/Core"|' \
  -e 's/{{PLATFORMS}}/"macOS"/' -e 's/{{IOS_SIMULATOR}}//' "$TEMPLATE" >"$P/scripts/verify.sh"
chmod +x "$P/scripts/verify.sh"
set_config "$P" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast"}}'
mkdir -p "$P/Packages/Core"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(\n  name: "Core",\n  platforms: [.iOS(.v17), .macOS(.v14)],\n  targets: [.target(name: "Core")]\n)\n' >"$P/Packages/Core/Package.swift"
expect_row "doctor platforms: platforms: in a package's manifest are read" "$(pdoctor "$P")" WARN 'Platforms' 'iOS.*Packages/Core/Package\.swift'
sed -i '' 's/^PLATFORMS=.*/PLATFORMS=("macOS" "iOS")/' "$P/scripts/verify.sh"
expect_row "doctor platforms: iOS listed with packages only is partial" "$(pdoctor "$P")" WARN 'Platforms' 'no SCHEME.*iOS'

# verify.sh generated before 1.5.0 has no PLATFORMS line: it builds for macOS.
P="$(platform_project plat-old '"macOS"' '')"
sed -i '' -e '/^PLATFORMS=/d' -e '/^IOS_SIMULATOR=/d' "$P/scripts/verify.sh"
pbx "$P" 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";'
expect_row "doctor platforms: a verify.sh without PLATFORMS is read as macOS" "$(pdoctor "$P")" WARN 'Platforms' 'iOS.*not built or tested'

P="$(new_project doctor-tools)"
set_config "$P" '{"format":"swift-format","lint":"swiftlint","lintBlocking":true}'
out="$(PATH="$NOLINT:/usr/bin:/bin" SWIFT_HARNESS_EXTRA_PATH='' CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)"
expect_row "doctor: lintBlocking without SwiftLint fails" "$out" FAIL 'SwiftLint' 'brew install swiftlint'
expect_row "doctor: swift-format without .swift-format is a warning" "$out" WARN 'Formatter config' '.swift-format'
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":false}'
out="$(PATH="$NOLINT:/usr/bin:/bin" SWIFT_HARNESS_EXTRA_PATH='' CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)"
expect_row "doctor: missing SwiftLint without lintBlocking is a warning" "$out" WARN 'SwiftLint' 'brew install swiftlint'
expect_row "doctor: no package explains architecture contracts" "$out" INFO 'Architecture contracts' 'no SwiftPM package'

out="$(CLAUDE_PLUGIN_DATA='' "$SCRIPTS/doctor.sh" "$P" 2>&1)"
expect_row "doctor: without the plugin data folder, approval is unknown" "$out" WARN 'Verify approval' 'swift-harness:doctor'

D3="$TMP/doctor-nogit"
mkdir -p "$D3/.claude"
echo '{}' >"$D3/.claude/swift-harness.json"
expect_row "doctor: a folder that is not a git repository fails" "$(doctor "$D3")" FAIL 'Git' ''

# ---------- worktrees ----------

P="$(new_project wt-main)"
W="$TMP/wt-feature"
git -C "$P" worktree add -q "$W" -b feature
approve "$W" >/dev/null
LOG="$TMP/wt.log"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
hook session-start.sh "$W" '{"source":"startup"}' >/dev/null
echo 'let app = 9' >"$W/Sources/App.swift"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$W" >/dev/null 2>&1
code=$?
main_resume="$(hook session-start.sh "$P" '{"source":"resume"}')"
main_out="$(FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$P" 2>&1)"
main_code=$?
if [ "$code" = 2 ] && [ "$main_code" = 0 ] && ! grep -qi 'failed' <<<"$main_resume" && [ "$(wc -l <"$LOG" | tr -d ' ')" = 1 ]; then
  ok "worktrees: a failure in one worktree does not affect the other"
else
  nok "worktrees: a failure in one worktree does not affect the other" "worktree exit=$code main exit=$main_code resume='$main_resume' $main_out"
fi
wt_resume="$(hook session-start.sh "$W" '{"source":"resume"}')"
if grep -qi failed <<<"$wt_resume"; then ok "worktrees: each worktree keeps its own failure state"
else nok "worktrees: each worktree keeps its own failure state" "${wt_resume:-<empty>}"; fi

# ---------- lintBlocking pending files at session start ----------

P="$(new_project pending-at-start)"
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":true}'
git -C "$P" commit -qam "lintBlocking on"
echo 'let app = x!' >"$P/Sources/App.swift"
FAKE_LINT=error post_edit "$P" "$P/Sources/App.swift" >/dev/null
out="$(hook session-start.sh "$P" '{"source":"resume"}')"
if grep -q 'Sources/App.swift' <<<"$out" && grep -qi 'swiftlint' <<<"$out"; then
  ok "session-start: lintBlocking files that still fail SwiftLint are reported"
else
  nok "session-start: lintBlocking files that still fail SwiftLint are reported" "${out:-<empty>}"
fi
set_config "$P" '{"format":"none","lint":"swiftlint","lintBlocking":false}'
out="$(hook session-start.sh "$P" '{"source":"resume"}')"
if ! grep -q 'Sources/App.swift' <<<"$out"; then ok "session-start: pending files are not reported without lintBlocking"
else nok "session-start: pending files are not reported without lintBlocking" "$out"; fi

# ---------- design-system fixture assets ----------

# Every Color("name", bundle: .module) in the reference Tokens.swift must exist as
# name.colorset in the fixture, with numeric color components.
REFS="$PLUGIN/skills/design-system/references/Tokens.swift"
ASSETS="$HERE/fixtures/design-system/Sources/DesignSystem/Resources/Colors.xcassets"
missing=""
for name in $(grep -oE 'Color\("[A-Za-z]+", bundle: \.module\)' "$REFS" | sed -E 's/Color\("([A-Za-z]+)".*/\1/'); do
  set_file="$ASSETS/$name.colorset/Contents.json"
  if [ ! -f "$set_file" ]; then
    missing="$missing $name(missing)"
  elif ! jq -e '[.colors[].color.components | .red, .green, .blue, .alpha | tonumber] | length > 0' "$set_file" >/dev/null 2>&1; then
    missing="$missing $name(invalid components)"
  fi
done
if [ -z "$missing" ] && [ -n "$(grep -oE 'Color\("[A-Za-z]+", bundle' "$REFS")" ]; then
  ok "fixture: every color referenced by Tokens.swift exists with numeric components"
else
  nok "fixture: every color referenced by Tokens.swift exists with numeric components" "$missing"
fi
unexpected=""
for set_dir in "$ASSETS"/*.colorset; do
  set_name="$(basename "$set_dir")"
  [[ "$set_name" =~ ^[A-Za-z]+\.colorset$ ]] || unexpected="$unexpected [$set_name]"
done
if [ -z "$unexpected" ]; then ok "fixture: colorset folder names are plain semantic names"
else nok "fixture: colorset folder names are plain semantic names" "$unexpected"; fi

# ---------- swift-format configuration ----------

P="$(new_project swift-format-config)"
set_config "$P" '{"format":"swift-format","lint":"none"}'
out="$(PATH="$PEFAKES:$PATH" hook session-start.sh "$P" '{"source":"startup"}')"
if grep -q 'no .swift-format' <<<"$out"; then ok "session-start: warns when swift-format has no .swift-format file"
else nok "session-start: warns when swift-format has no .swift-format file" "${out:-<empty>}"; fi
cp "$PLUGIN/skills/setup/templates/swift-format" "$P/.swift-format" 2>/dev/null
out="$(PATH="$PEFAKES:$PATH" hook session-start.sh "$P" '{"source":"startup"}')"
if [ -f "$P/.swift-format" ] && ! grep -q '.swift-format' <<<"$out"; then ok "session-start: no warning when .swift-format exists"
else nok "session-start: no warning when .swift-format exists" "${out:-<empty>}"; fi
set_config "$P" '{"format":"swiftformat","lint":"none"}'
rm -f "$P/.swift-format"
out="$(PATH="$PEFAKES:$PATH" hook session-start.sh "$P" '{"source":"startup"}')"
if ! grep -q '.swift-format' <<<"$out"; then ok "session-start: no swift-format warning when swiftformat is used"
else nok "session-start: no swift-format warning when swiftformat is used" "$out"; fi
if jq -e '.indentation.spaces == 4 and .lineLength == 160' "$PLUGIN/skills/setup/templates/swift-format" >/dev/null 2>&1; then
  ok "setup: swift-format template uses 4 spaces and 160 columns like the swiftformat template"
else
  nok "setup: swift-format template uses 4 spaces and 160 columns like the swiftformat template"
fi

P="$(new_project doctor-inputs)"
set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":"scripts"}}'
expect_row "doctor: verify.inputs that is not a list fails" "$(doctor "$P")" FAIL 'Config' 'verify\.inputs must be a list'
set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts"]}}'
expect_row "doctor: verify.inputs is a known key" "$(doctor "$P")" PASS 'Config keys' 'all known'

# ---------- skills and templates ----------

SKILLS="$PLUGIN/skills"
TEMPLATES="$PLUGIN/skills/setup/templates"
bad=""
for f in "$SKILLS"/*/SKILL.md; do
  dir="$(basename "$(dirname "$f")")"
  name="$(sed -n '2,/^---$/s/^name: *//p' "$f")"
  [ "$name" = "$dir" ] || bad="$bad $dir(name: ${name:-none})"
done
if [ -z "$bad" ]; then ok "skills: every SKILL.md is named like its folder"
else nok "skills: every SKILL.md is named like its folder" "$bad"; fi

bad=""
for f in "$SKILLS"/*/SKILL.md "$PLUGIN"/agents/*.md; do
  for ref in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$f" | sed -e 's|^\${CLAUDE_PLUGIN_ROOT}/||' -e 's|[.]$||'); do
    [ -e "$PLUGIN/$ref" ] || bad="$bad $(basename "$(dirname "$f")"):$ref"
  done
done
if [ -z "$bad" ]; then ok "skills: every \${CLAUDE_PLUGIN_ROOT} path they cite exists"
else nok "skills: every \${CLAUDE_PLUGIN_ROOT} path they cite exists" "$bad"; fi

bad=""
for f in "$TEMPLATES"/docs/*.md "$TEMPLATES"/rules/*.md; do
  rel="${f#"$TEMPLATES"/}"
  grep -qF "| \`$rel\` |" "$SKILLS/setup/SKILL.md" || bad="$bad $rel"
done
if [ -z "$bad" ]; then ok "setup: every docs and rules template is in the setup table"
else nok "setup: every docs and rules template is in the setup table" "$bad"; fi

bad=""
for doc in $(grep -oE 'docs/[A-Z_]+\.md' "$TEMPLATES/CLAUDE.md" "$TEMPLATES/docs/ARCHITECTURE.md" "$TEMPLATES"/rules/*.md | cut -d: -f2 | sort -u); do
  [ -f "$TEMPLATES/$doc" ] || bad="$bad $doc"
done
if [ -z "$bad" ]; then ok "setup: every doc linked from CLAUDE.md, ARCHITECTURE.md and rules has a template"
else nok "setup: every doc linked from CLAUDE.md, ARCHITECTURE.md and rules has a template" "$bad"; fi

PM="$SKILLS/product-map/SKILL.md"
if [ -f "$PM" ] && grep -q '^disable-model-invocation: true$' "$PM"; then ok "product-map: user-invoked only, like audit"
else nok "product-map: user-invoked only, like audit"; fi
bad=""
for section in '## Rules' '## Entities' '## Relations' '## Appearances' '## Action sets' '## User-managed collections' '## Exceptions' '## Known gaps'; do
  grep -qxF "$section" "$TEMPLATES/docs/PRODUCT_MAP.md" 2>/dev/null || bad="$bad [$section]"
done
if [ -z "$bad" ]; then ok "product-map: template has every section the skills refer to"
else nok "product-map: template has every section the skills refer to" "$bad"; fi
bad=""
for f in "$TEMPLATES/CLAUDE.md" "$TEMPLATES/rules/ui-features.md" "$SKILLS/feature/SKILL.md" "$SKILLS/ui-change/SKILL.md" "$PLUGIN/agents/ui-reviewer.md"; do
  grep -qF 'docs/PRODUCT_MAP.md' "$f" || bad="$bad ${f#"$PLUGIN"/}"
done
if [ -z "$bad" ]; then ok "product-map: CLAUDE.md, the UI rule, feature, ui-change and ui-reviewer consult the map"
else nok "product-map: CLAUDE.md, the UI rule, feature, ui-change and ui-reviewer consult the map" "$bad"; fi
bad=""
for f in "$TEMPLATES/CLAUDE.md" "$TEMPLATES/docs/ARCHITECTURE.md" "$TEMPLATES/rules/ui-features.md" "$SKILLS/ui-change/SKILL.md" "$PLUGIN/agents/ui-reviewer.md"; do
  grep -qF 'docs/LAYOUT_CONTRACT.md' "$f" || bad="$bad ${f#"$PLUGIN"/}"
done
if [ -z "$bad" ]; then ok "layout: CLAUDE.md, ARCHITECTURE.md, the UI rule, ui-change and ui-reviewer consult the contract"
else nok "layout: CLAUDE.md, ARCHITECTURE.md, the UI rule, ui-change and ui-reviewer consult the contract" "$bad"; fi
# #40: UI guidance per platform. iOS conventions are named, and the macOS-only helpers say so.
bad=""
for f in "$SKILLS/ui-change/SKILL.md" "$PLUGIN/agents/ui-reviewer.md" "$SKILLS/design-system/SKILL.md" "$TEMPLATES/rules/ui-features.md"; do
  for term in 'Dynamic Type' 'safe area' '44 pt' 'size class'; do
    grep -qiF "$term" "$f" || bad="$bad ${f#"$PLUGIN"/}:'$term'"
  done
done
if [ -z "$bad" ]; then ok "platforms: ui-change, ui-reviewer, design-system and the UI rule name the iOS conventions"
else nok "platforms: ui-change, ui-reviewer, design-system and the UI rule name the iOS conventions" "$bad"; fi
bad=""
for f in "$SKILLS/ui-change/SKILL.md" "$PLUGIN/agents/ui-reviewer.md" "$SKILLS/design-system/SKILL.md"; do
  grep -qF 'macOS only' "$f" || bad="$bad ${f#"$PLUGIN"/}"
done
if [ -z "$bad" ]; then ok "platforms: the layout, screenshot and snapshot helpers are described as macOS only"
else nok "platforms: the layout, screenshot and snapshot helpers are described as macOS only" "$bad"; fi
if grep -qF '| `tests/LayoutContract.swift` |' "$SKILLS/setup/SKILL.md"; then ok "layout: setup installs the measuring helper"
else nok "layout: setup installs the measuring helper"; fi
if [ "$(readlink "$HERE/fixtures/layout/Tests/ScreensTests/LayoutContract.swift")" = "../../../../../plugins/swift-harness/skills/setup/templates/tests/LayoutContract.swift" ] &&
  cmp -s "$HERE/fixtures/layout/Tests/ScreensTests/LayoutContract.swift" "$TEMPLATES/tests/LayoutContract.swift"; then
  ok "layout: the Swift fixture measures with the template helper itself"
else nok "layout: the Swift fixture measures with the template helper itself"; fi
if grep -qF '| `tests/Screenshot.swift` |' "$SKILLS/setup/SKILL.md"; then ok "screenshots: setup installs the capture helper"
else nok "screenshots: setup installs the capture helper"; fi
bad=""
for f in LayoutContract.swift Screenshot.swift; do
  [ "$(readlink "$HERE/fixtures/visual/Tests/ScreensTests/$f")" = "../../../../../plugins/swift-harness/skills/setup/templates/tests/$f" ] || bad="$bad $f"
done
if [ -z "$bad" ]; then ok "screenshots: the Swift fixture captures with the template helpers themselves"
else nok "screenshots: the Swift fixture captures with the template helpers themselves" "$bad"; fi
# The reviewer looks where the helper writes.
if grep -qF '.build/swift-harness/screenshots' "$TEMPLATES/tests/Screenshot.swift" &&
  grep -qF '.build/swift-harness/screenshots' "$PLUGIN/agents/ui-reviewer.md" &&
  grep -qF 'screenshots.path' "$PLUGIN/agents/ui-reviewer.md"; then
  ok "screenshots: ui-reviewer reads the folder the helper writes"
else nok "screenshots: ui-reviewer reads the folder the helper writes"; fi
# A direct call warns (deprecated since macOS 14) in projects that treat warnings as errors.
if grep -vE '^ *//' "$TEMPLATES/tests/Screenshot.swift" | grep -qE '(^|[^"])CGWindowListCreateImage\('; then
  nok "screenshots: the helper does not call the deprecated capture function directly"
else ok "screenshots: the helper does not call the deprecated capture function directly"; fi

# ---------- verify.sh template ----------

FAKES="$TMP/fakes"
mkdir -p "$FAKES"
printf '#!/bin/bash\n[ -z "${FAKE_XCODEBUILD_ARGS:-}" ] || printf "%%s\\n" "$@" >>"$FAKE_XCODEBUILD_ARGS"\nexit "${FAKE_XCODEBUILD_EXIT:-0}"\n' >"$FAKES/xcodebuild"
printf '#!/bin/bash\nexit "${FAKE_SWIFT_EXIT:-0}"\n' >"$FAKES/swift"
printf '#!/bin/bash\nexit "${FAKE_SWIFTLINT_EXIT:-0}"\n' >"$FAKES/swiftlint"
chmod +x "$FAKES/xcodebuild" "$FAKES/swift" "$FAKES/swiftlint"

# $1 name, $2 container flag, $3 scheme, $4 packages (bash array body),
# $5 platforms (bash array body, default "macOS"), $6 iOS simulator. Prints the project dir.
verify_project() {
  local p="$TMP/verify-$1"
  mkdir -p "$p/scripts"
  if [ "$2" = RAW ]; then
    cp "$TEMPLATE" "$p/scripts/verify.sh"
  else
    sed -e "s|{{XCODE_CONTAINER_FLAG}}|$2|" -e "s|{{SCHEME}}|$3|" -e "s|{{LOCAL_PACKAGES}}|$4|" \
      -e "s|{{PLATFORMS}}|${5-\"macOS\"}|" -e "s|{{IOS_SIMULATOR}}|${6:-}|" \
      "$TEMPLATE" >"$p/scripts/verify.sh"
  fi
  chmod +x "$p/scripts/verify.sh"
  printf '%s' "$p"
}

run_verify() { # $1 project, $2 mode; prints "exit=<code>" then output
  local out code
  out="$(PATH="$FAKES:/usr/bin:/bin" "$1/scripts/verify.sh" "${2:-fast}" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

expect_verify() { # $1 name, $2 expected exit (0 or nonzero), $3 regex in output, $4 output
  local code="${4%%$'\n'*}"
  code="${code#exit=}"
  if [ "$2" != 0 ] && [ "$code" != 0 ]; then
    expect_result "$1" "$code" "$3" "$4"
  else
    expect_result "$1" "$2" "$3" "$4"
  fi
}

V="$(verify_project scheme-only '-project App.xcodeproj' App '')"
expect_verify "verify.sh: Xcode project without local packages builds and passes" 0 'verify fast: PASS' "$(run_verify "$V")"

V="$(verify_project nothing '' '' '')"
expect_verify "verify.sh: no scheme and no package is NOT CONFIGURED, not PASS" 1 'NOT CONFIGURED' "$(run_verify "$V")"

V="$(verify_project missing-pkg '' '' '"Packages/Missing"')"
expect_verify "verify.sh: a listed package that does not exist fails" 1 'Packages/Missing' "$(run_verify "$V")"

V="$(verify_project pkg '' '' '"Packages/Core"')"
mkdir -p "$V/Packages/Core"
expect_verify "verify.sh: existing package with passing tests passes" 0 'verify fast: PASS' "$(run_verify "$V")"

V="$(verify_project build-fails '-project App.xcodeproj' App '')"
expect_verify "verify.sh: failing build fails" 1 'verify fast: FAIL' "$(FAKE_XCODEBUILD_EXIT=65 run_verify "$V")"

# SH120-05: a project name with spaces must reach xcodebuild as one argument.
V="$(verify_project spaced '-project My App.xcodeproj' App '')"
: >"$TMP/xcodebuild-args"
FAKE_XCODEBUILD_ARGS="$TMP/xcodebuild-args" run_verify "$V" full >/dev/null
if grep -qx 'My App.xcodeproj' "$TMP/xcodebuild-args" && grep -qx -- '-project' "$TMP/xcodebuild-args"; then
  ok "verify.sh: a project path with spaces is passed as one argument"
else nok "verify.sh: a project path with spaces is passed as one argument" "$(cat "$TMP/xcodebuild-args")"; fi
V="$(verify_project workspace '-workspace App.xcworkspace' App '')"
: >"$TMP/xcodebuild-args"
FAKE_XCODEBUILD_ARGS="$TMP/xcodebuild-args" run_verify "$V" >/dev/null
if [ "$(head -2 "$TMP/xcodebuild-args" | paste -sd' ' -)" = "-workspace App.xcworkspace" ]; then ok "verify.sh: the container flag and path come first"
else nok "verify.sh: the container flag and path come first" "$(cat "$TMP/xcodebuild-args")"; fi

V="$(verify_project bad-mode '-project App.xcodeproj' App '')"
expect_verify "verify.sh: unknown mode is rejected" 1 'fsat' "$(run_verify "$V" fsat)"

V="$(verify_project raw RAW '' '')"
expect_verify "verify.sh: unfilled template placeholders are reported" 1 'placeholder' "$(run_verify "$V")"

V="$(verify_project full-lint-only '' '' '')"
expect_verify "verify.sh full: SwiftLint alone is not a verification" 1 'NOT CONFIGURED' "$(run_verify "$V" full)"

V="$(verify_project full-scheme '-project App.xcodeproj' App '')"
expect_verify "verify.sh full: tests plus lint pass" 0 'verify full: PASS' "$(run_verify "$V" full)"
expect_verify "verify.sh full: failing lint fails" 1 'verify full: FAIL' "$(FAKE_SWIFTLINT_EXIT=2 run_verify "$V" full)"

# ---------- verify.sh platforms (#40) ----------

dest_args() { # $1 project, $2 mode; prints the -destination values, one per line
  : >"$TMP/xcodebuild-args"
  FAKE_XCODEBUILD_ARGS="$TMP/xcodebuild-args" run_verify "$1" "$2" >/dev/null
  grep -A1 -x -- '-destination' "$TMP/xcodebuild-args" | grep -vx -- '-destination' | grep -vx -- '--'
}

V="$(verify_project mac-only '-project App.xcodeproj' App '')"
if [ "$(dest_args "$V" fast)" = 'platform=macOS' ]; then ok "verify.sh platforms: macOS builds with the macOS destination"
else nok "verify.sh platforms: macOS builds with the macOS destination" "$(cat "$TMP/xcodebuild-args")"; fi
expect_verify "verify.sh platforms: the result names the platforms checked" 0 'verify fast: PASS \(.*platforms: macOS\)' "$(run_verify "$V")"

V="$(verify_project multi '-project App.xcodeproj' App '' '"macOS" "iOS"' 'iPhone 16')"
if [ "$(dest_args "$V" fast | paste -sd'|' -)" = 'platform=macOS|generic/platform=iOS Simulator' ]; then
  ok "verify.sh platforms: fast builds iOS for any simulator, without booting one"
else nok "verify.sh platforms: fast builds iOS for any simulator, without booting one" "$(cat "$TMP/xcodebuild-args")"; fi
if [ "$(dest_args "$V" full | paste -sd'|' -)" = 'platform=macOS|platform=iOS Simulator,name=iPhone 16' ]; then
  ok "verify.sh platforms: full tests iOS on the named simulator"
else nok "verify.sh platforms: full tests iOS on the named simulator" "$(cat "$TMP/xcodebuild-args")"; fi
out="$(run_verify "$V")"
expect_verify "verify.sh platforms: a multiplatform pass names both platforms" 0 'verify fast: PASS \(2 build/test check\(s\); platforms: macOS, iOS\)' "$out"
expect_verify "verify.sh platforms: each build step names its platform" 0 'xcodebuild build \(App, iOS\)' "$out"

# The fake fails only for iOS destinations.
printf '#!/bin/bash\ncase "$*" in *iOS*) exit 65 ;; esac\nexit 0\n' >"$TMP/xcodebuild-ios-fails"
chmod +x "$TMP/xcodebuild-ios-fails"
mkdir -p "$TMP/fakes-ios-fails"
cp "$FAKES/swift" "$FAKES/swiftlint" "$TMP/fakes-ios-fails/"
cp "$TMP/xcodebuild-ios-fails" "$TMP/fakes-ios-fails/xcodebuild"
out="$(PATH="$TMP/fakes-ios-fails:/usr/bin:/bin" "$V/scripts/verify.sh" fast 2>&1; printf '\nexit=%s' $?)"
if grep -q 'verify fast: FAIL' <<<"$out" && grep -q 'exit=1' <<<"$out" && grep -q 'failed on: iOS' <<<"$out"; then
  ok "verify.sh platforms: a build failing only on iOS fails and names iOS"
else nok "verify.sh platforms: a build failing only on iOS fails and names iOS" "$out"; fi

V="$(verify_project pkg-ios '' '' '"Packages/Core"' '"macOS" "iOS"' 'iPhone 16')"
mkdir -p "$V/Packages/Core"
out="$(run_verify "$V")"
expect_verify "verify.sh platforms: packages only, iOS listed, is PARTIAL and never PASS" 0 'verify fast: PARTIAL \(passed on macOS; not checked on iOS' "$out" 'verify fast: PASS'

V="$(verify_project bad-platform '-project App.xcodeproj' App '' '"macOS" "Android"')"
expect_verify "verify.sh platforms: an unknown platform is NOT CONFIGURED" 1 'NOT CONFIGURED.*Android' "$(run_verify "$V")"

V="$(verify_project no-platform '-project App.xcodeproj' App '' '')"
expect_verify "verify.sh platforms: a scheme with no platform is NOT CONFIGURED" 1 'NOT CONFIGURED.*PLATFORMS' "$(run_verify "$V")"

V="$(verify_project ios-no-sim '-project App.xcodeproj' App '' '"iOS"' '')"
expect_verify "verify.sh platforms: iOS builds in fast mode without a simulator name" 0 'verify fast: PASS' "$(run_verify "$V")"
expect_verify "verify.sh platforms: iOS tests in full mode need IOS_SIMULATOR" 1 'NOT CONFIGURED.*IOS_SIMULATOR' "$(run_verify "$V" full)"

# ---------- porting scan (#47) ----------

PORT="$TMP/porting"
cp -R "$HERE/fixtures/porting" "$PORT"
git -C "$PORT" init -q
pbefore="$(snapshot "$PORT")"
pscan="$("$SCRIPTS/porting.sh" scan "$PORT" 2>&1)"
psum="$("$SCRIPTS/porting.sh" summary "$PORT" 2>&1)"
expect_result "porting: a shared package importing AppKit blocks iOS, with file and line" 0 'blocks	Packages/Shared › Sources/Shared	Packages/Shared/Sources/Shared/Clipboard\.swift:2	import AppKit' "exit=0
$pscan"
expect_result "porting: an AppKit type is named with its line" 0 'Clipboard\.swift:6	AppKit NSPasteboard' "exit=0
$pscan"
expect_result "porting: the summary says the package does not build for iOS as is" 0 'Packages/Shared › Sources/Shared .*does not build for iOS as is.*Clipboard\.swift:2 import AppKit' "exit=0
$psum"
expect_result "porting: AppKit inside #if os(macOS) is guarded, not blocking" 0 'guarded	Packages/Guarded.*PlatformImage\.swift:3	import AppKit' "exit=0
$pscan" 'blocks	Packages/Guarded'
expect_result "porting: the UIKit branch of #else is not reported" 0 'PlatformImage' "exit=0
$pscan" 'PlatformImage\.swift:(6|7)'
expect_result "porting: hover is a UI adaptation" 0 'adapt	.*PlatformImage\.swift:13	hover' "exit=0
$pscan"
expect_result "porting: comments, strings and multiline strings are not code (review #7)" 0 'Shared' "exit=0
$pscan" 'Track\.swift|Help\.swift'
expect_result "porting: a pure Swift package has no macOS-only API" 0 'Packages/Domain › Sources/Domain \(2 source file\(s\)\): no macOS-only API' "exit=0
$psum"
expect_result "porting: macOS-only scenes in the app are found" 0 'DemoApp\.swift:8	Settings scene.*DemoApp\.swift:9	MenuBarExtra' "exit=0
$(printf '%s' "$pscan" | tr '\n' ' ')"
expect_result "porting: menu commands are an adaptation" 0 'adapt	App	App/DemoApp\.swift:7	menu bar commands' "exit=0
$pscan"
expect_result "porting: the declared platforms are listed" 0 'Platforms declared:.*- macOS \(Packages/' "exit=0
$(printf '%s' "$psum" | tr '\n' ' ')"
expect_result "porting: a C module including IOKit blocks iOS (real-app check)" 0 'blocks	Packages/Shared › Sources/CDisc	Packages/Shared/Sources/CDisc/disc\.c:2	#include <IOKit/storage/IOCDTypes\.h>' "exit=0
$pscan"
expect_result "porting: iTunesLibrary, FSEvents and the Core Audio HAL block iOS (real-app check)" 0 'Library\.swift:1	import iTunesLibrary.*Library\.swift:4	Core Audio HAL.*Library\.swift:6	FSEvents' "exit=0
$(printf '%s' "$pscan" | tr '\n' ' ')"
expect_result "porting: the summary says a static scan is not a build" 0 'Only a build for iOS proves it builds' "exit=0
$psum"
if [ "$pbefore" = "$(snapshot "$PORT")" ]; then ok "porting: the scan changes no file"
else nok "porting: the scan changes no file"; fi

# ---------- architecture contracts (#13) ----------
# Real `swift package dump-package` on tests/fixtures/contracts: it reads the manifest
# without building or fetching anything.

if ! command -v swift >/dev/null 2>&1; then
  nok "contracts: swift not found, the architecture contract tests need Xcode"
else

contracts_project() { # $1 name; a copy of the fixture, opted in, verify command approved
  local p="$TMP/$1"
  cp -R "$HERE/fixtures/contracts" "$p"
  mkdir -p "$p/.claude" "$p/scripts"
  printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3}}' >"$p/.claude/swift-harness.json"
  printf '#!/bin/bash\necho "fake verify output"\nexit "${FAKE_VERIFY_EXIT:-0}"\n' >"$p/scripts/verify.sh"
  chmod +x "$p/scripts/verify.sh"
  printf '.build/\n' >"$p/.gitignore"
  git -C "$p" init -q
  git -C "$p" config user.email test@example.com
  git -C "$p" config user.name test
  git -C "$p" add -A
  git -C "$p" commit -qm init
  approve "$p" >/dev/null
  printf '%s' "$p"
}
check_contracts() { # $1 project; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/contracts.sh" "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
# $1 project, $2 jq filter applied to the contract
edit_contract() {
  local f="$1/docs/architecture-contracts.json"
  jq "$2" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
# $1 project, $2 target, $3 dependency written as in Package.swift: add it first in the list
add_dependency() {
  sed -i '' "s|\.target(name: \"$2\", dependencies: \[|.target(name: \"$2\", dependencies: [$3, |" "$1/Package.swift"
}

C="$(contracts_project contracts-ok)"
expect_result "contracts: the fixture's graph matches its contract" 0 '^exit=0' "$(check_contracts "$C")" 'depends on'
expect_result "contracts: test targets are not checked unless listed" 0 '^exit=0' "$(check_contracts "$C")" 'AppTests'

C="$(contracts_project contracts-forbidden)"
add_dependency "$C" Domain '"DesignSystem"'
expect_result "contracts: a forbidden dependency fails, naming the target and the dependency" 1 'Package\.swift: target "Domain" depends on "DesignSystem"' "$(check_contracts "$C")"
expect_result "contracts: the failure says how a new dependency gets approved" 1 'ADR' "$(check_contracts "$C")"

C="$(contracts_project contracts-target-form)"
add_dependency "$C" Services '.target(name: "Features")'
expect_result "contracts: .target(name:) dependencies are checked" 1 'target "Services" depends on "Features"' "$(check_contracts "$C")"

C="$(contracts_project contracts-product)"
edit_contract "$C" '.packages["."].Domain = []'
expect_result "contracts: external products are named package/product" 1 'target "Domain" depends on "swift-collections/Collections"' "$(check_contracts "$C")"

C="$(contracts_project contracts-new-target)"
sed -i '' 's|        .target(name: "DesignSystem"),|        .target(name: "DesignSystem"),\
        .target(name: "Analytics", dependencies: ["Domain"]),|' "$C/Package.swift"
mkdir -p "$C/Sources/Analytics" && echo 'enum A {}' >"$C/Sources/Analytics/A.swift"
expect_result "contracts: a target missing from the contract fails" 1 'target "Analytics" is not in the contract' "$(check_contracts "$C")"

C="$(contracts_project contracts-test-listed)"
edit_contract "$C" '.packages["."].AppTests = ["App"]'
expect_result "contracts: a listed test target is checked" 1 'target "AppTests" depends on "Domain"' "$(check_contracts "$C")"

C="$(contracts_project contracts-stale)"
edit_contract "$C" '.packages["."].Legacy = []'
expect_result "contracts: a contract entry with no target is reported, not failed" 0 'Legacy.*no such target' "$(check_contracts "$C")"

C="$(contracts_project contracts-bad-json)"
printf '{"version": 1, "packages": {' >"$C/docs/architecture-contracts.json"
expect_result "contracts: invalid JSON fails clearly" 1 'not valid JSON' "$(check_contracts "$C")"
printf '{"version": 2, "packages": {}}' >"$C/docs/architecture-contracts.json"
expect_result "contracts: an unknown version fails" 1 'version' "$(check_contracts "$C")"
printf '{"version": 1, "packages": {".": {"App": "Features"}}}' >"$C/docs/architecture-contracts.json"
expect_result "contracts: a dependency list that is not a list of names fails" 1 'list of names' "$(check_contracts "$C")"
printf '{"version": 1, "packages": {"Packages/Missing": {}}}' >"$C/docs/architecture-contracts.json"
expect_result "contracts: a package folder without Package.swift fails" 1 'Packages/Missing.*no Package\.swift' "$(check_contracts "$C")"

C="$(contracts_project contracts-broken-manifest)"
printf 'this is not swift\n' >>"$C/Package.swift"
expect_result "contracts: a manifest that does not load fails with the error" 1 'could not read Package\.swift' "$(check_contracts "$C")"

C="$(contracts_project contracts-subfolder)"
mkdir -p "$C/Packages/Core"
mv "$C/Package.swift" "$C/Sources" "$C/Tests" "$C/Packages/Core/"
edit_contract "$C" '.packages = {"Packages/Core": .packages["."]}'
add_dependency "$C/Packages/Core" Domain '"Services"'
expect_result "contracts: a package in a subfolder is named by its path" 1 'Packages/Core/Package\.swift: target "Domain" depends on "Services"' "$(check_contracts "$C")"

C="$(contracts_project contracts-none)"
rm "$C/docs/architecture-contracts.json"
expect_result "contracts: no contract file means nothing to check" 0 '^exit=0$' "$(check_contracts "$C")"

# --- in the hooks ---

cstop() { # $1 project; prints "exit=<code>" then stdout+stderr
  local out code
  out="$(hook stop-verify.sh "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

C="$(contracts_project contracts-stop)"
hook session-start.sh "$C" '{"source":"startup"}' >/dev/null
add_dependency "$C" Domain '"DesignSystem"'
out="$(cstop "$C")"
expect_result "stop: a forbidden dependency blocks the turn, with verify passing" 2 'target "Domain" depends on "DesignSystem"' "$out"
expect_result "stop: the contracts are named in the failure header" 2 'scripts/verify\.sh fast \+ architecture contracts' "$out"
git -C "$C" checkout -q Package.swift
echo '// changed' >>"$C/Sources/Domain/Domain.swift"
expect_result "stop: an allowed change passes" 0 '^exit=0' "$(cstop "$C")" 'depends on'
edit_contract "$C" '.packages["."].App = ["Features"]'
expect_result "stop: a contract change alone is checked again" 2 'target "App" depends on "DesignSystem"' "$(cstop "$C")"

C="$(contracts_project contracts-stop-unapproved)"
hook session-start.sh "$C" '{"source":"startup"}' >/dev/null
echo '# changed after approval' >>"$C/scripts/verify.sh"
add_dependency "$C" Domain '"DesignSystem"'
expect_result "stop: without the verify approval the manifest is not run" 0 '^exit=0' "$(cstop "$C")" 'depends on'

C="$(contracts_project contracts-post-edit)"
add_dependency "$C" Domain '"DesignSystem"'
expect_result "post-edit: a forbidden dependency in Package.swift is reported at once" 2 'target "Domain" depends on "DesignSystem"' "$(post_edit "$C" "$C/Package.swift")"
expect_result "post-edit: other Swift files do not run the contract check" 0 '^exit=0' "$(post_edit "$C" "$C/Sources/Domain/Domain.swift")" 'depends on'
git -C "$C" checkout -q Package.swift
expect_result "post-edit: an allowed Package.swift passes" 0 '^exit=0' "$(post_edit "$C" "$C/Package.swift")" 'depends on|contract'
add_dependency "$C" Domain '"DesignSystem"'
echo '# changed after approval' >>"$C/scripts/verify.sh"
expect_result "post-edit: without the verify approval the manifest is not run" 0 '^exit=0' "$(post_edit "$C" "$C/Package.swift")" 'depends on'

C="$(contracts_project contracts-doctor)"
out="$(doctor "$C")"
expect_row "doctor: a valid contract with the approved command is checked" "$out" PASS 'Architecture contracts' '1 package\(s\), 5 target\(s\)'
if [ ! -e "$C/.build" ]; then ok "doctor: does not run the manifest"; else nok "doctor: does not run the manifest" "$(ls -a "$C/.build")"; fi
echo '# changed after approval' >>"$C/scripts/verify.sh"
expect_row "doctor: a contract without the approval is not checked" "$(doctor "$C")" WARN 'Architecture contracts' 'not checked'
printf '{"version": 1, "packages": {"Packages/Missing": {}}}' >"$C/docs/architecture-contracts.json"
expect_row "doctor: a contract package folder that does not exist fails" "$(doctor "$C")" FAIL 'Architecture contracts' 'Packages/Missing'
printf '{"version": 1' >"$C/docs/architecture-contracts.json"
expect_row "doctor: an invalid contract fails" "$(doctor "$C")" FAIL 'Architecture contracts' 'not valid JSON'

cwatch() { # $1 project
  local out code
  out="$(hook contract-watch.sh "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
C="$(contracts_project contracts-watch)"
hook session-start.sh "$C" '{"source":"startup"}' >/dev/null
expect_result "contract-watch: an unchanged contract says nothing" 0 '^exit=0$' "$(cwatch "$C")"
edit_contract "$C" '.packages["."].Domain += ["Services"]'
expect_result "contract-watch: a new allowed dependency is shown to the user" 0 'systemMessage.*\+ Domain -> Services' "$(cwatch "$C")"
expect_result "contract-watch: the same change is shown once" 0 '^exit=0$' "$(cwatch "$C")"
edit_contract "$C" '.packages["."].App = ["Features"]'
expect_result "contract-watch: a removed dependency is shown too" 0 '\- App -> DesignSystem' "$(cwatch "$C")"
rm "$C/docs/architecture-contracts.json"
expect_result "contract-watch: a deleted contract is shown" 0 'deleted' "$(cwatch "$C")"
C="$(contracts_project contracts-watch-new)"
rm "$C/docs/architecture-contracts.json"
hook session-start.sh "$C" '{"source":"startup"}' >/dev/null
cp "$HERE/fixtures/contracts/docs/architecture-contracts.json" "$C/docs/"
expect_result "contract-watch: a contract created in the session is shown" 0 'created' "$(cwatch "$C")"

fi

# ---------- component registry (#7) ----------

# A design system with three registered components, an internal gallery, a private helper
# and a retired entry. Sources need not compile: nothing here builds them.
registry_project() { # $1 name
  local p
  p="$(new_project "$1")"
  mkdir -p "$p/Sources/DesignSystem" "$p/docs"
  cat >"$p/Sources/DesignSystem/PillCenter.swift" <<'EOF'
import SwiftUI

@MainActor @Observable
public final class PillCenter {
    public init() {}
}

public struct PillHost: ViewModifier {
    public func body(content: Content) -> some View { content }
}

extension View {
    public func pillHost() -> some View { modifier(PillHost()) }
}
EOF
  cat >"$p/Sources/DesignSystem/Badge.swift" <<'EOF'
import SwiftUI

public struct Badge<Label: View>: View {
    let label: Label
    public var body: some View { label }
}

private struct BadgeShape: View {
    var body: some View { EmptyView() }
}

struct Outer {
    struct Nested: View {
        var body: some View { EmptyView() }
    }
}
EOF
  cat >"$p/Sources/DesignSystem/Gallery.swift" <<'EOF'
import SwiftUI

struct ComponentGallery: View {
    var body: some View { EmptyView() }
}
EOF
  cat >"$p/docs/COMPONENT_REGISTRY.md" <<'EOF'
# Component registry

## Components

| ID | Name | Purpose | Use when | Don't use when | API entry point | File | Used by | Tests |
|---|---|---|---|---|---|---|---|---|
| UI-001 | PillCenter | Transient feedback | Confirmations | Errors that need a decision | `pills.show(.success("..."))` | `Sources/DesignSystem/PillCenter.swift` | LibraryView | previews |
| UI-002 | `pillHost` | Hosts the pills once per window | Root views | | `.pillHost()` | Sources/DesignSystem/PillCenter.swift:13 | RootView | none |
| UI-003 | Badge | A label in a capsule, `a \| b` variants | Counts | | `Badge { Text("3") }` | Sources/DesignSystem/Badge.swift | none yet | previews |

## Internal

| Name | Why not registered |
|---|---|
| ComponentGallery | Preview gallery, not used by features |

## To consolidate

| Element | Locations | Differences | Plan |
|---|---|---|---|
| PillHost modifier | PillCenter.swift | exposed only through pillHost() | keep internal |

## Retired

| ID | Replaced by | Date |
|---|---|---|
| UI-000 | PillCenter | 2026-11-01 |
EOF
  set_config "$p" '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3},"registry":{"sources":["Sources/DesignSystem"]}}'
  git -C "$p" add -A && git -C "$p" commit -qm registry
  approve "$p" >/dev/null
  printf '%s' "$p"
}
registry() { # registry.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/registry.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
REG_FILE=docs/COMPONENT_REGISTRY.md
reg_edit() { sed -i '' "$2" "$1/$REG_FILE"; }

R="$(registry_project registry-ok)"
expect_result "registry: a correct registry passes" 0 '^exit=0$' "$(registry check "$R")"
expect_result "registry: the summary counts the components" 0 '3 components' "$(registry summary "$R")"
expect_result "registry: nothing missing when every component is listed, internal or under To consolidate" 0 '^exit=0$' "$(registry missing "$R")"

R="$(registry_project registry-stale)"
reg_edit "$R" 's|`Sources/DesignSystem/PillCenter.swift`|Sources/DesignSystem/Feedback/PillCenter.swift|'
out="$(registry check "$R")"
expect_result "registry: a stale path fails, naming the entry and the path" 1 'UI-001 PillCenter: .*Sources/DesignSystem/Feedback/PillCenter\.swift does not exist' "$out"
expect_result "registry: the failure names the registry file and the line" 1 'docs/COMPONENT_REGISTRY\.md:7: UI-001' "$out"
expect_result "registry: the failure says how to fix it" 1 'same change' "$out"

R="$(registry_project registry-undeclared)"
sed -i '' 's/public struct Badge</public struct Tag</' "$R/Sources/DesignSystem/Badge.swift"
expect_result "registry: a name not declared in its file fails" 1 'UI-003 Badge: .*not declared in Sources/DesignSystem/Badge\.swift' "$(registry check "$R")"
expect_result "registry: a renamed component is reported as missing too" 0 'Tag	Sources/DesignSystem/Badge\.swift:3' "$(registry missing "$R")"

R="$(registry_project registry-duplicates)"
reg_edit "$R" 's/^| UI-003 | Badge |/| UI-002 | PillCenter |/'
out="$(registry check "$R")"
expect_result "registry: a duplicate ID fails" 1 'UI-002.* more than once' "$out"
expect_result "registry: a duplicate name fails" 1 'PillCenter.* more than once' "$out"

R="$(registry_project registry-retired)"
reg_edit "$R" 's/^| UI-000 |/| UI-003 |/'
expect_result "registry: a retired ID still listed fails" 1 'UI-003.*Retired' "$(registry check "$R")"

R="$(registry_project registry-columns)"
awk 'BEGIN{FS=OFS="|"} /^\| (ID|---|UI-)/ {gsub(/\\\|/, "\001"); $0=$0; t=$3; $3=$8; $8=t; gsub("\001", "\\|")} {print}' "$R/$REG_FILE" >"$R/reg.tmp" && mv "$R/reg.tmp" "$R/$REG_FILE"
expect_result "registry: columns are found by their header, in any order" 0 '^exit=0$' "$(registry check "$R")"

R="$(registry_project registry-template)"
cp "$PLUGIN/skills/setup/templates/docs/COMPONENT_REGISTRY.md" "$R/$REG_FILE"
expect_result "registry: the setup template's empty row passes" 0 '^exit=0$' "$(registry check "$R")"
expect_result "registry: with the empty template, components in sources are missing" 0 'Badge	Sources/DesignSystem/Badge\.swift:3' "$(registry missing "$R")"

R="$(registry_project registry-format)"
printf '# Components\n\n- PillCenter: the pill\n' >"$R/$REG_FILE"
expect_result "registry: a registry without a Name and File table is not checked, and says why" 3 'Name and File' "$(registry check "$R")"

R="$(registry_project registry-none)"
rm "$R/$REG_FILE"
expect_result "registry: no registry file means nothing to check" 0 '^exit=0$' "$(registry check "$R")"

R="$(registry_project registry-missing)"
cat >"$R/Sources/DesignSystem/Toast.swift" <<'EOF'
import SwiftUI

public struct Toast: View {
    public var body: some View { EmptyView() }
}

public struct ToastButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

fileprivate struct ToastShadow: ViewModifier {
    func body(content: Content) -> some View { content }
}

public final class ToastQueue {}

struct ToastStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { .zero }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

struct ToastEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ToastBlurView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView() }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

struct ToastPicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
EOF
out="$(registry missing "$R")"
expect_result "registry: an unlisted View in sources is missing" 0 'Toast	Sources/DesignSystem/Toast\.swift:3' "$out"
expect_result "registry: an unlisted ButtonStyle in sources is missing" 0 'ToastButtonStyle	' "$out"
expect_result "registry: an unlisted Layout in sources is missing" 0 'ToastStack	' "$out"
expect_result "registry: an unlisted AppKit representable in sources is missing" 0 'ToastEffectView	' "$out"
expect_result "registry: an unlisted UIKit view representable in sources is missing" 0 'ToastBlurView	' "$out"
expect_result "registry: an unlisted UIKit view controller representable in sources is missing" 0 'ToastPicker	' "$out"
expect_result "registry: private, nested and non-UI types are not components" 0 'Toast' "$out" 'ToastShadow|ToastQueue|BadgeShape|Nested'
expect_result "registry: missing can be limited to one file" 0 '^exit=0$' "$(registry missing "$R" "$R/Sources/DesignSystem/Badge.swift")"
expect_result "registry: a missing entry does not fail the check" 0 '^exit=0$' "$(registry check "$R")"
set_config "$R" '{"verify":{"command":"scripts/verify.sh fast"}}'
expect_result "registry: without registry.sources nothing is reported missing" 0 '^exit=0$' "$(registry missing "$R")"

R="$(registry_project registry-custom-path)"
mkdir -p "$R/design"
git -C "$R" mv "$REG_FILE" design/REGISTRY.md
sed -i '' 's|Sources/DesignSystem/Badge.swift |Sources/DesignSystem/Gone.swift |' "$R/design/REGISTRY.md"
set_config "$R" '{"registry":{"path":"design/REGISTRY.md","sources":["Sources/DesignSystem"]}}'
expect_result "registry: registry.path is read" 1 'design/REGISTRY\.md.*Gone\.swift does not exist' "$(registry check "$R")"

# --- in the hooks ---

R="$(registry_project registry-fp)"
base="$(cd "$R" && jq -nc --arg cwd "$R" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="$R" bash -c '. "$1/lib.sh"; sh_init; sh_fingerprint' _ "$SCRIPTS")"
echo '| UI-009 | X | | | | | Sources/DesignSystem/Badge.swift | | |' >>"$R/$REG_FILE"
now="$(cd "$R" && jq -nc --arg cwd "$R" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="$R" bash -c '. "$1/lib.sh"; sh_init; sh_fingerprint' _ "$SCRIPTS")"
if [ -n "$base" ] && [ "$base" != "$now" ]; then ok "fingerprint: a registry edit counts, so a fixed registry is checked again"
else nok "fingerprint: a registry edit counts, so a fixed registry is checked again" "$base / $now"; fi

rstop() { # $1 project; prints "exit=<code>" then stdout+stderr
  local out code
  out="$(FAKE_VERIFY_LOG=/dev/null FAKE_VERIFY_EXIT=0 hook stop-verify.sh "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

R="$(registry_project registry-stop)"
hook session-start.sh "$R" '{"source":"startup"}' >/dev/null
sed -i '' 's/public struct Badge</public struct Tag</' "$R/Sources/DesignSystem/Badge.swift"
out="$(rstop "$R")"
expect_result "stop: a registry error blocks the turn, with verify passing" 2 'UI-003 Badge: .*not declared' "$out"
expect_result "stop: the registry is named in the failure header" 2 'scripts/verify\.sh fast \+ component registry' "$out"
reg_edit "$R" 's/^| UI-003 | Badge |/| UI-003 | Tag |/'
expect_result "stop: a registry fix alone is checked again and passes" 0 '^exit=0' "$(rstop "$R")" 'not declared'

R="$(registry_project registry-stop-unapproved)"
hook session-start.sh "$R" '{"source":"startup"}' >/dev/null
echo '# changed' >>"$R/scripts/verify.sh"
sed -i '' 's/public struct Badge</public struct Tag</' "$R/Sources/DesignSystem/Badge.swift"
out="$(rstop "$R")"
expect_result "stop: the registry is checked without the verify approval, since it runs no project code" 2 'not declared' "$out"

R="$(registry_project registry-stop-format)"
hook session-start.sh "$R" '{"source":"startup"}' >/dev/null
printf '# Components\n\n- PillCenter\n' >"$R/$REG_FILE"
echo '// changed' >>"$R/Sources/DesignSystem/Badge.swift"
expect_result "stop: a registry that cannot be read does not block" 0 '^exit=0' "$(rstop "$R")"

R="$(registry_project registry-stop-off)"
hook session-start.sh "$R" '{"source":"startup"}' >/dev/null
set_config "$R" '{"verify":{"command":"scripts/verify.sh fast"},"registry":{"enabled":false}}'
approve "$R" >/dev/null
sed -i '' 's/public struct Badge</public struct Tag</' "$R/Sources/DesignSystem/Badge.swift"
expect_result "stop: registry.enabled false turns the check off" 0 '^exit=0' "$(rstop "$R")"

R="$(registry_project registry-post-edit)"
set_config "$R" '{"format":"none","lint":"none","registry":{"sources":["Sources/DesignSystem"]}}'
printf 'import SwiftUI\n\npublic struct Toast: View {\n    public var body: some View { EmptyView() }\n}\n' >"$R/Sources/DesignSystem/Toast.swift"
out="$(post_edit "$R" "$R/Sources/DesignSystem/Toast.swift")"
expect_result "post-edit: a new component not in the registry is pointed out" 0 'Toast.*docs/COMPONENT_REGISTRY\.md' "$out"
out="$(post_edit "$R" "$R/Sources/DesignSystem/Badge.swift")"
expect_result "post-edit: editing a registered component's file names its entry" 0 'UI-003 Badge' "$out"
expect_result "post-edit: the registry note does not block" 0 '^exit=0' "$out"
out="$(post_edit "$R" "$R/Sources/App.swift")"
expect_result "post-edit: files outside the registry and its sources get no registry note" 0 '^exit=0' "$out" 'COMPONENT_REGISTRY'

R="$(registry_project registry-doctor)"
expect_row "doctor: a correct registry passes" "$(doctor "$R")" PASS 'Component registry' '3 components'
cp "$R/Sources/DesignSystem/Gallery.swift" "$R/Sources/DesignSystem/Toast.swift"
sed -i '' 's/ComponentGallery/Toast/' "$R/Sources/DesignSystem/Toast.swift"
expect_row "doctor: a component missing from the registry warns" "$(doctor "$R")" WARN 'Component registry' 'not listed: Toast'
reg_edit "$R" 's|`Sources/DesignSystem/PillCenter.swift`|Sources/Gone.swift|'
out="$(doctor "$R")"
expect_row "doctor: a stale registry path fails" "$out" FAIL 'Component registry' 'Gone\.swift does not exist'
expect_row "doctor: registry keys are known" "$out" PASS 'Config keys' 'all known'
set_config "$R" '{"registry":{"sources":"Sources/DesignSystem","path":3}}'
out="$(doctor "$R")"
expect_row "doctor: registry.sources must be a list" "$out" FAIL 'Config' 'registry\.sources must be a list'
expect_row "doctor: registry.path must be a path" "$out" FAIL 'Config' 'registry\.path must be'
rm "$R/$REG_FILE"
set_config "$R" '{}'
expect_row "doctor: no registry is explained" "$(doctor "$R")" INFO 'Component registry' 'none'

# ---------- external audit of 1.3.0 (SH130) ----------

# SH130-01: "passed" means the verify command ran and passed. Registry or lint alone is a
# separate, weaker result, and doctor says which.
P="$(registry_project sh130-01-off)"
set_config "$P" '{"format":"none","lint":"none","verify":{"enabled":false}}'
git -C "$P" add -A && git -C "$P" commit -qm off
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$P/Sources/App.swift"
out="$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$P" 2>&1)"
expect_row "doctor: verify disabled and only the registry checked is not a passed verification" "$(doctor "$P")" WARN 'Last verification' 'build and tests were not run'
if ! grep -qE '^\| PASS \| Last verification' <<<"$(doctor "$P")"; then ok "doctor: no 'passed' claim when only the registry ran"
else nok "doctor: no 'passed' claim when only the registry ran" "$(doctor "$P")"; fi
out="$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$P" 2>&1; echo "exit=$?")"
expect_result "stop: a registry-only result on unchanged code is not re-checked" 0 'exit=0' "$out" 'Component registry'

P="$(registry_project sh130-01-unapproved)"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo '# changed' >>"$P/scripts/verify.sh"
echo 'let app = 2' >"$P/Sources/App.swift"
FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$P" >/dev/null 2>&1
expect_row "doctor: an unapproved verify command with the registry passing is not a passed verification" "$(doctor "$P")" WARN 'Last verification' 'build and tests were not run'
approve "$P" >/dev/null
LOG="$TMP/sh130-01.log"; : >"$LOG"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=0 hook stop-verify.sh "$P" >/dev/null 2>&1
if [ "$(wc -l <"$LOG" | tr -d ' ')" = 1 ]; then ok "stop: approving the command later runs it on the code checked without it"
else nok "stop: approving the command later runs it on the code checked without it" "runs=$(wc -l <"$LOG")"; fi
expect_row "doctor: verify command, contracts and registry passing is a passed verification" "$(doctor "$P")" PASS 'Last verification' 'passed on the current code'

# SH130-03: an input outside the project cannot be covered, so approval is refused.
P="$(new_project sh130-03)"
echo 'echo outside' >"$TMP/sh130-outside.sh"
set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":["../sh130-outside.sh"]}}'
git -C "$P" add -A && git -C "$P" commit -qm outside
approve_result() { local o c; o="$(approve "$1" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
out="$(approve_result "$P")"
expect_result "approval: refused while a verify.inputs path is outside the project" 1 'Nothing approved' "$out"
expect_result "approval: the refusal names the outside input" 1 'sh130-outside\.sh \(outside the project' "$out"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: nothing is stored when refused"
else nok "approval: nothing is stored when refused" "$(approval "$P" --status)"; fi

# SH130-04: links inside a watched folder are covered by their target.
P="$(new_project sh130-04)"
mkdir -p "$P/tools" "$P/elsewhere"
echo 'echo real' >"$P/elsewhere/real.sh"
ln -s ../elsewhere/real.sh "$P/tools/run.sh"
set_config "$P" '{"verify":{"command":"scripts/verify.sh fast","inputs":["tools"]}}'
git -C "$P" add -A && git -C "$P" commit -qm links
approve "$P" >/dev/null
echo 'echo changed' >"$P/elsewhere/real.sh"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: a changed link target in a verify.inputs folder needs a new approval"
else nok "approval: a changed link target in a verify.inputs folder needs a new approval" "$(approval "$P" --status)"; fi
approve "$P" >/dev/null
echo 'echo other' >"$P/elsewhere/other.sh"
ln -sf ../elsewhere/other.sh "$P/tools/run.sh"
if grep -q '^Status: not approved' <<<"$(approval "$P" --status)"; then ok "approval: a retargeted link in a verify.inputs folder needs a new approval"
else nok "approval: a retargeted link in a verify.inputs folder needs a new approval" "$(approval "$P" --status)"; fi
ln -sf "$TMP/sh130-outside.sh" "$P/tools/run.sh"
expect_result "approval: refused while a link in a verify.inputs folder points outside the project" 1 'Nothing approved' "$(approve_result "$P")"

# SH130-02: a command with quotes or shell syntax and no verify.inputs is approved with
# partial coverage, and both the status and doctor say so.
P="$(new_project sh130-02)"
printf '#!/bin/bash\necho ok\n' >"$P/scripts/my verify.sh"
set_config "$P" '{"verify":{"command":"bash \"scripts/my verify.sh\" fast"}}'
git -C "$P" add -A && git -C "$P" commit -qm partial
approve "$P" >/dev/null
expect_result "approval: a command with shell syntax is approved with partial coverage" 0 '^Status: approved, partial coverage' "exit=0
$(approval "$P" --status)"
expect_row "doctor: partial coverage is a warning" "$(doctor "$P")" WARN 'Verify approval' 'partial coverage'
set_config "$P" '{"verify":{"command":"bash \"scripts/my verify.sh\" fast","inputs":["scripts/my verify.sh"]}}'
approve "$P" >/dev/null
expect_result "approval: with verify.inputs the coverage is declared, not partial" 0 '^Status: approved$' "exit=0
$(approval "$P" --status)"

# SH130-05: doctor reads quoted package paths with spaces without running the script.
P="$(new_project sh130-05)"
mkdir -p "$P/Packages/My Package" "$P/Packages/Core"
echo '// swift-tools-version:5.9' >"$P/Packages/My Package/Package.swift"
echo '// swift-tools-version:5.9' >"$P/Packages/Core/Package.swift"
printf '#!/bin/bash\nXCODE_CONTAINER=""\nSCHEME=""\nPACKAGES=("Packages/My Package" '"'"'Packages/Core'"'"')\n' >"$P/scripts/verify.sh"
expect_row "doctor: quoted package paths with spaces are read correctly" "$(doctor "$P")" PASS 'Verify script' 'packages Packages/My Package, Packages/Core'
printf '#!/bin/bash\nXCODE_CONTAINER=""\nSCHEME=""\nPACKAGES=("$ROOT/Packages/Core")\n' >"$P/scripts/verify.sh"
expect_row "doctor: a package list it cannot read without running the script is not a failure" "$(doctor "$P")" WARN 'Verify script' 'cannot be read'

# SH130-07: component detection edge cases.
R="$(registry_project sh130-07)"
cat >"$R/Sources/DesignSystem/Edge.swift" <<'EOF'
import SwiftUI

public struct MultiLine:
    View
{
    public var body: some View { EmptyView() }
}

// struct Commented: View {}

/*
struct InBlockComment: View {}
*/

extension Badge: Equatable {}
EOF
out="$(registry missing "$R")"
expect_result "registry: a conformance on the next line is detected" 0 'MultiLine	Sources/DesignSystem/Edge\.swift:3' "$out"
expect_result "registry: declarations in comments and extensions are not components" 0 'MultiLine' "$out" 'Commented|InBlockComment|Badge'

# The ID column is optional. read with a tab IFS merges empty cells, so a registry without
# IDs had its Name read as the ID and its File as the Name.
R="$(registry_project registry-no-id)"
cat >"$R/$REG_FILE" <<'EOF'
# Component registry

## Components

| Name | File |
|---|---|
| PillCenter | Sources/DesignSystem/PillCenter.swift |
| Badge | Sources/DesignSystem/Badge.swift |
EOF
expect_result "registry: a registry without an ID column passes" 0 '^exit=0$' "$(registry check "$R")"
reg_edit "$R" 's#DesignSystem/Badge.swift#DesignSystem/Gone.swift#'
expect_result "registry: without IDs, a stale path names the component" 1 ':8: Badge: Sources/DesignSystem/Gone\.swift does not exist' "$(registry check "$R")"
expect_result "registry: without IDs, entries names the component" 0 '^PillCenter$' "$(registry entries "$R" Sources/DesignSystem/PillCenter.swift)"

# ---------- layout contract (#34) ----------

# A window screen with its content, a pane, and the tests that measure them. Sources need not
# compile: layout.sh reads them as text. The measuring itself is tested on the Swift fixture
# tests/fixtures/layout, in CI.
layout_project() { # $1 name
  local p
  p="$(new_project "$1")"
  mkdir -p "$p/Sources/App" "$p/Tests/AppTests" "$p/docs"
  cat >"$p/Sources/App/Library.swift" <<'EOF'
import SwiftUI

struct LibraryView: View {
    var body: some View { List { Text("Item") } }
}

struct LibraryWindow: View {
    var body: some View { LibraryView().frame(minWidth: 640, minHeight: 400) }
}
EOF
  cat >"$p/Sources/App/Inspector.swift" <<'EOF'
import SwiftUI

struct InspectorPane: View {
    var body: some View { Text("Details") }
}
EOF
  cat >"$p/Tests/AppTests/LayoutTests.swift" <<'EOF'
import Testing
@testable import App

@MainActor struct LayoutTests {
    @Test func library() { #expect(LayoutContract.check("LibraryView") { LibraryView() } == []) }
    @Test func window() { #expect(LayoutContract.check( "LibraryWindow") { LibraryWindow() } == []) }
    @Test func inspector() { #expect(LayoutContract.check("InspectorPane") { InspectorPane() } == []) }
}
EOF
  cat >"$p/docs/LAYOUT_CONTRACT.md" <<'EOF'
# Layout contract

## Screens

| Screen | View | File | Window | Min | Default | Max | Compact below | Compact behavior |
|---|---|---|---|---|---|---|---|---|
| Library | `LibraryView` | Sources/App/Library.swift | LibraryWindow | 640x400 | 1000x700 | - | 800 | Filters collapse into a menu |
| Inspector | InspectorPane | `Sources/App/Inspector.swift` | | 260 × 300 | - | 400pt | - | |

## Presented UI

| Element | Opened from | Kind | Size | At the minimum size |
|---|---|---|---|---|
| Sort menu | Library | popover | 220x300 | opens inside the window |
EOF
  set_config "$p" '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3}}'
  git -C "$p" add -A && git -C "$p" commit -qm layout
  approve "$p" >/dev/null
  printf '%s' "$p"
}
layout() { # layout.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/layout.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
LAY_FILE=docs/LAYOUT_CONTRACT.md
lay_edit() { sed -i '' "$2" "$1/$LAY_FILE"; }

L="$(layout_project layout-ok)"
expect_result "layout: a correct contract passes" 0 '^exit=0$' "$(layout check "$L")"
expect_result "layout: the summary counts the screens" 0 '2 screens' "$(layout summary "$L")"
expect_result "layout: entries names the screens of a file, with their sizes" 0 'Library \(LibraryView, min 640x400, compact below 800\)' "$(layout entries "$L" "$L/Sources/App/Library.swift")"
expect_result "layout: entries is empty for a file without screens" 0 '^exit=0$' "$(layout entries "$L" Sources/App/Other.swift)"

L="$(layout_project layout-stale)"
git -C "$L" mv Sources/App/Inspector.swift Sources/App/Details.swift
out="$(layout check "$L")"
expect_result "layout: a moved file fails, naming the row, the line and the path" 1 'docs/LAYOUT_CONTRACT\.md:8: Inspector \(InspectorPane\): Sources/App/Inspector\.swift does not exist' "$out"
expect_result "layout: the failure says how to fix it" 1 'same change' "$out"

L="$(layout_project layout-renamed)"
sed -i '' 's/struct LibraryView:/struct BrowserView:/' "$L/Sources/App/Library.swift"
expect_result "layout: a view not declared in its file fails" 1 'LibraryView is not declared in Sources/App/Library\.swift' "$(layout check "$L")"

L="$(layout_project layout-window-gone)"
sed -i '' 's/struct LibraryWindow:/struct MainWindow:/' "$L/Sources/App/Library.swift"
expect_result "layout: a window view declared nowhere fails" 1 'the window view LibraryWindow is not declared in any Swift file' "$(layout check "$L")"

L="$(layout_project layout-untested)"
sed -i '' '/inspector()/d; /"LibraryWindow"/d' "$L/Tests/AppTests/LayoutTests.swift"
out="$(layout check "$L")"
expect_result "layout: a view no test measures fails, naming the helper call" 1 'Inspector \(InspectorPane\): no test measures InspectorPane\. Add one that calls LayoutContract\.check\("InspectorPane"\)' "$out"
expect_result "layout: a window no test measures fails too" 1 'no test measures LibraryWindow' "$out"
echo '// LayoutContract.check("InspectorPane") is planned' >"$L/Tests/AppTests/Notes.md"
expect_result "layout: only Swift files count as tests" 1 'no test measures InspectorPane' "$(layout check "$L")"

L="$(layout_project layout-sizes)"
lay_edit "$L" 's/| 640x400 | 1000x700 | - | 800 |/| 640 by 400 | 600x700 | 500 | 600 |/'
out="$(layout check "$L")"
expect_result "layout: a Min that is not a size fails" 1 "Min '640 by 400' is not a size" "$out"
lay_edit "$L" 's/| 640 by 400 |/| 640x400 |/'
out="$(layout check "$L")"
expect_result "layout: Default below Min fails" 1 'Default width 600 is smaller than Min width 640' "$out"
expect_result "layout: Max below Min fails" 1 'Max width 500 is smaller than Min width 640' "$out"
expect_result "layout: a compact width not above Min fails" 1 'Compact below 600 is not above Min width 640' "$out"
lay_edit "$L" 's/| 260 × 300 |/| - |/'
expect_result "layout: an empty Min fails" 1 'Inspector \(InspectorPane\): Min is empty' "$(layout check "$L")"

L="$(layout_project layout-duplicate)"
lay_edit "$L" '/^| Inspector /a\
| Library again | LibraryView | Sources/App/Library.swift | | 700x400 | - | - | - | |
'
expect_result "layout: a view listed twice fails" 1 'the view LibraryView is listed more than once' "$(layout check "$L")"

L="$(layout_project layout-columns)"
awk 'BEGIN{FS=OFS="|"} /^\| (Screen|---|Library|Inspector)/ {t=$3; $3=$6; $6=t} {print}' "$L/$LAY_FILE" >"$L/l.tmp" && mv "$L/l.tmp" "$L/$LAY_FILE"
expect_result "layout: columns are found by their header, in any order" 0 '^exit=0$' "$(layout check "$L")"

L="$(layout_project layout-template)"
cp "$PLUGIN/skills/setup/templates/docs/LAYOUT_CONTRACT.md" "$L/$LAY_FILE"
expect_result "layout: the setup template's empty rows pass" 0 '^exit=0$' "$(layout check "$L")"
expect_result "layout: the setup template has no screens yet" 0 '0 screens' "$(layout summary "$L")"

L="$(layout_project layout-format)"
printf '# Layout\n\n- Library: at least 640 wide\n' >"$L/$LAY_FILE"
expect_result "layout: a contract without a Screens table is not checked, and says why" 3 'View, File and Min' "$(layout check "$L")"

L="$(layout_project layout-none)"
git -C "$L" rm -q "$LAY_FILE"
expect_result "layout: no contract means nothing to check" 0 '^exit=0$' "$(layout check "$L")"

L="$(layout_project layout-custom-path)"
mkdir -p "$L/design"
git -C "$L" mv "$LAY_FILE" design/LAYOUT.md
sed -i '' 's|Sources/App/Inspector.swift|Sources/App/Gone.swift|' "$L/design/LAYOUT.md"
set_config "$L" '{"layout":{"path":"design/LAYOUT.md"}}'
expect_result "layout: layout.path is read" 1 'design/LAYOUT\.md.*Gone\.swift does not exist' "$(layout check "$L")"

expect_result "layout: the Swift fixture's contract passes, every screen measured" 0 '^exit=0$' "$(layout check "$HERE/fixtures/layout")"

# --- in the hooks ---

L="$(layout_project layout-fp)"
base="$(cd "$L" && jq -nc --arg cwd "$L" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="$L" bash -c '. "$1/lib.sh"; sh_init; sh_fingerprint' _ "$SCRIPTS")"
lay_edit "$L" 's/| 640x400 |/| 600x400 |/'
now="$(cd "$L" && jq -nc --arg cwd "$L" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="$L" bash -c '. "$1/lib.sh"; sh_init; sh_fingerprint' _ "$SCRIPTS")"
if [ -n "$base" ] && [ "$base" != "$now" ]; then ok "fingerprint: a contract edit counts, since the layout tests read it"
else nok "fingerprint: a contract edit counts, since the layout tests read it" "$base / $now"; fi

L="$(layout_project layout-stop)"
hook session-start.sh "$L" '{"source":"startup"}' >/dev/null
sed -i '' 's/struct InspectorPane:/struct DetailsPane:/' "$L/Sources/App/Inspector.swift"
out="$(rstop "$L")"
expect_result "stop: a layout contract error blocks the turn, with verify passing" 2 'InspectorPane is not declared' "$out"
expect_result "stop: the layout contract is named in the failure header" 2 'scripts/verify\.sh fast \+ layout contract' "$out"
lay_edit "$L" 's/| InspectorPane |/| DetailsPane |/'
sed -i '' 's/"InspectorPane") { InspectorPane()/"DetailsPane") { DetailsPane()/' "$L/Tests/AppTests/LayoutTests.swift"
expect_result "stop: a contract fix is checked again and passes" 0 '^exit=0' "$(rstop "$L")" 'not declared'

L="$(layout_project layout-stop-unapproved)"
hook session-start.sh "$L" '{"source":"startup"}' >/dev/null
echo '# changed' >>"$L/scripts/verify.sh"
sed -i '' 's/struct InspectorPane:/struct DetailsPane:/' "$L/Sources/App/Inspector.swift"
expect_result "stop: the layout contract is checked without the verify approval, since it runs no project code" 2 'InspectorPane is not declared' "$(rstop "$L")"

L="$(layout_project layout-stop-format)"
hook session-start.sh "$L" '{"source":"startup"}' >/dev/null
printf '# Layout\n\n- Library: at least 640 wide\n' >"$L/$LAY_FILE"
echo '// changed' >>"$L/Sources/App/Library.swift"
expect_result "stop: a contract that cannot be read does not block" 0 '^exit=0' "$(rstop "$L")"

L="$(layout_project layout-stop-off)"
hook session-start.sh "$L" '{"source":"startup"}' >/dev/null
set_config "$L" '{"verify":{"command":"scripts/verify.sh fast"},"layout":{"enabled":false}}'
approve "$L" >/dev/null
sed -i '' 's/struct InspectorPane:/struct DetailsPane:/' "$L/Sources/App/Inspector.swift"
expect_result "stop: layout.enabled false turns the check off" 0 '^exit=0' "$(rstop "$L")"

L="$(layout_project layout-post-edit)"
set_config "$L" '{"format":"none","lint":"none"}'
out="$(post_edit "$L" "$L/Sources/App/Library.swift")"
expect_result "post-edit: editing a screen's file names its sizes" 0 'Layout contract: Sources/App/Library\.swift draws Library \(LibraryView, min 640x400, compact below 800\)' "$out"
expect_result "post-edit: a file without screens gets no layout note" 0 '^exit=0' "$(post_edit "$L" "$L/Tests/AppTests/LayoutTests.swift")" 'Layout contract'

L="$(layout_project layout-doctor)"
expect_row "doctor: a correct layout contract passes" "$(doctor "$L")" PASS 'Layout contract' '2 screens'
sed -i '' 's/struct InspectorPane:/struct DetailsPane:/' "$L/Sources/App/Inspector.swift"
expect_row "doctor: a wrong layout contract fails" "$(doctor "$L")" FAIL 'Layout contract' 'InspectorPane is not declared'
git -C "$L" rm -q "$LAY_FILE"
expect_row "doctor: no layout contract is info" "$(doctor "$L")" INFO 'Layout contract' 'none'
set_config "$L" '{"layout":{"enabled":"yes","pth":"x"}}'
out="$(doctor "$L")"
expect_row "doctor: a wrong layout value fails the config" "$out" FAIL Config 'layout.enabled must be true or false'
expect_row "doctor: an unknown layout key warns" "$out" WARN 'Config keys' 'layout.pth'

# ---------- screenshots (#35) ----------
# The capture itself runs on the Swift fixture tests/fixtures/visual, in CI. Here: the config
# key the helper reads is known to doctor.
set_config "$L" '{"screenshots":{"path":"review/shots"}}'
out="$(doctor "$L")"
expect_row "doctor: screenshots.path is a known key" "$out" PASS 'Config keys' 'all known'
set_config "$L" '{"screenshots":{"path":3,"pth":"x"}}'
out="$(doctor "$L")"
expect_row "doctor: a wrong screenshots.path fails the config" "$out" FAIL Config 'screenshots.path must be a path'
expect_row "doctor: an unknown screenshots key warns" "$out" WARN 'Config keys' 'screenshots.pth'

# ---------- snapshot baselines (#9) ----------
# The comparison itself runs on the Swift fixture tests/fixtures/visual (locally and in CI).
# Here: approving new images, the guard, the end-of-turn notice, the fingerprint and doctor.

if grep -qF '| `tests/Snapshot.swift` |' "$SKILLS/setup/SKILL.md"; then ok "snapshots: setup installs the snapshot helper"
else nok "snapshots: setup installs the snapshot helper"; fi
if [ "$(readlink "$HERE/fixtures/visual/Tests/ScreensTests/Snapshot.swift")" = "../../../../../plugins/swift-harness/skills/setup/templates/tests/Snapshot.swift" ]; then
  ok "snapshots: the Swift fixture compares with the template helper itself"
else nok "snapshots: the Swift fixture compares with the template helper itself"; fi
if grep -qx 'disable-model-invocation: true' "$SKILLS/approve-snapshots/SKILL.md"; then ok "snapshots: only the user runs approve-snapshots"
else nok "snapshots: only the user runs approve-snapshots"; fi
if grep -qF '/swift-harness:approve-snapshots' "$TEMPLATES/tests/Snapshot.swift" &&
  grep -qF '.build/swift-harness/snapshots' "$TEMPLATES/tests/Snapshot.swift" &&
  grep -qF 'SH_SNAPSHOT_CANDIDATES=".build/swift-harness/snapshots"' "$SCRIPTS/lib.sh"; then
  ok "snapshots: the helper and the approval use the same folders"
else nok "snapshots: the helper and the approval use the same folders"; fi
if jq -e '[.hooks.Stop[].hooks[].command] | any(test("snapshot-watch.sh"))' "$PLUGIN/hooks/hooks.json" >/dev/null; then
  ok "snapshots: the end-of-turn notice is a Stop hook"
else nok "snapshots: the end-of-turn notice is a Stop hook"; fi

snap() { # snapshots.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/snapshots.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
snap_digest() { CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/snapshots.sh" --status --project "$1" | sed -n 's/^Digest: //p'; }
# A new image as the test helper leaves it: $1 project, $2 name, $3 status, $4 content.
candidate() {
  local c="$1/.build/swift-harness/snapshots"
  mkdir -p "$c"
  printf '%s' "$4" >"$c/$2.png"
  printf '{"os": "%s", "scale": 2}\n' "$THIS_OS" >"$c/$2.json"
  [ "$3" = failed ] && printf 'diff' >"$c/$2.diff.png"
  printf '{"status": "%s", "reason": "%s: reason"}\n' "$3" "$2" >"$c/$2.result.json"
}
THIS_OS="$(sw_vers -productVersion | cut -d. -f1-2)"
case "$THIS_OS" in *.*) ;; *) THIS_OS="$THIS_OS.0" ;; esac

S="$(new_project snapshots)"
out="$(snap --status --project "$S")"
expect_result "snapshots: nothing waiting is said plainly" 0 'No new images wait' "$out"
candidate "$S" Pill-macos-120-light missing new-pill
candidate "$S" Card-macos-200-dark failed new-card
candidate "$S" Row-macos-200-light passed same
rm -f "$S/.build/swift-harness/snapshots/Row-macos-200-light.png"
out="$(snap --status --project "$S")"
expect_result "snapshots: status lists the missing and different images" 0 'Card-macos-200-dark: failed.*Pill-macos-120-light: missing' "$(head -1 <<<"$out")
$(tail -n +2 <<<"$out" | tr '\n' ' ')" 'Row-macos'
expect_result "snapshots: status shows the diff image" 0 'Changes in red: .*Card-macos-200-dark\.diff\.png' "$out"
expect_result "snapshots: status ends with a digest" 0 '^Digest: [0-9a-f]{64}$' "$out"
expect_result "snapshots: a wrong digest approves nothing" 1 'Nothing approved' "$(snap --approve 0000 --project "$S")"
[ ! -e "$S/snapshots" ] && ok "snapshots: nothing is written when the approval is refused" || nok "snapshots: nothing is written when the approval is refused"
d="$(snap_digest "$S")"
expect_result "snapshots: an image not waiting cannot be approved" 1 "'Gone' is not waiting" "$(snap --approve "$d" --project "$S" Gone)"
out="$(snap --approve "$d" --project "$S" Card-macos-200-dark)"
expect_result "snapshots: approving one image copies it into snapshots/" 0 'Approved: snapshots/Card-macos-200-dark\.png \(failed\)' "$out" 'Pill'
if [ "$(cat "$S/snapshots/Card-macos-200-dark.png")" = new-card ] && jq -e '.approved and .os' "$S/snapshots/Card-macos-200-dark.json" >/dev/null &&
  [ ! -e "$S/.build/swift-harness/snapshots/Card-macos-200-dark.png" ] && [ ! -e "$S/.build/swift-harness/snapshots/Card-macos-200-dark.diff.png" ] &&
  [ -e "$S/.build/swift-harness/snapshots/Pill-macos-120-light.png" ]; then
  ok "snapshots: the approved image and its metadata are copied, the rest still waits"
else nok "snapshots: the approved image and its metadata are copied, the rest still waits" "$(ls -R "$S/snapshots" "$S/.build/swift-harness/snapshots" 2>&1)"; fi
expect_result "snapshots: an old digest is refused after a partial approval" 1 'Nothing approved' "$(snap --approve "$d" --project "$S")"
expect_result "snapshots: approving needs the plugin data folder" 1 'CLAUDE_PLUGIN_DATA is not set' \
  "$(out="$(CLAUDE_PLUGIN_DATA='' "$SCRIPTS/snapshots.sh" --status --project "$S" 2>&1)"; printf 'exit=%s\n%s' $? "$out")"
set_config "$S" '{"snapshots":{"path":"../outside"}}'
expect_result "snapshots: a baselines folder outside the project is refused" 1 'inside the project' "$(snap --status --project "$S")"
set_config "$S" '{"snapshots":{"path":"Tests/Baselines"}}'
out="$(snap --approve "$(snap_digest "$S")" --project "$S")"
expect_result "snapshots: snapshots.path is where images are approved" 0 'Approved: Tests/Baselines/Pill-macos-120-light\.png' "$out"
set_config "$S" '{}'

# Guard: Edit and Write in the baselines folder ask.
expect_ask "$S" "$S/snapshots/Card-macos-200-dark.png" "guard: a snapshot baseline edit asks"
expect_no_ask "$S" "$S/snapshots-old/x.png" "guard: a folder sharing the baselines prefix does not ask"
set_config "$S" '{"snapshots":{"path":"Tests/Baselines/"}}'
expect_ask "$S" "$S/Tests/Baselines/New.png" "guard: snapshots.path is protected"
set_config "$S" '{}'

# End of turn: baselines changed without the approval are shown to the user.
git -C "$S" add -A && git -C "$S" commit -qm baselines
swatch() { # $1 project
  local out code
  out="$(hook snapshot-watch.sh "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
hook session-start.sh "$S" '{"source":"startup"}' >/dev/null
expect_result "snapshot-watch: unchanged baselines say nothing" 0 '^exit=0$' "$(swatch "$S")"
candidate "$S" Pill-macos-120-light failed newer-pill
expect_result "snapshot-watch: an approved change says nothing" 0 '^exit=0$' \
  "$(snap --approve "$(snap_digest "$S")" --project "$S" >/dev/null; swatch "$S")"
printf 'copied by hand' >"$S/snapshots/Card-macos-200-dark.png"
printf 'new' >"$S/snapshots/Extra-macos-80-light.png"
out="$(swatch "$S")"
expect_result "snapshot-watch: a baseline replaced without approval is shown" 0 'systemMessage.*without /swift-harness:approve-snapshots.*changed: snapshots/Card-macos-200-dark\.png' "$out"
expect_result "snapshot-watch: a baseline added without approval is shown" 0 'changed: snapshots/Extra-macos-80-light\.png' "$out" 'Pill-macos-120-light'
expect_result "snapshot-watch: the same change is shown once" 0 '^exit=0$' "$(swatch "$S")"
rm "$S/snapshots/Card-macos-200-dark.json"
expect_result "snapshot-watch: a deleted baseline is shown" 0 'deleted: snapshots/Card-macos-200-dark\.json' "$(swatch "$S")"
git -C "$S" checkout -q -- snapshots && rm -f "$S/snapshots/Extra-macos-80-light.png"

before="$(fingerprint "$S")"
printf 'changed' >"$S/snapshots/Card-macos-200-dark.png"
[ "$before" != "$(fingerprint "$S")" ] && ok "fingerprint: a changed baseline is a change to verify" || nok "fingerprint: a changed baseline is a change to verify"
git -C "$S" checkout -q -- snapshots

# Doctor.
expect_row "doctor: baselines made on this macOS pass" "$(doctor "$S")" PASS 'Snapshot baselines' "made on macOS $THIS_OS, compared on this Mac"
jq '.os = "13.9"' "$S/snapshots/Card-macos-200-dark.json" >"$TMP/sj" && mv "$TMP/sj" "$S/snapshots/Card-macos-200-dark.json"
expect_row "doctor: baselines from another macOS are not compared here" "$(doctor "$S")" WARN 'Snapshot baselines' 'not compared'
git -C "$S" checkout -q -- snapshots
candidate "$S" Badge-macos-80-light missing x
expect_row "doctor: new images waiting are pointed out" "$(doctor "$S")" WARN 'Snapshot baselines' '1 new image\(s\).*approve-snapshots'
rm -rf "$S/snapshots"
expect_row "doctor: no baselines is info" "$(doctor "$S")" INFO 'Snapshot baselines' 'none'
set_config "$S" '{"snapshots":{"path":"../x","pth":1}}'
out="$(doctor "$S")"
expect_row "doctor: a baselines folder outside the project fails the config" "$out" FAIL Config 'snapshots.path must be a folder inside the project'
expect_row "doctor: an unknown snapshots key warns" "$out" WARN 'Config keys' 'snapshots.pth'

# ---------- security settings (#32) ----------

sec() { CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/security.sh" "$@"; }
sec_project() { # $1 name; an app with a sandboxed entitlements file, hardened runtime and an Info.plist
  local p
  p="$(new_project "$1")"
  set_config "$p" '{"format":"none","lint":"none","verify":{"enabled":false,"maxAttempts":20}}'
  mkdir -p "$p/App"
  cat >"$p/App/App.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
EOF
  cat >"$p/App/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>App</string>
</dict>
</plist>
EOF
  printf '// !$*UTF8*$!\n{\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = App/App.entitlements;\n\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n\t\t\t\tPRODUCT_NAME = App;\n}\n' >"$p/App.xcodeproj/project.pbxproj"
  git -C "$p" add -A && git -C "$p" commit -qm "app"
  printf '%s' "$p"
}
entitle() { # $1 project, $2 plutil key, $3 value: add or change an entitlement
  plutil -replace "$2" -bool "$3" "$1/App/App.entitlements"
}

P="$(sec_project security)"
out="$(sec state --project "$P")"
expect_result "security: entitlements are read key by key" 0 'App/App\.entitlements: com\.apple\.security\.app-sandbox = true' "exit=0
$out"
expect_result "security: signing build settings are read, with how many configurations set them" 0 'project\.pbxproj: ENABLE_HARDENED_RUNTIME = YES \(2 configurations\)' "exit=0
$out" 'PRODUCT_NAME'
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "security: an unchanged state passes the end-of-turn check" 0 '^exit=0' "$(rstop "$P")" 'Security settings'

echo 'let app = 2' >"$P/Sources/App.swift"
entitle "$P" 'com\.apple\.security\.cs\.disable-library-validation' YES
out="$(rstop "$P")"
expect_result "security: a hardened runtime exception blocks the turn, naming it" 2 '\+ App/App\.entitlements: com\.apple\.security\.cs\.disable-library-validation = true' "$out"
expect_result "security: the block says only the user approves it" 2 'only they approve it.*/swift-harness:approve-security' "$out"
expect_result "security: the check runs without the verify command approval" 2 'security settings' "$out"
expect_row "doctor: changed security settings fail, with the change" "$(doctor "$P")" FAIL 'Security settings' 'disable-library-validation'

git -C "$P" checkout -q -- App/App.entitlements
plutil -remove 'com\.apple\.security\.app-sandbox' "$P/App/App.entitlements"
expect_result "security: removing the sandbox blocks the turn" 2 '\- App/App\.entitlements: com\.apple\.security\.app-sandbox = true' "$(rstop "$P")"

git -C "$P" checkout -q -- App/App.entitlements
perl -0pi -e 's/ENABLE_HARDENED_RUNTIME = YES/ENABLE_HARDENED_RUNTIME = NO/' "$P/App.xcodeproj/project.pbxproj"
expect_result "security: turning hardened runtime off in one configuration blocks the turn" 2 'ENABLE_HARDENED_RUNTIME = NO' "$(rstop "$P")"

git -C "$P" checkout -q -- App.xcodeproj/project.pbxproj
plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' "$P/App/Info.plist"
expect_result "security: an ATS exception blocks the turn" 2 'App/Info\.plist: NSAppTransportSecurity\.NSAllowsArbitraryLoads = true' "$(rstop "$P")"

out="$(sec --status --project "$P")"
expect_result "security: status lists the change and a digest" 0 'NSAllowsArbitraryLoads = true.*Digest: [0-9a-f]{64}' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
out2="$(sec --approve 0000 --project "$P" 2>&1)"
expect_result "security: a wrong digest approves nothing" 1 'Nothing approved' "exit=$?
$out2"
expect_result "security: approving needs the plugin data folder" 1 'CLAUDE_PLUGIN_DATA is not set' "exit=1
$(CLAUDE_PLUGIN_DATA='' "$SCRIPTS/security.sh" --status --project "$P" 2>&1)"
d="$(printf '%s' "$out" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$P" >/dev/null
echo 'let app = 3' >"$P/Sources/App.swift"
expect_result "security: once approved, the same settings pass" 0 '^exit=0' "$(rstop "$P")" 'Security settings'
expect_row "doctor: approved security settings pass" "$(doctor "$P")" PASS 'Security settings' 'unchanged since approval'

entitle "$P" 'com\.apple\.security\.cs\.allow-jit' YES
echo 'let app = 4' >"$P/Sources/App.swift"
set_config "$P" '{"format":"none","lint":"none","verify":{"enabled":false,"maxAttempts":20},"security":{"enabled":false}}'
out="$(rstop "$P")"
expect_result "security: turning the check off in the config is itself a change to approve (review #2)" 2 '\+ \.claude/swift-harness\.json: security\.enabled = false' "$out"
expect_result "security: the change made while turning it off is still shown" 2 'allow-jit = true' "$out"
expect_row "doctor: security turned off without approval fails" "$(doctor "$P")" FAIL 'Security settings' 'security\.enabled = false'
d="$(sec --status --project "$P" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$P" >/dev/null
echo 'let app = 5' >"$P/Sources/App.swift"
expect_result "security: once the user approved it off, the check is off" 0 '^exit=0' "$(rstop "$P")" 'Security settings'
expect_row "doctor: security turned off with approval is a warning" "$(doctor "$P")" WARN 'Security settings' 'approved turning it off'
set_config "$P" '{"security":{"enabled":"yes","x":1}}'
out="$(doctor "$P")"
expect_row "doctor: security.enabled must be a boolean" "$out" FAIL Config 'security.enabled must be true or false'
expect_row "doctor: an unknown security key warns" "$out" WARN 'Config keys' 'security.x'

# The first baseline is recorded, not approved: doctor says so and names what weakens protection.
P="$(sec_project security-unreviewed)"
entitle "$P" 'com\.apple\.security\.cs\.allow-jit' YES
git -C "$P" commit -qam "jit" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
out="$(doctor "$P")"
expect_row "security: an automatic baseline is not reviewed, and doctor says so" "$out" WARN 'Security settings' 'recorded automatically on [0-9-]+ and not reviewed by you'
expect_row "security: doctor names what already weakens protection in it" "$out" WARN 'Security settings' 'allow-jit = true'
out="$(sec --status --project "$P")"
expect_result "security: approve-security lists an unreviewed baseline in full" 0 'recorded automatically.*app-sandbox = true.*weakening protection:.*allow-jit = true' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
sec --approve "$(printf '%s' "$out" | sed -n 's/^Digest: //p')" --project "$P" >/dev/null
expect_row "security: once reviewed, the baseline passes" "$(doctor "$P")" PASS 'Security settings' 'unchanged since approval'
expect_result "security: marking the automatic baseline reviewed in a session is shown to the user" 0 'baseline was approved in this session.*marked as reviewed' "exit=0
$(hook protected-watch.sh "$P" 2>&1 | tr '\n' ' ')"

# Review #3: code signing identity and whether signing is allowed are security settings.
P="$(sec_project security-signing)"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
perl -0pi -e 's/PRODUCT_NAME = App;/PRODUCT_NAME = App;\n\t\t\t\tCODE_SIGN_IDENTITY = "-";\n\t\t\t\tCODE_SIGNING_ALLOWED = NO;/' "$P/App.xcodeproj/project.pbxproj"
out="$(rstop "$P")"
expect_result "security: ad hoc signing identity is a change (review #3)" 2 'CODE_SIGN_IDENTITY = -' "$out"
expect_result "security: signing turned off is a change (review #3)" 2 'CODE_SIGNING_ALLOWED = NO' "$out"
# Review #1: an approval made in the session, by whoever ran it, is shown to the user.
d="$(sec --status --project "$P" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$P" >/dev/null
out="$(hook protected-watch.sh "$P" 2>&1 | tr '\n' ' ')"
expect_result "security: an approval made in this session is shown to the user (review #1)" 0 'systemMessage.*baseline was approved in this session.*CODE_SIGNING_ALLOWED = NO.*did not type /swift-harness:approve-security yourself' "exit=0
$out"
expect_result "security: the approval notice is shown once" 0 '^exit=0$' "exit=$(hook protected-watch.sh "$P" >/dev/null 2>&1; echo $?)$(hook protected-watch.sh "$P" 2>&1)"

P="$(sec_project security-new)"
expect_row "doctor: before the first session, the baseline is not recorded yet" "$(doctor "$P")" INFO 'Security settings' 'no baseline yet'
mkdir -p "$P/Helper"
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>\n' >"$P/Helper/Helper.entitlements"
expect_result "security: a new entitlements file is a change too" 2 'Helper/Helper\.entitlements: com\.apple\.security\.cs\.allow-unsigned-executable-memory = true' "$(rstop "$P")"

# ---------- concurrency escape hatches (#37) ----------
# Real SwiftLint with the setup template: the rules are regexes, so test them as SwiftLint runs them.

if ! command -v swiftlint >/dev/null 2>&1; then
  printf 'skip  concurrency: swiftlint not installed, the template rules were not run\n'
else
  # Not under $TMP: with an `excluded:` list, SwiftLint 0.65 ignores the baseline in folders
  # reached through /var or /tmp (both links to /private), so test where projects live.
  L="$HERE/../.build/concurrency-test"
  rm -rf "$L"
  mkdir -p "$L/Sources"
  sed 's/{{DS_EXCLUDED_REGEX}}/DesignSystem/' "$PLUGIN/skills/setup/templates/swiftlint.yml" >"$L/.swiftlint.yml"
  cat >"$L/Sources/Old.swift" <<'EOF'
final class OldCache: @unchecked Sendable {}
EOF
  (cd "$L" && swiftlint lint --quiet --write-baseline .baseline.json >/dev/null 2>&1)
  cat >"$L/Sources/New.swift" <<'EOF'
import Foundation
@preconcurrency import Dispatch

final class Cache: @unchecked Sendable {}
final class Guarded: @unchecked Sendable {} // concurrency: every access holds lock
final class Fake: @unchecked Sendable { let note = "// concurrency: fake justification" }
final class Later: @unchecked Sendable { let label = "x" } // concurrency: guarded by a queue
nonisolated(unsafe) var counter = 0
@MainActor func update() {}
func callback() { MainActor.assumeIsolated { update() } }
// A comment about @unchecked Sendable and nonisolated(unsafe) is not code.
let text = "@preconcurrency in a string is not code"
EOF
  lint="$(cd "$L" && swiftlint lint --quiet --baseline .baseline.json 2>&1)"
  for case_ in 'New.swift:2:.*concurrency_preconcurrency' 'New.swift:4:.*concurrency_unchecked_sendable' 'New.swift:8:.*concurrency_nonisolated_unsafe' 'New.swift:10:.*concurrency_assume_isolated' 'New.swift:6:.*concurrency_unchecked_sendable'; do
    if grep -qE "$case_" <<<"$lint"; then ok "concurrency: reported: ${case_%%.\**}"; else nok "concurrency: reported: $case_" "$lint"; fi
  done
  if grep -qE 'New\.swift:(5|7|11|12):' <<<"$lint"; then nok "concurrency: a justified use (also after a string), a comment and a string are not reported" "$lint"
  else ok "concurrency: a justified use (also after a string), a comment and a string are not reported"; fi
  if grep -q 'Old\.swift' <<<"$lint"; then nok "concurrency: the baseline keeps existing uses" "$lint"
  else ok "concurrency: the baseline keeps existing uses"; fi
  if grep -qF '// concurrency: <why it is safe>' <<<"$lint"; then ok "concurrency: the message says how to justify a needed one"
  else nok "concurrency: the message says how to justify a needed one" "$lint"; fi
  rm -rf "$L"
fi
if grep -qF '// concurrency: <why it is safe>' "$PLUGIN/skills/setup/templates/rules/architecture.md"; then ok "concurrency: the architecture rule says what to try first and how to justify"
else nok "concurrency: the architecture rule says what to try first and how to justify"; fi

# ---------- protected paths changed outside Edit and Write (#11) ----------

pwatch() { # $1 project
  local out code
  out="$(hook protected-watch.sh "$1" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
P="$(new_project protected-watch)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "protected-watch: nothing changed says nothing" 0 '^exit=0$' "$(pwatch "$P")"
echo 'let tool = 2' >"$P/Sources/AudioTools/Tool.swift"
expect_result "protected-watch: a change outside the protected paths says nothing" 0 '^exit=0$' "$(pwatch "$P")"
echo 'let engine = 2' >>"$P/Sources/Audio/Engine.swift"
out="$(pwatch "$P")"
expect_result "protected-watch: a protected file changed by a shell command is shown to the user" 0 'systemMessage.*without going through Edit or Write.*changed: Sources/Audio/Engine\.swift' "$out"
expect_result "protected-watch: it never blocks" 0 '^exit=0' "$out"
expect_result "protected-watch: the same change is shown once" 0 '^exit=0$' "$(pwatch "$P")"
echo 'let mixer = 1' >"$P/Sources/Audio/Mixer.swift"
rm "$P/Sources/Audio/Engine.swift"
out="$(pwatch "$P")"
expect_result "protected-watch: a new file in a protected folder is shown" 0 'changed: Sources/Audio/Mixer\.swift' "$out"
expect_result "protected-watch: a deleted protected file is shown" 0 'deleted: Sources/Audio/Engine\.swift' "$out"

P="$(new_project protected-edit)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let engine = 3' >"$P/Sources/Audio/Engine.swift"
post_edit "$P" "$P/Sources/Audio/Engine.swift" >/dev/null
expect_result "protected-watch: an edit through the guarded tools is not reported" 0 '^exit=0$' "$(pwatch "$P")"
echo '// later, by sed' >>"$P/Sources/Audio/Engine.swift"
expect_result "protected-watch: a shell change after a guarded edit is reported" 0 'changed: Sources/Audio/Engine\.swift' "$(pwatch "$P")"
printf '<plist/>\n' >"$P/Info.plist"
set_config "$P" '{"protectedPaths":["Info.plist"]}'
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
printf '<plist version="1.0"/>\n' >"$P/Info.plist"
post_edit "$P" "$P/Info.plist" >/dev/null
expect_result "protected-watch: a guarded edit of a non-Swift protected file is not reported" 0 '^exit=0$' "$(pwatch "$P")"

# Review #5: a protected path that is a symlink to a folder is watched through the link.
P="$(new_project protected-link)"
mkdir -p "$P/real"
echo 'secret = 1' >"$P/real/secret.txt"
ln -s real "$P/Protected"
set_config "$P" '{"protectedPaths":["Protected"]}'
git -C "$P" add -A && git -C "$P" commit -qm "link" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'secret = 2' >"$P/real/secret.txt"
expect_result "protected-watch: a change behind a symlinked protected folder is shown (review #5)" 0 'changed: Protected/secret\.txt' "$(pwatch "$P")"

P="$(new_project protected-nosession)"
echo 'let engine = 4' >>"$P/Sources/Audio/Engine.swift"
expect_result "protected-watch: without a session-start list it says nothing" 0 '^exit=0$' "$(pwatch "$P")"
if jq -e '.hooks.Stop[0].hooks | map(.command) | any(test("protected-watch"))' "$PLUGIN/hooks/hooks.json" >/dev/null; then
  ok "protected-watch: registered as a Stop hook"
else nok "protected-watch: registered as a Stop hook"; fi

# ---------- checkpoint after compaction (#10) ----------

compact() { hook session-start.sh "$1" '{"source":"compact"}' 2>&1; }
P="$(new_project checkpoint)"
set_config "$P" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast","maxAttempts":5}}'
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
approve "$P" >/dev/null
echo '# Project' >"$P/CLAUDE.md"
git -C "$P" add -A && git -C "$P" commit -qm "docs" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
out="$(compact "$P")"
expect_result "checkpoint: right after the start, no code changed" 0 'checkpoint after compaction.*Verification: no code changed' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
echo 'let app = 2' >"$P/Sources/App.swift"
out="$(compact "$P")"
expect_result "checkpoint: names the branch and the files changed in the session" 0 'Branch: (main|master); 1 file\(s\) changed in this session: Sources/App\.swift' "exit=0
$out"
expect_result "checkpoint: changed code not checked yet is NOT verified" 0 'Verification: NOT verified' "exit=0
$out"
expect_result "checkpoint: points to the docs to reread" 0 'Source of truth, reread before relying on memory: CLAUDE\.md' "exit=0
$out"
: >"$LOG"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$P" >/dev/null 2>&1
if [ "$(grep -c . "$LOG")" = 1 ]; then ok "checkpoint: a compaction does not reset the session baseline"
else nok "checkpoint: a compaction does not reset the session baseline" "verify runs: $(grep -c . "$LOG")"; fi
expect_result "checkpoint: a failed check on the current code is FAILED" 0 'Verification: FAILED on the current code' "exit=0
$(compact "$P")"
echo 'let app = 3' >"$P/Sources/App.swift"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=0 hook stop-verify.sh "$P" >/dev/null 2>&1
expect_result "checkpoint: a passed check on the current code is passed" 0 'Verification: passed on the current code' "exit=0
$(compact "$P")"
git -C "$P" commit -qam "work" >/dev/null 2>&1
expect_result "checkpoint: commits made in the session are counted" 0 '1 commit\(s\) since the session started' "exit=0
$(compact "$P")"
printf '%s\n' 'echo changed' >>"$P/scripts/verify.sh"
expect_result "checkpoint: an unapproved verify command is waiting" 0 'Waiting:.*verify command is not approved' "exit=0
$(compact "$P" | tr '\n' ' ')"
if jq -e '.hooks.SessionStart[0].matcher | split("|") | index("compact")' "$PLUGIN/hooks/hooks.json" >/dev/null; then
  ok "checkpoint: session-start runs after a compaction"
else nok "checkpoint: session-start runs after a compaction"; fi

# ---------- per-session state (#61) ----------
# Two Claude Code sessions on one folder: each session's notices report what changed since its
# own start, and the second start does not erase the first session's lists.

as() { # $1 session id, $2 script, $3 project, $4 optional extra JSON
  local extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  hook "$2" "$3" "$(jq -nc --arg s "$1" --argjson e "$extra" '$e + {session_id: $s}')"
}
state_of() { printf '%s/data/state/%s' "$TMP" "$(printf '%s' "$(cd "$1" && pwd -P)" | shasum | cut -c1-16)"; }

P="$(new_project sessions-protected)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
as A session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let engine = 2' >>"$P/Sources/Audio/Engine.swift"
as B session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "sessions: a protected file changed before a second session started is still reported to the first" 0 'changed: Sources/Audio/Engine\.swift' "exit=0
$(as A protected-watch.sh "$P" 2>&1)"
expect_result "sessions: the second session does not report a change made before it started" 0 '^exit=0$' "exit=0$(as B protected-watch.sh "$P" 2>&1)"
echo 'let engine = 3' >"$P/Sources/Audio/Engine.swift"
post_edit "$P" "$P/Sources/Audio/Engine.swift" >/dev/null
expect_result "sessions: an edit through the guarded tools is not reported to the other session either" 0 '^exit=0$' "exit=0$(as B protected-watch.sh "$P" 2>&1)"

P="$(new_project sessions-verify)"
set_config "$P" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast","maxAttempts":5}}'
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
approve "$P" >/dev/null
as A session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$P/Sources/App.swift"
as B session-start.sh "$P" '{"source":"startup"}' >/dev/null
: >"$LOG"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=0 as B stop-verify.sh "$P" >/dev/null 2>&1
b_runs="$(grep -c . "$LOG")"
out="$(as A session-start.sh "$P" '{"source":"compact"}' 2>&1)"
expect_result "sessions: the first session's checkpoint counts a change made before the second started" 0 '1 file\(s\) changed in this session: Sources/App\.swift' "exit=0
$out"
FAKE_VERIFY_LOG="$LOG" FAKE_VERIFY_EXIT=0 as A stop-verify.sh "$P" >/dev/null 2>&1
if [ "$b_runs" = 0 ] && [ "$(grep -c . "$LOG")" = 1 ]; then ok "sessions: each session's end check compares with its own starting code"
else nok "sessions: each session's end check compares with its own starting code" "runs: B=$b_runs, then total $(grep -c . "$LOG")"; fi

P="$(new_project sessions-contract)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
as A session-start.sh "$P" '{"source":"startup"}' >/dev/null
mkdir -p "$P/docs"
printf '{"packages":{".":{"App":["Core"]}}}\n' >"$P/docs/architecture-contracts.json"
as B session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "sessions: a contract created before a second session started is still reported to the first" 0 'created in this session.*App -> Core' "exit=0
$(as A contract-watch.sh "$P" 2>&1 | tr '\n' ' ')"
expect_result "sessions: the second session does not report the contract it started with" 0 '^exit=0$' "exit=0$(as B contract-watch.sh "$P" 2>&1)"

P="$(new_project sessions-snapshots)"
mkdir -p "$P/snapshots"
echo one >"$P/snapshots/Pill.png"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
as A session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo two >"$P/snapshots/Pill.png"
as B session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "sessions: a baseline replaced before a second session started is still reported to the first" 0 'changed: snapshots/Pill\.png' "exit=0
$(as A snapshot-watch.sh "$P" 2>&1)"

P="$(sec_project sessions-security)"
as A session-start.sh "$P" '{"source":"startup"}' >/dev/null
entitle "$P" 'com\.apple\.security\.cs\.allow-jit' YES
sec --approve "$(sec --status --project "$P" | sed -n 's/^Digest: //p')" --project "$P" >/dev/null
as B session-start.sh "$P" '{"source":"startup"}' >/dev/null
expect_result "sessions: a security approval made before a second session started is still shown to the first" 0 'baseline was approved in this session.*allow-jit = true' "exit=0
$(as A protected-watch.sh "$P" 2>&1 | tr '\n' ' ')"

P="$(new_project sessions-cleanup)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
S="$(state_of "$P")"
mkdir -p "$S/sessions/old-session"
touch -t 202001010000 "$S/sessions/old-session"
as '../../escape' session-start.sh "$P" '{"source":"startup"}' >/dev/null
if [ ! -e "$S/sessions/old-session" ] && [ -d "$S/sessions/escape" ] && [ ! -e "$TMP/data/escape" ] && [ ! -e "$TMP/data/state/escape" ]; then
  ok "sessions: old session folders are removed, and a session id cannot leave the sessions folder"
else nok "sessions: old session folders are removed, and a session id cannot leave the sessions folder" "$(find "$TMP/data" -maxdepth 4 -name '*escape*' -o -maxdepth 4 -name old-session)"; fi

# ---------- accessibility audit template (#36) ----------
A11Y="$HERE/fixtures/accessibility"
if [ "$(readlink "$A11Y/A11yFixtureUITests/AccessibilityAudit.swift")" = "../../../../plugins/swift-harness/skills/setup/templates/tests/AccessibilityAudit.swift" ] &&
  cmp -s "$A11Y/A11yFixtureUITests/AccessibilityAudit.swift" "$PLUGIN/skills/setup/templates/tests/AccessibilityAudit.swift"; then
  ok "accessibility: the CI fixture runs the template helper itself"
else nok "accessibility: the CI fixture runs the template helper itself"; fi
if grep -qF 'has no reason' "$PLUGIN/skills/setup/templates/tests/AccessibilityAudit.swift" &&
  grep -qF '| `tests/AccessibilityAudit.swift` |' "$PLUGIN/skills/setup/SKILL.md"; then
  ok "accessibility: exceptions need a reason, and setup installs the helper"
else nok "accessibility: exceptions need a reason, and setup installs the helper"; fi

# ---------- keyboard, focus order and Reduce Motion (#52) ----------

link_ok() { # $1 link, $2 template: the link resolves to the template file
  [ "$(cd "$(dirname "$1")/$(dirname "$(readlink "$1")")" 2>/dev/null && pwd -P)/$(basename "$(readlink "$1")")" = "$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")" ]
}
if link_ok "$HERE/fixtures/keyboard/Tests/ComponentsTests/KeyboardCheck.swift" "$PLUGIN/skills/setup/templates/tests/KeyboardCheck.swift" &&
  link_ok "$HERE/fixtures/accessibility/A11yFixtureUITests/FocusOrder.swift" "$PLUGIN/skills/setup/templates/tests/FocusOrder.swift"; then
  ok "keyboard: the CI fixtures run the template helpers themselves"
else nok "keyboard: the CI fixtures run the template helpers themselves"; fi
if grep -qF '| `tests/KeyboardCheck.swift` |' "$PLUGIN/skills/setup/SKILL.md" && grep -qF '| `tests/FocusOrder.swift` |' "$PLUGIN/skills/setup/SKILL.md"; then
  ok "keyboard: setup installs both helpers"
else nok "keyboard: setup installs both helpers"; fi
if grep -qF 'XCTSkip' "$PLUGIN/skills/setup/templates/tests/FocusOrder.swift" && grep -qF 'AppleKeyboardUIMode -int 2' "$HERE/../.github/workflows/ci.yml"; then
  ok "keyboard: with Keyboard navigation off the focus order is skipped, not passed; CI turns it on"
else nok "keyboard: with Keyboard navigation off the focus order is skipped, not passed; CI turns it on"; fi
if grep -qF '@ReduceMotion private var reduceMotion' "$PLUGIN/skills/design-system/references/PillCenter.swift" &&
  grep -qF 'reduceMotionOverride' "$PLUGIN/skills/design-system/references/Tokens.swift"; then
  ok "motion: the shared presenter reads Reduce Motion through the overridable wrapper"
else nok "motion: the shared presenter reads Reduce Motion through the overridable wrapper"; fi

# ---------- layout audit from the accessibility tree (#69) ----------
LA="$PLUGIN/skills/setup/templates/tests/LayoutAudit.swift"
if link_ok "$HERE/fixtures/layout-audit/LayoutFixtureUITests/LayoutAudit.swift" "$LA" &&
  grep -qF 'layout-audit-fixture:' "$HERE/../.github/workflows/ci.yml" &&
  grep -qF 'platform=iOS Simulator' "$HERE/../.github/workflows/ci.yml"; then
  ok "layout audit: the CI fixture runs the template helper itself, on macOS and an iOS simulator"
else nok "layout audit: the CI fixture runs the template helper itself, on macOS and an iOS simulator"; fi
if grep -qF '| `tests/LayoutAudit.swift` |' "$PLUGIN/skills/setup/SKILL.md" && grep -qF 'has no reason' "$LA" &&
  grep -qF 'matches no issue' "$LA" && grep -qF 'it is not resizable' "$LA"; then
  ok "layout audit: setup installs it; an exception needs a reason and an issue; a window that cannot be resized fails"
else nok "layout audit: setup installs it; an exception needs a reason and an issue; a window that cannot be resized fails"; fi
if grep -qF 'cut by its own frame' "$LA" && grep -qF 'status bar' "$LA" && grep -qF 'UILaunchScreen' "$LA" &&
  grep -qF 'INFOPLIST_KEY_UILaunchScreen_Generation = YES' "$HERE/fixtures/layout-audit/LayoutFixture.xcodeproj/project.pbxproj"; then
  ok "layout audit: the header lists what it cannot see, and the iOS fixture has a launch screen"
else nok "layout audit: the header lists what it cannot see, and the iOS fixture has a launch screen"; fi

if ! command -v swiftlint >/dev/null 2>&1; then
  printf 'skip  motion: swiftlint not installed, the template rule was not run\n'
else
  # Not under $TMP, for the same reason as the concurrency rules above.
  L="$HERE/../.build/motion-test"
  rm -rf "$L"
  mkdir -p "$L/Sources"
  sed 's/{{DS_EXCLUDED_REGEX}}/DesignSystem/' "$PLUGIN/skills/setup/templates/swiftlint.yml" >"$L/.swiftlint.yml"
  cat >"$L/Sources/Panel.swift" <<'SWIFT'
import SwiftUI

struct Panel: View {
    @State private var open = false
    var reduceMotion = false
    var body: some View {
        VStack {
            if open { Text("a").transition(.move(edge: .top)) }
            if open { Text("b").transition(.slide) }
            if open { Text("c").transition(.scale.combined(with: .opacity)) }
            if open { Text("d").transition(Motion.moving(.move(edge: .top), reduced: reduceMotion)) }
            if open { Text("e").transition(.opacity) }
            // A comment about .transition(.move(edge: .top)) is not code.
            Text(".transition(.slide) in a string")
        }
    }
}
SWIFT
  lint="$(cd "$L" && swiftlint lint --quiet 2>&1 | grep ds_motion_without_reduce)"
  for n in 8 9 10; do
    if grep -qE "Panel\.swift:$n:.*ds_motion_without_reduce" <<<"$lint"; then ok "motion: a moving transition without Motion.moving is reported (line $n)"
    else nok "motion: a moving transition without Motion.moving is reported (line $n)" "$lint"; fi
  done
  if grep -qE 'Panel\.swift:(11|12|13|14):' <<<"$lint"; then nok "motion: Motion.moving, a fade, a comment and a string are not reported" "$lint"
  else ok "motion: Motion.moving, a fade, a comment and a string are not reported"; fi
  rm -rf "$L"
fi

# ---------- summary ----------

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
