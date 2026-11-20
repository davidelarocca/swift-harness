import Foundation
import SwiftUI
import Testing
@testable import Screens

// The baselines committed in snapshots/ were approved on one Mac: there they are compared,
// elsewhere (GitHub's runners) they are reported as not compared. The other tests make their
// own baselines in a temporary folder, the way /swift-harness:approve-snapshots does.
@MainActor
struct SnapshotTests {
    @Test func gallery() {
        #expect(Snapshot.verify("ArtistsView", sizes: ["360x420"]) { ArtistsView() } == [])
        #expect(Snapshot.verify("Badge", sizes: ["200"], state: "long-text") { badge("A long badge title that wraps onto more lines") } == [])
        #expect(Snapshot.verify("Row", sizes: ["200x40"], locale: "ar") { row } == [])
    }

    @Test func aMissingBaselineFailsAndIsNeverWritten() throws {
        let (baselines, out) = try folders()
        let problems = Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("New") }
        #expect(problems.count == 2)
        #expect(problems.first?.contains("Badge-macos-120-light: no approved baseline") == true)
        #expect(problems.first?.contains("/swift-harness:approve-snapshots") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: baselines.path).isEmpty)
        #expect(try names(out) == [
            "Badge-macos-120-dark.json", "Badge-macos-120-dark.png", "Badge-macos-120-dark.result.json",
            "Badge-macos-120-light.json", "Badge-macos-120-light.png", "Badge-macos-120-light.result.json",
        ])
        #expect(try result(out, "Badge-macos-120-light")["status"] as? String == "missing")
        let info = try json(out.appendingPathComponent("Badge-macos-120-light.json"))
        #expect(info["os"] as? String == Snapshot.osVersion)
        // What an approval copies into the baselines folder, to be committed: no absolute path.
        #expect(info["test"] as? String == "Tests/ScreensTests/SnapshotTests.swift")
    }

    @Test func anApprovedImageMatchesAndLeavesNoCandidate() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("New") }
        try approve(out, baselines)
        #expect(Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("New") } == [])
        #expect(try names(out) == ["Badge-macos-120-dark.result.json", "Badge-macos-120-light.result.json"])
        #expect(try result(out, "Badge-macos-120-dark")["status"] as? String == "passed")
    }

    @Test func aChangedImageFailsWithADiffAndTheRegion() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Badge", sizes: ["120x40"], baselines: baselines, output: out) { badge("New") }
        try approve(out, baselines)
        let problems = Snapshot.verify("Badge", sizes: ["120x40"], baselines: baselines, output: out) { badge("Old") }
        #expect(problems.count == 2)
        #expect(problems.first?.contains("pixels differ") == true)
        #expect(problems.first?.contains("pt from the top left") == true)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Badge-macos-120x40-light.diff.png").path))
        #expect(try result(out, "Badge-macos-120x40-light")["status"] as? String == "failed")
        // The baseline is unchanged: still the approved image.
        #expect(Snapshot.verify("Badge", sizes: ["120x40"], baselines: baselines, output: out) { badge("New") } == [])
    }

    @Test func aSizeChangeIsNamed() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("New") }
        try approve(out, baselines)
        let problems = Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("A much longer title that wraps") }
        #expect(problems.first?.contains("the size changed from 120x") == true)
    }

    @Test func toleranceAllowsSomePixels() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Badge", sizes: ["120x40"], baselines: baselines, output: out) { badge("New") }
        try approve(out, baselines)
        #expect(Snapshot.verify("Badge", sizes: ["120x40"], tolerance: 0.5, baselines: baselines, output: out) { badge("Old") } == [])
    }

    @Test func aBaselineFromAnotherMacIsNotCompared() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("New") }
        try approve(out, baselines)
        for appearance in ["light", "dark"] {
            let url = baselines.appendingPathComponent("Badge-macos-120-\(appearance).json")
            var info = try json(url)
            info["os"] = "13.9"
            try JSONSerialization.data(withJSONObject: info).write(to: url)
        }
        #expect(Snapshot.verify("Badge", sizes: ["120"], baselines: baselines, output: out) { badge("Old") } == [])
        let outcome = try result(out, "Badge-macos-120-light")
        #expect(outcome["status"] as? String == "not-compared")
        #expect((outcome["reason"] as? String)?.contains("made on macOS 13.9") == true)
    }

    @Test func aRightToLeftLocaleIsDrawnRightToLeft() throws {
        let (baselines, out) = try folders()
        _ = Snapshot.verify("Row", sizes: ["200x40"], baselines: baselines, output: out) { row }
        try approve(out, baselines)
        // Same name, so the same baseline: the mirrored layout must not match it.
        try FileManager.default.copyItem(at: baselines.appendingPathComponent("Row-macos-200x40-light.png"),
                                         to: baselines.appendingPathComponent("Row-ar-macos-200x40-light.png"))
        try FileManager.default.copyItem(at: baselines.appendingPathComponent("Row-macos-200x40-light.json"),
                                         to: baselines.appendingPathComponent("Row-ar-macos-200x40-light.json"))
        let problems = Snapshot.verify("Row", sizes: ["200x40"], locale: "ar", baselines: baselines, output: out) { row }
        #expect(problems.first?.hasPrefix("Row-ar-macos-200x40-light:") == true)
        #expect(problems.first?.contains("pixels differ") == true)
    }

    @Test func screenshotsTakeALocaleToo() throws {
        let out = try folders().1
        #expect(Screenshot.capture("Badge", sizes: ["120"], locale: "it", output: out) { badge("Nuovo") } == [])
        #expect(try json(out.appendingPathComponent("Badge-it-macos-120-light.json"))["locale"] as? String == "it")
    }

    @Test func snapshotsPathInTheConfigIsTheBaselineFolder() throws {
        let root = try folders().0
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"snapshots":{"path":"Tests/Baselines"}}"#.write(to: root.appendingPathComponent(".claude/swift-harness.json"), atomically: true, encoding: .utf8)
        let found = try #require(Snapshot.folders(from: root.appendingPathComponent("Tests/X")))
        #expect(found.baselines == root.appendingPathComponent("Tests/Baselines"))
        #expect(found.candidates == root.appendingPathComponent(".build/swift-harness/snapshots"))
    }

    // MARK: - Helpers

    private var row: some View {
        HStack { Text("Albums"); Spacer(); Text("12") }.padding(.horizontal, DS.Space.m)
    }

    private func badge(_ title: String) -> some View {
        Text(title).font(DS.Font.rowTitle).padding(DS.Space.s)
    }

    /// What /swift-harness:approve-snapshots does: copy each new image and its metadata.
    private func approve(_ out: URL, _ baselines: URL) throws {
        for name in try names(out) where name.hasSuffix(".png") && !name.hasSuffix(".diff.png") {
            let stem = String(name.dropLast(4))
            for ext in ["png", "json"] {
                let target = baselines.appendingPathComponent("\(stem).\(ext)")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: out.appendingPathComponent("\(stem).\(ext)"), to: target)
            }
        }
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func result(_ folder: URL, _ base: String) throws -> [String: Any] {
        try json(folder.appendingPathComponent("\(base).result.json"))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func folders() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("baselines"), b = root.appendingPathComponent("out")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (a, b)
    }
}
