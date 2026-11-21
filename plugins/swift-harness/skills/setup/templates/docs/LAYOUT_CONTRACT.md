# Layout contract

How each main screen holds up as its window or pane is resized. Read it before changing the layout of a
screen listed here, and update it in the same change.

Sizes are in points, `<width>x<height>`, or `<width>` alone when the height does not matter.

- The end-of-turn check (swift-harness) keeps the table true: each View exists in its File, and tests
  measure the View and the Window.
- The tests do the measuring, with `LayoutContract.check("<View or Window>") { ... }`:
  - **View**, the screen's content, is proposed each size of its row: Min, just below and at Compact below,
    Default, Max. It fails when it needs more room than that: content clipped or pushed out of the window.
  - **Window**, the view the window shows (the content with the window's `.frame(minWidth:minHeight:)`), must
    declare Min as its minimum: not less, or the window shrinks to sizes the screen was not designed for; not
    more, or it never reaches Min. With a Max, it must not grow past it.
  - Measure the content without the window's frame: a minimum or fixed frame around a view hides content
    wider than the frame.
- Not measured: truncated text, overlapping content, and where popovers and secondary windows open. Those are
  checked in review, against the rows below. `Screenshot.capture("<View>") { ... }` in the same tests saves
  images of the screen at Min and Default for that review.

## Screens

| Screen | View | File | Window | Min | Default | Max | Compact below | Compact behavior |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | | |

- **View**: the SwiftUI type of the screen's content. **File**: where it is declared, from the repository root.
  A split view (`NavigationSplitView`, `HSplitView`) takes any width, so its content cannot be measured: name
  its window type as View and Window, and give each page of the detail column and the sidebar a row of its own,
  with Min the width its column gets at the window's Min.
- **Window**: for a screen that fills a window, the type the window shows, which declares the window's
  minimum size (often `View().frame(minWidth: ..., minHeight: ...)` in its own type). Empty for a pane (a
  sidebar, an inspector, a detail column), which is measured as View only. It can be the View itself when the
  content declares its own minimum and has nothing that could overflow around it.
- **Max**: a size, or `-` for none. **Compact below**: a width under which the screen switches to a compact
  layout, or `-`. **Compact behavior**: what changes below it (which controls collapse into a menu, what
  hides, what becomes a popover).

## Presented UI

Popovers, sheets, menus, dropdowns, tooltips and secondary windows opened from these screens. At the screen's
Min size they open inside the window and nothing sticks out past its edge; a separate window opens on screen.
In **Opened from**, put the accessibility identifier of the control that opens it in backticks (`moreButton`):
`LayoutAudit.checkPresented(app)` in a UI test opens each one at the smallest window and fails for what
sticks out. The menu bar and context menus opened at the pointer are not listed: the app does not place them.

| Element | Opened from | Kind | Size | At the minimum size |
|---|---|---|---|---|
| | | | | |

## Exceptions

Deliberate departures from the rules above, with the reason.
