// PerformanceBudget.swift, from the swift-harness setup templates (#33).
// Copy it into a test target of the code it measures (a package test target, so
// `scripts/verify.sh fast` runs it). Keep this header so updates can be compared.
//
// A performance budget for a key operation: the operation runs a few times to warm up, then
// is measured `iterations` times, and the median is compared with a baseline the user
// approved. Returns the problems found (empty when the operation is within its budget, or
// could not be compared on this machine, see below):
//
//     final class LibraryBudgetTests: XCTestCase {        // XCTest runs these one at a time
//         func testLoadingTenThousandSongs() {
//             let data = Fixtures.library(count: 10_000)
//             XCTAssertEqual(PerformanceBudget.verify("LoadLibrary-10k") { _ = Library.load(data) }, [])
//         }
//     }
//
// What is measured: instructions retired by the test process (proc_pid_rusage), the median of
// the iterations. On a Mac they are stable to about a quarter of a percent between runs, where
// time moves by a few percent and by far more on a busy machine; a real regression (the same
// data decoded twice) moved them by 64%. Thread CPU time is recorded next to them, for people.
// Measured in #33: https://github.com/davidelarocca/swift-harness/issues/33
//
// - The count is for the whole process: tests running at the same time inflate it. Swift
//   Testing runs tests in parallel, so put budget tests in an XCTest class, or in a Swift
//   Testing suite marked `.serialized` in a test target of their own. When the iterations
//   spread by more than 2%, the result is "unstable" and fails: it is not a measurement.
// - Virtual machines, such as GitHub's macOS runners, have no instruction counter, and time
//   there varies by ±20% between runs of the same code. There the budget prints its numbers
//   and is "not compared": it neither fails nor counts as a pass. Budgets hold on real Macs.
// - Baselines are pinned to the architecture, the macOS version (major.minor, whose frameworks
//   change the count) and the build configuration. Elsewhere the result is "not compared".
//
// Baselines are never written by a test. A missing baseline, or a count more than `tolerance`
// (default 5%) over it, fails and leaves the new numbers in .build/swift-harness/performance/;
// a count more than `tolerance` under it passes and leaves them too, so a gain can be kept.
// The user approves them with /swift-harness:approve-performance, which copies them into the
// baselines folder: `performance.path` in .claude/swift-harness.json, default `performance/`
// at the project root. Commit that folder.

#if os(macOS)
import Darwin
import Foundation

enum PerformanceBudget {
    static let defaultBaselines = "performance"
    static let candidates = ".build/swift-harness/performance"
    /// Iterations may differ from their median by this fraction (interquartile range) before
    /// the measurement counts as disturbed.
    static let maxSpread = 0.02

    enum Status: String {
        case passed, missing, failed, unstable, faster
        case notCompared = "not-compared"
    }

    struct Measurement {
        var instructions: UInt64
        var cpuMilliseconds: Double
        var spread: Double
        var iterations: Int
        var counter: Bool { instructions > 0 }
    }

    static func verify(
        _ name: String,
        tolerance: Double = 0.05,
        iterations: Int = 15,
        warmup: Int = 3,
        baselines: URL? = nil,
        output: URL? = nil,
        file: StaticString = #filePath,
        _ body: () throws -> Void
    ) rethrows -> [String] {
        let base = name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let start = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let found = folders(from: start)
        guard let baselineFolder = baselines ?? found?.baselines, let candidateFolder = output ?? found?.candidates else {
            return ["No project root found above \(file): pass baselines: and output:."]
        }
        let measured = try measure(iterations: max(iterations, 5), warmup: warmup, body)
        return check(measured, base: base, baselines: baselineFolder, candidates: candidateFolder, tolerance: tolerance)
    }

    // MARK: - Measuring

    static func measure(iterations: Int, warmup: Int, _ body: () throws -> Void) rethrows -> Measurement {
        for _ in 0..<warmup { try body() }
        var counts: [UInt64] = []
        var cpu: [Double] = []
        for _ in 0..<iterations {
            let i0 = instructions()
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try body()
            let c1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let i1 = instructions()
            counts.append(i1 &- i0)
            cpu.append(Double(c1 - c0) / 1_000_000)
        }
        let sorted = counts.sorted()
        let median = sorted[sorted.count / 2]
        let spread = median == 0 ? 0 : Double(sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4]) / Double(median)
        return Measurement(instructions: median, cpuMilliseconds: cpu.sorted()[cpu.count / 2], spread: spread, iterations: iterations)
    }

    /// Instructions retired by this process so far; 0 where the machine does not count them.
    static func instructions() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_instructions : 0
    }

    /// What a baseline is pinned to.
    static var machine: [String: String] {
        var system = utsname()
        uname(&system)
        let arch = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return ["arch": arch, "os": "\(version.majorVersion).\(version.minorVersion)", "configuration": configuration]
    }

    // MARK: - Comparing

    static func check(_ m: Measurement, base: String, baselines: URL, candidates: URL, tolerance: Double) -> [String] {
        let files = FileManager.default
        let baselineFile = baselines.appendingPathComponent("\(base).json")
        let candidateFile = candidates.appendingPathComponent("\(base).json")
        let resultFile = candidates.appendingPathComponent("\(base).result.json")
        let pin = machine
        let numbers = "\(millions(m.instructions)) instructions, \(String(format: "%.2f", m.cpuMilliseconds)) ms CPU"
        let approve = "show the numbers to the user; only they approve them, with /swift-harness:approve-performance. Do not write \(baselines.lastPathComponent)/ yourself."
        var record: [String: Any] = ["name": base, "instructions": m.instructions, "cpuMilliseconds": NSDecimalNumber(string: String(format: "%.2f", m.cpuMilliseconds)),
                                     "spread": NSDecimalNumber(string: String(format: "%.4f", m.spread)), "iterations": m.iterations]
        record.merge(pin) { $1 }

        func finish(_ status: Status, problem: String? = nil, note: String? = nil, keep: Bool) -> [String] {
            try? files.createDirectory(at: candidates, withIntermediateDirectories: true)
            if keep, let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: candidateFile, options: .atomic)
            } else {
                try? files.removeItem(at: candidateFile)
            }
            var result: [String: Any] = ["status": status.rawValue]
            if let reason = problem ?? note { result["reason"] = reason }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: resultFile, options: .atomic)
            }
            print("PerformanceBudget: \(base) \(status.rawValue): \(problem ?? note ?? numbers)")
            return problem.map { [$0] } ?? []
        }

        guard m.counter else {
            return finish(.notCompared, note: "this machine counts no instructions (a virtual machine, such as a CI runner, where time varies too much to compare). \(String(format: "%.2f", m.cpuMilliseconds)) ms CPU.", keep: false)
        }
        guard m.spread <= maxSpread else {
            return finish(.unstable, problem: "\(base): the iterations spread by \(percent(m.spread)), more than \(percent(maxSpread)): other work ran in the test process while it was measured, such as tests running in parallel. Run budget tests one at a time: in an XCTest class, or a Swift Testing suite marked .serialized in a test target of their own.", keep: false)
        }
        guard let data = try? Data(contentsOf: baselineFile),
              let baseline = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let approved = (baseline["instructions"] as? NSNumber)?.uint64Value, approved > 0 else {
            return finish(.missing, problem: "\(base): no approved baseline yet: \(numbers) (\(pin["arch"]!), macOS \(pin["os"]!), \(pin["configuration"]!)). To set it, \(approve)", keep: true)
        }
        let made = ["arch", "os", "configuration"].map { baseline[$0] as? String ?? "?" }
        let here = ["arch", "os", "configuration"].map { pin[$0]! }
        guard made == here else {
            func text(_ p: [String]) -> String { "\(p[0]), macOS \(p[1]), \(p[2])" }
            return finish(.notCompared, note: "the baseline was made on \(text(made)), this is \(text(here)). \(numbers). Approving these numbers moves the baseline here.", keep: true)
        }
        let ratio = Double(m.instructions) / Double(approved)
        let was = (baseline["cpuMilliseconds"] as? NSNumber).map { String(format: "%.2f ms", $0.doubleValue) } ?? "?"
        if ratio > 1 + tolerance {
            return finish(.failed, problem: "\(base): \(millions(m.instructions)) instructions, \(percent(ratio - 1)) over the approved \(millions(approved)) (tolerance \(percent(tolerance))); CPU time \(String(format: "%.2f", m.cpuMilliseconds)) ms, was \(was). Find what made it slower. If the extra work is intended: \(approve)", keep: true)
        }
        if ratio < 1 - tolerance {
            return finish(.faster, note: "\(percent(1 - ratio)) fewer instructions than the approved \(millions(approved)) (\(numbers)): approve the new numbers to keep the gain.", keep: true)
        }
        return finish(.passed, note: "\(numbers), \(ratio >= 1 ? "+" : "")\(percent(ratio - 1)) of the approved \(millions(approved))", keep: false)
    }

    static func folders(from start: URL) -> (baselines: URL, candidates: URL)? {
        let files = FileManager.default
        var dir = start.standardizedFileURL
        while true {
            let config = dir.appendingPathComponent(".claude/swift-harness.json")
            if let data = try? Data(contentsOf: config) {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let path = (json?["performance"] as? [String: Any])?["path"] as? String ?? defaultBaselines
                return (dir.appendingPathComponent(path), dir.appendingPathComponent(candidates))
            }
            if files.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return (dir.appendingPathComponent(defaultBaselines), dir.appendingPathComponent(candidates))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static func millions(_ n: UInt64) -> String { String(format: "%.2f M", Double(n) / 1_000_000) }
    static func percent(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}
#endif
