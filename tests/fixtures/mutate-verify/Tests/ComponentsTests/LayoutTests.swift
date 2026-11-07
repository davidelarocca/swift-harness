import Components
import SwiftUI
import Testing

@MainActor
struct LayoutTests {
    @Test func library() { #expect(LayoutContract.check("LibraryView") { LibraryView() } == []) }
}
