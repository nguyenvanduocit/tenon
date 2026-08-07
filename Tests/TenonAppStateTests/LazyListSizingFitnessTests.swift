import Foundation
import XCTest

/// T-091. A lazy list must not sit inside a layout that asks it how big it wants to be.
///
/// This is the one shape the hang's stack trace names directly:
///
/// ```
/// _ZStackLayout.sizeThatFits → ScrollViewLayoutComputer.Engine.sizeThatFits
///   → LazyStack.measureEstimates → ForEachList.applyNodes → ForEachState.item(at:offset:)
///     → AgentTimelineItem
/// ```
///
/// A `ZStack` sizes itself by asking every child what it wants. Asking that of a `ScrollView`
/// makes the lazy list inside it materialise rows nobody can see — and in a pane whose height
/// is decided by the canvas, measuring content the pane never displays is work with no purpose
/// at all. An `.overlay` is sized by the view it sits on, so it never asks.
///
/// The check is textual because the defect is a *shape*, and a shape is what a reviewer scans
/// for. It is deliberately narrow: `ZStack` → `ScrollView` → lazy container, in that order,
/// within one screenful.
final class LazyListSizingFitnessTests: XCTestCase {
    func testNoLazyListIsMeasuredByAnEnclosingStackLayout() throws {
        var offenders: [String] = []

        for file in try appSourceFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() where line.contains("ZStack(") {
                let stackIndent = indent(of: line)
                let window = lines[index ..< min(index + 40, lines.count)]

                guard let scrollOffset = window.dropFirst().firstIndex(where: {
                    $0.contains("ScrollView") && indent(of: $0) > stackIndent
                }) else { continue }

                let scrollIndent = indent(of: lines[scrollOffset])
                let nested = lines[scrollOffset ..< min(scrollOffset + 6, lines.count)]
                guard nested.dropFirst().contains(where: {
                    ($0.contains("LazyVStack") || $0.contains("LazyVGrid"))
                        && indent(of: $0) > scrollIndent
                }) else { continue }

                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertEqual(
            offenders,
            [],
            """
            a lazy list inside a ScrollView inside a ZStack is measured in full every time the \
            stack computes its size — use .overlay(alignment:) on the scroll view instead
            """
        )
    }

    // MARK: - Fixture

    private func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func appSourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TenonApp")
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertGreaterThan(
            files.count,
            10,
            "fixture failed to enumerate TenonApp sources — an empty scan passes vacuously"
        )
        return files
    }
}
