---
name: configure
description: Guided configuration of swift-harness for this project - a few questions (how strict, when the checks run, snapshots, approvals, where the app is going, docs, recaps) written into .claude/swift-harness.json. Only the user runs this.
disable-model-invocation: true
---

# Configure swift-harness

A few questions, each answer written into `.claude/swift-harness.json` as the keys it stands for, by `configure.sh`. Every other key stays as it is. The project must be set up first (`/swift-harness:setup`).

The user asked for this by typing the command. Do not run `configure.sh --apply` at any other time, and never on your own initiative.

## 1. Read the current answers

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/configure.sh" --show
```

It prints one `question: answer` line per question. If it says there is no config, tell the user to run `/swift-harness:setup` first, and stop.

## 2. Ask

Ask with the question tool, in three rounds of three questions (one round per group below). For each question put the current answer first, marked `(current)`, and keep the descriptions to one line on what the choice does in daily work. Do not ask anything else.

Round 1, how the checks stop the work:

- **strictness**: `light` (a failing check is reported, the turn is never blocked), `normal` (a failing check blocks the end of the turn, up to 3 times), `strict` (up to 5 times, and SwiftLint errors in an edited file block too).
- **stop**: `turn` (the checks run at the end of each turn that changed code), `commit` (nothing runs at the end of a turn; a commit made by the agent is refused until the checks pass on its code).
- **snapshots**: `fail` (a new or changed image fails its test at once), `collect` (it waits; one approval before the commit, and `scripts/verify.sh full` fails while any waits).

Round 2, approvals and visual tolerance:

- **approvals**: `weakening` (an approval command asks only when something weakens a check), `always` (it asks every time).
- **moves**: `approve` (a security setting moved to another file, as in a rename, waits for an approval that asks nothing), `pass` (a move is no change).
- **tolerance**: `0` (any changed pixel counts), `0.001` (up to 0.1% of the pixels may differ: antialiasing noise), `0.01` (1%: only large changes count). The user may type another number from 0 up to 1.

Round 3, the project:

- **direction**: `mac` (a Mac app), `ios-planned` (an iPhone or iPad version is planned), `porting` (a port is under way: modules that already build for iOS must keep building).
- **docs**: `blocking` (a reference broken in the docs blocks the end of the turn), `observed` (it is reported, never blocking), `off`.
- **recap**: `off` (the user hears about the checks only when something failed or was not checked), `text` (one line at the end of each turn with every check and its result), `md` or `html` (the same line, and the recap kept as a file in `.build/swift-harness/`).

## 3. Write

Pass only the answers that differ from step 1:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/configure.sh" --apply question=choice ...
```

If nothing differs, say that the configuration already matches, and stop.

## 4. Say what follows

Show the lines it printed under `Written to`, then each line under `To know` in your own words, briefly. Some answers need one more step by the user, which you name and do not run:

- `moves=pass` weakens the security check: it fails the end of the turn until they approve it with `/swift-harness:approve-security`.
- `snapshots=collect`: if `scripts/verify.sh` was made from an older template, update it from the setup template and approve it again (`/swift-harness:approve-verify`).
- `stop=commit`: their own commits are not stopped; a git pre-commit hook that runs the `check.sh` path it printed checks them too.
- `direction=porting` with no ratchet: recording the modules already ported needs their yes (`porting.sh ratchet --record`).

End with one line: `/swift-harness:configure` again changes any answer, and `/swift-harness:doctor` shows the whole setup.
