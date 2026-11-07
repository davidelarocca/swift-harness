---
name: check-sensitivity
description: Measure whether the project's checks notice defects. Plants one defect at a time in a temporary copy of the project (a renamed registry entry or layout view, a stale docs link, a relaxed entitlement, a forbidden dependency; with --verify also a hardcoded padding, a removed keyboard shortcut or accessibility label, a view wider than its minimum, a changed padding) and reports which check caught each one. Only the user runs this.
disable-model-invocation: true
argument-hint: "[--verify] [operator ...]"
---

# Check sensitivity

A check can pass for the wrong reason. This runs the project's checks against planted defects, one at a time, to show which ones each check would catch. It works on a copy under `.build/swift-harness/`, removed at the end: the project is never changed.

The user asked for this by typing the command. Do not run it at any other time. It evaluates `Package.swift` through `swift package dump-package` (the architecture contracts check), which runs code from the repository; with `--verify` it also runs `scripts/verify.sh full`, which builds and tests it.

## 1. Run

From the project root, with `--verify` if the arguments (`$ARGUMENTS`) have it, and one `--only <operator>` per operator they name (none for all):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --project . [--verify] [--only <operator>]...
```

`"${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --list` names the operators and the check each one targets.

Without `--verify`, only the checks that read files run (seconds). With it, the checks inside the project's tests and SwiftLint run too: one `scripts/verify.sh full` without mutations and one per operator, a full build and test run each. Before a long run, tell the user how many runs that is.

## 2. Report

Show the table as printed. Then, in a few lines:
- `Without mutations`: a check that already fails still counts, but only problems it did not report before kill a mutation. Name the checks that could not run.
- `killed`: the check it targets noticed the defect. Other checks in the last column noticed it too.
- `no site`: the project has nothing for that operator to change (no registry, no layout contract, no entitlements, no architecture contract, no local link in the docs; for the verify operators: no padding with a token, no keyboard shortcut, no accessibility label, no snapshot test). Say what is missing, and that the check it feeds is not in use.
- `not run`: a verify operator without `--verify`, or `scripts/verify.sh` missing or not configured.
- `verify` in the last column: verify failed, but on no check's test and no SwiftLint rule. Often the mutation did not build: say so, it is not a finding about the checks.
- `SURVIVED`: a finding. Read the check's input and the site, and say why it went through: a bug in the check, a setting that turns it off (`security.enabled`, a file outside `docs.paths`, a file the SwiftLint rule excludes), or a defect out of its scope by design. Do not change the project or the checks to make it pass unless the user asks.
