import AppKit
import Components
import SwiftUI
import Testing

// KeyboardCheck from the setup templates on the fixture components. Each test asserts what the
// action did; the pointer-only card is the negative control: no key reaches its action.

@MainActor
final class Box<Value> { var value: Value; init(_ value: Value) { self.value = value } }

/// The selection lives in @State, as in the app: a Binding(get:set:) over a plain variable keeps
/// the value SwiftUI read last, so a second arrow press would not see the first.
private struct TrackListHost: View {
    let selection: Box<Int>
    let onPlay: (String) -> Void
    let onFind: () -> Void
    @State private var current = 0

    var body: some View {
        TrackList(tracks: ["Intro", "Theme", "Outro"], selection: $current, onPlay: onPlay, onFind: onFind)
            .onChange(of: current) { _, value in selection.value = value }
    }
}

// Serialized: each press runs the main run loop, where parallel tests would start.
@MainActor
@Suite(.serialized)
struct KeyboardTests {
    @Test func returnSavesAndEscapeCancels() {
        let saved = Box(0), cancelled = Box(0)
        let keys = KeyboardCheck.host { SaveBar(onSave: { saved.value += 1 }, onCancel: { cancelled.value += 1 }) }
        defer { keys.close() }
        keys.press(.return)
        #expect(saved.value == 1 && cancelled.value == 0)
        keys.press(.escape)
        #expect(saved.value == 1 && cancelled.value == 1)
    }

    @Test func arrowsMoveTheSelectionAndReturnPlays() {
        let selection = Box(0), played = Box<[String]>([]), found = Box(false)
        let keys = KeyboardCheck.host {
            TrackListHost(selection: selection, onPlay: { played.value.append($0) }, onFind: { found.value = true })
        }
        defer { keys.close() }
        keys.press(.downArrow)
        keys.press(.downArrow)
        keys.press(.upArrow)
        #expect(selection.value == 1)
        keys.press(.return)
        #expect(played.value == ["Theme"])
        keys.press("g", modifiers: .command)
        #expect(!found.value, "Command-G is not the shortcut")
        keys.press("f", modifiers: .command)
        #expect(found.value)
    }

    @Test func escapeClosesTheInspector() {
        let closed = Box(false)
        let keys = KeyboardCheck.host { Inspector(onClose: { closed.value = true }) }
        defer { keys.close() }
        keys.press(.escape)
        #expect(closed.value)
    }

    // With "Keyboard navigation" off (the default, and the runners), a standard control does not
    // take the focus: the helper says so, where a test would only see its assertion fail.
    @Test func aStandardControlWithoutFocusIsSaid() {
        let keys = KeyboardCheck.host { Slider(value: .constant(0.5), in: 0...1) }
        defer { keys.close() }
        #expect((keys.focusNote == nil) == keys.focused)
        guard !NSApp.isFullKeyboardAccessEnabled else { return }
        #expect(!keys.focused)
        #expect(keys.focusNote?.contains("\"Keyboard navigation\" is off on this Mac") == true)
        #expect(keys.focusNote?.contains(".focusable(interactions: .edit)") == true)
        keys.press(.rightArrow) // prints the note once: read it in the test output
        keys.press(.rightArrow)
    }

    @Test func aFocusableComponentHasTheFocusWhateverTheSetting() {
        let pressed = Box(0)
        let keys = KeyboardCheck.host {
            Text("row").focusable().onKeyPress(.downArrow) { pressed.value += 1; return .handled }
        }
        defer { keys.close() }
        #expect(keys.focused)
        #expect(keys.focusNote == nil)
        keys.press(.downArrow)
        #expect(pressed.value == 1)
    }

    @Test func noKeyReachesAPointerOnlyAction() {
        let opened = Box(false)
        let keys = KeyboardCheck.host { PointerOnlyCard(onOpen: { opened.value = true }) }
        defer { keys.close() }
        for key in [KeyboardCheck.Key.return, .space, .escape, .downArrow] { keys.press(key) }
        #expect(!opened.value, "the negative control: a click-only action is not reachable from the keyboard")
    }
}
