// Layout audit for UI tests, from the swift-harness setup templates (#69).
// Copy into a UI test target (XCUITest), macOS or iOS. It reads the accessibility tree of the
// launched app once and fails with every fault it finds:
// - an element cut by the edge of its window (or sheet, popover), outside any scroll view;
// - a text over another text, neither containing the other.
//
//     func testLibraryAtTheSmallestWindow() throws {
//         let app = XCUIApplication()
//         app.launch()
//         LayoutAudit.shrinkWindow(app)                 // macOS: the window at its minimum size
//         try LayoutAudit.check(app)
//     }
//
//     func testLibraryWithTheLargestText() throws {    // iOS: the largest Dynamic Type size
//         let app = XCUIApplication()
//         app.launchArguments += LayoutAudit.largestText
//         app.launch()
//         try LayoutAudit.check(app)
//     }
//
// On iOS the size is the simulator's: run the test on an iPhone and an iPad destination, and in
// landscape with `XCUIDevice.shared.orientation = .landscapeLeft`. An iOS app without a launch
// screen (`UILaunchScreen` in Info.plist, or `INFOPLIST_KEY_UILaunchScreen_Generation = YES`)
// runs at the legacy 320x480 size on any iPhone: the audit then measures that size.
//
// Frames in the tree are not clipped: content past an edge keeps its whole frame, so an edge is
// measurable. Inside a scroll view, list, table or outline, content past the edge is scrolled
// away on purpose: it is never reported as cut, and its texts are only compared with texts in
// the same scroll view.
//
// What it cannot see, which stays a review (screenshots, `AccessibilityAudit`'s clipped text):
// - text cut by its own frame (truncated, or clipped by a frame): the tree gives the visible part;
// - elements hidden from VoiceOver, and drawn content with no accessibility element;
// - content under the iOS status bar, the Dynamic Island or the home indicator (the tree has no
//   safe area), and a control covered by a non-text view;
// - empty or unbalanced space.
// On iOS a text with opacity 0 is in the tree and can be reported; on macOS it is not.
//
// UI tests run in `scripts/verify.sh full`, not in `fast`.

import XCTest

enum LayoutAudit {
    struct Issue: CustomStringConvertible {
        enum Kind { case cutByEdge, textOverText }
        let kind: Kind
        /// The element's accessibility identifier, or its label or value when it has none.
        let element: String
        let frame: CGRect
        /// The other text, for an overlap.
        let other: String?
        /// The edge's container (window, sheet, popover) for a cut; the other text for an overlap.
        let otherFrame: CGRect

        var description: String {
            switch kind {
            case .cutByEdge:
                return "'\(element)' is cut by the \(LayoutAudit.edges(of: frame, in: otherFrame)) edge: \(LayoutAudit.text(frame)) in \(LayoutAudit.text(otherFrame))"
            case .textOverText:
                return "'\(element)' and '\(other ?? "")' overlap: \(LayoutAudit.text(frame)) and \(LayoutAudit.text(otherFrame))"
            }
        }
    }

    /// An issue accepted on purpose. `element` is the accessibility identifier or label; it
    /// covers every issue that names it.
    struct Exception {
        let element: String
        let reason: String
    }

    #if os(iOS)
    /// Launch arguments for the largest Dynamic Type size (Accessibility XXXL).
    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    #endif

    /// Fails for every issue on the current screen of `app` that is not an exception. An
    /// exception without a reason, or one that matches nothing, fails too.
    @MainActor
    static func check(_ app: XCUIApplication, exceptions: [Exception] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try issues(app)
        for exception in exceptions {
            if exception.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTFail("Layout exception for '\(exception.element)' has no reason.", file: file, line: line)
            }
            if !found.contains(where: { $0.element == exception.element || $0.other == exception.element }) {
                XCTFail("Layout exception for '\(exception.element)' matches no issue: remove it.", file: file, line: line)
            }
        }
        for issue in found where !exceptions.contains(where: { $0.element == issue.element || $0.element == issue.other }) {
            XCTFail("Layout: \(issue)", file: file, line: line)
        }
    }

    /// The issues on the current screen, without failing: for tests that assert on them.
    @MainActor
    static func issues(_ app: XCUIApplication) throws -> [Issue] {
        var cut: [Issue] = []
        var texts: [(name: String, frame: CGRect, scroll: Int?)] = []
        var scrolls = 0

        func walk(_ node: XCUIElementSnapshot, bounds: CGRect?, scroll: Int?) {
            let type = node.elementType
            if skipped.contains(type) { return }
            var bounds = bounds, scroll = scroll
            if edges.contains(type), !node.frame.isEmpty {
                bounds = node.frame
            } else if let bounds, !node.frame.isEmpty, !containers.contains(type) {
                if scroll == nil, !bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(node.frame) {
                    cut.append(Issue(kind: .cutByEdge, element: name(node), frame: node.frame, other: nil, otherFrame: bounds))
                }
                if type == .staticText { texts.append((name(node), node.frame, scroll)) }
            }
            if scrolling.contains(type) {
                scrolls += 1
                scroll = scrolls
            }
            for child in node.children { walk(child, bounds: bounds, scroll: scroll) }
        }
        walk(try app.snapshot(), bounds: nil, scroll: nil)

        var overlaps: [Issue] = []
        for (i, a) in texts.enumerated() {
            for b in texts[(i + 1)...] where a.scroll == b.scroll {
                let shared = a.frame.intersection(b.frame)
                guard shared.width > tolerance, shared.height > tolerance,
                      !a.frame.contains(b.frame), !b.frame.contains(a.frame) else { continue }
                overlaps.append(Issue(kind: .textOverText, element: a.name, frame: a.frame, other: b.name, otherFrame: b.frame))
            }
        }
        return cut + overlaps
    }

    #if os(macOS)
    /// Drags the bottom-right corner of the first window up and left, to the window's minimum
    /// size. macOS restores a window's last frame, so a window that does not move may already be
    /// at its minimum: it is grown once to tell. Fails if the window cannot be resized: it is not
    /// resizable (then do not call this), or the drag did not reach it.
    @MainActor
    static func shrinkWindow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 10) else {
            return XCTFail("LayoutAudit.shrinkWindow: the app has no window.", file: file, line: line)
        }
        let before = window.frame
        resize(window, by: CGVector(dx: -before.width, dy: -before.height))
        var after = window.frame
        if after.size == before.size {
            resize(window, by: CGVector(dx: 100, dy: 100))
            let grown = window.frame
            guard grown.size != before.size else {
                return XCTFail("LayoutAudit.shrinkWindow: the window stayed \(text(before)); it is not resizable, or the drag did not reach it.", file: file, line: line)
            }
            resize(window, by: CGVector(dx: -grown.width, dy: -grown.height))
            after = window.frame
        }
        print("LayoutAudit: window shrunk from \(text(before)) to \(text(after))")
    }

    /// Drags the bottom-right corner of `window` by `offset`.
    @MainActor
    static func resize(_ window: XCUIElement, by offset: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        // A click-drag (mouse down, move, up): on macOS 27 a press-drag does not reach the window.
        corner.click(forDuration: 0.5, thenDragTo: corner.withOffset(offset))
    }
    #endif

    /// Content past the edge of these is cut.
    private static let edges: Set<XCUIElement.ElementType> = [.window, .sheet, .popover, .dialog, .alert]
    /// Content past the edge of these is scrolled away on purpose.
    private static let scrolling: Set<XCUIElement.ElementType> = [.scrollView, .table, .collectionView, .outline, .browser, .textView, .webView]
    /// Layout containers: their frame can exceed the window without anything visible being cut.
    private static let containers: Set<XCUIElement.ElementType> = [.application, .other, .group, .layoutArea, .layoutItem, .splitGroup, .scrollBar]
    /// System UI the app does not lay out.
    private static let skipped: Set<XCUIElement.ElementType> = [.menuBar, .menu, .menuBarItem, .statusBar, .keyboard]
    /// Points of slack for rounding: a frame this far past an edge is not cut.
    private static let tolerance: CGFloat = 1

    private static func name(_ node: XCUIElementSnapshot) -> String {
        if !node.identifier.isEmpty { return node.identifier }
        if !node.label.isEmpty { return node.label }
        if let value = node.value as? String, !value.isEmpty { return value }
        return "\(node.elementType) at \(text(node.frame))"
    }

    fileprivate static func edges(of frame: CGRect, in bounds: CGRect) -> String {
        var sides: [String] = []
        if frame.minX < bounds.minX - tolerance { sides.append("left") }
        if frame.maxX > bounds.maxX + tolerance { sides.append("right") }
        if frame.minY < bounds.minY - tolerance { sides.append("top") }
        if frame.maxY > bounds.maxY + tolerance { sides.append("bottom") }
        return sides.joined(separator: " and ")
    }

    fileprivate static func text(_ r: CGRect) -> String {
        func n(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v)) }
        return "(\(n(r.minX)), \(n(r.minY)), \(n(r.width))x\(n(r.height)))"
    }
}
