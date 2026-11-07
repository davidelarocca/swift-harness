---
name: approve-performance
description: Look at the new numbers left by performance budget tests (a missing baseline, a regression, a gain, or another machine) and approve them as baselines. Only the user runs this; tests never write baselines, and Claude must not write the baselines folder.
disable-model-invocation: true
argument-hint: "[name ...]"
---

# Approve performance baselines

The project's budget tests (`tests/PerformanceBudget.swift` from the setup templates) measure key operations in instructions retired and compare each with an approved baseline in the baselines folder (`performance.path` in `.claude/swift-harness.json`, default `performance/`). A missing baseline or a count over the tolerance fails; a gain or numbers from another machine pass. In each case the new numbers wait in `.build/swift-harness/performance/`. Nothing replaces a baseline until the user approves it here.

The user asked for this by typing the command. Do not run these scripts at any other time, and never on your own initiative.

## 1. List what waits

Run from the project root:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/performance.sh" --status
```

If nothing waits, say so: the budget tests have to run first (`scripts/verify.sh fast` for a package test target), and stop.

## 2. Explain each one

For each name, give the new numbers and the baseline in one or two lines, and what the status means:
- `missing`: a first baseline. Say what the operation measures and on which data.
- `failed`: the operation got slower by the percentage shown. Say which change in this session most likely caused it. Approving accepts the extra work as the new budget: recommend it only when that work is intended (a feature that does more), never to make the test pass.
- `faster`: approving keeps the gain, so a later change cannot give it back unnoticed.
- `not-compared`: the baseline was made on another architecture, macOS version or build configuration. Approving moves the baseline to this Mac: from then on the comparison runs here, and the machine it ran on before reports it as not compared.

## 3. Approve

Ask the user which to approve (all, some, or none), unless the arguments (`$ARGUMENTS`) already name them. Then pass the `Digest:` value from step 1, and the names when not all of them:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/performance.sh" --approve <digest> [name ...]
```

If it reports that the numbers changed since step 1, a test ran again: list them again and start from step 2. Never write, edit or delete files in the baselines folder yourself to make a test pass.

End with one line: the approved numbers are now the baselines, to commit with the change that made them; the rest still fail until they are fixed or approved.
