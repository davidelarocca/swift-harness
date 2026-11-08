---
name: report
description: Show what swift-harness caught in this project: blocks at the end of a turn, lint and registry reports, questions before protected edits, approvals, and the checks that did not run. From the local catch log; nothing leaves the machine. Only the user runs this.
disable-model-invocation: true
argument-hint: "[days | YYYY-MM-DD | all] [html]"
---

# Report

The hooks keep a local log of what they caught and how it ended (`catches.jsonl` in the plugin data folder, per project). The user asked for this by typing the command; do not run it at any other time.

## 1. Run

From the project root. With a number in the arguments (`$ARGUMENTS`) use `--days <n>`, with a date `--since <date>`, with `all` use `--all`; without arguments the last 7 days:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh" --project . [--days <n> | --since <date> | --all]
```

With `html` in the arguments, add `--html`: it writes `.build/swift-harness/report.html` (a static page, no script, no network) and prints its path. Give the user the path to open; do not open it yourself.

## 2. Report

Show the output as printed. Then, in two or three lines:
- what the blocks were about, and whether they ended fixed or left failing;
- the checks that did not run, and the one thing that would turn each on (approve the verify command, install SwiftLint, fix the registry's table);
- that the log counts what the hooks saw, not what they prevented: a block fixed in the same turn is still a block.

Do not change the project, the config or the log.
