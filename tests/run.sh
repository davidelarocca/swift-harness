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
# The simulator lock (#74) of the tests, apart from the machine's own.
export SWIFT_HARNESS_LOCK_DIR="$TMP/sim-lock"
# Claude Code's list of installed plugins, read by session-start and the doctor: an empty one
# here, so that the installs of the Mac running the tests change nothing.
export CLAUDE_CONFIG_DIR="$TMP/claude-config"

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

# ---------- guard-bash.sh: shell commands that write to a protected path (#135) ----------

bash_input() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
bash_asks() { hook guard-bash.sh "$1" "$(bash_input "$2")" | grep -q '"permissionDecision": "ask"'; }
expect_bash_ask() {
  if bash_asks "$1" "$2"; then ok "$3"; else nok "$3" "no approval request for: $2"; fi
}
expect_bash_no_ask() {
  if bash_asks "$1" "$2"; then nok "$3" "unexpected approval request for: $2"; else ok "$3"; fi
}

P="$(new_project guard-bash)"
# Off by default: the after-the-fact notice of protected-watch.sh stays the only control.
expect_bash_no_ask "$P" "echo x > Sources/Audio/Engine.swift" "guard-bash: off unless guardBash is true"
jq '.guardBash = true | .snapshots = {path: "snapshots"}' "$P/.claude/swift-harness.json" >"$TMP/gb.json" && mv "$TMP/gb.json" "$P/.claude/swift-harness.json"
mkdir -p "$P/snapshots" && echo png >"$P/snapshots/Library.png"
expect_bash_ask "$P" "echo x > Sources/Audio/Engine.swift" "guard-bash: a redirect into a protected file asks"
expect_bash_ask "$P" "printf 'x\n' >> Sources/Audio/Engine.swift" "guard-bash: an appending redirect asks"
expect_bash_ask "$P" "cat > ./Sources/Audio/New.swift <<'EOF'
let n = 1
EOF" "guard-bash: a heredoc into a new file under a protected folder asks"
expect_bash_ask "$P" "echo x > \"$P/Sources/Audio/Engine.swift\"" "guard-bash: an absolute path asks"
expect_bash_ask "$P" "printf x | tee -a Sources/Audio/Engine.swift" "guard-bash: tee asks"
expect_bash_ask "$P" "sed -i '' 's/1/2/' Sources/Audio/Engine.swift" "guard-bash: sed -i asks"
expect_bash_ask "$P" "perl -pi -e 's/1/2/' Sources/Audio/Engine.swift" "guard-bash: perl -pi asks"
expect_bash_ask "$P" "mv Sources/Audio/Engine.swift /tmp/engine.swift" "guard-bash: mv out of a protected path asks"
expect_bash_ask "$P" "cp /tmp/engine.swift Sources/Audio/Engine.swift" "guard-bash: cp onto a protected file asks"
expect_bash_ask "$P" "rm -rf Sources/Audio" "guard-bash: rm of a protected folder asks"
expect_bash_ask "$P" "git checkout -- Sources/Audio/Engine.swift" "guard-bash: git checkout of a protected file asks"
expect_bash_ask "$P" "python3 -c \"open('Sources/Audio/Engine.swift', 'w').write('x')\"" "guard-bash: python open(..., 'w') asks"
expect_bash_ask "$P" "python3 - <<'EOF'
from pathlib import Path
Path('Sources/Audio/Engine.swift').write_text('x')
EOF" "guard-bash: python write_text asks"
expect_bash_ask "$P" "sed -i '' 's/a/b/' App.xcodeproj/project.pbxproj" "guard-bash: a write to project.pbxproj asks"
expect_bash_ask "$P" "rm snapshots/Library.png" "guard-bash: a write to a snapshot baseline asks"
# Reading a protected path, or writing elsewhere, never asks.
expect_bash_no_ask "$P" "cat Sources/Audio/Engine.swift" "guard-bash: cat does not ask"
expect_bash_no_ask "$P" "grep -n engine Sources/Audio/Engine.swift" "guard-bash: grep does not ask"
expect_bash_no_ask "$P" "git diff -- Sources/Audio/" "guard-bash: git diff does not ask"
expect_bash_no_ask "$P" "git log --oneline -- Sources/Audio" "guard-bash: git log does not ask"
expect_bash_no_ask "$P" "cp Sources/Audio/Engine.swift /tmp/engine-copy.swift" "guard-bash: cp from a protected file does not ask"
expect_bash_no_ask "$P" "ls Sources/Audio > /tmp/list.txt 2>/dev/null" "guard-bash: a redirect elsewhere does not ask"
expect_bash_no_ask "$P" "echo x > Sources/AudioTools/Tool.swift" "guard-bash: a sibling folder sharing the prefix does not ask"
expect_bash_no_ask "$P" "python3 -c \"print(open('Sources/Audio/Engine.swift').read())\"" "guard-bash: python reading a protected file does not ask"
expect_bash_no_ask "$P" "python3 - <<'EOF'
p='docs/NOTES.md'
s=open(p).read() + 'See Sources/Audio/Engine.swift for the engine.'
open(p, 'w').write(s)
EOF" "guard-bash: a script that only mentions a protected path in the text it writes elsewhere does not ask"
expect_bash_no_ask "$P" "swift build" "guard-bash: a command that names no protected path does not ask"
expect_bash_no_ask "$P" "rm -rf .build
cat Sources/Audio/Engine.swift" "guard-bash: a write on one line and a read of a protected path on the next does not ask"
out="$(hook guard-bash.sh "$P" "$(bash_input 'echo x > Sources/Audio/Engine.swift')")"
expect_result "guard-bash: the reason names the path and the setting" 0 'Sources/Audio.*protected.*guardBash' "exit=0
$out"
CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$P" >"$TMP/gb-report.txt" 2>&1
expect_result "guard-bash: the question is in the catch log" 0 'shell' "exit=0
$(cat "$TMP/gb-report.txt")"
# The doctor knows the key and checks its type.
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)"
expect_result "guard-bash: doctor knows guardBash" 0 'Config keys.*all known' "exit=0
$out"
jq '.guardBash = "yes"' "$P/.claude/swift-harness.json" >"$TMP/gb.json" && mv "$TMP/gb.json" "$P/.claude/swift-harness.json"
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)"
expect_result "guard-bash: doctor rejects a guardBash that is not true or false" 0 'guardBash must be' "exit=0
$out"
grep -q '"matcher": "Bash"' "$PLUGIN/hooks/hooks.json" 2>/dev/null && grep -q 'guard-bash.sh' "$PLUGIN/hooks/hooks.json" &&
  ok "guard-bash: registered for Bash in hooks.json" || nok "guard-bash: registered for Bash in hooks.json" "missing"

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
# The doctor's check of the config: `swiftformat stdin --config .swiftformat --quiet`.
if [ "$1" = stdin ]; then
  [ "${FAKE_FMT_CONFIG:-ok}" = unknown ] && { echo "error: Unknown rule 'swiftTestingTestCaseNames'." >&2; exit 70; }
  cat
  exit 0
fi
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

# Presented UI: an edit that writes a popover, a menu or a positioned overlay is reminded, once
# per file, that it opens inside the window at every size.
pe_write() { # $1 project, $2 file, $3 text written by the edit
  jq -nc --arg cwd "$1" --arg f "$2" --arg t "$3" '{cwd: $cwd, session_id: "test", tool_name: "Edit", tool_input: {file_path: $f, old_string: "x", new_string: $t}}' |
    CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$1" "$SCRIPTS/post-edit.sh" 2>&1
}
PU="$(new_project presented-ui)"
set_config "$PU" '{"format":"none","lint":"none"}'
hook session-start.sh "$PU" '{"source":"startup"}' >/dev/null
printf 'struct Bar: View {\n    var body: some View { Button("x") {}.popover(isPresented: $shown) { List {} } }\n}\n' >"$PU/Sources/Bar.swift"
out="$(pe_write "$PU" "$PU/Sources/Bar.swift" 'Button("x") {}.popover(isPresented: $shown) { List {} }')"
expect_result "presented UI: a popover written by an edit is reminded to open inside the window" 0 'Presented UI: this edit opens a popover, menu, sheet or overlay in Sources/Bar\.swift.*smallest one.*Nothing may stick out of the window.*windows of their own.*clamp it inside the window bounds.*fits inside the window on the side it opens' "exit=0
$out"
expect_result "presented UI: ... once per file in a session" 0 '^exit=0$' "exit=0
$(pe_write "$PU" "$PU/Sources/Bar.swift" 'Menu("More") { Button("A") {} }')" 'Presented UI'
printf 'let menu = 1\n' >"$PU/Sources/Menu.swift"
expect_result "presented UI: a Menu in another file is reminded too" 0 'Presented UI: .*Sources/Menu\.swift' "exit=0
$(pe_write "$PU" "$PU/Sources/Menu.swift" 'Menu { Button("A") {} } label: { Text("More") }')"
printf 'let a = 1\n' >"$PU/Sources/Plain.swift"
expect_result "presented UI: an edit with none says nothing" 0 '^exit=0$' "exit=0
$(pe_write "$PU" "$PU/Sources/Plain.swift" 'let mainMenuTitle = "x"; let overlayCount = 2')" 'Presented UI'
printf 'struct Pop: View {\n    var body: some View { Color.clear.overlay { Text("x").offset(x: 300, y: 40) } }\n}\n' >"$PU/Sources/Pop.swift"
expect_result "presented UI: an overlay in a file that offsets or positions views is reminded" 0 'Presented UI: .*Sources/Pop\.swift' "exit=0
$(pe_write "$PU" "$PU/Sources/Pop.swift" 'Color.clear.overlay { Text("x").offset(x: 300, y: 40) }')"

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
bad=""
for f in "$SKILLS/ui-change/SKILL.md" "$PLUGIN/agents/ui-reviewer.md"; do
  for w in measured seen inferred; do grep -q "\*$w\*" "$f" || bad="$bad $(basename "$f"):$w"; done
done
if [ -z "$bad" ]; then ok "evidence: ui-change and ui-reviewer mark claims measured, seen or inferred (#81)"
else nok "evidence: ui-change and ui-reviewer mark claims measured, seen or inferred (#81)" "$bad"; fi
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

# With several test targets the one that fails can finish first: the last lines of `swift test`
# then hold only suites that passed (#187, and the 1.11 field report). What failed is read from
# the whole output and shown again just before the result, where the Stop hook reads: the last
# 60 lines.
SWF="$TMP/fakes-swift-fails"
mkdir -p "$SWF"
cp "$FAKES/xcodebuild" "$FAKES/swiftlint" "$SWF/"
cat >"$SWF/swift" <<'FAKE'
#!/bin/bash
# fake swift test: a target that fails first, then a long one that passes
case "${FAKE_SWIFT_OUTPUT:-both}" in
  both)
    echo "$PWD/Packages/Core/Tests/ATests/ATests.swift:8: error: -[ATests.OldStyleTests testDoublingTwo] : XCTAssertEqual failed: (\"4\") is not equal to (\"5\")"
    echo "Test Case '-[ATests.OldStyleTests testDoublingTwo]' failed (0.085 seconds)."
    echo '✘ Test doublingThreeGivesSix() recorded an issue at ATests.swift:5:38: Expectation failed: double(3) == 7'
    ;;
  names) echo "Test Case '-[ATests.OldStyleTests testOnlyNamed]' failed (0.085 seconds)." ;;
  many) i=0; while [ "$i" -lt 45 ]; do echo "✘ Test broken$i() recorded an issue at ATests.swift:$i:1: Expectation failed"; i=$((i + 1)); done ;;
esac
i=0
while [ "$i" -lt 150 ]; do echo "✔ Test passes$i() passed after 0.001 seconds."; i=$((i + 1)); done
echo 'Note: Some test targets reported failures:'
exit 1
FAKE
chmod +x "$SWF/swift"
swift_fails() { # prints "exit=<code>" then the last 60 lines of verify.sh fast: what the Stop hook shows
  local out code
  out="$(PATH="$SWF:/usr/bin:/bin" "$V/scripts/verify.sh" fast 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$(tail -n 60 <<<"$out")"
}
out="$(swift_fails)"
expect_result "verify.sh: an XCTest failure early in swift test is in the last 60 lines, relative to the project" 1 \
  '^Packages/Core: Packages/Core/Tests/ATests/ATests\.swift:8: error: -\[ATests\.OldStyleTests testDoublingTwo\] : XCTAssertEqual failed' "$out" "$V/Packages"
expect_result "verify.sh: ... and so is a Swift Testing issue" 1 '^Packages/Core: ✘ Test doublingThreeGivesSix\(\) recorded an issue at ATests\.swift:5:38: Expectation failed' "$out"
expect_result "verify.sh: ... each failure once, under a line that says where it comes from" 1 'what failed in swift test, from its whole output \(2 line\(s\)\):' "$out"
if [ "$(tail -n 1 <<<"$out")" = 'swift-harness-result/1: failed; checked: macOS; tested: macOS; not checked: none' ]; then ok "verify.sh: ... and the result line is still the last one"
else nok "verify.sh: ... and the result line is still the last one" "$(tail -n 3 <<<"$out")"; fi
expect_result "verify.sh: with no error line, the lines that name a failed test are shown" 1 "^Packages/Core: Test Case '-\[ATests\.OldStyleTests testOnlyNamed\]' failed" "$(FAKE_SWIFT_OUTPUT=names swift_fails)"
out="$(FAKE_SWIFT_OUTPUT=many swift_fails)"
expect_result "verify.sh: many failures are cut at 30, with the number left out" 1 '^\.\.\. and 15 more: run swift test' "$out" 'broken30\(\)'
expect_result "verify.sh: ... and the first ones are still in the last 60 lines" 1 '^Packages/Core: ✘ Test broken0\(\)' "$out"
expect_verify "verify.sh: a passing swift test shows no list of failures" 0 'verify fast: PASS' "$(run_verify "$V")"
if grep -q 'what failed' <<<"$(run_verify "$V")"; then nok "verify.sh: ... not even its heading"; else ok "verify.sh: ... not even its heading"; fi
if ! grep -qF '| tail -40' "$TEMPLATE"; then ok "verify.sh: swift test is not read through tail alone"
else nok "verify.sh: swift test is not read through tail alone"; fi

V="$(verify_project build-fails '-project App.xcodeproj' App '')"
expect_verify "verify.sh: failing build fails" 1 'verify fast: FAIL' "$(FAKE_XCODEBUILD_EXIT=65 run_verify "$V")"

# Xcode 27 with -quiet names failed tests only under "Failing tests:", one per indented line
# (found by the mutation run of #79): without xcbeautify they must still reach Claude.
mkdir -p "$TMP/fakes-failing"
cp "$FAKES/swift" "$FAKES/swiftlint" "$TMP/fakes-failing/"
printf '#!/bin/bash\nprintf "Failing tests:\\n\\tAppUITests.testTheFixedScreenPassesTheAudit()\\n\\n** TEST FAILED **\\n"\nexit 65\n' >"$TMP/fakes-failing/xcodebuild"
chmod +x "$TMP/fakes-failing/xcodebuild"
out="$(PATH="$TMP/fakes-failing:/usr/bin:/bin" "$V/scripts/verify.sh" full 2>&1)"
expect_result "verify.sh: without xcbeautify, the names of failed tests are shown (Xcode 27 -quiet)" 1 'Failing tests:' "exit=$?
$out"
expect_result "verify.sh: ... with each test on its line" 1 'AppUITests\.testTheFixedScreenPassesTheAudit\(\)' "exit=1
$out"

# The result bundle (#147): on a failure verify.sh reads build errors with file and line and failed
# tests with their messages from xcresulttool; the text of xcodebuild is the fallback. The fakes
# answer with the JSON of a real bundle (tests/fixtures/xcresult, Xcode 27.2).
XR="$HERE/fixtures/xcresult"
FB="$TMP/fakes-bundle"
mkdir -p "$FB"
cp "$FAKES/swift" "$FAKES/swiftlint" "$FB/"
ln -s "$(command -v jq)" "$FB/jq"
cat >"$FB/xcodebuild" <<'EOF'
#!/bin/bash
b=""
while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && b="$2"; shift; done
[ -n "$b" ] || { echo "no -resultBundlePath"; exit 64; }
[ ! -e "$b" ] || { echo "Existing file at -resultBundlePath $b"; exit 70; }
mkdir -p "$b"
[ "${FAKE_XCODEBUILD_EXIT:-65}" = 0 ] && exit 0
printf 'Failing tests:\n\tLegacyTests.testSum()\n\n** TEST FAILED **\n'
exit "${FAKE_XCODEBUILD_EXIT:-65}"
EOF
cat >"$FB/xcrun" <<EOF
#!/bin/bash
[ "\${FAKE_XCRESULT:-}" != none ] || exit 1
case "\$*" in
  "--find xcresulttool") echo /usr/bin/xcresulttool ;;
  *"get build-results"*) sed "s|file://PROJECT/|file://\$PWD/|" "$XR/build-results.json" ;;
  *"get test-results summary"*) cat "$XR/test-summary.json" ;;
  *"export attachments"*)
    o=""; while [ \$# -gt 0 ]; do [ "\$1" = --output-path ] && o="\$2"; shift; done
    mkdir -p "\$o" && echo png >"\$o/Failure-1.png" && echo '[]' >"\$o/manifest.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FB/xcodebuild" "$FB/xcrun"
V="$(verify_project bundle '-project App.xcodeproj' App '')"
out="$(PATH="$FB:/usr/bin:/bin" "$V/scripts/verify.sh" full 2>&1)"
expect_result "verify.sh: a failure is read from the result bundle, and says so" 1 'results from the result bundle \(\.build/swift-harness/results/test-macOS\.xcresult\)' "exit=1
$out" "results from xcodebuild's text"
expect_result "verify.sh: ... each failed test with its message" 1 'failed test: ComponentsTests/LegacyTests/testSum\(\): XCTAssertEqual failed: \("2"\) is not equal to \("3"\) - sum is wrong' "exit=1
$out"
expect_result "verify.sh: ... each build error with its file and line, relative to the project" 1 "error: Tests/ComponentsTests/KeyboardTests.swift:31: Cannot find 'KeyboardCheck' in scope" "exit=1
$out"
expect_result "verify.sh: ... and the attachments of failing tests, exported next to the bundle" 1 'attachments of failing tests \(1 file\(s\), screenshots included\): \.build/swift-harness/results/attachments-macOS' "exit=1
$out"
out="$(FAKE_XCRESULT=none PATH="$FB:/usr/bin:/bin" "$V/scripts/verify.sh" full 2>&1)"
expect_result "verify.sh: without xcresulttool the text of xcodebuild is the fallback, and says so" 1 "results from xcodebuild's text .*
Failing tests:" "exit=1
$out" 'results from the result bundle'
mkdir -p "$V/.build/swift-harness/results/build-macOS.xcresult"
out="$(FAKE_XCODEBUILD_EXIT=0 PATH="$FB:/usr/bin:/bin" "$V/scripts/verify.sh" fast 2>&1)"
expect_result "verify.sh: the bundle of the last run is replaced, not refused" 0 'verify fast: PASS' "exit=$?
$out"

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
expect_verify "verify.sh platforms: in fast mode a scheme is built, not tested, and the hooks' line says so" 0 '^swift-harness-result/1: passed; checked: macOS, iOS; tested: none; not checked: none$' "$out"
expect_verify "verify.sh platforms: each build step names its platform" 0 'xcodebuild build \(App, iOS\)' "$out"

# The fake fails only for iOS destinations.
printf '#!/bin/bash\ncase "$*" in *iOS*) exit 65 ;; esac\nexit 0\n' >"$TMP/xcodebuild-ios-fails"
chmod +x "$TMP/xcodebuild-ios-fails"
mkdir -p "$TMP/fakes-ios-fails"
cp "$FAKES/swift" "$FAKES/swiftlint" "$TMP/fakes-ios-fails/"
cp "$TMP/xcodebuild-ios-fails" "$TMP/fakes-ios-fails/xcodebuild"
out="$(PATH="$TMP/fakes-ios-fails:/usr/bin:/bin" "$V/scripts/verify.sh" fast 2>&1; printf '\nexit=%s' $?)"
if grep -q 'verify fast: FAIL' <<<"$out" && grep -q 'exit=1' <<<"$out" && grep -q 'failed on: iOS' <<<"$out" &&
  grep -qx 'swift-harness-result/1: failed; checked: macOS, iOS; tested: none; not checked: none' <<<"$out"; then
  ok "verify.sh platforms: a build failing only on iOS fails and names iOS"
else nok "verify.sh platforms: a build failing only on iOS fails and names iOS" "$out"; fi

V="$(verify_project pkg-ios '' '' '"Packages/Core"' '"macOS" "iOS"' 'iPhone 16')"
mkdir -p "$V/Packages/Core"
out="$(run_verify "$V")"
expect_verify "verify.sh platforms: packages only, iOS listed, is PARTIAL and never PASS" 0 'verify fast: PARTIAL \(passed on macOS; not checked on iOS' "$out" 'verify fast: PASS'
expect_verify "verify.sh platforms: PARTIAL also gives the hooks a versioned line" 0 '^swift-harness-result/1: partial; checked: macOS; tested: macOS; not checked: iOS$' "$out"

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
expect_result "stop: the contracts are named in the failure header, the verify command that passed apart" 2 '^Verification failed \(attempt 1 of 3\): architecture contracts$' "$out"
expect_result "stop: ... and the verify command on the line of the checks that passed" 2 '^Passed: scripts/verify\.sh fast' "$out"
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
expect_result "stop: the registry is named in the failure header, the verify command that passed apart" 2 '^Verification failed \(attempt 1 of 3\): component registry$' "$out"
expect_result "stop: ... and the verify command on the line of the checks that passed" 2 '^Passed: scripts/verify\.sh fast' "$out"
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
expect_result "stop: the layout contract is named in the failure header, the verify command that passed apart" 2 '^Verification failed \(attempt 1 of 3\): layout contract$' "$out"
expect_result "stop: ... and the verify command on the line of the checks that passed" 2 '^Passed: scripts/verify\.sh fast' "$out"
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

# The helpers are kept as shipped, so each one turns the formatters off for itself, before its
# first line of code. The real formatters run on them in tests/format-helpers.sh (CI).
bad=""
for f in "$TEMPLATES"/tests/*.swift; do
  code="$(grep -n -m1 -E '^(import|#if|@|enum|struct|final|class|func) ' "$f" | cut -d: -f1)"
  for marker in '// swiftformat:disable all' '// swift-format-ignore-file'; do
    line="$(grep -n -m1 -xF -- "$marker" "$f" | cut -d: -f1)"
    [ -n "$line" ] && [ -n "$code" ] && [ "$line" -lt "$code" ] || bad="$bad $(basename "$f"):$marker"
  done
done
if [ -z "$bad" ]; then ok "templates: every test helper turns SwiftFormat and swift-format off for itself"
else nok "templates: every test helper turns SwiftFormat and swift-format off for itself" "$bad"; fi
# What a baseline depends on and the helper does not pin yet is said where baselines are made.
if grep -qF 'neither pinned nor recorded yet' "$TEMPLATES/tests/Snapshot.swift" && grep -qF 'Color.accentColor' "$TEMPLATES/tests/Snapshot.swift" &&
  grep -qF 'pass `locale:`' "$TEMPLATES/tests/Snapshot.swift"; then
  ok "snapshots: the helper says that the locale and the accent color are not pinned"
else nok "snapshots: the helper says that the locale and the accent color are not pinned"; fi

# Where the component tests go when screens and design system are separate packages: one answer,
# the same in the two skills that speak of it, and what the contract check sees of a test target.
if grep -qF '**Where the helpers go.**' "$SKILLS/setup/SKILL.md" && grep -qF 'Tests/DesignSystemTests/' "$SKILLS/setup/SKILL.md" &&
  grep -qF "the design system package's tests for shared components" "$SKILLS/setup/SKILL.md" &&
  grep -qF 'with their own copies of the setup helpers' "$SKILLS/design-system/SKILL.md" &&
  ! grep -qF '| `tests/Snapshot.swift` | the same test target as `LayoutContract.swift` (see step 7) |' "$SKILLS/setup/SKILL.md"; then
  ok "skills: setup and design-system put the component tests in the same place"
else nok "skills: setup and design-system put the component tests in the same place"; fi
if [ "$(grep -lF 'a new dependency needs the user' "$SKILLS/design-system/SKILL.md" | wc -l | tr -d ' ')" = 1 ] &&
  grep -qF 'test targets are checked only when the contract lists them' "$SKILLS/setup/SKILL.md" &&
  grep -qF 'Test targets are checked only when the contract lists them' "$TEMPLATES/rules/architecture.md"; then
  ok "skills: the limit of the contract check on test targets is said where a dependency is decided"
else nok "skills: the limit of the contract check on test targets is said where a dependency is decided"; fi

# Formatting does not rename tests: the generated config turns the rule off, the setup says so,
# and the doctor names a swiftformat too old to know the rule. The real formatter runs in
# tests/format-helpers.sh.
if grep -qxF -- '--disable swiftTestingTestCaseNames' "$TEMPLATES/swiftformat" && grep -qF 'swiftTestingTestCaseNames' "$SKILLS/setup/SKILL.md" &&
  grep -qF 'swiftformat --rules' "$SKILLS/setup/SKILL.md"; then
  ok "templates: the generated .swiftformat does not rename Swift Testing tests, and setup says so"
else nok "templates: the generated .swiftformat does not rename Swift Testing tests, and setup says so"; fi
P="$(new_project formatter-config)"
set_config "$P" '{"format":"swiftformat"}'
if grep -q 'Formatter config' <<<"$(doctor "$P")"; then nok "doctor: no .swiftformat, no Formatter config row"; else ok "doctor: no .swiftformat, no Formatter config row"; fi
sed 's/{{SWIFT_VERSION}}/6.2/' "$TEMPLATES/swiftformat" >"$P/.swiftformat"
expect_row "doctor: a .swiftformat the formatter accepts passes" "$(doctor "$P")" PASS 'Formatter config' '\.swiftformat'
expect_row "doctor: a .swiftformat with a rule this swiftformat does not know is named" "$(FAKE_FMT_CONFIG=unknown doctor "$P")" WARN 'Formatter config' "refused by this swiftformat \(Unknown rule 'swiftTestingTestCaseNames'\.\).*brew upgrade swiftformat"

if grep -qF 'swiftformat:disable all' "$SKILLS/setup/SKILL.md" && [ -x "$HERE/format-helpers.sh" ]; then ok "templates: setup says the helpers are left alone by the formatters"
else nok "templates: setup says the helpers are left alone by the formatters"; fi
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

# The metadata beside a baseline never names the test file by its absolute path: the folder is
# committed, and that path holds the account name and the folders of the Mac that ran the test.
if ! grep -qF '"test": "\(file)"' "$TEMPLATES/tests/Snapshot.swift" "$TEMPLATES/tests/Screenshot.swift" &&
  grep -qF '"test": test,' "$TEMPLATES/tests/Snapshot.swift" && grep -qF '"test": test,' "$TEMPLATES/tests/Screenshot.swift" &&
  grep -qF 'static func testPath' "$TEMPLATES/tests/Screenshot.swift"; then
  ok "snapshots: the helpers write the test file relative to the project"
else nok "snapshots: the helpers write the test file relative to the project"; fi
if ! grep -lE '"test": "/' "$HERE"/fixtures/visual/snapshots/*.json >/dev/null; then ok "snapshots: the fixture's own baselines hold no absolute path"
else nok "snapshots: the fixture's own baselines hold no absolute path"; fi

S="$(new_project snapshot-paths)"
mkdir -p "$S/Tests/AppTests"
echo '// tests' >"$S/Tests/AppTests/SnapTests.swift"
git -C "$S" add -A && git -C "$S" commit -qm tests
ELSEWHERE="/elsewhere/app" # the project root on the Mac that made a baseline
meta() { # $1 project, $2 image name, $3 test path: the metadata an older helper left
  printf '{"os": "%s", "scale": 2, "test": "%s"}\n' "$THIS_OS" "$3" >"$1/.build/swift-harness/snapshots/$2.json"
}
candidate "$S" Here-macos-80-light missing a
meta "$S" Here-macos-80-light "$S/Tests/AppTests/SnapTests.swift"
candidate "$S" Elsewhere-macos-80-light missing b
meta "$S" Elsewhere-macos-80-light "$ELSEWHERE/Tests/AppTests/SnapTests.swift"
candidate "$S" Gone-macos-80-light missing c
meta "$S" Gone-macos-80-light "$ELSEWHERE/Tests/OldTests/GoneTests.swift"
candidate "$S" Relative-macos-80-light missing d
meta "$S" Relative-macos-80-light "Tests/AppTests/SnapTests.swift"
candidate "$S" NoTest-macos-80-light missing e
out="$(snap --approve "$(snap_digest "$S")" --project "$S")"
tests_of() { for n in "$@"; do jq -r '.test // "none"' "$S/snapshots/$n-macos-80-light.json"; done | paste -sd' ' -; }
if [ "$(tests_of Here Elsewhere Gone Relative NoTest)" = "Tests/AppTests/SnapTests.swift Tests/AppTests/SnapTests.swift GoneTests.swift Tests/AppTests/SnapTests.swift none" ]; then
  ok "snapshots: an approval makes the test path relative (under the project, from another Mac, a file that is gone)"
else nok "snapshots: an approval makes the test path relative (under the project, from another Mac, a file that is gone)" "$(tests_of Here Elsewhere Gone Relative NoTest)
$out"; fi
if ! grep -rqE "$S|\"/" "$S/snapshots" && jq -e '.approved and .os and .approvedFrom == "missing"' "$S/snapshots/Here-macos-80-light.json" >/dev/null; then
  ok "snapshots: a fresh approval leaves no absolute path in the baselines folder"
else nok "snapshots: a fresh approval leaves no absolute path in the baselines folder" "$(grep -rE "$S|\"/" "$S/snapshots")"; fi
expect_row "doctor: baselines with relative test paths pass" "$(doctor "$S")" PASS 'Snapshot metadata' 'no absolute path in snapshots/'

# Baselines approved with an older helper: reported, and made relative only by the approval script.
for n in Here Elsewhere; do
  jq --arg t "$ELSEWHERE/Tests/AppTests/SnapTests.swift" '.test = $t' "$S/snapshots/$n-macos-80-light.json" >"$TMP/sj" && mv "$TMP/sj" "$S/snapshots/$n-macos-80-light.json"
done
git -C "$S" add -A && git -C "$S" commit -qm "baselines from an older helper"
hook session-start.sh "$S" '{"source":"startup"}' >/dev/null
png_before="$(shasum "$S"/snapshots/*.png)"
expect_row "doctor: a baseline made by an older helper is reported" "$(doctor "$S")" WARN 'Snapshot metadata' '2 file\(s\) in snapshots/ name the test or source file by its absolute path.*first: snapshots/Elsewhere-macos-80-light\.json.*approve-snapshots'
expect_result "snapshots: status counts the metadata with an absolute path" 0 '^2 metadata file\(s\) in snapshots/ hold the absolute path.*--relative-paths' "$(snap --status --project "$S")"
expect_result "snapshots: --relative-paths takes no image name" 2 'usage:' "$(snap --relative-paths --project "$S" Here-macos-80-light)"
# An edit by hand of such metadata would ask the user once per file: it is refused with the one
# command that fixes them all, which needs no question. The images still ask.
out="$(hook guard.sh "$S" "$(edit_input "$S/snapshots/Here-macos-80-light.json")")"
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null <<<"$out" &&
  grep -qE '2 metadata file\(s\) in snapshots/ hold an absolute path.*CLAUDE_PLUGIN_DATA=\\"[^\\"]+\\" \\"[^\\"]*/snapshots\.sh\\" --relative-paths --project' <<<"$out"; then
  ok "guard: a hand edit of metadata with an absolute path is sent to snapshots.sh --relative-paths"
else nok "guard: a hand edit of metadata with an absolute path is sent to snapshots.sh --relative-paths" "$out"; fi
expect_ask "$S" "$S/snapshots/Here-macos-80-light.png" "guard: ... while an image there still asks"
out="$(snap --relative-paths --project "$S")"
expect_result "snapshots: --relative-paths rewrites the test field of each file" 0 'Made relative: snapshots/Elsewhere-macos-80-light\.json \(test: Tests/AppTests/SnapTests\.swift\)' "$out"
expect_result "snapshots: --relative-paths says what to commit" 0 'only the file paths \("test", "source"\) of 2 metadata file\(s\) changed' "$out"
if [ "$png_before" = "$(shasum "$S"/snapshots/*.png)" ] && ! grep -rqE '"/' "$S/snapshots" &&
  [ "$(git -C "$S" diff --numstat | awk '{ a += $1; d += $2 } END { print NR, a, d }')" = "2 2 2" ]; then
  ok "snapshots: --relative-paths changes one line in each file and no image"
else nok "snapshots: --relative-paths changes one line in each file and no image" "$(git -C "$S" diff --stat)"; fi
expect_result "snapshot-watch: paths made relative by the script are not reported" 0 '^exit=0$' "$(swatch "$S")"
expect_result "snapshots: --relative-paths with nothing to do says so" 0 'Nothing changed' "$(snap --relative-paths --project "$S")"
expect_row "doctor: after --relative-paths the metadata passes" "$(doctor "$S")" PASS 'Snapshot metadata'
expect_ask "$S" "$S/snapshots/Here-macos-80-light.json" "guard: metadata with relative paths asks as before"
expect_result "snapshots: status says nothing about metadata when it is clean" 0 'No new images wait' "$(snap --status --project "$S")" 'absolute path'
# The source a test passes (source:) is committed too: an absolute one is caught the same way.
jq --arg s "$ELSEWHERE/Sources/App.swift" '.source = $s' "$S/snapshots/Here-macos-80-light.json" >"$TMP/sj" && mv "$TMP/sj" "$S/snapshots/Here-macos-80-light.json"
expect_row "doctor: an absolute source path in a baseline is reported" "$(doctor "$S")" WARN 'Snapshot metadata' '1 file\(s\) in snapshots/ name the test or source file by its absolute path'
snap --relative-paths --project "$S" >/dev/null
if [ "$(jq -r .source "$S/snapshots/Here-macos-80-light.json")" = Sources/App.swift ]; then ok "snapshots: --relative-paths makes the source relative too"
else nok "snapshots: --relative-paths makes the source relative too" "$(cat "$S/snapshots/Here-macos-80-light.json")"; fi
# Screenshots are not committed by default; a folder set in the config can be.
mkdir -p "$S/review/shots"
printf '{"os": "27.0", "test": "%s/Tests/AppTests/ShotTests.swift"}\n' "$ELSEWHERE" >"$S/review/shots/Main-macos-600x400-light.json"
set_config "$S" '{"screenshots":{"path":"review/shots"}}'
expect_row "doctor: screenshot metadata with an absolute path is reported" "$(doctor "$S")" WARN 'Snapshot metadata' '1 file\(s\) in review/shots/.*run the tests that capture again'
set_config "$S" '{}'
if grep -qF -- '--relative-paths' "$SKILLS/approve-snapshots/SKILL.md"; then ok "snapshots: the approval skill makes old metadata relative"
else nok "snapshots: the approval skill makes old metadata relative"; fi

# The review page: the user approves images they have seen, not a description. --status writes
# review.html next to the new images: per component the image that changed most, as approved,
# as it is now and with the changed pixels in red.
S="$(new_project snapshot-page)"
RP="$S/.build/swift-harness/snapshots/review.html"
full_meta() { # $1 image name, $2 screen, $3 state, $4 size, $5 appearance: the metadata the helper writes
  printf '{"os": "%s", "scale": 2, "screen": "%s", "state": "%s", "locale": "", "contractSize": "%s", "size": "%s", "appearance": "%s"}\n' \
    "$THIS_OS" "$2" "$3" "$4" "$4" "$5" >"$S/.build/swift-harness/snapshots/$1.json"
}
result() { # $1 image name, $2 status, $3 reason
  jq -n --arg s "$2" --arg r "$3" '{status: $s, reason: $r}' >"$S/.build/swift-harness/snapshots/$1.result.json"
}
mkdir -p "$S/snapshots"
for a in light dark; do
  candidate "$S" "Card-macos-200x80-$a" failed new-card
  full_meta "Card-macos-200x80-$a" Card "" 200x80 "$a"
  printf 'old-card' >"$S/snapshots/Card-macos-200x80-$a.png"
  printf '{"os": "%s", "scale": 2}\n' "$THIS_OS" >"$S/snapshots/Card-macos-200x80-$a.json"
done
result Card-macos-200x80-light failed "Card-macos-200x80-light: 85 of 151200 pixels differ (0.06%), within x 96-110, y 118-126 pt from the top left. The new image is /somewhere/Card.png, changes in red in /somewhere/Card.diff.png."
result Card-macos-200x80-dark failed "Card-macos-200x80-dark: 4200 of 151200 pixels differ (2.78%), within x 10-110, y 18-126 pt from the top left. The new image is /somewhere/Card.png."
candidate "$S" Pill-long-text-macos-120-light missing new-pill
full_meta Pill-long-text-macos-120-light Pill long-text 120x24 light
candidate "$S" Badge-macos-200-light failed new-badge
full_meta Badge-macos-200-light Badge "" 200x64 light
rm -f "$S/.build/swift-harness/snapshots/Badge-macos-200-light.diff.png"
printf 'old-badge' >"$S/snapshots/Badge-macos-200-light.png"
result Badge-macos-200-light failed "Badge-macos-200-light: the size changed from 200x48 to 200x64 pt. The new image is /somewhere/Badge.png."
# A name with characters HTML reads: it comes from the project, so it is escaped.
candidate "$S" 'Odd<b>&x-macos-80-light' missing odd
out="$(snap --status --project "$S")"
expect_result "snapshot page: status names the page to open, before the digest" 0 "Review page, to open for the user before asking what to approve: $RP.*Digest: [0-9a-f]{64}" "exit=0
$(tail -n +2 <<<"$out" | tr '\n' ' ')"
page="$(cat "$RP" 2>/dev/null)"
if grep -qF '5 snapshot images wait for your approval, in 4 components' <<<"$page" && grep -qF 'must look like its <b>Now</b> image' <<<"$page"; then
  ok "snapshot page: it says how many images wait and what approving means"
else nok "snapshot page: it says how many images wait and what approving means" "$(grep -m1 '<h1>' <<<"$page")"; fi
# The order: a size change, then pixel changes with the largest first, then new images.
if [ "$(grep -o '<h2 id="g[0-9]*">[^<]*</h2>' <<<"$page" | sed -E 's/<[^>]*>//g' | paste -sd'|' -)" = 'Badge|Card|Odd&lt;b&gt;&amp;x-macos-80-light|Pill · long-text' ]; then
  ok "snapshot page: the largest changes are first, and a name from the project is escaped"
else nok "snapshot page: the largest changes are first, and a name from the project is escaped" "$(grep -o '<h2 id="g[0-9]*">[^<]*</h2>' <<<"$page")"; fi
if grep -qF '<td>2.78% of pixels</td>' <<<"$page" && grep -qF '<td>200x48 to 200x64 pt</td>' <<<"$page" &&
  grep -qF '· changed · 2.78% of pixels, within x 10-110, y 18-126 pt from the top left' <<<"$page"; then
  ok "snapshot page: each component has the size of its largest change, and where to look"
else nok "snapshot page: each component has the size of its largest change, and where to look" "$(grep '<td>' <<<"$page")"; fi
card="$(awk '/<h2 id="g[0-9]*">Card</,/<h2 id="g[0-9]*">Odd/' <<<"$page")"
# The light variant changed in another place than the dark one: folded, it could be approved
# with "all" unseen, so it is shown open.
# (The range ends on the next component's heading line, which holds its first <h3> too.)
if [ "$(grep -o '<h3>[^<]*' <<<"$card" | head -2 | paste -sd'|' -)" = '<h3>200x80, dark |<h3>200x80, light ' ] && ! grep -qF '<details>' <<<"$card"; then
  ok "snapshot page: a component shows the variant that changed most first, and one that changed elsewhere open"
else nok "snapshot page: a component shows the variant that changed most first, and one that changed elsewhere open" "$(grep -o '<h3>[^<]*\|<summary>[^<]*' <<<"$card")"; fi
if grep -qF 'src="../../../snapshots/Card-macos-200x80-dark.png"' <<<"$card" && grep -qF 'src="Card-macos-200x80-dark.png"' <<<"$card" &&
  grep -qF 'src="Card-macos-200x80-dark.diff.png"' <<<"$card" && grep -qF "Before (approved, made on macOS $THIS_OS)" <<<"$card"; then
  ok "snapshot page: the approved image, the new one and the changed pixels are side by side"
else nok "snapshot page: the approved image, the new one and the changed pixels are side by side" "$(grep -o 'src="[^"]*"' <<<"$card")"; fi
pill="$(awk '/<h2 id="g[0-9]*">Pill/,0' <<<"$page")"
if grep -qF 'new: no approved image yet' <<<"$pill" && ! grep -qF 'Before (approved' <<<"$pill" && ! grep -qF '.diff.png' <<<"$pill"; then
  ok "snapshot page: a new image has no approved one and no diff beside it"
else nok "snapshot page: a new image has no approved one and no diff beside it" "$pill"; fi
if grep -qF 'src="Odd%3Cb%3E%26x-macos-80-light.png"' <<<"$page" && ! grep -qF '<b>&x' <<<"$page"; then ok "snapshot page: a path is encoded for the link, never written as HTML"
else nok "snapshot page: a path is encoded for the link, never written as HTML" "$(grep -o 'src="Odd[^"]*"' <<<"$page")"; fi
if ! grep -qiE '<script|https?://|javascript:' <<<"$page" && grep -qF "default-src 'none'" <<<"$page" && ! grep -qF "$S" <<<"$page"; then
  ok "snapshot page: no script, nothing from outside, and no absolute path of this Mac"
else nok "snapshot page: no script, nothing from outside, and no absolute path of this Mac" "$(grep -iE '<script|https?://|javascript:' <<<"$page"; grep -F "$S" <<<"$page")"; fi
# The same change in the same place: folded under the one shown.
result Card-macos-200x80-light failed "Card-macos-200x80-light: 4000 of 151200 pixels differ (2.65%), within x 10-110, y 18-126 pt from the top left. The new image is /somewhere/Card.png."
snap --status --project "$S" >/dev/null
card="$(awk '/<h2 id="g[0-9]*">Card</,/<h2 id="g[0-9]*">Odd/' "$RP")"
if [ "$(grep -o '<h3>200x80' <<<"$card" | grep -c .)" = 2 ] && grep -qF '<details><summary>1 more image of this component with the same change in the same place: 200x80, light</summary>' <<<"$card"; then
  ok "snapshot page: a variant with the same change in the same place is folded under the one shown"
else nok "snapshot page: a variant with the same change in the same place is folded under the one shown" "$(grep -o '<h3>[^<]*\|<summary>[^<]*' <<<"$card")"; fi
d="$(snap_digest "$S")"
if [ "$d" = "$(snap_digest "$S")" ] && [ -f "$RP" ] && [ -z "$(find "$S/.build/swift-harness/snapshots" -type f ! -name '*.png' ! -name '*.json' ! -name review.html)" ]; then
  ok "snapshot page: writing the page does not change the digest, and leaves no other file"
else nok "snapshot page: writing the page does not change the digest, and leaves no other file" "$(ls -a "$S/.build/swift-harness/snapshots")"; fi
set_config "$S" '{"snapshots":{"path":"Tests/Baselines"}}'
mkdir -p "$S/Tests/Baselines" && cp "$S/snapshots/Badge-macos-200-light.png" "$S/Tests/Baselines/"
snap --status --project "$S" >/dev/null
if grep -qF 'src="../../../Tests/Baselines/Badge-macos-200-light.png"' "$RP"; then ok "snapshot page: the approved images come from snapshots.path"
else nok "snapshot page: the approved images come from snapshots.path" "$(grep -o 'src="[^"]*Badge[^"]*"' "$RP")"; fi
set_config "$S" '{}'
snap --approve "$(snap_digest "$S")" --project "$S" Badge-macos-200-light >/dev/null
[ ! -e "$RP" ] && ok "snapshot page: an approval removes the page, which showed what waited before it" || nok "snapshot page: an approval removes the page, which showed what waited before it"
# A link in the way could lead outside the project: no page, and the status goes on without it.
mv "$S/.build/swift-harness/snapshots" "$TMP/moved-candidates" && ln -s "$TMP/moved-candidates" "$S/.build/swift-harness/snapshots"
out="$(snap --status --project "$S")"
expect_result "snapshot page: with a link in the way no page is written, and the status says so" 0 'No review page could be written in \.build/swift-harness/snapshots: show the user the image files listed above' "$out"
[ ! -e "$TMP/moved-candidates/review.html" ] && ok "snapshot page: ... and nothing lands behind the link" || nok "snapshot page: ... and nothing lands behind the link"
expect_result "snapshot page: ... while the digest is still given" 0 '^Digest: [0-9a-f]{64}$' "$out"
rm "$S/.build/swift-harness/snapshots" && mv "$TMP/moved-candidates" "$S/.build/swift-harness/snapshots"
if grep -qF 'open "<the path of the review page>"' "$SKILLS/approve-snapshots/SKILL.md" && grep -qF 'do not narrate every image' "$SKILLS/approve-snapshots/SKILL.md" &&
  grep -qF 'an approved image is how the component must look from now on' "$SKILLS/approve-snapshots/SKILL.md"; then
  ok "snapshot page: the skill opens it, keeps its own words short and says what approving means"
else nok "snapshot page: the skill opens it, keeps its own words short and says what approving means"; fi
if grep -qF 'opens a page with each image before, now and its changed pixels' "$TEMPLATES/tests/Snapshot.swift" && ! grep -qF 'Show it to the user' "$TEMPLATES/tests/Snapshot.swift"; then
  ok "snapshot page: a failing snapshot test says what the approval command shows"
else nok "snapshot page: a failing snapshot test says what the approval command shows"; fi

# ---------- guard-bash.sh: a commit with git's automatic identity ----------

# With no user.email git signs a commit as <account>@<host name>, and with no user.name with
# the full name of the account: once pushed, that leaves only by rewriting history. The guard
# denies a command that writes a commit while the identity is that one.

# The environment of a Mac where git was never configured: no global or system config, no
# identity in the environment. The project's own config stays.
bare_git() { env -u EMAIL -u GIT_COMMITTER_EMAIL -u GIT_COMMITTER_NAME -u GIT_AUTHOR_EMAIL -u GIT_AUTHOR_NAME HOME="$TMP/no-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"; }
mkdir -p "$TMP/no-home"
commit_guard() { # $1 project, $2 command, $3 the session's folder (default: the project)
  jq -nc --arg cwd "${3:-$1}" --arg c "$2" '{cwd: $cwd, session_id: "test", tool_name: "Bash", tool_input: {command: $c}}' |
    bare_git env CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$1" "$SCRIPTS/guard-bash.sh"
}
expect_commit_denied() { # $1 project, $2 command, $3 test name, $4 regex on the reason, $5 folder
  local out
  out="$(commit_guard "$1" "$2" "${5:-}" 2>&1)"
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ] && grep -qE -- "${4:-.}" <<<"$out"; then ok "$3"
  else nok "$3" "not denied: $2
$out"; fi
}
expect_commit_allowed() { # $1 project, $2 command, $3 test name, $4 folder
  local out
  out="$(commit_guard "$1" "$2" "${4:-}" 2>&1)"
  if [ -z "$out" ]; then ok "$3"; else nok "$3" "unexpected output for: $2
$out"; fi
}

P="$(new_project commit-identity)"
expect_commit_allowed "$P" "git commit -m x" "commit identity: a commit with user.name and user.email set goes through"

git -C "$P" config --unset user.email
if bare_git git -C "$P" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
  # git builds an address from the account and the host name: the automatic identity.
  expect_commit_denied "$P" "git commit -m x" "commit identity: a commit with no user.email is denied before it exists" 'user\.email is not set'
  expect_commit_denied "$P" "git add -A && git commit -m \"a message\"" "commit identity: ... also after another command"
  expect_commit_denied "$P" "git -C $P commit -m x" "commit identity: ... also with git -C" '' "$TMP"
  expect_commit_denied "$P" "cd .. && git commit -m x" "commit identity: ... also after a cd, from a subfolder" '' "$P/Sources"
  for sub in "merge feature" "pull" "cherry-pick abc123" "revert HEAD" "rebase main" "am patch.mbox"; do
    expect_commit_denied "$P" "git $sub" "commit identity: git ${sub%% *} writes commits too"
  done
  out="$(commit_guard "$P" "git commit -m x")"
  if grep -qF 'git config --global user.email' <<<"$out" && grep -qF 'do not give an identity yourself' <<<"$out" && grep -qF '"guardCommitIdentity\": false' <<<"$out" &&
    ! grep -qF "$(bare_git git -C "$P" var GIT_COMMITTER_IDENT | sed -E 's/.*<(.*)>.*/\1/')" <<<"$out"; then
    ok "commit identity: the reason names the fix and the switch, and prints no account or host name"
  else nok "commit identity: the reason names the fix and the switch, and prints no account or host name" "$out"; fi
  if grep -rqs '"check":"commit identity","kind":"blocked"' "$TMP/data/state"; then
    ok "commit identity: the denied commit is in the catch log"
  else nok "commit identity: the denied commit is in the catch log"; fi
  out="$(bare_git env PATH="$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)"
  expect_row "doctor: no user.email is a warning that names the fix" "$out" WARN 'Git identity' 'user\.email is not set.*git config --global user\.email.*user\.useConfigOnly'
  if ! grep -qF "$(bare_git git -C "$P" var GIT_COMMITTER_IDENT | sed -E 's/.*<(.*)>.*/\1/')" <<<"$out"; then ok "doctor: the automatic identity itself is not printed"
  else nok "doctor: the automatic identity itself is not printed" "$out"; fi
  set_config "$P" '{"guardCommitIdentity":false}'
  expect_commit_allowed "$P" "git commit -m x" "commit identity: guardCommitIdentity false turns the check off"
  set_config "$P" '{}'
  git -C "$P" config user.useConfigOnly true
  expect_commit_allowed "$P" "git commit -m x" "commit identity: where git refuses by itself (user.useConfigOnly) the guard says nothing"
  expect_row "doctor: ... and the doctor says git refuses until the identity is set" \
    "$(bare_git env PATH="$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)" INFO 'Git identity' 'git refuses to commit without one'
  git -C "$P" config --unset user.useConfigOnly
else
  # No host name to build an address from: git itself refuses the commit.
  expect_commit_allowed "$P" "git commit -m x" "commit identity: where git cannot build an identity it refuses by itself, and the guard says nothing"
fi
expect_commit_allowed "$P" "git status" "commit identity: a command that writes no commit goes through"
expect_commit_allowed "$P" "git log --grep commit" "commit identity: the word commit as an argument is not a commit"
expect_commit_allowed "$P" "git commit-graph write" "commit identity: commit-graph is not a commit"
expect_commit_allowed "$P" "git -c user.name=a -c user.email=a@example.com commit -m x" "commit identity: an identity given in the command goes through"
expect_commit_allowed "$P" "GIT_COMMITTER_EMAIL=a@example.com GIT_AUTHOR_EMAIL=a@example.com git commit -m x" "commit identity: ... also given in the environment"
expect_commit_allowed "$P" "git -C \"\$OTHER\" commit -m x" "commit identity: a folder known only at run time is not asked"

# An address that is the host name: what a config copied from the automatic identity holds.
git -C "$P" config user.email someone@some-mac.local
expect_commit_denied "$P" "git commit -m x" "commit identity: an address ending in .local is denied" 'ends in \.local'
expect_row "doctor: an address ending in .local is a warning" \
  "$(bare_git env PATH="$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)" WARN 'Git identity' 'ends in \.local'
git -C "$P" config user.email test@example.com
git -C "$P" config --unset user.name
expect_commit_denied "$P" "git commit -m x" "commit identity: no user.name is denied" 'user\.name is not set'
git -C "$P" config user.name test
expect_row "doctor: an identity that is set passes" \
  "$(bare_git env PATH="$PEFAKES:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$P" 2>&1)" PASS 'Git identity' 'user\.name and user\.email are set'
set_config "$P" '{"guardCommitIdentity":"no"}'
expect_row "doctor: guardCommitIdentity must be true or false" "$(doctor "$P")" FAIL Config 'guardCommitIdentity must be true or false'
rm "$P/.claude/swift-harness.json"
git -C "$P" config --unset user.email
expect_commit_allowed "$P" "git commit -m x" "commit identity: a project without swift-harness.json is left alone"

# The generated verify.sh through the Stop hook: the test that failed first is in what Claude
# reads at the end of the turn (the "Done when" of the field report, item 6).
SV="$(new_project stop-swift-fails)"
sed -e 's|{{XCODE_CONTAINER_FLAG}}||' -e 's|{{SCHEME}}||' -e 's|{{LOCAL_PACKAGES}}|"Packages/Core"|' -e 's|{{PLATFORMS}}|"macOS"|' -e 's|{{IOS_SIMULATOR}}||' "$TEMPLATE" >"$SV/scripts/verify.sh"
mkdir -p "$SV/Packages/Core"
echo '// swift-tools-version:5.9' >"$SV/Packages/Core/Package.swift"
set_config "$SV" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast"}}'
git -C "$SV" add -A && git -C "$SV" commit -qm "the generated verify script"
approve "$SV" >/dev/null
hook session-start.sh "$SV" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$SV/Sources/App.swift"
out="$(jq -nc --arg cwd "$SV" '{cwd: $cwd, session_id: "test"}' | PATH="$SWF:$PATH" CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$SV" "$SCRIPTS/stop-verify.sh" 2>&1)"
expect_result "stop: a test that failed before a long passing target is in what Claude reads" 2 'error: -\[ATests\.OldStyleTests testDoublingTwo\]' "exit=$?
$out"

# ---------- snapshots.pending "collect": images wait instead of failing ----------
# A new or changed image does not fail its test (tests/Snapshot.swift); the approval is asked
# once: before a commit, and by verify.sh full, which fails while images wait.
C="$(new_project snapshots-collect)"
set_config "$C" '{"snapshots":{"pending":"collect"}}'
expect_commit_allowed "$C" "git commit -m x" "collect: with no image waiting a commit goes through"
candidate "$C" Pill-macos-120-light missing new-pill
candidate "$C" Card-macos-200-dark failed new-card
candidate "$C" Row-macos-200-light not-compared other-mac
out="$(commit_guard "$C" "git add -A && git commit -m x")"
if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = ask ] &&
  grep -qE "2 snapshot image\(s\) wait for the user's approval \(Card-macos-200-dark, Pill-macos-120-light\)" <<<"$out" &&
  grep -qF '/swift-harness:approve-snapshots' <<<"$out" && grep -qF 'verify.sh full fails' <<<"$out" && ! grep -qF 'Row-macos' <<<"$out"; then
  ok "collect: a commit asks first while images wait, and names them (an image from another Mac does not wait)"
else nok "collect: a commit asks first while images wait, and names them (an image from another Mac does not wait)" "$out"; fi
out="$(commit_guard "$C" "git -C $C commit -m x" "$TMP")"
[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = ask ] && ok "collect: ... also with git -C from another folder" || nok "collect: ... also with git -C from another folder" "$out"
if grep -rqs '"check":"snapshot images","kind":"asked"' "$TMP/data/state"; then ok "collect: the question is in the catch log"
else nok "collect: the question is in the catch log"; fi
expect_commit_allowed "$C" "git push" "collect: a push does not ask"
expect_commit_allowed "$C" "git commit-graph write" "collect: commit-graph is not a commit"
mkdir -p "$TMP/collect-other"
git -C "$TMP/collect-other" init -q && git -C "$TMP/collect-other" config user.email test@example.com && git -C "$TMP/collect-other" config user.name test
expect_commit_allowed "$C" "cd $TMP/collect-other && git commit -m x" "collect: a commit in another repository does not ask"
set_config "$C" '{}'
expect_commit_allowed "$C" "git commit -m x" "collect: without the setting a commit does not ask (the tests fail instead)"
set_config "$C" '{"snapshots":{"pending":"later"}}'
expect_row "doctor: snapshots.pending is fail or collect" "$(doctor "$C")" FAIL Config 'snapshots\.pending must be "fail".*or "collect"'
set_config "$C" '{"snapshots":{"tolerance":2}}'
expect_row "doctor: snapshots.tolerance is a fraction" "$(doctor "$C")" FAIL Config 'snapshots\.tolerance must be a number from 0 up to 1'
set_config "$C" '{"snapshots":{"pending":"collect","tolerance":0.001}}'
mkdir -p "$C/snapshots"
printf 'old' >"$C/snapshots/Card-macos-200-dark.png"
printf '{"os": "%s", "scale": 2}\n' "$THIS_OS" >"$C/snapshots/Card-macos-200-dark.json"
out="$(doctor "$C")"
expect_row "doctor: snapshots.pending and snapshots.tolerance are known keys" "$out" PASS 'Config keys' 'all known'
expect_row "doctor: images collected are said to wait with their tests passed" "$out" WARN 'Snapshot baselines' 'new image\(s\).*snapshots\.pending is collect: their tests passed'

# verify.sh: full fails while images wait, fast only says so.
V="$(verify_project collect '' '' '"Packages/Core"')"
mkdir -p "$V/Packages/Core" "$V/.claude"
candidate "$V" Pill-macos-120-light missing new-pill
candidate "$V" Row-macos-200-light not-compared other-mac
expect_verify "collect: without the setting verify.sh does not look at the images" 0 'verify full: PASS' "$(run_verify "$V" full)"
printf '{"snapshots":{"pending":"collect"}}\n' >"$V/.claude/swift-harness.json"
out="$(run_verify "$V" full)"
expect_verify "collect: verify.sh full fails while an image waits" 1 'verify full: FAIL' "$out"
expect_result "collect: ... and names it, not the one from another Mac" 1 '^snapshot waiting for approval: Pill-macos-120-light$' "$out" 'Row-macos'
out="$(run_verify "$V" fast)"
expect_verify "collect: verify.sh fast passes and says images wait" 0 '1 image\(s\) wait \(fast does not fail on them; full does\)' "$out"
if grep -qF 'snapshot waiting for approval: ' "$SCRIPTS/mutate.sh"; then ok "collect: check-sensitivity credits the snapshot check with the waiting line of verify.sh"
else nok "collect: check-sensitivity credits the snapshot check with the waiting line of verify.sh"; fi

# The Stop hook: the images are not checked, and the user is told.
SC="$(new_project stop-collect)"
set_config "$SC" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast"},"snapshots":{"pending":"collect"}}'
git -C "$SC" add -A && git -C "$SC" commit -qm collect
approve "$SC" >/dev/null
hook session-start.sh "$SC" '{"source":"startup"}' >/dev/null
echo 'let app = 3' >"$SC/Sources/App.swift"
candidate "$SC" Pill-macos-120-light missing new-pill
out="$(hook stop-verify.sh "$SC" 2>&1)"
expect_result "collect: the end of the turn tells the user that waiting images are not checked" 0 "not checked: snapshot images \(1 snapshot image\(s\) wait for the user's approval \(Pill-macos-120-light\): /swift-harness:approve-snapshots\)" "exit=$?
$out"
sc_state="$TMP/data/state/$(printf '%s' "$(cd "$SC" && pwd -P)" | shasum | cut -c1-16)"
if [ "$(jq -r '.checks[] | select(.name == "snapshot images") | .result' "$sc_state/evidence.json" 2>/dev/null)" = "not checked" ] &&
  [ "$(jq -r .outcome "$sc_state/evidence.json")" = passed ]; then
  ok "collect: ... and the record has them as not checked, next to the verify command that passed"
else nok "collect: ... and the record has them as not checked, next to the verify command that passed" "$(cat "$sc_state/evidence.json" 2>&1)"; fi

# A project-wide tolerance: raising it is a weaker check.
WT="$(new_project weaken-snapshot-tolerance)"
set_config "$WT" '{"snapshots":{"tolerance":0.001}}'
git -C "$WT" add -A && git -C "$WT" commit -qm tolerance
hook session-start.sh "$WT" '{"source":"startup"}' >/dev/null
set_config "$WT" '{"snapshots":{"tolerance":0.01}}'
out="$(hook weaken-watch.sh "$WT" 2>&1)"
expect_result "collect: raising snapshots.tolerance is reported as a weaker check" 0 '\.claude/swift-harness\.json: tolerance raised \(0\.001 -> 0\.01\)' "exit=$?
$out"
hook session-start.sh "$WT" '{"source":"startup"}' >/dev/null
set_config "$WT" '{"snapshots":{"tolerance":0.0001}}'
expect_result "collect: lowering it says nothing" 0 '^exit=0$' "exit=$?
$(hook weaken-watch.sh "$WT" 2>&1)" 'swift-harness'
if grep -qF '"tolerance"' "$TEMPLATES/tests/Snapshot.swift" && grep -qF 'tolerance ?? (settings["tolerance"]' "$TEMPLATES/tests/Snapshot.swift"; then
  ok "collect: Snapshot.verify takes the project's tolerance when a test passes none"
else nok "collect: Snapshot.verify takes the project's tolerance when a test passes none"; fi

# snapshots.approveNew: a new image recorded by its test as its baseline is told once, not
# reported as unapproved; anything else in the folder still is.
AN="$(new_project approve-new)"
set_config "$AN" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none","snapshots":{"approveNew":true}}'
mkdir -p "$AN/snapshots"
printf 'old' >"$AN/snapshots/Old-macos-80-light.png"
printf '{"os": "%s", "approvedFrom": "missing"}\n' "$THIS_OS" >"$AN/snapshots/Old-macos-80-light.json"
git -C "$AN" add -A && git -C "$AN" commit -qm approve-new
hook session-start.sh "$AN" '{"source":"startup"}' >/dev/null
for n in Card-macos-80-light Card-macos-80-dark; do
  printf 'new %s' "$n" >"$AN/snapshots/$n.png"
  printf '{"os": "%s", "approvedFrom": "new", "test": "Tests/AppTests/SnapTests.swift"}\n' "$THIS_OS" >"$AN/snapshots/$n.json"
done
out="$(swatch "$AN")"
expect_result "approveNew: new images recorded by their test are told in one line, not as unapproved" 0 '2 new snapshot image\(s\) recorded as baselines with no approval \(snapshots\.approveNew is true\): Card-macos-80-dark, Card-macos-80-light\.' "$out" 'without /swift-harness:approve-snapshots'
if jq -e --arg p "$AN/snapshots/Card-macos-80-dark.png" '.hookSpecificOutput.additionalContext | contains("Look at each image") and contains($p) and contains("clipped")' >/dev/null <<<"$(tail -n +2 <<<"$out")"; then
  ok "approveNew: ... and the agent is given the new images to look at, for defects"
else nok "approveNew: ... and the agent is given the new images to look at, for defects" "$out"; fi
expect_result "approveNew: ... once" 0 '^exit=0$' "$(swatch "$AN")" 'swift-harness'
printf 'changed' >"$AN/snapshots/Old-macos-80-light.png"
printf 'hand' >"$AN/snapshots/Hand-macos-80-light.png"
printf '{"os": "%s"}\n' "$THIS_OS" >"$AN/snapshots/Hand-macos-80-light.json"
out="$(swatch "$AN")"
expect_result "approveNew: a changed baseline and a new image not recorded as new are still reported" 0 'changed: snapshots/Hand-macos-80-light\.png' "$out"
expect_result "approveNew: ... the changed one too" 0 'changed: snapshots/Old-macos-80-light\.png' "$out" 'Card-macos'
git -C "$AN" checkout -q -- snapshots && rm -f "$AN"/snapshots/Hand-* "$AN"/snapshots/Card-*
set_config "$AN" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none"}'
hook session-start.sh "$AN" '{"source":"startup"}' >/dev/null
printf 'new' >"$AN/snapshots/Card-macos-80-light.png"
printf '{"os": "%s", "approvedFrom": "new"}\n' "$THIS_OS" >"$AN/snapshots/Card-macos-80-light.json"
expect_result "approveNew: off, an image marked new is reported like any other" 0 'changed: snapshots/Card-macos-80-light\.png' "$(swatch "$AN")"
rm -f "$AN"/snapshots/Card-*
set_config "$AN" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none","snapshots":{"approveNew":true}}'
WN="$(new_project weaken-approve-new)"
hook session-start.sh "$WN" '{"source":"startup"}' >/dev/null
set_config "$WN" '{"snapshots":{"approveNew":true}}'
expect_result "approveNew: turning it on is reported as a weaker check" 0 '\.claude/swift-harness\.json: snapshots\.approveNew turned on' "exit=0
$(hook weaken-watch.sh "$WN" 2>&1)"
# A session that started with nothing to count: the first weakening is still found.
WE="$(new_project weaken-empty-start)"
hook session-start.sh "$WE" '{"source":"startup"}' >/dev/null
printf '// swiftlint:disable force_cast\nlet app = 1\n' >"$WE/Sources/App.swift"
expect_result "weaken: a session that started with nothing to count still reports the first weakening" 0 'Sources/App\.swift: 1 swiftlint:disable added' "exit=0
$(hook weaken-watch.sh "$WE" 2>&1)"
mkdir -p "$AN/Tests/AppTests"
printf 'enum Snapshot {\n    static let candidates = ""\n}\n' >"$AN/Tests/AppTests/Snapshot.swift"
out="$(doctor "$AN")"
expect_row "doctor: approveNew with a Snapshot.swift that does not read it is a warning" "$out" WARN 'New snapshots' 'Tests/AppTests/Snapshot\.swift does not read it'
expect_row "doctor: approveNew is a known key" "$out" PASS 'Config keys' 'all known'
cp "$TEMPLATES/tests/Snapshot.swift" "$AN/Tests/AppTests/Snapshot.swift"
expect_row "doctor: approveNew with the current helper is said" "$(doctor "$AN")" INFO 'New snapshots' 'becomes its baseline in its test'
set_config "$AN" '{"snapshots":{"approveNew":"yes"}}'
expect_row "doctor: approveNew must be a boolean" "$(doctor "$AN")" FAIL Config 'snapshots\.approveNew must be true'
if grep -qF 'approveNew ?? (settings["approveNew"] as? Bool == true)' "$TEMPLATES/tests/Snapshot.swift"; then
  ok "approveNew: Snapshot.verify reads it from the project config"
else nok "approveNew: Snapshot.verify reads it from the project config"; fi

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
# The check's own switch is listed with the settings. With no security.enabled key in the config
# its value is the default: the status says so, and the recorded line stays as it was approved.
expect_result "security: a default shown with the settings is called the default" 0 '^  \.claude/swift-harness\.json: security\.enabled = true \(the default: the file has no security\.enabled key\)$' "exit=0
$out"
if [ "$(sec state --project "$P" | grep -F 'security.enabled')" = '.claude/swift-harness.json: security.enabled = true' ]; then ok "security: ... and the recorded line is unchanged"
else nok "security: ... and the recorded line is unchanged" "$(sec state --project "$P" | grep -F 'security.enabled')"; fi
before="$(printf '%s' "$out" | sed -n 's/^Digest: //p')"
jq '. + {security: {enabled: true}}' "$P/.claude/swift-harness.json" >"$TMP/sj" && mv "$TMP/sj" "$P/.claude/swift-harness.json"
out2="$(sec --status --project "$P")"
expect_result "security: a value written in the config is not called the default" 0 '^  \.claude/swift-harness\.json: security\.enabled = true$' "exit=0
$out2" 'the default'
if [ "$before" = "$(printf '%s' "$out2" | sed -n 's/^Digest: //p')" ]; then ok "security: ... and the digest to approve is the same either way"
else nok "security: ... and the digest to approve is the same either way"; fi
git -C "$P" checkout -q -- .claude/swift-harness.json
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

# ---------- approvals on a rename (the second field report on 1.11) ----------
# One rename of a whole project set off three approvals and two notices, each approval with a
# second question. A move is said as a move, an approval asks only what needs a decision, and
# one command clears whatever waits.

state_dir_of() { printf '%s/data/state/%s' "$TMP" "$(printf '%s' "$(cd "$1" && pwd -P)" | shasum | cut -c1-16)"; }
R="$(sec_project rename-security)"
hook session-start.sh "$R" '{"source":"startup"}' >/dev/null
d="$(sec --status --project "$R" | sed -n 's/^Digest: //p')"
out="$(sec --approve "$d" --project "$R")"
expect_result "rename: the approval counts the settings the listing shows, the switch apart" 0 '^Approved: 4 setting\(s\) recorded as the security baseline, and security\.enabled\.$' "exit=0
$out"
git -C "$R" mv App NewApp
git -C "$R" mv NewApp/App.entitlements NewApp/NewApp.entitlements
perl -pi -e 's#App/App\.entitlements#NewApp/NewApp.entitlements#' "$R/App.xcodeproj/project.pbxproj"
out="$(sec --status --project "$R")"
if grep -qF 'Moved to another file, values unchanged (a rename):' <<<"$out" &&
  grep -qF '  App/App.entitlements -> NewApp/NewApp.entitlements: 2 setting(s) moved' <<<"$out" &&
  grep -qF '  App.xcodeproj/project.pbxproj: the entitlements path follows the moved entitlements file' <<<"$out" &&
  grep -qF 'No setting changed its value.' <<<"$out" && grep -qF 'Nothing to decide: no change weakens protection.' <<<"$out" &&
  ! grep -qE '^[+-] ' <<<"$out"; then
  ok "rename: the security status shows moved settings one line per file, with no +/- pair"
else nok "rename: the security status shows moved settings one line per file, with no +/- pair" "$out"; fi
echo 'let app = 2' >"$R/Sources/App.swift"
out="$(rstop "$R")"
expect_result "rename: by default a move waits for the user, said as a move with nothing relaxed" 2 'Nothing was relaxed\. The user records the new paths by typing /swift-harness:approve-security \(no question to answer\)' "$out" '^\+ '
d="$(sec --status --project "$R" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$R" >/dev/null
expect_result "rename: ... and once approved the turn passes" 0 '^exit=0' "$(rstop "$R")" 'Security settings'

# security.moves "pass": a move is no change. Setting it is itself a change to approve.
set_config "$R" '{"format":"none","lint":"none","verify":{"enabled":false,"maxAttempts":20},"security":{"moves":"pass"}}'
out="$(sec --status --project "$R")"
expect_result "rename: security.moves pass is a change that weakens protection, to decide" 0 'To decide: these changes weaken protection:' "exit=0
$out"
expect_result "rename: ... named" 0 '^  \+ \.claude/swift-harness\.json: security\.moves = pass$' "exit=0
$out"
d="$(sec --status --project "$R" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$R" >/dev/null
git -C "$R" add -A && git -C "$R" commit -qm renamed
git -C "$R" mv NewApp Renamed
git -C "$R" mv Renamed/NewApp.entitlements Renamed/Renamed.entitlements
perl -pi -e 's#NewApp/NewApp\.entitlements#Renamed/Renamed.entitlements#' "$R/App.xcodeproj/project.pbxproj"
echo 'let app = 3' >"$R/Sources/App.swift"
expect_result "rename: with security.moves pass a move passes the turn" 0 '^exit=0' "$(rstop "$R")" 'Security settings'
plutil -replace 'com\.apple\.security\.cs\.disable-library-validation' -bool YES "$R/Renamed/Renamed.entitlements"
echo 'let app = 4' >"$R/Sources/App.swift"
out="$(rstop "$R")"
expect_result "rename: ... and a real change in a moved file still blocks, alone in the list" 2 '^\+ Renamed/Renamed\.entitlements: com\.apple\.security\.cs\.disable-library-validation = true$' "$out" 'app-sandbox'
expect_result "rename: the failure header names only the failing check" 2 '^Verification failed \(attempt [0-9] of 20\): security settings$' "$out"
if grep -qF 'Nothing to decide' "$SKILLS/approve-security/SKILL.md" && grep -qF 'do not ask again for what weakens nothing' "$SKILLS/approve-security/SKILL.md"; then
  ok "rename: approve-security asks only when something weakens protection"
else nok "rename: approve-security asks only when something weakens protection"; fi
expect_row "doctor: security.moves is approve or pass" "$(set_config "$R" '{"security":{"moves":"sometimes"}}'; doctor "$R")" FAIL Config 'security\.moves must be "approve"'

# The verify approval keeps the text it approved: the next status shows what changed since.
V2="$(new_project rename-verify)"
printf 'source scripts/helper.sh\n' >>"$V2/scripts/verify.sh"
printf 'name=OldApp\n' >"$V2/scripts/helper.sh"
set_config "$V2" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast","inputs":["scripts/helper.sh"]}}'
git -C "$V2" add -A && git -C "$V2" commit -qm inputs
approve "$V2" >/dev/null
hook session-start.sh "$V2" '{"source":"startup"}' >/dev/null
perl -pi -e 's/fake verify output/fake check output/' "$V2/scripts/verify.sh"
perl -pi -e 's/OldApp/NewApp/' "$V2/scripts/helper.sh"
out="$(approval "$V2" --status)"
expect_result "verify diff: the status names the files changed since the approval" 0 'Changes since the last approval in this folder \(scripts/helper\.sh \(\+1 -1 lines\), scripts/verify\.sh \(\+1 -1 lines\);' "exit=0
$out"
expect_result "verify diff: ... and shows the lines" 0 '^\+echo "fake check output"$' "exit=0
$out"
expect_result "verify diff: ... and not the lines that did not change" 0 '^-name=OldApp$' "exit=0
$out" '^[+-]exit '
echo 'let app = 5' >"$V2/Sources/App.swift"
out="$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$V2" 2>&1)"
expect_result "verify diff: the end-of-turn notice says which files changed and by how much" 0 'changed since you last approved it \(changed: scripts/helper\.sh \(\+1 -1 lines\), scripts/verify\.sh \(\+1 -1 lines\)\)' "exit=$?
$out"
rm -rf "$(state_dir_of "$V2")/verify-approved-text"
expect_result "verify diff: an approval that kept no copy says the changes are not available" 0 'Changes since the last approval: not available' "exit=0
$(approval "$V2" --status)"
approve "$V2" >/dev/null
approval "$V2" --revoke >/dev/null
if [ ! -e "$(state_dir_of "$V2")/verify-approved-text" ]; then ok "verify diff: revoking removes the copy"
else nok "verify diff: revoking removes the copy"; fi
if grep -qF 'flag only what the added lines' "$SKILLS/approve-verify/SKILL.md"; then ok "verify diff: the skill flags only what the changed lines bring"
else nok "verify diff: the skill flags only what the changed lines bring"; fi

# The failure header: the failing checks only, the ones that passed on their own line. And when
# more than one kind of approval waits, the single command is named.
H="$(sec_project rename-header)"
set_config "$H" '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast","maxAttempts":20}}'
git -C "$H" add -A && git -C "$H" commit -qm verify
approve "$H" >/dev/null
hook session-start.sh "$H" '{"source":"startup"}' >/dev/null
d="$(sec --status --project "$H" | sed -n 's/^Digest: //p')"
sec --approve "$d" --project "$H" >/dev/null
entitle "$H" 'com\.apple\.security\.cs\.allow-jit' YES
echo 'let app = 6' >"$H/Sources/App.swift"
out="$(rstop "$H")"
expect_result "header: a failure names the failing check" 2 '^Verification failed \(attempt 1 of 20\): security settings$' "$out"
expect_result "header: ... and the passed ones apart" 2 '^Passed: scripts/verify\.sh fast$' "$out"
expect_result "header: one kind of approval waiting does not name the single command" 2 'security settings' "$out" 'swift-harness:approve clears'
echo '# changed' >>"$H/scripts/verify.sh"
echo 'let app = 7' >"$H/Sources/App.swift"
out="$(rstop "$H")"
expect_result "approve: with two kinds of approval waiting, the block names the single command" 2 'More than one approval waits: /swift-harness:approve clears them in one go\. Tell the user; do not run it yourself\.' "$out"
if grep -qx 'disable-model-invocation: true' "$SKILLS/approve/SKILL.md" && grep -qF 'approve-verify.sh" --approve' "$SKILLS/approve/SKILL.md" &&
  grep -qF 'security.sh" --approve' "$SKILLS/approve/SKILL.md" && grep -qF 'snapshots.sh" --approve' "$SKILLS/approve/SKILL.md" &&
  grep -qF 'One question at most' "$SKILLS/approve/SKILL.md"; then
  ok "approve: one command for the three approvals, run by the user only, with one question at most"
else nok "approve: one command for the three approvals, run by the user only, with one question at most"; fi
if grep -qF 'are `all`, or name images, the user decided' "$SKILLS/approve-snapshots/SKILL.md"; then ok "approve: approve-snapshots all asks no question"
else nok "approve: approve-snapshots all asks no question"; fi

# A protected file moved: said as a move, content unchanged.
M="$(new_project rename-protected)"
hook session-start.sh "$M" '{"source":"startup"}' >/dev/null
git -C "$M" mv Sources/Audio Sources/Sound
out="$(hook protected-watch.sh "$M" 2>&1)"
expect_result "protected move: a file moved out of the protected paths is said as a move" 0 'moved out of the protected paths, content unchanged: Sources/Audio/Engine\.swift -> Sources/Sound/Engine\.swift' "exit=0
$out" 'deleted: '
expect_result "protected move: ... and the notice says it is no longer protected" 0 'still names the old place, so the files at the new one are no longer protected' "exit=0
$out"
M2="$(new_project rename-protected-inside)"
set_config "$M2" '{"protectedPaths":["Sources/Audio/","Sources/Sound/"]}'
hook session-start.sh "$M2" '{"source":"startup"}' >/dev/null
git -C "$M2" mv Sources/Audio Sources/Sound
out="$(hook protected-watch.sh "$M2" 2>&1)"
expect_result "protected move: a move inside the protected paths is said as a move, not a change" 0 '  moved, content unchanged: Sources/Audio/Engine\.swift -> Sources/Sound/Engine\.swift' "exit=0
$out" '[^n]changed: |deleted: |no longer protected'
echo 'let engine = 2' >"$M2/Sources/Sound/Engine.swift"
expect_result "protected move: an edit after the move is still a change" 0 'changed: Sources/Sound/Engine\.swift' "exit=0
$(hook protected-watch.sh "$M2" 2>&1)"
if grep -qF 'move the file with `git mv`, content unchanged, and name its new place in `protectedPaths`' "$TEMPLATES/CLAUDE.md"; then
  ok "protected move: the setup's rules say how to move a protected file"
else nok "protected move: the setup's rules say how to move a protected file"; fi

# A lint exclusion that follows a renamed folder is not a weaker check.
X="$(new_project rename-lint)"
printf 'excluded:\n  - OldApp/Generated\n' >"$X/.swiftlint.yml"
git -C "$X" add -A && git -C "$X" commit -qm lint
hook session-start.sh "$X" '{"source":"startup"}' >/dev/null
printf 'excluded:\n  - NewApp/Generated\n' >"$X/.swiftlint.yml"
expect_result "rename: a lint exclusion that follows a renamed folder is not a weaker check" 0 '^exit=0$' "exit=0
$(hook weaken-watch.sh "$X" 2>&1)" 'excluded from lint'
printf 'excluded:\n  - NewApp/Generated\n  - Other/Stuff\n' >"$X/.swiftlint.yml"
expect_result "rename: ... a new exclusion still is" 0 'Other/Stuff excluded from lint' "exit=0
$(hook weaken-watch.sh "$X" 2>&1)" 'NewApp/Generated excluded'
# A test file moved and edited in the same change: compared as one file by its name.
Y="$(new_project rename-tests)"
mkdir -p "$Y/OldApp/Tests"
printf 'import XCTest\nfinal class PlayerTests: XCTestCase {\n    func testPlays() { XCTAssertTrue(true) }\n    func testStops() { XCTAssertTrue(true) }\n    func testSeeks() { XCTAssertTrue(true) }\n}\n' >"$Y/OldApp/Tests/PlayerTests.swift"
git -C "$Y" add -A && git -C "$Y" commit -qm tests
hook session-start.sh "$Y" '{"source":"startup"}' >/dev/null
mkdir -p "$Y/NewApp"
git -C "$Y" mv OldApp/Tests NewApp/Tests
perl -ni -e 'print unless /testSeeks/' "$Y/NewApp/Tests/PlayerTests.swift"
out="$(hook weaken-watch.sh "$Y" 2>&1)"
expect_result "rename: a test file moved and edited is compared as one file" 0 'NewApp/Tests/PlayerTests\.swift: 1 test removed \(3 -> 2\)' "exit=0
$out" 'file removed'

# ---------- /swift-harness:configure, verify.when, recap ----------

cfg() { local out code; out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/configure.sh" "$@" 2>&1)"; code=$?; printf 'exit=%s\n%s' "$code" "$out"; }
CF="$(new_project configure)"
out="$(cfg --show --project "$CF")"
if [ "$(tail -n +2 <<<"$out" | paste -sd'|' -)" = 'strictness: normal|stop: turn|snapshots: fail|new: wait|tolerance: 0|approvals: weakening|moves: approve|direction: mac|docs: blocking|recap: off' ]; then
  ok "configure: --show gives the default answers for a fresh config"
else nok "configure: --show gives the default answers for a fresh config" "$out"; fi
out="$(cfg --apply --project "$CF" strictness=strict stop=commit snapshots=collect new=accept tolerance=.001 approvals=always moves=pass direction=porting docs=observed recap=md)"
if jq -e '.lintBlocking == true and .verify.maxAttempts == 5 and .verify.when == "commit" and .verify.command == "scripts/verify.sh fast"
    and .snapshots == {pending: "collect", approveNew: true, tolerance: 0.001} and .approvals.ask == "always" and .security.moves == "pass"
    and .porting.direction == "porting" and .docs == {blocking: false} and .recap == "md" and .protectedPaths == ["Sources/Audio/"]' "$CF/.claude/swift-harness.json" >/dev/null; then
  ok "configure: each answer is written as its keys, and the other keys stay"
else nok "configure: each answer is written as its keys, and the other keys stay" "$(cat "$CF/.claude/swift-harness.json")"; fi
expect_result "configure: it says what it wrote" 0 '^  stop: commit$' "$out"
expect_result "configure: ... and what follows, with the step left to the user" 0 'moves=pass weakens the security check.*approve-security' "$out"
out="$(doctor "$CF")"
expect_row "configure: the doctor knows every key it writes" "$out" PASS 'Config keys' 'all known'
expect_row "doctor: verify.when commit is said" "$out" INFO 'Checks run' 'before a commit'
expect_row "doctor: a port under way with no ratchet is a warning" "$out" WARN 'Porting ratchet' 'porting\.direction is "porting" but no module is recorded'
cfg --apply --project "$CF" strictness=normal stop=turn snapshots=fail new=wait tolerance=0 approvals=weakening moves=approve direction=mac docs=blocking recap=off >/dev/null
if jq -e '. == {verify: {command: "scripts/verify.sh fast"}, protectedPaths: ["Sources/Audio/"]}' "$CF/.claude/swift-harness.json" >/dev/null; then
  ok "configure: default answers remove their keys, and empty objects go"
else nok "configure: default answers remove their keys, and empty objects go" "$(cat "$CF/.claude/swift-harness.json")"; fi
expect_result "configure: the same answers again change nothing" 0 'Nothing changed' "$(cfg --apply --project "$CF" stop=turn)"
before="$(cat "$CF/.claude/swift-harness.json")"
expect_result "configure: a wrong answer is refused" 2 "'later' is not an answer to stop" "$(cfg --apply --project "$CF" recap=md stop=later)"
expect_result "configure: an unknown question is refused" 2 "no question named 'colour'" "$(cfg --apply --project "$CF" colour=blue)"
expect_result "configure: a tolerance over 1 is refused" 2 'not an answer to tolerance' "$(cfg --apply --project "$CF" tolerance=2)"
[ "$before" = "$(cat "$CF/.claude/swift-harness.json")" ] && ok "configure: a refused answer writes nothing, not even the valid ones" || nok "configure: a refused answer writes nothing, not even the valid ones" "$(cat "$CF/.claude/swift-harness.json")"
for k in strictness=light approvals=always recap=text; do cfg --apply --project "$CF" "$k" >/dev/null; done
expect_result "configure: --show reads the answers back" 0 'strictness: light' "$(cfg --show --project "$CF")"
set_config "$CF" '{"verify":{"when":"sometimes"},"approvals":{"ask":"never"},"recap":"pdf","porting":{"direction":"android"}}'
out="$(doctor "$CF")"
for want in 'verify\.when must be' 'approvals\.ask must be' 'recap must be' 'porting\.direction must be'; do
  expect_row "doctor: a wrong value is named ($want)" "$out" FAIL Config "$want"
done
if grep -qx 'disable-model-invocation: true' "$SKILLS/configure/SKILL.md" && grep -qF 'configure.sh" --apply' "$SKILLS/configure/SKILL.md"; then
  ok "configure: only the user runs the skill, and it writes through the script"
else nok "configure: only the user runs the skill, and it writes through the script"; fi
missing=""
for f in approve approve-security approve-verify approve-snapshots; do grep -qF '`approvals.ask`' "$SKILLS/$f/SKILL.md" || missing="$missing $f"; done
[ -z "$missing" ] && ok "configure: every approval skill reads approvals.ask" || nok "configure: every approval skill reads approvals.ask" "$missing"

# verify.when "commit": nothing at the end of a turn, and a commit waits for the checks.
WC="$(new_project when-commit)"
set_config "$WC" '{"verify":{"command":"scripts/verify.sh fast","when":"commit"},"format":"none","lint":"none"}'
git -C "$WC" add -A && git -C "$WC" commit -qm when
approve "$WC" >/dev/null
hook session-start.sh "$WC" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$WC/Sources/App.swift"
WLOG="$TMP/when-commit.log"
: >"$WLOG"
out="$(FAKE_VERIFY_LOG="$WLOG" hook stop-verify.sh "$WC" 2>&1)"
if [ -z "$out" ] && [ ! -s "$WLOG" ] && [ "$(jq -r '.checks[0].detail' "$(state_dir_of "$WC")/evidence.json")" = 'verify.when is commit: the checks run before a commit' ]; then
  ok "when commit: the end of a turn runs nothing, and the record says why"
else nok "when commit: the end of a turn runs nothing, and the record says why" "$out $(cat "$WLOG") $(cat "$(state_dir_of "$WC")/evidence.json" 2>&1)"; fi
expect_commit_denied "$WC" "git add -A && git commit -m x" "when commit: a commit before the checks passed is refused, naming check.sh" 'have not passed on this code yet.*CLAUDE_PLUGIN_DATA=.{0,2}[^ ]*/data.{0,2} .{0,2}[^ ]*check\.sh.{0,2} --project'
expect_commit_allowed "$WC" "git push" "when commit: a push is not a commit"
FAKE_VERIFY_LOG="$WLOG" FAKE_VERIFY_EXIT=1 CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$WC" --agent claude >/dev/null 2>&1
expect_commit_denied "$WC" "git commit -m x" "when commit: after a failed check the commit is refused, saying it failed" 'the checks failed on this code'
echo 'let app = 3' >"$WC/Sources/App.swift"
FAKE_VERIFY_LOG="$WLOG" CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$WC" --agent claude >/dev/null 2>&1
expect_commit_allowed "$WC" "git add -A && git commit -m x" "when commit: once check.sh passed on this code, the commit goes through"
echo 'let app = 4' >"$WC/Sources/App.swift"
expect_commit_denied "$WC" "git commit -am x" "when commit: an edit after the check needs it again" 'have not passed'

# An older install of the plugin loaded while a newer one is installed for the project.
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
ours="$(jq -r .version "$SCRIPTS/../.claude-plugin/plugin.json")"
installs() { jq -n --arg root "$1" --arg v "$2" --arg ours "$ours" '{version: 2, plugins: {"swift-harness@swift-harness": [
  {scope: "user", installPath: "/x/\($ours)", version: $ours},
  {scope: "project", projectPath: $root, installPath: "/x/\($v)", version: $v}]}}' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }
installs "$WC" 99.0.0
out="$(hook session-start.sh "$WC" '{"source":"startup"}')"
expect_result "install: an older install loaded while a newer one is installed for the project is said" 0 "this session runs swift-harness $ours, but 99\.0\.0 is installed for this project \(project scope\).*start a new session" "exit=0
$out"
expect_row "doctor: ... and the doctor warns" "$(doctor "$WC")" WARN 'Plugin install' "runs swift-harness $ours, but 99\.0\.0"
installs "$TMP/elsewhere" 99.0.0
expect_result "install: a newer install for another project is not this one" 0 '^exit=0' "exit=0
$(hook session-start.sh "$WC" '{"source":"startup"}')" 'is installed for this project'
installs "$WC" 1.0.0
expect_result "install: an older install for the project is not a problem" 0 '^exit=0' "exit=0
$(hook session-start.sh "$WC" '{"source":"startup"}')" 'is installed for this project'
printf 'not json' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
expect_result "install: a list that cannot be read says nothing" 0 '^exit=0' "exit=0
$(hook session-start.sh "$WC" '{"source":"startup"}')" 'is installed for this project'
rm -f "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"

# The recap: a line for the user at the end of each turn whose checks ran, and a file if asked.
RC="$(new_project recap)"
set_config "$RC" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none","recap":"text"}'
git -C "$RC" add -A && git -C "$RC" commit -qm recap
approve "$RC" >/dev/null
hook session-start.sh "$RC" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$RC/Sources/App.swift"
out="$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$RC" 2>&1)"
expect_result "recap: text gives every check and its result in one line" 0 'checks this turn \(passed\): scripts/verify\.sh fast: passed[;.]' "exit=$?
$out" 'Recap: '
set_config "$RC" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none","recap":"md"}'
echo 'let app = 3' >"$RC/Sources/App.swift"
out="$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$RC" 2>&1)"
expect_result "recap: md gives the path of the file" 0 "Recap: $RC/\.build/swift-harness/recap\.md" "exit=$?
$out"
if grep -qF '| scripts/verify.sh fast | passed |' "$RC/.build/swift-harness/recap.md"; then ok "recap: ... which holds a table of the checks"
else nok "recap: ... which holds a table of the checks" "$(cat "$RC/.build/swift-harness/recap.md" 2>&1)"; fi
set_config "$RC" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none","recap":"html"}'
echo 'let app = 4' >"$RC/Sources/App.swift"
FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$RC" >/dev/null 2>&1
if grep -qF '<td>scripts/verify.sh fast</td><td>passed</td>' "$RC/.build/swift-harness/recap.html" && ! grep -qiE '<script|https?://' "$RC/.build/swift-harness/recap.html"; then
  ok "recap: html is a static page with the same table"
else nok "recap: html is a static page with the same table" "$(cat "$RC/.build/swift-harness/recap.html" 2>&1)"; fi
set_config "$RC" '{"verify":{"command":"scripts/verify.sh fast"},"format":"none","lint":"none"}'
echo 'let app = 5' >"$RC/Sources/App.swift"
expect_result "recap: off by default, a passing turn says nothing" 0 '^exit=0$' "exit=0
$(FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$RC" 2>&1)" 'checks this turn'

# docs.blocking false now applies to the built-in docs check too.
DO="$(new_project docs-observed)"
printf '# App\n' >"$DO/CLAUDE.md"
set_config "$DO" '{"verify":{"enabled":false},"format":"none","lint":"none","docs":{"blocking":false}}'
git -C "$DO" add -A && git -C "$DO" commit -qm docs
hook session-start.sh "$DO" '{"source":"startup"}' >/dev/null
printf '# App\n\nSee [the plan](docs/PLAN.md).\n' >"$DO/CLAUDE.md"
out="$(hook docs-watch.sh "$DO" 2>&1)"
expect_result "docs observed: a broken reference is told, and the turn is not blocked" 0 'docs\.blocking is false, so the turn was not stopped' "exit=$?
$out"
expect_result "docs observed: ... once per set" 0 '^exit=0$' "exit=$?
$(hook docs-watch.sh "$DO" 2>&1)" 'swift-harness'

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
expect_result "protected-watch: a protected file changed by a shell command is shown to the user" 0 'systemMessage.*changed since this session started.*changed: Sources/Audio/Engine\.swift' "$out"
expect_result "protected-watch: the notice does not claim this session made the change (#135)" 0 'changed: Sources' "$out" 'in this session without'
expect_result "protected-watch: an uncommitted change names no commit (#135)" 0 'changed: Sources' "$out" 'committed in'
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

# #135: another session (or agent) on the same checkout edits and commits a protected file.
P="$(new_project protected-commit)"
git -C "$P" add -A && git -C "$P" commit -qm "start" >/dev/null 2>&1
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
echo 'let engine = 5' >>"$P/Sources/Audio/Engine.swift"
git -C "$P" commit -qam "Engine from another session" >/dev/null 2>&1
c1="$(git -C "$P" rev-parse --short HEAD)"
out="$(pwatch "$P")"
expect_result "protected-watch: a committed change names its commit (#135)" 0 "changed: Sources/Audio/Engine\\.swift \\(committed in $c1: Engine from another session\\)" "$out"
expect_result "protected-watch: a committed change says it may come from another session (#135)" 0 'another session or agent' "$out"
echo 'let engine = 6' >>"$P/Sources/Audio/Engine.swift"
expect_result "protected-watch: a committed file changed again says so (#135)" 0 "changed: Sources/Audio/Engine\\.swift \\(committed in $c1: Engine from another session; changed again since, not committed\\)" "$(pwatch "$P")"
git -C "$P" checkout -q -- Sources/Audio/Engine.swift
git -C "$P" rm -q Sources/Audio/Engine.swift && git -C "$P" commit -qm "Engine removed" >/dev/null 2>&1
c2="$(git -C "$P" rev-parse --short HEAD)"
expect_result "protected-watch: a committed deletion names its commit (#135)" 0 "deleted: Sources/Audio/Engine\\.swift \\(committed in $c2: Engine removed\\)" "$(pwatch "$P")"

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
  grep -qF 'working-directory: tests/fixtures/layout-audit' "$HERE/../.github/workflows/ci.yml" &&
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

# ---------- a PARTIAL verification stays partial (SH160-01) ----------

P="$(new_project partial)"
printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_RESULT_LINE:-}"\nexit "${FAKE_RESULT_EXIT:-0}"\n' >"$P/scripts/verify.sh"
git -C "$P" add -A && git -C "$P" commit -qm "verify that prints a given result line"
approve "$P" >/dev/null
hook session-start.sh "$P" '{"source":"startup"}' >/dev/null
S_P="$(state_of "$P")"
echo 'let app = 2' >"$P/Sources/App.swift"
out="$(FAKE_RESULT_LINE='swift-harness-result/1: partial; checked: macOS; tested: macOS; not checked: iOS' gate_stop "$P")"
expect_result "partial: a PARTIAL pass does not block, and the user is told what was not checked" 0 '"systemMessage": "swift-harness: .*passed on this code, but iOS was not checked' "$out"
expect_result "partial: Claude is told too, as context that does not block" 0 '"hookEventName": "Stop".*"additionalContext": ".*iOS was not checked' "$(head -1 <<<"$out")
$(tail -n +2 <<<"$out" | tr '\n' ' ')"
expect_result "partial: the same code is not announced twice" 0 '^exit=0$' "$(FAKE_RESULT_LINE='swift-harness-result/1: partial; checked: macOS; tested: macOS; not checked: iOS' gate_stop "$P")"
if [ "$(sed -n 2,5p "$S_P/coverage")" = 'outcome: partial
checked: macOS
tested: macOS
not checked: iOS' ]; then ok "partial: the state keeps the outcome and the platforms checked, tested and not checked"
else nok "partial: the state keeps the outcome and the platforms checked, tested and not checked" "$(cat "$S_P/coverage" 2>&1)"; fi
expect_row "partial: doctor says the last verification left iOS unchecked" "$(doctor "$P")" WARN 'Last verification' 'PARTIAL.*not checked on iOS'
expect_result "partial: the checkpoint after a compaction says it too" 0 'PARTIAL.*not checked on iOS' "exit=0
$(hook session-start.sh "$P" '{"source":"compact"}')"

echo 'let app = 3' >"$P/Sources/App.swift"
FAKE_RESULT_LINE='verify fast: PARTIAL (passed on macOS; not checked on iOS, iPadOS: no SCHEME builds it, and swift test runs on this Mac only)' gate_stop "$P" >/dev/null
expect_row "partial: the result line of a verify.sh generated before 1.6.1 is read too" "$(doctor "$P")" WARN 'Last verification' 'not checked on iOS, iPadOS'

# The line can lower the outcome, never raise it.
echo 'let app = 4' >"$P/Sources/App.swift"
out="$(FAKE_RESULT_LINE='swift-harness-result/1: passed; checked: macOS; tested: macOS; not checked: none' FAKE_RESULT_EXIT=1 gate_stop "$P")"
expect_result "partial: an exit other than 0 is a failure, whatever the line says" 2 'Verification failed' "$out"
echo 'let app = 5' >"$P/Sources/App.swift"
out="$(FAKE_RESULT_LINE="$(printf 'swift-harness-result/1: passed; checked: macOS; tested: macOS; not checked: none\nswift-harness-result/1: failed; checked: macOS; tested: macOS; not checked: none')" gate_stop "$P")"
expect_result "partial: a failed line lowers an exit 0 to a failure; the last line counts" 2 'Verification failed' "$out"

echo 'let app = 6' >"$P/Sources/App.swift"
out="$(FAKE_RESULT_LINE='swift-harness-result/1: passed; checked: macOS, iOS; tested: none; not checked: none' gate_stop "$P")"
expect_result "partial: a full pass says nothing" 0 '^exit=0$' "$out"
expect_row "partial: after a full pass doctor gives the platforms it covered" "$(doctor "$P")" PASS 'Last verification' 'passed on the current code: built on macOS, iOS; tests ran on none'
echo 'let app = 7' >"$P/Sources/App.swift"
gate_stop "$P" >/dev/null
expect_row "partial: a custom command with no result line passes, with its coverage unknown" "$(doctor "$P")" PASS 'Last verification' 'passed on the current code; its output names no platforms'

# ---------- performance budget (#33) ----------

if grep -qx 'disable-model-invocation: true' "$SKILLS/approve-performance/SKILL.md" &&
  grep -qF '/swift-harness:approve-performance' "$TEMPLATES/tests/PerformanceBudget.swift" &&
  grep -qF '| `tests/PerformanceBudget.swift` |' "$PLUGIN/skills/setup/SKILL.md"; then
  ok "performance: only the user approves baselines, the helper says how, and setup installs it"
else nok "performance: only the user approves baselines, the helper says how, and setup installs it"; fi
if link_ok "$HERE/fixtures/performance/Tests/LibraryTests/PerformanceBudget.swift" "$TEMPLATES/tests/PerformanceBudget.swift"; then
  ok "performance: the fixture runs the template helper itself"
else nok "performance: the fixture runs the template helper itself"; fi

perf() { # performance.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/performance.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
perf_digest() { CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/performance.sh" --status --project "$1" | sed -n 's/^Digest: //p'; }
perf_candidate() { # $1 project, $2 name, $3 status, $4 instructions
  local c="$1/.build/swift-harness/performance"
  mkdir -p "$c"
  printf '{"name":"%s","instructions":%s,"cpuMilliseconds":12.5,"arch":"arm64","os":"27.0","configuration":"debug","iterations":15,"spread":0.0001}\n' "$2" "$4" >"$c/$2.json"
  printf '{"status": "%s", "reason": "%s: reason"}\n' "$3" "$2" >"$c/$2.result.json"
}
B="$(new_project performance)"
expect_result "performance: nothing waiting is said plainly" 0 'No new numbers wait' "$(perf --status --project "$B")"
perf_candidate "$B" Load missing 360000000
perf_candidate "$B" Sort failed 590000000
perf_candidate "$B" Scan passed 100
rm -f "$B/.build/swift-harness/performance/Scan.json"
out="$(perf --status --project "$B")"
expect_result "performance: status lists what waits, with the numbers" 0 'Load: missing.*360 M instructions, 12\.5 ms CPU, on arm64, macOS 27\.0, debug.*Sort: failed' "$(head -1 <<<"$out")
$(tail -n +2 <<<"$out" | tr '\n' ' ')" 'Scan'
expect_result "performance: a wrong digest approves nothing" 1 'Nothing approved' "$(perf --approve 0000 --project "$B")"
out="$(perf --approve "$(perf_digest "$B")" --project "$B" Load)"
if grep -qF 'Approved: performance/Load.json (missing)' <<<"$out" && jq -e '.approved and .instructions == 360000000' "$B/performance/Load.json" >/dev/null &&
  [ -e "$B/.build/swift-harness/performance/Sort.json" ] && [ ! -e "$B/.build/swift-harness/performance/Load.json" ]; then
  ok "performance: approving one copies its numbers into performance/, the rest still waits"
else nok "performance: approving one copies its numbers into performance/, the rest still waits" "$out"; fi
expect_ask "$B" "$B/performance/Load.json" "guard: a performance baseline edit asks"
git -C "$B" add -A && git -C "$B" commit -qm baselines
hook session-start.sh "$B" '{"source":"startup"}' >/dev/null
expect_result "snapshot-watch: an approved performance baseline says nothing" 0 '^exit=0$' \
  "$(perf --approve "$(perf_digest "$B")" --project "$B" >/dev/null; swatch "$B")"
jq '.instructions = 900000000' "$B/performance/Load.json" >"$TMP/pj" && mv "$TMP/pj" "$B/performance/Load.json"
expect_result "snapshot-watch: a performance baseline changed without approval is shown" 0 'performance baselines in performance/ changed in this session without /swift-harness:approve-performance.*changed: performance/Load\.json' "$(swatch "$B")"
before="$(fingerprint "$B")"
jq '.instructions = 1' "$B/performance/Load.json" >"$TMP/pj" && mv "$TMP/pj" "$B/performance/Load.json"
[ "$before" != "$(fingerprint "$B")" ] && ok "fingerprint: a changed performance baseline is a change to verify" || nok "fingerprint: a changed performance baseline is a change to verify"
set_config "$B" '{"performance":{"path":"../outside"}}'
expect_result "performance: a baselines folder outside the project is refused" 1 'inside the project' "$(perf --status --project "$B")"
set_config "$B" '{"performance":{"pth":"x"},"docs":{"budget":"big"}}'
out="$(doctor "$B")"
expect_row "doctor: unknown docs and performance keys are named" "$out" WARN 'Config keys' 'performance\.pth'
expect_row "doctor: a docs budget that is not a number fails" "$out" FAIL 'Config' 'docs\.budget must be a number'
set_config "$B" '{}'

# The template on the fixture, in real `swift test` runs. Without an instruction counter (a
# virtual machine, such as a CI runner) the budget is not compared; with one, every case runs.
if ! command -v swift >/dev/null 2>&1; then
  printf 'skip  performance: swift not installed, the fixture was not run\n'
else
  F="$TMP/perf-fixture"
  cp -RL "$HERE/fixtures/performance" "$F"
  git -C "$F" init -q && mkdir -p "$F/.claude" && echo '{}' >"$F/.claude/swift-harness.json"
  (cd "$F" && swift build --build-tests >/dev/null 2>&1)
  ptest() { # env assignments; prints "exit=<code>" then the PerformanceBudget lines
    local out code
    out="$(cd "$F" && env "$@" swift test 2>&1)"
    code=$?
    printf 'exit=%s\n%s' "$code" "$(grep '^PerformanceBudget:' <<<"$out")"
  }
  out="$(ptest X=1)"
  if grep -qF 'counts no instructions' <<<"$out"; then
    expect_result "performance: with no instruction counter the budget is not compared, and does not fail" 0 'not-compared: this machine counts no instructions' "$out"
    printf 'skip  performance: this machine counts no instructions, the comparisons were not run\n'
  else
    expect_result "performance: with no baseline the budget fails, with the numbers" 1 'missing: LoadLibrary-10k: no approved baseline yet: [0-9.]+ M instructions' "$out"
    CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/performance.sh" --approve "$(perf_digest "$F")" --project "$F" >/dev/null
    expect_result "performance: the same code passes its approved budget" 0 'passed: [0-9.]+ M instructions.*of the approved' "$(ptest X=1)"
    expect_result "performance: decoding twice fails, with the numbers and the percentage" 1 'failed: LoadLibrary-10k: [0-9.]+ M instructions, [0-9.]+% over the approved' "$(ptest SLOW=1)"
    expect_result "performance: other work in the process makes the result unstable, not a measurement" 1 'unstable: .*the iterations spread by' "$(ptest HOG=1)"
    jq '.instructions *= 2' "$F/performance/LoadLibrary-10k.json" >"$TMP/pj" && mv "$TMP/pj" "$F/performance/LoadLibrary-10k.json"
    expect_result "performance: a gain passes and leaves the numbers to approve" 0 'faster: [0-9.]+% fewer instructions' "$(ptest X=1)"
    jq '.instructions /= 2 | .os = "13.0"' "$F/performance/LoadLibrary-10k.json" >"$TMP/pj" && mv "$TMP/pj" "$F/performance/LoadLibrary-10k.json"
    expect_result "performance: a baseline from another macOS is not compared" 0 'not-compared: the baseline was made on arm64, macOS 13\.0' "$(ptest X=1)"
  fi
fi

# ---------- docs references (#70) ----------

docs_project() { # $1 name: a project whose docs point at files, headings and sections
  local p
  p="$(new_project "$1")"
  mkdir -p "$p/docs/adr"
  cat >"$p/CLAUDE.md" <<'MD'
# App

@docs/ARCHITECTURE.md

- Player: `Sources/App.swift`, the engine `Sources/Audio/Engine.swift:12`.
- Popovers are listed under "Presented UI" in `docs/LAYOUT.md`.
- [Modules](docs/ARCHITECTURE.md#modules), [external](https://example.com/a.md), [top](#app).
- Snapshot baselines go in `snapshots/`; build logs in `build-output/log.txt`.
- Run `scripts/verify.sh fast`; `{{PLACEHOLDER}}/x.swift` is filled by setup.
MD
  cat >"$p/docs/ARCHITECTURE.md" <<'MD'
# Architecture

## Modules

Audio lives in `Sources/Audio/`; see [the presented UI](LAYOUT.md#presented-ui).

```swift
// `Sources/Nowhere.swift` in a code block is not a reference.
```
<!-- `Sources/Commented.swift` in a comment neither. -->
MD
  printf '# Layout\n\n## Presented UI\n\nNone yet.\n' >"$p/docs/LAYOUT.md"
  printf '# 1. Old engine\n\nWe removed `Sources/Old/Engine.swift`.\n' >"$p/docs/adr/0001-old.md"
  printf 'build-output/\n' >"$p/.gitignore"
  git -C "$p" add -A && git -C "$p" commit -qm docs
  printf '%s' "$p"
}
docs() { # docs.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/docs.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

D="$(docs_project docs-ok)"
expect_result "docs: unchanged docs pass (links, paths, sections, an ADR, code, comments, ignored and later folders)" 0 '^exit=0$' "$(docs check "$D")"
expect_result "docs: the summary counts docs and references and gives the session size" 0 '^exit=0$
4 docs, [0-9]+ references; every session reads [0-9]+ of 20000 bytes' "$(docs summary "$D")"

D="$(docs_project docs-renamed-file)"
git -C "$D" mv Sources/App.swift Sources/Main.swift
expect_result "docs: a renamed file is reported as file:line" 1 '^- CLAUDE\.md:5: `Sources/App\.swift` does not exist$' "$(docs check "$D")"

D="$(docs_project docs-renamed-heading)"
sed -i '' 's/^## Presented UI/## Popovers/' "$D/docs/LAYOUT.md"
out="$(docs check "$D")"
expect_result "docs: a renamed heading breaks the link to it, as file:line" 1 '^- docs/ARCHITECTURE\.md:5: link to #presented-ui, which is not a heading of docs/LAYOUT\.md$' "$out"
expect_result "docs: and the section named beside the doc, as file:line" 1 '^- CLAUDE\.md:6: "Presented UI" is not a section of docs/LAYOUT\.md$' "$out"

D="$(docs_project docs-renamed-doc)"
git -C "$D" mv docs/LAYOUT.md docs/LAYOUT_CONTRACT.md
out="$(docs check "$D")"
expect_result "docs: a renamed doc breaks links and paths to it" 1 'docs/ARCHITECTURE\.md:5: link to LAYOUT\.md, which does not exist' "$out"
expect_result "docs: the path in backticks too" 1 'CLAUDE\.md:6: `docs/LAYOUT\.md` does not exist' "$out"

D="$(docs_project docs-budget)"
set_config "$D" '{"docs":{"budget":300}}'
expect_result "docs: files read into every session over the budget are reported, with each file's size" 1 \
  '^- CLAUDE\.md:1: the files read into every session are [0-9]+ bytes \(about [0-9]+ tokens\), over the budget of 300 \(docs.budget\): CLAUDE\.md [0-9]+, docs/ARCHITECTURE\.md [0-9]+$' "$(docs check "$D")"

D="$(docs_project docs-import)"
printf '@docs/GONE.md\n' >>"$D/CLAUDE.md"
expect_result "docs: an import of a missing file is reported" 1 '^- CLAUDE\.md:10: @docs/GONE\.md imports a file that does not exist$' "$(docs check "$D")"

D="$(docs_project docs-history)"
set_config "$D" '{"docs":{"history":[]}}'
expect_result "docs: with no history folders, the ADR's old path is reported" 1 'docs/adr/0001-old\.md:3: `Sources/Old/Engine\.swift` does not exist' "$(docs check "$D")"

D="$(docs_project docs-forms)"
cat >>"$D/docs/LAYOUT.md" <<'MD'

## Burning (services, step 3)

- **Focus.** Keyboard focus stays in the sidebar.

| Decision | Why |
|---|---|
| Network shares, the plan (2026-11-01) | Asked by the user. |
MD
cat >>"$D/CLAUDE.md" <<'MD'
- "Burning" in `docs/LAYOUT.md`; "Focus" in `docs/LAYOUT.md`; `docs/LAYOUT.md`, "Network shares, the plan".
- "Network shares" in `docs/LAYOUT.md`; "Rendering" in `docs/LAYOUT.md`.
- Inside a module: `Nodes/`, `Player/Bar.swift`; on disk: `Music/Library.store`.
MD
out="$(docs check "$D")"
expect_result "docs: a heading's lead, a bold label and a table row's first cell are sections" 1 '"Rendering" is not a section' "$out" '"(Burning|Focus|Network shares, the plan|Network shares)" is not'
expect_result "docs: paths of one part, or whose first folder is not in the project, are left alone" 1 '"Rendering"' "$out" 'Nodes/|Player/Bar|Library\.store'

# The docs setup generates, placeholders and all, pass.
D="$(new_project docs-templates)"
cp "$PLUGIN/skills/setup/templates/CLAUDE.md" "$D/CLAUDE.md"
cp -R "$PLUGIN/skills/setup/templates/docs" "$D/"
expect_result "docs: the docs setup generates pass before anything is filled in" 0 '^exit=0$' "$(docs check "$D")"

# The end-of-turn hook: only problems new in the session block, once.
docs_watch() { # $1 project, $2 extra JSON; prints "exit=<code>" then stdout and stderr on one line
  local out code
  out="$(hook docs-watch.sh "$1" "${2:-}" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$(printf '%s' "$out" | tr '\n' ' ')"
}
D="$(docs_project docs-watch)"
git -C "$D" mv Sources/AudioTools/Tool.swift Sources/AudioTools/Tools.swift
printf -- '- Tools: `Sources/AudioTools/Tool.swift`\n' >>"$D/CLAUDE.md"
git -C "$D" add -A && git -C "$D" commit -qm "a broken reference before the session"
hook session-start.sh "$D" '{"source":"startup"}' >/dev/null
expect_result "docs-watch: a problem already there when the session started does not block" 0 '^exit=0$' "$(docs_watch "$D")" 'Tool\.swift'
LOG="$TMP/docs-watch.log"; : >"$LOG"
echo 'let app = 2' >"$D/Sources/App.swift"
FAKE_VERIFY_LOG="$LOG" hook stop-verify.sh "$D" >/dev/null 2>&1
ran="$(wc -l <"$LOG" | tr -d ' ')"
: >"$LOG"
sed -i '' 's/^## Modules/## Parts/' "$D/docs/ARCHITECTURE.md"
FAKE_VERIFY_LOG="$LOG" hook stop-verify.sh "$D" >/dev/null 2>&1
if [ "$ran" = 1 ] && [ ! -s "$LOG" ]; then ok "docs-watch: a Swift edit runs the verify command, a docs edit after it does not"
else nok "docs-watch: a Swift edit runs the verify command, a docs edit after it does not" "runs after the Swift edit: $ran; after the docs edit: $(wc -l <"$LOG")"; fi
expect_result "docs-watch: a reference broken in the session blocks, with file:line" 2 'CLAUDE\.md:7: link to #modules, which is not a heading of docs/ARCHITECTURE\.md' "$(docs_watch "$D")" 'Tool\.swift'
expect_result "docs-watch: the same problems do not block twice; the user is told" 0 'systemMessage.*#modules' "$(docs_watch "$D" '{"stop_hook_active":true}')"
sed -i '' 's/^## Parts/## Modules/' "$D/docs/ARCHITECTURE.md"
expect_result "docs-watch: fixed docs pass" 0 '^exit=0$' "$(docs_watch "$D")"
set_config "$D" '{"docs":{"enabled":false}}'
sed -i '' 's/^## Modules/## Parts/' "$D/docs/ARCHITECTURE.md"
expect_result "docs-watch: docs.enabled false turns it off" 0 '^exit=0$' "$(docs_watch "$D")"

# ---------- check sensitivity (#79) ----------

mutate() { # mutate.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/mutate.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
M="$TMP/mutate"
cp -R "$HERE/fixtures/mutate" "$M"
before="$(snapshot "$M")"
out="$(mutate --project "$M")"
expect_result "mutate: the fixture passes every check without mutations" 0 'Without mutations: registry pass, layout pass, docs pass, security pass, contracts pass' "$out"
for op in registry-rename:registry layout-rename:layout docs-stale-link:docs security-relax:security contracts-forbidden:contracts; do
  expect_result "mutate: ${op%%:*} is killed by the ${op#*:} check, and only by it" 0 "^\| ${op%%:*} \| [^|]+:[0-9]+ \([^|]+\) \| ${op#*:} \| killed \| ${op#*:} \|$" "$out"
done
expect_result "mutate: the summary counts them" 0 '^5 killed, 0 survived, 0 with no site, 5 not run\.$' "$out"
if [ "$(snapshot "$M")" = "$before" ]; then ok "mutate: the project itself is not changed"
else nok "mutate: the project itself is not changed" "$(diff <(printf '%s\n' "$before") <(snapshot "$M") | head)"; fi
expect_result "mutate: --only runs one operator" 0 '^1 killed, 0 survived, 0 with no site\.$' "$(mutate --project "$M" --only docs-stale-link)" 'registry-rename'
expect_result "mutate: an unknown operator is a usage error" 2 'unknown operator "nope"' "$(mutate --project "$M" --only nope)"
expect_result "mutate: --list names each operator and its check" 0 'contracts-forbidden +contracts' "$(mutate --list)"

# A survived mutation is reported, not a failed run: security off, approved off, so the
# check compares nothing and the relaxed entitlement goes through.
M2="$TMP/mutate-survived"
cp -R "$HERE/fixtures/mutate" "$M2"
printf '%s\n' '{"registry":{"sources":["Sources/DesignSystem"]},"security":{"enabled":false}}' >"$M2/.claude/swift-harness.json"
expect_result "mutate: a mutation no check notices is reported as SURVIVED, exit 0" 0 '^\| security-relax \| [^|]+ \| security \| SURVIVED \| - \|$' "$(mutate --project "$M2" --only security-relax)"

# A check that already fails can still kill: only problems it did not report before count.
M3="$TMP/mutate-failing"
cp -R "$HERE/fixtures/mutate" "$M3"
printf '| UI-002 | Ghost | Gone | | | | Sources/DesignSystem/Ghost.swift | | |\n' >>"$M3/docs/COMPONENT_REGISTRY.md"
out="$(mutate --project "$M3" --only registry-rename)"
expect_result "mutate: a check failing without mutations is named" 0 'registry fails already' "$out"
expect_result "mutate: it still kills a mutation with a new problem" 0 '^\| registry-rename \| [^|]+ \| registry \| killed \| registry \|$' "$out"

# No documents, no sites; a path in backticks is used when the docs have no link.
M4="$TMP/mutate-bare"
mkdir -p "$M4/.claude" "$M4/docs"
printf '{}\n' >"$M4/.claude/swift-harness.json"
printf '# Notes\n\nSee `docs/NOTES.md` and [the web](https://example.com).\n' >"$M4/CLAUDE.md"
printf '# Notes\n' >"$M4/docs/NOTES.md"
out="$(mutate --project "$M4")"
expect_result "mutate: operators with nothing to change report no site" 0 '^1 killed, 0 survived, 4 with no site, 5 not run\.$' "$out"
expect_result "mutate: a path in backticks is moved when there is no local link" 0 'CLAUDE\.md:3 \(docs/NOTES\.md now points to docs/NOTES-moved\.md\) \| docs \| killed' "$out"

# --verify, with a fake scripts/verify.sh that prints what each check prints when the code
# has the defect (tests/mutate-fixture.sh runs the real ones on Xcode). The run line has a
# number that changes every run: numbers are ignored, so it is not a new problem.
mutate_verify_project() { # $1 name
  local p="$TMP/$1"
  cp -R "$HERE/fixtures/mutate-verify" "$p"
  mkdir -p "$p/scripts" "$p/Tests/AppUITests"
  cat >"$p/Sources/Components/Favorite.swift" <<'EOF'
import SwiftUI

struct Favorite: View {
    var body: some View {
        Button {} label: { Image(systemName: "star") }
            .accessibilityLabel("Favorite")
    }
}
EOF
  # The audit through a helper of the project, in a file whose name has a "+".
  cat >"$p/Tests/AppUITests/AppUITests.swift" <<'EOF'
import XCTest

final class AppUITests: XCTestCase {
    @MainActor func testTheScreenPassesTheAudit() throws { XCUIApplication().assertAudit(in: self) }
}
EOF
  cat >"$p/Tests/AppUITests/XCUIApplication+Audit.swift" <<'EOF'
import XCTest

extension XCUIApplication {
    @MainActor func assertAudit(in testCase: XCTestCase) { try? performAccessibilityAudit() }
}
EOF
  printf 'custom_rules:\n  ds_hardcoded_padding:\n    regex: x\n' >"$p/.swiftlint.yml"
  cat >"$p/scripts/verify.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.." || exit 2
fail=0
c=Sources/Components
echo "Test run with 4 tests in 3 suites passed after 0.$RANDOM seconds with 0 issues."
[ -f old-failure ] && { echo "Sources/Components/Old.swift:3:1: error: Line Length Violation (line_length)"; fail=1; }
grep -q '\.padding(13)' $c/Badge.swift && { echo "$c/Badge.swift:8:9: error: Hardcoded padding Violation: Use a Spacing token. (ds_hardcoded_padding)"; fail=1; }
grep -q 'keyboardShortcut(.cancelAction)' $c/SaveBar.swift || { echo "✘ Test returnSavesAndEscapeCancels() recorded an issue at KeyboardTests.swift:17:9: Expectation failed"; fail=1; }
if grep -q mutantBody $c/LibraryView.swift; then
  if [ -f build-breaks ]; then echo "$c/LibraryView.swift:5:40: error: cannot find 'mutantBody' in scope"
  else echo "✘ Test library() recorded an issue at LayoutTests.swift:7:28: LibraryView needs 600 pt at Min 400"; fi
  fail=1
fi
grep -q 'Spacing.small + 3' $c/Badge.swift && { echo "✘ Test badge() recorded an issue at SnapshotTests.swift:7:25: Badge-macos-120x40-light: 412 pixels differ"; fail=1; }
grep -q accessibilityLabel $c/Favorite.swift || { printf 'Failing tests:\n\tAppUITests.testTheScreenPassesTheAudit()\n'; fail=1; }
exit $fail
EOF
  chmod +x "$p/scripts/verify.sh"
  printf '%s' "$p"
}
MV="$(mutate_verify_project mutate-verify)"
out="$(mutate --project "$MV" --verify)"
expect_result "mutate --verify: the run without mutations passes verify (a number that changes is not a problem)" 0 'Without mutations: .*, verify pass$' "$out"
for op in lint-literal:lint keyboard-shortcut:keyboard layout-wide:layout-size a11y-label:accessibility snapshot-padding:snapshot; do
  expect_result "mutate --verify: ${op%%:*} is killed by the ${op#*:} check, and only by it" 0 "^\| ${op%%:*} \| [^|]+:[0-9]+ \([^|]+\) \| ${op#*:} \| killed \| ${op#*:} \|$" "$out"
done
expect_result "mutate --verify: the padding token becomes a literal" 0 'Badge\.swift:8 \(\.padding\(Spacing\.small\) became \.padding\(13\)\)' "$out"
expect_result "mutate --verify: the shortcut comes from a view a KeyboardCheck test hosts" 0 'SaveBar\.swift:12 \(\.keyboardShortcut\(\.cancelAction\) removed\)' "$out"
expect_result "mutate --verify: the first Screens view is made wider than Min, on the same line" 0 'LibraryView\.swift:5 \(LibraryView wrapped in \.frame\(minWidth: 600\), Min width 400\)' "$out"
expect_result "mutate --verify: an audit called through a helper of the project is credited to accessibility" 0 '^\| a11y-label \| [^|]+ \| accessibility \| killed \| accessibility \|$' "$out"
expect_result "mutate --verify: the summary counts all ten" 0 '^6 killed, 0 survived, 4 with no site\.$' "$out"
if grep -q 'mutantBody' "$MV/Sources/Components/LibraryView.swift" || [ -d "$MV/.build" ]; then nok "mutate --verify: the project is not changed, and no .build is left behind"
else ok "mutate --verify: the project is not changed, and no .build is left behind"; fi

out="$(mutate --project "$MV")"
expect_result "mutate: without --verify, the verify operators are not run" 0 '^\| keyboard-shortcut \| - \| keyboard \| not run \(needs --verify\) \| - \|$' "$out"
mv "$MV/scripts/verify.sh" "$MV/scripts/verify.off"
out="$(mutate --project "$MV" --verify --only keyboard-shortcut)"
expect_result "mutate --verify: without scripts/verify.sh, said and not run" 0 'verify not run \(no scripts/verify\.sh\)' "$out"
expect_result "mutate --verify: ... and the operators are not run" 0 'not run \(verify cannot run\)' "$out"
mv "$MV/scripts/verify.off" "$MV/scripts/verify.sh"

touch "$MV/old-failure" "$MV/build-breaks"
out="$(mutate --project "$MV" --verify --only keyboard-shortcut --only layout-wide)"
expect_result "mutate --verify: verify failing without mutations is named" 0 'verify fails already' "$out"
expect_result "mutate --verify: it still kills a mutation with a new failure" 0 '^\| keyboard-shortcut \| [^|]+ \| keyboard \| killed \| keyboard \|$' "$out"
expect_result "mutate --verify: a failure no check is credited with (a mutation that does not build) is 'verify', and the mutation survives" 0 '^\| layout-wide \| [^|]+ \| layout-size \| SURVIVED \| verify \|$' "$out"
rm -f "$MV/old-failure" "$MV/build-breaks"

# A check the project does not use cannot notice anything: said, and verify is not run for it.
rm "$MV/.swiftlint.yml" "$MV/Tests/ComponentsTests/KeyboardTests.swift"
out="$(mutate --project "$MV" --verify --only lint-literal --only keyboard-shortcut)"
expect_result "mutate --verify: no padding rule in .swiftlint.yml is 'no check'" 0 '^\| lint-literal \| - \| lint \| no check \(no ds_hardcoded_padding rule in \.swiftlint\.yml\) \| - \|$' "$out"
expect_result "mutate --verify: no test calling KeyboardCheck is 'no check'" 0 '^\| keyboard-shortcut \| - \| keyboard \| no check \(no test calls KeyboardCheck\) \| - \|$' "$out"
expect_result "mutate --verify: ... counted apart" 0 '^0 killed, 0 survived, 0 with no site, 2 with no check\.$' "$out"

# ---------- drift score (#80) ----------

drift() { # drift.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$("$SCRIPTS/drift.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
DR="$TMP/drift"
mkdir -p "$DR/.claude" "$DR/docs" "$DR/Sources/DesignSystem" "$DR/Sources/Features"
git -C "$DR" init -q
git -C "$DR" config user.email test@example.com
git -C "$DR" config user.name test
printf '%s\n' '{"registry":{"sources":["Sources"]}}' >"$DR/.claude/swift-harness.json"
cat >"$DR/Sources/DesignSystem/Tokens.swift" <<'EOF'
import SwiftUI

public enum Spacing { public static let s: CGFloat = 8; public static let m: CGFloat = 12 }
public enum Radius { public static let card: CGFloat = 10 }
EOF
cat >"$DR/Sources/DesignSystem/Pill.swift" <<'EOF'
import SwiftUI

public struct Pill: View {
    let text: String
    public var body: some View { Text(text).padding(Spacing.s).background(Capsule().fill(.quaternary)) }
}
EOF
cat >"$DR/docs/COMPONENT_REGISTRY.md" <<'EOF'
# Component registry

## Components

| ID | Name | Purpose | Use when | Don't use when | API entry point | File | Used by | Tests |
|---|---|---|---|---|---|---|---|---|
| UI-001 | Pill | Transient status | Confirmations | Errors | `Pill(text:)` | Sources/DesignSystem/Pill.swift | LibraryView | none |

## Internal

| Name | Why not registered |
|---|---|
| LibraryView | A screen |
EOF
printf '# App\n\nComponents: [registry](docs/COMPONENT_REGISTRY.md).\n' >"$DR/CLAUDE.md"
library() { # $1 body of LibraryView
  printf 'import SwiftUI\n\nstruct LibraryView: View {\n    var body: some View {\n%s\n    }\n}\n' "$1" >"$DR/Sources/Features/LibraryView.swift"
}
CLEAN='        VStack(spacing: Spacing.s) {
            Text("Library").font(Typography.title).padding(Spacing.m)
            Text("Albums").padding().padding(.horizontal)
            HStack(spacing: 0) {}
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))'
library "$CLEAN"
git -C "$DR" add -A && git -C "$DR" commit -qm clean
library '        VStack(spacing: 7) {
            Text("Library").font(.system(size: 15)).padding(13)
            Text("Albums").padding(.horizontal, 13).foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.4))
            HStack(spacing: 0) {}
        }
        .cornerRadius(5)'
cat >"$DR/Sources/Features/StatusPill.swift" <<'EOF'
import SwiftUI

struct StatusPill: View {
    var body: some View { Text("Saved").padding(Spacing.s) }
}
EOF
printf '# App\n\nComponents: [registry](docs/REGISTRY.md).\n' >"$DR/CLAUDE.md"
git -C "$DR" add -A && git -C "$DR" commit -qm drift
library "$CLEAN"
git -C "$DR" rm -q Sources/Features/StatusPill.swift
printf '# App\n\nComponents: [registry](docs/COMPONENT_REGISTRY.md).\n' >"$DR/CLAUDE.md"
git -C "$DR" add -A && git -C "$DR" commit -qm cleanup

out="$(drift history --project "$DR" "$(git -C "$DR" rev-list --max-parents=0 HEAD)^!" 2>&1)"
expect_result "drift: a clean commit scores 0, with every design value a token" 0 'score 0  tokens 100%' "$out"
out="$(drift history HEAD~2..HEAD --project "$DR" --json)"
scores="$(printf '%s\n' "$out" | sed 1d | jq -r '.score' | paste -sd' ' -)"
expect_result "drift: history prints one object per commit, oldest first" 0 '^exit=0' "$out"
if [ "$scores" = "8 0" ]; then ok "drift: planted drift raises the score (8), the clean-up brings it back (0)"
else nok "drift: planted drift raises the score (8), the clean-up brings it back (0)" "scores: $scores"; fi
drifted="$(printf '%s\n' "$out" | sed -n 2p)"
if [ "$(jq -c '[.tokens.padding.values, .tokens.padding.literal, .tokens.spacing.values, .tokens.radius.values, .tokens.font.values, .colors.literal, .token_share]' <<<"$drifted")" = '[[13],2,[7],[5],[15],1,29]' ]; then
  ok "drift: literal values are counted by kind (padding 13 twice, spacing 7, radius 5, font 15, one color), token share 29%"
else nok "drift: literal values are counted by kind (padding 13 twice, spacing 7, radius 5, font 15, one color), token share 29%" "$drifted"; fi
if [ "$(jq -c '.near_duplicates' <<<"$drifted")" = '[{"name":"StatusPill","file":"Sources/Features/StatusPill.swift:3","like":"Pill"}]' ]; then
  ok "drift: a new component with the role of a registered one is a near-duplicate"
else nok "drift: a new component with the role of a registered one is a near-duplicate" "$drifted"; fi
if [ "$(printf '%s\n' "$out" | sed 1d | jq -c '[.ui_lines > 0, .literals_per_kloc]' | paste -sd' ' -)" = "[true,$(jq '(6 * 10000 / .ui_lines | round) / 10' <<<"$drifted")] [true,0]" ]; then
  ok "drift: literals per 1000 UI lines, for comparing across sizes"
else nok "drift: literals per 1000 UI lines, for comparing across sizes" "$out"; fi
if [ "$(jq -c '.checks' <<<"$drifted")" = '{"registry":0,"layout":0,"docs":1,"contracts":0}' ]; then ok "drift: the docs check's problems are counted"
else nok "drift: the docs check's problems are counted" "$drifted"; fi
git -C "$DR" checkout -q HEAD~1
out="$(drift score --project "$DR")"
expect_result "drift: score names the literal values and the near-duplicate" 0 'near-duplicate: StatusPill \(Sources/Features/StatusPill\.swift:3\) has the role of Pill' "$out"
git -C "$DR" checkout -q -
printf '%s\n' "custom_rules:" "  ds_hardcoded_padding:" "    regex: x" "    excluded: 'Sources/Features/'" >"$DR/.swiftlint.yml"
library '        Text("x").padding(13)'
expect_result "drift: files the SwiftLint padding rule excludes are not UI code" 0 'score 0 ' "$(drift score --project "$DR")"
expect_result "drift: history outside a git repository is a usage error" 2 'not a git repository' "$(drift history HEAD --project "$M4")"
expect_result "drift: a range git does not know is a usage error" 2 'not a range git knows' "$(drift history nope..HEAD --project "$DR")"
rm "$DR/.swiftlint.yml"
expect_result "drift: --exclude leaves matching paths out of the UI code" 0 'score 0 ' "$(drift score --project "$DR" --exclude '^Sources/Features/')"
library '        Text("x").foregroundStyle(Color(red: r, green: g, blue: b)).background(Color(hex: 0x336699))'
expect_result "drift: a color computed from variables is not a literal, a hex one is" 0 'color 1/1' "$(drift score --project "$DR")"
for i in 1 2 3 4; do git -C "$DR" commit -q --allow-empty -m "empty $i"; done
out="$(drift history HEAD~6..HEAD --every 3 --project "$DR" --json)"
if [ "$(printf '%s\n' "$out" | sed 1d | jq -r .commit | paste -sd' ' -)" = "$(for r in HEAD~5 HEAD~2 HEAD; do git -C "$DR" rev-parse --short "$r"; done | paste -sd' ' -)" ]; then
  ok "drift: --every 3 keeps the first commit of each three, and the last"
else nok "drift: --every 3 keeps the first commit of each three, and the last" "$out"; fi
expect_result "drift: --every needs a positive number" 2 'usage' "$(drift history HEAD --every 0 --project "$DR")"

# ---------- evidence summary (#81) ----------

ev_stop() { # $1 project, $2 optional extra JSON; prints "exit=<code>" then stdout+stderr
  local out code
  out="$(hook stop-verify.sh "$1" "${2:-}" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
ev_of() { jq -c "$2" "$(state_of "$1")/evidence.json" 2>/dev/null; } # $1 project, $2 jq filter
E="$(new_project evidence)"
hook session-start.sh "$E" '{"source":"startup"}' >/dev/null
out="$(ev_stop "$E")"
if [ "$(ev_of "$E" '[.outcome, .note]')" = '["unchanged","no build input changed in this session: nothing ran, and the starting code is not verified"]' ]; then
  ok "evidence: no change in the session is recorded as such, with the starting code not verified"
else nok "evidence: no change in the session is recorded as such, with the starting code not verified" "$(cat "$(state_of "$E")/evidence.json" 2>&1)"; fi
echo 'let app = 2' >"$E/Sources/App.swift"
out="$(ev_stop "$E")"
if [ "$(ev_of "$E" '[.outcome, (.checks | map(select(.name == "scripts/verify.sh fast") | del(.seconds)))]')" = '["passed",[{"name":"scripts/verify.sh fast","result":"passed","detail":"exit 0; the command does not say which platforms it checked"}]]' ]; then
  ok "evidence: a pass records the command, its result and what it says it covered"
else nok "evidence: a pass records the command, its result and what it says it covered" "$(cat "$(state_of "$E")/evidence.json")"; fi
expect_result "evidence: a clean pass sends the user nothing" 0 '^exit=0$' "$out"
if cmp -s "$(state_of "$E")/evidence.json" "$(state_of "$E")/sessions/test/evidence.json"; then ok "evidence: written for the session and for the project"
else nok "evidence: written for the session and for the project"; fi
ev_stop "$E" >/dev/null
if [ "$(ev_of "$E" '[.outcome, (.checks | map(.name))]')" = '["unchanged",["scripts/verify.sh fast","security settings"]]' ]; then ok "evidence: the same code again keeps the checks that passed on it"
else nok "evidence: the same code again keeps the checks that passed on it" "$(cat "$(state_of "$E")/evidence.json")"; fi
echo 'let app = 3' >"$E/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=1 ev_stop "$E")"
if [ "$(ev_of "$E" '[.outcome, .checks[0].result, .checks[0].detail]')" = '["failed","failed","exit 1"]' ]; then ok "evidence: a failure is recorded with the exit code"
else nok "evidence: a failure is recorded with the exit code" "$(cat "$(state_of "$E")/evidence.json")"; fi
expect_result "evidence: with nothing skipped, the block says nothing about unchecked parts" 2 'Verification failed' "$out" 'Not checked this turn'

# A registry in another format is not checked: the user is told once, with what did pass.
printf '# Components\n\nA list, not a table.\n' >"$E/docs/COMPONENT_REGISTRY.md" 2>/dev/null || { mkdir -p "$E/docs"; printf '# Components\n\nA list, not a table.\n' >"$E/docs/COMPONENT_REGISTRY.md"; }
echo 'let app = 4' >"$E/Sources/App.swift"
out="$(ev_stop "$E")"
expect_result "evidence: a check that could not read its input is 'not checked', and the user is told" 0 'checked this turn: scripts/verify\.sh fast, security settings; not checked: component registry \(the registry has no Components table with Name and File columns\)' "$out"
if [ "$(ev_of "$E" '.checks | map(.name + ": " + .result)')" = '["scripts/verify.sh fast: passed","component registry: not checked","security settings: passed"]' ]; then ok "evidence: ... and it is in the record"
else nok "evidence: ... and it is in the record" "$(cat "$(state_of "$E")/evidence.json")"; fi
rm "$E/docs/COMPONENT_REGISTRY.md"

# Not approved: the existing notice says what was not checked, the contracts included.
printf '{"version":1,"packages":{}}\n' >"$E/docs/architecture-contracts.json"
printf '#!/bin/bash\necho changed\n' >"$E/scripts/verify.sh"
echo 'let app = 5' >"$E/Sources/App.swift"
out="$(ev_stop "$E")"
expect_result "evidence: not approved, the notice lists the verify command and the contracts as not checked" 0 'Not checked this turn: scripts/verify\.sh fast \(the verify command is not approved: /swift-harness:approve-verify\), architecture contracts \(they run only with the approved verify command\)' "$out"
if [ "$(ev_of "$E" '[.outcome, .note, (.checks | map(.result))]')" = '["checked","the checks that ran passed; the build and tests did not run",["not run","not run","passed"]]' ]; then ok "evidence: ... recorded as checked, not passed: the build and tests did not run"
else nok "evidence: ... recorded as checked, not passed: the build and tests did not run" "$(cat "$(state_of "$E")/evidence.json")"; fi
expect_row "evidence: doctor shows the last turn's checks and what was not checked" "$(doctor "$E")" WARN "Last turn's checks" 'Not checked: scripts/verify\.sh fast \(the verify command is not approved'
expect_result "evidence: the checkpoint after a compaction lists them" 0 'Checks at the last turn end, on this code: scripts/verify\.sh fast: not run \(the verify command is not approved: /swift-harness:approve-verify\); architecture contracts: not run \(they run only with the approved verify command\); security settings: passed' "exit=0
$(compact "$E")"

# ---------- catch log and report (#86) ----------

report() { # report.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
C="$(new_project catches)"
hook session-start.sh "$C" '{"source":"startup"}' >/dev/null
CL="$(state_of "$C")/catches.jsonl"
: >"$CL" # the approval made by new_project
expect_result "report: an empty log says so" 0 'Nothing in the catch log' "$(report --project "$C")"
echo 'let app = 2' >"$C/Sources/App.swift"
FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$C" >/dev/null 2>&1
echo 'let app = 3' >"$C/Sources/App.swift"
FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$C" >/dev/null 2>&1
echo 'let app = 4' >"$C/Sources/App.swift"
hook stop-verify.sh "$C" >/dev/null 2>&1
guard_asks "$C" "$C/Sources/Audio/Engine.swift" >/dev/null
if [ "$(jq -sc 'map([.check, .kind])' "$CL")" = '[["scripts/verify.sh fast","blocked"],["scripts/verify.sh fast","blocked"],["scripts/verify.sh fast","fixed"],["guard","asked"]]' ]; then
  ok "catch log: two blocks, the pass that fixed them (once), and the guard's question"
else nok "catch log: two blocks, the pass that fixed them (once), and the guard's question" "$(cat "$CL")"; fi
if [ "$(jq -sc '.[0] | [.session, (.what | test("^attempt 1 of 3: exit 1$")), (.time | test("^[0-9-]+T[0-9:]+Z$"))]' "$CL")" = '["test",true,true]' ]; then
  ok "catch log: each line has the time, the session and what was caught"
else nok "catch log: each line has the time, the session and what was caught" "$(head -1 "$CL")"; fi
out="$(report --project "$C")"
expect_result "report: the totals" 0 '2 block\(s\), 0 report\(s\), 1 question\(s\) before an edit; 1 fixed by Claude, 0 left failing, 0 approval\(s\) by you\.' "$out"
expect_result "report: one line per check, with how it ended" 0 '^- scripts/verify\.sh fast: 2 blocked, 1 fixed by Claude\. Last: attempt 2 of 3: exit 1$' "$out"
expect_result "report: the guard's question names the file" 0 '^- guard: 1 asked\. Last: Sources/Audio/Engine\.swift: ' "$out"
echo 'let app = 5' >"$C/Sources/App.swift"
for i in 1 2 3; do echo "let app = 1$i" >"$C/Sources/App.swift"; FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$C" >/dev/null 2>&1; done
expect_result "report: max attempts ends the blocks as left failing, once per check" 0 '^- scripts/verify\.sh fast: 5 blocked, 1 fixed by Claude, 1 left failing\.' "$(report --project "$C")"
printf '#!/bin/bash\necho changed\n' >"$C/scripts/verify.sh"
echo 'let app = 6' >"$C/Sources/App.swift"
hook stop-verify.sh "$C" >/dev/null 2>&1
out="$(report --project "$C" --json)"
if [ "$(jq -c '.skipped' <<<"${out#*$'\n'}")" = '[{"check":"scripts/verify.sh fast","times":1,"why":["the verify command is not approved: /swift-harness:approve-verify"]}]' ]; then
  ok "report: a check that did not run is listed with why, once per code"
else nok "report: a check that did not run is listed with why, once per code" "$out"; fi
expect_result "report: --since in the future leaves nothing" 0 'Nothing in the catch log' "$(report --project "$C" --since 2999-01-01)"
expect_result "report: a bad --since is a usage error" 2 'usage' "$(report --project "$C" --since yesterday)"
approve "$C" >/dev/null
expect_result "report: the user's approval of the verify command is counted" 0 '^- verify command: 1 approved by you' "$(report --project "$C" --all)"

# ---------- static HTML report (#87) ----------

H="$(new_project html-report)"
hook session-start.sh "$H" '{"source":"startup"}' >/dev/null
out="$(report --project "$H" --html)"
expect_result "html: written to .build/swift-harness/report.html, path printed" 0 'html-report/\.build/swift-harness/report\.html$' "$out"
page="$H/.build/swift-harness/report.html"
if grep -q 'No end-of-turn check has run in this project yet' "$page"; then ok "html: without a record, it says so"
else nok "html: without a record, it says so" "$(head -c 600 "$page")"; fi
# Values from the repository and the log are untrusted: a check name and a catch with HTML.
HL="$(state_of "$H")/catches.jsonl"
printf '%s\n' '{"time":"2026-11-08T00:00:00Z","session":"x","check":"<script>alert(1)</script>","kind":"blocked","what":"<img src=x onerror=alert(2)>"}' >>"$HL"
printf '#!/bin/bash\necho changed\n' >"$H/scripts/verify.sh"
echo 'let app = 2' >"$H/Sources/App.swift"
hook stop-verify.sh "$H" >/dev/null 2>&1
report --project "$H" --all --html >/dev/null
if ! grep -qiE '<script|<img' "$page" && grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' "$page" && grep -q '&lt;img src=x onerror=alert(2)&gt;' "$page"; then
  ok "html: names and catches carrying HTML are escaped"
else nok "html: names and catches carrying HTML are escaped" "$(grep -iE 'script|img' "$page" | head -5)"; fi
if grep -q '<span class="b none">not run</span>' "$page" && ! grep -q '<span class="b ok">not run' "$page"; then ok "html: a check that did not run is never green"
else nok "html: a check that did not run is never green" "$(grep -o '<span class="b [a-z]*">[^<]*' "$page")"; fi
if grep -q 'about the code as it is now' "$page"; then ok "html: the record about the current code says so"
else nok "html: the record about the current code says so"; fi
echo 'let app = 3' >"$H/Sources/App.swift"
report --project "$H" --all --html >/dev/null
if grep -q 'about an earlier state of the code' "$page" && ! grep -q '<span class="b ok">' "$page"; then ok "html: a record about earlier code is marked so, and shows nothing green"
else nok "html: a record about earlier code is marked so, and shows nothing green" "$(grep -o '<span class="b [a-z]*">[^<]*' "$page")"; fi
if ! grep -qiE '<script|<link|src="http|href="http' "$page" && grep -q "Content-Security-Policy\" content=\"default-src 'none'" "$page"; then
  ok "html: no script, no external resource, and a policy that forbids them"
else nok "html: no script, no external resource, and a policy that forbids them"; fi
if grep -q 'Source: <code>' "$page" && [ "$(grep -o 'Source: <code>' "$page" | wc -l | tr -d ' ')" = 2 ]; then ok "html: each section names its source file"
else nok "html: each section names its source file"; fi

# ---------- guest mode (#71) ----------

G="$TMP/guest"
mkdir -p "$G/Scripts" "$G/Sources/App" "$G/docs"
git -C "$G" init -q
git -C "$G" config user.email test@example.com
git -C "$G" config user.name test
printf '# Own rules\n\nRun `Scripts/check.sh` before a pull request.\n' >"$G/CLAUDE.md"
printf '# Agents\n\nThe coordinator owns docs/.\n' >"$G/AGENTS.md"
printf '# Plan\n' >"$G/docs/PLAN.md"
printf '#!/bin/bash\necho own-check >>"${GUEST_LOG:-/dev/null}"\nexit "${GUEST_EXIT:-0}"\n' >"$G/Scripts/check.sh"
chmod +x "$G/Scripts/check.sh"
echo 'let app = 1' >"$G/Sources/App/App.swift"
printf 'indent: 2\n' >"$G/.swiftformat"
git -C "$G" add -A && git -C "$G" commit -qm "a project with its own rules and checks"
gs() { "$SCRIPTS/setup-guest.sh" "$@" 2>&1; }
out="$(gs --project "$G" --fast 'Scripts/check.sh fast' --full 'Scripts/check.sh full')"
if [ "$(git -C "$G" status --short | sort | paste -sd' ' -)" = '?? .claude/ ?? Scripts/verify.sh' ] && [ "$(jq -r .verify.command "$G/.claude/swift-harness.json")" = 'Scripts/verify.sh fast' ]; then
  ok "guest: setup adds only the config and verify.sh, in the project's own Scripts/ folder (one folder on macOS)"
else nok "guest: setup adds only the config and verify.sh, in the project's own Scripts/ folder (one folder on macOS)" "$(git -C "$G" status --short)"; fi
if [ "$(jq -c '[.guest, .format, .lint]' "$G/.claude/swift-harness.json")" = '[true,"swiftformat","none"]' ]; then
  ok "guest: the project's own formatter config is used, SwiftLint stays off without one"
else nok "guest: the project's own formatter config is used, SwiftLint stays off without one" "$(cat "$G/.claude/swift-harness.json")"; fi
expect_result "guest: setup refuses when a file is there, and writes nothing" 1 'already there: \.claude/swift-harness\.json Scripts/verify\.sh' "exit=$(gs --project "$G" --fast x >/dev/null; echo $?)
$(gs --project "$G" --fast x)"
approve "$G" >/dev/null
hook session-start.sh "$G" '{"source":"startup"}' >"$TMP/guest-start.out" 2>&1
expect_result "guest: session start tells Claude the project's own rules come first" 0 'guest mode\. This project.s own agent rules and docs' "exit=0
$(cat "$TMP/guest-start.out")"
GL="$TMP/guest.log"; : >"$GL"
echo 'let app = 2' >"$G/Sources/App/App.swift"
GUEST_LOG="$GL" hook stop-verify.sh "$G" >/dev/null 2>&1
if [ "$(cat "$GL")" = own-check ]; then ok "guest: the end-of-turn check runs the project's own command"
else nok "guest: the end-of-turn check runs the project's own command" "$(cat "$GL")"; fi
echo 'let app = 3' >"$G/Sources/App/App.swift"
expect_result "guest: the project's command failing blocks the turn" 2 'Verification failed' "$(GUEST_EXIT=1 ev_stop "$G")"
git -C "$G" checkout -q -- Sources/App/App.swift
if [ "$(git -C "$G" status --short | sort | paste -sd' ' -)" = '?? .claude/ ?? Scripts/verify.sh' ]; then ok "guest: after the hooks ran, still nothing else changed"
else nok "guest: after the hooks ran, still nothing else changed" "$(git -C "$G" status --short)"; fi
expect_row "guest: doctor shows the mode and the project's own rules" "$(doctor "$G")" INFO Mode 'guest: .*CLAUDE\.md, AGENTS\.md are the source of truth'
if [ "$(jq -c '.protectedPaths' "$G/.claude/swift-harness.json")" = '["CLAUDE.md","AGENTS.md"]' ] && guard_asks "$G" "$G/AGENTS.md" && ! guard_asks "$G" "$G/Sources/App/App.swift"; then
  ok "guest: the project's own agent rules are protected: the guard asks before an edit (#109)"
else nok "guest: the project's own agent rules are protected: the guard asks before an edit (#109)" "$(cat "$G/.claude/swift-harness.json")"; fi
G4="$TMP/guest-owned"; mkdir -p "$G4/.claude/rules" "$G4/docs"; printf '# r\n' >"$G4/.claude/rules/a.md"; printf '# p\n' >"$G4/docs/ROADMAP.md"
"$SCRIPTS/setup-guest.sh" --project "$G4" --fast 'swift build' --owned docs/ROADMAP.md --owned docs/NOPE.md >/dev/null 2>"$TMP/guest-owned.err"
if [ "$(jq -c '.protectedPaths' "$G4/.claude/swift-harness.json")" = '[".claude/rules/","docs/ROADMAP.md"]' ] && grep -q 'docs/NOPE.md does not exist' "$TMP/guest-owned.err"; then
  ok "guest: --owned adds paths the project owns; one that does not exist is left out, and said (#109)"
else nok "guest: --owned adds paths the project owns; one that does not exist is left out, and said (#109)" "$(cat "$G4/.claude/swift-harness.json" "$TMP/guest-owned.err")"; fi
expect_result "guest: --full defaults to the fast command, --no-docs turns the docs check off" 0 'FULL=.Scripts/check\.sh.' "exit=0
$(G2="$TMP/guest2"; mkdir -p "$G2"; gs --project "$G2" --fast 'Scripts/check.sh' --no-docs >/dev/null; jq -r '.docs.enabled' "$G2/.claude/swift-harness.json"; grep FULL= "$G2/scripts/verify.sh")" 'true'
if ! jq -e 'has("protectedPaths")' "$TMP/guest2/.claude/swift-harness.json" >/dev/null; then ok "guest: a project without rules files gets no protected paths (#109)"
else nok "guest: a project without rules files gets no protected paths (#109)" "$(cat "$TMP/guest2/.claude/swift-harness.json")"; fi
expect_result "guest: without --fast it is a usage error" 2 'usage' "exit=$(gs --project "$G" >/dev/null; echo $?)
$(gs --project "$G")"

# ---------- test isolation (#68) ----------

I="$(new_project isolation)"
mkdir -p "$I/AppUITests"
cat >"$I/AppUITests/XCUIApplication+App.swift" <<'EOF'
import XCTest

extension XCUIApplication {
    func launchWithSongs() { launchArguments = ["-UITestingSuite", "Songs"]; launch() }
    func close() {}
}
EOF
cat >"$I/AppUITests/LibraryUITests.swift" <<'EOF'
import XCTest

final class LibraryUITests: XCTestCase {
    func testList() { let app = XCUIApplication(); app.launchWithSongs(); app.close() }
}
EOF
cat >"$I/AppUITests/DirectUITests.swift" <<'EOF'
import XCTest

final class DirectUITests: XCTestCase {
    func testOwn() { let app = XCUIApplication(); app.launchArguments = ["-UITestingSuite", "X"]; app.launch() }
}
EOF
iso() { local o c; o="$("$SCRIPTS/isolation.sh" check "$1" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
expect_result "isolation: no declared argument while UI tests launch the app is said, never blocks" 3 'declares no uiTests\.isolation arguments' "$(iso "$I")"
set_config "$I" '{"verify":{"command":"scripts/verify.sh fast"},"uiTests":{"isolation":["-UITestingSuite"]}}'
expect_result "isolation: a direct argument and a launch helper that sets it both count" 0 '^exit=0$' "$(iso "$I")"
cat >"$I/AppUITests/LeakUITests.swift" <<'EOF'
import XCTest

final class LeakUITests: XCTestCase {
    func testReal() {
        let app = XCUIApplication()
        app.launch()
        app.close()
    }
}
EOF
expect_result "isolation: a launch without it is reported with file and line, a generic helper (close) does not count" 1 '^- AppUITests/LeakUITests\.swift:6: launches the app without an isolation argument \(-UITestingSuite\)' "$(iso "$I")"
expect_row "isolation: doctor warns with the file" "$(doctor "$I")" WARN "Test isolation" 'LeakUITests\.swift:6'
set_config "$I" '{"verify":{"command":"scripts/verify.sh fast"},"uiTests":{"isolation":["-UITestingSuite"],"launchHelpers":["close"]}}'
expect_result "isolation: a helper listed in uiTests.launchHelpers counts" 0 '^exit=0$' "$(iso "$I")"
rm -rf "$I/AppUITests"
expect_result "isolation: no UI tests, nothing to check" 0 '^exit=0$' "$(iso "$I")"
if grep -q 'uiTests.isolation' "$TEMPLATES/rules/tests.md" && grep -q 'rules/tests.md' "$SKILLS/setup/SKILL.md" && grep -q 'docs/PITFALLS.md' "$SKILLS/setup/SKILL.md" && grep -q 'docs/PITFALLS.md' "$SCRIPTS/checkpoint.sh"; then
  ok "isolation: setup offers the tests rule and the pitfalls template; the checkpoint names the pitfalls"
else nok "isolation: setup offers the tests rule and the pitfalls template; the checkpoint names the pitfalls"; fi

# ---------- branch scope contract (#72) ----------

B="$(new_project scope)"
git -C "$B" branch -M main
set_config "$B" '{"verify":{"command":"scripts/verify.sh fast"},"scope":[{"branch":"ios-*","paths":["App-iOS/","Sources/AudioTools/"],"base":"main"}]}'
git -C "$B" add -A && git -C "$B" commit -qm scope
git -C "$B" switch -qc ios-port
hook session-start.sh "$B" '{"source":"startup"}' >/dev/null
scope() { local o c; o="$(hook scope-watch.sh "$B" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
mkdir -p "$B/App-iOS"
echo 'let ios = 1' >"$B/App-iOS/App.swift"
echo 'let tool = 2' >"$B/Sources/AudioTools/Tool.swift"
expect_result "scope: edits inside the branch's paths say nothing" 0 '^exit=0$' "$(scope)"
echo 'let app = 9' >"$B/Sources/App.swift"
git -C "$B" add -A && git -C "$B" commit -qm "a shared file changed on the branch"
out="$(scope)"
expect_result "scope: a file outside the scope is reported, committed or not, and never blocks" 0 'branch ios-port changed 1 file\(s\) outside its scope \(App-iOS/, Sources/AudioTools/\) since it left main:' "$out" 'App-iOS/App\.swift'
expect_result "scope: ... naming the file, to the user and to Claude" 0 '- Sources/App\.swift.*additionalContext' "exit=0
$(printf '%s' "${out#*$'\n'}" | tr '\n' ' ')"
expect_result "scope: the same files are not reported twice" 0 '^exit=0$' "$(scope)"
printf 'A = 2\n' >"$B/Config.xcconfig"
expect_result "scope: a new file outside (a shell edit, not committed) is reported again" 0 'changed 2 file\(s\) outside its scope' "$(scope)"
git -C "$B" switch -q main
echo '# main moves on' >>"$B/README.md"
git -C "$B" commit -qam "work on main"
git -C "$B" switch -q ios-port
expect_result "scope: commits of the base not merged into the branch are counted" 0 'main has 1 commit\(s\) not merged into ios-port yet' "$(scope)"
git -C "$B" switch -q main
expect_result "scope: on a branch without a scope entry, nothing" 0 '^exit=0$' "$(scope)"

# ---------- weakened checks (#146) ----------

W="$(new_project weaken)"
mkdir -p "$W/Tests/AppTests"
cat >"$W/Tests/AppTests/PlayerTests.swift" <<'EOF'
import XCTest
final class PlayerTests: XCTestCase {
    func testPlays() {
        XCTAssertTrue(true)
        XCTAssertEqual(1, 1)
    }
    func testStops() {
        XCTAssertFalse(false)
    }
    // func testOld() { XCTAssertTrue(true) }
    func testSeeks() throws {
        let x = try XCTUnwrap(Optional(1))
        XCTAssertEqual(x, 1)
    }
}
EOF
cat >"$W/Tests/AppTests/LibraryTests.swift" <<'EOF'
import Testing
@Test func loads() { #expect(1 == 1) }
@Test("sorts") func sorts() { #expect(2 > 1) }
EOF
cat >"$W/.swiftlint.yml" <<'EOF'
disabled_rules:
  - todo
opt_in_rules:
  - empty_count
excluded:
  - .build
EOF
git -C "$W" add -A && git -C "$W" commit -qm tests
hook session-start.sh "$W" '{"source":"startup"}' >/dev/null
weaken() { local o c; o="$(hook weaken-watch.sh "$W" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
expect_result "weakened: nothing changed, nothing said" 0 '^exit=0$' "$(weaken)" 'swift-harness'
# A comment that looks like a test is not a test: removing it says nothing.
sed -i '' '/func testOld/d' "$W/Tests/AppTests/PlayerTests.swift"
expect_result "weakened: a commented-out test is not counted" 0 '^exit=0$' "$(weaken)" 'swift-harness'
# Remove testStops (one test, one assertion).
sed -i '' '/func testStops/,/^    }$/d' "$W/Tests/AppTests/PlayerTests.swift"
out="$(weaken)"
expect_result "weakened: a removed test is reported with its file, and never blocks" 0 'Tests/AppTests/PlayerTests\.swift: 1 test removed \(3 -> 2\)' "$out" '"decision"'
expect_result "weakened: ... and its assertion" 0 'Tests/AppTests/PlayerTests\.swift: 1 assertion removed \(5 -> 4\)' "$out"
expect_result "weakened: ... to the user and to the agent" 0 'systemMessage.*additionalContext' "exit=0
$(printf '%s' "${out#*$'\n'}" | tr '\n' ' ')"
expect_result "weakened: the same set is not said twice" 0 '^exit=0$' "$(weaken)" 'swift-harness'
if jq -e 'select(.check == "weakened checks" and .kind == "reported")' "$(state_of "$W")/catches.jsonl" >/dev/null 2>&1; then
  ok "weakened: recorded in the catch log, so the report counts it"
else nok "weakened: recorded in the catch log, so the report counts it" "$(cat "$(state_of "$W")/catches.jsonl" 2>/dev/null)"; fi
# Skips: XCTSkip, .disabled(...), #if false.
sed -i '' 's/func testPlays() {/func testPlays() throws {\
        throw XCTSkip("later")/' "$W/Tests/AppTests/PlayerTests.swift"
sed -i '' 's/@Test("sorts")/@Test("sorts", .disabled("flaky"))/' "$W/Tests/AppTests/LibraryTests.swift"
out="$(weaken)"
expect_result "weakened: an XCTSkip added to a test is reported" 0 'Tests/AppTests/PlayerTests\.swift: 1 skip added' "$out"
expect_result "weakened: a .disabled(...) trait added is reported" 0 'Tests/AppTests/LibraryTests\.swift: 1 skip added' "$out"
expect_result "weakened: ... and the message lists the whole set, the earlier removal included" 0 '1 test removed' "$out"
printf '#if false\n@Test func hidden() { #expect(true) }\n#endif\n' >>"$W/Tests/AppTests/LibraryTests.swift"
expect_result "weakened: an #if false block in a test file is reported" 0 'LibraryTests\.swift: 2 skips added' "$(weaken)"
# Lint: a new swiftlint:disable anywhere in Swift code, and the config.
printf '// swiftlint:disable:next force_unwrapping\nlet forced = Int("1")!\n' >>"$W/Sources/App.swift"
expect_result "weakened: a swiftlint:disable added to the code is reported" 0 'Sources/App\.swift: 1 swiftlint:disable added' "$(weaken)"
cat >"$W/.swiftlint.yml" <<'EOF'
disabled_rules:
  - todo
  - force_cast
opt_in_rules: []
excluded:
  - .build
  - Sources/Audio
EOF
out="$(weaken)"
expect_result "weakened: a rule added to disabled_rules is reported" 0 '\.swiftlint\.yml: rule force_cast disabled' "$out"
expect_result "weakened: an opt-in rule removed is reported" 0 '\.swiftlint\.yml: rule empty_count no longer opted in' "$out"
expect_result "weakened: a path added to excluded is reported" 0 '\.swiftlint\.yml: Sources/Audio excluded from lint' "$out"
# A new session starts from the code as it is; a renamed test file is not a removal.
git -C "$W" add -A && git -C "$W" commit -qm weaker
hook session-start.sh "$W" '{"source":"startup"}' >/dev/null
expect_result "weakened: a new session starts from the code as it is" 0 '^exit=0$' "$(weaken)" 'swift-harness'
git -C "$W" mv Tests/AppTests/LibraryTests.swift Tests/AppTests/CatalogTests.swift
expect_result "weakened: a test file renamed with the same tests is not a removal" 0 '^exit=0$' "$(weaken)" 'swift-harness'
rm "$W/Tests/AppTests/PlayerTests.swift"
expect_result "weakened: a deleted test file is reported with what it held" 0 'Tests/AppTests/PlayerTests\.swift: file removed \(2 tests, 4 assertions\)' "$(weaken)"
# Part 2: tolerances, the layout contract, the registry.
mkdir -p "$W/docs"
cat >"$W/Tests/AppTests/LooksTests.swift" <<'EOF'
import XCTest
final class LooksTests: XCTestCase {
    func testLibrary() {
        Snapshot.verify(LibraryView(), named: "library", tolerance: 0.01)
        PerformanceBudget.verify("launch",
                                 tolerance: 0.05) { }
    }
}
EOF
cat >"$W/docs/LAYOUT_CONTRACT.md" <<'EOF'
# Layout contract

## Screens

| Screen | View | File | Min |
|---|---|---|---|
| Library | LibraryView | Sources/App.swift | 900x600 |
| Settings | SettingsView | Sources/App.swift | 500 |
EOF
cat >"$W/docs/COMPONENT_REGISTRY.md" <<'EOF'
# Component registry

## Components

| ID | Name | File |
|---|---|---|
| UI-001 | PlayButton | Sources/App.swift |
| UI-002 | Badge | Sources/App.swift |
| UI-003 | Meter | Sources/App.swift |

## Internal

| Name | Why not registered |
|---|---|

## Retired

| ID | Replaced by | Date |
|---|---|---|
EOF
git -C "$W" add -A && git -C "$W" commit -qm looks
hook session-start.sh "$W" '{"source":"startup"}' >/dev/null
expect_result "weakened: tolerances, layout rows and registry rows at session start say nothing" 0 '^exit=0$' "$(weaken)" 'swift-harness'
sed -i '' 's/tolerance: 0.01)/tolerance: 0.2)/' "$W/Tests/AppTests/LooksTests.swift"
sed -i '' 's/| 900x600 |/| 700x600 |/; /| Settings |/d' "$W/docs/LAYOUT_CONTRACT.md"
sed -i '' '/| UI-002 |/d; /| UI-003 |/d; s/| UI-001 | PlayButton |/| UI-001 | PlayControl |/' "$W/docs/COMPONENT_REGISTRY.md"
printf '| UI-003 | PlayControl | 2026-11-10 |\n' >>"$W/docs/COMPONENT_REGISTRY.md"
out="$(weaken)"
expect_result "weakened: a larger tolerance in a test is reported" 0 'Tests/AppTests/LooksTests\.swift: tolerance raised \(0\.01 -> 0\.2\)' "$out"
expect_result "weakened: a lower Min in the layout contract is reported" 0 'docs/LAYOUT_CONTRACT\.md: Min of Library lowered \(900x600 -> 700x600\)' "$out"
expect_result "weakened: a layout row removed is reported" 0 'docs/LAYOUT_CONTRACT\.md: layout row Settings removed' "$out"
expect_result "weakened: a component gone from Components is reported" 0 'docs/COMPONENT_REGISTRY\.md: UI-002 Badge no longer under Components' "$out"
expect_result "weakened: a retired component and a renamed one (same ID) are not" 0 'swift-harness' "$out" 'UI-003|UI-001'
hook session-start.sh "$W" '{"source":"startup"}' >/dev/null
sed -i '' 's/tolerance: 0.05)/tolerance: 0.01)/; s/| 700x600 |/| 1000x700 |/' "$W/Tests/AppTests/LooksTests.swift" "$W/docs/LAYOUT_CONTRACT.md"
expect_result "weakened: a smaller tolerance or a larger Min is not a weakening" 0 '^exit=0$' "$(weaken)" 'swift-harness'
if jq -e '.hooks.Stop[].hooks[] | select(.command | endswith("weaken-watch.sh\""))' "$PLUGIN/hooks/hooks.json" >/dev/null; then
  ok "weakened: the notice runs at the end of every turn"
else nok "weakened: the notice runs at the end of every turn"; fi

# The plugin's own test helpers carry a swiftlint:disable line: a helper copied as shipped is
# not a check made weaker. What the project adds to it still is.
WH="$(new_project weaken-helpers)"
mkdir -p "$WH/Tests/AppTests"
echo 'import XCTest' >"$WH/Tests/AppTests/AppTests.swift"
git -C "$WH" add -A && git -C "$WH" commit -qm tests
hook session-start.sh "$WH" '{"source":"startup"}' >/dev/null
weaken_helpers() { local o c; o="$(hook weaken-watch.sh "$WH" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
cp "$TEMPLATES"/tests/*.swift "$WH/Tests/AppTests/"
expect_result "weakened: the helpers copied as shipped are not reported" 0 '^exit=0$' "$(weaken_helpers)" 'swift-harness'
sed -i '' 's|^// swiftlint:disable line_length$|// swiftlint:disable line_length force_cast|' "$WH/Tests/AppTests/Screenshot.swift"
expect_result "weakened: a rule added to a helper's own line is reported" 0 'Tests/AppTests/Screenshot\.swift: 1 swiftlint:disable added \(0 -> 1\)' "$(weaken_helpers)" 'Snapshot\.swift|KeyboardCheck\.swift'
printf '// swiftlint:disable:next force_cast\nlet extra = 1\n' >>"$WH/Tests/AppTests/Snapshot.swift"
expect_result "weakened: another swiftlint:disable in a helper is reported" 0 'Tests/AppTests/Snapshot\.swift: 1 swiftlint:disable added \(0 -> 1\)' "$(weaken_helpers)"
printf '        throw XCTSkip("not today")\n' >>"$WH/Tests/AppTests/FocusOrder.swift"
expect_result "weakened: a skip added to a helper is reported, the helper's own is not" 0 'Tests/AppTests/FocusOrder\.swift: 1 skip added \(0 -> 1\)' "$(weaken_helpers)"
printf '// swiftlint:disable line_length\nlet other = 1\n' >"$WH/Tests/AppTests/OtherTests.swift"
expect_result "weakened: a helper's line in a file of another name is reported" 0 'Tests/AppTests/OtherTests\.swift: 1 swiftlint:disable added' "$(weaken_helpers)"
mkdir -p "$WH/Sources/Extra"
printf '// swiftlint:disable force_cast\nlet mine = 1\n' >"$WH/Sources/Extra/KeyboardCheck.swift"
expect_result "weakened: a file named as a helper, with a line of its own, is reported" 0 'Sources/Extra/KeyboardCheck\.swift: 1 swiftlint:disable added' "$(weaken_helpers)"

# ---------- adoption audit (#104) ----------

AD="$TMP/adopt"
mkdir -p "$AD/Sources/App" "$AD/Tests/AppTests" "$AD/UITests" "$AD/scripts" "$AD/.github/workflows" "$AD/App.xcodeproj" "$AD/App" "$AD/Config" "$AD/docs"
git -C "$AD" init -q
printf '# Demo\n\nRuns on macOS and iOS.\n' >"$AD/README.md"
printf '# Agents\n\nBuild with `swift build`. Before a pull request run `scripts/check-docs.sh`.\n' >"$AD/AGENTS.md"
printf '@AGENTS.md\n' >"$AD/CLAUDE.md"
printf -- '--indent 2\n' >"$AD/.swiftformat"
cat >"$AD/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Demo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "App"),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"]
        ),
    ]
)
EOF
echo 'let app = 1' >"$AD/Sources/App/App.swift"
printf 'import Testing\n@Test func ok() {}\n' >"$AD/Tests/AppTests/AppTests.swift"
printf 'import XCTest\nextension XCUIApplication {\n    func assertAudit() { try? performAccessibilityAudit() }\n}\n' >"$AD/UITests/AuditHelpers.swift"
printf 'import XCTest\nfinal class LibraryUITests: XCTestCase {\n    func testLibrary() { let app = XCUIApplication(); app.launchArguments = ["-UITesting"]; app.launch(); app.assertAudit() }\n}\n' >"$AD/UITests/LibraryUITests.swift"
# Anything run from the project leaves a sentinel: the scripts, and git through core.fsmonitor.
for s in build check-docs fsmonitor; do printf '#!/bin/bash\ntouch "%s/RAN-%s"\n' "$AD" "$s" >"$AD/scripts/$s.sh"; chmod +x "$AD/scripts/$s.sh"; done
printf 'swift build\n' >>"$AD/scripts/build.sh"
git -C "$AD" config core.fsmonitor "$AD/scripts/fsmonitor.sh"
printf 'build:\n\tswift build\n' >"$AD/Makefile"
printf 'name: ci\non: push\njobs:\n  build:\n    runs-on: macos-latest\n    steps:\n      - run: scripts/build.sh\n      - run: swift test\n' >"$AD/.github/workflows/ci.yml"
printf 'jobs:\n  a: [unclosed\n' >"$AD/.github/workflows/broken.yml"
printf 'garbage, not an Xcode project\n' >"$AD/App.xcodeproj/project.pbxproj"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n</dict>\n</plist>\n' >"$AD/App/App.entitlements"
printf 'API_TOKEN=sk-test-SECRET-123\n' >"$AD/.env"
printf 'KEY = sk-test-SECRET-456\n' >"$AD/Config/Secrets.xcconfig"
for i in 1 2 3; do printf '# Note %s\n' "$i" >"$AD/docs/note$i.md"; done
head -c 3000 /dev/zero | tr '\0' 'a' >"$AD/docs/huge.md"
AFAKE="$TMP/audit-fakes"; ALOG="$TMP/audit-fakes.log"; mkdir -p "$AFAKE"; : >"$ALOG"
for t in swift xcodebuild python3 make xcrun git bash-project; do printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$t" "$ALOG" >"$AFAKE/$t"; chmod +x "$AFAKE/$t"; done
audit() { local o c; o="$(PATH="$AFAKE:$PATH" CLAUDE_PLUGIN_DATA="$TMP/audit-data" SWIFT_HARNESS_AUDIT_MAX_BYTES=2000 "$SCRIPTS/audit.sh" "$@" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
before="$(snapshot "$AD")"
out="$(audit --project "$AD")"
json="$(audit --project "$AD" --json)"
if [ "$(snapshot "$AD")" = "$before" ] && [ ! -e "$TMP/audit-data" ]; then ok "audit: writes nothing, in the project or the plugin data"
else nok "audit: writes nothing, in the project or the plugin data" "$(diff <(printf '%s\n' "$before") <(snapshot "$AD") | head)"; fi
if [ ! -s "$ALOG" ] && ! ls "$AD"/RAN-* >/dev/null 2>&1; then ok "audit: runs nothing: no swift, xcodebuild, make, git, and no project script (V-09)"
else nok "audit: runs nothing: no swift, xcodebuild, make, git, and no project script (V-09)" "$(cat "$ALOG"; ls "$AD"/RAN-* 2>/dev/null)"; fi
expect_result "audit: an executable build script is listed as configured, not run (V-09)" 0 '\| scripts \| configured \| scripts/build\.sh \| executable, not run by the audit \|' "$out"
expect_result "audit: a platform only a document claims is declared, and nothing ran (V-01)" 0 '\| platforms \| declared \| README\.md \| iOS, macOS mentioned \|' "$out" 'platforms \| (configured|executed) \|[^|]*\| [^|]*iOS'
expect_result "audit: ... with no record, nothing is said to have run" 0 '\| executed \| unknown \| - \| no end-of-turn record' "$out"
expect_result "audit: an accessibility helper used by one test: observed, and the screens it reaches unknown (V-07)" 0 '\| accessibility \| observed \| UITests/AuditHelpers\.swift \| an accessibility audit in 1 file\(s\), called from 1 other UI test file\(s\) \|' "$out"
expect_result "audit: ... never a claim about every screen (V-07)" 0 '\| accessibility \| unknown \| UITests/ \| which screens the UI tests open is not known without running them \|' "$out"
expect_result "audit: the project's own agent rules and formatter are kept (V-08)" 0 '\| agent rules \| configured \| AGENTS\.md \| [0-9]+ lines; kept as they are \|' "$out"
expect_result "audit: ... the project's docs check is reused, not duplicated (V-08)" 0 'the project has its own docs check: run it instead of the harness.s, with --docs-command "scripts/check-docs.sh" \(docs.command\)' "$out"
expect_result "audit: a workflow that cannot be read as YAML is unknown, with the reason (V-15)" 0 '\| ci \| unknown \| \.github/workflows/broken\.yml \| cannot be read as YAML: brackets that do not close \|' "$out"
expect_result "audit: ... a well-formed one is configured, checked but not parsed" 0 '\| ci \| configured \| \.github/workflows/ci\.yml \| workflow \(structure checked, not parsed\) \|' "$out"
expect_result "audit: an Xcode project it cannot read is unknown, not guessed (V-15)" 0 '\| build \| unknown \| App\.xcodeproj/project\.pbxproj \| not a readable Xcode project file' "$out"
expect_result "audit: a file over the read limit is listed as not read (V-17)" 0 '^- docs/huge\.md: 3000 bytes, over the 2000 read limit$' "$out"
expect_result "audit: past the file limit the result says incomplete, with the numbers (V-17)" 0 'INCOMPLETE: listed the first 5 of [0-9]+ files' "$(SWIFT_HARNESS_AUDIT_MAX_FILES=5 audit --project "$AD")"
if ! grep -q 'SECRET' <<<"$out$json" && grep -q '^- \.env: may hold secrets: not opened$' <<<"$out" && grep -q '^- Config/Secrets\.xcconfig: may hold secrets: not opened$' <<<"$out"; then
  ok "audit: files that may hold secrets are listed by path, never opened or printed (V-18)"
else nok "audit: files that may hold secrets are listed by path, never opened or printed (V-18)" "$(grep -n 'SECRET\|secrets' <<<"$out$json")"; fi
expect_result "audit: the test targets are read across lines, the platforms from the manifest" 0 '\| tests \| configured \| Package\.swift \| test targets: AppTests \|' "$out"
expect_result "audit: the proposal uses the project's own commands, cost not measured" 0 '^- fast: swift build \(the project.s own\)$' "$out"
if [ "$(jq -c '[.writes, .project_code_run, .proposal.cost, .proposal.full]' <<<"${json#*$'\n'}")" = '[0,0,"not measured","swift test"]' ]; then ok "audit: --json says no writes, no project code run, cost not measured"
else nok "audit: --json says no writes, no project code run, cost not measured" "${json#*$'\n'}"; fi
# #167: the CI runner ignores SIGPIPE, so a writer whose reader has gone prints an error instead
# of dying quietly. first_cmd's reader stopped at the first command while the next awk (the
# scripts, then the CI files) still had to write. A slow awk for those makes the race certain.
ASLOW="$TMP/audit-slow-awk"; mkdir -p "$ASLOW"
printf '#!/bin/bash\ncase " $* " in *" src=scripts "* | *" src=ci "*) sleep 0.3 ;; esac\nexec %s "$@"\n' "$(command -v awk)" >"$ASLOW/awk"; chmod +x "$ASLOW/awk"
json167="$(trap '' PIPE; PATH="$ASLOW:$PATH" audit --project "$AD" --json)"
if [ "$(jq -c '.proposal.full' <<<"${json167#*$'\n'}" 2>/dev/null)" = '"swift test"' ] && ! grep -q 'awk:' <<<"$json167"; then ok "audit: a reader that stops at the first command leaves no writer behind (#167)"
else nok "audit: a reader that stops at the first command leaves no writer behind (#167)" "$(printf '%s\n' "$json167" | head -4)"; fi
# What a passing lint or formatter looks at, read from its config (#105, H1).
AR="$TMP/adopt-rules"; mkdir -p "$AR"
printf 'disabled_rules:\n  - force_cast\n  - line_length # long lines are fine here\nopt_in_rules:\n  - empty_count\nexcluded:\n  - Pods\n' >"$AR/.swiftlint.yml"
printf '{"version": 1, "rules": {"AlwaysUseLowerCamelCase": false, "NoBlockComments": true}}\n' >"$AR/.swift-format"
out="$(audit --project "$AR")"
expect_result "audit: the rules a lint config turns off are named: a passing lint does not look at them" 0 '\| lint \| observed \| \.swiftlint\.yml \| rules turned off \(2\), so a passing lint does not look at them: force_cast, line_length \|' "$out"
expect_result "audit: ... and the opt-in rules it turns on" 0 '\| lint \| observed \| \.swiftlint\.yml \| opt-in rules turned on \(1\): empty_count \|' "$out"
expect_result "audit: a swift-format rule set to false is named" 0 '\| formatter \| observed \| \.swift-format \| rules turned off \(1\): AlwaysUseLowerCamelCase \|' "$out"
printf 'only_rules:\n  - trailing_whitespace\n' >"$AR/.swiftlint.yml"
expect_result "audit: an only-list is said as such" 0 '\| lint \| observed \| \.swiftlint\.yml \| only these rules run \(1\): trailing_whitespace \|' "$(audit --project "$AR")"

# With the harness's own record for the folder, what ran is executed.
mkdir -p "$TMP/audit-data/state/$(printf '%s' "$(cd "$AD" && pwd -P)" | shasum | cut -c1-16)"
printf '%s\n' '{"version":1,"time":"2026-11-08T10:00:00Z","code":"x","outcome":"passed","checks":[{"name":"scripts/verify.sh fast","result":"passed","detail":"checked on macOS, tested on macOS"}]}' >"$TMP/audit-data/state/$(printf '%s' "$(cd "$AD" && pwd -P)" | shasum | cut -c1-16)/evidence.json"
expect_result "audit: the harness's end-of-turn record makes a check executed" 0 '\| executed \| executed \| end-of-turn record \| scripts/verify\.sh fast: passed at 2026-11-08T10:00:00Z \(checked on macOS, tested on macOS\) \|' "$(audit --project "$AD")"

# ---------- evidence over time (#110) ----------

HI="$(new_project history)"
hook session-start.sh "$HI" '{"source":"startup"}' >/dev/null
HF="$(state_of "$HI")/evidence-history.jsonl"
for i in 1 2 3; do echo "let app = 1$i" >"$HI/Sources/App.swift"; hook stop-verify.sh "$HI" >/dev/null 2>&1; done
if [ "$(jq -sc 'map([.outcome, (.code | length), .session])' "$HF")" = '[["passed",40,"test"],["passed",40,"test"],["passed",40,"test"]]' ] && [ "$(jq -s 'map(.code) | unique | length' "$HF")" = 3 ]; then
  ok "history: one record per end of turn, each with its own code identity and session"
else nok "history: one record per end of turn, each with its own code identity and session" "$(cat "$HF")"; fi
if [ "$(jq -c '[.checks[] | select(.name == "scripts/verify.sh fast") | (.seconds | type)]' "$(state_of "$HI")/evidence.json")" = '["number"]' ]; then ok "history: a check that ran has its duration in seconds"
else nok "history: a check that ran has its duration in seconds" "$(cat "$(state_of "$HI")/evidence.json")"; fi
hook stop-verify.sh "$HI" >/dev/null 2>&1; hook stop-verify.sh "$HI" >/dev/null 2>&1
if [ "$(jq -sc 'map(.outcome)' "$HF")" = '["passed","passed","passed","unchanged"]' ]; then ok "history: nothing running again on the same code is recorded once, not every turn"
else nok "history: nothing running again on the same code is recorded once, not every turn" "$(jq -sc 'map(.outcome)' "$HF")"; fi
for i in 4 5 6; do echo "let app = 2$i" >"$HI/Sources/App.swift"; SWIFT_HARNESS_HISTORY_MAX=3 hook stop-verify.sh "$HI" >/dev/null 2>&1; done
if [ "$(wc -l <"$HF" | tr -d ' ')" = 3 ] && [ "$(tail -n 1 "$HF" | jq -r .code)" = "$(jq -r .code "$(state_of "$HI")/evidence.json")" ]; then ok "history: trimmed to the limit, keeping the newest"
else nok "history: trimmed to the limit, keeping the newest" "$(wc -l <"$HF")"; fi
{ printf '%s\n' '{"version":1,"time":"2000-01-01T00:00:00Z","code":"old","outcome":"passed","checks":[]}'; cat "$HF"; } >"$HF.new" && mv "$HF.new" "$HF"
echo 'let app = 30' >"$HI/Sources/App.swift"; hook stop-verify.sh "$HI" >/dev/null 2>&1
if ! grep -q '"code":"old"' "$HF"; then ok "history: records older than the session retention are dropped"
else nok "history: records older than the session retention are dropped"; fi
mkdir "$(state_of "$HI")/evidence-history.lock"
for i in 7 8; do echo "let app = 4$i" >"$HI/Sources/App.swift"; SWIFT_HARNESS_HISTORY_MAX=2 hook stop-verify.sh "$HI" >/dev/null 2>&1; done
n="$(wc -l <"$HF" | tr -d ' ')"
rmdir "$(state_of "$HI")/evidence-history.lock"
if [ "$n" -gt 2 ]; then ok "history: while another session holds the lock, nothing is trimmed (and nothing lost)"
else nok "history: while another session holds the lock, nothing is trimmed (and nothing lost)" "$n lines"; fi
CLH="$(state_of "$HI")/catches.jsonl"; : >"$CLH"
echo 'let app = 50' >"$HI/Sources/App.swift"
FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$HI" >/dev/null 2>&1
if [ "$(jq -c '[.kind, .code, (.seconds | type)]' "$CLH")" = "[\"blocked\",\"$(jq -r .code "$(state_of "$HI")/evidence.json")\",\"number\"]" ]; then
  ok "history: a block in the catch log carries the code identity and the check's duration"
else nok "history: a block in the catch log carries the code identity and the check's duration" "$(cat "$CLH")"; fi
expect_result "history: the report counts the end-of-turn records of the period" 0 '^End of turn: [0-9]+ record\(s\) \([0-9]+ failed, [0-9]+ passed[^)]*\); the checks that ran took [0-9]+ s\.$' "$(report --project "$HI" --all)"

# ---------- approval across worktrees (#107) ----------

WA="$(new_project worktree-main)"
WB="$TMP/worktree-b"
git -C "$WA" worktree add -q "$WB" -b feature 2>/dev/null
WLOG="$TMP/worktree.log"; : >"$WLOG"
echo 'let app = 2' >"$WB/Sources/App.swift"
FAKE_VERIFY_LOG="$WLOG" hook stop-verify.sh "$WB" >/dev/null 2>&1
if [ "$(wc -l <"$WLOG" | tr -d ' ')" = 1 ]; then ok "worktrees: a worktree of the same repository with identical files inherits the approval"
else nok "worktrees: a worktree of the same repository with identical files inherits the approval" "runs: $(wc -l <"$WLOG")"; fi
expect_result "worktrees: status says where the approval comes from" 0 "Status: approved, inherited from the $(cd "$WA" && pwd -P) worktree of this repository" "exit=0
$(approval "$WB" --status)"
expect_row "worktrees: doctor says the approval was given in another worktree" "$(doctor "$WB")" PASS "Verify approval" 'approved in another worktree of this repository'
printf '#!/bin/bash\necho changed\n' >"$WB/scripts/verify.sh"
: >"$WLOG"; echo 'let app = 3' >"$WB/Sources/App.swift"
FAKE_VERIFY_LOG="$WLOG" hook stop-verify.sh "$WB" >/dev/null 2>&1
if [ ! -s "$WLOG" ] && approval "$WB" --status | grep -q '^Status: not approved'; then ok "worktrees: a changed file in the worktree asks again (V-12)"
else nok "worktrees: a changed file in the worktree asks again (V-12)" "$(approval "$WB" --status | grep Status)"; fi
git -C "$WB" checkout -q -- scripts/verify.sh
WC="$TMP/worktree-clone"; cp -R "$WA" "$WC"
if approval "$WC" --status | grep -q '^Status: not approved'; then ok "worktrees: another repository with the same files never inherits"
else nok "worktrees: another repository with the same files never inherits" "$(approval "$WC" --status | grep Status)"; fi
approval "$WB" --revoke >/dev/null
if approval "$WB" --status | grep -q '^Status: not approved' && approval "$WA" --status | grep -q '^Status: approved$'; then
  ok "worktrees: revoking removes what the worktrees share; the main checkout keeps its own approval"
else nok "worktrees: revoking removes what the worktrees share; the main checkout keeps its own approval" "B: $(approval "$WB" --status | grep Status); A: $(approval "$WA" --status | grep Status)"; fi

# ---------- adapters: the project's own docs check (#105) ----------

DA="$(new_project adapter)"
mkdir -p "$DA/docs"
printf '# Old\n\nOLD-PROBLEM\n' >"$DA/docs/old.md"
cat >"$DA/scripts/check-docs.sh" <<'EOF'
#!/bin/bash
echo run >>"${ADAPTER_LOG:-/dev/null}"
cd "$(dirname "$0")/.." || exit 2
found=0
for f in docs/*.md; do grep -n 'PROBLEM' "$f" | sed "s#^#$f:#" && found=1; done
exit "$found"
EOF
chmod +x "$DA/scripts/check-docs.sh"
set_config "$DA" '{"verify":{"command":"scripts/verify.sh fast"},"docs":{"command":"scripts/check-docs.sh"}}'
git -C "$DA" add -A && git -C "$DA" commit -qm adapter
expect_result "adapter: the verify approval covers the docs command and its script" 0 'file scripts/check-docs\.sh [0-9a-f]{64}|scripts/check-docs\.sh' "exit=0
$(approval "$DA" --status)"
ALOGA="$TMP/adapter.log"; : >"$ALOGA"
hook session-start.sh "$DA" '{"source":"startup"}' >/dev/null 2>&1
printf 'more\n' >>"$DA/docs/old.md"
out="$(ADAPTER_LOG="$ALOGA" ev_stop "$DA")"
if [ ! -s "$ALOGA" ] && [ "$(ev_of "$DA" '.checks[] | select(.name == "docs: scripts/check-docs.sh") | .result')" = '"not run"' ]; then
  ok "adapter: not approved, the project's command does not run, and the record says so"
else nok "adapter: not approved, the project's command does not run, and the record says so" "$out $(cat "$ALOGA")"; fi
approve "$DA" >/dev/null
ADAPTER_LOG="$ALOGA" hook session-start.sh "$DA" '{"source":"startup"}' >/dev/null 2>&1
: >"$ALOGA"
printf 'still old\n' >>"$DA/docs/old.md"
out="$(ADAPTER_LOG="$ALOGA" ev_stop "$DA")"
if [[ "$out" == exit=0* ]] && [ "$(ev_of "$DA" '.checks[] | select(.name == "docs: scripts/check-docs.sh") | [.result, .detail]')" = '["failed","exit 1, only problems already there at session start"]' ]; then
  ok "adapter: problems already there at session start are recorded, and do not block"
else nok "adapter: problems already there at session start are recorded, and do not block" "$out"; fi
printf '# New\n\nNEW-PROBLEM\n' >"$DA/docs/new.md"
out="$(ADAPTER_LOG="$ALOGA" ev_stop "$DA")"
expect_result "adapter: a new problem blocks, with the project's own output" 2 "The project's docs check \(scripts/check-docs\.sh\) found problems.*docs/new\.md" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^exit=2 /exit=2\n/')"
if [ "$(ev_of "$DA" '[.outcome, (.checks[] | select(.name == "docs: scripts/check-docs.sh") | .result)]')" = '["failed","failed"]' ] && tail -n 1 "$(state_of "$DA")/catches.jsonl" | jq -e '.kind == "blocked" and .check == "docs: scripts/check-docs.sh"' >/dev/null; then
  ok "adapter: the block is in the evidence record and the catch log"
else nok "adapter: the block is in the evidence record and the catch log" "$(tail -n 1 "$(state_of "$DA")/catches.jsonl")"; fi
printf 'x\n' >>"$DA/docs/new.md"
expect_result "adapter: the same new problems do not block twice" 0 '^exit=0' "$(ADAPTER_LOG="$ALOGA" ev_stop "$DA" '{"stop_hook_active":true}')"
rm "$DA/docs/new.md"
runs="$(wc -l <"$ALOGA" | tr -d ' ')"
ADAPTER_LOG="$ALOGA" ev_stop "$DA" >/dev/null
if tail -n 1 "$(state_of "$DA")/catches.jsonl" | jq -e '.kind == "fixed"' >/dev/null; then ok "adapter: fixing the docs is recorded as fixed"
else nok "adapter: fixing the docs is recorded as fixed" "$(tail -n 2 "$(state_of "$DA")/catches.jsonl")"; fi
runs2="$(wc -l <"$ALOGA" | tr -d ' ')"
ADAPTER_LOG="$ALOGA" ev_stop "$DA" >/dev/null
if [ "$(wc -l <"$ALOGA" | tr -d ' ')" = "$runs2" ] && [ "$runs2" -gt "$runs" ] && [ "$(ev_of "$DA" '[.checks[] | select(.name == "docs: scripts/check-docs.sh")] | length')" = 1 ]; then
  ok "adapter: with the docs unchanged it does not run again, and the record keeps its result"
else nok "adapter: with the docs unchanged it does not run again, and the record keeps its result" "runs $runs $runs2 $(wc -l <"$ALOGA")"; fi
set_config "$DA" '{"verify":{"command":"scripts/verify.sh fast"},"docs":{"command":"scripts/check-docs.sh","blocking":false}}'
approve "$DA" >/dev/null
printf '# New\n\nNEW-PROBLEM-2\n' >"$DA/docs/new2.md"
out="$(ADAPTER_LOG="$ALOGA" ev_stop "$DA")"
if [[ "$out" == exit=0* ]] && tail -n 1 "$(state_of "$DA")/catches.jsonl" | jq -e '.kind == "observed"' >/dev/null; then ok "adapter: with docs.blocking false a new problem is recorded as observed, never blocking"
else nok "adapter: with docs.blocking false a new problem is recorded as observed, never blocking" "$out"; fi
CLA="$(state_of "$DA")/catches.jsonl"
printf 'z\n' >>"$DA/docs/new2.md"
ADAPTER_LOG="$ALOGA" ev_stop "$DA" >/dev/null
if [ "$(grep -c '"kind":"observed"' "$CLA")" = 1 ]; then ok "adapter H2: the same observed problems are logged once"
else nok "adapter H2: the same observed problems are logged once" "$(tail -n 3 "$CLA")"; fi
rm "$DA/docs/new2.md"
ADAPTER_LOG="$ALOGA" ev_stop "$DA" >/dev/null
if tail -n 1 "$CLA" | jq -e '.kind == "fixed" and (.what | startswith("observed problems gone"))' >/dev/null; then ok "adapter H2: observed problems that go away are logged as fixed"
else nok "adapter H2: observed problems that go away are logged as fixed" "$(tail -n 2 "$CLA")"; fi
expect_result "adapter H2: the report waits for 10 observed findings before it proposes anything" 0 'docs: scripts/check-docs\.sh: 1 episode\(s\) in 1 session\(s\), 1 fixed in their session: too few to decide' "exit=0
$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$DA" 2>&1)"
HR="$(new_project h2-report)"; HRL="$(state_of "$HR")/catches.jsonl"; mkdir -p "$(dirname "$HRL")"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf '{"time":"2099-01-01T00:00:0%sZ","session":"s%s","check":"docs: d","kind":"observed","what":"1 new"}\n' "$((i % 10))" "$i" >>"$HRL"
  [ "$i" -gt 10 ] || printf '{"time":"2099-01-01T00:00:0%sZ","session":"s%s","check":"docs: d","kind":"fixed","what":"observed problems gone: passes again"}\n' "$((i % 10))" "$i" >>"$HRL"
done
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$HR" --json 2>&1)"
if [ "$(jq -c '.checks[] | select(.check == "docs: d") | [.observed, .observed_fixed, .promotion.proposal]' <<<"$out")" = '[11,10,"block"]' ]; then ok "adapter H2: more than 90% of 10 or more observed findings fixed: the report proposes blocking"
else nok "adapter H2: more than 90% of 10 or more observed findings fixed: the report proposes blocking" "$out"; fi
printf '{"time":"2099-01-01T00:00:09Z","session":"s12","check":"docs: d","kind":"observed","what":"1 new"}\n' >>"$HRL"
expect_result "adapter H2: with fewer fixed, the report says to look at the others first" 0 '12 episode\(s\) in 12 session\(s\), 10 fixed in their session: look at the others' "exit=0
$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$HR" 2>&1)"
printf '#!/bin/bash\necho "check-docs: python not found" >&2\nexit 127\n' >"$DA/scripts/check-docs.sh"
approve "$DA" >/dev/null
printf 'y\n' >>"$DA/docs/old.md"
out="$(ev_stop "$DA")"
if [ "$(ev_of "$DA" '.checks[] | select(.name == "docs: scripts/check-docs.sh") | [.result, .detail]')" = '["not checked","exit 127: check-docs: python not found"]' ] && grep -q 'Not checked this turn\|not checked: docs: scripts/check-docs.sh' <<<"$out"; then
  ok "adapter: a check that cannot run (exit other than 0 or 1) is not checked, and the user is told"
else nok "adapter: a check that cannot run (exit other than 0 or 1) is not checked, and the user is told" "$out"; fi
expect_result "adapter: docs-watch leaves the docs to the project's check" 0 '^exit=0$' "$(ev_stop_hook() { local o c; o="$(hook docs-watch.sh "$DA" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }; printf 'Broken [link](docs/none.md)\n' >>"$DA/CLAUDE.md"; ev_stop_hook)"
expect_row "adapter: doctor names the project's check as the docs check" "$(doctor "$DA")" PASS "Docs references" "the project's own check 'scripts/check-docs\.sh' runs instead of the harness's; observed"
# check-sensitivity credits the project's check for the docs operator (H1 case: a script).
MA="$TMP/mutate-adapter"; cp -R "$HERE/fixtures/mutate" "$MA"
printf '#!/bin/bash\ncd "$(dirname "$0")" || exit 2\nfor t in $(grep -oE "\\\\]\\\\([^)]+\\\\)" CLAUDE.md | sed "s/^](//; s/)$//"); do [ -e "$t" ] || { echo "CLAUDE.md: missing $t"; exit 1; }; done\n' >"$MA/scripts-check-links.sh"
chmod +x "$MA/scripts-check-links.sh"
printf '%s\n' '{"registry":{"sources":["Sources/DesignSystem"]},"docs":{"command":"./scripts-check-links.sh"}}' >"$MA/.claude/swift-harness.json"
expect_result "adapter: check-sensitivity credits the project's docs check (with --verify)" 0 '^\| docs-stale-link \| [^|]+ \| docs \| killed \| docs \|$' "$(mutate --project "$MA" --verify --only docs-stale-link)"
G3="$TMP/guest-docs"; mkdir -p "$G3"
"$SCRIPTS/setup-guest.sh" --project "$G3" --fast 'swift build' --docs-command 'scripts/check-docs.sh' >/dev/null
if [ "$(jq -c '.docs' "$G3/.claude/swift-harness.json")" = '{"command":"scripts/check-docs.sh"}' ]; then ok "adapter: setup-guest --docs-command sets docs.command"
else nok "adapter: setup-guest --docs-command sets docs.command" "$(cat "$G3/.claude/swift-harness.json")"; fi

# ---------- adapters: the project's own lint and formatter (#125) ----------

LA="$(new_project lint-adapter)"
cat >"$LA/scripts/lint.sh" <<'EOF'
#!/bin/bash
echo run >>"${LINT_LOG:-/dev/null}"
cd "$(dirname "$0")/.." || exit 2
found=0
for f in Sources/*.swift; do grep -n 'TODO' "$f" | sed "s#^#$f:#" && found=1; done
exit "$found"
EOF
chmod +x "$LA/scripts/lint.sh"
echo 'let old = 1 // TODO old' >"$LA/Sources/Old.swift"
set_config "$LA" '{"verify":{"command":"scripts/verify.sh fast"},"lint":{"command":"scripts/lint.sh"}}'
git -C "$LA" add -A && git -C "$LA" commit -qm lint
expect_result "lint adapter: the verify approval covers the lint command and its script" 0 'scripts/lint\.sh' "exit=0
$(approval "$LA" --status)"
approve "$LA" >/dev/null
LLOG="$TMP/lint-adapter.log"; : >"$LLOG"
LINT_LOG="$LLOG" hook session-start.sh "$LA" '{"source":"startup"}' >/dev/null 2>&1
SLOG="$TMP/lint-adapter-tools.log"; : >"$SLOG"
mkdir -p "$TMP/fake-tools"
for t in swiftlint swiftformat; do printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$t" "$SLOG" >"$TMP/fake-tools/$t"; chmod +x "$TMP/fake-tools/$t"; done
echo 'let app = 2' >"$LA/Sources/App.swift"
PATH="$TMP/fake-tools:$PATH" hook post-edit.sh "$LA" "$(edit_input "$LA/Sources/App.swift")" >/dev/null 2>&1
if ! grep -q '^swiftlint' "$SLOG"; then ok "lint adapter: the harness's SwiftLint does not run"
else nok "lint adapter: the harness's SwiftLint does not run" "$(cat "$SLOG")"; fi
out="$(LINT_LOG="$LLOG" ev_stop "$LA")"
if [[ "$out" == exit=0* ]] && [ "$(ev_of "$LA" '.checks[] | select(.name == "lint: scripts/lint.sh") | [.result, .detail]')" = '["failed","exit 1, only problems already there at session start"]' ]; then
  ok "lint adapter: violations already there at session start are recorded, and do not block"
else nok "lint adapter: violations already there at session start are recorded, and do not block" "$out $(ev_of "$LA" .checks)"; fi
echo 'let todo = 3 // TODO new' >>"$LA/Sources/App.swift"
out="$(LINT_LOG="$LLOG" ev_stop "$LA")"
expect_result "lint adapter: a new violation blocks, with the project's own output" 2 "The project's lint check \(scripts/lint\.sh\) found problems.*Sources/App\.swift:2:let todo" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^exit=2 /exit=2\n/')"
if [ "$(ev_of "$LA" '.checks[] | select(.name == "lint: scripts/lint.sh") | .result')" = '"failed"' ] && tail -n 1 "$(state_of "$LA")/catches.jsonl" | jq -e '.kind == "blocked" and .check == "lint: scripts/lint.sh"' >/dev/null; then
  ok "lint adapter: the evidence record and the catch log name the project's lint"
else nok "lint adapter: the evidence record and the catch log name the project's lint" "$(tail -n 1 "$(state_of "$LA")/catches.jsonl")"; fi
echo 'let more = 4' >>"$LA/Sources/App.swift"
expect_result "lint adapter: the same new violations do not block twice" 0 '^exit=0' "$(LINT_LOG="$LLOG" ev_stop "$LA" '{"stop_hook_active":true}')"
echo 'let app = 2' >"$LA/Sources/App.swift"
LINT_LOG="$LLOG" ev_stop "$LA" >/dev/null
if tail -n 1 "$(state_of "$LA")/catches.jsonl" | jq -e '.kind == "fixed" and .check == "lint: scripts/lint.sh"' >/dev/null; then ok "lint adapter: fixing the violation is recorded as fixed"
else nok "lint adapter: fixing the violation is recorded as fixed" "$(tail -n 2 "$(state_of "$LA")/catches.jsonl")"; fi
runs="$(wc -l <"$LLOG" | tr -d ' ')"
LINT_LOG="$LLOG" ev_stop "$LA" >/dev/null
if [ "$(wc -l <"$LLOG" | tr -d ' ')" = "$runs" ]; then ok "lint adapter: with the code unchanged it does not run again"
else nok "lint adapter: with the code unchanged it does not run again" "runs $runs $(wc -l <"$LLOG")"; fi
set_config "$LA" '{"verify":{"command":"scripts/verify.sh fast"},"lint":{"command":"scripts/lint.sh","blocking":false}}'
approve "$LA" >/dev/null
echo 'let todo = 5 // TODO observed' >>"$LA/Sources/App.swift"
out="$(LINT_LOG="$LLOG" ev_stop "$LA")"
if [[ "$out" == exit=0* ]] && tail -n 1 "$(state_of "$LA")/catches.jsonl" | jq -e '.kind == "observed" and (.what | contains("lint.blocking is false"))' >/dev/null; then
  ok "lint adapter: with lint.blocking false a new violation is observed, never blocking"
else nok "lint adapter: with lint.blocking false a new violation is observed, never blocking" "$out $(tail -n 1 "$(state_of "$LA")/catches.jsonl")"; fi
printf '%s\n' "$(cat "$LA/scripts/lint.sh")" '# changed' >"$LA/scripts/lint.sh"
echo 'let app = 6' >>"$LA/Sources/App.swift"
: >"$LLOG"
out="$(LINT_LOG="$LLOG" ev_stop "$LA")"
if [ ! -s "$LLOG" ] && [ "$(ev_of "$LA" '.checks[] | select(.name == "lint: scripts/lint.sh") | .result')" = '"not run"' ]; then
  ok "lint adapter: a changed lint script is not approved any more, and does not run"
else nok "lint adapter: a changed lint script is not approved any more, and does not run" "$out $(cat "$LLOG")"; fi
HL="$(new_project h2-lint)"; HLL="$(state_of "$HL")/catches.jsonl"; mkdir -p "$(dirname "$HLL")"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf '{"time":"2099-01-01T00:00:0%sZ","session":"s%s","check":"lint: l","kind":"observed","what":"1 new"}\n' "$((i % 10))" "$i" >>"$HLL"
  printf '{"time":"2099-01-01T00:00:0%sZ","session":"s%s","check":"lint: l","kind":"fixed","what":"observed problems gone: passes again"}\n' "$((i % 10))" "$i" >>"$HLL"
done
expect_result "lint adapter: in observation the report proposes lint.blocking, with the docs thresholds" 0 'lint: l: 11 episode\(s\) in 11 session\(s\), 11 fixed in their session. If those findings were right, not just obeyed, set lint\.blocking to true' "exit=0
$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$HL" 2>&1)"
approve "$LA" >/dev/null
expect_row "lint adapter: doctor names the project's lint" "$(doctor "$LA")" PASS SwiftLint "the project's own lint 'scripts/lint\.sh' runs instead of SwiftLint"
set_config "$LA" '{"verify":{"command":"scripts/verify.sh fast"},"lint":{"command":3}}'
expect_row "lint adapter: doctor rejects a lint command that is not a command line" "$(doctor "$LA")" FAIL Config "lint\.command must be a command line"

FA="$(new_project format-adapter)"
cat >"$FA/scripts/format-check.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.." || exit 2
found=0
for f in Sources/*.swift; do grep -n '	' "$f" | sed "s#^#$f:#" && found=1; done
exit "$found"
EOF
chmod +x "$FA/scripts/format-check.sh"
set_config "$FA" '{"verify":{"command":"scripts/verify.sh fast"},"format":{"command":"scripts/format-check.sh"}}'
git -C "$FA" add -A && git -C "$FA" commit -qm format
approve "$FA" >/dev/null
hook session-start.sh "$FA" '{"source":"startup"}' >/dev/null 2>&1
: >"$SLOG"
printf 'let app = 1\n\tlet tab = 2\n' >"$FA/Sources/App.swift"
PATH="$TMP/fake-tools:$PATH" hook post-edit.sh "$FA" "$(edit_input "$FA/Sources/App.swift")" >/dev/null 2>&1
if ! grep -q '^swiftformat' "$SLOG"; then ok "format adapter: the harness's formatter does not run"
else nok "format adapter: the harness's formatter does not run" "$(cat "$SLOG")"; fi
out="$(ev_stop "$FA")"
expect_result "format adapter: a new formatting problem blocks, with the project's own output" 2 "The project's format check \(scripts/format-check\.sh\) found problems.*Sources/App\.swift:2:" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^exit=2 /exit=2\n/')"
expect_row "format adapter: doctor names the project's formatter" "$(doctor "$FA")" PASS Formatter "the project's own format check 'scripts/format-check\.sh' runs instead of the harness's formatter"
G4="$TMP/guest-lint"; mkdir -p "$G4"
"$SCRIPTS/setup-guest.sh" --project "$G4" --fast 'swift build' --lint-command 'make lint' --lint-observe --format-command 'scripts/format-check.sh' >/dev/null
if [ "$(jq -c '[.lint, .format]' "$G4/.claude/swift-harness.json")" = '[{"command":"make lint","blocking":false},{"command":"scripts/format-check.sh"}]' ]; then ok "adapters: setup-guest --lint-command, --lint-observe and --format-command set lint and format"
else nok "adapters: setup-guest --lint-command, --lint-observe and --format-command set lint and format" "$(cat "$G4/.claude/swift-harness.json")"; fi

# ---------- one engine for every agent: check.sh (#106) ----------

chk() { local o c; o="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" "$@" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
CK="$(new_project check-cli)"
CKL="$TMP/check-cli.log"; : >"$CKL"
echo 'let app = 2' >"$CK/Sources/App.swift"
out="$(FAKE_VERIFY_LOG="$CKL" chk --project "$CK" --agent codex)"
expect_result "check: from a shell, the approved verify command runs and passes" 0 'Result: passed\.' "$out"
cli_checks="$(jq -c '[.session, (.checks | map([.name, .result]))]' "$(state_of "$CK")/evidence.json")"
echo 'let app = 3' >"$CK/Sources/App.swift"
FAKE_VERIFY_LOG="$CKL" hook stop-verify.sh "$CK" >/dev/null 2>&1
hook_checks="$(jq -c '[.session, (.checks | map([.name, .result]))]' "$(state_of "$CK")/evidence.json")"
if [ "${cli_checks#*,}" = "${hook_checks#*,}" ] && [[ "$cli_checks" == '["agent-codex",'* ]]; then ok "check: the same checks and results as the Stop hook, recorded as the agent's session"
else nok "check: the same checks and results as the Stop hook, recorded as the agent's session" "cli $cli_checks hook $hook_checks"; fi
expect_result "check: code that passed before is not run again, and says so" 0 'Outcome: unchanged.*Result: passed' "$(chk --project "$CK" --agent codex | tr '\n' ' ' | sed 's/^exit=0 /exit=0\n/')"
echo 'let app = 4' >"$CK/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=1 chk --project "$CK" --agent codex)"
expect_result "check: a failing check exits 1 with the failure output" 1 'Verification failed.*Result: FAILED' "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^exit=1 /exit=1\n/')"
if tail -n 1 "$(state_of "$CK")/catches.jsonl" | jq -e '.session == "agent-codex" and .kind == "blocked"' >/dev/null; then ok "check: the catch log names the agent"
else nok "check: the catch log names the agent" "$(tail -n 1 "$(state_of "$CK")/catches.jsonl")"; fi
printf '#!/bin/bash\necho changed\n' >"$CK/scripts/verify.sh"
expect_result "check: an unapproved verify command is not run: exit 3, not verified" 3 'Result: NOT VERIFIED: the verify command did not run\.' "$(chk --project "$CK")"
expect_result "check: --json gives the record and the exit" 3 '"exit": 3' "$(chk --project "$CK" --json)"
git -C "$CK" checkout -q -- scripts/verify.sh
# The data folder the hooks use, found without CLAUDE_PLUGIN_DATA.
FH="$TMP/fake-home"; mkdir -p "$FH/.claude/plugins/data"
ln -s "$TMP/data" "$FH/.claude/plugins/data/swift-harness-inline"
echo 'let app = 5' >"$CK/Sources/App.swift"
expect_result "check: without CLAUDE_PLUGIN_DATA, the only swift-harness data folder is used" 0 'Result: passed\.' "$(o="$(env -u CLAUDE_PLUGIN_DATA HOME="$FH" "$SCRIPTS/check.sh" --project "$CK" 2>&1)"; printf 'exit=%s\n%s' "$?" "$o")"
mkdir -p "$FH/.claude/plugins/data/swift-harness-other"
echo 'let app = 6' >"$CK/Sources/App.swift"
expect_result "check: with two, the one that holds this project's approval" 0 'Result: passed\.' "$(o="$(env -u CLAUDE_PLUGIN_DATA HOME="$FH" "$SCRIPTS/check.sh" --project "$CK" 2>&1)"; printf 'exit=%s\n%s' "$?" "$o")"
expect_result "check: with none, it says to set CLAUDE_PLUGIN_DATA" 2 'set CLAUDE_PLUGIN_DATA' "$(o="$(env -u CLAUDE_PLUGIN_DATA HOME="$TMP/no-home" "$SCRIPTS/check.sh" --project "$CK" 2>&1)"; printf 'exit=%s\n%s' "$?" "$o")"
# The git pre-commit recipe.
printf '#!/bin/bash\nCLAUDE_PLUGIN_DATA="%s" exec "%s/check.sh" --agent git-hook >/dev/null\n' "$TMP/data" "$SCRIPTS" >"$CK/.git/hooks/pre-commit"
chmod +x "$CK/.git/hooks/pre-commit"
echo 'let app = 7' >"$CK/Sources/App.swift"
git -C "$CK" add -A
if ! FAKE_VERIFY_EXIT=1 git -C "$CK" commit -qm "breaks" 2>/dev/null && echo 'let app = 8' >"$CK/Sources/App.swift" && git -C "$CK" add -A && git -C "$CK" commit -qm "fixed" 2>/dev/null; then ok "check: as a git pre-commit hook, a failing check stops the commit and a passing one lets it through"
else nok "check: as a git pre-commit hook, a failing check stops the commit and a passing one lets it through" "$(git -C "$CK" log --oneline -2)"; fi

# ---------- timed commands and unstable tests (#104, #108) ----------

TC="$TMP/timing"; mkdir -p "$TC"
tc() { local o c; o="$("$SCRIPTS/time-commands.sh" "$@" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
before="$(snapshot "$TC")"
# Wide margins, so a slow CI machine cannot change the split: 0.1 + 0.2 s fit a 3 s budget, 4 s does not.
out="$(tc --project "$TC" --budget 3 -- "sleep 0.1" "false" "sleep 0.2" "sleep 4")"
expect_result "timing: each command runs twice, with median, worst time and exits" 0 '\| `sleep 0\.1` \| [0-9]+\.[0-9]+, [0-9]+\.[0-9]+ \| [0-9.]+ \| [0-9]+\.[0-9]+ \| 0, 0 \|' "$out"
expect_result "timing: fast takes the commands in order while their worst times fit the budget" 0 '^- fast: sleep 0\.1 && sleep 0\.2 \(worst [0-9]+\.[0-9]+ s\)$' "$out"
expect_result "timing: a failing command is left out, and said" 0 '^- failed, left out: false' "$out"
if [ "$(snapshot "$TC")" = "$before" ]; then ok "timing: the script itself writes nothing"
else nok "timing: the script itself writes nothing"; fi
if [ "$(tc --project "$TC" --runs 3 --json -- "true" | sed 1d | jq -c '[.runs, (.commands[0].times | length), .proposal.fast, .proposal.full]')" = '[3,3,["true"],["true"]]' ]; then ok "timing: --runs and --json"
else nok "timing: --runs and --json" "$(tc --project "$TC" --runs 3 --json -- "true")"; fi
expect_result "timing: no command is a usage error" 2 'usage' "$(tc --project "$TC")"
printf 'import XCTest\nfinal class HardwareTests: XCTestCase {\n    func testDevice() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DEMO_HARDWARE"] == "1") }\n}\n' >"$AD/Tests/AppTests/HardwareTests.swift"
expect_result "timing: the audit lists tests gated by environment variables, to keep out of fast" 0 '\| tests \| observed \| Tests/AppTests/HardwareTests\.swift \| 1 test file\(s\) read environment variables \(DEMO_HARDWARE\): tests gated by them run only when set; keep them out of the fast command \|' "$(audit --project "$AD")"
rm "$AD/Tests/AppTests/HardwareTests.swift"
# verify.retryFailed: a failure that passes on a rerun is unstable, not a block.
RF="$(new_project retry)"
cat >"$RF/scripts/verify.sh" <<'EOF'
#!/bin/bash
n="$(cat "${RETRY_COUNT:?}" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$RETRY_COUNT"
if [ "$n" -lt "${RETRY_FAILS:-1}" ]; then printf 'Failing tests:\n\tAppTests.testFlaky()\n'; exit 1; fi
echo ok
EOF
set_config "$RF" '{"verify":{"command":"scripts/verify.sh fast","retryFailed":true}}'
git -C "$RF" add -A && git -C "$RF" commit -qm retry && approve "$RF" >/dev/null
hook session-start.sh "$RF" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$RF/Sources/App.swift"
out="$(RETRY_COUNT="$TMP/retry1" ev_stop "$RF")"
if [[ "$out" == exit=0* ]] && [ "$(ev_of "$RF" '.checks[] | select(.name == "scripts/verify.sh fast") | .result')" = '"passed"' ] &&
  ev_of "$RF" '.checks[] | select(.name == "scripts/verify.sh fast") | .detail' | grep -q 'failed once, passed on a rerun: unstable (AppTests.testFlaky())'; then
  ok "retry: a failure that passes on the rerun is recorded as unstable, with the test, and does not block"
else nok "retry: a failure that passes on the rerun is recorded as unstable, with the test, and does not block" "$out $(cat "$(state_of "$RF")/evidence.json")"; fi
if tail -n 1 "$(state_of "$RF")/catches.jsonl" | jq -e '.kind == "unstable" and .what == "AppTests.testFlaky()"' >/dev/null; then ok "retry: the catch log has it as unstable"
else nok "retry: the catch log has it as unstable" "$(tail -n 1 "$(state_of "$RF")/catches.jsonl")"; fi
expect_result "retry: the report counts unstable failures" 0 'unstable \(failed once, passed on a rerun\)' "$(report --project "$RF" --all)"
echo 'let app = 3' >"$RF/Sources/App.swift"
expect_result "retry: a failure on both runs still blocks" 2 'Verification failed' "$(RETRY_COUNT="$TMP/retry2" RETRY_FAILS=2 ev_stop "$RF")"
set_config "$RF" '{"verify":{"command":"scripts/verify.sh fast"}}'
approve "$RF" >/dev/null
echo 'let app = 4' >"$RF/Sources/App.swift"
expect_result "retry: without retryFailed a failure blocks at once" 2 'Verification failed' "$(RETRY_COUNT="$TMP/retry3" ev_stop "$RF")"
# The names of unstable tests come from the result bundle's lines when verify.sh prints them (#147).
RB="$(new_project retry-bundle)"
cat >"$RB/scripts/verify.sh" <<'EOF'
#!/bin/bash
n="$(cat "${RETRY_COUNT:?}" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$RETRY_COUNT"
if [ "$n" -lt 1 ]; then
  printf 'results from the result bundle (.build/swift-harness/results/test-macOS.xcresult):\n'
  printf 'failed test: AppTests/greetsByName(): Expectation failed: "Hello, Ada!" == "Hi, Ada!"\n'
  exit 1
fi
echo ok
EOF
set_config "$RB" '{"verify":{"command":"scripts/verify.sh fast","retryFailed":true}}'
git -C "$RB" add -A && git -C "$RB" commit -qm retry && approve "$RB" >/dev/null
hook session-start.sh "$RB" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$RB/Sources/App.swift"
RETRY_COUNT="$TMP/retry-bundle-count" ev_stop "$RB" >/dev/null
if tail -n 1 "$(state_of "$RB")/catches.jsonl" | jq -e '.kind == "unstable" and .what == "AppTests/greetsByName()"' >/dev/null; then ok "retry: an unstable test is named from the result bundle's lines"
else nok "retry: an unstable test is named from the result bundle's lines" "$(tail -n 1 "$(state_of "$RB")/catches.jsonl")"; fi
G5="$TMP/guest-retry"; mkdir -p "$G5"
"$SCRIPTS/setup-guest.sh" --project "$G5" --fast 'swift build' --retry-failed >/dev/null
if [ "$(jq -c '.verify.retryFailed' "$G5/.claude/swift-harness.json")" = true ]; then ok "retry: setup-guest --retry-failed sets verify.retryFailed"
else nok "retry: setup-guest --retry-failed sets verify.retryFailed" "$(cat "$G5/.claude/swift-harness.json")"; fi

# ---------- guest mode kept local, and new worktrees (#71, #105) ----------

GL="$TMP/guest-local"; mkdir -p "$GL/Scripts" "$GL/docs"; git -C "$GL" init -q
git -C "$GL" config user.email t@example.com; git -C "$GL" config user.name t
printf '# Agents\n' >"$GL/AGENTS.md"; printf '# Roadmap\n' >"$GL/docs/ROADMAP.md"; echo x >"$GL/Scripts/check-docs.sh"
git -C "$GL" add -A && git -C "$GL" commit -qm init
"$SCRIPTS/setup-guest.sh" --project "$GL" --fast 'swift build' --full 'swift test' --docs-command 'python3 Scripts/check-docs.py' --docs-observe --owned docs/ROADMAP.md --local >/dev/null
if [ -z "$(git -C "$GL" status --short)" ] && [ "$(jq -c '[.docs, .protectedPaths]' "$GL/.claude/swift-harness.json")" = '[{"command":"python3 Scripts/check-docs.py","blocking":false},["AGENTS.md","docs/ROADMAP.md"]]' ]; then
  ok "guest --local: the two files stay out of git; the docs check observes; the owned docs are protected"
else nok "guest --local: the two files stay out of git; the docs check observes; the owned docs are protected" "$(git -C "$GL" status --short; cat "$GL/.claude/swift-harness.json")"; fi
G6="$TMP/guest-isolation"; mkdir -p "$G6"
"$SCRIPTS/setup-guest.sh" --project "$G6" --fast 'swift build' --ui-isolation -UITestingSuite >/dev/null
if [ "$(jq -c '.uiTests' "$G6/.claude/swift-harness.json")" = '{"isolation":["-UITestingSuite"]}' ]; then ok "guest --ui-isolation: declares the launch argument that keeps UI tests off real data"
else nok "guest --ui-isolation: declares the launch argument that keeps UI tests off real data" "$(cat "$G6/.claude/swift-harness.json")"; fi
GW="$TMP/guest-local-wt"
git -C "$GL" worktree add -q "$GW" -b other 2>/dev/null
"$SCRIPTS/setup-guest.sh" --project "$GW" --from "$GL" >/dev/null
if cmp -s "$GL/.claude/swift-harness.json" "$GW/.claude/swift-harness.json" && [ -x "$GW/Scripts/verify.sh" ] && [ -z "$(git -C "$GW" status --short)" ]; then
  ok "guest --from: a new worktree gets the same two files, still out of git"
else nok "guest --from: a new worktree gets the same two files, still out of git" "$(git -C "$GW" status --short)"; fi
GW2="$TMP/guest-local-wt2"
git -C "$GL" worktree add -q "$GW2" -b third 2>/dev/null
out="$(hook session-start.sh "$GW2" '{"source":"startup"}' 2>&1)"
if grep -q 'this worktree does not have them, so no check runs here' <<<"$out" && grep -qF 'guest-local\" --local' <<<"$out" && [ -z "$(git -C "$GW2" status --short)" ]; then
  ok "guest --local: a new worktree without the files says no check runs there, with the command to prepare it"
else nok "guest --local: a new worktree without the files says no check runs there, with the command to prepare it" "$out"; fi
expect_result "guest --local: a repository that does not keep the files local says nothing" 0 '^exit=0$' "exit=0
$(hook session-start.sh "$TMP/guest-owned" '{"source":"startup"}' 2>&1 | grep -c 'no check runs here' | sed 's/^0$//')"
expect_result "guest --from: refuses when the worktree already has them" 1 'already there' "exit=$("$SCRIPTS/setup-guest.sh" --project "$GW" --from "$GL" >/dev/null 2>&1; echo $?)
$("$SCRIPTS/setup-guest.sh" --project "$GW" --from "$GL" 2>&1)"

# ---------- Codex (#122) ----------

# A Codex hook input: $1 cwd, then extra JSON (object).
codex_hook() { # $1 hook script, $2 cwd, $3 extra JSON
  jq -nc --arg cwd "$2" --argjson extra "${3:-{\}}" '{cwd: $cwd, session_id: "codex-1", turn_id: "t1"} + $extra' |
    CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/codex-hook.sh" "$1"
}
patch_input() { # $1 patch text
  jq -nc --arg p "$1" '{hook_event_name: "PreToolUse", tool_name: "apply_patch", tool_input: {command: $p}}'
}
X="$(new_project codex)"
PROT="$(patch_input $'*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-let app = 1\n+let app = 2\n*** Update File: Sources/Audio/Engine.swift\n@@\n-let engine = 1\n+let engine = 2\n*** End Patch')"
out="$(codex_hook guard.sh "$X" "$PROT")"
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ] && grep -q 'Sources/Audio' <<<"$out" && grep -q 'If they agree' <<<"$out"; then
  ok "codex: an apply_patch that touches a protected path is denied, with the reason and how to ask the user"
else nok "codex: an apply_patch that touches a protected path is denied, with the reason and how to ask the user" "$out"; fi
if tail -1 "$(state_of "$X")/catches.jsonl" 2>/dev/null | jq -e '.agent == "codex" and .kind == "blocked" and (.what | test("refused"))' >/dev/null; then
  ok "codex: the refusal is logged as a block, not a question"
else nok "codex: the refusal is logged as a block, not a question" "$(tail -1 "$(state_of "$X")/catches.jsonl" 2>&1)"; fi
out="$(codex_hook guard.sh "$X" "$(patch_input $'*** Begin Patch\n*** Add File: Sources/New.swift\n+let n = 1\n*** End Patch')")"
if [ -z "$out" ]; then ok "codex: an apply_patch outside protected paths passes"
else nok "codex: an apply_patch outside protected paths passes" "$out"; fi
out="$(codex_hook guard.sh "$X" "$(patch_input $'*** Begin Patch\n*** Update File: Sources/Tool.swift\n*** Move to: Sources/Audio/Tool.swift\n*** End Patch')")"
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ]; then ok "codex: a move into a protected path is denied"
else nok "codex: a move into a protected path is denied" "$out"; fi
out="$(codex_hook guard.sh "$X" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
if [ -z "$out" ]; then ok "codex: a shell command is not read as a patch"
else nok "codex: a shell command is not read as a patch" "$out"; fi

codex_hook session-start.sh "$X" '{"hook_event_name":"SessionStart","source":"startup"}' >/dev/null
echo 'let app = 3' >"$X/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=1 codex_hook stop-verify.sh "$X" '{"hook_event_name":"Stop","stop_hook_active":false}' 2>&1)"; code=$?
if [ "$code" = 2 ] && grep -q 'Verification failed' <<<"$out" && [ "$(ev_of "$X" '[.agent, .outcome]')" = '["codex","failed"]' ]; then
  ok "codex: a failing check at the end of the turn blocks, and the record names the agent"
else nok "codex: a failing check at the end of the turn blocks, and the record names the agent" "exit=$code $out $(ev_of "$X" .)"; fi
if tail -1 "$(state_of "$X")/catches.jsonl" 2>/dev/null | jq -e '.agent == "codex"' >/dev/null; then ok "codex: the catch log names the agent"
else nok "codex: the catch log names the agent" "$(cat "$(state_of "$X")/catches.jsonl" 2>&1)"; fi
echo 'let app = 4' >"$X/Sources/App.swift"
out="$(FAKE_VERIFY_EXIT=0 codex_hook stop-verify.sh "$X" '{"hook_event_name":"Stop","stop_hook_active":true}' 2>&1)"; code=$?
if [ "$code" = 0 ] && [ "$(ev_of "$X" '[.agent, .outcome]')" = '["codex","passed"]' ]; then ok "codex: the fix passes at the next end of turn"
else nok "codex: the fix passes at the next end of turn" "exit=$code $out $(ev_of "$X" .)"; fi

GC="$TMP/guest-codex"; mkdir -p "$GC"; git -C "$GC" init -q
git -C "$GC" config user.email t@example.com; git -C "$GC" config user.name t
echo x >"$GC/README.md"; echo x >"$GC/AGENTS.md"; git -C "$GC" add -A && git -C "$GC" commit -qm init
"$SCRIPTS/setup-guest.sh" --project "$GC" --fast 'swift build' --codex --data "$TMP/data" --local >/dev/null
if [ "$(jq -c '.hooks | [keys, .PreToolUse[0].matcher, (.Stop[0].hooks | length)]' "$GC/.codex/hooks.json")" = '[["PostToolUse","PreToolUse","SessionStart","Stop"],"^(apply_patch|Edit|Write)$",6]' ] &&
  [ -x "$GC/.codex/swift-harness-hook.sh" ] && [ -z "$(git -C "$GC" status --short)" ]; then
  ok "guest --codex: writes the Codex hooks and their launcher, kept out of git with --local"
else nok "guest --codex: writes the Codex hooks and their launcher, kept out of git with --local" "$(git -C "$GC" status --short; cat "$GC/.codex/hooks.json" 2>&1)"; fi
out="$(cd "$GC" && jq -nc --arg cwd "$GC" '{cwd: $cwd, session_id: "c", hook_event_name: "PreToolUse", tool_name: "apply_patch", tool_input: {command: "*** Begin Patch\n*** Update File: AGENTS.md\n*** End Patch"}}' |
  HOME="$TMP/codex-home" CLAUDE_PLUGIN_DATA='' bash "$GC/.codex/swift-harness-hook.sh" guard.sh)"
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ]; then
  ok "guest --codex: the launcher finds the plugin without an installed one, and the guard runs"
else nok "guest --codex: the launcher finds the plugin without an installed one, and the guard runs" "$out"; fi
if grep -qF "CLAUDE_PLUGIN_DATA:-$TMP/data}" "$GC/.codex/swift-harness-hook.sh"; then ok "guest --codex: the launcher uses the same data folder as Claude Code"
else nok "guest --codex: the launcher uses the same data folder as Claude Code" "$(cat "$GC/.codex/swift-harness-hook.sh")"; fi
GCW="$TMP/guest-codex-wt"
git -C "$GC" worktree add -q "$GCW" -b other 2>/dev/null
"$SCRIPTS/setup-guest.sh" --project "$GCW" --from "$GC" >/dev/null
if cmp -s "$GC/.codex/hooks.json" "$GCW/.codex/hooks.json" && [ -x "$GCW/.codex/swift-harness-hook.sh" ] && [ -z "$(git -C "$GCW" status --short)" ]; then
  ok "guest --from: a new worktree gets the Codex hooks too, still out of git"
else nok "guest --from: a new worktree gets the Codex hooks too, still out of git" "$(git -C "$GCW" status --short)"; fi
mkdir -p "$TMP/guest-codex2"
expect_result "guest --codex: needs the data folder when it cannot tell" 1 'pass --data' "exit=$(HOME="$TMP/codex-home" CLAUDE_PLUGIN_DATA='' "$SCRIPTS/setup-guest.sh" --project "$TMP/guest-codex2" --fast 'swift build' --codex >/dev/null 2>&1; echo $?)
$(HOME="$TMP/codex-home" CLAUDE_PLUGIN_DATA='' "$SCRIPTS/setup-guest.sh" --project "$TMP/guest-codex2" --fast 'swift build' --codex 2>&1)"
if [ -z "$(ls -A "$TMP/guest-codex2")" ]; then ok "guest --codex: without a data folder, nothing is written"
else nok "guest --codex: without a data folder, nothing is written" "$(ls -A "$TMP/guest-codex2")"; fi

# ---------- 1.8.1: what an external review found (SH180-R01, R02, R07, #127), and Codex permits ----------

# One root cause, the set of problems growing at each turn, all fixed in the end: one episode.
HE="$(new_project h2-episodes)"; HEL="$(state_of "$HE")/catches.jsonl"; mkdir -p "$(dirname "$HEL")"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf '{"time":"2099-01-01T00:00:00Z","session":"one","check":"docs: d","kind":"observed","what":"%s new"}\n' "$i" >>"$HEL"
done
printf '{"time":"2099-01-01T00:00:01Z","session":"one","check":"docs: d","kind":"fixed","what":"observed problems gone: passes again"}\n' >>"$HEL"
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$HE" --json 2>&1)"
if [ "$(jq -c '.checks[] | select(.check == "docs: d") | [.observed, .observed_fixed, .observed_sessions, .promotion.proposal]' <<<"$out")" = '[1,1,1,"wait"]' ]; then
  ok "report: findings growing from one root cause are one episode, fixed"
else nok "report: findings growing from one root cause are one episode, fixed" "$out"; fi
: >"$HEL"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf '{"time":"2099-01-01T00:00:00Z","session":"one","check":"docs: d","kind":"observed","what":"1 new"}\n{"time":"2099-01-01T00:00:01Z","session":"one","check":"docs: d","kind":"fixed","what":"observed problems gone: passes again"}\n' >>"$HEL"
done
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$HE" --json 2>&1)"
if [ "$(jq -c '.checks[] | select(.check == "docs: d") | [.observed, .promotion.proposal]' <<<"$out")" = '[11,"wait"]' ]; then
  ok "report: 11 fixed episodes in one session do not propose blocking"
else nok "report: 11 fixed episodes in one session do not propose blocking" "$out"; fi

# check.sh says what passing means.
CS="$(new_project check-strict)"
cat >"$CS/scripts/verify.sh" <<'EOF'
#!/bin/bash
echo "swift-harness-result/1: partial; checked=macOS; tested=macOS; not checked=iOS"
exit 0
EOF
git -C "$CS" add -A; git -C "$CS" commit -qm partial; approve "$CS" >/dev/null
csc() { local o c; o="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$CS" --agent t "$@" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
echo 'let app = 2' >"$CS/Sources/App.swift"
expect_result "check: a partial result exits 0 by default, and says PARTIAL, not passed" 0 'Result: PARTIAL' "$(csc)" 'Result: passed'
expect_result "check --strict: a partial result exits 4" 4 'Result: PARTIAL' "$(csc --strict)"
if [ "$(csc --json | sed 1d | jq -r '.result')" = partial ]; then ok "check --json: the result is named"
else nok "check --json: the result is named" "$(csc --json)"; fi
CU="$(new_project check-unstable)"
cat >"$CU/scripts/verify.sh" <<'EOF'
#!/bin/bash
f="$(dirname "$0")/../.git/count"; n="$(cat "$f" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$f"
[ "$n" -gt 0 ] || { echo boom; exit 1; }
exit 0
EOF
set_config "$CU" '{"verify":{"command":"scripts/verify.sh fast","retryFailed":true}}'
git -C "$CU" add -A; git -C "$CU" commit -qm unstable; approve "$CU" >/dev/null
echo 'let app = 2' >"$CU/Sources/App.swift"
out="exit=$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$CU" --agent t --strict >"$TMP/cu.out" 2>&1; echo $?)
$(cat "$TMP/cu.out")"
expect_result "check --strict: a pass on the rerun exits 4, and says UNSTABLE" 4 'Result: UNSTABLE' "$out"
if [ "$(ev_of "$CU" '.stability')" = '"unstable"' ]; then ok "evidence: a pass on the rerun has stability unstable"
else nok "evidence: a pass on the rerun has stability unstable" "$(ev_of "$CU" .)"; fi
PASS_REC="$(ev_of "$E" '.stability')"
if [ "$PASS_REC" = null ]; then ok "evidence: a clean pass has no stability field"
else nok "evidence: a clean pass has no stability field" "$PASS_REC"; fi
out="$(HOME="$TMP/no-home" CLAUDE_PLUGIN_DATA='' "$SCRIPTS/check.sh" --project "$CS" 2>&1)"
if grep -q 'no plugin data folder' <<<"$out" && ! grep -q 'one of: )' <<<"$out"; then ok "check: with no data folder, it says what to do"
else nok "check: with no data folder, it says what to do" "$out"; fi

# Scripts an approved file names, not covered by the approval (#127).
UC="$(new_project uncovered)"
cat >"$UC/scripts/verify.sh" <<'EOF'
#!/bin/bash
# See also scripts/gone.sh, which no longer exists.
python3 "$(dirname "$0")/helper.py"
bash scripts/nested/run.sh
exit 0
EOF
mkdir -p "$UC/scripts/nested"; echo 'print(1)' >"$UC/scripts/helper.py"; echo 'exit 0' >"$UC/scripts/nested/run.sh"
git -C "$UC" add -A; git -C "$UC" commit -qm uncovered
out="$(approval "$UC" --status)"
if grep -q 'Not covered: scripts/helper.py, named in scripts/verify.sh' <<<"$out" && grep -q 'Not covered: scripts/nested/run.sh, named in scripts/verify.sh' <<<"$out" && ! grep -q 'Not covered: .*gone.sh' <<<"$out" && ! grep -q 'Not covered: scripts/verify.sh' <<<"$out"; then
  ok "approval: a script named by the approved one and not covered is shown; a name that does not exist is not"
else nok "approval: a script named by the approved one and not covered is shown; a name that does not exist is not" "$out"; fi
out="$(doctor "$UC")"
expect_row "doctor: scripts the approval does not cover are a hint, not a warning" "$out" INFO "Verify coverage"
expect_row "doctor: each script not covered says which file names it" "$out" INFO "Verify coverage" "scripts/helper.py \(named in scripts/verify.sh\); scripts/nested/run.sh \(named in scripts/verify.sh\)"
expect_row "doctor: the advice depends on whether the script runs" "$out" INFO "Verify coverage" "If one of them runs.*verify.inputs.*If it is only mentioned, nothing to do"
UC2="$(new_project uncovered-two)"
printf '#!/bin/bash\n# See scripts/helper.sh\nexit 0\n' >"$UC2/scripts/verify.sh"
printf '# See scripts/helper.sh\n' >"$UC2/scripts/other.py"
echo 'exit 0' >"$UC2/scripts/helper.sh"
set_config "$UC2" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts/other.py"]},"protectedPaths":[]}'
expect_row "doctor: a script named by two approved files lists both, once" "$(doctor "$UC2")" INFO "Verify coverage" "scripts/helper.sh \(named in scripts/other.py, scripts/verify.sh\)"
set_config "$UC" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts/helper.py","scripts/nested"]},"protectedPaths":[]}'
out="$(approval "$UC" --status)"
if grep -q 'Not covered' <<<"$out"; then nok "approval: inputs, a file or a folder, cover them" "$out"; else ok "approval: inputs, a file or a folder, cover them"; fi
approve "$UC" >/dev/null
echo 'print(2)' >"$UC/scripts/helper.py"
if approval "$UC" --status | grep -q '^Status: not approved'; then ok "approval: once covered, a change to that script asks again"
else nok "approval: once covered, a change to that script asks again" "$(approval "$UC" --status)"; fi

# A CI file with two problems: one row, and nothing on stderr (awk's END runs after exit).
AY="$TMP/audit-yaml"; mkdir -p "$AY/.github/workflows"
printf 'on: [push\njobs:\n  a: "b\n' >"$AY/.github/workflows/ci.yml"
out="$("$SCRIPTS/audit.sh" --project "$AY" 2>"$TMP/ay.err")"
if [ ! -s "$TMP/ay.err" ] && grep -q 'cannot be read as YAML: a quote that does not close (line 3)' <<<"$out"; then ok "audit: a CI file with two problems gives the first, and nothing on stderr"
else nok "audit: a CI file with two problems gives the first, and nothing on stderr" "$(cat "$TMP/ay.err"; printf '%s' "$out" | grep -n 'YAML')"; fi

# A one-time permit for a Codex edit of a protected file.
PX="$(new_project codex-permit)"
PERM="$(patch_input $'*** Begin Patch\n*** Update File: Sources/Audio/Engine.swift\n@@\n-let engine = 1\n+let engine = 2\n*** End Patch')"
MIX="$(patch_input $'*** Begin Patch\n*** Update File: Sources/Audio/Engine.swift\n*** Update File: App.xcodeproj/project.pbxproj\n*** End Patch')"
allow() { (cd "$PX" && { sleep 3; printf 'yes\n'; sleep 2; } | CLAUDE_PLUGIN_DATA="$TMP/data" script -q /dev/null "$SCRIPTS/codex-hook.sh" --allow "$@" 2>&1); }
denied() { [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$1" 2>/dev/null)" = deny ]; }
out="$(codex_hook guard.sh "$PX" "$PERM")"
if denied "$out" && grep -q -- '--allow' <<<"$out" && grep -q 'Never run that command yourself' <<<"$out"; then ok "codex permit: without one, the edit is refused, and the reason says how the user gives it"
else nok "codex permit: without one, the edit is refused, and the reason says how the user gives it" "$out"; fi
out="$(cd "$PX" && CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/codex-hook.sh" --allow Sources/Audio/Engine.swift </dev/null 2>&1)"; code=$?
if [ "$code" = 1 ] && grep -q 'own terminal' <<<"$out" && denied "$(codex_hook guard.sh "$PX" "$PERM")"; then ok "codex permit: not given without a terminal"
else nok "codex permit: not given without a terminal" "exit=$code $out"; fi
out="$(allow Sources/Audio/Engine.swift)"
if grep -q 'Allowed: one edit of Sources/Audio/Engine.swift' <<<"$out" && tail -n 1 "$(state_of "$PX")/catches.jsonl" | jq -e '.agent == "user"' >/dev/null; then ok "codex permit: given from a terminal, with a typed yes"
else nok "codex permit: given from a terminal, with a typed yes" "$out"; fi
out="$(cd "$PX" && { printf 'yes\n'; sleep 4; printf 'no\n'; sleep 2; } | CLAUDE_PLUGIN_DATA="$TMP/data" script -q /dev/null "$SCRIPTS/codex-hook.sh" --allow Sources/Audio/Tool.swift 2>&1)"
if grep -q 'Nothing allowed' <<<"$out"; then ok "codex permit: a yes typed before the question is not an answer"
else nok "codex permit: a yes typed before the question is not an answer" "$out"; fi
out="$(codex_hook guard.sh "$PX" "$MIX")"
if denied "$out" && [ -n "$(ls -A "$(state_of "$PX")/edit-permits")" ]; then ok "codex permit: a patch that also touches another protected file is refused, and the permit stays"
else nok "codex permit: a patch that also touches another protected file is refused, and the permit stays" "$out"; fi
out="$(codex_hook guard.sh "$PX" "$PERM")"
if [ -z "$out" ] && tail -n 1 "$(state_of "$PX")/catches.jsonl" | jq -e '.kind == "approved" and .agent == "codex" and (.what | test("one-time permit"))' >/dev/null; then ok "codex permit: the same patch goes through, and the log says so"
else nok "codex permit: the same patch goes through, and the log says so" "$out $(tail -n 1 "$(state_of "$PX")/catches.jsonl")"; fi
if denied "$(codex_hook guard.sh "$PX" "$PERM")"; then ok "codex permit: it works once"
else nok "codex permit: it works once"; fi
allow Sources/Audio/Engine.swift >/dev/null
f="$(ls "$(state_of "$PX")/edit-permits/"* | head -n 1)"; { echo 1000; sed -n 2p "$f"; } >"$f.tmp"; mv "$f.tmp" "$f"
if denied "$(codex_hook guard.sh "$PX" "$PERM")"; then ok "codex permit: an old one has expired"
else nok "codex permit: an old one has expired"; fi

# ---------- findings of a review by another agent ----------

# A config the guard cannot read must not switch the guard off.
GI="$(new_project guard-invalid)"
for bad in '{"protectedPaths":"Sources/Audio/"}' '{"protectedPaths":[{}]}' '{"protectedPaths":["Sources/Audio/",5]}' '{"protectedPaths":["Sources/Audio/"],' ''; do
  printf '%s\n' "$bad" >"$GI/.claude/swift-harness.json"
  if guard_asks "$GI" "$GI/Sources/Audio/Engine.swift"; then ok "guard: asks when the config is unusable: '$bad'"
  else nok "guard: asks when the config is unusable: '$bad'"; fi
  if guard_asks "$GI" "$GI/.claude/swift-harness.json"; then nok "guard: the unusable config itself stays editable: '$bad'"
  else ok "guard: the unusable config itself stays editable: '$bad'"; fi
done
if hook guard.sh "$GI" "$(edit_input "$GI/Sources/App.swift")" | grep -q 'not valid'; then ok "guard: says the config is the reason"
else nok "guard: says the config is the reason"; fi
set_config "$GI" '{}'
if guard_asks "$GI" "$GI/Sources/App.swift"; then nok "guard: a config with no protected paths asks nothing"
else ok "guard: a config with no protected paths asks nothing"; fi

# A folder reached by a link inside a verify.inputs folder cannot be covered: refuse, never
# under-cover and never walk the link graph (which can blow up exponentially).
VF="$(new_project verify-folder-link)"
mkdir -p "$VF/shared"
printf '#!/bin/bash\nbash scripts/tree/run.sh\n' >"$VF/scripts/verify.sh"; chmod +x "$VF/scripts/verify.sh"
echo 'exit 0' >"$VF/shared/run.sh"
ln -s ../shared "$VF/scripts/tree"
set_config "$VF" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts"]},"protectedPaths":[]}'
# Capture the whole output and grep the variable, never `| grep -q` which closes the pipe early.
VF_OUT="$(approval "$VF" --status)"
if grep -q 'cannot be covered' <<<"$VF_OUT"; then ok "approval: a folder reached by a link in an input folder cannot be covered"
else nok "approval: a folder reached by a link in an input folder cannot be covered" "$VF_OUT"; fi
VF_DIG="$(sed -n 's/^Digest: *//p' <<<"$VF_OUT")"
VF_APP="$(approval "$VF" --approve "$VF_DIG")"
if grep -q 'cannot cover' <<<"$VF_APP"; then ok "approval: such an input is refused at approve time"
else nok "approval: such an input is refused at approve time" "$VF_APP"; fi

# A link to a file inside an input folder is still covered by the target's content.
VF2="$(new_project verify-file-link)"
mkdir -p "$VF2/shared"
printf '#!/bin/bash\nbash scripts/run.sh\n' >"$VF2/scripts/verify.sh"; chmod +x "$VF2/scripts/verify.sh"
echo 'exit 0' >"$VF2/shared/run.sh"
ln -s ../shared/run.sh "$VF2/scripts/run.sh"
set_config "$VF2" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts"]},"protectedPaths":[]}'
approve "$VF2" >/dev/null
echo 'exit 1' >"$VF2/shared/run.sh"
VF2_OUT="$(approval "$VF2" --status)"
if grep -q '^Status: not approved' <<<"$VF2_OUT"; then ok "approval: a change behind a file link in an input folder asks again"
else nok "approval: a change behind a file link in an input folder asks again" "$VF2_OUT"; fi

# A link out of the project inside an input folder is refused.
VF3="$(new_project verify-link-out)"
printf '#!/bin/bash\n' >"$VF3/scripts/verify.sh"; chmod +x "$VF3/scripts/verify.sh"
ln -s "$TMP" "$VF3/scripts/away"
set_config "$VF3" '{"verify":{"command":"scripts/verify.sh fast","inputs":["scripts"]},"protectedPaths":[]}'
VF3_OUT="$(approval "$VF3" --status)"
if grep -q 'cannot be covered' <<<"$VF3_OUT"; then ok "approval: a link out of the project in an input folder is refused"
else nok "approval: a link out of the project in an input folder is refused" "$VF3_OUT"; fi

# A protected file edited through a case-variant name is still protected on a case-insensitive disk.
CS="$(new_project guard-caseins)"
mkdir -p "$CS/Policies"; printf 'secret\n' >"$CS/Policies/secret.txt"
set_config "$CS" '{"protectedPaths":["Policies/"]}'
if [ "$CS/policies/secret.txt" -ef "$CS/Policies/secret.txt" ]; then
  if guard_asks "$CS" "$CS/policies/secret.txt"; then ok "guard: a case-variant of a file in a protected dir still asks"
  else nok "guard: a case-variant of a file in a protected dir still asks"; fi
  if guard_asks "$CS" "$CS/policies/new.txt"; then ok "guard: a new file in a case-variant of a protected dir asks"
  else nok "guard: a new file in a case-variant of a protected dir asks"; fi
else
  ok "guard: case-insensitive checks skipped (case-sensitive disk)"
  ok "guard: case-insensitive dir check skipped (case-sensitive disk)"
fi

# A normal write appends a record and leaves no lock behind.
HR="$(new_project history-lock)"
printf '#!/bin/bash\nexit 0\n' >"$HR/scripts/verify.sh"; chmod +x "$HR/scripts/verify.sh"
git -C "$HR" add -A; git -C "$HR" commit -qm init
approve "$HR" >/dev/null
hook session-start.sh "$HR" '{"session_id":"s1","source":"startup"}' >/dev/null
HR_HIST="$(state_of "$HR")/evidence-history.jsonl"
HR_LOCK="$(state_of "$HR")/evidence-history.lock"
echo 'let app = 2' >"$HR/Sources/App.swift"
jq -nc --arg cwd "$HR" '{cwd: $cwd, session_id: "s1"}' |
  CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$HR" "$SCRIPTS/stop-verify.sh" >/dev/null 2>&1
if [ "$(jq -sc 'length' "$HR_HIST" 2>/dev/null)" -ge 1 ] && [ ! -e "$HR_LOCK" ]; then ok "history: a normal write appends a record and releases the lock"
else nok "history: a normal write appends a record and releases the lock" "lines=$(wc -l <"$HR_HIST" 2>/dev/null) lock=$([ -e "$HR_LOCK" ] && echo held)"; fi

# A lock left behind by a killed hook (old mtime) is taken over, and the record is appended.
HR_PRE="$(jq -sc 'length' "$HR_HIST" 2>/dev/null)"
mkdir "$HR_LOCK"; touch -t 202001010000 "$HR_LOCK"
echo 'let app = 3' >"$HR/Sources/App.swift"
jq -nc --arg cwd "$HR" '{cwd: $cwd, session_id: "s1"}' |
  CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$HR" "$SCRIPTS/stop-verify.sh" >/dev/null 2>&1
if [ ! -e "$HR_LOCK" ] && [ "$(jq -sc 'length' "$HR_HIST" 2>/dev/null)" -gt "${HR_PRE:-0}" ]; then ok "history: a lock left by a killed hook is taken over, and the record is kept"
else nok "history: a lock left by a killed hook is taken over, and the record is kept" "lock=$([ -e "$HR_LOCK" ] && echo held) pre=$HR_PRE now=$(jq -sc 'length' "$HR_HIST" 2>/dev/null)"; fi

# A writer that cannot get the lock (a live holder) skips, without appending or erasing.
HL="$(new_project history-locked)"
printf '#!/bin/bash\nexit 0\n' >"$HL/scripts/verify.sh"; chmod +x "$HL/scripts/verify.sh"
git -C "$HL" add -A; git -C "$HL" commit -qm init
approve "$HL" >/dev/null
hook session-start.sh "$HL" '{"session_id":"s1","source":"startup"}' >/dev/null
HL_HIST="$(state_of "$HL")/evidence-history.jsonl"
printf '{"time":"%s","session":"keep","code":"k","outcome":"passed","checks":[]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$HL_HIST"
mkdir "$(state_of "$HL")/evidence-history.lock" # a fresh lock a live holder owns
echo 'let app = 9' >"$HL/Sources/App.swift"
jq -nc --arg cwd "$HL" '{cwd: $cwd, session_id: "s1"}' |
  SWIFT_HARNESS_LOCK_TRIES=3 CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$HL" "$SCRIPTS/stop-verify.sh" >/dev/null 2>&1
if [ "$(jq -sc '[.[].session]' "$HL_HIST")" = '["keep"]' ]; then ok "history: a writer that cannot get the lock does not append or erase"
else nok "history: a writer that cannot get the lock does not append or erase" "$(cat "$HL_HIST")"; fi
rmdir "$(state_of "$HL")/evidence-history.lock" 2>/dev/null

# The HTML report: the first one, with no catch log yet, and never out of the project.
RN="$(new_project report-no-log)"
rm -f "$(state_of "$RN")/catches.jsonl" # new_project approves, and an approval is logged
expect_result "html: works before any catch is logged" 0 'report\.html$' "$(report --project "$RN" --all --html)"
RO="$TMP/report-outside"; mkdir -p "$RO"; echo keep >"$RO/report.html"
RL="$(new_project report-link-folder)"; mkdir -p "$RL/.build"; ln -s "$RO" "$RL/.build/swift-harness"
expect_result "html: refuses a linked output folder" 1 'link' "$(report --project "$RL" --all --html)"
RB="$(new_project report-link-build)"; ln -s "$RO" "$RB/.build"
expect_result "html: refuses a linked .build" 1 'link' "$(report --project "$RB" --all --html)"
if [ -e "$RO/swift-harness" ]; then nok "html: a linked .build gets no new folder"; else ok "html: a linked .build gets no new folder"; fi
RF="$(new_project report-link-file)"; mkdir -p "$RF/.build/swift-harness"; ln -s "$RO/report.html" "$RF/.build/swift-harness/report.html"
expect_result "html: refuses a linked page" 1 'link' "$(report --project "$RF" --all --html)"
if [ "$(cat "$RO/report.html")" = keep ]; then ok "html: the file out of the project is unchanged"
else nok "html: the file out of the project is unchanged"; fi
# A hard link is a regular file, so the page is renamed into place rather than truncating it.
RH="$(new_project report-hardlink)"; mkdir -p "$RH/.build/swift-harness"
echo keep >"$TMP/report-hardlink-outside"
ln "$TMP/report-hardlink-outside" "$RH/.build/swift-harness/report.html"
report --project "$RH" --all --html >/dev/null
if [ "$(cat "$TMP/report-hardlink-outside")" = keep ]; then ok "html: a hard-linked report.html does not truncate the outside file"
else nok "html: a hard-linked report.html does not truncate the outside file" "$(head -1 "$TMP/report-hardlink-outside")"; fi

# setup-guest --from must not write through a destination link or over existing files.
FO="$TMP/from-src"; mkdir -p "$FO/.claude" "$FO/scripts" "$FO/.codex"; git -C "$FO" init -q
printf '{}\n' >"$FO/.claude/swift-harness.json"; printf '#!/bin/bash\n' >"$FO/scripts/verify.sh"
printf '{"hooks":{}}\n' >"$FO/.codex/hooks.json"; printf '#!/bin/bash\n' >"$FO/.codex/swift-harness-hook.sh"
FD="$TMP/from-dest"; mkdir -p "$FD/.codex"; git -C "$FD" init -q
echo keep >"$TMP/from-outside"
ln -s "$TMP/from-outside" "$FD/.codex/swift-harness-hook.sh"
out="$("$SCRIPTS/setup-guest.sh" --from "$FO" --project "$FD" 2>&1)"; code=$?
expect_result "guest --from: refuses a destination launcher link" 1 'already there.*swift-harness-hook' "exit=$code
$out"
if [ "$(cat "$TMP/from-outside")" = keep ]; then ok "guest --from: the outside file behind the link is unchanged"
else nok "guest --from: the outside file behind the link is unchanged" "$(cat "$TMP/from-outside")"; fi

# setup-guest --codex must not overwrite the user's own launcher file.
GO="$TMP/guest-codex-own"; mkdir -p "$GO/.codex"; git -C "$GO" init -q
echo OWN >"$GO/.codex/swift-harness-hook.sh"
out="$("$SCRIPTS/setup-guest.sh" --project "$GO" --fast 'swift build' --codex --data "$TMP/data" 2>&1)"; code=$?
expect_result "guest --codex: refuses when the launcher exists" 1 'already there.*swift-harness-hook' "exit=$code
$out"
if [ "$(cat "$GO/.codex/swift-harness-hook.sh")" = OWN ] && [ ! -e "$GO/.codex/hooks.json" ] && [ ! -e "$GO/.claude/swift-harness.json" ]; then ok "guest --codex: the file is unchanged and nothing is written"
else nok "guest --codex: the file is unchanged and nothing is written"; fi
GD="$TMP/guest-codex-dangling"; mkdir -p "$GD/.codex"; git -C "$GD" init -q
ln -s "$TMP/guest-nowhere" "$GD/.codex/swift-harness-hook.sh"
out="$("$SCRIPTS/setup-guest.sh" --project "$GD" --fast 'swift build' --codex --data "$TMP/data" 2>&1)"; code=$?
expect_result "guest --codex: refuses a link that points nowhere" 1 'already there' "exit=$code
$out"
if [ -e "$TMP/guest-nowhere" ]; then nok "guest --codex: nothing is written through that link"; else ok "guest --codex: nothing is written through that link"; fi

# The way to approve depends on the agent: a slash command exists only in Claude Code.
AN="$(new_project approve-notice)"
printf '#!/bin/bash\nexit 0\n' >"$AN/scripts/verify.sh"; chmod +x "$AN/scripts/verify.sh"
git -C "$AN" add -A; git -C "$AN" commit -qm init
echo 'let app = 2' >"$AN/Sources/App.swift"
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$AN" --agent codex --json 2>&1 | jq -r .notice)"
if grep -q "own terminal" <<<"$out" && ! grep -q 'then type /swift-harness:approve-verify' <<<"$out"; then ok "check: for another agent, the notice names a way that works there"
else nok "check: for another agent, the notice names a way that works there" "$out"; fi
out="$(SH_AGENT=codex hook session-start.sh "$AN" '{"source":"startup"}' 2>&1)"
if grep -q "own terminal" <<<"$out" && grep -q 'Do not run the approval yourself' <<<"$out"; then ok "session start: for another agent, the same, and it still must not approve"
else nok "session start: for another agent, the same, and it still must not approve" "$out"; fi
out="$(hook session-start.sh "$AN" '{"source":"startup"}' 2>&1)"
if grep -q 'type /swift-harness:approve-verify' <<<"$out" && ! grep -q "own terminal" <<<"$out"; then ok "session start: for Claude, the slash command"
else nok "session start: for Claude, the slash command" "$out"; fi

# ---------- changes the fingerprint did not see (#137) ----------

fp_of() { fingerprint "$1"; }
fp_differs() { # $1 name, $2 before, $3 project
  if [ "$(fp_of "$3")" != "$2" ]; then ok "$1"; else nok "$1" "fingerprint did not change"; fi
}

# Guest files kept out of git (--local): the config and the verify script are in .git/info/exclude.
FL="$(new_project fp-local)"
git -C "$FL" rm -q --cached .claude/swift-harness.json scripts/verify.sh
git -C "$FL" commit -qm 'keep the harness files local'
printf '/.claude/swift-harness.json\n/scripts/verify.sh\n' >>"$FL/.git/info/exclude"
approve "$FL" >/dev/null
before="$(fp_of "$FL")"
printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3},"lintBlocking":true}' >"$FL/.claude/swift-harness.json"
fp_differs "fingerprint: a config kept out of git still counts" "$before" "$FL"
before="$(fp_of "$FL")"
printf '#!/bin/bash\necho changed\nexit 1\n' >"$FL/scripts/verify.sh"
fp_differs "fingerprint: a verify script kept out of git still counts" "$before" "$FL"
FL2="$(new_project fp-local-stop)"
git -C "$FL2" rm -q --cached .claude/swift-harness.json scripts/verify.sh
git -C "$FL2" commit -qm 'keep the harness files local'
printf '/.claude/swift-harness.json\n/scripts/verify.sh\n' >>"$FL2/.git/info/exclude"
approve "$FL2" >/dev/null
hook session-start.sh "$FL2" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$FL2/Sources/App.swift"
hook stop-verify.sh "$FL2" >/dev/null 2>&1
printf '#!/bin/bash\necho the new script fails\nexit 1\n' >"$FL2/scripts/verify.sh"
approve "$FL2" >/dev/null
expect_result "stop: a verify script kept out of git, changed and approved, runs on code that passed the old one" 2 'the new script fails' "exit=$(hook stop-verify.sh "$FL2" >/dev/null 2>&1; echo $?)
$(rm -f "$TMP/data/state/"*/failed; hook stop-verify.sh "$FL2" 2>&1)"

# A repository with no commit yet: files staged, HEAD not born.
FU="$TMP/fp-unborn"; mkdir -p "$FU/.claude" "$FU/Sources" "$FU/scripts"; git -C "$FU" init -q
printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast"}}' >"$FU/.claude/swift-harness.json"
printf '#!/bin/bash\nexit 0\n' >"$FU/scripts/verify.sh"; chmod +x "$FU/scripts/verify.sh"
echo 'let a = 1' >"$FU/Sources/A.swift"; echo 'let b = 1' >"$FU/Sources/B.swift"
git -C "$FU" add -A
before="$(fp_of "$FU")"
echo 'let a = 2' >"$FU/Sources/A.swift"
fp_differs "fingerprint: no commit yet, an edit to a staged file counts" "$before" "$FU"
before="$(fp_of "$FU")"
rm "$FU/Sources/B.swift"
fp_differs "fingerprint: no commit yet, a deleted staged file counts" "$before" "$FU"

# Nested repositories: a folder with its own .git, tracked as a link, untracked, or a submodule.
nested_repo() { # $1 folder: a repository with one Swift file and one commit
  mkdir -p "$1/Sources/Core"; git -C "$1" init -q
  git -C "$1" config user.email t@example.com; git -C "$1" config user.name t
  echo 'let core = 1' >"$1/Sources/Core/Core.swift"; echo '# core' >"$1/README.md"
  git -C "$1" add -A && git -C "$1" commit -qm core
}
FN="$(new_project fp-nested)"
nested_repo "$FN/Packages/Core"
git -C "$FN" add -A 2>/dev/null; git -C "$FN" commit -qm 'a nested repository, as a link'
before="$(fp_of "$FN")"
echo 'let core = 2' >"$FN/Packages/Core/Sources/Core/Core.swift"
fp_differs "fingerprint: an edit inside a nested repository counts" "$before" "$FN"
before="$(fp_of "$FN")"
echo 'let core = 3' >"$FN/Packages/Core/Sources/Core/Core.swift"
fp_differs "fingerprint: a second edit inside a nested repository counts" "$before" "$FN"
before="$(fp_of "$FN")"
echo 'let more = 1' >"$FN/Packages/Core/Sources/Core/More.swift"
fp_differs "fingerprint: a new file inside a nested repository counts" "$before" "$FN"
git -C "$FN/Packages/Core" checkout -q -- . && git -C "$FN/Packages/Core" clean -qfd
before="$(fp_of "$FN")"
echo '# changed' >"$FN/Packages/Core/README.md"
if [ "$(fp_of "$FN")" = "$before" ]; then ok "fingerprint: a README inside a nested repository is ignored"
else nok "fingerprint: a README inside a nested repository is ignored" "fingerprint changed"; fi
FN2="$(new_project fp-nested-untracked)"
nested_repo "$FN2/Vendor/Core"
before="$(fp_of "$FN2")"
echo 'let core = 2' >"$FN2/Vendor/Core/Sources/Core/Core.swift"
fp_differs "fingerprint: an edit inside an untracked nested repository counts" "$before" "$FN2"
FS="$(new_project fp-submodule)"
nested_repo "$TMP/fp-submodule-origin"
git -C "$FS" -c protocol.file.allow=always submodule add -q "$TMP/fp-submodule-origin" Packages/Sub 2>/dev/null
git -C "$FS" commit -qm 'a submodule'
before="$(fp_of "$FS")"
echo 'let core = 2' >"$FS/Packages/Sub/Sources/Core/Core.swift"
fp_differs "fingerprint: an edit inside a submodule counts" "$before" "$FS"
before="$(fp_of "$FS")"
echo 'let core = 3' >"$FS/Packages/Sub/Sources/Core/Core.swift"
fp_differs "fingerprint: a second edit inside a submodule counts" "$before" "$FS"

# C and C++ sources of an Xcode target, outside Sources/.
FC="$(new_project fp-cpp)"
mkdir -p "$FC/App/DSP"
for f in filter.cpp filter.hpp mix.cc mix.hh gain.cxx; do echo '// one' >"$FC/App/DSP/$f"; done
git -C "$FC" add -A && git -C "$FC" commit -qm dsp
for f in filter.cpp filter.hpp mix.cc mix.hh gain.cxx; do
  before="$(fp_of "$FC")"
  echo '// two' >"$FC/App/DSP/$f"
  fp_differs "fingerprint: edited $f in an app folder" "$before" "$FC"
done

# ---------- a working directory inside a nested repository (#138) ----------

root_of() { # $1 cwd, $2 CLAUDE_PROJECT_DIR (default: the cwd)
  jq -nc --arg cwd "$1" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="${2:-$1}" bash -c '. "$0"; sh_root' "$SCRIPTS/lib.sh"
}
if [ "$(root_of "$FN/Packages/Core")" = "$FN" ]; then ok "root: from a nested repository, the project that holds the config"
else nok "root: from a nested repository, the project that holds the config" "$(root_of "$FN/Packages/Core")"; fi
if [ "$(root_of "$FN/Packages/Core/Sources/Core")" = "$FN" ]; then ok "root: from a folder of a nested repository, the same"
else nok "root: from a folder of a nested repository, the same" "$(root_of "$FN/Packages/Core/Sources/Core")"; fi
if [ "$(root_of "$FS/Packages/Sub")" = "$FS" ]; then ok "root: from a submodule, the project that holds the config"
else nok "root: from a submodule, the project that holds the config" "$(root_of "$FS/Packages/Sub")"; fi
if [ "$(root_of "$FN2/Vendor/Core")" = "$FN2" ]; then ok "root: from an untracked nested repository, the same"
else nok "root: from an untracked nested repository, the same" "$(root_of "$FN2/Vendor/Core")"; fi
RN="$TMP/root-none"; mkdir -p "$RN"; nested_repo "$RN/inner"
if [ "$(root_of "$RN/inner")" = "$RN/inner" ]; then ok "root: a repository with no config above it stays its own root"
else nok "root: a repository with no config above it stays its own root" "$(root_of "$RN/inner")"; fi
# A worktree placed inside the checkout, without the local guest files: its own root, so the
# session-start notice still says no check runs there, and the main checkout is not checked for it.
git -C "$FL" worktree add -q "$FL/.worktrees/w1" -b w1 2>/dev/null
if [ "$(root_of "$FL/.worktrees/w1" "$FL")" = "$FL/.worktrees/w1" ]; then ok "root: a worktree inside the checkout, without the files, stays its own root"
else nok "root: a worktree inside the checkout, without the files, stays its own root" "$(root_of "$FL/.worktrees/w1" "$FL")"; fi
out="$(jq -nc --arg cwd "$FL/.worktrees/w1" '{cwd: $cwd, session_id: "test", source: "startup"}' | CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$FL" "$SCRIPTS/session-start.sh" 2>&1)"
if grep -q 'no check runs here' <<<"$out"; then ok "root: that worktree still says no check runs there"
else nok "root: that worktree still says no check runs there" "$out"; fi

nested_guard() { hook guard.sh "$FN/Packages/Core" "$(edit_input "$FN/Sources/Audio/Engine.swift")" | grep -q '"permissionDecision": "ask"'; }
if nested_guard; then ok "guard: from a nested repository, a protected file of the project still asks"
else nok "guard: from a nested repository, a protected file of the project still asks" "no approval request"; fi
git -C "$FN/Packages/Core" checkout -q -- . && git -C "$FN/Packages/Core" clean -qfd
hook session-start.sh "$FN" '{"source":"startup"}' >/dev/null
echo 'let app = 7' >"$FN/Sources/App.swift"
expect_result "stop: from a nested repository, the project is still verified" 2 'Verification failed' "exit=$(FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$FN/Packages/Core" >/dev/null 2>&1; echo $?)
$(rm -f "$TMP/data/state/"*/failed; FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$FN/Packages/Core" 2>&1)"

# ---------- docs adapter in a UTF-8 locale (#139) ----------

DL="$(new_project adapter-locale)"
mkdir -p "$DL/docs"; echo '# a' >"$DL/docs/a.md"
cat >"$DL/scripts/check-docs.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.." || exit 2
grep -q fixed docs/a.md || echo "docs/a.md:1: old problem"
echo "docs/B.md:2: old problem"
echo "docs/_c.md:3: old problem"
echo "docs/Z.md:4: old problem"
exit 1
EOF
chmod +x "$DL/scripts/check-docs.sh"
set_config "$DL" '{"verify":{"command":"scripts/verify.sh fast"},"docs":{"command":"scripts/check-docs.sh"}}'
git -C "$DL" add -A && git -C "$DL" commit -qm adapter
approve "$DL" >/dev/null
LC_ALL=en_US.UTF-8 hook session-start.sh "$DL" '{"source":"startup"}' >/dev/null
echo fixed >>"$DL/docs/a.md"
expect_result "adapter: in a UTF-8 locale, fixing one old problem does not make the others new" 0 '^exit=0' "$(LC_ALL=en_US.UTF-8 ev_stop "$DL")" 'were not there when the session started'

# ---------- check.sh run twice (#140) ----------

flat() { printf '%s\n' "${1%%$'\n'*}"; printf '%s' "${1#*$'\n'}" | tr '\n' ' '; }
CD="$(new_project check-twice)"
printf '#!/bin/bash\necho "docs/a.md:1: broken link"\nexit 1\n' >"$CD/scripts/check-docs.sh"; chmod +x "$CD/scripts/check-docs.sh"
set_config "$CD" '{"verify":{"command":"scripts/verify.sh fast"},"docs":{"command":"scripts/check-docs.sh"}}'
git -C "$CD" add -A && git -C "$CD" commit -qm docs
approve "$CD" >/dev/null
expect_result "check: a failing blocking docs check fails the first run" 1 'Result: FAILED' "$(flat "$(chk --project "$CD")")"
expect_result "check: and the second run, with nothing changed" 1 'Result: FAILED' "$(flat "$(chk --project "$CD")")"
expect_result "check: and --strict --json says failed, exit 1" 1 '"result": "failed"' "$(chk --project "$CD" --strict --json)"
set_config "$CD" '{"verify":{"command":"scripts/verify.sh fast"},"docs":{"command":"scripts/check-docs.sh","blocking":false}}'
expect_result "check: an observed docs check does not fail the run, and is named as failed" 0 'docs: scripts/check-docs\.sh: failed.*Result: passed' "$(flat "$(chk --project "$CD")")"
expect_result "check: nor the run after it" 0 'docs: scripts/check-docs\.sh: failed.*Result: passed' "$(flat "$(chk --project "$CD")")"
CL="$(new_project check-lint-observed)"
printf '#!/bin/bash\necho "Sources/App.swift:1: TODO"\nexit 1\n' >"$CL/scripts/lint.sh"; chmod +x "$CL/scripts/lint.sh"
set_config "$CL" '{"verify":{"command":"scripts/verify.sh fast"},"lint":{"command":"scripts/lint.sh","blocking":false}}'
git -C "$CL" add -A && git -C "$CL" commit -qm lint
approve "$CL" >/dev/null
echo 'let app = 2' >"$CL/Sources/App.swift"
expect_result "check: an observed lint check does not fail the run, and is named as failed" 0 'lint: scripts/lint\.sh: failed.*Result: passed' "$(flat "$(chk --project "$CL")")"

# ---------- an approved security change (#141) ----------

SA="$(sec_project sec-approved)"
hook session-start.sh "$SA" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$SA/Sources/App.swift"
entitle "$SA" 'com\.apple\.security\.network\.client' YES
rstop "$SA" >/dev/null
sec --approve "$(sec --status --project "$SA" | sed -n 's/^Digest: //p')" --project "$SA" >/dev/null
expect_result "security: after the user approves the change, the next Stop checks again and passes" 0 '^checked$' "$(ev_stop "$SA" | head -1)
$(jq -r .outcome "$(state_of "$SA")/evidence.json")"
out="$(hook session-start.sh "$SA" '{"source":"startup"}')"
if grep -qi 'failed on the current code' <<<"$out"; then nok "security: the next session does not start as failed after the approval" "$out"
else ok "security: the next session does not start as failed after the approval"; fi

# ---------- paths with non-ASCII characters (#142) ----------

SN="$(sec_project sec-nonascii)"
git -C "$SN" mv App/App.entitlements "App/Caffè.entitlements"
git -C "$SN" mv App.xcodeproj "Caffè.xcodeproj"
printf '// !$*UTF8*$!\n{\n\t\t\t\tSDKROOT = macosx;\n\t\t\t\tENABLE_HARDENED_RUNTIME = NO;\n}\n' >"$SN/Caffè.xcodeproj/project.pbxproj"
git -C "$SN" add -A && git -C "$SN" commit -qm 'names with an accent'
out="$(sec state --project "$SN")"
expect_result "security: an entitlements file with a non-ASCII name is read" 0 '^App/Caffè\.entitlements: com\.apple\.security\.app-sandbox = true' "exit=0
$out" 'not a readable plist'
expect_result "security: build settings of a project with a non-ASCII name are read" 0 '^Caffè\.xcodeproj/project\.pbxproj: ENABLE_HARDENED_RUNTIME = NO' "exit=0
$out"
expect_result "platforms: a project with a non-ASCII name is read" 0 '^macOS	Caffè\.xcodeproj/project\.pbxproj' "exit=0
$(printf '{}' | bash -c '. "$0"; sh_platforms "$1"' "$SCRIPTS/lib.sh" "$SN")"
SB="$(new_project scope-nonascii)"
git -C "$SB" branch -M main
set_config "$SB" '{"verify":{"command":"scripts/verify.sh fast"},"scope":[{"branch":"ios-*","paths":["App-iOS/"],"base":"main"}]}'
git -C "$SB" add -A && git -C "$SB" commit -qm scope
git -C "$SB" switch -qc ios-port
mkdir -p "$SB/App-iOS"; echo 'let c = 1' >"$SB/App-iOS/Città.swift"
# One call each: the notice is said once per set of files, so a second call would say nothing.
expect_result "scope: a file with a non-ASCII name inside the scope is not reported as outside" 0 '^exit=0$' "exit=0
$(hook scope-watch.sh "$SB" 2>&1)" 'outside its scope'
git -C "$SB" add -A && git -C "$SB" commit -qm 'a committed file with an accent'
rm -f "$(state_of "$SB")/sessions/test/scope-outside"
expect_result "scope: nor once it is committed" 0 '^exit=0$' "exit=0
$(hook scope-watch.sh "$SB" 2>&1)" 'outside its scope'

# ---------- interrupted turns (#143) ----------

RS="$(new_project resume)"
RSL="$TMP/resume.log"; : >"$RSL"
hook session-start.sh "$RS" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$RS/Sources/App.swift"
echo '// by a shell command' >>"$RS/Sources/Audio/Engine.swift"
hook session-start.sh "$RS" '{"source":"resume"}' >/dev/null
FAKE_VERIFY_LOG="$RSL" hook stop-verify.sh "$RS" >/dev/null 2>&1
if [ -s "$RSL" ]; then ok "session start: a resumed session keeps its baseline, so its earlier edits are verified"
else nok "session start: a resumed session keeps its baseline, so its earlier edits are verified" "$(ev_of "$RS" .)"; fi
expect_result "session start: a resumed session still reports a protected file changed before the resume" 0 'Sources/Audio/Engine\.swift' "exit=0
$(hook protected-watch.sh "$RS" 2>&1)"
hook session-start.sh "$RS" '{"source":"startup"}' >/dev/null
: >"$RSL"
FAKE_VERIFY_LOG="$RSL" hook stop-verify.sh "$RS" >/dev/null 2>&1
if [ ! -s "$RSL" ]; then ok "session start: a new start of the session takes the code as it is"
else nok "session start: a new start of the session takes the code as it is" "the verify command ran"; fi
FC="$(new_project failure-count)"
hook session-start.sh "$FC" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$FC/Sources/App.swift"; FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$FC" '{"stop_hook_active":false}' >/dev/null 2>&1
echo 'let app = 3' >"$FC/Sources/App.swift"; FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$FC" '{"stop_hook_active":true}' >/dev/null 2>&1
# The user interrupts here: no Stop. Then a new turn fails once.
echo 'let app = 4' >"$FC/Sources/App.swift"
expect_result "stop: after an interrupted turn, a new turn's first failure blocks as attempt 1" 2 'attempt 1 of 3' "$(FAKE_VERIFY_EXIT=1 ev_stop "$FC" '{"stop_hook_active":false}')"
echo 'let app = 5' >"$FC/Sources/App.swift"; FAKE_VERIFY_EXIT=1 hook stop-verify.sh "$FC" '{"stop_hook_active":true}' >/dev/null 2>&1
echo 'let app = 6' >"$FC/Sources/App.swift"
expect_result "stop: within one turn the attempts still add up to the limit" 0 'failed 3 times in a row' "$(FAKE_VERIFY_EXIT=1 ev_stop "$FC" '{"stop_hook_active":true}')"

# ---------- a Stop hook that never ended (#144) ----------

KS="$(new_project killed)"
# The verify command looks at what the hook has recorded while it is still running.
cat >"$KS/scripts/verify.sh" <<'EOF'
#!/bin/bash
cp "$KS_STATE/evidence.json" "$KS_STATE/evidence.during" 2>/dev/null
cp "$KS_STATE/sessions/test/running" "$KS_STATE/running.during" 2>/dev/null
exit 0
EOF
git -C "$KS" add -A && git -C "$KS" commit -qm 'a verify script that looks'
approve "$KS" >/dev/null
KSS="$(state_of "$KS")"
hook session-start.sh "$KS" '{"source":"startup"}' >/dev/null
echo 'let app = 2' >"$KS/Sources/App.swift"
KS_STATE="$KSS" hook stop-verify.sh "$KS" >/dev/null 2>&1
if [ "$(jq -r .outcome "$KSS/evidence.during" 2>/dev/null)" = not-finished ] && [ -s "$KSS/running.during" ]; then ok "stop: while the checks run, the record says not finished, and a marker is there"
else nok "stop: while the checks run, the record says not finished, and a marker is there" "$(cat "$KSS/evidence.during" 2>&1)"; fi
if [ ! -e "$KSS/sessions/test/running" ] && [ "$(jq -r .outcome "$KSS/evidence.json")" = passed ]; then ok "stop: when they end, the marker is gone and the record is the result"
else nok "stop: when they end, the marker is gone and the record is the result" "$(cat "$KSS/evidence.json")"; fi
if [ "$(grep -c '"outcome":"not-finished"' "$KSS/evidence-history.jsonl" 2>/dev/null)" = 0 ]; then ok "stop: the history keeps only the result"
else nok "stop: the history keeps only the result" "$(cat "$KSS/evidence-history.jsonl")"; fi
# As after a timeout: the marker of a run whose process is gone, and the record it left.
echo 'let app = 3' >"$KS/Sources/App.swift"
printf '%s\n%s\n%s\n' somecode "$(($(date +%s) - 1200))" 999999 >"$KSS/sessions/test/running"
jq -nc --arg c "$(jq -nc --arg cwd "$KS" '{cwd: $cwd}' | CLAUDE_PLUGIN_DATA="$TMP/data" bash -c '. "$0"; sh_init && sh_identity' "$SCRIPTS/lib.sh")" '{version: 1, code: $c, outcome: "not-finished", checks: []}' >"$KSS/evidence.json"
expect_row "doctor: a check that started and never ended is a warning" "$(doctor "$KS")" WARN 'Last verification' 'did not finish'
KS_STATE="$KSS" hook stop-verify.sh "$KS" >/dev/null 2>&1
if grep -q '"kind":"not-finished"' "$KSS/catches.jsonl" && grep -q '20 min' "$KSS/catches.jsonl"; then ok "stop: the next run records that the last one did not finish, and since when"
else nok "stop: the next run records that the last one did not finish, and since when" "$(tail -n 3 "$KSS/catches.jsonl")"; fi
expect_result "stop: the user is told once that a check did not finish" 0 'did not finish.*900' "exit=0
$(hook protected-watch.sh "$KS" 2>&1 | tr '\n' ' ')"
expect_result "stop: and not again" 0 '^exit=0$' "exit=0
$(hook protected-watch.sh "$KS" 2>&1)" 'did not finish'
mkdir -p "$TMP/own-tmp"
echo 'let app = 4' >"$KS/Sources/App.swift"
TMPDIR="$TMP/own-tmp" KS_STATE="$KSS" hook stop-verify.sh "$KS" >/dev/null 2>&1
if [ -z "$(ls "$TMP/own-tmp")" ] && [ "$(jq -r .outcome "$KSS/evidence.json")" = passed ]; then ok "stop: no temporary output file is left behind"
else nok "stop: no temporary output file is left behind" "$(ls "$TMP/own-tmp")"; fi

# ---------- the catch log: bound, and a broken line (#145) ----------

CB="$(new_project catch-bound)"
CBL="$(state_of "$CB")/catches.jsonl"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '{"time":"%s","session":"s","agent":"claude","check":"SwiftLint","kind":"blocked","what":"one"}\n' "$now"
  printf '{"time":"%s","session":"s","agent":"cl\n' "$now"
  printf '{"time":"%s","session":"s","agent":"claude","check":"SwiftLint","kind":"fixed","what":"two"}\n' "$now"
} >"$CBL"
out="$(report --project "$CB")"
expect_result "report: a broken line in the catch log does not empty the report" 0 'SwiftLint: 1 blocked, 1 fixed' "$out" 'Nothing in the catch log'
expect_result "report: it says how many lines it could not read" 0 '1 line.* could not be read' "$out"
: >"$CBL"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '{"time":"%s","session":"s","agent":"claude","check":"old","kind":"reported","what":"%s"}\n' "$now" "$i" >>"$CBL"; done
SWIFT_HARNESS_CATCH_MAX=8 hook guard.sh "$CB" "$(edit_input "$CB/Sources/Audio/Engine.swift")" >/dev/null
if [ "$(wc -l <"$CBL" | tr -d ' ')" -le 8 ] && tail -n 1 "$CBL" | jq -e '.check == "guard"' >/dev/null && ! grep -q '"what":"1"' "$CBL"; then ok "catch log: trimmed to its bound, keeping the newest lines"
else nok "catch log: trimmed to its bound, keeping the newest lines" "$(wc -l <"$CBL") line(s): $(tail -n 2 "$CBL")"; fi

# ---------- rules and the checks that enforce them (#148) ----------

RF="$TMP/rules-fakes"; mkdir -p "$RF"
cat >"$RF/swiftlint" <<'EOF'
#!/bin/bash
[ "$1" = rules ] || exit 0
[ -z "${FAKE_SWIFTLINT_NONE:-}" ] || exit 1
cat <<'TABLE'
+----------------+--------+-------------+
| identifier     | opt-in | correctable | enabled in your config |
+----------------+--------+-------------+
| line_length    | no     | no          | yes |
| sorted_imports | yes    | yes         | no  |
TABLE
EOF
chmod +x "$RF/swiftlint"
rules() { # rules.sh arguments; prints "exit=<code>" then the output
  local out code
  out="$(PATH="$RF:$PATH" "$SCRIPTS/rules.sh" "$@" 2>&1)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
R="$(new_project rules)"
mkdir -p "$R/.claude/rules"
cat >"$R/CLAUDE.md" <<'EOF'
# App
## Commands
- Lint: `swiftlint lint`
## Non-negotiable rules
- Core is protected. <!-- check: guard -->
- Views hold no logic.
- No raw padding. <!-- check: lint ds_padding --> <!-- check: lint nope_rule -->
- Shell changes are asked about. <!-- check: shell guard -->
- A typo in the name. <!-- check: gaurd -->
```
- a bullet inside a fence is not a rule
```
## Definition of done
- Tests pass.
EOF
cat >"$R/.claude/rules/arch.md" <<'EOF'
---
paths:
  - "**/*.swift"
---
- Contracts hold. <!-- check: architecture contracts -->
- A line nothing checks.
EOF
printf 'disabled_rules:\n  - trailing_whitespace\ncustom_rules:\n  ds_padding:\n    regex: x\n' >"$R/.swiftlint.yml"
out="$(rules --project "$R" --all)"
expect_result "rules: counts the rule lines, not the bullets of other sections or fences" 0 '^7 rule\(s\): 5 name a check, 2 name none\.' "$out"
expect_result "rules: a check that is turned off is named, with why" 0 'shell guard: off, guardBash is not turned on' "$out"
expect_result "rules: a name that is no check is called unknown" 0 'gaurd: unknown, no check called "gaurd"' "$out"
expect_result "rules: a lint rule that exists nowhere is unknown" 0 'lint nope_rule: unknown' "$out"
expect_result "rules: a custom lint rule of .swiftlint.yml holds" 0 '^7 rule' "$out" 'lint ds_padding: (off|unknown)'
expect_result "rules: --all lists the rules nothing checks, with file and line" 0 'CLAUDE\.md:6: Views hold no logic\.' "$out"
expect_result "rules: a bullet of Commands or Definition of done is not a rule" 0 '^7 rule' "$out" 'Tests pass|swiftlint lint'
expect_result "rules: without --all it says how to list them" 0 'Run with --all' "$(rules --project "$R")"
expect_result "rules: architecture contracts is off without the contract file" 0 'architecture contracts: off, no docs/architecture-contracts\.json' "$out"
mkdir -p "$R/docs"; echo '{}' >"$R/docs/architecture-contracts.json"
expect_result "rules: ... and holds with it" 0 '^7 rule' "$(rules --project "$R")" 'architecture contracts: off'
jq '.guardBash = true' "$R/.claude/swift-harness.json" >"$R/cfg.tmp" && mv "$R/cfg.tmp" "$R/.claude/swift-harness.json"
expect_result "rules: shell guard holds once guardBash is on" 0 '^7 rule' "$(rules --project "$R")" 'shell guard: off'
if [ "$(rules --project "$R" --json | sed 1d | jq -c '[.total, .linked, .unlinked, (.broken | length)]')" = '[7,5,2,2]' ]; then ok "rules --json: the same counts, and the broken links"
else nok "rules --json: the same counts, and the broken links" "$(rules --project "$R" --json)"; fi
# Lint rules the yml does not name: default and opt-in rules come from swiftlint itself.
printf '%s\n' '- Lines are short. <!-- check: lint line_length -->' '- Imports are sorted. <!-- check: lint sorted_imports -->' >>"$R/.claude/rules/arch.md"
printf 'disabled_rules:\n  - line_length\n' >"$R/.swiftlint.yml"
out="$(rules --project "$R")"
expect_result "rules: a default rule listed in disabled_rules is off" 0 'lint line_length: off, line_length is in disabled_rules' "$out"
expect_result "rules: an opt-in rule that opt_in_rules does not turn on is off" 0 'lint sorted_imports: off, sorted_imports is an opt-in rule' "$out"
printf 'opt_in_rules:\n  - sorted_imports\n' >"$R/.swiftlint.yml"
out="$(rules --project "$R")"
expect_result "rules: a default rule holds, and so does an opt-in rule that is turned on" 0 '^[0-9]+ rule' "$out" 'lint (line_length|sorted_imports): '
printf 'only_rules:\n  - sorted_imports\n' >"$R/.swiftlint.yml"
expect_result "rules: with only_rules, a rule not listed does not run" 0 'lint line_length: off, only_rules does not list' "$(rules --project "$R")"
printf 'opt_in_rules: []\n' >"$R/.swiftlint.yml"
out="$(FAKE_SWIFTLINT_NONE=1 rules --project "$R")"
expect_result "rules: with no way to list SwiftLint's rules, it says unchecked, not wrong" 0 'could not be checked here' "$out" 'lint line_length: (off|unknown)'
# The doctor row.
expect_row "doctor: broken rule links are a warning" "$(doctor "$R")" WARN Rules 'do not hold'
RN="$(new_project rules-none)"
printf '# App\n## Rules\n- A rule.\n- Another.\n' >"$RN/CLAUDE.md"
expect_row "doctor: rules that name no check are only information" "$(doctor "$RN")" INFO Rules '2 rule\(s\), none names'
RO="$(new_project rules-ok)"
printf '# App\n## Rules\n- Core. <!-- check: guard -->\n- Another.\n' >"$RO/CLAUDE.md"
expect_row "doctor: links that hold are a pass" "$(doctor "$RO")" PASS Rules '1 of 2 rule\(s\) name a check'
RE="$(new_project rules-empty)"
if ! doctor "$RE" | grep -q '| Rules |'; then ok "doctor: a project with no rule lines gets no Rules row"; else nok "doctor: a project with no rule lines gets no Rules row"; fi
# The report counts the catches of each linked rule.
RC="$(new_project rules-report)"
printf '# App\n## Rules\n- Core. <!-- check: guard -->\n- Padding. <!-- check: lint ds_hardcoded_padding -->\n- Other lint. <!-- check: lint line_length -->\n- Quiet. <!-- check: security settings -->\n- Free.\n' >"$RC/CLAUDE.md"
printf 'disabled_rules: []\ncustom_rules:\n  ds_hardcoded_padding:\n    regex: x\n' >"$RC/.swiftlint.yml"
hook session-start.sh "$RC" '{"source":"startup"}' >/dev/null
RCL="$(state_of "$RC")/catches.jsonl"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '{"time":"%s","session":"s","agent":"claude","check":"guard","kind":"asked","what":"a"}\n' "$now"
  printf '{"time":"%s","session":"s","agent":"claude","check":"guard","kind":"blocked","what":"b"}\n' "$now"
  printf '{"time":"%s","session":"s","agent":"claude","check":"guard","kind":"approved","what":"not a catch"}\n' "$now"
  printf '{"time":"%s","session":"s","agent":"claude","check":"SwiftLint","kind":"reported","what":"2 issue(s) in A.swift: ds_hardcoded_padding, vertical_whitespace"}\n' "$now"
  printf '{"time":"%s","session":"s","agent":"claude","check":"SwiftLint","kind":"reported","what":"1 issue(s) in B.swift: ds_hardcoded_padding_extra"}\n' "$now"
} >"$RCL"
out="$(report --project "$RC")"
expect_result "report: a linked rule shows how often its check caught something" 0 '^- Core\. -> guard: 2 catch\(es\)$' "$out"
expect_result "report: a lint rule is counted from the rule ids the catch names, whole ids only" 0 '^- Padding\. -> lint ds_hardcoded_padding: 1 catch\(es\)$' "$out"
expect_result "report: a rule whose check caught nothing says so, and the list is for the user" 0 '^- Quiet\. -> security settings: no catch in the period$' "$out"
expect_result "report: the heading counts linked and unlinked rules" 0 'Rules that name a check \(4 of 5; 1 name none\)' "$out"
expect_result "report: --json carries the rules part" 0 '"caught": 2' "$(report --project "$RC" --json)"
RH="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/report.sh" --project "$RC" --html 2>&1)"
if grep -q 'Rules that name a check' "$RH" 2>/dev/null && grep -q '<td>guard</td><td>2</td>' "$RH"; then ok "report --html: a table of the rules and their catches"
else nok "report --html: a table of the rules and their catches" "$RH"; fi
RZ="$(new_project rules-report-none)"
printf '# App\n## Rules\n- Free.\n' >"$RZ/CLAUDE.md"
hook session-start.sh "$RZ" '{"source":"startup"}' >/dev/null
expect_result "report: with no rule naming a check, the part is left out" 0 '^swift-harness report for ' "$(report --project "$RZ")" 'Rules that name'
# The setup templates: every link they ship holds in a project set up from them.
RT="$(new_project rules-templates)"
mkdir -p "$RT/.claude/rules" "$RT/docs"
cp "$PLUGIN/skills/setup/templates/CLAUDE.md" "$RT/CLAUDE.md"
cp "$PLUGIN/skills/setup/templates/rules/"*.md "$RT/.claude/rules/"
cp "$PLUGIN/skills/setup/templates/swiftlint.yml" "$RT/.swiftlint.yml"
echo '{}' >"$RT/docs/architecture-contracts.json"
jq '.lint = "swiftlint"' "$RT/.claude/swift-harness.json" >"$RT/cfg.tmp" && mv "$RT/cfg.tmp" "$RT/.claude/swift-harness.json"
out="$(FAKE_SWIFTLINT_NONE=1 rules --project "$RT" --json)"
if [ "$(sed 1d <<<"$out" | jq -c '[(.linked > 8), (.broken | length), (.unchecked | length)]')" = '[true,0,0]' ]; then ok "rules: every link the setup templates ship holds"
else nok "rules: every link the setup templates ship holds" "$(sed 1d <<<"$out" | jq -c '[.broken, .unchecked]')"; fi
if [ "$(grep -c 'check:' "$PLUGIN/skills/setup/templates/CLAUDE.md")" -ge 6 ]; then ok "templates: the main rules name their checks"; else nok "templates: the main rules name their checks"; fi
RNum="$(new_project rules-numbered)"
printf '# App\n## Architecture rules\n1. Layers hold. <!-- check: guard -->\n2) Views have no logic.\n* Star item.\n' >"$RNum/CLAUDE.md"
expect_result "rules: numbered and starred items are rules too" 0 '^3 rule\(s\): 1 name a check, 2 name none\.' "$(rules --project "$RNum")"
expect_result "rules: usage error" 2 'usage' "$(rules --bogus)"
# ---------- porting: the C floating-point environment and build-check ----------

BC="$TMP/bc-project"
mkdir -p "$BC/Sources/DSP" "$BC/Sources/Domain" "$BC/Sources/Core" "$BC/.build"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "X", targets: [])\n' >"$BC/Package.swift"
printf 'import Foundation\nfunc f() {\n  var e = fenv_t()\n  fegetenv(&e)\n}\n// fesetenv in a comment\nlet s = "fegetenv in a string"\n' >"$BC/Sources/DSP/Denormals.swift"
echo 'let d = 1' >"$BC/Sources/Domain/D.swift"
echo 'let c = 1' >"$BC/Sources/Core/C.swift"
echo 'secret' >"$BC/Secrets.xcconfig"
echo 'old build' >"$BC/.build/stale"
git -C "$BC" init -q
bcscan="$("$SCRIPTS/porting.sh" scan "$BC" 2>&1)"
expect_result "porting: fenv_t and fegetenv block iOS, with their lines" 0 'blocks	Sources/DSP	Sources/DSP/Denormals\.swift:3	floating-point environment.*Denormals\.swift:4	floating-point environment' "exit=0
$(printf '%s' "$bcscan" | tr '\n' ' ')"
if [ "$(printf '%s\n' "$bcscan" | grep -c 'floating-point environment')" = 2 ]; then ok "porting: fenv in a comment or a string is not code"
else nok "porting: fenv in a comment or a string is not code" "$bcscan"; fi

BF="$TMP/bc-fakes"; mkdir -p "$BF" "$TMP/bc-tmp" "$TMP/bc-sdk"
cat >"$BF/xcrun" <<'EOF'
#!/bin/bash
case "$*" in
  *--show-sdk-path*) echo "${FAKE_SDK:-/nonexistent}" ;;
  *--show-sdk-version*) echo 27.2 ;;
esac
EOF
cat >"$BF/swift" <<'EOF'
#!/bin/bash
# fake swift build: logs its arguments and the files it sees; fails the targets in FAKE_SWIFT_FAIL
echo "$*" >>"$FAKE_SWIFT_LOG"
ls -a "$PWD" | tr '\n' ' ' >>"$FAKE_SWIFT_LOG"; echo >>"$FAKE_SWIFT_LOG"
target=""
while [ $# -gt 0 ]; do [ "$1" = --target ] && target="$2"; shift; done
case " ${FAKE_SWIFT_FAIL:-} " in
  *" $target "*)
    printf '%s/Sources/DSP/Denormals.swift:3:11: \033[1;31merror: \033[0mcannot find '"'"'fenv_t'"'"' in scope\n' "$PWD"
    printf '%s/Sources/DSP/Denormals.swift:4:3: error: cannot find '"'"'fegetenv'"'"' in scope\n' "$PWD"
    printf '%s/Sources/DSP/Denormals.swift:4:3: error: cannot find '"'"'fegetenv'"'"' in scope\n' "$PWD"
    echo "error: Build failed"; exit 1 ;;
esac
case " ${FAKE_SWIFT_LINK:-} " in
  *" $target "*)
    printf '%s/Sources/Net/n.swift:2:5: error: not concurrency-safe [\033]8;;https://docs.swift.org/x\033\\#MutableGlobalVariable\033]8;;\033\\]\n' "$PWD"
    echo "error: Build failed"; exit 1 ;;
esac
case " ${FAKE_SWIFT_C:-} " in
  *" $target "*) # the new build system writes a C error as "error: path:line:col message"
    printf 'error: %s/Sources/IO/io.c:3:10 '"'"'IOKit/a.h'"'"' file not found\n' "$PWD"
    printf '%s/Sources/IO/io.c:4:10: fatal error: '"'"'IOKit/b.h'"'"' file not found\n' "$PWD"
    echo "error: Build failed"; exit 1 ;;
esac
echo "Build complete!"
EOF
chmod +x "$BF/xcrun" "$BF/swift"
bc() { # build-check arguments; prints "exit=<code>" then the output
  local out code
  out="$(PATH="$BF:$PATH" TMPDIR="$TMP/bc-tmp" FAKE_SDK="${FAKE_SDK:-$TMP/bc-sdk}" FAKE_SWIFT_LOG="$TMP/bc-swift.log" "$SCRIPTS/porting.sh" build-check "$@" 2>&1 </dev/null)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
bcbefore="$(snapshot "$BC")"
: >"$TMP/bc-swift.log"
out="$(FAKE_SWIFT_FAIL="DSP Domain" bc "$BC")"
expect_result "build-check: a target that builds is a PASS, a failing one a FAIL with its errors" 0 '- PASS Core.*- FAIL DSP: 2 error\(s\).*Sources/DSP/Denormals\.swift:3:11: cannot find .fenv_t. in scope' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
expect_result "build-check: the same error twice is counted once, colours are gone" 1 'FAIL DSP: 2 error' "$out" $'\x1b'
expect_result "build-check: a target behind a failing one shows the other's errors, and says why" 1 'FAIL Domain: 2 error\(s\)' "$out"
expect_result "build-check: names the module the error came from only for a dependency" 0 'Domain: 2 error.*\(in DSP, a dependency\)' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
expect_result "build-check: ... and the DSP's own errors carry no such note" 0 'FAIL DSP: 2 error\(s\) +Sources/DSP/Denormals\.swift:3:11: cannot find .fenv_t. in scope +Sources/DSP/Denormals\.swift:4:3: cannot find .fegetenv. in scope +(- |A target)' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
expect_result "build-check: it says a dependency's errors hide the target's own" 1 'behind a failing dependency' "$out"
expect_result "build-check: it says it is a build only" 1 '1 built, 2 failed\. This is a build only: nothing was tested' "$out"
expect_result "build-check: exits 1 when a target failed" 1 'FAIL DSP' "$out"
expect_result "build-check: it names the SDK and the iOS version it used" 1 'iOS 27\.0, SDK 27\.2' "$out"
if grep -q -- '--triple [a-z0-9_]*-apple-ios27.0-simulator' "$TMP/bc-swift.log" && grep -q -- "--sdk $TMP/bc-sdk" "$TMP/bc-swift.log"; then ok "build-check: builds each target for the simulator triple with the simulator SDK"
else nok "build-check: builds each target for the simulator triple with the simulator SDK" "$(cat "$TMP/bc-swift.log")"; fi
if [ "$(grep -c -- '--target' "$TMP/bc-swift.log")" = 3 ]; then ok "build-check: one build per folder of Sources/"; else nok "build-check: one build per folder of Sources/" "$(cat "$TMP/bc-swift.log")"; fi
if ! grep -qE '(^| )(\.git|\.build|Secrets\.xcconfig)( |$)' "$TMP/bc-swift.log" && grep -q 'Package.swift' "$TMP/bc-swift.log"; then ok "build-check: the copy has no .git, .build or secrets"
else nok "build-check: the copy has no .git, .build or secrets" "$(grep -v -- '--target' "$TMP/bc-swift.log" | head -3)"; fi
if [ "$bcbefore" = "$(snapshot "$BC")" ]; then ok "build-check: the project is unchanged"; else nok "build-check: the project is unchanged"; fi
if [ -z "$(ls -A "$TMP/bc-tmp")" ]; then ok "build-check: the copy is removed afterwards"; else nok "build-check: the copy is removed afterwards" "$(ls "$TMP/bc-tmp")"; fi
: >"$TMP/bc-swift.log"
out="$(bc "$BC" --target Core --ios 17.0 --keep)"
expect_result "build-check: --target limits it, --ios sets the version, --keep says where the copy is" 0 'iOS 17\.0.*- PASS Core.*Copy kept at ' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
if [ "$(grep -c -- '--target' "$TMP/bc-swift.log")" = 1 ] && grep -q 'ios17.0-simulator' "$TMP/bc-swift.log"; then ok "build-check: only the named target was built"; else nok "build-check: only the named target was built" "$(cat "$TMP/bc-swift.log")"; fi
out="$(FAKE_SWIFT_C="IO" bc "$BC" --target IO)"
expect_result "build-check: reads C errors in the new build system's form and fatal errors" 0 'FAIL IO: 2 error\(s\) +Sources/IO/io\.c:3:10: .IOKit/a\.h. file not found +Sources/IO/io\.c:4:10: .IOKit/b\.h. file not found' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
rm -rf "$TMP/bc-tmp"; mkdir -p "$TMP/bc-tmp"
expect_result "build-check: a bad --ios is a usage error" 2 'usage' "$(bc "$BC" --ios latest)"
expect_result "build-check: an unknown option is a usage error" 2 'usage' "$(bc "$BC" --bogus)"
BN="$TMP/bc-nopkg"; mkdir -p "$BN/Sources/A"; echo 'let a = 1' >"$BN/Sources/A/A.swift"
expect_result "build-check: without a root Package.swift it says so" 1 'no Package\.swift' "$(bc "$BN")"
expect_result "build-check: without a simulator SDK it says so" 1 'no iOS Simulator SDK' "$(FAKE_SDK=/nonexistent bc "$BC" --target Core | sed 's/^exit=0$/exit=0/')" 
expect_result "porting: scan still takes no build options" 2 'usage' "exit=$("$SCRIPTS/porting.sh" scan "$BC" --keep >/dev/null 2>&1; echo $?)
usage"

# ---------- porting: test-check ----------

TC="$TMP/tc-project"
mkdir -p "$TC/Sources/Core" "$TC/Sources/MacOnly" "$TC/Tests/CoreTests" "$TC/Tests/MacOnlyTests" "$TC/App.xcodeproj" "$TC/.build"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "X", targets: [])\n' >"$TC/Package.swift"
echo 'let c = 1' >"$TC/Sources/Core/C.swift"
echo 'import AppKit' >"$TC/Sources/MacOnly/M.swift"
echo 'import Testing' >"$TC/Tests/CoreTests/T.swift"
echo 'import Testing' >"$TC/Tests/MacOnlyTests/T.swift"
echo 'secret' >"$TC/Secrets.xcconfig"
echo 'old build' >"$TC/.build/stale"
TF="$TMP/tc-fakes"; mkdir -p "$TF" "$TMP/tc-tmp"
cat >"$TF/xcrun" <<'EOF'
#!/bin/bash
# fake xcrun: simctl list and shutdown, xcresulttool summary
echo "xcrun $*" >>"$FAKE_TC_LOG"
case "$*" in
  "simctl list devices available --json") cat "$FAKE_SIMS" ;;
  "simctl shutdown "*) ;;
  "xcresulttool get test-results summary --path "*) [ -n "${FAKE_SUMMARY:-}" ] && cat "$FAKE_SUMMARY" ;;
esac
EOF
cat >"$TF/xcodebuild" <<'EOF'
#!/bin/bash
# fake xcodebuild test: logs its arguments, the copy and the scheme; writes a result bundle
echo "xcodebuild $*" >>"$FAKE_TC_LOG"
ls -a "$PWD" | tr '\n' ' ' >>"$FAKE_TC_LOG"; echo >>"$FAKE_TC_LOG"
cat "$PWD"/.swiftpm/xcode/xcshareddata/xcschemes/*.xcscheme >>"$FAKE_TC_LOG" 2>/dev/null; echo >>"$FAKE_TC_LOG"
bundle=""
while [ $# -gt 0 ]; do [ "$1" = -resultBundlePath ] && bundle="$2"; shift; done
case "${FAKE_XCB:-pass}" in
  pass) mkdir -p "$bundle"; echo "** TEST SUCCEEDED **" ;;
  fail) mkdir -p "$bundle"; echo "** TEST FAILED **"; exit 65 ;;
  build)
    printf '%s/Sources/MacOnly/M.swift:1:8: \033[1;31merror: \033[0mno such module '"'"'AppKit'"'"'\n' "$PWD"
    printf '%s/Sources/MacOnly/M.swift:1:8: error: no such module '"'"'AppKit'"'"'\n' "$PWD"
    echo "** TEST FAILED **"; exit 65 ;;
  noscheme) echo "xcodebuild: error: The project does not contain a scheme."; exit 66 ;;
esac
EOF
chmod +x "$TF/xcrun" "$TF/xcodebuild"
cat >"$TMP/tc-sims.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [{"name": "Apple Watch", "udid": "W-1", "state": "Shutdown", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [{"name": "iPhone 17", "udid": "OLD-1", "state": "Shutdown", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPad Pro", "udid": "PAD-1", "state": "Shutdown", "isAvailable": true},
                                                  {"name": "iPhone 18 Pro", "udid": "NEW-1", "state": "Shutdown", "isAvailable": true},
                                                  {"name": "iPhone 18", "udid": "NEW-2", "state": "Booted", "isAvailable": true}]
}}
EOF
cat >"$TMP/tc-pass.json" <<'EOF'
{"result": "Passed", "totalTestCount": 12, "passedTests": 10, "failedTests": 0, "skippedTests": 2, "expectedFailures": 0, "testFailures": []}
EOF
cat >"$TMP/tc-fail.json" <<'EOF'
{"result": "Failed", "totalTestCount": 12, "passedTests": 9, "failedTests": 1, "skippedTests": 2, "expectedFailures": 0,
 "testFailures": [{"testName": "parsesTheDate()", "targetName": "CoreTests", "failureText": "Expectation failed: (date → nil) != nil"}]}
EOF
tcrun() { # test-check arguments; prints "exit=<code>" then the output
  local out code
  out="$(PATH="$TF:$PATH" TMPDIR="$TMP/tc-tmp" FAKE_SIMS="${FAKE_SIMS:-$TMP/tc-sims.json}" FAKE_TC_LOG="$TMP/tc.log" "$SCRIPTS/porting.sh" test-check "$@" 2>&1 </dev/null)"
  code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}
tcbefore="$(snapshot "$TC")"
: >"$TMP/tc.log"
out="$(FAKE_SUMMARY="$TMP/tc-pass.json" tcrun "$TC" --target CoreTests)"
expect_result "test-check: the counts come from the result bundle" 0 'iPhone 18 Pro, iOS 27\.2.*CoreTests.*12 test\(s\): 10 passed, 0 failed, 2 skipped' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
expect_result "test-check: it says what it did not prove" 0 'no UI was looked at, the Mac app was not built.*a skipped test proves nothing' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
if grep -q 'destination platform=iOS Simulator,id=NEW-1 ' "$TMP/tc.log"; then ok "test-check: picks the first iPhone of the newest iOS runtime"
else nok "test-check: picks the first iPhone of the newest iOS runtime" "$(grep xcodebuild "$TMP/tc.log")"; fi
if grep -q 'BlueprintName="CoreTests"' "$TMP/tc.log" && ! grep -q 'BlueprintName="MacOnlyTests"' "$TMP/tc.log"; then ok "test-check: the temporary scheme holds only the named test targets"
else nok "test-check: the temporary scheme holds only the named test targets" "$(grep -o 'BlueprintName="[^"]*"' "$TMP/tc.log" | sort -u)"; fi
if grep -q -- '-scheme swift-harness-port-tests' "$TMP/tc.log" && grep -q -- '-resultBundlePath ' "$TMP/tc.log"; then ok "test-check: runs xcodebuild test with that scheme and a result bundle"
else nok "test-check: runs xcodebuild test with that scheme and a result bundle" "$(grep xcodebuild "$TMP/tc.log")"; fi
if ! grep -qE '(^| )(\.git|\.build|Secrets\.xcconfig|App\.xcodeproj)( |$)' "$TMP/tc.log" && grep -q 'Package.swift' "$TMP/tc.log"; then ok "test-check: the copy has no .git, .build, secrets or root Xcode project"
else nok "test-check: the copy has no .git, .build, secrets or root Xcode project" "$(grep 'Package.swift' "$TMP/tc.log")"; fi
if grep -q 'simctl shutdown NEW-1' "$TMP/tc.log"; then ok "test-check: shuts down a simulator it found shut down"
else nok "test-check: shuts down a simulator it found shut down" "$(grep simctl "$TMP/tc.log")"; fi
if [ "$tcbefore" = "$(snapshot "$TC")" ]; then ok "test-check: the project is unchanged"; else nok "test-check: the project is unchanged"; fi
if [ -z "$(ls -A "$TMP/tc-tmp")" ]; then ok "test-check: the copy is removed afterwards"; else nok "test-check: the copy is removed afterwards" "$(ls "$TMP/tc-tmp")"; fi
: >"$TMP/tc.log"
out="$(FAKE_XCB=fail FAKE_SUMMARY="$TMP/tc-fail.json" tcrun "$TC" --device "iPhone 18")"
expect_result "test-check: a failing test is named with its message" 0 '12 test\(s\): 9 passed, 1 failed, 2 skipped.*CoreTests/parsesTheDate\(\): Expectation failed' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
if grep -q 'id=NEW-2 ' "$TMP/tc.log" && ! grep -q 'simctl shutdown' "$TMP/tc.log"; then ok "test-check: --device picks by name and leaves a booted simulator booted"
else nok "test-check: --device picks by name and leaves a booted simulator booted" "$(grep -E 'xcodebuild|simctl' "$TMP/tc.log")"; fi
if grep -q 'BlueprintName="CoreTests"' "$TMP/tc.log" && grep -q 'BlueprintName="MacOnlyTests"' "$TMP/tc.log"; then ok "test-check: without --target every folder of Tests/ is in the scheme"
else nok "test-check: without --target every folder of Tests/ is in the scheme" "$(grep -o 'BlueprintName="[^"]*"' "$TMP/tc.log" | sort -u)"; fi
out="$(FAKE_XCB=build tcrun "$TC")"
expect_result "test-check: tests that do not build show the compiler's errors, once, without colour" 0 'the tests did not build: 1 error\(s\) +Sources/MacOnly/M\.swift:1:8: no such module .AppKit.' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')" $'\x1b'
expect_result "test-check: a result bundle it cannot read is not called a build failure" 0 'result bundle could not be read.*TEST SUCCEEDED' "exit=0
$(printf '%s' "$(tcrun "$TC")" | tr '\n' ' ')" 'did not build'
expect_result "test-check: a failure with no error line shows xcodebuild's own" 1 'did not run: xcodebuild: error: The project does not contain a scheme' "$(FAKE_XCB=noscheme tcrun "$TC")"
expect_result "test-check: exits 0 when tests ran and none failed" 0 '10 passed, 0 failed' "$(FAKE_SUMMARY="$TMP/tc-pass.json" tcrun "$TC" --target CoreTests)"
expect_result "test-check: exits 1 when a test failed" 1 '1 failed' "$(FAKE_XCB=fail FAKE_SUMMARY="$TMP/tc-fail.json" tcrun "$TC" --target CoreTests)"
expect_result "test-check: an unknown --device says so" 1 'no available iOS simulator called .iPad Mini.' "$(tcrun "$TC" --device "iPad Mini")"
printf '{"devices": {}}\n' >"$TMP/tc-nosims.json"
expect_result "test-check: no iPhone simulator says how to get one" 1 'no iPhone simulator' "$(FAKE_SIMS="$TMP/tc-nosims.json" tcrun "$TC")"
expect_result "test-check: without a root Package.swift it says so" 1 'no Package\.swift' "$(tcrun "$BN")"
expect_result "test-check: a bad target name is a usage error" 2 'usage' "$(tcrun "$TC" --target 'a b')"

# ---------- porting: audio APIs only the compiler showed ----------

AU="$TMP/au-project"
mkdir -p "$AU/Sources/Effects"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "X", targets: [])\n' >"$AU/Package.swift"
printf 'import AudioToolbox\nimport AVFoundation\nfunc make() async throws -> AVAudioUnit {\n  try await AVAudioUnit.instantiate(with: d, options: .loadInProcess)\n}\n' >"$AU/Sources/Effects/Unit.swift"
printf 'import AudioToolbox\nfunc f(_ p: UnsafeMutablePointer<AudioBufferList>) {\n  let b = UnsafeMutableAudioBufferListPointer(p)\n}\n' >"$AU/Sources/Effects/Kernel.swift"
printf 'import AudioToolbox\nimport CoreAudio\nfunc g(_ p: UnsafeMutablePointer<AudioBufferList>) {\n  let b = UnsafeMutableAudioBufferListPointer(p)\n}\n' >"$AU/Sources/Effects/Fixed.swift"
printf 'import AVFAudio\nfunc h(_ p: UnsafeMutablePointer<AudioBufferList>) {\n  let b = UnsafeMutableAudioBufferListPointer(p)\n}\n' >"$AU/Sources/Effects/ViaAVFAudio.swift"
printf '#if os(macOS)\nimport AudioToolbox\nlet o: AudioComponentInstantiationOptions = .loadInProcess\n#endif\n' >"$AU/Sources/Effects/Guarded.swift"
git -C "$AU" init -q
auscan="$("$SCRIPTS/porting.sh" scan "$AU" 2>&1)"
expect_result "porting: .loadInProcess blocks iOS, with its line" 0 'blocks	Sources/Effects	Sources/Effects/Unit\.swift:4	\.loadInProcess' "exit=0
$auscan"
expect_result "porting: the buffer list pointer without import CoreAudio blocks iOS" 0 'blocks	Sources/Effects	Sources/Effects/Kernel\.swift:3	UnsafeMutableAudioBufferListPointer without import CoreAudio' "exit=0
$auscan"
expect_result "porting: ... not when the file imports CoreAudio or AVFAudio" 0 '' "exit=0
$auscan" 'Fixed\.swift|ViaAVFAudio\.swift'
expect_result "porting: .loadInProcess inside #if os(macOS) is guarded" 0 'guarded	Sources/Effects	Sources/Effects/Guarded\.swift:3	\.loadInProcess' "exit=0
$auscan"

# ---------- porting ratchet (#73) ----------

RT="$(new_project ratchet)"
mkdir -p "$RT/Sources/Core" "$RT/Sources/MacUI" "$RT/Packages/Kit/Sources/Shared"
printf '// swift-tools-version: 6.0\n' >"$RT/Package.swift"
printf '// swift-tools-version: 6.0\n' >"$RT/Packages/Kit/Package.swift"
printf 'import Foundation\nstruct Model {}\n' >"$RT/Sources/Core/Model.swift"
printf 'import AppKit\nlet tint = NSColor.red\n' >"$RT/Sources/MacUI/Window.swift"
printf '#if os(macOS)\nimport AppKit\n#endif\nlet legacy = NSColor.red\n' >"$RT/Packages/Kit/Sources/Shared/Legacy.swift"
set_config "$RT" '{"format":"none","lint":"none","verify":{"enabled":false}}'
git -C "$RT" add -A && git -C "$RT" commit -qm modules
ratchet() { local o c; o="$("$SCRIPTS/porting.sh" ratchet "$RT" "$@" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
expect_result "ratchet: no ratchet file, nothing to check" 0 '^exit=0$' "$(ratchet)"
expect_result "ratchet: --module needs --record" 2 'usage' "$(ratchet --module Sources/Core)"
expect_result "ratchet: an unknown module is refused, with the names summary uses" 2 'no module Sources/Nope\. Name it as porting\.sh summary does: .*Sources/Core' "$(ratchet --record --module Sources/Nope)"
expect_result "ratchet: a path outside the project is refused" 2 'not a module folder' "$(ratchet --record --module ../x)"
out="$(ratchet --record --module Sources/Core --module 'Packages/Kit › Sources/Shared')"
expect_result "ratchet: recording names the modules and accepts the current uses" 0 '2 module\(s\), 1 macOS-only use\(s\) accepted' "$out"
expect_result "ratchet: ... listing each accepted use" 0 'accepted: Packages/Kit/Sources/Shared/Legacy\.swift: AppKit NSColor \(1\)' "$out"
rtfile="$(grep -v '^#' "$RT/docs/PORTING_RATCHET.tsv" | paste -sd'|' -)"
if [ "$rtfile" = "module	Sources/Core|module	Packages/Kit › Sources/Shared|accepted	Packages/Kit › Sources/Shared	Packages/Kit/Sources/Shared/Legacy.swift	AppKit NSColor	1" ]; then
  ok "ratchet: the file lists modules and accepted uses, tab-separated"
else nok "ratchet: the file lists modules and accepted uses, tab-separated" "$rtfile"; fi
expect_result "ratchet: right after recording, the check passes" 0 '^exit=0$' "$(ratchet)"
printf 'import AppKit\nlet w = NSWindow()\n' >>"$RT/Sources/Core/Model.swift"
out="$(ratchet)"
expect_result "ratchet: a new import AppKit in a ported module fails, naming the line" 1 'Sources/Core/Model\.swift:3: import AppKit \(in Sources/Core, ported to iOS; none accepted here\)' "$out"
expect_result "ratchet: each new use is named" 1 'Sources/Core/Model\.swift:4: AppKit NSWindow' "$out"
expect_result "ratchet: the failure says how to fix it, and not to record it" 1 'inside #if os\(macOS\), or behind a protocol.*do not record it yourself' "$out"
expect_result "ratchet: a module that is not ported is not checked" 1 'Model' "$out" 'MacUI'
printf '#if os(macOS)\nimport AppKit\nlet w = NSWindow()\n#endif\n' >"$RT/Sources/Core/Model.swift"
expect_result "ratchet: the same code inside #if os(macOS) passes" 0 '^exit=0$' "$(ratchet)"
printf 'let more = NSColor.blue\n' >>"$RT/Packages/Kit/Sources/Shared/Legacy.swift"
expect_result "ratchet: one use more than accepted fails, with both counts" 1 'Legacy\.swift:4, .*Legacy\.swift:5: AppKit NSColor \(in Packages/Kit › Sources/Shared, ported to iOS; 1 accepted here, 2 now\)' "$(ratchet)"
git -C "$RT" checkout -q -- Packages
git -C "$RT" add -A && git -C "$RT" commit -qm ratchet

# The end of the turn: no verify approval needed, it reads text only.
hook session-start.sh "$RT" '{"source":"startup"}' >/dev/null
printf 'import AppKit\n' >>"$RT/Sources/Core/Model.swift"
out="$(rstop "$RT")"
expect_result "stop: the porting ratchet blocks the turn on new macOS-only code" 2 'Sources/Core/Model\.swift:5: import AppKit \(in Sources/Core' "$out"
expect_result "stop: the porting ratchet is named in the failure header" 2 'porting ratchet' "$out"
git -C "$RT" checkout -q -- Sources
expect_result "stop: the ratchet passes once the code is guarded again" 0 '^exit=0' "$(rstop "$RT")"
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$RT" 2>&1)"
expect_result "doctor: the ratchet row counts modules and accepted uses" 0 'Porting ratchet.*2 ported module\(s\), 1 macOS-only use\(s\) accepted' "exit=0
$out"

# Weaker: a module dropped, or a use accepted by recording again, is told to the user.
hook session-start.sh "$RT" '{"source":"startup"}' >/dev/null
printf 'let more = NSColor.blue\n' >>"$RT/Packages/Kit/Sources/Shared/Legacy.swift"
"$SCRIPTS/porting.sh" ratchet "$RT" --record >/dev/null 2>&1
sed -i '' '/^module	Sources\/Core$/d' "$RT/docs/PORTING_RATCHET.tsv"
out="$(hook weaken-watch.sh "$RT" 2>&1)"
expect_result "weakened: a module removed from the porting ratchet is reported" 0 'docs/PORTING_RATCHET\.tsv: module Sources/Core removed from the porting ratchet' "exit=0
$out"
expect_result "weakened: a macOS-only use accepted by recording again is reported" 0 '1 macOS-only use accepted by the porting ratchet: Packages/Kit/Sources/Shared/Legacy\.swift: AppKit NSColor' "exit=0
$out"
set_config "$RT" '{"format":"none","lint":"none","verify":{"enabled":false},"porting":{"ratchet":"plans/ios.tsv"}}'
expect_result "ratchet: porting.ratchet moves the file" 0 'plans/ios\.tsv' "$(ratchet --record --module Sources/Core)"
expect_result "ratchet: ... and the check reads it there" 0 '^exit=0$' "$(ratchet)"

# ---------- porting: APIs common in Mac apps (#173) ----------

out="$(FAKE_SWIFT_LINK="Net" bc "$BC" --target Net)"
expect_result "build-check: a terminal hyperlink in an error keeps its text, not its escape codes" 1 'n\.swift:2:5: not concurrency-safe \[#MutableGlobalVariable\]' "$out" $'\x1b|8;;'

CA="$TMP/common-apis"
mkdir -p "$CA/Sources/Tools" "$CA/Sources/Guarded" "$CA/Sources/UI"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "X", targets: [])\n' >"$CA/Package.swift"
cat >"$CA/Sources/Tools/Tools.swift" <<'SWIFT'
import Foundation
import CoreGraphics
func run() throws { let p = Process(); try p.run() }
let script = NSAppleScript(source: "")
let home = FileManager.default.homeDirectoryForCurrentUser
let center = DistributedNotificationCenter.default()
let note = NSUserNotification()
let xpc = NSXPCConnection(machServiceName: "a", options: [])
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
let trusted = AXIsProcessTrusted()
let host = Host.current().name
// Process() and NSAppleScript in a comment
let text = "Host.current() in a string"
let info = ProcessInfo.processInfo
SWIFT
cat >"$CA/Sources/Guarded/Guarded.swift" <<'SWIFT'
#if os(macOS)
import Foundation
let p = Process()
let host = Host.current()
#endif
SWIFT
cat >"$CA/Sources/UI/App.swift" <<'SWIFT'
import SwiftUI
struct Docs: App { var body: some Scene { DocumentGroup(newDocument: Doc()) { _ in Text("") } } }
struct Open: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View { Table(rows) { TableColumn("Name", value: \.name) } }
}
SWIFT
git -C "$CA" init -q
cascan="$("$SCRIPTS/porting.sh" scan "$CA" 2>&1)"
for row in '3	Process' '4	AppleScript' '5	home folder of the user' '6	distributed notifications' '7	NSUserNotification' '8	XPC to a Mach service' '9	Core Graphics window' '10	accessibility automation' '11	Host'; do
  n="${row%%	*}"; what="${row#*	}"
  expect_result "porting: $what blocks iOS, with its line (checked by a real iOS build)" 0 "blocks	Sources/Tools	Sources/Tools/Tools\.swift:$n	$what" "exit=0
$cascan"
done
expect_result "porting: ... not in comments, strings or ProcessInfo" 0 'Tools' "exit=0
$cascan" 'Tools\.swift:(12|13|14)	'
expect_result "porting: Process and Host inside #if os(macOS) are guarded" 0 'guarded	Sources/Guarded	Sources/Guarded/Guarded\.swift:3	Process' "exit=0
$cascan" 'blocks	Sources/Guarded'
expect_result "porting: DocumentGroup is an adaptation" 0 'adapt	Sources/UI	Sources/UI/App\.swift:2	document app' "exit=0
$cascan"
expect_result "porting: openWindow is an adaptation" 0 'adapt	Sources/UI	Sources/UI/App\.swift:4	several windows' "exit=0
$cascan"
expect_result "porting: Table is an adaptation" 0 'adapt	Sources/UI	Sources/UI/App\.swift:5	Table \(one column' "exit=0
$cascan"

# ---------- porting: Xcode projects (#171) ----------

XP="$TMP/xc-project"
mkdir -p "$XP/App.xcodeproj" "$XP/App" "$XP/Shared"
echo '// pbx' >"$XP/App.xcodeproj/project.pbxproj"
echo 'import SwiftUI' >"$XP/App/App.swift"
echo 'secret' >"$XP/Secrets.xcconfig"
echo 'key' >"$XP/AuthKey_1.p8"
printf 'machine x login y password z\n' >"$XP/.netrc"
ln -s ../../outside-shared.swift "$XP/Shared/Linked.swift"
ln -s ../nowhere.swift "$XP/Shared/Broken.swift"
echo 'let shared = 1' >"$TMP/outside-shared.swift"
git -C "$XP" init -q
cat >"$BF/xcodebuild" <<'FAKE'
#!/bin/bash
# fake xcodebuild for Xcode projects: -list -json, and build/test per scheme from FAKE_XC_SCHEMES
# ("Name:pass Name:fail Name:noios").
echo "xcodebuild $*" >>"$FAKE_SWIFT_LOG"
ls -a "$PWD" | tr '\n' ' ' >>"$FAKE_SWIFT_LOG"; echo >>"$FAKE_SWIFT_LOG"
[ -f "$PWD/Shared/Linked.swift" ] && [ ! -L "$PWD/Shared/Linked.swift" ] && echo "linked file copied" >>"$FAKE_SWIFT_LOG"
case "$*" in
  "-list -json"*)
    names="$(for x in ${FAKE_XC_SCHEMES:-}; do printf '"%s",' "${x%%:*}"; done)"
    printf '{"project": {"name": "App", "schemes": [%s], "targets": ["App"]}}\n' "${names%,}"; exit 0 ;;
esac
scheme=""; bundle=""
while [ $# -gt 0 ]; do
  [ "$1" = -scheme ] && scheme="$2"
  [ "$1" = -resultBundlePath ] && bundle="$2"
  shift
done
case " ${FAKE_XC_SCHEMES:-} " in
  *" $scheme:pass "*) [ -z "$bundle" ] || mkdir -p "$bundle"; echo "** BUILD SUCCEEDED **"; exit 0 ;;
  *" $scheme:noios "*) echo "xcodebuild: error: Unable to find a destination matching the provided destination specifier:"; exit 70 ;;
  *" $scheme:fail "*)
    printf '%s/App/App.swift:3:8: error: Unable to resolve module dependency: '"'"'AppKit'"'"'\n' "${PWD#/private}"
    echo "** BUILD FAILED **"; exit 65 ;;
esac
echo "xcodebuild: error: The project does not contain a scheme named $scheme."; exit 66
FAKE
chmod +x "$BF/xcodebuild"
xbefore="$(snapshot "$XP")"
: >"$TMP/bc-swift.log"
out="$(FAKE_XC_SCHEMES="App:pass MacTool:noios Broken:fail" bc "$XP")"
expect_result "build-check: an Xcode project builds every scheme xcodebuild lists" 1 '- PASS App' "$out"
expect_result "build-check: a scheme with no iOS destination is NOT iOS, not a failure" 1 '- NOT iOS MacTool: the scheme has no iOS destination yet' "$out"
expect_result "build-check: a failing scheme shows its first error, with a path inside the project" 1 '- FAIL Broken: 1 error\(s\)' "$out"
expect_result "build-check: ... even when xcodebuild drops /private from the copy's path" 1 '^    App/App\.swift:3:8: Unable to resolve module dependency' "$out" 'swift-harness-port'
expect_result "build-check: the Xcode summary counts the three kinds" 1 '1 built, 1 failed, 1 with no iOS destination\. This is a build only' "$out"
expect_result "build-check: a broken link is named and the rest is copied" 1 'Note: not copied \(the build sees the rest\): .*Shared/Broken\.swift' "$out"
expect_result "build-check: only NOT iOS and PASS exit 0" 0 '- NOT iOS MacTool' "$(FAKE_XC_SCHEMES="App:pass MacTool:noios" bc "$XP")"
if grep -q -- "-project App.xcodeproj -scheme App -destination generic/platform=iOS Simulator .*CODE_SIGNING_ALLOWED=NO" "$TMP/bc-swift.log"; then ok "build-check: each scheme builds for the generic iOS Simulator, without signing"
else nok "build-check: each scheme builds for the generic iOS Simulator, without signing" "$(grep xcodebuild "$TMP/bc-swift.log")"; fi
if ! grep -qE '(^| )(\.git|Secrets\.xcconfig|AuthKey_1\.p8|\.netrc)( |$)' "$TMP/bc-swift.log" && grep -q 'App.xcodeproj' "$TMP/bc-swift.log"; then ok "build-check: the Xcode copy keeps the project, without .git or secrets"
else nok "build-check: the Xcode copy keeps the project, without .git or secrets" "$(grep App.xcodeproj "$TMP/bc-swift.log" | head -2)"; fi
if grep -q 'linked file copied' "$TMP/bc-swift.log"; then ok "build-check: a link to a file outside the project is copied as a file"
else nok "build-check: a link to a file outside the project is copied as a file"; fi
if [ "$xbefore" = "$(snapshot "$XP")" ]; then ok "build-check: the Xcode project is unchanged"; else nok "build-check: the Xcode project is unchanged"; fi
: >"$TMP/bc-swift.log"
out="$(FAKE_XC_SCHEMES="App:pass MacTool:noios" bc "$XP" --scheme App)"
if [ "$(grep -c -- '-scheme ' "$TMP/bc-swift.log")" = 1 ] && ! grep -q -- '-list' "$TMP/bc-swift.log"; then ok "build-check: --scheme builds only that scheme"
else nok "build-check: --scheme builds only that scheme" "$(grep xcodebuild "$TMP/bc-swift.log")"; fi
expect_result "build-check: --target is for packages, not Xcode projects" 2 '--scheme' "$(bc "$XP" --target App)"
expect_result "build-check: an Xcode project with no scheme says so" 1 'no scheme found in App\.xcodeproj' "$(FAKE_XC_SCHEMES="" bc "$XP")"
mkdir -p "$XP/Other.xcodeproj"
expect_result "build-check: several projects ask for --project" 1 'several Xcode workspaces or projects .*App\.xcodeproj, Other\.xcodeproj.*--project' "$(FAKE_XC_SCHEMES="App:pass" bc "$XP")"
expect_result "build-check: --project picks one" 0 '- PASS App' "$(FAKE_XC_SCHEMES="App:pass" bc "$XP" --project App.xcodeproj)"
expect_result "build-check: --project outside the root is a usage error" 2 'usage' "$(bc "$XP" --project ../x.xcodeproj)"
mkdir -p "$XP/App.xcworkspace"
: >"$TMP/bc-swift.log"
FAKE_XC_SCHEMES="App:pass" bc "$XP" --scheme App >/dev/null
if grep -q -- '-workspace App.xcworkspace -scheme App' "$TMP/bc-swift.log"; then ok "build-check: a workspace is preferred to its projects"
else nok "build-check: a workspace is preferred to its projects" "$(grep xcodebuild "$TMP/bc-swift.log")"; fi
rm -rf "$XP/App.xcworkspace" "$XP/Other.xcodeproj"
expect_result "build-check: no Package.swift and no Xcode project says so" 1 'no Package\.swift and no Xcode project' "$(bc "$BN")"

# test-check on an Xcode project: the fakes of test-check, with the scheme named.
cp "$BF/xcodebuild" "$TF/xcodebuild-xc"
xtc() { local out code; out="$(PATH="$TF:$PATH" TMPDIR="$TMP/tc-tmp" FAKE_SIMS="$TMP/tc-sims.json" FAKE_TC_LOG="$TMP/tc.log" FAKE_SWIFT_LOG="$TMP/tc.log" "$SCRIPTS/porting.sh" test-check "$@" 2>&1 </dev/null)"; code=$?; printf 'exit=%s\n%s' "$code" "$out"; }
mv "$TF/xcodebuild" "$TF/xcodebuild-pkg"; cp "$TF/xcodebuild-xc" "$TF/xcodebuild"
expect_result "test-check: an Xcode project needs the test scheme named" 1 'name the test scheme of App\.xcodeproj with --scheme' "$(xtc "$XP")"
: >"$TMP/tc.log"
out="$(FAKE_XC_SCHEMES="App:pass" FAKE_SUMMARY="$TMP/tc-pass.json" xtc "$XP" --scheme App)"
expect_result "test-check: an Xcode scheme's counts come from its result bundle" 0 'App\.xcodeproj.*Scheme App:.*12 test\(s\): 10 passed, 0 failed, 2 skipped' "exit=0
$(printf '%s' "$out" | tr '\n' ' ')"
if grep -q -- 'xcodebuild test -project App.xcodeproj -scheme App -destination platform=iOS Simulator,id=NEW-1 .*CODE_SIGNING_ALLOWED=NO' "$TMP/tc.log"; then ok "test-check: runs the scheme on the picked simulator, without signing"
else nok "test-check: runs the scheme on the picked simulator, without signing" "$(grep xcodebuild "$TMP/tc.log")"; fi
expect_result "test-check: a scheme with no iOS destination says so" 1 'not run: the scheme has no iOS destination yet' "$(FAKE_XC_SCHEMES="MacTool:noios" xtc "$XP" --scheme MacTool)"
mv "$TF/xcodebuild-pkg" "$TF/xcodebuild"; rm -f "$TF/xcodebuild-xc"

# ---------- from an external review of 1.10.0 ----------

# guard-bash: with SIGPIPE ignored, as on CI runners, stopping at the first protected path must
# not leave a writer on a closed pipe.
GP="$(new_project guard-pipe)"
jq '.guardBash = true | .protectedPaths = (["Sources/Audio/"] + [range(0; 400) | "Sources/Gen\(.)/"])' "$GP/.claude/swift-harness.json" >"$GP/cfg.tmp" && mv "$GP/cfg.tmp" "$GP/.claude/swift-harness.json"
gperr="$( (trap '' PIPE; hook guard-bash.sh "$GP" "$(bash_input 'echo x > Sources/Audio/Engine.swift')" 2>&1 >/dev/null) )"
if [ -z "$gperr" ]; then ok "guard-bash: no write error on a closed pipe when SIGPIPE is ignored"
else nok "guard-bash: no write error on a closed pipe when SIGPIPE is ignored" "$gperr"; fi
out="$(hook guard-bash.sh "$GP" "$(bash_input 'echo x > Sources/Gen399/A.swift')")"
expect_result "guard-bash: the last of many protected paths still asks" 0 'Sources/Gen399.*protected' "exit=0
$out"

# rules: a link to the verify command holds only once the command is approved.
RV="$TMP/rules-verify"
mkdir -p "$RV/.claude" "$RV/scripts" "$RV/docs"
git -C "$RV" init -q
printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast"},"protectedPaths":["Sources/Core/"]}' >"$RV/.claude/swift-harness.json"
printf '#!/bin/bash\nexit 0\n' >"$RV/scripts/verify.sh"; chmod +x "$RV/scripts/verify.sh"
echo '{}' >"$RV/docs/architecture-contracts.json"
printf '# App\n## Non-negotiable rules\n- The build passes. <!-- check: verify -->\n- Modules keep their layers. <!-- check: architecture contracts -->\n- Core is protected. <!-- check: guard -->\n' >"$RV/CLAUDE.md"
git -C "$RV" add -A && git -C "$RV" -c user.email=t@e.c -c user.name=t commit -qm init
rv() { local o c; o="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/rules.sh" --project "$RV" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
out="$(rv)"
expect_result "rules: a verify link does not hold while the command is not approved" 0 'verify: off, the verify command is not approved yet' "$out"
expect_result "rules: ... nor do the architecture contracts, which run with it" 0 'architecture contracts: off, the verify command is not approved yet.*they run only with the verify command' "$out"
approve "$RV" >/dev/null
out="$(rv)"
expect_result "rules: once approved, both links hold" 0 '3 rule\(s\): 3 name a check' "$out" 'Links to fix'
expect_result "rules: it says what a link that holds means" 0 'not that it catches every case of the rule' "$out"
out="$(env -u CLAUDE_PLUGIN_DATA "$SCRIPTS/rules.sh" --project "$RV" --json 2>&1)"
if jq -e '[.rules[].links[] | select(.check == "verify")][0] | .status == "ok" and (.why | test("could not be told here"))' <<<"$out" >/dev/null; then ok "rules: without the plugin's data folder it says the approval could not be told"
else nok "rules: without the plugin's data folder it says the approval could not be told" "$out"; fi

# ---------- verify.watch: build inputs beyond Swift (#177) ----------

WT="$(new_project watch)"
mkdir -p "$WT/engine/crates/ffi/src" "$WT/engine/target" "$WT/engine/vendor/core/src" "$WT/apple"
echo 'fn a() {}' >"$WT/engine/crates/ffi/src/lib.rs"
echo '[package]' >"$WT/engine/Cargo.toml"
echo 'name: X' >"$WT/apple/project.yml"
echo 'target/' >"$WT/.gitignore"
git -C "$WT/engine/vendor/core" init -q
echo 'fn c() {}' >"$WT/engine/vendor/core/src/c.rs"
git -C "$WT/engine/vendor/core" add -A && git -C "$WT/engine/vendor/core" -c user.email=t@e.c -c user.name=t commit -qm core
git -C "$WT" add -A 2>/dev/null; git -C "$WT" commit -qm engine
wchanges() { # $1 name, $2 "same" or "changes", $3 command that edits the project
  local a b
  a="$(fingerprint "$WT")"; eval "$3"; b="$(fingerprint "$WT")"
  if { [ "$2" = changes ] && [ "$a" != "$b" ]; } || { [ "$2" = same ] && [ "$a" = "$b" ]; }; then ok "$1"; else nok "$1"; fi
}
wchanges "watch: without verify.watch a Rust change is not a build input" same 'echo "// x" >>"$WT/engine/crates/ffi/src/lib.rs"'
wchanges "watch: an XcodeGen project.yml is a build input with no setting" changes 'echo "x: 1" >>"$WT/apple/project.yml"'
wchanges "watch: a Podfile is a build input with no setting" changes 'echo "pod 1" >"$WT/Podfile"'
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":["engine/",":!engine/crates/ffi/gen/","../outside/","/etc/"]},"protectedPaths":["Sources/Audio/"]}'
approve "$WT" >/dev/null
wchanges "watch: a Rust change under a watched folder is seen" changes 'echo "// y" >>"$WT/engine/crates/ffi/src/lib.rs"'
wchanges "watch: a file git ignores under it is not" same 'echo junk >"$WT/engine/target/out.o"'
wchanges "watch: a change inside a nested repository under it is seen" changes 'echo "// z" >>"$WT/engine/vendor/core/src/c.rs"'
wchanges "watch: a folder left out with :! is not seen" same 'mkdir -p "$WT/engine/crates/ffi/gen"; echo g >"$WT/engine/crates/ffi/gen/g.rs"'
if [ "$(jq -nc --arg cwd "$WT" '{cwd: $cwd}' | bash -c '. "$0"; sh_init && sh_watch | paste -sd" " -' "$SCRIPTS/lib.sh")" = "engine/ :!engine/crates/ffi/gen/" ]; then ok "watch: entries that leave the project are dropped"
else nok "watch: entries that leave the project are dropped"; fi
if CLAUDE_PLUGIN_DATA="$TMP/data" bash -c '. "$0" </dev/null; SH_INPUT="{\"cwd\":\"$1\"}"; SH_ROOT="$(sh_root)"; SH_CONFIG="$SH_ROOT/.claude/swift-harness.json"; sh_verify_approved "scripts/verify.sh fast" "$(sh_state_path)"' "$SCRIPTS/lib.sh" "$WT"; then ok "watch: changing watched code does not ask for a new verify approval"
else nok "watch: changing watched code does not ask for a new verify approval"; fi
# The end of the turn: a change to watched Rust code alone runs the verify command.
git -C "$WT" add -A 2>/dev/null; git -C "$WT" commit -qm watched
hook session-start.sh "$WT" '{"source":"startup"}' >/dev/null
WLOG="$TMP/watch-verify.log"; : >"$WLOG"
echo '// end of turn' >>"$WT/engine/crates/ffi/src/lib.rs"
FAKE_VERIFY_LOG="$WLOG" hook stop-verify.sh "$WT" >/dev/null 2>&1
if [ "$(wc -l <"$WLOG" | tr -d ' ')" = 1 ]; then ok "stop: a change to watched Rust code alone runs the verify command"
else nok "stop: a change to watched Rust code alone runs the verify command" "$(cat "$WLOG")"; fi
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$WT" 2>&1)"
expect_result "doctor: watch entries that leave the project are named" 0 'WARN \| Other build systems \| verify\.watch entries not used .*\.\./outside/, /etc/' "exit=0
$out"
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":["engine/",":!engine/crates/ffi/gen/"]},"protectedPaths":["Sources/Audio/"]}'
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$WT" 2>&1)"
expect_result "doctor: watched code of another build system passes" 0 'PASS \| Other build systems \| verify\.watch: engine/' "exit=0
$out"
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast"},"protectedPaths":["Sources/Audio/"]}'
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$WT" 2>&1)"
expect_result "doctor: a Cargo.toml nothing watches is a warning with the entry to add" 0 'WARN \| Other build systems \| engine/Cargo\.toml \(Rust\).*"watch": \["engine/"\]' "exit=0
$out"
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":"engine"}}'
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$WT" 2>&1)"
expect_result "doctor: verify.watch must be a list" 0 'verify\.watch must be a list of paths' "exit=0
$out"

# ---------- simulator lock (#74) ----------

SL="$SCRIPTS/simulator-lock.sh"
expect_result "simulator lock: free when nothing runs" 0 '^free$' "exit=0
$("$SL" status)"
"$SL" run --name "a long UI test run" -- sleep 6 &
slpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SWIFT_HARNESS_LOCK_DIR/simulator.lock/holder" ] && break; sleep 0.2; done
expect_result "simulator lock: status names the run that holds it" 0 '^busy: a long UI test run \(pid [0-9]+\)' "exit=0
$("$SL" status)"
out="$("$SL" run -- echo second 2>&1)"; code=$?
expect_result "simulator lock: a second run does not start, and says who holds the lock" 75 'busy: a long UI test run .*Nothing ran' "exit=$code
$out" '^second$'
: >"$TMP/tc.log"
out="$(FAKE_SUMMARY="$TMP/tc-pass.json" tcrun "$TC" --target CoreTests)"
expect_result "test-check: with the simulator busy it exits 3 and runs nothing" 3 'the simulator is busy: a long UI test run' "$out"
if ! grep -q 'xcodebuild' "$TMP/tc.log"; then ok "test-check: ... xcodebuild was not started"; else nok "test-check: ... xcodebuild was not started" "$(cat "$TMP/tc.log")"; fi
out="$("$SL" run --wait 30 -- echo waited 2>&1)"; code=$?
expect_result "simulator lock: --wait runs once the lock is free" 0 '^waited$' "exit=$code
$out"
wait "$slpid" 2>/dev/null
"$SL" run -- sh -c 'exit 7'
expect_result "simulator lock: the exit code is the command's" 7 '' "exit=$?"
mkdir -p "$SWIFT_HARNESS_LOCK_DIR/simulator.lock"; printf '999999\n1\na run that died\n' >"$SWIFT_HARNESS_LOCK_DIR/simulator.lock/holder"
expect_result "simulator lock: a lock whose process is gone is taken over" 0 '^took it$' "exit=0
$("$SL" run -- echo "took it" 2>&1)"
out="$(FAKE_SUMMARY="$TMP/tc-pass.json" tcrun "$TC" --target CoreTests)"
expect_result "test-check: it takes the lock and gives it back" 0 '10 passed' "$out"
expect_result "simulator lock: free again after test-check" 0 '^free$' "exit=0
$("$SL" status)"
expect_result "simulator lock: a missing command is a usage error" 2 'usage' "exit=$("$SL" run -- >/dev/null 2>&1; echo $?)
$("$SL" run 2>&1)"
expect_result "test-check: --wait needs a number" 2 'usage' "$(tcrun "$TC" --wait soon)"

# ---------- a project in a subfolder of the repository (monorepo) ----------

MR="$TMP/monorepo"
mkdir -p "$MR/apple/.claude" "$MR/apple/Sources/Core" "$MR/apple/scripts" "$MR/backend"
git -C "$MR" init -q; git -C "$MR" config user.email t@e.c; git -C "$MR" config user.name t
printf '%s\n' '{"verify":{"command":"scripts/verify.sh fast","maxAttempts":3},"protectedPaths":["Sources/Core/"]}' >"$MR/apple/.claude/swift-harness.json"
printf '#!/bin/bash\necho run >>"${FAKE_VERIFY_LOG:-/dev/null}"\nexit "${FAKE_VERIFY_EXIT:-0}"\n' >"$MR/apple/scripts/verify.sh"; chmod +x "$MR/apple/scripts/verify.sh"
echo 'let core = 1' >"$MR/apple/Sources/Core/Core.swift"
echo 'package main' >"$MR/backend/main.go"
git -C "$MR" add -A && git -C "$MR" commit -qm init
mroot() { jq -nc --arg cwd "$1" '{cwd: $cwd}' | CLAUDE_PROJECT_DIR="$2" bash -c '. "$0"; sh_init && printf "%s" "$SH_ROOT"' "$SCRIPTS/lib.sh"; }
if [ "$(mroot "$MR/apple" "$MR/apple")" = "$MR/apple" ]; then ok "monorepo: a session in the app's subfolder finds its config"
else nok "monorepo: a session in the app's subfolder finds its config" "$(mroot "$MR/apple" "$MR/apple")"; fi
if [ "$(mroot "$MR/apple/Sources/Core" "$MR/apple")" = "$MR/apple" ]; then ok "monorepo: ... from a folder below it too"
else nok "monorepo: ... from a folder below it too"; fi
if [ "$(mroot "$MR/backend" "$MR/apple")" = "$MR/apple" ]; then ok "monorepo: ... and when the cwd moved to a sibling folder of the same checkout"
else nok "monorepo: ... and when the cwd moved to a sibling folder of the same checkout" "$(mroot "$MR/backend" "$MR/apple")"; fi
mhook() { local extra="${3:-}"; [ -n "$extra" ] || extra='{}'; jq -nc --arg cwd "$2" --argjson extra "$extra" '{cwd: $cwd, session_id: "mono"} + $extra' | CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$MR/apple" "$SCRIPTS/$1"; }
if mhook guard.sh "$MR/apple" "$(edit_input "$MR/apple/Sources/Core/Core.swift")" | grep -q '"permissionDecision": "ask"'; then ok "monorepo: the guard asks for a protected path of the subfolder project"
else nok "monorepo: the guard asks for a protected path of the subfolder project"; fi
approve "$MR/apple" >/dev/null
mhook session-start.sh "$MR/apple" '{"source":"startup"}' >/dev/null
MLOG="$TMP/mono-verify.log"; : >"$MLOG"
echo 'let more = 2' >>"$MR/apple/Sources/Core/Core.swift"
FAKE_VERIFY_LOG="$MLOG" mhook stop-verify.sh "$MR/apple" >/dev/null 2>&1
if [ "$(wc -l <"$MLOG" | tr -d ' ')" = 1 ]; then ok "monorepo: the end-of-turn check runs for the subfolder project"
else nok "monorepo: the end-of-turn check runs for the subfolder project" "runs: $(cat "$MLOG")"; fi
echo 'package main // changed' >"$MR/backend/main.go"
FAKE_VERIFY_LOG="$MLOG" mhook stop-verify.sh "$MR/apple" >/dev/null 2>&1
if [ "$(wc -l <"$MLOG" | tr -d ' ')" = 1 ]; then ok "monorepo: a change outside the subfolder does not run it again"
else nok "monorepo: a change outside the subfolder does not run it again" "runs: $(wc -l <"$MLOG")"; fi
out="$(jq -nc --arg cwd "$MR" '{cwd: $cwd, session_id: "top", source: "startup"}' | CLAUDE_PLUGIN_DATA="$TMP/data" CLAUDE_PROJECT_DIR="$MR" "$SCRIPTS/session-start.sh" 2>&1)"
expect_result "monorepo: a session started above the project is told no check runs, and where the plugin is" 0 'no check runs here.*set up in: apple' "exit=0
$out"

# ---------- porting: audio on iOS (#75) ----------

AA="$TMP/audio-app"
mkdir -p "$AA/Sources/Player" "$AA/Sources/Devices" "$AA/App"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "X", targets: [])\n' >"$AA/Package.swift"
cat >"$AA/Sources/Player/Engine.swift" <<'SWIFT'
import AVFoundation
final class Engine {
  let engine = AVAudioEngine()
  // AVAudioSession.sharedInstance().setCategory(.playback) in a comment
  let note = "MPRemoteCommandCenter in a string"
}
SWIFT
cat >"$AA/Sources/Devices/Output.swift" <<'SWIFT'
#if os(macOS)
import CoreAudio
import AVFoundation
final class Output {
  let unit = AVAudioUnitEQ()
  var hog = kAudioDevicePropertyHogMode
  var rate = kAudioDevicePropertyNominalSampleRate
}
#endif
SWIFT
git -C "$AA" init -q
aud() { local o c; o="$("$SCRIPTS/porting.sh" audio "$AA" 2>&1)"; c=$?; printf 'exit=%s\n%s' "$c" "$o"; }
out="$(aud)"
expect_result "audio: names the audio code iOS compiles" 0 'Audio code iOS compiles: 1 file\(s\) \(Sources/Player/Engine\.swift:3\)' "$out"
expect_result "audio: names the audio code only the Mac compiles" 0 'only the Mac compiles \(behind #if\): 1 file\(s\) \(Sources/Devices/Output\.swift:5\)' "$out"
expect_result "audio: with no session code every item is not found" 0 'audio session category \(AVAudioSession setCategory\): not found' "$out"
expect_result "audio: comments and strings are not code" 0 'remote commands.*: not found' "$out"
expect_result "audio: background audio is not found without UIBackgroundModes" 0 'background audio .*: not found' "$out"
expect_result "audio: hog mode is named as having no iOS equivalent" 0 'exclusive device access \(hog mode\): Sources/Devices/Output\.swift:6' "$out"
expect_result "audio: so is the device sample rate" 0 'device sample rate .*: Sources/Devices/Output\.swift:7' "$out"
expect_result "audio: it says what found does not prove" 0 'proved only on a simulator or a device' "$out"
cat >"$AA/Sources/Player/Session.swift" <<'SWIFT'
#if os(iOS)
import AVFoundation
import MediaPlayer
final class Session {
  func start() throws {
    let s = AVAudioSession.sharedInstance()
    try s.setCategory(.playback)
    try s.setActive(true)
    NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: s)
    NotificationCenter.default.addObserver(self, selector: #selector(route), name: AVAudioSession.routeChangeNotification, object: s)
    MPRemoteCommandCenter.shared().playCommand.isEnabled = true
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [:]
  }
}
#endif
SWIFT
printf '<plist><dict>\n<key>UIBackgroundModes</key>\n<array>\n<string>audio</string>\n</array>\n</dict></plist>\n' >"$AA/App/Info.plist"
out="$(aud)"
expect_result "audio: the session category is found with its line" 0 'audio session category \(AVAudioSession setCategory\): Sources/Player/Session\.swift:7' "$out"
expect_result "audio: activation, interruptions and route changes too" 0 'session activation \(setActive\): Sources/Player/Session\.swift:8' "$out"
expect_result "audio: ... interruptions" 0 'interruptionNotification\): Sources/Player/Session\.swift:9' "$out"
expect_result "audio: ... route changes" 0 'routeChangeNotification\): Sources/Player/Session\.swift:10' "$out"
expect_result "audio: remote commands and Now Playing" 0 'MPRemoteCommandCenter\): Sources/Player/Session\.swift:11' "$out"
expect_result "audio: background audio is read from the Info.plist" 0 'background audio .*: App/Info\.plist:4' "$out"
expect_result "audio: an item still missing stays not found" 0 'media services reset .*: not found' "$out"
if ! "$SCRIPTS/porting.sh" scan "$AA" | grep -q '^bg	'; then ok "audio: its lines stay out of the scan"; else nok "audio: its lines stay out of the scan"; fi
expect_result "audio: a project with no audio code says so" 0 'no audio playback, recording or audio unit API found' "exit=0
$("$SCRIPTS/porting.sh" audio "$CA" 2>&1)"

# ---------- from a second external review (1.11.0) ----------

# The nearest config wins over one at the top of the repository.
printf '%s\n' '{"verify":{"enabled":false},"protectedPaths":["docs/"]}' >"$MR/.claude-top.json"; mkdir -p "$MR/.claude"; mv "$MR/.claude-top.json" "$MR/.claude/swift-harness.json"
if [ "$(mroot "$MR/apple" "$MR/apple")" = "$MR/apple" ]; then ok "monorepo: with a config at the top too, the app's own config wins inside the app"
else nok "monorepo: with a config at the top too, the app's own config wins inside the app" "$(mroot "$MR/apple" "$MR/apple")"; fi
if [ "$(mroot "$MR/backend" "$MR")" = "$MR" ]; then ok "monorepo: ... and the top config is used outside the app"
else nok "monorepo: ... and the top config is used outside the app" "$(mroot "$MR/backend" "$MR")"; fi
if mhook guard.sh "$MR/apple" "$(edit_input "$MR/apple/Sources/Core/Core.swift")" | grep -q '"permissionDecision": "ask"'; then ok "monorepo: the app's protected path is still guarded with a config at the top"
else nok "monorepo: the app's protected path is still guarded with a config at the top"; fi
rm -rf "$MR/.claude"
# check.sh finds a project in a subfolder as the hooks do.
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" FAKE_VERIFY_LOG=/dev/null "$SCRIPTS/check.sh" --project "$MR/apple" 2>&1)"; code=$?
expect_result "check.sh: a project in a subfolder of its repository is found" "$code" '' "exit=$code
$out" 'no \.claude/swift-harness\.json'
expect_result "check.sh: with no config up to the top of the repository it says where it looked" 2 'no \.claude/swift-harness\.json in .*backend or above it' "exit=$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$MR/backend" >/dev/null 2>&1; echo $?)
$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/check.sh" --project "$MR/backend" 2>&1)"

# Guest mode in a subfolder: the excludes and the Codex launcher carry the subfolder.
GM="$TMP/guest-mono"
mkdir -p "$GM/App/Sources"
git -C "$GM" init -q; git -C "$GM" config user.email t@e.c; git -C "$GM" config user.name t
echo 'let a = 1' >"$GM/App/Sources/A.swift"; git -C "$GM" add -A; git -C "$GM" commit -qm init
CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/setup-guest.sh" --project "$GM/App" --fast "swift build" --full "swift test" --local --codex >/dev/null 2>&1
if [ -z "$(git -C "$GM" status --porcelain)" ]; then ok "guest: --local in a subfolder keeps its files out of git"
else nok "guest: --local in a subfolder keeps its files out of git" "$(git -C "$GM" status --porcelain)"; fi
if jq -r '.hooks.SessionStart[0].hooks[0].command' "$GM/App/.codex/hooks.json" 2>/dev/null | grep -q 'show-toplevel)/App/\.codex/swift-harness-hook\.sh'; then ok "guest: the Codex launcher of a subfolder project points into the subfolder"
else nok "guest: the Codex launcher of a subfolder project points into the subfolder" "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$GM/App/.codex/hooks.json" 2>&1)"; fi

# verify.watch: an entry git does not accept does not switch change detection off.
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":[":(glob","engine/"]},"protectedPaths":["Sources/Audio/"]}'
wchanges "watch: with a malformed entry, a Swift change is still seen" changes 'echo "let w = 9" >>"$WT/Sources/App.swift"'
wchanges "watch: ... and so is a change under the entries that are valid" changes 'echo "// w" >>"$WT/engine/crates/ffi/src/lib.rs"'
out="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/doctor.sh" "$WT" 2>&1)"
expect_result "doctor: a verify.watch entry that is not a pathspec is named" 0 'WARN \| Other build systems \| verify\.watch entries not used .*:\(glob' "exit=0
$out"
# A glob with folders reaches into a nested repository.
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":["engine/*/*/src/*.rs"]},"protectedPaths":["Sources/Audio/"]}'
wchanges "watch: a glob with folders reaches a file of a nested repository" changes 'echo "// g" >>"$WT/engine/vendor/core/src/c.rs"'
set_config "$WT" '{"verify":{"command":"scripts/verify.sh fast","watch":["other/*/*.rs"]},"protectedPaths":["Sources/Audio/"]}'
wchanges "watch: ... and a glob for another folder does not" same 'echo "// h" >>"$WT/engine/vendor/core/src/c.rs"'

# Untracked files are hashed in batches: the result is the same, a new one is seen.
UT="$(new_project untracked-many)"
mkdir -p "$UT/Sources/Gen"
for i in 1 2 3 4 5 6 7 8 9 10; do echo "let g$i = $i" >"$UT/Sources/Gen/G $i.swift"; done
a="$(fingerprint "$UT")"; b="$(fingerprint "$UT")"
if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "fingerprint: untracked files, names with spaces included, hash the same twice"; else nok "fingerprint: untracked files, names with spaces included, hash the same twice"; fi
echo 'let g = 0' >>"$UT/Sources/Gen/G 7.swift"
if [ "$a" != "$(fingerprint "$UT")" ]; then ok "fingerprint: a change to one untracked file is seen"; else nok "fingerprint: a change to one untracked file is seen"; fi

# SwiftLint with another reporter in its config: the hook asks for the one it reads.
LR="$(new_project lint-reporter)"
set_config "$LR" '{"format":"none","lint":"swiftlint"}'
LRF="$TMP/lint-reporter-fakes"; mkdir -p "$LRF"
cat >"$LRF/swiftlint" <<'FAKE'
#!/bin/bash
# fake swiftlint whose config picks the json reporter: xcode lines only with --reporter xcode
file="${!#}"
case " $* " in
  *" --reporter xcode "*) printf '%s:1:5: warning: Force Cast Violation: Force casts should be avoided (force_cast)\n' "$file" ;;
  *) printf '[{"rule_id":"force_cast","severity":"Warning","file":"%s","line":1}]\n' "$file" ;;
esac
FAKE
chmod +x "$LRF/swiftlint"
out="$(PATH="$LRF:$PATH" hook post-edit.sh "$LR" "$(edit_input "$LR/Sources/App.swift")" 2>&1)"
expect_result "post-edit: warnings are read whatever reporter the SwiftLint config picks" 0 'SwiftLint: 1 issue\(s\) in Sources/App\.swift' "exit=0
$out" 'no issues'

# Architecture contracts: a dump with no targets is a failure to read, not a pass.
CF="$TMP/contracts-fakes"; mkdir -p "$CF"
printf '#!/bin/bash\necho "{\\"name\\": \\"X\\"}"\n' >"$CF/swift"; chmod +x "$CF/swift"
CP="$TMP/contracts-nodump"; mkdir -p "$CP/docs"
printf '// swift-tools-version: 6.0\n' >"$CP/Package.swift"
printf '%s\n' '{"version":1,"packages":{".":{"App":[]}}}' >"$CP/docs/architecture-contracts.json"
out="$(PATH="$CF:$PATH" "$SCRIPTS/contracts.sh" "$CP" 2>&1)"; code=$?
expect_result "contracts: a dump with no list of targets fails, saying nothing was checked" 1 'gave no list of targets, so its dependencies were not checked' "exit=$code
$out"

# Security settings turned off with approval: the record says not run, not passed.
SO="$(new_project security-off)"
hook session-start.sh "$SO" '{"source":"startup"}' >/dev/null
set_config "$SO" '{"verify":{"command":"scripts/verify.sh fast"},"security":{"enabled":false}}'
sdig="$(CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/security.sh" --status --project "$SO" 2>/dev/null | sed -n 's/^Digest: *//p')"
CLAUDE_PLUGIN_DATA="$TMP/data" "$SCRIPTS/security.sh" --approve "$sdig" --project "$SO" >/dev/null 2>&1
approve "$SO" >/dev/null
echo 'let s = 2' >>"$SO/Sources/App.swift"
FAKE_VERIFY_LOG=/dev/null hook stop-verify.sh "$SO" >/dev/null 2>&1
sev="$(find "$TMP/data/state" -name evidence.json -newer "$SO/Sources/App.swift" 2>/dev/null | head -1)"
if [ -n "$sev" ] && jq -e '[.checks[]? | select(.name == "security settings")][0] | .result == "not run" and (.detail | test("approved by the user"))' "$sev" >/dev/null 2>&1; then ok "stop: security turned off with approval is recorded as not run, not passed"
else nok "stop: security turned off with approval is recorded as not run, not passed" "$( [ -n "$sev" ] && jq -c '[.checks[]? | select(.name == "security settings")]' "$sev")"; fi

# No git repository: the session is told the end-of-turn check does not run.
NG="$TMP/no-git"; mkdir -p "$NG/.claude" "$NG/Sources"
printf '%s\n' '{"verify":{"enabled":false}}' >"$NG/.claude/swift-harness.json"
out="$(hook session-start.sh "$NG" '{"source":"startup"}' 2>&1)"
expect_result "session start: without a git repository it says the end-of-turn check does not run" 0 'is not a git repository, so the end-of-turn check .* does not run' "exit=0
$out"

# ---------- summary ----------

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
