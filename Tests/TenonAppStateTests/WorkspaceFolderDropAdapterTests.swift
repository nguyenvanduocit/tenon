import AppKit
import SwiftUI
@testable import TenonApp
import TenonCore
import UniformTypeIdentifiers
import XCTest

/// T-138's native adapter receipt. The core tests start after URLs already exist; these
/// assertions mount the shipping drop zone and drive its AppKit destination with the exact
/// `public.file-url` pasteboard representation Finder provides.
@MainActor
final class WorkspaceFolderDropAdapterTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-sidebar-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try await super.tearDown()
    }

    func testFinderFolderUsesFileURLTransportRatherThanFolderTransport() throws {
        let folder = try makeFolder("project")
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: folder))

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertFalse(
            provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier),
            "registering only public.folder prevents Finder's file-URL drag from entering"
        )
    }

    func testShippingDropZoneMountsTheFileURLDestination() throws {
        let mounted = try mountDestination(store: WorkspaceStore())

        XCTAssertTrue(mounted.destination.registeredDraggedTypes.contains(.fileURL))
        XCTAssertFalse(
            mounted.destination.registeredDraggedTypes.contains(.init(UTType.folder.identifier))
        )
        withExtendedLifetime(mounted.host) {}
    }

    func testPlainFileIsRefusedWithoutHighlightOrWorkspaceMutation() throws {
        let file = root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: file)
        let pasteboard = try makePasteboard(urls: [file])
        defer { pasteboard.clearContents() }
        let drag = DraggingInfoStub(pasteboard: pasteboard)
        let store = WorkspaceStore()
        let originalCatalog = store.catalog
        let mounted = try mountDestination(store: store)

        XCTAssertEqual(mounted.destination.draggingEntered(drag), [])
        XCTAssertFalse(mounted.destination.isDropTargeted)
        XCTAssertFalse(mounted.destination.performDragOperation(drag))
        XCTAssertEqual(store.catalog, originalCatalog)
        withExtendedLifetime(mounted.host) {}
    }

    func testFolderEntryTargetsAndExitClearsTheDestination() throws {
        let folder = try makeFolder("project")
        let pasteboard = try makePasteboard(urls: [folder])
        defer { pasteboard.clearContents() }
        let drag = DraggingInfoStub(pasteboard: pasteboard)
        let mounted = try mountDestination(store: WorkspaceStore())

        XCTAssertEqual(mounted.destination.draggingEntered(drag), .copy)
        XCTAssertTrue(mounted.destination.isDropTargeted)
        XCTAssertEqual(drag.numberOfValidItemsForDrop, 1)

        mounted.destination.draggingExited(nil)

        XCTAssertFalse(mounted.destination.isDropTargeted)
        withExtendedLifetime(mounted.host) {}
    }

    func testMixedDropOpensOnlyFoldersInOrderThroughTheMountedDestination() throws {
        let first = try makeFolder("alpha")
        let file = root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: file)
        let second = try makeFolder("beta")
        let pasteboard = try makePasteboard(urls: [first, file, second])
        defer { pasteboard.clearContents() }
        let drag = DraggingInfoStub(pasteboard: pasteboard)
        let store = WorkspaceStore()
        let originalWorkspaceIDs = Set(store.catalog.workspaces.map(\.id))
        let mounted = try mountDestination(store: store)

        XCTAssertEqual(mounted.destination.draggingEntered(drag), .copy)
        XCTAssertEqual(drag.numberOfValidItemsForDrop, 2)
        XCTAssertTrue(mounted.destination.performDragOperation(drag))

        let added = store.catalog.workspaces.filter { !originalWorkspaceIDs.contains($0.id) }
        XCTAssertEqual(added.map(\.path), [first, second])
        XCTAssertEqual(store.catalog.activeWorkspaceID, added.last?.id)
        XCTAssertFalse(mounted.destination.isDropTargeted)
        withExtendedLifetime(mounted.host) {}
    }

    private func mountDestination(
        store: WorkspaceStore
    ) throws -> (
        host: NSHostingView<WorkspaceFolderDropZone<Color>>,
        destination: WorkspaceFolderDropHostingView<Color>
    ) {
        let zone = WorkspaceFolderDropZone(store: store) { Color.clear }
        let host = NSHostingView(rootView: zone)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        host.layoutSubtreeIfNeeded()
        let destination = try XCTUnwrap(
            descendant(of: WorkspaceFolderDropHostingView<Color>.self, in: host),
            "the shipping drop zone must mount the AppKit destination"
        )
        return (host, destination)
    }

    private func descendant<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePasteboard(urls: [URL]) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.tenon.tests.sidebar-drop.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        return pasteboard
    }
}

@MainActor
private final class DraggingInfoStub: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var numberOfValidItemsForDrop = 0
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? {
        nil
    }

    var draggingSourceOperationMask: NSDragOperation {
        .copy
    }

    var draggingLocation: NSPoint {
        .zero
    }

    var draggedImageLocation: NSPoint {
        .zero
    }

    var draggedImage: NSImage? {
        nil
    }

    var draggingSource: Any? {
        nil
    }

    var draggingSequenceNumber: Int {
        1
    }

    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    func slideDraggedImage(to _: NSPoint) {}

    override func namesOfPromisedFilesDropped(
        atDestination _: URL
    ) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using _: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
