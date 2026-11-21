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

    #if os(macOS)
    /// Presented UI at the smallest window: the wide popover and the menu with long items stick out
    /// of the window, and the dropdown at a fixed offset is cut by its right edge; the short menu
    /// passes.
    @MainActor
    func testWhatSticksOutOfTheWindowIsFound() throws {
        let app = launch(["-presented"])
        let found = try LayoutAudit.presentedIssues(app, controls: ["actions", "more", "sort", "export"], shrink: false)
        print("LayoutAudit presented negative control:", found.map { "\($0.control): \($0.issue)" })
        // The tree with the popover and a menu open, on the CI log, for when this fails.
        for id in ["more", "export"] {
            app.descendants(matching: .any).matching(identifier: id).firstMatch.click()
            sleep(1)
            print("LayoutAudit tree with '\(id)' open:\n\(app.debugDescription)")
            app.typeKey(.escape, modifierFlags: [])
            sleep(1)
        }
        XCTAssertEqual(Set(found.map(\.control)), ["more", "sort", "export"], "\(found)")
        XCTAssertTrue(found.contains { $0.control == "more" && $0.issue.kind == .outsideWindow }, "\(found)")
        XCTAssertTrue(found.contains { $0.control == "sort" && $0.issue.kind == .cutByEdge }, "\(found)")
        XCTAssertTrue(found.contains { $0.control == "export" && $0.issue.kind == .outsideWindow }, "\(found)")
    }

    /// The same screen fixed passes, opened from the fixture's layout contract.
    @MainActor
    func testWhatFitsPassesFromTheContract() throws {
        try LayoutAudit.checkPresented(launch(["-presented", "-fixed"], smallest: false))
    }

    /// checkPresented fails for each one that sticks out.
    @MainActor
    func testCheckPresentedFailsForWhatSticksOut() throws {
        let app = launch(["-presented"], smallest: false)
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { ["opening 'more'", "opening 'sort'", "opening 'export'"].contains(where: $0.compactDescription.contains) }
        XCTExpectFailure("the wide popover and the dropdown past the edge", options: options) {
            try? LayoutAudit.checkPresented(app)
        }
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
