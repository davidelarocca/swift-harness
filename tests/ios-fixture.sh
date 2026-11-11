#!/bin/bash
# The generated scripts/verify.sh and doctor on a package for macOS and iOS, with real Xcode (#40).
#
#   tests/ios-fixture.sh          fast mode on macOS and iOS (builds only: no simulator needed)
#   tests/ios-fixture.sh --full   also full mode: iOS tests on a simulator, plus a negative control
#                                 that fails on iOS only, to prove the iOS tests really run
#
# Works on a copy of tests/fixtures/ios. Needs Xcode with the iOS SDK, git and jq.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN="$HERE/../plugins/swift-harness"
TEMPLATE="$PLUGIN/skills/setup/templates/verify.sh"
FULL=false
[ "${1:-}" = "--full" ] && FULL=true

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
nok() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' | tail -25
}
# $1 name, $2 expected exit code, $3 regex that must match, $4 actual exit code, $5 output
expect() {
  if [ "$4" = "$2" ] && grep -qE -- "$3" <<<"$5"; then ok "$1"; else nok "$1" "exit=$4
$5"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/app"
cp -R "$HERE/fixtures/ios" "$APP"
rm -rf "$APP/.build"
git -C "$APP" init -q
mkdir -p "$APP/scripts" "$APP/.claude"
printf '%s\n' '{"format":"none","lint":"none","verify":{"command":"scripts/verify.sh fast"}}' >"$APP/.claude/swift-harness.json"

# The simulator, picked the way setup does: the first iPhone that is available.
SIM="$(xcrun simctl list devices available -j 2>/dev/null |
  jq -r '[.devices[][] | select(.name | startswith("iPhone")) | .name][0] // empty')"
printf 'Xcode: %s\niPhone simulator: %s\n\n' "$(xcodebuild -version | head -1)" "${SIM:-none}"

generate() { # $1 scheme, $2 packages (array body), $3 platforms (array body)
  sed -e 's/{{XCODE_CONTAINER_FLAG}}//' -e "s/{{SCHEME}}/$1/" -e "s|{{LOCAL_PACKAGES}}|$2|" \
    -e "s/{{PLATFORMS}}/$3/" -e "s/{{IOS_SIMULATOR}}/$SIM/" "$TEMPLATE" >"$APP/scripts/verify.sh"
  chmod +x "$APP/scripts/verify.sh"
}
verify() { # $1 mode; prints the output, sets $code
  out="$(cd "$APP" && "${@:2}" scripts/verify.sh "$1" 2>&1)"
  code=$?
}

generate Kit '' '"macOS" "iOS"'
verify fast
expect "fast: the scheme builds for macOS and for iOS" 0 'verify fast: PASS \(2 build/test check\(s\); platforms: macOS, iOS\)' "$code" "$out"

# An error that exists only in the iOS build.
printf '#if os(iOS)\nlet broken: Int = "only on iOS"\n#endif\n' >"$APP/Sources/Kit/IOSOnly.swift"
verify fast
expect "fast: an error only in the iOS build fails on iOS" 1 'verify fast: FAIL \(failed on: iOS\)' "$code" "$out"
# The real result bundle (#147), on this machine's Xcode: the error with its file and line.
expect "fast: the error is read from the iOS result bundle" 1 'results from the result bundle \(\.build/swift-harness/results/build-iOS\.xcresult\)' "$code" "$out"
expect "fast: ... with its file and line" 1 'error: Sources/Kit/IOSOnly\.swift:2: ' "$code" "$out"
rm "$APP/Sources/Kit/IOSOnly.swift"

generate '' '"."' '"macOS" "iOS"'
verify fast
expect "fast: packages only, with iOS listed, is PARTIAL" 0 'verify fast: PARTIAL \(passed on macOS; not checked on iOS' "$code" "$out"

generate Kit '' '"macOS" "iOS"'
out="$(CLAUDE_PLUGIN_DATA="$WORK/data" "$PLUGIN/scripts/doctor.sh" "$APP" 2>&1)"
expect "doctor: Package.swift platforms are all verified" 0 '^\| PASS \| Platforms \| macOS, iOS' 0 "$out"
if [ -n "$SIM" ]; then
  expect "doctor: the simulator exists" 0 "^\\| PASS \\| iOS simulator \\| '$SIM' is available" 0 "$out"
fi

if [ "$FULL" = true ]; then
  if [ -z "$SIM" ]; then
    nok "full: no available iPhone simulator on this machine"
  else
    verify full
    expect "full: tests pass on macOS and on the $SIM simulator" 0 'verify full: PASS \(2 build/test check\(s\).*platforms: macOS, iOS\)' "$code" "$out"
    verify full env TEST_RUNNER_SH_FAIL_ON_IOS=1
    expect "full: the negative control fails on iOS only" 1 'verify full: FAIL \(failed on: iOS\)' "$code" "$out"
    expect "full: the failure is the negative control test" 1 'negative control' "$code" "$out"
    expect "full: the failed test and its message come from the iOS result bundle" 1 'results from the result bundle \(\.build/swift-harness/results/test-iOS\.xcresult\)' "$code" "$out"
    expect "full: ... one line for the failed test, with its message" 1 'failed test: .*negative control' "$code" "$out"
  fi
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
