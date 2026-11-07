import Components
import SwiftUI
import Testing

@MainActor
struct SnapshotTests {
    @Test func badge() { #expect(Snapshot.verify("Badge", sizes: ["120x40"]) { Badge(text: "3") } == []) }
}
