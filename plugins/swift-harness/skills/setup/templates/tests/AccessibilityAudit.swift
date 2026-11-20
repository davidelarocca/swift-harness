// Accessibility audit for UI tests, from the swift-harness setup templates (#36).
// Copy into a UI test target (XCUITest). It runs Apple's audit (macOS 14, iOS 17 or later) on
// the screen a launched app shows: missing descriptions, contrast, hit areas, clipped text,
// traits. Every issue fails the test, except the ones listed as exceptions, each with a reason.
//
//     func testLibraryScreen() throws {
//         let app = XCUIApplication()
//         app.launch()
//         try AccessibilityAudit.check(app, exceptions: [
//             .init(element: "waveform", type: .contrast, reason: "decorative, the value is read by the label next to it"),
//         ])
//     }
//
// UI tests run in `scripts/verify.sh full`, not in `fast`.
//
// On macOS the audit also reports parts of the window and screen the system draws, which the
// app cannot fix: the root group of a SwiftUI window, the window buttons, the title text, the
// system menu bar (see `isWindowChrome`). `check` skips exactly these by default and prints
// each one it skips; pass `skipWindowChrome: false` to see them fail.

// A helper kept as shipped, so that a later version can be compared with it: no formatter
// rewrites it (SwiftFormat, swift-format).
// swiftformat:disable all
// swift-format-ignore-file

import XCTest

enum AccessibilityAudit {
    /// An issue accepted on purpose. `element` is the accessibility identifier or label.
    struct Exception {
        let element: String
        let type: XCUIAccessibilityAuditType
        let reason: String
    }

    /// Audits the current screen of `app` and fails for every issue that is not an exception.
    /// An exception without a reason fails too: silencing an issue needs a why.
    @MainActor
    static func check(
        _ app: XCUIApplication,
        types: XCUIAccessibilityAuditType = .all,
        exceptions: [Exception] = [],
        skipWindowChrome: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for exception in exceptions where exception.reason.trimmingCharacters(in: .whitespaces).isEmpty {
            XCTFail("Accessibility exception for '\(exception.element)' has no reason.", file: file, line: line)
        }
        let windows = app.windows.allElementsBoundByIndex.map(\.frame)
        try app.performAccessibilityAudit(for: types) { issue in
            if skipWindowChrome, isWindowChrome(issue, windows: windows) {
                print("AccessibilityAudit: skipped window chrome: \(issue.compactDescription), \(issue.element?.frame ?? .zero)")
                return true
            }
            return exceptions.contains { exception in
                exception.type.contains(issue.auditType) && matches(issue.element, exception.element)
            }
        }
    }

    /// The issues the audit finds, without failing: for tests that assert on them.
    @MainActor
    static func issues(_ app: XCUIApplication, types: XCUIAccessibilityAuditType = .all) throws -> [XCUIAccessibilityAuditIssue] {
        var found: [XCUIAccessibilityAuditIssue] = []
        try app.performAccessibilityAudit(for: types) { issue in
            found.append(issue)
            return true
        }
        return found
    }

    /// The parts of a macOS window and screen the system draws, which no app can fix. Measured
    /// on macOS 26 and 27: the root group that fills a SwiftUI window (no description), the
    /// window buttons at the left of the title bar, the title text (contrast when the window is
    /// not key), and elements of the system menu bar above every window that are not menus or
    /// menu items (the app's own menus stay audited). Toolbar items in the title bar are audited.
    @MainActor
    static func isWindowChrome(_ issue: XCUIAccessibilityAuditIssue, windows: [CGRect]) -> Bool {
        #if os(macOS)
        guard let element = issue.element else { return false }
        let frame = element.frame
        if let top = windows.map(\.minY).min(), frame.maxY <= top,
           element.elementType != .menuBarItem, element.elementType != .menuItem, element.elementType != .menu {
            return true
        }
        for window in windows where window.contains(frame) {
            if issue.auditType == .sufficientElementDescription, element.elementType == .group,
               element.identifier.isEmpty, element.label.isEmpty, frame == window {
                return true
            }
            let titleBar = frame.maxY <= window.minY + 52
            if titleBar, frame.maxX <= window.minX + 90 {
                return true
            }
            if titleBar, issue.auditType == .contrast, element.elementType == .staticText {
                return true
            }
        }
        #endif
        return false
    }

    @MainActor
    private static func matches(_ element: XCUIElement?, _ name: String) -> Bool {
        guard let element else { return false }
        return element.identifier == name || element.label == name
    }
}
