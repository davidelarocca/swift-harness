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

## 2. Show the images

The output of step 1 ends with `Review page, to open for the user ...` and a path. Open that page for the user before asking anything:

```bash
open "<the path of the review page>"
```

The page shows what waits: a table of the components, then for each one the image that changed most, with the approved image, the new one and the changed pixels in red side by side, and its other sizes and appearances folded under it. The user decides on what they see there, not on a description, so do not narrate every image. Look at the new images yourself (and the diff and the baseline where there are any) and write a few lines, one per component at most:

- first, anything that needs their eyes: what looks like a defect rather than an intended change (clipped or overlapping text, wrong colors in dark mode, a layout that is not mirrored for a right-to-left locale), and any change you cannot tie to an edit of this session;
- then the rest together: which edit caused it and how many images it accounts for ("the new padding of the badge: 6 images, as expected").

If the output says no review page could be written, give the user the image paths it lists instead.

For a `not-compared` image, say that approving it moves the baseline to this Mac's macOS version and scale: from then on the comparison runs here, and the Mac it ran on before reports it as not compared.

## 3. Approve

Ask the user which images to approve (all, some, or none), unless the arguments (`$ARGUMENTS`) already name them. Say in one line what the answer means: an approved image is how the component must look from now on, and the tests compare with it; one that is not approved stays a failure for you to fix. Then pass the `Digest:` value from step 1, and the names when not all of them:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/snapshots.sh" --approve <digest> [name ...]
```

If it reports that the images changed since step 1, a test ran again: list them again and start from step 2. Never copy, edit or delete files in the baselines folder yourself to make a test pass.

End with one line: the approved images are now the baselines, to commit with the change that made them; the rest still fail until they are fixed or approved.
