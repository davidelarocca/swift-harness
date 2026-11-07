// Focus order for UI tests, from the swift-harness setup templates (#52).
// Copy into a UI test target (XCUITest), next to AccessibilityAudit.swift. Keep this header so
// updates can be compared.
//
// Presses Tab on the screen a launched app shows and checks that keyboard focus visits the
// controls in the order given (accessibility identifiers), then comes back to the first, and
// that Shift-Tab goes back. A control missing from the Tab loop, an extra one, or a different
// order fails with the order measured:
//
//     func testLibraryFocusOrder() throws {
//         let app = XCUIApplication()
//         app.launch()
//         try FocusOrder.check(app, ["search", "sort", "play", "shuffle", "trackList"])
//     }
//
// UI tests run in `scripts/verify.sh full`, not in `fast`.
//
// macOS puts buttons, toggles and other controls in the Tab loop only when Keyboard navigation
// is on (System Settings > Keyboard); with it off, only text fields and lists take focus. So the
// result depends on the Mac: with the setting off, check() skips the test (XCTSkip), and the run
// shows it as skipped, not passed. On CI, turn it on before the tests:
// `defaults write -g AppleKeyboardUIMode -int 2`.
//
// macOS has no public API for keyboard focus in UI tests (XCUIElement.hasFocus is iOS and tvOS
// only, and the snapshot attribute stays empty on macOS 27). This reads the
// `hasKeyboardFocus` attribute through a query, which works on macOS 26 and 27 but is not
// documented. When no element reports focus, check() fails saying so rather than passing.

// A helper kept as shipped, so its style rules are off here; the project's own rules still apply.
// swiftlint:disable line_length

import XCTest

enum FocusOrder {
    /// Whether Keyboard navigation is on for this user: controls are in the Tab loop.
    static var keyboardNavigationEnabled: Bool {
        (UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2) != 0
    }

    /// The element that has keyboard focus now: its identifier, else its label, else its type.
    @MainActor
    static func focused(_ app: XCUIApplication) -> String? {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard element.exists else { return nil }
        if !element.identifier.isEmpty { return element.identifier }
        if !element.label.isEmpty { return "'\(element.label)'" }
        return "an element of type \(element.elementType.rawValue) without identifier"
    }

    /// Fails unless Tab visits `expected` in this order and wraps, and Shift-Tab goes back.
    @MainActor
    static func check(
        _ app: XCUIApplication,
        _ expected: [String],
        reverse: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard keyboardNavigationEnabled else {
            throw XCTSkip("Keyboard navigation is off (System Settings > Keyboard), so buttons and toggles are not in the Tab loop: the focus order was not measured. Turn it on to run this check; on CI: defaults write -g AppleKeyboardUIMode -int 2.")
        }
        guard let first = expected.first else { return }
        for id in expected where !app.descendants(matching: .any)[id].firstMatch.exists {
            XCTFail("FocusOrder: no element with identifier '\(id)' on this screen.", file: file, line: line)
            return
        }

        // Tab until the first control has focus; the window may start anywhere in the loop.
        var visited: [String] = []
        let limit = expected.count * 2 + 2
        while focused(app) != first, visited.count < limit {
            app.typeKey(.tab, modifierFlags: [])
            visited.append(focused(app) ?? "nothing")
        }
        if visited.allSatisfy({ $0 == "nothing" }), focused(app) == nil {
            XCTFail("FocusOrder: no element reports keyboard focus after \(visited.count) Tab presses. The hasKeyboardFocus attribute may not be available in this Xcode: the focus order was not measured.", file: file, line: line)
            return
        }
        guard focused(app) == first else {
            XCTFail("FocusOrder: '\(first)' never got focus. Tab visited: \(visited.joined(separator: " → ")).", file: file, line: line)
            return
        }

        // One full loop: every expected control in order, then back to the first.
        var measured = [first]
        for index in 1...expected.count {
            app.typeKey(.tab, modifierFlags: [])
            let now = focused(app) ?? "a stop with no accessibility element (an extra .focusable() on a control that already takes focus, or a focusable container)"
            measured.append(now)
            let want = expected[index % expected.count]
            guard now == want else {
                XCTFail("FocusOrder: after '\(measured[measured.count - 2])', Tab moved focus to \(now), expected '\(want)'. Measured: \(measured.joined(separator: " → ")). Expected: \((expected + [first]).joined(separator: " → ")).", file: file, line: line)
                return
            }
        }

        if reverse, expected.count > 1 {
            app.typeKey(.tab, modifierFlags: .shift)
            let back = focused(app) ?? "a stop with no accessibility element"
            if back != expected[expected.count - 1] {
                XCTFail("FocusOrder: Shift-Tab from '\(first)' moved focus to \(back), expected '\(expected[expected.count - 1])'.", file: file, line: line)
            }
        }
    }
}

// swiftlint:enable line_length
