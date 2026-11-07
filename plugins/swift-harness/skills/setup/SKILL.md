---
name: setup
description: Bootstrap or retrofit the swift-harness method in a Swift/SwiftUI macOS project - CLAUDE.md, path-scoped rules, design system docs, component registry, ADRs, SwiftLint/formatter config, verify script and quality-gate config. Use when the user asks to set up, initialize or onboard a project to swift-harness.
disable-model-invocation: true
---

# Set up swift-harness in a project

Goal: leave the project with persistent instructions, a documented design system, a component registry and active quality gates, without overwriting anything the project already has.

Templates live in `${CLAUDE_PLUGIN_ROOT}/skills/setup/templates/`. Placeholders look like `{{NAME}}`.

## 1. Safety first

1. Confirm the folder is a git repository. If not, stop and ask whether to run `git init`.
2. Run `git status --porcelain`. If there are uncommitted changes, ask the user to commit them first. Do not commit their work for them.
3. Create a branch `chore/swift-harness-setup` unless the user is already on a dedicated branch.

## 2. Detect the project (read only)

Collect, and show the user a short summary:

- Project type: `.xcworkspace`, `.xcodeproj`, `Package.swift`, local packages under `Packages/` or similar.
- Schemes and targets: `xcodebuild -list -json` (workspace or project as appropriate).
- Swift version, platforms and minimum versions: `SUPPORTED_PLATFORMS` and `SDKROOT` in `project.pbxproj` (or `xcodebuild -showBuildSettings -scheme <scheme>`), `platforms:` in each `Package.swift`. If iOS is among them, pick the simulator for iOS tests from `xcrun simctl list devices available`: the newest iPhone listed.
- Whether the Xcode project uses synchronized folders: search `project.pbxproj` for `PBXFileSystemSynchronizedRootGroup`. If present, new files do not touch `project.pbxproj`.
- Existing instruction files: `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `.claude/rules/`, `.claude/settings.json`.
- Existing docs: hub and spoke docs, roadmap, step plans, any architecture or design notes.
- Existing tooling: `.swiftlint.yml`, `.swiftformat`, `.swift-format`, test targets, snapshot tests.
- Installed tools: `which swiftlint swiftformat jq`, and `xcrun --find swift-format`.
- Protected areas candidates: audio engines, persistence/migrations, crypto, anything the docs flag as critical.
- Security settings: `*.entitlements` files (sandbox, hardened runtime exceptions, capabilities), `Info.plist` files of app targets (usage descriptions, URL schemes, ATS), `PrivacyInfo.xcprivacy`. Find them with `git ls-files '*.entitlements' '*Info.plist' '*.xcprivacy'`, ignoring tests and third-party code.

## 3. Ask only what you cannot detect

Use one AskUserQuestion call with at most four questions, for example:

- Design system location: a local Swift package `Packages/DesignSystem` (recommended) or a folder inside the app target.
- Formatter: `swiftformat` (recommended, needs Homebrew) or Apple `swift-format` (ships with Xcode).
- Protected paths that require explicit approval before Claude edits them. Pre-select the security settings files found in step 2 and recommend keeping them: Claude tends to relax an entitlement to make something work. List each file by its path: protected paths are exact files or folder prefixes, not globs.
- Verify commands: the fast check run before Claude ends a turn, and the full check run before merging.

## 4. Generate files

For each template, if the target file does not exist, create it with placeholders filled. If it exists, never overwrite: show the user the proposed additions and merge only what they approve.

| Template | Target |
|---|---|
| `CLAUDE.md` | `CLAUDE.md` (if the repo uses `AGENTS.md` only, add `@AGENTS.md` at the top of the new CLAUDE.md instead of duplicating) |
| `rules/ui-features.md` | `.claude/rules/ui-features.md` |
| `rules/design-system.md` | `.claude/rules/design-system.md` |
| `rules/architecture.md` | `.claude/rules/architecture.md` |
| `docs/ARCHITECTURE.md` | `docs/ARCHITECTURE.md` |
| `docs/DESIGN_SYSTEM.md` | `docs/DESIGN_SYSTEM.md` |
| `docs/COMPONENT_REGISTRY.md` | `docs/COMPONENT_REGISTRY.md` |
| `docs/PRODUCT_MAP.md` | `docs/PRODUCT_MAP.md` |
| `docs/LAYOUT_CONTRACT.md` | `docs/LAYOUT_CONTRACT.md` (see step 7) |
| `tests/LayoutContract.swift` | a test target that can import SwiftUI and the screens, without a sandboxed host app (see step 7) |
| `tests/Screenshot.swift` | the same test target as `LayoutContract.swift` (see step 7) |
| `tests/Snapshot.swift` | the same test target as `LayoutContract.swift` (see step 7) |
| `tests/AccessibilityAudit.swift` | a UI test target (XCUITest) of the app (see step 7, accessibility) |
| `tests/KeyboardCheck.swift` | the same test target as `LayoutContract.swift`, or the design system package tests (see step 7, keyboard) |
| `tests/FocusOrder.swift` | the UI test target, next to `AccessibilityAudit.swift` (see step 7, keyboard) |
| `tests/LayoutAudit.swift` | the UI test target, next to `AccessibilityAudit.swift` (see step 7, layout audit) |
| `docs/adr/0000-template.md` | `docs/adr/0000-template.md` |
| `swiftlint.yml` | `.swiftlint.yml` |
| `swiftformat` | `.swiftformat` (only if swiftformat was chosen) |
| `swift-format` | `.swift-format` (only if swift-format was chosen; without it swift-format uses 2-space indentation and reformats every edited file) |
| `verify.sh` | `scripts/verify.sh` (then `chmod +x`) |
| `swift-harness.json` | `.claude/swift-harness.json` (this file switches the plugin hooks on for this project) |

Rules for filling templates:

- Fill `paths:` globs in the rules with the real folder layout found in step 2.
- Fill the SwiftLint `excluded` regex for custom rules with the real design system path.
- In `verify.sh`: `{{LOCAL_PACKAGES}}` becomes quoted paths (`"Packages/DesignSystem" "Packages/Domain"`) or nothing for `PACKAGES=()`; `{{SCHEME}}` and `{{XCODE_CONTAINER_FLAG}}` become empty strings for a packages-only project. At least one of the two must be set: with neither, the script reports `NOT CONFIGURED` and fails. `{{PLATFORMS}}` becomes the quoted platforms the scheme builds, `"macOS"`, `"iOS"` or `"macOS" "iOS"` (only these two are supported; name any other platform found in step 2 in the summary as not verified). `{{IOS_SIMULATOR}}` becomes the simulator picked in step 2, or an empty string without iOS. A packages-only project that lists iOS gets `PARTIAL`, never `PASS`, because `swift test` runs on this Mac only: say so in the summary.
- Keep CLAUDE.md under 100 lines. Link to docs, do not copy them.
- If the project has existing hub and spoke docs, make `docs/ARCHITECTURE.md` the hub that links to them. Do not move or rewrite the existing docs in this step; list outdated ones as follow-ups.
- Populate `COMPONENT_REGISTRY.md` only with components that really exist and are shared. Unknown or duplicated ones go in the "To consolidate" section, design system views not meant for reuse (galleries, building blocks) under "Internal". Do not invent entries. Keep the column headers: the end-of-turn check reads them, and fails when a File does not exist or does not declare its Name.
- In `swift-harness.json`, `registry.sources` lists the design system folders (`{{DESIGN_SYSTEM_PATH}}`). Views, modifiers and styles declared there and missing from the registry are pointed out to Claude after each edit and to the user by `/swift-harness:doctor`. After populating the registry, list what it still misses with `"${CLAUDE_PLUGIN_ROOT}/scripts/registry.sh" missing .` and add those entries or list them under Internal.
- Leave the `PRODUCT_MAP.md` tables empty: filling them needs `/swift-harness:product-map`, which reads the whole app.

## 5. Tooling check

- Missing tools: tell the user the exact install command (`brew install swiftlint swiftformat jq`). Do not install them yourself.
- Run `scripts/verify.sh fast` once. Report the result. If it fails for reasons unrelated to setup, record that in the summary instead of fixing it now.
- Run SwiftLint once on the whole project and report the count per custom rule. This is the baseline of hardcoded values to migrate, and of concurrency escape hatches already in the code (the `concurrency_*` rules: a new one needs `// concurrency: <why it is safe>` on its line). If the count is high, suggest `swiftlint lint --write-baseline .swiftlint-baseline.json` and adding `--baseline .swiftlint-baseline.json` in `verify.sh`, so only new violations count.

## 6. Architecture contracts (SwiftPM, optional)

Only when the code is split into SwiftPM packages with several targets. Offer to create `docs/architecture-contracts.json`, which makes the end-of-turn check fail when a target gains a dependency the contract does not allow:

1. Read the current graph with `swift package dump-package` in each package folder (it runs `Package.swift`: ask before running it in a project you have not built).
2. Propose one entry per non-test target, listing its current dependencies: local targets by name, products of other packages as `package/product`. Point out any dependency that looks like a boundary violation instead of copying it silently.
3. Write the file only after the user agrees, with `"version": 1` and package folders as keys (`"."` for the root package). Suggest adding it to `protectedPaths` so Claude asks before editing it.

Skip this step for Xcode-only projects or a single target: there is nothing to check.

## 7. Layout contract

Offer it when the app has windows the user resizes. Fill `docs/LAYOUT_CONTRACT.md` only with what you find and the user confirms:

1. Find the main windows (`WindowGroup`, `Window`, `Settings`, `MenuBarExtra(...).menuBarExtraStyle(.window)`) and the view each shows, its `.frame(minWidth:minHeight:)` or `.defaultSize`, and `.windowResizability`. Find the panes with a width of their own (sidebar `navigationSplitViewColumnWidth`, inspectors).
2. Propose one row per main screen: Min from the declared minimum, Default from `.defaultSize`; ask the user for what is not declared, and for Compact below and the compact behavior. A window with no declared minimum is a finding: say so, it can shrink to nothing.
3. The test measures the content without the window's frame, because a minimum frame hides overflow. When the window's minimum frame is inside the content view, propose the split: a content type for View, a small window type that adds the frame for Window. Do not refactor without the user's agreement. A screen built on `NavigationSplitView`, `HSplitView`, a `List` or a `Table` takes any width, so its content cannot be measured and the check fails saying so: give that row the window type as View and Window, and give each page of the detail column and the sidebar a row of its own, with Min the width the column gets at the window's Min. A note on the test output ("takes any width") means the width is checked only as far as the content wraps like text: if it sits in a stretched frame, measure what is inside.
4. Copy `tests/LayoutContract.swift` into a test target that can import the screens and is not hosted by a sandboxed app (a sandboxed host cannot read `docs/`). Add one test per row, `LayoutContract.check("<View>") { <View>(...) }` and one for its Window, with the preview data the views need. Run them and report the result: a failing row is a real finding, not something to fix in the setup.
5. List popovers, sheets and secondary windows opened from these screens under "Presented UI".
6. Offer screenshots for review: copy `tests/Screenshot.swift` next to `LayoutContract.swift` and add one test per row, `Screenshot.capture("<View>") { <View>(...) }`. It saves PNG images at Min and Default, light and dark, to `.build/swift-harness/screenshots/` (add `.build/` to `.gitignore` if it is missing, or set `screenshots.path` in `.claude/swift-harness.json` to an ignored folder). The `ui-reviewer` agent looks at them; they are not compared with a baseline (item 7 does that). Each image takes about a third of a second: with many screens, capture the main ones. The generated `scripts/verify.sh fast` runs `swift test` for packages at the end of every turn, so captures in a package stay current; for an Xcode target it only builds, and the tests run in `full` mode. Put the captures (and the layout tests) in a package test target when you can, and say which case applies.
7. Offer visual regression for shared components: copy `tests/Snapshot.swift` next to `Screenshot.swift` and add a gallery test file with one `Snapshot.verify("<Component>", sizes: ["<width>"], state: "<state>") { ... }` per component in `docs/COMPONENT_REGISTRY.md` and state: default, long text, a long language (`locale: "de"`) and right to left (`locale: "ar"`) where the component shows text. Run it once: every image fails as missing, which is expected. Tell the user to look at them and run `/swift-harness:approve-snapshots`, then commit `snapshots/`. Never copy the images into `snapshots/` yourself. Baselines are pinned to this Mac's macOS version: say that other Macs and CI runners report them as not compared.

Skip items 1-6 for apps without resizable windows; item 7 applies to any app with shared components (it needs `LayoutContract.swift` and `Screenshot.swift` in the test target, not a contract). It can be done later by asking for a layout contract or snapshot tests.


**Accessibility audit (any app with a UI test target, macOS 14 or iOS 17 and later).** Offer it: copy `tests/AccessibilityAudit.swift` into the app's UI test target and add one test per main screen that launches the app, opens the screen and calls `try AccessibilityAudit.check(app)`. It runs Apple's `performAccessibilityAudit()`: missing descriptions, contrast, hit areas, clipped text, traits. Without a UI test target, propose creating one in Xcode and let the user do it (a new target edits `project.pbxproj`). Run it once: list the issues found. Each one is fixed or, with the user's agreement, listed as an exception in that test with its reason, never silenced for the whole app. UI tests run in `scripts/verify.sh full`.

**Layout audit (any app with a UI test target, macOS or iOS).** Offer it: copy `tests/LayoutAudit.swift` next to `AccessibilityAudit.swift` and add one test per main screen that launches the app, opens the screen and calls `try LayoutAudit.check(app)`. It reads the accessibility tree once and fails for every element cut by the edge of its window, sheet or popover outside a scroll view, and for every text over another text. On macOS call `LayoutAudit.shrinkWindow(app)` first, so the screen is checked at the window's minimum size; it fails if the window cannot be resized, so do not call it on a fixed-size window. On iOS run the tests on an iPhone and an iPad destination, and add a test with `app.launchArguments += LayoutAudit.largestText` (the largest Dynamic Type size); an app with no launch screen runs at the legacy 320x480 size, so check `UILaunchScreen` first. It cannot see text truncated by its own frame, content under the iOS status bar or home indicator, or empty space: say so, these stay with screenshots and review. Run it once and list what it finds; each fault is fixed or, with the user's agreement, an exception with its reason. UI tests run in `scripts/verify.sh full`.

**Keyboard and focus (any app with shared components; focus order needs a UI test target).** Offer both:
- Copy `tests/KeyboardCheck.swift` into the test target of the shared components (the design system package's tests when there is one, so `fast` runs them) and add a test per component with keyboard actions: host it, press the keys a user would (`return`, `escape`, arrows, its Command shortcuts) and assert what the action did. Use a `@Suite(.serialized)` with Swift Testing. A component whose action only a click reaches is a finding for the user, not something to hide with a test. It cannot check Tab, focus order, menu commands or shortcuts that differ only by Shift: say so.
- Copy `tests/FocusOrder.swift` next to `AccessibilityAudit.swift` and add one test per main screen, `try FocusOrder.check(app, [<identifiers in visual order>])`, giving the controls accessibility identifiers where they have none. It needs Keyboard navigation on (System Settings > Keyboard): with it off the test is skipped, and the result says so. Tell the user, and never change that setting on their Mac yourself; on CI add `defaults write -g AppleKeyboardUIMode -int 2` before the UI tests. It reads focus through an undocumented attribute: say that too.
- Reduce Motion: when the design system follows `references/Tokens.swift` of the design-system skill, components that move content read `@ReduceMotion` and animate through `Motion.moving(_:reduced:)`, and tests set `.environment(\.reduceMotionOverride, true)` (SwiftUI's `accessibilityReduceMotion` cannot be set). The `ds_motion_without_reduce` SwiftLint rule reports moving transitions that skip it.
## 8. Companion plugins

Check `/plugin` state and recommend, without installing on your own:

- `swift-lsp@claude-plugins-official`: type diagnostics and code navigation after edits. Recommended for every Swift project.
- Optional: XcodeBuildMCP for build/run/test loops without Xcode open, or the Xcode 26.3+ MCP (`xcrun mcpbridge`) for RenderPreview. Suggest at most one to start.

## 9. Finish

1. Show the list of created and merged files.
2. Commit on the setup branch with message `chore: set up swift-harness` only after the user confirms.
3. Tell the user that the end-of-turn check does not run `verify.command` until they approve it by typing `/swift-harness:approve-verify`, and that it asks again whenever the command or `scripts/verify.sh` changes. Do not run the approval yourself.
4. Tell the user that the first session after setup records the app's security settings (entitlements, App Transport Security, signing build settings) as a baseline: from then on a change fails the end-of-turn check until they approve it with `/swift-harness:approve-security`. `/swift-harness:doctor` shows the baseline.
5. Suggest the next step: `/swift-harness:audit` and `/swift-harness:product-map` if the project already has code, otherwise start with the design system skill.
