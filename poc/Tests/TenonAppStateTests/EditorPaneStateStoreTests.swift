import Foundation
import XCTest
@testable import TenonApp

/// T-016: editor state (scroll + selection + unsaved buffer) is keyed by BOTH the
/// pane's slot and the file that pane showed. A pane whose content moved to another
/// file restores nothing — inheriting the previous file's scroll would be worse than
/// opening at the top — and the store is bounded (invariant 10).
@MainActor
final class EditorPaneStateStoreTests: XCTestCase {
    func testScrollSelectionAndBufferRoundTripForTheSamePaneAndFile() {
        let store = EditorPaneStateStore()
        let slot = UUID()

        store.recordScroll(for: slot, path: "/a/file.swift", x: 12, y: 340)
        store.recordSelection(
            for: slot,
            path: "/a/file.swift",
            location: 25,
            length: 4
        )
        store.recordBuffer(
            for: slot,
            path: "/a/file.swift",
            pendingText: "draft",
            savedTextHash: 99,
            conflicted: true
        )

        let state = store.state(for: slot, path: "/a/file.swift")
        XCTAssertEqual(state?.scrollX, 12)
        XCTAssertEqual(state?.scrollY, 340)
        XCTAssertEqual(state?.selectionLocation, 25)
        XCTAssertEqual(state?.selectionLength, 4)
        XCTAssertEqual(state?.pendingText, "draft")
        XCTAssertEqual(state?.savedTextHash, 99)
        XCTAssertEqual(state?.conflicted, true)
    }

    func testAPaneWhoseContentMovedToAnotherFileRestoresNothing() {
        let store = EditorPaneStateStore()
        let slot = UUID()

        store.recordScroll(for: slot, path: "/a/first.swift", x: 0, y: 900)

        XCTAssertNil(store.state(for: slot, path: "/a/second.swift"))

        // Recording for the new file replaces the old file's entry outright, so the
        // old scroll can never come back even if the pane later shows the old path
        // again — conservative beats wrong.
        store.recordSelection(
            for: slot,
            path: "/a/second.swift",
            location: 3,
            length: 0
        )
        XCTAssertNil(store.state(for: slot, path: "/a/first.swift"))
        let second = store.state(for: slot, path: "/a/second.swift")
        XCTAssertEqual(second?.selectionLocation, 3)
        XCTAssertNil(second?.scrollY)
    }

    func testTwoPanesShowingTheSameFileKeepIndependentState() {
        let store = EditorPaneStateStore()
        let left = UUID()
        let right = UUID()

        store.recordScroll(for: left, path: "/a/file.swift", x: 0, y: 100)
        store.recordScroll(for: right, path: "/a/file.swift", x: 0, y: 2000)

        XCTAssertEqual(store.state(for: left, path: "/a/file.swift")?.scrollY, 100)
        XCTAssertEqual(store.state(for: right, path: "/a/file.swift")?.scrollY, 2000)
    }

    func testTheStoreIsBoundedByItsCapacityAndEvictsTheColdestSlot() {
        let store = EditorPaneStateStore()
        let first = UUID()
        store.recordScroll(for: first, path: "/p/0", x: 0, y: 0)

        for index in 1 ... EditorPaneStateStore.capacity {
            store.recordScroll(for: UUID(), path: "/p/\(index)", x: 0, y: 0)
        }

        XCTAssertEqual(store.count, EditorPaneStateStore.capacity)
        XCTAssertNil(store.state(for: first, path: "/p/0"))
    }

    func testTouchingASlotKeepsItWarmAgainstEviction() {
        let store = EditorPaneStateStore()
        let first = UUID()
        store.recordScroll(for: first, path: "/p/0", x: 0, y: 0)

        for index in 1 ..< EditorPaneStateStore.capacity {
            store.recordScroll(for: UUID(), path: "/p/\(index)", x: 0, y: 0)
        }
        // Re-touch the oldest entry, then push one more slot in: the store is full,
        // but the re-touched slot must survive because it is no longer the coldest.
        store.recordScroll(for: first, path: "/p/0", x: 0, y: 5)
        store.recordScroll(for: UUID(), path: "/p/new", x: 0, y: 0)

        XCTAssertEqual(store.count, EditorPaneStateStore.capacity)
        XCTAssertEqual(store.state(for: first, path: "/p/0")?.scrollY, 5)
    }
}
