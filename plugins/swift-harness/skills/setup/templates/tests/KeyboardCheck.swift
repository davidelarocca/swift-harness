// KeyboardCheck.swift, from the swift-harness setup templates (#52).
// Copy it into a test target that can import SwiftUI and the components (the one with
// LayoutContract.swift works). Keep this header so updates can be compared.
//
// Presses keys on a view in a real window, so a test can check that every action of a shared
// component works without a pointer. Call it from a @MainActor test and assert on what the
// action did:
//
//     let keys = KeyboardCheck.host { SaveBar(onSave: { saved = true }, onCancel: { cancelled = true }) }
//     defer { keys.close() }
//     keys.press(.return)                      // .keyboardShortcut(.defaultAction)
//     keys.press(.escape)                      // .cancelAction, .onExitCommand, onKeyPress(.escape)
//     keys.press("k", modifiers: .command)     // .keyboardShortcut("k")
//     keys.press(.downArrow)                   // onKeyPress(.downArrow), list selection
//     XCTAssertTrue(saved)
//
// With Swift Testing, put these tests in a `@Suite(.serialized)`: each press runs the main run
// loop, and parallel tests would start inside it, with their own windows.
//
// Keep the state a component binds to in @State, in a small wrapper view, and report it out
// with onChange: a Binding(get:set:) over a plain variable keeps the value SwiftUI read last.
//
// A key goes to the view SwiftUI focuses first in the window, as in the app: with several
// focusable views, host the one under test, or give the component a way to set its focus.
// Shortcuts (defaultAction, cancelAction, Command combinations) work wherever focus is.
//
// When no view takes the focus, a key that is not a shortcut reaches nothing, and the test
// fails on its assertion with no word about why. `focused` says whether a view took it, and
// the first such key pressed without one prints a note (`focusNote`). The usual reason: standard controls
// (Slider, Toggle, Picker, Button) take the focus only while "Keyboard navigation" is on in
// System Settings > Keyboard, in a test as in the app, and a test cannot turn it on (measured
// on macOS 27, with `swift test` and with `xcodebuild test`). A component whose keys must
// work whatever that setting takes the focus itself: `.focusable(interactions: .edit)` with
// `.onKeyPress`. Assert it when a test depends on it: `#expect(keys.focused)`.
//
// What it cannot check, measured on macOS 26 and 27: Tab and focus order (a test process has no key
// view loop: Tab does not move focus), the app's menu commands, and shortcuts that differ only
// by Shift (in a test process SwiftUI can take Command-F for a Command-Shift-F shortcut on the
// same letter, and the other way round; the real app tells them apart). Check those in a UI
// test: FocusOrder.swift for the focus order, XCUIApplication.typeKey for the shortcuts.
// Letters map to their key on a US keyboard; other layouts match by character.

// A helper kept as shipped, so that a later version can be compared with it: no formatter
// rewrites it (SwiftFormat, swift-format) and its style rules are off here; the project's
// other lint rules still apply.
// swiftformat:disable all
// swift-format-ignore-file
// swiftlint:disable large_tuple

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class KeyboardCheck {
    enum Key {
        case `return`, escape, tab, space, delete, upArrow, downArrow, leftArrow, rightArrow
        case character(String)
    }

    /// Seconds to let SwiftUI handle each key and update.
    static let settle: TimeInterval = 0.1

    let window: NSWindow
    private var noted = false

    private init(window: NSWindow) { self.window = window }

    static func host<Content: View>(
        width: CGFloat = 480,
        height: CGFloat = 320,
        @ViewBuilder _ make: () -> Content
    ) -> KeyboardCheck {
        _ = NSApplication.shared
        let window = Window(
            contentRect: CGRect(x: -6000, y: -6000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Closed by close(); released by this object, not by AppKit (a double release crashes).
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: make())
        window.orderFrontRegardless()
        window.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return KeyboardCheck(window: window)
    }

    /// True when a view of the hosted content has the keyboard focus: a key that is not a
    /// shortcut goes to it. False when the focus stayed on the window: such a key reaches nothing.
    var focused: Bool {
        guard let responder = window.firstResponder else { return false }
        return responder !== window
    }

    /// Why keys may reach nothing, when no view has the focus; nil when one has it.
    var focusNote: String? {
        if focused { return nil }
        let setting = NSApp.isFullKeyboardAccessEnabled
            ? "\"Keyboard navigation\" is on, so the hosted view has nothing that can take the focus"
            : "\"Keyboard navigation\" is off on this Mac (System Settings > Keyboard), so standard controls"
                + " (Slider, Toggle, Picker, Button) do not take it, or the hosted view has nothing that can"
        return "no view took the focus: \(setting)."
            + " Keys that are not shortcuts (Return for .defaultAction, Escape for .cancelAction, Command combinations)"
            + " reach nothing. A component whose keys must work whatever the setting takes the focus itself:"
            + " .focusable(interactions: .edit) with .onKeyPress."
    }

    func press(_ character: String, modifiers: NSEvent.ModifierFlags = []) {
        press(.character(character), modifiers: modifiers)
    }

    func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) {
        let (characters, code, extra) = Self.event(for: key)
        let flags = modifiers.union(extra)
        // Said once per window, and only for a key that needs the focus: a shortcut does not.
        var shortcut = flags.contains(.command)
        if case .return = key { shortcut = true }
        if case .escape = key { shortcut = true }
        if !shortcut, !noted, let note = focusNote {
            noted = true
            print("swift-harness keyboard: \(note)")
        }
        let shown = flags.contains(.shift) ? characters.uppercased() : characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: shown, charactersIgnoringModifiers: shown,
                isARepeat: false, keyCode: code
            ) else { continue }
            window.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(Self.settle))
    }

    func close() { window.close() }

    private static func event(for key: Key) -> (String, UInt16, NSEvent.ModifierFlags) {
        func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt16(scalar)).map(Character.init) ?? " ") }
        switch key {
        case .return: return ("\r", 36, [])
        case .escape: return ("\u{1b}", 53, [])
        case .tab: return ("\t", 48, [])
        case .space: return (" ", 49, [])
        case .delete: return ("\u{7f}", 51, [])
        case .upArrow: return (function(NSUpArrowFunctionKey), 126, [.numericPad, .function])
        case .downArrow: return (function(NSDownArrowFunctionKey), 125, [.numericPad, .function])
        case .leftArrow: return (function(NSLeftArrowFunctionKey), 123, [.numericPad, .function])
        case .rightArrow: return (function(NSRightArrowFunctionKey), 124, [.numericPad, .function])
        case .character(let text):
            let lower = text.lowercased()
            let index = lower.count == 1 ? usLayout.firstIndex(of: Character(lower)) : nil
            let code = index.map { UInt16(usLayout.distance(from: usLayout.startIndex, to: $0)) }
            return (lower, code ?? 0, [])
        }
    }

    /// Virtual key codes 0-47 of a US keyboard, in order ("\0" where the key is not a character).
    private static let usLayout = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm."

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
#endif

// swiftlint:enable large_tuple
