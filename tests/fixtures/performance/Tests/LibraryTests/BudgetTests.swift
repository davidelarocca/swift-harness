import Foundation
import XCTest
@testable import Library

/// The template helper on the fixture. XCTest runs one test at a time, as budgets need.
final class BudgetTests: XCTestCase {
    func testLoadingTenThousandSongs() {
        let data = Library.data(count: 10_000)
        let env = ProcessInfo.processInfo.environment
        let slow = env["SLOW"] == "1"
        // Other work in the process while it is measured, as a test running in parallel would be.
        let stop = Hog()
        if env["HOG"] == "1" { stop.start() }
        defer { stop.stop() }
        XCTAssertEqual(PerformanceBudget.verify("LoadLibrary-10k") { _ = Library.load(data, slow: slow) }, [])
    }
}

final class Hog: @unchecked Sendable { // concurrency: `running` is only a stop flag, read racily on purpose
    private var running = false
    private var threads: [Thread] = []
    func start() {
        running = true
        for _ in 0..<2 {
            let thread = Thread { [self] in
                var h: UInt64 = 1
                while running { for i in 0..<100_000 { h = (h ^ UInt64(i)) &* 1_099_511_628_211 } }
                if h == 42 { print(h) }
            }
            thread.start()
            threads.append(thread)
        }
    }
    func stop() { running = false }
}
