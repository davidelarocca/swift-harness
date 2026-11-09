# Roadmap

Where swift-harness is going, and why. Live status is in the [milestones](https://github.com/davidelarocca/swift-harness/milestones) and [issues](https://github.com/davidelarocca/swift-harness/issues). This page is updated with every release.

_Last updated: 10 November 2026: a patch release, v1.8.3, now comes first (see below). Before that: 8 November 2026, after v1.8.0 (adoption on real projects: adoption audit, an adapter for the project's own docs check with observation first, the same checks for Codex, git hooks and other agents, approval across worktrees, timed commands and unstable tests, guest mode that protects the project's own files and stays local, evidence over time)._

**Guiding principle:** every check the harness claims to run must actually run, and must be backed by a test. New features come after the existing gates are reliable, and claims about impact come with measurements. A new method earns its place by beating a simple baseline on held-out data, not by being clever.

## First: v1.8.3, no silent skips

A review of the hook scripts found cases where a check did not run, or a result was wrong, and nothing said so. Each was reproduced on a fixture, and each gets a test that fails before its fix. They come before any new feature.

| | What gets fixed | Issue |
|---|---|---|
| 🫥 | **Changes the fingerprint did not see.** Guest files kept out of git, a repository with no commit yet, nested repositories and submodules, C++ sources outside `Sources/`: the end-of-turn check ran nothing. | [#137](https://github.com/davidelarocca/swift-harness/issues/137) |
| 📂 | **A working directory inside a nested repository** turned every hook off. | [#138](https://github.com/davidelarocca/swift-harness/issues/138) |
| 🔤 | **Old docs problems reported as new** by the docs adapter in a UTF-8 locale, when a turn fixed one of them. | [#139](https://github.com/davidelarocca/swift-harness/issues/139) |
| 🔁 | **`check.sh` passed on the second run** while a blocking check still failed. | [#140](https://github.com/davidelarocca/swift-harness/issues/140) |
| ✅ | **An approved security change** left the code recorded as failed. | [#141](https://github.com/davidelarocca/swift-harness/issues/141) |
| 🈶 | **Paths with non-ASCII characters** were skipped: the security contract did not see them. | [#142](https://github.com/davidelarocca/swift-harness/issues/142) |
| ⏸️ | **Interrupted turns.** A resumed session took its own unverified edits as the starting code. | [#143](https://github.com/davidelarocca/swift-harness/issues/143) |
| ⏱️ | **A Stop hook that timed out** left no record. | [#144](https://github.com/davidelarocca/swift-harness/issues/144) |
| 🧾 | **The catch log** had no bound, and one broken line emptied the report. | [#145](https://github.com/davidelarocca/swift-harness/issues/145) |

## Now: v1.9.0, perception in motion

Today every check on the running app looks at one state at one size. These look at flows, time and a hostile environment. Test isolation, which they need, shipped in 1.7.0. Two items move here from 1.8.0: adapters for a project's own lint and formatter, and the demo.

| | What you get | Issue |
|---|---|---|
| 🗺️ | **Real vs declared navigation.** A crawler walks the app through the accessibility tree and compares what it reaches with the product map: unreachable screens, missing links. | [#82](https://github.com/davidelarocca/swift-harness/issues/82) |
| 🗣️ | **Interaction conventions.** One word per action, menu bar commands and standard shortcuts, empty, loading and error states, confirmation or Undo for destructive actions, pseudo-localization. | [#83](https://github.com/davidelarocca/swift-harness/issues/83) |
| 🌩️ | **Faults and lifecycle.** Network, disk and permission failures injected in UI tests; save, relaunch and unsaved changes. | [#84](https://github.com/davidelarocca/swift-harness/issues/84) |
| 🦮 | **Accessibility task check.** An agent finishes a task through the accessibility tree only. | [#85](https://github.com/davidelarocca/swift-harness/issues/85) |
| 📊 | **Evals with and without swift-harness**, over a series of sessions on the same app rather than single tasks: drift, duplicates, regressions and unbacked claims at the end, read from the catch log and the evidence records. Published with method and raw data. | [#8](https://github.com/davidelarocca/swift-harness/issues/8) |
| 🔌 | **Adapters for the project's own lint and formatter.** As for docs in 1.8.0: the project's command runs instead of the harness's, starts in observation if you want, and the report proposes when it should block. | [#125](https://github.com/davidelarocca/swift-harness/issues/125) |
| ⏱️ | **Try it in minutes.** A demo app where the plugin catches something in the first session, and a README organised by problem. | [#88](https://github.com/davidelarocca/swift-harness/issues/88) |
| 🪫 | **Weakened checks.** At the end of a turn you are told when it removed tests, added skips or `swiftlint:disable`, raised a tolerance or loosened a contract; and a measured list of the ways an agent told to "make it pass" gets round the checks, misses included. | [#146](https://github.com/davidelarocca/swift-harness/issues/146) |
| 📦 | **Results from the result bundle.** `verify.sh` reads failed tests, messages and UI test screenshots from `xcodebuild`'s result bundle instead of filtering its text, which changes between Xcode versions. | [#147](https://github.com/davidelarocca/swift-harness/issues/147) |

## Research track

Methods from other fields, studied as hypotheses before any becomes a feature. Each experiment has a question, a simple baseline, held-out data, a negative control and a condition for not shipping, written before the results; method and raw results go in [`tests/evals/`](tests/evals/), negative results included. An experiment that fails is archived, not forced into a release.

| | Question | Baseline it must beat | Status |
|---|---|---|---|
| 🎭 | **Metamorphic UI checks**: do relations between two states of a screen (two window sizes, the largest Dynamic Type) catch a defect that LayoutAudit and snapshots miss? Only relations the accessibility tree can observe. | LayoutAudit and snapshots at the same states | hypothesis; first spike on the UI fixtures |
| 📏 | **A token scale from the project's own values**: what scale would cover its hardcoded paddings, spacings and radii? On one open-source app, 5 radius values cover 95% of 87 uses. | The most frequent values (on the same app it already matches clustering, and beats it for padding: 82% against 72% unchanged) | measured on one app; needs apps that declare their tokens |
| 🧬 | **Duplicates under other names**: does compression distance find components that name and identifier overlap miss? | Identifier overlap (it ranks 27 of the 30 closest pairs the same way) | measured on one app; needs blind labels |
| 🧾 | **Unbacked claims**: how often does a final message say "verified" when the evidence record says otherwise, and would a receipt generated from that record fix it? | The evidence summary and notices of 1.7.0 | to measure on labelled sessions, English and Italian |
| 🔗 | **Missing companion changes**: do co-change rules learned from a project's history predict a forgotten half of a change? | Base rate and directory neighbours | one app, too few events; multi-repository study |
| 🧪 | **Smallest failing change and check order**: localizing the hunk that broke a test, and running the most informative checks first | Claude's own diagnosis; the declared order | parked until slow suites show the need |
| 🌳 | **Baselines of the accessibility tree, as text**: pixel snapshots are "not compared" on another macOS version, so on most CI runners. Does an approved text baseline of roles, labels and hierarchy catch regressions there, and read well in a diff? | Pixel snapshots on the machine they were made on; LayoutAudit | hypothesis |
| 🧮 | **Allocation budgets**: virtual machines count no instructions, so performance budgets are "not compared" on CI. Is the number of allocations of an operation stable enough there to catch the same regressions? | The instruction budget on a real Mac, on the same planted regressions | hypothesis |
| 🧰 | **Xcode as a host**: do the hooks run inside Xcode's own agent, and would the same engine behind an MCP server reach the agents that have no hooks? | `check.sh` called from the agent's rules | to measure first |

## Then: v2.0.0, assisted macOS to iOS porting

Waits for a real iOS port of a macOS app to check it on: the porting audit of 1.5.0 is there to start one.

| | What you get | Issue |
|---|---|---|
| 🍎➡️📱 | **Porting in verified slices.** After you accept the plan and the target structure: shared domain first, adapters for platform APIs, then one feature at a time, each built and tested on iOS and on the Mac, with results per platform. Checked on a real port. | [#48](https://github.com/davidelarocca/swift-harness/issues/48) |
| 📱 | **iOS checked on a real app.** The iOS-aware checks of 1.5.0 used on a real iOS port: the README says iOS once it passes. | [#40](https://github.com/davidelarocca/swift-harness/issues/40) |
| 🔒 | **Porting ratchet.** New macOS-only API in a ported shared module fails. | [#73](https://github.com/davidelarocca/swift-harness/issues/73) |
| 🚦 | **Shared machine.** UI tests and simulators ask first, take a lock, build only what is ported. | [#74](https://github.com/davidelarocca/swift-harness/issues/74) |
| 🎧 | **Audio apps.** Audio session, interruptions and background audio in the porting audit. | [#75](https://github.com/davidelarocca/swift-harness/issues/75) |

## Later

| | What you get | Issue |
|---|---|---|
| 👀 | **UI review ritual.** Three window sizes, a gallery of states from UI tests, a keyboard-only pass. | [#67](https://github.com/davidelarocca/swift-harness/issues/67) |
| 🔗 | **Rules and the checks that enforce them.** Which of the project's agent rules a check backs, which nothing checks, and which still catch something, so rules that no longer earn their place can leave the files read into every session. | [#148](https://github.com/davidelarocca/swift-harness/issues/148) |
| 🖼️ | **Previews as the list of states.** Snapshot, layout and accessibility checks on every `#Preview`, and a registry component with no preview reported. A spike comes first. | [#149](https://github.com/davidelarocca/swift-harness/issues/149) |

Ideas parked until there is demand: a local, read-only view of the checks with evidence behind every edge and status, possibly a map of screens by platform and check with provenance on each cell ([#50](https://github.com/davidelarocca/swift-harness/discussions/50)); declared design intent, where the user marks views as deliberately parallel or a value as an intended exception, with provenance; persistence migrations, localization and docs drift ([#38](https://github.com/davidelarocca/swift-harness/discussions/38)).

## Shipped

| Version | Highlights |
|---|---|
| [1.8.2](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.8.2) | Hardening from a hook-script review by another agent: the edit guard fails closed on a config it cannot read and matches protected paths by filesystem identity, verify approval and the HTML report refuse paths that leave the project, the evidence history serialises its writers, and the doctor's coverage warning is a hint, not a fix to apply. |
| [1.8.1](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.8.1) | Fixes from real use and an external review: partial and unstable results named by `check.sh` (`--strict`), observed checks counted by episode, scripts the approval does not cover named, and a one-time user permit for a Codex edit of a protected file. |
| [1.8.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.8.0) | Adoption on real projects: a read-only adoption audit, the project's own docs check run instead of the harness's (observed first, then proposed as a block from what was fixed), the same checks for Codex, git hooks and other agents, approval shared across worktrees, timed fast commands and unstable tests named, guest mode that protects the project's own rules and can stay out of git, and evidence kept over time. |
| [1.7.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.7.0) | A measured harness: planted defects show which check catches what (`/swift-harness:check-sensitivity`), a drift score per commit, an evidence summary at every turn end, a local catch log with `/swift-harness:report` and a static HTML page, guest mode for projects with their own rules, a UI test isolation check, and a branch scope contract. |
| [1.6.0](https://github.com/davidelarocca/swift-harness/releases/tag/swift-harness--v1.6.0) | Reliable sessions and checks on what the app does: per-session state, keyboard and focus order checks with an overridable Reduce Motion, a layout audit from the accessibility tree on macOS and iOS, a docs reference check, and performance budgets measured in instructions retired against baselines only you approve. |
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
