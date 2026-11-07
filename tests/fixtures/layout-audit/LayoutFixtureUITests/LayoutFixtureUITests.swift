import XCTest

/// The template helper on the fixture, on macOS (at the smallest window) and on an iOS
/// simulator: the audit finds the cut buttons and the overlapping labels and nothing in the
/// scrolling list; the fixed screen passes.
final class LayoutFixtureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = [], smallest: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        #if os(macOS)
        if smallest { LayoutAudit.shrinkWindow(app) }
        #endif
        return app
    }

    @MainActor
    func testTheAuditFindsTheCutButtonsAndTheOverlap() throws {
        let issues = try LayoutAudit.issues(launch())
        print("LayoutAudit negative control:", issues.map(\.description))
        let cut = Set(issues.filter { $0.kind == .cutByEdge }.map(\.element))
        XCTAssertEqual(cut, ["play", "repeat"], "\(issues)")
        let overlaps = issues.filter { $0.kind == .textOverText }
        XCTAssertEqual(overlaps.map { Set([$0.element, $0.other ?? ""]) }, [["nowPlaying", "upNext"]], "\(issues)")
    }

    @MainActor
    func testTheFixedScreenPasses() throws {
        try LayoutAudit.check(launch(["-fixed"]))
    }

    @MainActor
    func testAnExceptionCoversOnlyItsElement() throws {
        let app = launch()
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("is cut by") }
        XCTExpectFailure("play and repeat are still cut", options: options) {
            try? LayoutAudit.check(app, exceptions: [.init(element: "upNext", reason: "fixture: the overlap the negative control expects")])
        }
    }

    @MainActor
    func testAnExceptionNeedsAReasonAndAnIssue() throws {
        let app = launch(["-fixed"])
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("has no reason") || $0.compactDescription.contains("matches no issue") }
        XCTExpectFailure("an exception with no reason, on a screen with no issue", options: options) {
            try? LayoutAudit.check(app, exceptions: [.init(element: "upNext", reason: " ")])
        }
    }

    #if os(macOS)
    @MainActor
    func testInAWideWindowTheButtonsFit() throws {
        let app = launch(smallest: false)
        // macOS restores the last frame, which may be the minimum from another test.
        LayoutAudit.resize(app.windows.firstMatch, by: CGVector(dx: 600, dy: 100))
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 600)
        let issues = try LayoutAudit.issues(app)
        XCTAssertFalse(issues.contains { $0.kind == .cutByEdge }, "\(issues)")
    }
    #endif

    #if os(iOS)
    @MainActor
    func testTheLargestTextStillShowsTheOverlap() throws {
        let issues = try LayoutAudit.issues(launch(LayoutAudit.largestText))
        print("LayoutAudit largest text:", issues.map(\.description))
        XCTAssertTrue(issues.contains { $0.kind == .textOverText && $0.element == "nowPlaying" }, "\(issues)")
    }
    #endif
}
