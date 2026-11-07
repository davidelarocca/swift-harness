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
// Baselines are never written by a test. A missing or different image fails, and the new image
// (with a diff image, changed pixels in red) is saved under .build/swift-harness/snapshots/.
// The user looks at it and approves it with /swift-harness:approve-snapshots, which copies it
// into the baselines folder: `snapshots.path` in .claude/swift-harness.json, default
// `snapshots/` at the project root. Commit that folder.
//
// Baselines are pinned to the macOS version (major.minor) and display scale they were made on:
// text and controls draw differently on other versions. On a Mac or runner that differs, the
// image is not compared and the test says so on its output ("not compared"); it does not fail
// and it does not count as a match. Compare on the machine the baselines were made on.
//
// A pixel differs when a color channel changes by more than `channelTolerance`; `tolerance:`
// is the fraction of pixels allowed to differ (default 0).

// A helper kept as shipped, so its style rules are off here; the project's own rules still apply.
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
        tolerance: Double = 0,
        source: String? = nil,
        contract: URL? = nil,
        baselines: URL? = nil,
        output: URL? = nil,
        file: StaticString = #filePath,
        @ViewBuilder _ make: () -> Content
    ) -> [String] {
        let testFolder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
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
                    "test": "\(file)",
                    "captured": ISO8601DateFormatter().string(from: Date()),
                ]
                let outcome = check(image, info: info, base: base, baselines: baselineFolder, candidates: candidateFolder, tolerance: tolerance)
                if let problem = outcome.problem { problems.append(problem) }
                if outcome.status == .notCompared, let note = outcome.note { print("swift-harness snapshot: \(note)") }
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

    /// This Mac's macOS version, major.minor: what a baseline is pinned to.
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    struct Outcome {
        var status: Status
        var problem: String?
        var note: String?
    }

    /// Compares one rendered image with its baseline and leaves the files the approval reads in
    /// the candidates folder: <base>.png and .json (the new image), <base>.diff.png, and
    /// <base>.result.json with the status. A match removes the new image and the diff.
    static func check(_ image: CGImage, info: [String: Any], base: String, baselines: URL, candidates: URL, tolerance: Double) -> Outcome {
        let files = FileManager.default
        let baselinePNG = baselines.appendingPathComponent("\(base).png")
        let baselineJSON = baselines.appendingPathComponent("\(base).json")
        let candidatePNG = candidates.appendingPathComponent("\(base).png")
        let candidateJSON = candidates.appendingPathComponent("\(base).json")
        let diffPNG = candidates.appendingPathComponent("\(base).diff.png")
        let approve = "Show it to the user; only they approve it, with /swift-harness:approve-snapshots. Do not copy it into \(baselines.lastPathComponent)/ yourself."

        func finish(_ status: Status, problem: String? = nil, note: String? = nil, diff: CGImage? = nil) -> Outcome {
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
            return Outcome(status: status, problem: problem, note: note)
        }

        guard files.fileExists(atPath: baselinePNG.path) else {
            return finish(.missing, problem: "\(base): no approved baseline in \(baselines.path). The new image is \(candidatePNG.path). \(approve)")
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
            return finish(.failed, problem: "\(base): the size changed from \(points(reference)) to \(points(image)) pt. The new image is \(candidatePNG.path). \(approve)")
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
                      diff: Snapshot.image(from: diff, width: image.width, height: image.height))
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
