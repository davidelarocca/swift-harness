---
name: port-to-ios
description: Read-only assessment of what it takes to bring a macOS Swift/SwiftUI app to iOS - what can be shared as is, what needs an adapter, a UI adaptation or a redesign, what is unavailable - with file:line evidence, target structure options and a status per platform. Writes only docs/PORTING_PLAN.md. Use when the user asks about an iOS version, porting, or going multiplatform.
disable-model-invocation: true
---

# Porting audit: macOS to iOS

Goal: a plan the user can decide on, built from evidence. Nothing is ported here: project, target and package changes come later, in verified steps.

## Ground rules

- Read only. The one file you write is `docs/PORTING_PLAN.md`, after the user has seen the summary, and, only with the user's yes, the porting ratchet (see "After the plan"). No other file, no project or package edit, no new target, no dependency change.
- Every claim cites `file:line`, or says what was not assessed and why. No evidence, no claim.
- Static evidence is not a build. Never say a module, a screen or the app is ready for iOS: say what was built, what was tested and what was reviewed, per platform, and nothing more.
- Decisions belong to the user. Compare options and recommend one; do not pick the target structure, cut a feature or change the product silently.
- Protected paths (CLAUDE.md, `.claude/swift-harness.json`) are assessed like the rest, and any change they would need is marked for explicit approval.

## 1. Start

1. Run `git status --porcelain` and keep the output: at the end, nothing but `docs/PORTING_PLAN.md` may differ.
2. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" summary` and `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" scan` from the project root. The scan lists, per module, macOS-only API compiled for iOS (`blocks`), API that works differently on iOS (`adapt`) and macOS-only code already behind `#if` (`guarded`), with `file:line`. It reads text only and runs nothing.
3. A static scan is not a build, and it misses what only the compiler sees (the C floating-point environment, `fenv.h`, was invisible to it until a real build failed). Offer the user a build for the iOS Simulator, and run it only if they say yes: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" build-check`. With a root `Package.swift` it builds each folder of `Sources/` (`--target NAME` for some, `--ios VERSION` for the deployment version). In an Xcode project (a `.xcodeproj` or `.xcworkspace` at the root, no root package) it builds every scheme `xcodebuild -list` shows (`--scheme NAME` for some, `--project NAME` when there are several projects or workspaces) for the generic iOS Simulator destination, without signing; a scheme with no iOS destination is reported as `NOT iOS`, which is a finding for the plan, not a failure. Either way it works on a temporary COPY of the project, without `.git`, `.build` and files that look like secrets by name (`.env*`, `Secrets*`, keys, certificates, provisioning profiles), so nothing in the project changes. Say plainly what that is not: the copy is not a sandbox. The project's build (manifests, build phases, plugins, scripts) runs on it with the user's permissions, package dependencies are fetched into it, and a secret kept under another name is copied. Report its lines as they are: a PASS is a build, not a tested or reviewed module, and a target behind a failing dependency shows that dependency's errors until it builds.
   When tests of what built would tell more, offer to run them on an iPhone simulator, again only with a yes: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" test-check`. In a package, `--target NAMETests` per test target (without it every folder of `Tests/` runs, and a macOS-only one stops the build), on a temporary scheme in the copy that builds only those targets. In an Xcode project, `--scheme NAME` for the scheme whose tests to run. `--device NAME` for another simulator. Report the counts and failures as printed: a skipped test proves nothing, and no UI was looked at unless a UI test did.
4. Read what the project already knows, when present: `docs/architecture-contracts.json` (module graph), `docs/COMPONENT_REGISTRY.md` (shared UI), `docs/PRODUCT_MAP.md` (entities, destinations, actions), `docs/LAYOUT_CONTRACT.md` (screen sizes), `docs/ARCHITECTURE.md`, and the entitlements and `Info.plist` files of the app targets.

## 2. Investigate

Keep the main context clean: run Explore subagents in parallel, each returning findings with `file:line`, not file dumps:

1. **Modules and dependencies.** For each module of the scan: what it does, whether its `blocks` lines are incidental (one helper that needs an adapter) or the module's purpose (an AppKit wrapper). External dependencies: platforms they declare, those the scan could not check.
2. **Screens and interaction.** Per screen or feature: windows, split views, menus and commands, toolbars, hover, keyboard shortcuts, drag and drop, popovers, multiple windows, settings. What each becomes on iPhone and on iPad (size classes, Split View and Slide Over).
3. **System and files.** Sandbox and file access (security-scoped bookmarks, open and save panels, watched folders), background work, audio sessions, notifications, menu bar or login items, AppleScript or services, anything iOS does not offer or offers differently.
   For an app that plays or records audio, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" audio`: it lists what iOS needs (the audio session category and activation, interruptions, route changes, remote commands, Now Playing, background audio) with the first `file:line` or "not found", the audio code only the Mac compiles, and the macOS-only audio with no iOS equivalent (exclusive device access, device sample rate, output device selection). Carry its lines into the plan's "Audio on iOS" section as they are: "found" means the call exists in code iOS compiles, not that the behavior is right. Interruptions and background audio are proved only on a simulator or a device.
4. **Product.** Using the product map when present: which destinations and actions survive on a phone, which need a different entry point, which have no iOS counterpart and need a decision.

## 3. Classify

One row per module, then per feature or screen. Each gets exactly one class:

| Class | Meaning |
|---|---|
| Share as is | No macOS-only API compiled for iOS, no platform behavior. |
| Share with adapter | Mostly shared; a few macOS-only calls go behind a protocol or `#if os(...)`. Name them. |
| UI adaptation | Same feature, different interaction: touch, size classes, sheets instead of popovers or windows. |
| Redesign | The macOS design does not translate (multi-window workflows, menu bar apps, dense desktop tables): needs a product decision. |
| Unavailable | iOS has no equivalent (name the API). Needs a product decision to drop or replace it. |
| Not assessed | Say why (generated code, binary dependency, no access). |

## 4. Target structure

Compare at least: one multiplatform app target sharing everything, and separate macOS and iOS app targets sharing the packages. For each: what changes in the project, what is shared, effort, risks for the macOS app. Recommend one and say why, and say what would change the recommendation.

## 5. Build probe

The build of step 1.3 is the probe, for packages and Xcode projects alike; do not run it twice. Record the result with the date: builds, fails with the first errors and their `file:line`, or has no iOS destination. A failure the scan did not predict is a finding. Without a yes, the status says "not built".

## 6. Write the plan

Show the user a short summary first: the share of modules per class, the decisions needed, the recommended structure. Then write `docs/PORTING_PLAN.md` from `${CLAUDE_PLUGIN_ROOT}/skills/port-to-ios/templates/PORTING_PLAN.md`. Run `git status --porcelain` again and compare with step 1: report any other file that changed, and do not hide it.

## After the plan

- The status per platform says "not started" for iOS until something was built and tested there. A build is not a test, and a test is not a UX review.
- Suggest the first steps in the order that keeps the macOS app working: shared packages first (adapters, `platforms:`), each verified on macOS and built for iOS, then the iOS target, then screens. Each step is its own branch; `scripts/verify.sh` with `PLATFORMS=("macOS" "iOS")` checks both.
- Once a module builds for iOS, offer to add it to the porting ratchet, and do it only with the user's yes: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/porting.sh" ratchet --record --module "<module>"` (the module as `summary` names it). From then on, new macOS-only code in that module fails the end-of-turn check with `file:line`, so daily work on the Mac app cannot undo the port unnoticed. Its current macOS-only uses are accepted as they are. The file (`docs/PORTING_RATCHET.tsv`) goes in the same commit as the change that made the module build. Recording again accepts new uses: that is the user's decision, never a way to make the check pass.
- Porting itself is not done in this session.
