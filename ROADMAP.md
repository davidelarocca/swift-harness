# Roadmap

Where swift-harness is going, and why. Live status is in the [milestones](https://github.com/davidelarocca/swift-harness/milestones) and [issues](https://github.com/davidelarocca/swift-harness/issues). This page is updated with every release.

_Last updated: 7 November 2026: v1.6.0 is now sessions, keyboard and performance; iOS porting moves to v1.7.0, waiting for a real port._

**Guiding principle:** every check the harness claims to run must actually run, and must be backed by a test. New features come after the existing gates are reliable, and claims about impact come with measurements.

## Now: v1.6.0, reliable sessions, keyboard and performance

| | What you get | Issue |
|---|---|---|
| 🧷 | **Per-session state.** Two sessions on one folder keep their own start lists, so one never hides the other's shell changes. Done, in Unreleased. | [#61](https://github.com/davidelarocca/swift-harness/issues/61) |
| ⌨️ | **Keyboard, focus order and Reduce Motion checks** for shared components: keys pressed in unit tests, the Tab order in UI tests, an overridable Reduce Motion in the design system. Done, in Unreleased. | [#52](https://github.com/davidelarocca/swift-harness/issues/52) |
| ⏱️ | **Performance budget.** Key operations measured against recorded baselines in the full check; a regression fails with the numbers. Later, a skill that explains slowness with a trace. | [#33](https://github.com/davidelarocca/swift-harness/issues/33) |
| 📐 | **Layout check from the accessibility tree** in UI tests: an element cut by the window edge, a text over another, on macOS and iOS. Done, in Unreleased. | [#69](https://github.com/davidelarocca/swift-harness/issues/69) |
| 🔗 | **Docs reference check.** Broken links, paths and section names in the project docs, and a size budget for what every session reads. | [#70](https://github.com/davidelarocca/swift-harness/issues/70) |

## Next: v1.7.0, assisted macOS to iOS porting

Waits for a real iOS port of a macOS app to check it on: the porting audit of 1.5.0 is there to start one.

| | What you get | Issue |
|---|---|---|
| 🍎➡️📱 | **Porting in verified slices.** After you accept the plan and the target structure: shared domain first, adapters for platform APIs, then one feature at a time, each built and tested on iOS and on the Mac, with results per platform. Checked on a real port. | [#48](https://github.com/davidelarocca/swift-harness/issues/48) |
| 📱 | **iOS checked on a real app.** The iOS-aware checks of 1.5.0 used on a real iOS port: the README says iOS once it passes. | [#40](https://github.com/davidelarocca/swift-harness/issues/40) |
| 🧳 | **Guest mode.** Run on a project that has its own rules and checks, without setup. | [#71](https://github.com/davidelarocca/swift-harness/issues/71) |
| 🧭 | **Branch scope contract.** Changes outside a branch's paths, and its drift from main, reported. | [#72](https://github.com/davidelarocca/swift-harness/issues/72) |
| 🔒 | **Porting ratchet.** New macOS-only API in a ported shared module fails. | [#73](https://github.com/davidelarocca/swift-harness/issues/73) |
| 🚦 | **Shared machine.** UI tests and simulators ask first, take a lock, build only what is ported. | [#74](https://github.com/davidelarocca/swift-harness/issues/74) |
| 🎧 | **Audio apps.** Audio session, interruptions and background audio in the porting audit. | [#75](https://github.com/davidelarocca/swift-harness/issues/75) |

## Later

| | What you get | Issue |
|---|---|---|
| 👀 | **UI review ritual.** Three window sizes, a gallery of states from UI tests, a keyboard-only pass. | [#67](https://github.com/davidelarocca/swift-harness/issues/67) |
| 🪤 | **Pitfalls and test isolation.** A pitfalls template, and UI tests that never touch the user's real data. | [#68](https://github.com/davidelarocca/swift-harness/issues/68) |
| 📊 | **v2.0.0: a measured harness.** Repeatable evals of Claude with and without swift-harness: reuse, regressions, build passes, cost. Published with method and raw data. | [#8](https://github.com/davidelarocca/swift-harness/issues/8) |

Ideas parked until there is demand: a local, read-only view of the checks with evidence behind every edge and status ([#50](https://github.com/davidelarocca/swift-harness/discussions/50)); persistence migrations, localization, approval across worktrees, docs drift ([#38](https://github.com/davidelarocca/swift-harness/discussions/38)).

## Shipped

| Version | Highlights |
|---|---|
| [1.5.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.5.0) | iOS-aware verify script, doctor and UI guidance (an iPhone simulator in CI), a read-only porting audit checked on a real app, a security settings contract approved only by you, a concurrency ratchet, shell changes to protected files reported, a checkpoint after compaction, an accessibility audit for UI tests. |
| [1.4.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.4.1) | Layout contract checked on a real app: content that takes any width (split views, lists, tables) no longer passes unmeasured; it fails with what to measure instead. |
| [1.4.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.4.0) | Visual coherence: a layout contract measured by the project's tests at every window size, screenshots for the design review, and visual regression against baselines only you approve (`/swift-harness:approve-snapshots`), pinned to one macOS version. |
| [1.3.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.3.1) | Fixes from an external audit: no "passed" without the verify command, inputs outside the project refused, links in watched folders covered, partial approval coverage shown, doctor reads package paths with spaces. |
| [1.3.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.3.0) | Architecture you can enforce: SwiftPM architecture contracts checked from the real dependency graph, a component registry checked against the code, `/swift-harness:product-map` for navigation and lifecycle gaps, security settings proposed as protected paths, and real-session tests for reuse and product coherence. |
| [1.2.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.2.1) | Fixes from an external audit: `verify.inputs` and a warning for verify commands with quotes, Xcode project paths with spaces, docs on re-verification after an update. |
| [1.2.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.2.0) | Trust and onboarding: the repository's verify command runs only after you approve it (`/swift-harness:approve-verify`), `/swift-harness:doctor` diagnoses the setup, and results are tied to the plugin version so an update re-verifies once. |
| [1.1.3](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.1.3) | Strict lint means strict: with `lintBlocking`, a missing SwiftLint fails the end-of-turn check instead of passing unlinted code. |
| [1.1.2](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.1.2) | Verification fixes from an external review: lint alone never passes `verify.sh full`, design-system colors checked at runtime, blocking plugin validation. |
| [1.1.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.1.1) | Repository and marketplace renamed to swift-harness. Public roadmap, security policy, contribution guide, demo. |
| [1.1.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.1.0) | CI on every pull request: hook tests with macOS bash 3.2, ShellCheck, compiled Swift references. Claude Code smoke test suite with 7 scenarios checked automatically. |
| [1.0.3](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.0.3) | Clearer feedback to Claude: labelled formatter changes, "no issues" when lint passes, explicit guidance when lint blocks. `.swift-format` template. |
| [1.0.2](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.0.2) | No silent formatter or SwiftLint failures, including invalid SwiftLint configurations. `lintBlocking` enforced at the end of the turn. |
| [1.0.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.0.1) | Never PASS without a real check. Protected paths resolved through symlinks. Every build input triggers verification. |
| [1.0.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.0.0) | First release: six skills, UI reviewer, four hooks, project templates. |

## Have an idea?

Start a thread in [Discussions](https://github.com/davidelarocca/swift-harness/discussions) or open a [feature request](https://github.com/davidelarocca/swift-harness/issues/new?template=feature_request.yml). Concrete examples of where Claude goes wrong on your Swift project are the most useful input.
