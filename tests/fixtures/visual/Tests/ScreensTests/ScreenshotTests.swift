import Foundation
import SwiftUI
import Testing
@testable import Screens

// What a project writes, one capture per screen, and checks of what the helper saves.
@MainActor
struct ScreenshotTests {
    @Test func artists() {
        #expect(Screenshot.capture("ArtistsView") { ArtistsView() } == [])
    }

    @Test func albums() {
        #expect(Screenshot.capture("AlbumsView") { AlbumsView() } == [])
    }

    @Test func savesMinAndDefaultInBothAppearancesWithMetadata() throws {
        let out = try temporaryFolder()
        #expect(Screenshot.capture("ArtistsView", output: out) { ArtistsView() } == [])
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names == [
            "ArtistsView-macos-360x420-dark.json", "ArtistsView-macos-360x420-dark.png",
            "ArtistsView-macos-360x420-light.json", "ArtistsView-macos-360x420-light.png",
            "ArtistsView-macos-600x420-dark.json", "ArtistsView-macos-600x420-dark.png",
            "ArtistsView-macos-600x420-light.json", "ArtistsView-macos-600x420-light.png",
        ])
        let data = try Data(contentsOf: out.appendingPathComponent("ArtistsView-macos-360x420-dark.json"))
        let info = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(info["platform"] as? String == "macos")
        #expect(info["appearance"] as? String == "dark")
        #expect(info["size"] as? String == "360x420")
        #expect(info["source"] as? String == "Sources/Screens/ArtistsView.swift")
        // Relative to the project root: the metadata can be committed, so it never holds the
        // absolute path of the test file on this Mac.
        #expect(info["test"] as? String == "Tests/ScreensTests/ScreenshotTests.swift")
        #expect(Screenshot.testPath("/no/project/above/here/SomeTests.swift") == "SomeTests.swift")
        let scale = try #require(info["scale"] as? Double)
        let image = try #require(NSImage(contentsOf: out.appendingPathComponent("ArtistsView-macos-360x420-dark.png")))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == Int(360 * scale))
        #expect(rep.pixelsHigh == Int(420 * scale))
    }

    // A folder that exists and has no project above it (no .git, no config, no contract): the
    // search for the project root ends at the root of the disk. It used to go on for ever
    // there, since a folder URL asked for its parent at "/" answers "/../", never "/" again.
    @Test(.timeLimit(.minutes(1))) func theSearchForTheProjectEndsAtTheRootOfTheDisk() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("no-project-\(UUID().uuidString)/Tests/AppTests")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(Screenshot.root(from: outside) == nil)
        #expect(Screenshot.folder(from: outside) == nil)
        #expect(Snapshot.folders(from: outside) == nil)
        #expect(Snapshot.verify("Loose", sizes: ["120x40"], file: "/no/project/above/here/LooseTests.swift") { Text("Loose") }
            == ["No project root found above /no/project/above/here/LooseTests.swift: pass baselines: and output:."])
    }

    @Test func explicitSizesAndStateNameTheFiles() throws {
        let out = try temporaryFolder()
        let problems = Screenshot.capture("Badge", sizes: ["200"], state: "long-text", output: out) {
            Text("A long badge title that wraps onto more lines").padding()
        }
        #expect(problems == [])
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".png") }.sorted()
        #expect(names == ["Badge-long-text-macos-200-dark.png", "Badge-long-text-macos-200-light.png"])
    }

    @Test func aBlankImageIsReported() throws {
        let out = try temporaryFolder()
        let problems = Screenshot.capture("Empty", sizes: ["100x100"], output: out) {
            Color(nsColor: .windowBackgroundColor)
        }
        #expect(problems.count == 2)
        #expect(problems.first?.contains("the image is blank") == true)
    }

    // SH46-01: a view of one color is a valid capture; only an image like an empty window is blank.
    @Test func aSingleColorViewIsSaved() throws {
        let out = try temporaryFolder()
        #expect(Screenshot.capture("Swatch", sizes: ["80x40"], output: out) { Color.red } == [])
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Swatch-macos-80x40-light.png").path))
    }

    // SH46-04: explicit sizes still record the screen's source file, from its row or from source:.
    @Test func explicitSizesKeepTheSourceFile() throws {
        let out = try temporaryFolder()
        #expect(Screenshot.capture("ArtistsView", sizes: ["300"], output: out) { ArtistsView() } == [])
        #expect(try info(out, "ArtistsView-macos-300-light")["source"] as? String == "Sources/Screens/ArtistsView.swift")
        #expect(Screenshot.capture("Badge", sizes: ["120"], source: "Sources/Badge.swift", output: out) { Text("New") } == [])
        #expect(try info(out, "Badge-macos-120-light")["source"] as? String == "Sources/Badge.swift")
    }

    // SH46-03: a contract that cannot be read names the ways out.
    @Test func anUnreadableContractNamesTheRemedies() {
        let missing = URL(fileURLWithPath: "/nonexistent/LAYOUT_CONTRACT.md")
        let problems = Screenshot.capture("ArtistsView", contract: missing) { ArtistsView() }
        #expect(problems.count == 1)
        #expect(problems.first?.contains("pass sizes:") == true)
        #expect(problems.first?.contains("sandboxed") == true)
    }

    @Test func aMissingRowIsReported() {
        let problems = Screenshot.capture("SettingsView") { EmptyView() }
        #expect(problems == ["LAYOUT_CONTRACT.md has no row with SettingsView as View: add one, or pass sizes:."])
    }

    @Test func aBadSizeIsReported() {
        #expect(Screenshot.capture("Badge", sizes: ["wide"]) { EmptyView() } == ["Badge: 'wide' is not a size."])
    }

    @Test func screenshotsPathInTheConfigIsRead() throws {
        let root = try temporaryFolder()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Tests"), withIntermediateDirectories: true)
        try #"{"screenshots":{"path":"review/shots"}}"#.write(to: root.appendingPathComponent(".claude/swift-harness.json"), atomically: true, encoding: .utf8)
        #expect(Screenshot.folder(from: root.appendingPathComponent("App/Tests")) == root.appendingPathComponent("review/shots"))
    }

    private func info(_ folder: URL, _ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
