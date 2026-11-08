---
name: ui-change
description: Reuse-first procedure for any change to SwiftUI or AppKit interface code in a macOS app - new views, overlays, pills, toasts, popovers, buttons, styles, modifiers, lists or visual tweaks. Use before writing or modifying UI code, so existing components are reused and the component registry stays accurate.
---

# Reuse-first UI change

The goal is that every interaction pattern exists once. Visual bugs usually come from a second, slightly different copy of something that already exists.

## 1. Discover (before writing code)

1. Read `docs/COMPONENT_REGISTRY.md` and `docs/DESIGN_SYSTEM.md` if they exist.
2. Search the code for the same behavior, not only the same name. Examples: for a top notification search `overlay(alignment: .top`, `transition(.move(edge: .top`, `Toast`, `Pill`, `Banner`, `HUD`; for a hover button search `onHover`, `ButtonStyle`.
3. List every place the new or changed element will appear.
4. If the change touches the layout of a screen listed in `docs/LAYOUT_CONTRACT.md` (or a view inside it), read its row: Min, Default, Max, Compact below and the compact behavior, and the presented UI opened from it.
5. If the change displays an entity (a row, tile, header, menu or inspector showing a domain object), read its rows in `docs/PRODUCT_MAP.md`: its destination and how it is opened, its relations, its action set. Without a map, find them in the code: an existing appearance of the same entity shows the navigation call and the shared menu.

## 2. Decide

| Situation | Action |
|---|---|
| A component with the same behavior and responsibility exists | Reuse it as is |
| Same behavior, needs a new variant or option | Extend it: add a case to its kind enum or a parameter with a default. Check every caller still works |
| Looks similar, different behavior (e.g. transient pill vs anchored popover) | Separate component. Say why in the registry |
| Nothing similar | Create it in the design system, not inside the feature |
| Two or more existing copies | Stop and propose consolidation first. Do not add a third |

State the decision in one line before implementing.

For a screen in the layout contract, design for its whole range of sizes, not the size of your preview: at Min nothing is clipped or pushed out, below Compact below the compact behavior applies, popovers open inside the window. Prefer layouts that adapt (`ViewThatFits`, flexible frames, a menu for overflow) to fixed widths and `.fixedSize()` rows.

For an entity shown in a new place, the default is the whole: it opens its destination, related entities shown with it open theirs (no plain text styled as a link), and it offers its action set through the shared menu or command. Leave something out only for a reason, and say which.

## 3. Implement

- Inside the design system: tokens only, presentation separated from behavior (a view draws, a presenter or style decides when and how it shows).
- In feature code: call the component's public API with intent (`.success("Added to library")`), never with layout numbers.
- Shared transient UI is presented from a single host at the root, driven by an observable presenter in the environment. See the `design-system` skill for the pattern.
- Follow the conventions of each platform the view runs on (`PLATFORMS` in `scripts/verify.sh`, or the project's targets). A view shared by macOS and iOS keeps one structure and branches with `#if os(...)` only where behavior differs.
  - macOS: hover states, focus rings, keyboard access and shortcuts, pointer, menus and commands, windows that resize.
  - iOS: Dynamic Type (text styles, layouts that reflow instead of truncating at accessibility sizes), the safe area (content inside it, backgrounds may extend), touch targets of at least 44 pt, size classes (compact and regular width, including iPad Split View and Slide Over), no action reachable only by hover, haptics only for meaningful feedback.
  - Both: accessibility labels, Reduce Motion for moving content (`@ReduceMotion` with `Motion.moving(_:reduced:)` when the design system has them).

## 4. Verify

- Previews for every state of the component: default, hover or pressed where relevant, disabled, selected, light and dark, long and localized text. On iOS also the largest accessibility Dynamic Type size, and compact and regular width.
- `LayoutContract.check`, `Screenshot.capture` and `Snapshot.verify` are macOS only (they draw in an `NSWindow`). A view that builds only for iOS gets no layout test, screenshot or snapshot from them: check it with the previews above and say in your summary that no test measured it.
- Snapshot tests for shared components when the project has them (`Snapshot.verify`): add the new states to the gallery. A failing snapshot names the region that changed and leaves the new image and a diff in `.build/swift-harness/snapshots/`. Look at them: fix an unintended change; for an intended one, tell the user which images changed and why, and ask them to approve with `/swift-harness:approve-snapshots`. Never copy, edit or delete baselines yourself, and do not report the change as verified until they are approved.
- Keyboard: when the project has `KeyboardCheck` tests, a new keyboard action of a shared component gets one (press the key, assert what happened). When a main screen has a `FocusOrder` test and you add, remove or move a control, update the expected order in the same change. If Keyboard navigation is off on this Mac the focus test is skipped: say that the Tab order was not measured.
- For a screen in the layout contract: previews at its Min and Default sizes, and its `LayoutContract.check` tests pass (they run in the verify command). A failure gives the size and the width needed: fix the layout, or change the contract only when the user agrees the screen's sizes change.
- Build. For non-trivial changes, delegate a review to the `ui-reviewer` agent with the list of changed files. When the project has `Screenshot.capture` tests, run them first so the images show the change (`scripts/verify.sh fast` covers a package test target, `full` an Xcode one); for a new main screen, add its capture next to its layout test.
- If the component is used in several places, check each caller listed in the registry.

- In the summary to the user, mark each claim about the result with its evidence: *measured* (a check or test that ran on this code: name it), *seen* (a screenshot or the accessibility tree you looked at: name the image or the element), or *inferred* (from reading the code). "The pill fits at 320 pt" is measured only if a layout test at 320 pt passed. Anything the end-of-turn check did not run (it tells the user what) is not measured. Without evidence, say inferred, or that it was not checked.

## 5. Record

- Update `docs/COMPONENT_REGISTRY.md` in the same change: new entry, new variant, new callers, or a move to "Retired".
- Update `docs/LAYOUT_CONTRACT.md` if a screen's sizes, compact behavior or presented UI changed, or a main screen was added (with its `LayoutContract.check` test).
- Update `docs/PRODUCT_MAP.md` if it exists: new appearances, actions or relations, and deliberate omissions under "Exceptions".
- If you found duplicates you did not fix, add them to "To consolidate".
- If you introduced a new pattern, ask whether it deserves an ADR.
