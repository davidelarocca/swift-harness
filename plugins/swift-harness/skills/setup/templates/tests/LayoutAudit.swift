// Layout audit for UI tests, from the swift-harness setup templates (#69).
// Copy into a UI test target (XCUITest), macOS or iOS. It reads the accessibility tree of the
// launched app once and fails with every fault it finds:
// - an element cut by the edge of its window (or sheet, popover), outside any scroll view;
// - a text over another text, neither containing the other;
// - on macOS, a popover, sheet, dialog, alert, or the menu of a menu button or pop-up button,
//   that sticks out of the app window it belongs to. On the Mac these are windows of their own,
//   placed to stay on the screen, not in the app window: near the edge of a small window they
//   stick out. The menu bar and a context menu opened at the pointer are not checked: the app
//   does not place them.
//
// `checkPresented` opens what a screen presents, one at a time, at the smallest window, and
// checks each: the controls named in backticks in the "Opened from" column of the Presented UI
// table in docs/LAYOUT_CONTRACT.md, and any passed as `controls:` (accessibility identifiers).
//
//     func testWhatTheLibraryOpensStaysInTheWindow() throws {
//         let app = XCUIApplication()
//         app.launch()
//         try LayoutAudit.checkPresented(app)           // macOS: shrinks the window first
//     }
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

// A helper kept as shipped, so that a later version can be compared with it: no formatter
// rewrites it (SwiftFormat, swift-format) and its style rules are off here; the project's
// other lint rules still apply.
// swiftformat:disable all
// swift-format-ignore-file
// swiftlint:disable identifier_name large_tuple line_length nesting

import XCTest

enum LayoutAudit {
    struct Issue: CustomStringConvertible {
        enum Kind { case cutByEdge, textOverText, outsideWindow }
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
            case .outsideWindow:
                return "'\(element)' sticks out of its window on the \(LayoutAudit.edges(of: frame, in: otherFrame)): \(LayoutAudit.text(frame)) in the window \(LayoutAudit.text(otherFrame))"
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
        var outside: [Issue] = []
        var texts: [(name: String, frame: CGRect, scroll: Int?)] = []
        var scrolls = 0
        let root = try app.snapshot()
        // The app's main window: the largest of its windows. A popover or a menu can show in the
        // tree as a window of its own; it is then measured against this one.
        let windows = root.children.filter { $0.elementType == .window && !$0.frame.isEmpty }.map(\.frame)
        let mainWindow = windows.max { $0.width * $0.height < $1.width * $1.height }

        func walk(_ node: XCUIElementSnapshot, parent: XCUIElement.ElementType?, window: CGRect?, bounds: CGRect?, scroll: Int?) {
            let type = node.elementType
            // The menu of a menu button or pop-up button is placed from its control; other menus
            // (the menu bar's, a context menu at the pointer) are not the app's to place.
            let controlMenu = type == .menu && (parent == .menuButton || parent == .popUpButton)
            if skipped.contains(type), !controlMenu { return }
            var bounds = bounds, scroll = scroll, window = window
            #if os(macOS)
            if presented.contains(type) || controlMenu, !node.frame.isEmpty,
               let owner = window.flatMap({ ownWindow($0, of: node.frame) ? nil : $0 }) ?? mainWindow,
               !owner.insetBy(dx: -tolerance, dy: -tolerance).contains(node.frame) {
                outside.append(Issue(kind: .outsideWindow, element: name(node), frame: node.frame, other: nil, otherFrame: owner))
            }
            #endif
            // The top-level window a node is in: the one a presented element must stay inside.
            if type == .window, parent == .application, !node.frame.isEmpty { window = node.frame }
            if controlMenu, !node.frame.isEmpty {
                bounds = node.frame
            } else if edges.contains(type), !node.frame.isEmpty {
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
            for child in node.children { walk(child, parent: type, window: window, bounds: bounds, scroll: scroll) }
        }
        walk(root, parent: nil, window: nil, bounds: nil, scroll: nil)

        var overlaps: [Issue] = []
        for (i, a) in texts.enumerated() {
            for b in texts[(i + 1)...] where a.scroll == b.scroll {
                let shared = a.frame.intersection(b.frame)
                guard shared.width > tolerance, shared.height > tolerance,
                      !a.frame.contains(b.frame), !b.frame.contains(a.frame) else { continue }
                overlaps.append(Issue(kind: .textOverText, element: a.name, frame: a.frame, other: b.name, otherFrame: b.frame))
            }
        }
        return outside + cut + overlaps
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

    /// Opens, one at a time, each control named in `controls` (accessibility identifiers) and in
    /// the "Opened from" column of the Presented UI table of the layout contract (in backticks),
    /// at the window's smallest size unless `shrink` is false, and fails for what it opened that
    /// sticks out of the window, is cut, or overlaps a text: issues that were on the screen before
    /// it opened are not counted. Each is closed again with Escape, or a second click.
    @MainActor
    static func checkPresented(_ app: XCUIApplication, controls: [String] = [], contract: URL? = nil, shrink: Bool = true, exceptions: [Exception] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try presentedIssues(app, controls: controls, contract: contract, shrink: shrink, file: file, line: line)
        for exception in exceptions {
            if exception.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTFail("Layout exception for '\(exception.element)' has no reason.", file: file, line: line)
            }
            if !found.contains(where: { [$0.control, $0.issue.element, $0.issue.other].contains(exception.element) }) {
                XCTFail("Layout exception for '\(exception.element)' matches no issue: remove it.", file: file, line: line)
            }
        }
        for (control, issue) in found where !exceptions.contains(where: { [control, issue.element, issue.other].contains($0.element) }) {
            XCTFail("Layout, opening '\(control)': \(issue)", file: file, line: line)
        }
    }

    /// What `checkPresented` opens and measures, without failing for the issues: for tests that
    /// assert on them. A control that is missing, opens nothing or does not close still fails.
    @MainActor
    static func presentedIssues(_ app: XCUIApplication, controls: [String] = [], contract: URL? = nil, shrink: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> [(control: String, issue: Issue)] {
        if shrink { shrinkWindow(app, file: file, line: line) }
        let table = presentedControls(contract ?? locateContract(from: URL(fileURLWithPath: "\(file)").deletingLastPathComponent()))
        for note in table.notes { print("LayoutAudit: \(note)") }
        let ids = controls + table.ids.filter { !controls.contains($0) }
        guard !ids.isEmpty else {
            XCTFail("LayoutAudit.checkPresented: nothing to open. Name each control in backticks in the Opened from column of the Presented UI table in docs/LAYOUT_CONTRACT.md (its accessibility identifier), or pass controls:.", file: file, line: line)
            return []
        }
        let before = Set(try issues(app).map(\.description))
        var found: [(control: String, issue: Issue)] = []
        for id in ids {
            let control = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard control.waitForExistence(timeout: 5) else {
                XCTFail("LayoutAudit.checkPresented: no element '\(id)' on the screen.", file: file, line: line)
                continue
            }
            let closed = try size(app)
            control.click()
            var opened = false
            for _ in 0..<15 where !opened {
                usleep(200_000)
                opened = try size(app) != closed
            }
            guard opened else {
                XCTFail("LayoutAudit.checkPresented: '\(id)' opened nothing.", file: file, line: line)
                continue
            }
            usleep(500_000) // the opening animation
            let new = try issues(app).filter { !before.contains($0.description) }
            print("LayoutAudit: opened '\(id)': \(new.isEmpty ? "inside the window" : new.map(\.description).joined(separator: "; "))")
            found += new.map { (control: id, issue: $0) }
            app.typeKey(.escape, modifierFlags: [])
            usleep(500_000)
            if try size(app) != closed {
                if control.isHittable { control.click() }
                usleep(500_000)
                if try size(app) != closed {
                    XCTFail("LayoutAudit.checkPresented: what '\(id)' opened did not close with Escape or a second click; the next ones are measured with it open.", file: file, line: line)
                }
            }
        }
        return found
    }

    /// The number of elements in the tree: it changes when something opens or closes.
    @MainActor
    private static func size(_ app: XCUIApplication) throws -> Int {
        func count(_ node: XCUIElementSnapshot) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
        return count(try app.snapshot())
    }

    /// The identifiers in backticks in the "Opened from" column of the Presented UI table, and a
    /// note for each row without one.
    static func presentedControls(_ contract: URL?) -> (ids: [String], notes: [String]) {
        guard let contract, let text = try? String(contentsOf: contract, encoding: .utf8) else { return ([], []) }
        var ids: [String] = [], notes: [String] = []
        var inSection = false, column: Int?
        for raw in text.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("#") { inSection = row.range(of: #"^#+\s*Presented UI\b"#, options: .regularExpression) != nil; column = nil; continue }
            guard inSection, row.hasPrefix("|") else { continue }
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if column == nil {
                column = cells.firstIndex { $0.lowercased() == "opened from" }
                continue
            }
            guard let column, column < cells.count, !cells.allSatisfy({ $0.isEmpty || $0.allSatisfy { "-: ".contains($0) } }) else { continue }
            let found = cells[column].components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 && !$0.element.isEmpty }.map(\.element)
            if found.isEmpty {
                notes.append("not opened: '\(cells.first ?? "")' in the Presented UI table names no control in backticks in Opened from")
            }
            ids += found.filter { !ids.contains($0) }
        }
        return (ids, notes)
    }

    /// `layout.path` from the first .claude/swift-harness.json above `folder`, else the first
    /// docs/LAYOUT_CONTRACT.md above it.
    static func locateContract(from folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        while true {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(".claude/swift-harness.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dir.appendingPathComponent(((json["layout"] as? [String: Any])?["path"] as? String) ?? "docs/LAYOUT_CONTRACT.md")
            }
            let contract = dir.appendingPathComponent("docs/LAYOUT_CONTRACT.md")
            if FileManager.default.fileExists(atPath: contract.path) { return contract }
            let parent = dir.deletingLastPathComponent()
            if dir.path == "/" || parent.path == dir.path { return nil }
            dir = parent
        }
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
    /// Presented by the app over a window: on macOS each must lie inside the window it belongs to.
    private static let presented: Set<XCUIElement.ElementType> = [.sheet, .popover, .dialog, .alert]
    /// Content past the edge of these is scrolled away on purpose.
    private static let scrolling: Set<XCUIElement.ElementType> = [.scrollView, .table, .collectionView, .outline, .browser, .textView, .webView]
    /// Layout containers: their frame can exceed the window without anything visible being cut.
    private static let containers: Set<XCUIElement.ElementType> = [.application, .other, .group, .layoutArea, .layoutItem, .splitGroup, .scrollBar]
    /// System UI the app does not lay out.
    private static let skipped: Set<XCUIElement.ElementType> = [.menuBar, .menu, .menuBarItem, .statusBar, .keyboard]
    /// Points of slack for rounding: a frame this far past an edge is not cut.
    private static let tolerance: CGFloat = 1

    /// True when `window` is no more than the window of a presented element itself (a popover's
    /// own window, its arrow included), not the app window it belongs to.
    private static func ownWindow(_ window: CGRect, of frame: CGRect) -> Bool {
        window.insetBy(dx: -tolerance, dy: -tolerance).contains(frame) && window.width <= frame.width + 40 && window.height <= frame.height + 40
    }

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

// swiftlint:enable identifier_name large_tuple line_length nesting
