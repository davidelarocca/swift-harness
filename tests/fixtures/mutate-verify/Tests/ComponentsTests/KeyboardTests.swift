import Components
import SwiftUI
import Testing

@MainActor
final class Counter { var value = 0 }

@MainActor
@Suite(.serialized)
struct KeyboardTests {
    @Test func returnSavesAndEscapeCancels() {
        let saved = Counter(), cancelled = Counter()
        let keys = KeyboardCheck.host { SaveBar(onSave: { saved.value += 1 }, onCancel: { cancelled.value += 1 }) }
        defer { keys.close() }
        keys.press(.return)
        #expect(saved.value == 1)
        keys.press(.escape)
        #expect(cancelled.value == 1)
    }
}
