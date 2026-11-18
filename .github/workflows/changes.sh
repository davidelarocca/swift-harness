#!/bin/bash
# Which macOS jobs a CI run needs, as "name=true|false" lines for $GITHUB_OUTPUT.
#
#   changes.sh EVENT DRAFT [FILE...]
#
# EVENT is github.event_name, DRAFT github.event.pull_request.draft. The changed files are the
# arguments, or else `git diff --name-only HEAD^1 HEAD` (on a pull request HEAD is the merge
# commit). workflow_dispatch runs everything; a push to main and a draft pull request run no
# macOS job. When a job starts to depend on more files, widen its pattern here and add a case
# to tests/ci-changes.sh.
set -uo pipefail

event="${1:-}"
draft="${2:-false}"
shift 2 2>/dev/null || shift $#

all() { for k in code swift ios mutate; do printf '%s=%s\n' "$k" "$1"; done; }
case "$event" in
  workflow_dispatch) all true; exit 0 ;;
  pull_request) [ "$draft" != true ] || { all false; exit 0; } ;;
  *) all false; exit 0 ;;
esac

if [ $# -gt 0 ]; then files="$(printf '%s\n' "$@")"
else files="$(git diff --name-only HEAD^1 HEAD)" || { all true; exit 0; }; fi
printf 'changed files:\n%s\n' "$files" >&2

# grep on a here-string, not a pipe: with pipefail a pipe into grep -q can fail the writer.
has() { if grep -qE "$1" <<<"$files"; then echo true; else echo false; fi; }
ci='^\.github/workflows/'
tpl='^plugins/swift-harness/skills/(setup/templates|design-system/references)/'
lib='^plugins/swift-harness/scripts/lib\.sh$'

# Hook tests: any plugin, test or manifest file. Root docs (README, CHANGELOG, ROADMAP, docs/)
# are not read by tests/run.sh.
printf 'code=%s\n' "$(has "^(plugins|tests|\.claude-plugin)/|$ci")"
# Swift fixtures, accessibility and layout audit: the fixtures and the helpers they link.
printf 'swift=%s\n' "$(has "^tests/fixtures/|$tpl|$ci")"
# iOS fixture: the generated verify.sh on a package, and the doctor.
printf 'ios=%s\n' "$(has "^tests/(ios-fixture\.sh|fixtures/ios/)|^plugins/swift-harness/scripts/(verify|doctor)\.sh$|$lib|$tpl|$ci")"
# Check sensitivity: mutate.sh with real builds of the fixtures.
printf 'mutate=%s\n' "$(has "^tests/(mutate-fixture\.sh|fixtures/)|^plugins/swift-harness/scripts/(mutate|snapshots|verify)\.sh$|$lib|$tpl|$ci")"
