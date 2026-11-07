---
name: drift
description: Measure the project's drift, now or over a range of commits. Counts hardcoded design values against tokens, new components that look like registered ones, and the problems the registry, layout, docs and contracts checks report, and adds them up into one score per commit. Only the user runs this.
disable-model-invocation: true
argument-hint: "[<git range>]"
---

# Drift

How coherent the project is, measured the same way at every commit. The user asked for this by typing the command; do not run it at any other time. With an architecture contract, it evaluates `Package.swift` (`swift package dump-package`) once per commit measured: code from the repository.

## 1. Run

From the project root. Without arguments, the working tree:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/drift.sh" score --project .
```

With a git range in the arguments (`$ARGUMENTS`, for example `main~30..main`), one line per commit, oldest first:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/drift.sh" history <range> --project .
```

Each commit is extracted and measured on its own, so a long range takes a while: before running more than about 50 commits, say how many there are.

## 2. Report

Show the output as printed, then in a few lines:
- The score is the number of things to fix: literal uses (padding, spacing, radius, font size, colors made from components), near-duplicates and check problems. Lower is better. Its direction over commits matters more than its value.
- `tokens` is the share of design values that go through a token. Name the kinds whose literal values grew, and the values (from `score`).
- A near-duplicate is a guess from the name: `StatusPill` has the role of the registered `Pill`. Ask the user to confirm it before proposing to reuse the registered component or register the new one.
- Over a range, name the commits where the score jumped or dropped, and what moved.

Do not change the code to lower the score unless the user asks.
