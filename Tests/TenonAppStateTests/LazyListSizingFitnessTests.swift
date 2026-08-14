import AppKit
import Foundation
import SwiftUI
@testable import TenonApp
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
    func testAgentLensLiveChatUsesAFiniteViewportLayout() throws {
        let source = try String(
            contentsOf: appSourceRoot.appendingPathComponent("AgentLensView.swift"),
            encoding: .utf8
        )
        let sessionStart = try XCTUnwrap(
            source.range(of: "struct AgentSessionView")
        )
        let timelineStart = try XCTUnwrap(
            source.range(
                of: "private var timeline: some View",
                range: sessionStart.upperBound ..< source.endIndex
            )
        )
        let composerStart = try XCTUnwrap(
            source.range(
                of: "private var composer: some View",
                range: timelineStart.upperBound ..< source.endIndex
            )
        )
        let sessionBody = source[sessionStart.lowerBound ..< timelineStart.lowerBound]
        let timeline = source[timelineStart.lowerBound ..< composerStart.lowerBound]

        // Keep the fixture tied to the production path that failed. Chat must remain lazy so
        // offscreen rows do not appear eagerly and corrupt its bottom-sentinel semantics. Its
        // parent must instead give it an exact finite viewport, never an ideal-size query.
        XCTAssertTrue(sessionBody.contains("AgentSessionLayout {"))
        XCTAssertTrue(timeline.contains("ScrollViewReader"))
        XCTAssertTrue(timeline.contains("model.snapshot.renderRevision"))
        XCTAssertTrue(timeline.contains("scheduleBottomScroll(using: proxy)"))
        XCTAssertTrue(timeline.contains("AgentChatScrollPosition.revealBottom(bottomID, using: proxy)"))
        XCTAssertTrue(timeline.contains("LazyVStack"))
        XCTAssertFalse(
            timeline.contains("scrollTo(bottomID, anchor: .bottom)"),
            """
            Bottom-anchoring an underfilled transcript aligns its sentinel to the viewport's \
            bottom and turns the unused height into blank space above the first row. Let \
            scrollTo reveal the sentinel with its minimum movement so short chats stay at top.
            """
        )
    }

    @MainActor
    func testBottomScrollKeepsShortContentAtTopAndRevealsLongContentEnd() {
        let short = ScrollGeometryLedger()
        layOut(BottomScrollFixture(contentHeight: 40, ledger: short))
        XCTAssertEqual(
            short.firstRow.minY,
            12,
            accuracy: 1,
            "an underfilled transcript moved away from its 12-point top inset"
        )

        let long = ScrollGeometryLedger()
        layOut(BottomScrollFixture(contentHeight: 500, ledger: long))
        XCTAssertGreaterThanOrEqual(long.bottomTarget.maxY, 287)
        XCTAssertLessThanOrEqual(
            long.bottomTarget.maxY,
            301,
            "the overflowing transcript did not reveal its bottom sentinel"
        )
    }

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
        let root = appSourceRoot
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

    private var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TenonApp")
    }

    @MainActor
    private func layOut(_ view: some View) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class ScrollGeometryLedger {
    var firstRow = CGRect.zero
    var bottomTarget = CGRect.zero
}

private struct BottomScrollFixture: View {
    let contentHeight: CGFloat
    let ledger: ScrollGeometryLedger
    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.orange
                        .frame(height: contentHeight)
                        .background(frameRecorder(\.firstRow))
                    Color.clear
                        .frame(height: 12)
                        .background(frameRecorder(\.bottomTarget))
                        .id(bottomID)
                }
                .padding(.top, 12)
            }
            .coordinateSpace(.named("chat"))
            .onAppear {
                DispatchQueue.main.async {
                    AgentChatScrollPosition.revealBottom(bottomID, using: proxy)
                }
            }
        }
    }

    private func frameRecorder(_ keyPath: ReferenceWritableKeyPath<ScrollGeometryLedger, CGRect>) -> some View {
        GeometryReader { geometry in
            Color.clear.onAppear {
                ledger[keyPath: keyPath] = geometry.frame(in: .named("chat"))
            }
            .onChange(of: geometry.frame(in: .named("chat"))) { _, frame in
                ledger[keyPath: keyPath] = frame
            }
        }
    }
}
