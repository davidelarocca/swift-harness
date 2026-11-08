---
name: approve-verify
description: Approve this project's verify command so the swift-harness end-of-turn check can run it. Only the user runs this; the check runs nothing from the repository until it is approved, and asks again whenever the command or a file it runs changes.
disable-model-invocation: true
argument-hint: "[revoke]"
---

# Approve the verify command

The Stop hook runs `verify.command` from `.claude/swift-harness.json`, a file the repository controls. It runs only after the user approves the exact command and the files it names. The approval is stored outside the repository, in the plugin data folder, for this project path. Another git worktree of the same repository with the identical command and files inherits it; the status says so ("inherited from the … worktree"). Revoking removes it for the other worktrees too.

The user asked for this by typing the command. Do not run these scripts at any other time, and never on your own initiative.

## 1. Show what would be approved

Run from the project root:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/approve-verify.sh" --status
```

Show the output to the user as it is: project, command, each file and input with its hash, status. If there is a `Warning:` line, repeat it in your own words: the approval may not cover the scripts the command runs, and listing them in `verify.inputs` fixes that.

If the user passed `revoke` as the argument (`$ARGUMENTS`), run the same script with `--revoke` instead, show the output, and stop.

If an `Input:` line says it is outside the project, tell the user the approval will be refused until that entry is removed from `verify.inputs`: an approval cannot cover a file the repository does not contain.

If the status is already `approved`, say so and stop. If it is `approved, partial coverage`, say what that means (the scripts the command runs may change without a new approval) and that listing them in `verify.inputs` and approving again makes the coverage complete.

## 2. Point out what deserves a look

Read each file listed under `File:` and tell the user in two or three lines what it runs (for the generated `scripts/verify.sh`: `swift test` and `xcodebuild build`). Flag anything that does more than build, test or lint: network access, `curl`, `sudo`, deleting files outside the project, writing outside the project, or reading credentials. Also mention any script the command calls without naming it in the command line, since that is not covered by the approval.

Approving means trusting the project's build: `xcodebuild` runs the project's Run Script phases and SwiftPM runs package manifests and plugins.

## 3. Approve

If you flagged something, ask the user to confirm before approving. Otherwise approve right away, passing the `Digest:` value from step 1:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/approve-verify.sh" --approve <digest>
```

If it reports that something changed since step 1, show the new status and start again from step 2. Never edit the command or its files to make an approval go through.

End with one line: the check now runs this command at the end of each turn that changes code, and asks again if the command or one of its files changes.
