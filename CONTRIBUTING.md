# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome. For questions and ideas, [Discussions](https://github.com/davidelarocca/swift-harness/discussions) is the right place; for bugs, open an [issue](https://github.com/davidelarocca/swift-harness/issues/new/choose). Security problems go through [private reporting](SECURITY.md).

## What to work on

The [roadmap](ROADMAP.md) and the [milestones](https://github.com/davidelarocca/swift-harness/milestones) list what is planned. Issues labelled `good first issue` are small and well defined. For anything larger, comment on the issue first so we can agree on the approach before you write code.

## Try your changes

```bash
claude --plugin-dir ./plugins/swift-harness     # load this checkout instead of the installed plugin
```

## Tests

Every change to a hook, template or hook message needs a test that fails before the change and passes after it.

| Command | What it checks | Needs |
|---|---|---|
| `tests/run.sh` | Hook scripts and the `verify.sh` template, with fake tools | bash, git, jq |
| `swift build --build-tests` in `tests/fixtures/design-system` | The Swift reference files compile | Xcode |
| `tests/format-helpers.sh` | The real formatters leave the template helpers as shipped | swiftformat, Xcode |
| `tests/smoke/run.sh` | The hooks inside real Claude Code sessions | Claude Code (logged in), Xcode, SwiftLint; about $1 |

CI runs ShellCheck, JSON validation and `claude plugin validate` on every pull request, and the macOS jobs (`tests/run.sh`, the Swift fixtures, the iOS fixture, check sensitivity) only when the pull request changes files they read: see [CI minutes](#ci-minutes). Run the smoke test before opening a pull request that changes hooks, hook messages or templates, and paste its summary in the description. See [tests/smoke/README.md](tests/smoke/README.md).

## Rules for the hooks

- macOS ships bash 3.2: no associative arrays, no `${var^^}`, and empty arrays need `${arr[@]+"${arr[@]}"}` under `set -u`. CI runs the tests with `/bin/bash` to catch this.
- A hook must never report success for a check it did not run. Skipped, failed and passed are different states.
- Hooks stay no-ops in repositories without `.claude/swift-harness.json`.
- Messages to Claude are short, say what happened and what to do next, and do not contradict each other.

## Pull requests

- Small and focused: one fix or feature per pull request.
- Update `CHANGELOG.md`, and `README.md` and `README.it.md` together when behaviour changes. Update `ROADMAP.md` when an item ships or changes.
- Commit messages use a type prefix: `fix:`, `feat:`, `test:`, `docs:`, `ci:`.
- Releases bump `version` in `plugins/swift-harness/.claude-plugin/plugin.json` and are tagged `swift-harness--vX.Y.Z` after CI is green, including a full run on `main` (Actions > CI > Run workflow, or `gh workflow run CI --ref main`).

## CI minutes

A macOS minute costs ten times a Linux one, and one full CI run is about 38 macOS minutes. The repository is public, so they are free here, but not on a private fork, and they are never free in time. So:

- A pull request runs only the macOS jobs its changed files need. `.github/workflows/changes.sh` decides, and `tests/ci-changes.sh` tests it. When you add a fixture, a job, or a file a job reads, widen the pattern there and add a case to the test. A job skipped this way counts as passed for the required checks, so a pattern that is too narrow lets a change through untested.
- A draft pull request runs no macOS job. Open it as a draft while it still changes, and mark it ready when it is done: that runs the macOS jobs once.
- Push fixes together, not one push per fix: every push starts a new run, and the one it cancels has already used its minutes.
- A push to `main` runs the Linux jobs only, because the pull request already ran the rest. Before a release, run the full workflow on `main` by hand.
- Prefer a new step in an existing macOS job to a new job: each job pays for its own machine start.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE), and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
