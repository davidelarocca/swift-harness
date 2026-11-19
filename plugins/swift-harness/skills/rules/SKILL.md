---
name: rules
description: List the project's agent rules by whether a check enforces them. Reads the rule lines of CLAUDE.md, AGENTS.md and .claude/rules/, the <!-- check: NAME --> link at the end of each, and says which links hold, which name a check that is off or does not exist, and which rules nothing checks. Read-only. Only the user runs this.
disable-model-invocation: true
argument-hint: "[all]"
---

# Rules and the checks that enforce them

The user asked for this by typing the command; do not run it at any other time. It reads files and changes none.

## 1. Run

From the project root. With `all` in the arguments (`$ARGUMENTS`) add `--all`, which also lists the rules nothing checks:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/rules.sh" --project . [--all]
```

## 2. Report

Show the output as printed. Say once what a link that holds means: its check exists and is turned on. It is not a proof that the check catches every case of the rule; `/swift-harness:check-sensitivity` measures that. Then, in a few lines:
- the links that do not hold, each with the one fix: turn the check on, or correct the name in the rule's `<!-- check: NAME -->` comment;
- how a link is written, once, if the project has none yet: at the end of a rule's line, `<!-- check: guard -->` for an engine check (`guard`, `protected paths`, `shell guard`, `security settings`, `snapshot baselines`, `performance baselines`, `architecture contracts`, `docs references`, `component registry`, `weakened checks`, `verify`) or `<!-- check: lint ds_hardcoded_padding -->` for a SwiftLint rule; the same names are in `/swift-harness:report`'s log, so it can count what each rule's check caught;
- that a rule nothing checks is a hope, not a promise: say which ones a check could enforce, and do not add the link yourself unless the user asks.

Do not rewrite the rule files. The output is a list for the user; `/swift-harness:report` adds, per linked rule, how often its check caught something in the period.
