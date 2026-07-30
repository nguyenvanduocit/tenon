import Foundation
import XCTest
@testable import TenonApp

/// T-016: a file pane watches its file, and the stale-disk-versus-unsaved-edits rule
/// is explicit — our own save echoing back is ignored, a clean pane reloads, a dirty
/// pane keeps the user's buffer and flags the conflict. The watch is a resource with
/// a bounded lifetime: it dies with the pane's model (invariant 10).
@MainActor
final class FileDocumentExternalChangeTests: XCTestCase {
    func testTheStaleDiskRuleIsExplicit() {
        XCTAssertEqual(
            ExternalFileChange.action(
                diskText: "same",
                savedText: "same",
                isDirty: true
            ),
            .ignore,
            "Disk matching what we last knew is our own save echoing back"
        )
        XCTAssertEqual(
            ExternalFileChange.action(
                diskText: "new",
                savedText: "old",
                isDirty: false
            ),
            .reload,
            "A clean pane has no user work to lose"
        )
        XCTAssertEqual(
            ExternalFileChange.action(
                diskText: "new",
                savedText: "old",
                isDirty: true
            ),
            .conflict,
            "A dirty pane keeps the user's buffer — reloading would destroy it"
        )
    }

    func testExternalChangeReloadsACleanPane() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)
        await model.load("/w/file.swift")

        disk.set("two")
        await model.reloadAfterExternalChange()

        XCTAssertEqual(text(in: model.state), "two")
        XCTAssertEqual(model.revision, 1)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.hasDiskConflict)
    }

    func testExternalChangeKeepsUnsavedEditsAndFlagsTheConflict() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)
        await model.load("/w/file.swift")
        model.edited("mine")

        disk.set("two")
        await model.reloadAfterExternalChange()

        XCTAssertEqual(model.pendingSnapshot, "mine")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.hasDiskConflict)
        // No reload was pushed at the editor: the user's buffer stays on screen.
        XCTAssertEqual(model.revision, 0)
        // The model's disk baseline moved to what is really there now, so the next
        // identical watcher event is recognised as no news.
        XCTAssertEqual(model.savedTextHash, "two".hashValue)

        await model.save()
        XCTAssertEqual(disk.current, "mine")
        XCTAssertFalse(model.hasDiskConflict)
        XCTAssertFalse(model.isDirty)
    }

    func testOwnSaveIsNotTreatedAsAnExternalChange() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)
        await model.load("/w/file.swift")
        model.edited("mine")
        await model.save()
        XCTAssertEqual(disk.current, "mine")

        await model.reloadAfterExternalChange()

        XCTAssertEqual(model.revision, 0)
        XCTAssertFalse(model.hasDiskConflict)
        XCTAssertFalse(model.isDirty)
    }

    func testABufferMatchingTheNewDiskTextIsCleanNotConflicted() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)
        await model.load("/w/file.swift")
        model.edited("two")

        disk.set("two")
        await model.reloadAfterExternalChange()

        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.hasDiskConflict)
    }

    func testTextFilesAreWatchedAndTheWatchDiesWithItsPane() async {
        let recorder = WatchRecorder()
        let disk = DiskBox("one")
        var model: FileDocumentModel? = makeModel(
            disk: disk,
            recorder: recorder
        )
        await model?.load("/w/file.swift")

        XCTAssertEqual(recorder.watchedPaths, ["/w/file.swift"])
        XCTAssertEqual(recorder.cancelCount, 0)

        model = nil
        XCTAssertEqual(
            recorder.cancelCount,
            1,
            "The watch must be torn down when the pane's model goes away"
        )
    }

    func testSwitchingFilesReplacesTheWatch() async {
        let recorder = WatchRecorder()
        let disk = DiskBox("one")
        let model = makeModel(disk: disk, recorder: recorder)

        await model.load("/w/first.swift")
        await model.load("/w/second.swift")

        XCTAssertEqual(
            recorder.watchedPaths,
            ["/w/first.swift", "/w/second.swift"]
        )
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    func testUnreadableFilesAreNotWatched() async {
        let recorder = WatchRecorder()
        let io = FileDocumentIO(
            read: { _ in .unavailable("binary blob") },
            write: { _ in }
        )
        let model = FileDocumentModel(
            io: io,
            watchFiles: { path, _ in
                recorder.recordWatch(path)
                return EditorFileWatchToken { recorder.recordCancel() }
            }
        )

        await model.load("/w/blob.bin")

        XCTAssertEqual(recorder.watchedPaths, [])
    }

    func testAWatcherEventDrivesTheReloadThroughTheModel() async {
        let recorder = WatchRecorder()
        let disk = DiskBox("one")
        let model = makeModel(disk: disk, recorder: recorder)
        await model.load("/w/file.swift")

        disk.set("two")
        recorder.fireChange()
        await waitUntil("the watcher-driven reload lands") {
            self.text(in: model.state) == "two"
        }

        XCTAssertEqual(model.revision, 1)
    }

    func testUnsavedBufferIsRestoredAfterAPaneSwitch() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)

        await model.load(
            "/w/file.swift",
            restoring: EditorPaneState(
                path: "/w/file.swift",
                pendingText: "mine",
                savedTextHash: "one".hashValue
            )
        )

        XCTAssertEqual(text(in: model.state), "mine")
        XCTAssertEqual(model.pendingSnapshot, "mine")
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(
            model.hasDiskConflict,
            "The disk did not move underneath the buffer — this is just dirty"
        )
    }

    func testRestoreOntoAChangedDiskFlagsTheConflict() async {
        let disk = DiskBox("two")
        let model = makeModel(disk: disk)

        await model.load(
            "/w/file.swift",
            restoring: EditorPaneState(
                path: "/w/file.swift",
                pendingText: "mine",
                savedTextHash: "one".hashValue
            )
        )

        XCTAssertEqual(text(in: model.state), "mine")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.hasDiskConflict)
        XCTAssertEqual(model.savedTextHash, "two".hashValue)
    }

    func testARememberedConflictSurvivesThePaneSwitch() async {
        let disk = DiskBox("two")
        let model = makeModel(disk: disk)

        await model.load(
            "/w/file.swift",
            restoring: EditorPaneState(
                path: "/w/file.swift",
                pendingText: "mine",
                savedTextHash: "two".hashValue,
                conflicted: true
            )
        )

        XCTAssertTrue(model.hasDiskConflict)
    }

    func testARestoredBufferEqualToDiskIsClean() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)

        await model.load(
            "/w/file.swift",
            restoring: EditorPaneState(
                path: "/w/file.swift",
                pendingText: "one",
                savedTextHash: "one".hashValue
            )
        )

        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.hasDiskConflict)
    }

    func testBufferChangesArePublishedForThePerSlotStore() async {
        let disk = DiskBox("one")
        let model = makeModel(disk: disk)
        var published: [(pending: String?, conflicted: Bool)] = []
        model.onBufferStateChange = { [weak model] in
            guard let model else { return }
            published.append((
                pending: model.isDirty ? model.pendingSnapshot : nil,
                conflicted: model.hasDiskConflict
            ))
        }

        await model.load("/w/file.swift")
        model.edited("mine")
        await model.save()

        XCTAssertEqual(
            published.map(\.pending),
            [nil, "mine", nil],
            "Load, edit, and save must each publish the buffer state"
        )
    }

    // MARK: - Helpers

    private func makeModel(
        disk: DiskBox,
        recorder: WatchRecorder? = nil
    ) -> FileDocumentModel {
        var watchFiles: FileDocumentModel.WatchFiles?
        if let recorder {
            watchFiles = { path, onChange in
                recorder.recordWatch(path)
                recorder.setOnChange(onChange)
                return EditorFileWatchToken { recorder.recordCancel() }
            }
        }
        return FileDocumentModel(
            io: FileDocumentIO(
                read: { _ in .text(disk.current) },
                write: { request in disk.set(request.text) }
            ),
            watchFiles: watchFiles
        )
    }

    private func waitUntil(
        _ what: String,
        _ condition: () -> Bool
    ) async {
        for _ in 0 ..< 1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting until \(what)")
    }

    private func text(in state: FileDocumentModel.State) -> String? {
        guard case let .text(text) = state else {
            return nil
        }
        return text
    }
}

/// The "disk": a thread-safe mutable file body the fake IO reads and writes.
private final class DiskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String) {
        self.text = text
    }

    var current: String {
        lock.withLock { text }
    }

    func set(_ newText: String) {
        lock.withLock { text = newText }
    }
}

/// Records every watch the model starts and every cancellation its token performs,
/// and lets a test fire the change callback the way FSEvents would.
private final class WatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var watched: [String] = []
    private var cancels = 0
    private var onChange: (@Sendable () -> Void)?

    var watchedPaths: [String] {
        lock.withLock { watched }
    }

    var cancelCount: Int {
        lock.withLock { cancels }
    }

    func recordWatch(_ path: String) {
        lock.withLock { watched.append(path) }
    }

    func recordCancel() {
        lock.withLock { cancels += 1 }
    }

    func setOnChange(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = callback }
    }

    func fireChange() {
        let callback = lock.withLock { onChange }
        callback?()
    }
}
