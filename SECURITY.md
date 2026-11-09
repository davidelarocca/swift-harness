# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: use **[Report a vulnerability](https://github.com/davidelarocca/swift-harness/security/advisories/new)** in this repository's Security tab.

Include the plugin version, your Claude Code and macOS versions, and the smallest `.claude/swift-harness.json` or repository layout that reproduces the problem. The maintainer aims to reply within a week. Fixes are released as a patch version and credited in the CHANGELOG unless you prefer otherwise.

## Supported versions

Only the latest release receives fixes.

## Trust model

swift-harness runs local commands on your machine through Claude Code hooks. Know what it does before you enable it:

| What runs | When | Where it comes from |
|---|---|---|
| `jq`, `git`, `shasum` | Every hook | Your system |
| The plugin's `registry.sh`, which reads the component registry and Swift files as text | Before Claude ends a turn and after it edits a Swift file, when the registry exists. Runs nothing from the repository, so no approval | The plugin |
| `swiftformat` or `swift-format`, `swiftlint` | After Claude edits a Swift file | Your system |
| `verify.command` (default `scripts/verify.sh fast`) | Before Claude ends a turn, when build inputs changed, **and only after you approved it** | **The repository**: `.claude/swift-harness.json` and the script it points to |
| `swift package dump-package`, which runs `Package.swift` | With `verify.command`, and after Claude edits a `Package.swift`, when `docs/architecture-contracts.json` exists, **only while the verify command is approved** | **The repository**: the package manifests named in the contract |

The hooks do nothing in a repository that has no `.claude/swift-harness.json`.

**Repository commands need your approval.** `verify.command` comes from the repository, so the Stop hook runs it only after you approve it by typing `/swift-harness:approve-verify` ([#6](https://github.com/davidelarocca/swift-harness/issues/6), since 1.2.0). Until then it runs nothing from the repository, tells Claude at session start and tells you at the end of each turn that changed code.

- **What an approval covers:** the project path (physical, so each clone is approved separately), the exact command text, and the SHA-256 of every file inside the project that the command names, such as `scripts/verify.sh` or `scripts/check.sh` in `bash scripts/check.sh`. It also covers every file or folder listed in `verify.inputs` (a folder by the names and contents of all its files, and every link in it by its target and the content it points to). An input outside the project, or a folder with a link that resolves outside it, cannot be covered: the approval is refused until it is removed (1.3.1, SH130-03 and SH130-04). If any of them changes, or such a file appears or disappears, the command stops running until you approve again. The command is split on spaces, not parsed as shell: a path in quotes, such as `bash "scripts/my verify.sh"`, is not found. When the command has quotes or shell syntax and `verify.inputs` is empty, the status shows a warning and the approval as `approved, partial coverage`, in `/swift-harness:doctor` too; list the scripts it runs in `verify.inputs` (1.2.1 and 1.3.1, SH120-01 and SH130-02 of external audits).
- **Worktrees of one repository** (#107): an approval is also recorded, outside the repository, under the repository's git common directory, by a digest of the command and the file contents without the project path. Another worktree of that repository whose command and files are identical inherits it, and `/swift-harness:approve-verify` and `/swift-harness:doctor` say where it comes from. A changed file asks again. Another clone, with its own common directory, never inherits, even with identical files. Revoking in any worktree removes what the worktrees share.
- **Where it is stored:** in the plugin data folder (`~/.claude/plugins/data/…`), outside the repository. Nothing in the repository can approve itself, and there is no environment variable or setting that skips the approval, because a repository can set both through its own `.claude/settings.json`.
- **Only you approve.** The skill has `disable-model-invocation: true`, so Claude cannot start it, and the hooks tell Claude not to run the approval script. Claude can still run any shell command through Bash, including the approval script or `scripts/verify.sh` itself, subject to your Claude Code permission rules: the approval gates the hook, not Claude. The same holds for Codex: the hooks tell it not to run the approval script, and nothing else stops it apart from its own sandbox, which keeps a sandboxed agent out of the plugin data folder.

What the approval does **not** cover:

- Files the command reads without naming them: a `Makefile` behind `make verify`, a script that `verify.sh` runs or sources, a script named relative to another folder. Name the scripts you care about in `verify.command`, or keep the logic in `scripts/verify.sh`.
- The build itself. Approving the verify command means trusting the project's build: `xcodebuild` runs the project's Run Script phases, and SwiftPM runs package manifests and build plugins. These come from the repository and change without a new approval.
- Claude Code's own project configuration. A repository with hooks in its `.claude/settings.json` runs them once you trust the folder in Claude Code's trust dialog, with or without swift-harness. The approval removes the execution path that swift-harness adds; it does not make an untrusted repository safe to open.

**Upgrading from 1.1.x:** existing projects run no verification until you approve them once with `/swift-harness:approve-verify`. Claude is told at session start.

**Protected paths are not a sandbox.** `protectedPaths` and the `project.pbxproj` guard ask for approval before the Edit, Write and MultiEdit tools change a file. A shell command run through Bash can still change those files; swift-harness reports such a change to protected paths at the end of the turn, after it happened. For hard limits use Claude Code [permission rules](https://code.claude.com/docs/en/permissions) (`deny`) and, for untrusted code, an isolated environment.

**What the plugin's own scripts never do:** send data anywhere, install tools, or change files outside the project, except their own state in the plugin data folder.

This covers the hook scripts and the formatter and linter they call. It does not cover `verify.command`. Once you approve it, it runs with your user's permissions and can do anything you can, and that includes the generated `scripts/verify.sh`. `swift test` may download package dependencies, and SwiftPM and Xcode write caches outside the project (for example `~/Library/Caches/org.swift.swiftpm` and `~/Library/Developer/Xcode`). Approve only a command you have read, in a project you trust.
