---
name: approve-snapshots
description: Look at the new snapshot images left by failing visual regression tests and approve them as baselines. Only the user runs this; tests never write baselines, and Claude must not copy images into the baselines folder.
disable-model-invocation: true
argument-hint: "[image name ...]"
---

# Approve snapshot baselines

The project's snapshot tests (`tests/Snapshot.swift` from the setup templates) compare each rendered component or screen with an approved image in the baselines folder (`snapshots.path` in `.claude/swift-harness.json`, default `snapshots/`). A missing or different image fails the test and waits in `.build/swift-harness/snapshots/`: the new image, a diff with the changed pixels in red, and its metadata. Nothing replaces a baseline until the user approves it here.

The user asked for this by typing the command. Do not run these scripts at any other time, and never on your own initiative.

## 1. List what waits

Run from the project root:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --status
```

If the output says that metadata files hold an absolute path, tell the user: a `Snapshot.swift` older than 1.12.0 wrote the test file as this Mac sees it, account name included, into the `.json` beside each baseline, and the baselines folder is committed. With their agreement, make the paths relative. Only that field changes, no check reads it, and the images stay the same:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --relative-paths
```

Then say two things: commits already made keep the old path in their history, and `tests/Snapshot.swift` and `tests/Screenshot.swift` should be updated from the setup templates, so that new images are written with a relative path from the start (an approval makes the path relative in any case).

If nothing waits, say so: the snapshot tests have to run first (`scripts/verify.sh full`, or the test target that holds them), and stop.

## 2. Show each image

For each image listed, open the new image and, when there is one, the diff (`Changes in red:`) and the baseline, and tell the user in one or two lines what changed: where (the region the test reported), and what it looks like (a moved label, a new color, text that now wraps). Say which change in this session most likely caused it. Flag anything that looks like a defect rather than an intended change: clipped or overlapping text, wrong colors in dark mode, a layout that is not mirrored for a right-to-left locale.

For a `not-compared` image, say that approving it moves the baseline to this Mac's macOS version and scale: from then on the comparison runs here, and the Mac it ran on before reports it as not compared.

## 3. Approve

Ask the user which images to approve (all, some, or none), unless the arguments (`$ARGUMENTS`) already name them. Then pass the `Digest:` value from step 1, and the names when not all of them:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --approve <digest> [name ...]
```

If it reports that the images changed since step 1, a test ran again: list them again and start from step 2. Never copy, edit or delete files in the baselines folder yourself to make a test pass.

End with one line: the approved images are now the baselines, to commit with the change that made them; the rest still fail until they are fixed or approved.
