#!/bin/bash
# Tests of .github/workflows/changes.sh: which macOS CI jobs a change needs. Run by CI (static).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
check() { # name, expected "code swift ios mutate", event, draft, files...
  local name="$1" want="$2" got; shift 2
  got="$(bash .github/workflows/changes.sh "$@" 2>/dev/null | cut -d= -f2 | paste -sd' ' -)"
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL  %s: want "%s", got "%s"\n' "$name" "$want" "$got"; fi
}
check "docs only: no macOS job" "false false false false" pull_request false README.md CHANGELOG.md docs/x.md ROADMAP.md
check "a skill's SKILL.md is plugin code" "true false false false" pull_request false plugins/swift-harness/skills/port-to-ios/SKILL.md
check "a script runs the hook tests only" "true false false false" pull_request false plugins/swift-harness/scripts/porting.sh tests/run.sh
check "verify.sh runs the iOS fixture and check sensitivity" "true false true true" pull_request false plugins/swift-harness/scripts/verify.sh
check "lib.sh is used by every script" "true false true true" pull_request false plugins/swift-harness/scripts/lib.sh
check "a template helper runs every fixture" "true true true true" pull_request false plugins/swift-harness/skills/setup/templates/tests/LayoutAudit.swift
check "the formatter check runs with the Swift fixtures" "true true false false" pull_request false tests/format-helpers.sh
check "a fixture runs the Swift jobs and check sensitivity" "true true false true" pull_request false tests/fixtures/accessibility/A.swift
check "the workflow itself runs everything" "true true true true" pull_request false .github/workflows/ci.yml
check "a draft runs no macOS job" "false false false false" pull_request true plugins/swift-harness/scripts/verify.sh
check "a push to main runs no macOS job" "false false false false" push false plugins/swift-harness/scripts/verify.sh
check "Run workflow runs everything" "true true true true" workflow_dispatch "" README.md
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
