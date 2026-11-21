// Snapshot.swift, from the swift-harness setup templates (#9).
// Copy it into the test target that has LayoutContract.swift and Screenshot.swift: it renders
// through them. Keep this header so updates can be compared.
//
// Visual regression for shared components and screens: each image is compared with a baseline
// the user approved. Returns the problems found (empty when every image matches, or could not
// be compared on this Mac, see below):
//
//     XCTest:        XCTAssertEqual(Snapshot.verify("PillView", sizes: ["320"]) { PillView("New") }, [])
//     Swift Testing: #expect(Snapshot.verify("PillView", sizes: ["320"]) { PillView("New") } == [])
//
// Call it from a @MainActor test. Sizes, `state:` and `source:` work as in Screenshot.capture:
// with only a name, Min and Default come from the screen's row of docs/LAYOUT_CONTRACT.md.
// Each size is checked in light and dark. A gallery is one test file that checks every shared
// component in its usual states: `state: "long-text"` with a long title, `locale: "de"` for a
// long language, `locale: "ar"` for right to left (locale and text direction are set in the
// environment, so localized strings, dates and numbers follow). On macOS, dynamicTypeSize does
// not change how SwiftUI text is drawn: larger text is a state you draw yourself.
//
// Baselines are never written by a test (one exception: approveNew, below). A missing or
// different image fails, and the new image (with a diff image, changed pixels in red) is saved
// under .build/swift-harness/snapshots/.
// The user looks at it and approves it with /swift-harness:approve-snapshots, which copies it
// into the baselines folder: `snapshots.path` in .claude/swift-harness.json, default
// `snapshots/` at the project root. Commit that folder: the metadata beside each image names
// the test file relative to the project root, never by its absolute path.
//
// With `"snapshots": {"pending": "collect"}` in .claude/swift-harness.json a missing or different
// image does not fail its test: it is saved the same way and waits, so work goes on, and the
// approval is asked once, when the work is committed (a commit asks first, and
// `scripts/verify.sh full` fails while images wait). An image that cannot be read still fails.
//
// With `"snapshots": {"approveNew": true}` an image that has no baseline yet (a component or a
// state never captured before) becomes its baseline at once, and its test passes: the user
// approved new images once for all, in the config. The end of the turn lists them. An image that
// differs from its baseline still waits for the approval, and nothing replaces a baseline.
//
// Baselines are pinned to the macOS version (major.minor) and display scale they were made on:
// text and controls draw differently on other versions. On a Mac or runner that differs, the
// image is not compared and the test says so on its output ("not compared"); it does not fail
// and it does not count as a match. Compare on the machine the baselines were made on.
//
// Two settings of the Mac change an image and are neither pinned nor recorded yet. Without
// `locale:` the view keeps the Mac's locale, so numbers and dates follow it ("0.3" or "0,3"):
// pass `locale:` for a view that shows them. And `Color.accentColor`, with the selection and
// focus colors that follow it, is the accent color of System Settings: a baseline that shows
// one depends on the Mac that made it.
//
// A pixel differs when a color channel changes by more than `channelTolerance`; `tolerance:`
// is the fraction of pixels allowed to differ. Without it, `"snapshots": {"tolerance": 0.001}`
// in .claude/swift-harness.json gives the fraction for the whole project (default 0). A larger
// tolerance, here or in the config, is reported at the end of the turn as a weaker check.

// A helper kept as shipped, so that a later version can be compared with it: no formatter
// rewrites it (SwiftFormat, swift-format) and its style rules are off here; the project's
// other lint rules still apply.
// swiftformat:disable all
// swift-format-ignore-file
// swiftlint:disable cyclomatic_complexity function_body_length function_parameter_count identifier_name line_length

#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum Snapshot {
    /// Largest change of one color channel (0...255) that still counts as the same pixel.
    static let channelTolerance = 3
    static let defaultBaselines = "snapshots"
    static let candidates = ".build/swift-harness/snapshots"

    enum Status: String {
        case passed, missing, failed
        case notCompared = "not-compared"
    }

    @MainActor
    static func verify<Content: View>(
        _ name: String,
        sizes: [String]? = nil,
        state: String? = nil,
        locale: String? = nil,
        tolerance: Double? = nil,
        source: String? = nil,
        contract: URL? = nil,
        baselines: URL? = nil,
        output: URL? = nil,
        collect: Bool? = nil,
        approveNew: Bool? = nil,
        file: StaticString = #filePath,
        @ViewBuilder _ make: () -> Content
    ) -> [String] {
        let testFolder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let settings = Snapshot.settings(from: testFolder)
        let collects = collect ?? (settings["pending"] as? String == "collect")
        let allowed = tolerance ?? (settings["tolerance"] as? NSNumber)?.doubleValue ?? 0
        let acceptsNew = approveNew ?? (settings["approveNew"] as? Bool == true)
        let plan: Screenshot.Plan
        switch Screenshot.plan(name, sizes: sizes, source: source, contract: contract, file: file) {
        case .failure(let failure): return [failure.description]
        case .success(let value): plan = value
        }
        let found = folders(from: testFolder)
        guard let baselineFolder = baselines ?? found?.baselines, let candidateFolder = output ?? found?.candidates else {
            return ["No project root found above \(file): pass baselines: and output:."]
        }
        do {
            try FileManager.default.createDirectory(at: candidateFolder, withIntermediateDirectories: true)
        } catch {
            return ["Cannot create \(candidateFolder.path): \(error.localizedDescription). A sandboxed test host cannot write to the project: verify in a test target without a host app, or pass output:."]
        }

        _ = NSApplication.shared
        let content = Screenshot.localized(make(), locale)
        let test = Screenshot.testPath(file)
        var problems: [String] = []
        for size in plan.sizes {
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                let base = Screenshot.name(name, state: state, locale: locale, size: size, appearance: appearance)
                let image: CGImage, points: CGSize
                switch Screenshot.render(content, size: size, dark: dark) {
                case .failure(let reason):
                    problems.append("\(base): \(reason)")
                    continue
                case .success(let value):
                    (image, points) = value
                }
                let info: [String: Any] = [
                    "screen": name,
                    "state": state ?? "",
                    "locale": locale ?? "",
                    "platform": Screenshot.platform,
                    "size": "\(LayoutContract.Size.number(points.width))x\(LayoutContract.Size.number(points.height))",
                    "contractSize": size.text,
                    "appearance": appearance,
                    "scale": points.width > 0 ? Double(image.width) / Double(points.width) : 1,
                    "os": osVersion,
                    "osBuild": ProcessInfo.processInfo.operatingSystemVersionString,
                    "source": plan.source,
                    "test": test,
                    "captured": ISO8601DateFormatter().string(from: Date()),
                ]
                let outcome = check(image, info: info, base: base, baselines: baselineFolder, candidates: candidateFolder, tolerance: allowed, acceptsNew: acceptsNew)
                if let problem = outcome.problem {
                    if collects, outcome.waits {
                        print("swift-harness snapshot: \(base) waits for approval and does not fail this test (snapshots.pending is \"collect\"): \(problem)")
                    } else {
                        problems.append(problem)
                    }
                }
                if outcome.problem == nil, let note = outcome.note { print("swift-harness snapshot: \(note)") }
            }
        }
        return problems
    }

    /// The baselines folder (`snapshots.path` in .claude/swift-harness.json, else snapshots/)
    /// and the folder for new images, both under the project root above `start`.
    static func folders(from start: URL) -> (baselines: URL, candidates: URL)? {
        guard let (root, config) = Screenshot.root(from: start) else { return nil }
        let path = (config?["snapshots"] as? [String: Any])?["path"] as? String ?? defaultBaselines
        return (root.appendingPathComponent(path), root.appendingPathComponent(candidates))
    }

    /// The `snapshots` object of the .claude/swift-harness.json above `start`, or empty.
    /// `"pending": "collect"`: a new or different image waits instead of failing its test.
    /// `"tolerance"`: the fraction of pixels allowed to differ when a test passes none.
    /// `"approveNew": true`: an image with no baseline yet becomes its baseline at once.
    static func settings(from start: URL) -> [String: Any] {
        guard let (_, config) = Screenshot.root(from: start) else { return [:] }
        return config?["snapshots"] as? [String: Any] ?? [:]
    }

    /// True when the project collects images that wait instead of failing their tests.
    static func collects(from start: URL) -> Bool {
        settings(from: start)["pending"] as? String == "collect"
    }

    /// This Mac's macOS version, major.minor: what a baseline is pinned to.
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    struct Outcome {
        var status: Status
        var problem: String?
        var note: String?
        /// The image is new or differs from its baseline: it waits for the user's approval.
        /// False for a problem of another kind (a baseline that cannot be read).
        var waits = false
    }

    /// Compares one rendered image with its baseline and leaves the files the approval reads in
    /// the candidates folder: <base>.png and .json (the new image), <base>.diff.png, and
    /// <base>.result.json with the status. A match removes the new image and the diff.
    /// With `acceptsNew`, an image with no baseline is written as its baseline, approved from
    /// "new": the only case where a test writes into the baselines folder.
    static func check(_ image: CGImage, info: [String: Any], base: String, baselines: URL, candidates: URL, tolerance: Double, acceptsNew: Bool = false) -> Outcome {
        let files = FileManager.default
        let baselinePNG = baselines.appendingPathComponent("\(base).png")
        let baselineJSON = baselines.appendingPathComponent("\(base).json")
        let candidatePNG = candidates.appendingPathComponent("\(base).png")
        let candidateJSON = candidates.appendingPathComponent("\(base).json")
        let diffPNG = candidates.appendingPathComponent("\(base).diff.png")
        let approve = "Only the user approves it: /swift-harness:approve-snapshots opens a page with each image before, now and its changed pixels, and asks which to keep. Tell them so, and which change caused it. Do not copy it into \(baselines.lastPathComponent)/ yourself."

        func finish(_ status: Status, problem: String? = nil, note: String? = nil, diff: CGImage? = nil, waits: Bool = false) -> Outcome {
            for url in [candidatePNG, candidateJSON, diffPNG] { try? files.removeItem(at: url) }
            var result: [String: Any] = ["status": status.rawValue, "baseline": baselinePNG.path]
            if status != .passed {
                if let data = png(image) { try? data.write(to: candidatePNG) }
                if let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                    try? json.write(to: candidateJSON)
                }
                if let diff, let data = png(diff) { try? data.write(to: diffPNG) }
            }
            if let reason = problem ?? note { result["reason"] = reason }
            if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: candidates.appendingPathComponent("\(base).result.json"))
            }
            return Outcome(status: status, problem: problem, note: note, waits: waits)
        }

        guard files.fileExists(atPath: baselinePNG.path) else {
            if acceptsNew {
                var approved = info
                approved["approved"] = ISO8601DateFormatter().string(from: Date())
                approved["approvedFrom"] = "new"
                if let data = png(image),
                   let json = try? JSONSerialization.data(withJSONObject: approved, options: [.prettyPrinted, .sortedKeys]),
                   (try? files.createDirectory(at: baselines, withIntermediateDirectories: true)) != nil,
                   (try? json.write(to: baselineJSON)) != nil,
                   (try? data.write(to: baselinePNG)) != nil {
                    return finish(.passed, note: "\(base): new, recorded as its baseline (snapshots.approveNew is true): \(baselinePNG.path)")
                }
                try? files.removeItem(at: baselineJSON)
            }
            return finish(.missing, problem: "\(base): no approved baseline in \(baselines.path). The new image is \(candidatePNG.path). \(approve)", waits: true)
        }
        let pinned = (try? Data(contentsOf: baselineJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let pinnedOS = pinned["os"] as? String ?? "?"
        let pinnedScale = pinned["scale"] as? Double ?? 0
        let scale = info["scale"] as? Double ?? 0
        if pinnedOS != osVersion || pinnedScale != scale {
            return finish(.notCompared, note: "\(base): not compared, the baseline was made on macOS \(pinnedOS) at scale \(LayoutContract.Size.number(pinnedScale)) and this is macOS \(osVersion) at scale \(LayoutContract.Size.number(scale)). Compare on the Mac the baselines were made on.")
        }
        guard let data = try? Data(contentsOf: baselinePNG), let reference = NSBitmapImageRep(data: data)?.cgImage else {
            return finish(.failed, problem: "\(base): cannot read the baseline \(baselinePNG.path). The new image is \(candidatePNG.path). \(approve)")
        }
        guard reference.width == image.width, reference.height == image.height else {
            let ratio = scale > 0 ? scale : 1
            func points(_ image: CGImage) -> String {
                "\(LayoutContract.Size.number(CGFloat(Double(image.width) / ratio)))x\(LayoutContract.Size.number(CGFloat(Double(image.height) / ratio)))"
            }
            return finish(.failed, problem: "\(base): the size changed from \(points(reference)) to \(points(image)) pt. The new image is \(candidatePNG.path). \(approve)", waits: true)
        }
        guard let old = pixels(reference), let new = pixels(image) else {
            return finish(.failed, problem: "\(base): cannot read the pixels to compare. \(approve)")
        }
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var diff = [UInt32](repeating: 0, count: new.count)
        for index in 0..<new.count {
            let a = old[index], b = new[index]
            var same = true
            for shift in stride(from: 0, through: 24, by: 8) {
                let x = Int((a >> UInt32(shift)) & 0xFF), y = Int((b >> UInt32(shift)) & 0xFF)
                if abs(x - y) > channelTolerance { same = false; break }
            }
            if same {
                // The new image, faded toward white, so the red changes stand out.
                var faded: UInt32 = 0
                for shift in stride(from: 0, through: 16, by: 8) {
                    let value = UInt32((b >> UInt32(shift)) & 0xFF)
                    faded |= ((value + 3 * 255) / 4) << UInt32(shift)
                }
                diff[index] = faded | 0xFF00_0000
            } else {
                changed += 1
                let x = index % image.width, y = index / image.width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                diff[index] = 0xFF00_00FF // opaque red: red is the low byte, alpha the high one
            }
        }
        let total = new.count
        if changed == 0 || Double(changed) / Double(total) <= tolerance {
            return finish(.passed)
        }
        let ratio = scale > 0 ? scale : 1
        func pt(_ value: Int) -> String { LayoutContract.Size.number(CGFloat(Double(value) / ratio)) }
        let percent = String(format: "%.2f", Double(changed) * 100 / Double(total))
        let region = "x \(pt(minX))-\(pt(maxX + 1)), y \(pt(minY))-\(pt(maxY + 1)) pt from the top left"
        return finish(.failed,
                      problem: "\(base): \(changed) of \(total) pixels differ (\(percent)%), within \(region). The new image is \(candidatePNG.path), changes in red in \(diffPNG.path). \(approve)",
                      diff: Snapshot.image(from: diff, width: image.width, height: image.height), waits: true)
    }

    /// RGBA pixels, premultiplied, one UInt32 each.
    static func pixels(_ image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func image(from pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        var pixels = pixels
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif

// swiftlint:enable cyclomatic_complexity function_body_length function_parameter_count identifier_name line_length
