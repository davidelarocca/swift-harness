---
name: check-sensitivity
description: Measure whether the project's checks notice defects. Plants one defect at a time in a temporary copy of the project (a renamed registry entry, a renamed layout view, a stale docs link, a relaxed entitlement, a forbidden dependency) and reports which check caught each one. Only the user runs this.
disable-model-invocation: true
argument-hint: "[operator ...]"
---

# Check sensitivity

A check can pass for the wrong reason. This runs the project's checks against planted defects, one at a time, to show which ones each check would catch. It works on a temporary copy: the project is never changed.

The user asked for this by typing the command. Do not run it at any other time. It evaluates `Package.swift` through `swift package dump-package` (the architecture contracts check), which runs code from the repository.

## 1. Run

From the project root, with one `--only <operator>` per operator named in the arguments (`$ARGUMENTS`), none for all:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --project . [--only <operator>]...
```

`"${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --list` names the operators and the check each one targets.

## 2. Report

Show the table as printed. Then, in a few lines:
- `Without mutations`: a check that already fails still counts, but only problems it did not report before kill a mutation. Name the checks that could not run.
- `killed`: the check it targets noticed the defect. Other checks in the last column noticed it too.
- `no site`: the project has nothing for that operator to change (no registry, no layout contract, no entitlements, no architecture contract, no local link in the docs). Say which document is missing, and that the check it feeds is not in use.
- `SURVIVED`: a finding. Read the check's input and the site, and say why it went through: a bug in the check, a setting that turns it off (`security.enabled`, a file outside `docs.paths`), or a defect out of its scope by design. Do not change the project or the checks to make it pass unless the user asks.
