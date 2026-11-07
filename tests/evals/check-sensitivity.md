# Check sensitivity

Issue [#79](https://github.com/davidelarocca/swift-harness/issues/79). A check can pass for the wrong reason: the layout check of 1.4.0 accepted content 2000 pt wide on a real app while every test was green (fixed in 1.4.1). This eval plants one defect at a time and records which check notices it.

## Method

`scripts/mutate.sh` (`/swift-harness:check-sensitivity`) copies the project into its `.build/swift-harness/` (without `.git`, `.build` and DerivedData, with a fresh git repository), runs the checks once without mutations, then applies each operator, runs the checks again and restores the file.

| Operator | Target check | Defect |
|---|---|---|
| `registry-rename` | registry | the first Components entry renamed |
| `layout-rename` | layout contract | the first Screens view renamed |
| `docs-stale-link` | docs | the first local link (else path in backticks) of the checked docs moved to a file that does not exist |
| `security-relax` | security | an entitlement relaxed |
| `contracts-forbidden` | contracts | a target given a dependency on a sibling its contract does not allow |
| `lint-literal` | lint | a padding token replaced by a number |
| `keyboard-shortcut` | keyboard | a `.keyboardShortcut` removed, from a view a `KeyboardCheck` test hosts first |
| `layout-wide` | layout sizes | the first Screens view made 200 pt wider than its Min |
| `a11y-label` | accessibility | an `.accessibilityLabel` removed |
| `snapshot-padding` | snapshots | a padding made 3 pt larger, in a view a snapshot test renders |

The last five need `--verify`: they run `scripts/verify.sh full`, once without mutations and once per operator. Its output is one block, so a new failure line is credited to a check by what it names: a SwiftLint rule on the mutated file, or a test file (or a type declared in it) that calls the check's API, directly or through a helper function of the project. Numbers are ignored when comparing with the run without mutations.

Results:
- **killed**: the target check failed with a problem it did not report before.
- **SURVIVED**: it did not. This is a finding to explain: a bug in the check, a setting that turns it off, or a defect out of its reach.
- **no site**: nothing to change, for example no registry.
- **no check**: the project does not use that check: no test calls its API, or SwiftLint has no rule for it. The verify run is skipped.

## Results on the fixtures

Run by `tests/run.sh` and `tests/mutate-fixture.sh --ui`, in CI on every pull request.

| Fixture | Operators | Killed by their target | Notes |
|---|---|---|---|
| `tests/fixtures/mutate/` (docs, registry, layout contract, entitlements, contracts) | 5 | 5 | each by its target check only |
| `tests/fixtures/mutate-verify/` with the setup templates, real `swift test` and SwiftLint | 4 | 4 | `lint-literal` is also caught by the snapshot test: the padding really changes |
| `tests/fixtures/accessibility/` (an app with UI tests), real `xcodebuild test` | 1 | 1 | |

A run with real builds takes about 1.5 minutes on an M-series Mac.

## Results on a real app

A ~97k-line macOS app (a Swift package plus an Xcode app with UI tests, 55 docs), on a copy, read-only. It does not use swift-harness: no config, no registry, layout contract or architecture contract, no SwiftLint config, and its own layout and accessibility helpers in its UI tests. For `--verify`, its `scripts/verify.sh` ran the one UI test that runs the accessibility audit (a gallery of one flow's states), with the template's output filter.

| Operator | Result | Why |
|---|---|---|
| `docs-stale-link` | killed | the first link of `CLAUDE.md`. The docs check already failed on one real broken path, which did not hide the new one. |
| `security-relax` | killed | library validation turned off in the app's entitlements |
| `registry-rename`, `layout-rename`, `contracts-forbidden` | no site | the app has no registry, layout contract or architecture contract |
| `lint-literal`, `keyboard-shortcut`, `layout-wide`, `snapshot-padding` | no check | no SwiftLint padding rule; no test calls `KeyboardCheck`, `LayoutContract`, `LayoutAudit` or `Snapshot` |
| `a11y-label` | SURVIVED | out of reach: the label removed is on the online lookup's results, a screen the audited test never opens. The audit runs on the states of one flow only. |

The survivor measures coverage, not the check: the audit can only catch what the tests show it. One site per operator is not enough to say which screens are covered. A per-screen view of that coverage is a question for the navigation crawler of v1.8.0 ([#82](https://github.com/davidelarocca/swift-harness/issues/82)).

## What the runs found

Fixed in 1.7.0:
- **The test templates and the SwiftLint template.** The setup test templates broke the template `.swiftlint.yml` in 59 places. `verify.sh full` lints in strict mode, so a project that copied them failed on code it did not write. This was found on the first `--verify` run of the package fixture.
- **Failed test names hidden.** With Xcode 27, `xcodebuild -quiet` names failed tests only in a "Failing tests:" list. `verify.sh` without xcbeautify dropped that list, so Claude was told that tests failed but not which. This was found on the accessibility fixture.
- **SwiftLint baselines in temporary folders.** In the system temporary folder (a path through a symbolic link), SwiftLint 0.65 baselines match nothing. The copy now lives in the project's `.build`.
- **From the real app:**
  - A helper function that wraps the audit (`app.assertAccessibility(...)`) hid the test from the crediting. The test is now found through the helper.
  - A test file named `XCUIApplication+Layout.swift` broke the crediting regex.
  - Checks the project does not use cost a full verify run each and showed up as survivors. They are now reported as "no check", without a run.

## Limits

- One site per operator, always the first in a fixed order. A kill shows that the check can see that kind of defect. It does not show that the check sees it everywhere.
- Crediting reads the verify output. A failure that names neither a test file nor a SwiftLint rule is shown as `verify`, so a check that prints elsewhere would be missed. The test fixtures cover the formats of `swift test`, Swift Testing and `xcodebuild -quiet`.
- The operators look for the setup templates' API. A project with its own checks gets "no check" for them, even when its own checks would notice the defect.
