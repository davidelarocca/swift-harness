// LayoutContract.swift, from the swift-harness setup templates (#34).
// Copy it into a test target that can import SwiftUI. Keep this header so updates can be compared.
//
// Measures a screen at the sizes its row in docs/LAYOUT_CONTRACT.md declares, and returns
// the problems found (empty when the screen holds):
//
//     XCTest:        XCTAssertEqual(LayoutContract.check("LibraryView") { LibraryView() }, [])
//     Swift Testing: #expect(LayoutContract.check("LibraryView") { LibraryView() } == [])
//
// Call it from a @MainActor test, once for the View of a row and once for its Window, if any.
// The first argument is that cell, as a string literal on the same line as
// `LayoutContract.check(`: the end-of-turn check finds the test by it. The closure builds the
// view with what it needs (environment, a preview model).
//
// What it measures, with NSHostingController.sizeThatFits(in:):
// - View, the screen's content: at Min, just below and at Compact below, Default and Max, it
//   needs no more width (or height, when the size gives one) than proposed. More means content
//   clipped or pushed out of the window. A minimum or fixed frame around the measured view
//   hides this, so the content is measured without the window's .frame(minWidth:).
// - Window, the view the window shows (the content plus the window's minimum frame): its
//   declared minimum is Min, so the window neither shrinks below Min nor stops above it; with
//   a Max, it does not grow past it.
// Content whose width cannot be measured is reported, not passed: a NavigationSplitView, an
// HSplitView, a List or a Table takes any width and clips what does not fit without reporting
// it. Measure the pages of the detail column and the sidebar on rows of their own; a split
// view's row names its window type as View and Window. Its heights are still measured.
// Content that takes any width but has a width of its own (text that wraps, or content in a
// .frame(minWidth: 0, maxWidth: .infinity), which hides its overflow) cannot be told apart: it
// is measured, and a note on the test output says its width is checked only as far as it wraps.
// Not measured: truncated text, overlaps, where popovers open. Those stay in review.
//
// The contract is found from the calling test file upwards: `layout.path` in
// .claude/swift-harness.json, else docs/LAYOUT_CONTRACT.md. A sandboxed test host cannot read
// the source tree: measure in a test target without a host app, or pass `contract:`.

// A helper kept as shipped, so its style rules are off here; the project's own rules still apply.
// swiftlint:disable cyclomatic_complexity identifier_name line_length

#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum LayoutContract {
    struct Size: Equatable {
        var width: CGFloat
        var height: CGFloat?

        var text: String { height.map { "\(Self.number(width))x\(Self.number($0))" } ?? Self.number(width) }
        static func number(_ value: CGFloat) -> String {
            value == value.rounded() ? String(Int(value)) : String(Double(value))
        }
    }

    struct Row {
        var line: Int
        var view: String
        var window: String
        var min: String
        var defaultSize: String
        var max: String
        var compactBelow: String
    }

    /// Layout rounding.
    static let tolerance: CGFloat = 0.5
    /// The proposal used for a height the contract leaves open, and to find how far a window grows.
    static let unbounded: CGFloat = 20_000

    @MainActor
    static func check<Content: View>(
        _ view: String,
        contract: URL? = nil,
        file: StaticString = #filePath,
        @ViewBuilder _ make: () -> Content
    ) -> [String] {
        guard let url = contract ?? locate(from: URL(fileURLWithPath: "\(file)").deletingLastPathComponent()) else {
            return ["No layout contract found above \(file): add docs/LAYOUT_CONTRACT.md, or pass contract:."]
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ["Cannot read the layout contract at \(url.path): \(error.localizedDescription). A sandboxed test host cannot read the source tree: measure in a test target without a host app, or pass contract:."]
        }
        guard let rows = rows(in: text) else {
            return ["\(url.lastPathComponent) has no \"## Screens\" table with View and Min columns."]
        }
        let asContent = rows.first { $0.view == view }
        let asWindow = rows.first { $0.window == view }
        guard let row = asContent ?? asWindow else {
            return ["\(url.lastPathComponent) has no row with \(view) as View or Window: add one, or fix the name passed to LayoutContract.check."]
        }
        let place = "\(url.lastPathComponent):\(row.line) \(view)"
        guard let minCell = size(row.min), let min = minCell else {
            return ["\(place): Min '\(row.min)' is not a size."]
        }
        guard let defaultCell = size(row.defaultSize), let maxCell = size(row.max), let compactCell = size(row.compactBelow) else {
            return ["\(place): Default, Max or Compact below is not a size."]
        }

        let content = make()
        func needed(_ proposal: CGSize) -> CGSize {
            NSHostingController(rootView: content).sizeThatFits(in: proposal)
        }

        var widthMeasurable = true
        var sizes: [Size] = [min]
        if let compact = compactCell, compact.width > min.width {
            sizes.append(Size(width: compact.width - 1, height: min.height))
            sizes.append(Size(width: compact.width, height: min.height))
        }
        if let size = defaultCell { sizes.append(size) }
        if let size = maxCell { sizes.append(size) }

        var problems: [String] = []
        // Content that accepts 1 pt of width hides whatever does not fit: a split view or a frame
        // from zero to infinity clips it without reporting it. Saying it fits would be a guess.
        // A split view, a List or a Table takes any width and has no width of its own: what it
        // holds is clipped without being reported. Text that wraps also takes any width, but has
        // one of its own. A row whose View is also its Window is checked as a window below.
        let kind = asContent.map { $0.window == view } == false ? width(of: content, height: min.height) : .measurable
        if kind == .open {
            print("swift-harness layout: \(place): takes any width, so its width is checked only as far as it wraps like text. A .frame(minWidth: 0, maxWidth: .infinity) or other stretched content hides what does not fit: measure the content inside it on a row of its own.")
        }
        if kind == .hidden {
            widthMeasurable = false
            problems.append("\(place): its width cannot be measured: it takes any width, even 1 pt, and has none of its own, so content that does not fit is clipped without being reported (NavigationSplitView, HSplitView, List and Table do this). Measure what it holds: give each page of the detail column and the sidebar a row of its own, with View the page and Min the width its column gets at the window's Min. For a split view, set this row's View to its Window type, so the row checks the window's sizes.")
        }
        var seen: [Size] = []
        for size in sizes where asContent != nil && !seen.contains(size) {
            seen.append(size)
            let need = needed(CGSize(width: size.width, height: size.height ?? unbounded))
            if widthMeasurable, need.width > size.width + tolerance {
                problems.append("\(place): at \(size.text) it needs \(Size.number(need.width)) pt of width. Content is clipped or pushed out of the window: let it shrink, wrap or collapse (ViewThatFits, a menu) below this width.")
            }
            if let height = size.height, need.height > height + tolerance {
                problems.append("\(place): at \(size.text) it needs \(Size.number(need.height)) pt of height. Content is clipped: let it scroll or collapse below this height.")
            }
        }

        if asWindow != nil {
            let declared = needed(.zero)
            let declaredText = Size(width: declared.width, height: min.height == nil ? nil : declared.height).text
            let frame = ".frame(minWidth: \(Size.number(min.width))\(min.height.map { ", minHeight: \(Size.number($0))" } ?? ""))"
            if declared.width + tolerance < min.width || (min.height.map { declared.height + tolerance < $0 } ?? false) {
                problems.append("\(place): the window declares a minimum of \(declaredText), below Min \(min.text), so it can shrink to a size the screen was not designed for. Declare it on the window's root: \(frame).")
            } else if declared.width > min.width + tolerance || (min.height.map { declared.height > $0 + tolerance } ?? false) {
                problems.append("\(place): the window cannot shrink to Min \(min.text): its minimum is \(declaredText). Make the content fit at Min, or change Min in the contract.")
            }
            if let max = maxCell {
                let grown = needed(CGSize(width: unbounded, height: unbounded))
                if grown.width > max.width + tolerance || (max.height.map { grown.height > $0 + tolerance } ?? false) {
                    problems.append("\(place): the window grows past Max \(max.text). Declare .frame(maxWidth: \(Size.number(max.width))\(max.height.map { ", maxHeight: \(Size.number($0))" } ?? "")) on it and .windowResizability(.contentSize) on the scene.")
                }
            }
        }
        return problems
    }

    enum Width {
        /// It asks for the width it needs: the checks at each size measure it.
        case measurable
        /// It takes any width and asks for none: a split view, a List or a Table. What it holds
        /// is clipped without being reported.
        case hidden
        /// It takes any width but asks for one when nothing is proposed: text that wraps, or a
        /// stretched frame that hides its content. The two cannot be told apart.
        case open
    }

    /// How far sizeThatFits can see the width a view needs.
    @MainActor
    static func width<Content: View>(of content: Content, height: CGFloat? = nil) -> Width {
        let host = NSHostingController(rootView: content)
        guard host.sizeThatFits(in: CGSize(width: 1, height: height ?? unbounded)).width <= 1 + tolerance else { return .measurable }
        host.sizingOptions = [.intrinsicContentSize]
        return host.view.fittingSize.width <= tolerance ? .hidden : .open
    }

    /// `layout.path` from the first .claude/swift-harness.json above `folder`, else the first
    /// docs/LAYOUT_CONTRACT.md above it.
    static func locate(from folder: URL) -> URL? {
        let files = FileManager.default
        var dir = folder.standardizedFileURL
        while true {
            let config = dir.appendingPathComponent(".claude/swift-harness.json")
            if let data = try? Data(contentsOf: config),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let layout = json["layout"] as? [String: Any]
                let path = (layout?["path"] as? String) ?? "docs/LAYOUT_CONTRACT.md"
                return dir.appendingPathComponent(path)
            }
            let contract = dir.appendingPathComponent("docs/LAYOUT_CONTRACT.md")
            if files.fileExists(atPath: contract.path) { return contract }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// The rows of the "Screens" table; nil without one that has View and Min columns.
    static func rows(in text: String) -> [Row]? {
        var section = ""
        var header: [String: Int]?
        var inTable = false
        var rows: [Row] = []
        var found = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                section = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                inTable = false
                continue
            }
            guard line.hasPrefix("|") else {
                inTable = false
                continue
            }
            let cells = cellsOf(line)
            guard section.hasPrefix("screens") else { continue }
            if !inTable {
                inTable = true
                var columns: [String: Int] = [:]
                for (i, name) in cells.enumerated() { columns[name.lowercased()] = i }
                header = ["view", "min"].allSatisfy { columns[$0] != nil } ? columns : nil
                if header != nil { found = true }
                continue
            }
            guard let columns = header else { continue }
            if let first = cells.first, !first.isEmpty, first.allSatisfy({ "-:".contains($0) }) { continue }
            func cell(_ name: String) -> String {
                guard let i = columns[name], i < cells.count else { return "" }
                return cells[i]
            }
            let view = identifier(cell("view"))
            guard !view.isEmpty else { continue }
            rows.append(Row(line: index + 1, view: view, window: identifier(cell("window")), min: cell("min"),
                            defaultSize: cell("default"), max: cell("max"), compactBelow: cell("compact below")))
        }
        return found ? rows : nil
    }

    /// The Swift type a cell names: leading punctuation and a call or generic suffix dropped.
    static func identifier(_ cell: String) -> String {
        String(cell.drop { !($0.isLetter || $0 == "_") }.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func cellsOf(_ line: String) -> [String] {
        var body = line.replacingOccurrences(of: "\\|", with: "\u{1}")
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "\u{1}", with: "|")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// nil: not a size. .some(nil): none ("-" or empty). Accepts x, X or the multiplication sign.
    static func size(_ cell: String) -> Size?? {
        var text = cell.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "")
        if text.hasSuffix("pt") { text.removeLast(2) }
        if text.isEmpty || text == "-" || text.lowercased() == "none" { return .some(nil) }
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let width = Double(parts[0]) else { return nil }
        if parts.count == 1 { return Size(width: width) }
        guard let height = Double(parts[1]) else { return nil }
        return Size(width: width, height: height)
    }
}
#endif

// swiftlint:enable cyclomatic_complexity identifier_name line_length
