---
name: design-system
description: How to build or migrate to a SwiftUI design system for a macOS app - local Swift package layout, tokens, shared presenters for pills and toasts, button styles, component gallery and snapshot tests, plus a step-by-step migration from hardcoded values. Use when creating the design system, adding tokens, extracting a shared component, or setting up snapshot tests.
---

# SwiftUI design system for macOS apps

## Package layout

Prefer a local Swift package. It compiles and tests with `swift build` and `swift test` without touching `project.pbxproj`, and its boundary keeps app code out.

```
Packages/DesignSystem/
├── Package.swift
├── Sources/DesignSystem/
│   ├── Tokens/          Spacing, Radius, Typography, Motion, Color+Semantic
│   ├── Components/      one folder per component (view + presenter + styles)
│   ├── Styles/          ButtonStyle, LabelStyle, ToggleStyle
│   ├── Modifiers/       shared ViewModifiers (hover, card, selection)
│   ├── Resources/       Colors.xcassets
│   └── Gallery/         GalleryView listing every component in every state
└── Tests/DesignSystemTests/   snapshot gallery and keyboard tests, with their own copies of the setup helpers
```

`Package.swift`: platforms `.macOS(.v14)` or higher, plus `.iOS(.v17)` or higher when the app runs on iOS (match the app's targets), resources `.process("Resources")`. Snapshot tests need no package dependency. Add the package to the app once in Xcode (File > Add Package Dependencies > Add Local). After that, new files inside the package never need project edits.

## Tokens

See `references/Tokens.swift`. Rules:

- Names describe intent (`Spacing.section`), not the value.
- Typography builds on system text styles so Dynamic Type and accessibility keep working.
- Colors are semantic names in the package asset catalog with light and dark variants, exposed as `Color.DS.surface` style accessors.
- Motion tokens are `Animation` values. Where an animation or a transition moves content (position, size, scale, a slide or move transition), read Reduce Motion with `@ReduceMotion private var reduceMotion` and go through `Motion.moving(_:reduced:)`: no animation, or a fade for a transition. A fade alone needs nothing. `@ReduceMotion` is the system setting unless `.environment(\.reduceMotionOverride, true)` is set, which is how tests and previews check the reduced version (SwiftUI's `accessibilityReduceMotion` is read-only). The SwiftLint rule `ds_motion_without_reduce` reports a moving `.transition(...)` that skips it, on one line only.
- Keyboard: every action of a shared component works without a pointer (Return, Escape, arrows in lists, its Command shortcuts). Test it with `KeyboardCheck.swift` from the setup templates in the package tests.

## Shared presenters (pills, toasts, banners)

One presenter object owns the state, one host renders it at the root, features only call `show`. See `references/PillCenter.swift`.

- `@MainActor @Observable` presenter, injected with `.environment(_:)` at the root.
- A single `.pillHost()` modifier at the root window content draws the overlay.
- Message kinds are an enum (`info`, `success`, `warning`, `error`). New needs become new cases, not new views.
- Queueing, duration and dismissal live in the presenter, never in features.

The same shape works for any transient UI that appears in several screens.

## Interaction styles

Hover, pressed, selected and disabled states belong in `ButtonStyle`s and `ViewModifier`s in the design system. Features apply `.buttonStyle(.dsToolbar)` and never re-implement `onHover` logic.

## iOS and multiplatform

One design system serves every platform the app runs on. Differences live inside the components, never in feature code.

- Text uses text styles (`.font(.body)`, or `Font.custom(_:size:relativeTo:)`) so Dynamic Type scales it; spacing that sits next to text follows it with `@ScaledMetric`. Check each component at the largest accessibility size: it reflows, it does not truncate.
- Tappable components have a hit area of at least 44 pt on iOS, even when they draw smaller (`contentShape` plus a minimum frame from a token).
- Hover modifiers and pointer styles are macOS details: on iOS the same component shows its pressed and selected states, and no action is reachable only by hover.
- Components respect the safe area; only backgrounds extend past it (`ignoresSafeArea` on the background, not the content).
- Layout switches follow size class (`horizontalSizeClass`), not the device: an iPad in Split View or Slide Over is compact width.
- Branch with `#if os(iOS)` / `#if os(macOS)` inside the component only where behavior differs, and give the gallery a preview per platform.

## Gallery

A `GalleryView` in the package lists every component in every state, in light and dark. Show it from a debug-only menu item or a dedicated preview. It is the visual inventory for both the user and Claude.

## Snapshot tests

See `references/SnapshotTest.swift`. It uses `Snapshot.verify` from the setup templates (`tests/Snapshot.swift`, with `LayoutContract.swift` and `Screenshot.swift` in the same test target). The component tests live here, in the design system's own test target, also when the screens are another package with their own copies of the helpers for layout tests and screenshots: the helpers are made to be copied, and a copy needs no dependency. Do not make one package's tests depend on the other package to share a copy; a new dependency needs the user's agreement first, and the contract check sees a test target only when the contract lists it. Snapshot, screenshot and layout tests are macOS only: they draw in an `NSWindow`. A component that also builds for macOS is compared there; one that builds only for iOS has no snapshot yet. Notes for macOS:

- It renders in a real offscreen window. `NSHostingView` with `cacheDisplay` (what image snapshot libraries use for `NSView`) drops SwiftUI text and draws placeholders for `List`.
- Baselines are approved images in `snapshots/`, pinned to the macOS version and display scale they were made on. A test never writes one: a missing or different image fails and waits for `/swift-harness:approve-snapshots`. On another macOS version the images are reported as not compared.
- A gallery covers every state, long text, a long language and a right-to-left one (`locale:`). `dynamicTypeSize` does not change SwiftUI text on macOS.
- Run tests that need the package's colors with `xcodebuild test -scheme <Package> -destination 'platform=macOS'`. With Xcode 26 (Swift 6.3), `swift test` copies `Colors.xcassets` without compiling it, so `Color.DS.*` resolves to nothing and snapshots render without the real colors. Xcode 27 (Swift 6.4) compiles it.

## Migration from an existing app

Work in small steps, each on its own branch, each verifiable:

1. Create the package with tokens only. Build.
2. Pick the most duplicated element from the audit. Build the shared component with previews and snapshot tests.
3. Replace one call site. Compare before and after (screenshot or snapshot). Then the others, one screen at a time.
4. Delete the old copies. Update `docs/COMPONENT_REGISTRY.md` and move them to "Retired".
5. Repeat for the next element. Replace raw values file by file using the SwiftLint `ds_*` warnings as the to-do list.
6. When a category reaches zero warnings, switch that SwiftLint rule to `severity: error` so it cannot come back.
