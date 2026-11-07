import Testing
@testable import Feature

@MainActor struct LayoutTests {
    @Test func library() { #expect(LayoutContract.check("LibraryView") { LibraryView() } == []) }
}
