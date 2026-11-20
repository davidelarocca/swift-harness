---
name: approve
description: Review and approve everything that waits for the user in one go - the verify command, the security settings and new snapshot images. Only the user runs this; Claude must not approve its own changes.
disable-model-invocation: true
argument-hint: "[all]"
---

# Approve everything that waits

Three things wait for the user's approval, each with its own command: the verify command (`/swift-harness:approve-verify`), the security settings (`/swift-harness:approve-security`) and new snapshot images (`/swift-harness:approve-snapshots`). One change, a rename for example, can leave more than one waiting. This command lists them together and approves them in one pass, with the same rules as the three commands, which stay for approving one kind alone.

The user asked for this by typing the command. Do not run these scripts at any other time, and never on your own initiative.

## 1. List what waits

Run all three from the project root:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/approve-verify.sh" --status
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/security.sh" --status
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --status
```

Leave out what does not wait: a verify status that is `approved`, security with no change and nothing to review, snapshots with no new images. If nothing waits, say so in one line and stop.

## 2. Show each group once

For each group that waits, follow step 2 of its own command, in a few lines:

- **Verify command**: as `/swift-harness:approve-verify` step 2. With `Changes since the last approval`, look only at those lines, and flag only what the added lines bring.
- **Security settings**: as `/swift-harness:approve-security` step 2. Moves are one line per file; explain each real `+` or `-` line.
- **Snapshots**: open the review page the status names (`open "<the path of the review page>"`), as `/swift-harness:approve-snapshots` step 2, and write at most one line per component.

## 3. One question at most

Collect what needs the user's decision:

- a flag in the verify files that was not in the approved version;
- the security status ending with `To decide: ...`;
- the snapshot images, unless the argument (`$ARGUMENTS`) is `all`; with `all`, only an image that looks like a defect.

If nothing needs a decision, approve everything in this turn. Otherwise ask one question that names each point, and offer to approve the rest. Then approve, each with the `Digest:` from its status in step 1:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/approve-verify.sh" --approve <digest>
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/security.sh" --approve <digest>
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --approve <digest> [name ...]
```

If one reports that something changed since step 1, list that group again and start it from step 2; the others stand. Never edit the files, the settings or the baselines to make an approval go through.

End with one line per group: what is approved now, and what still waits.
