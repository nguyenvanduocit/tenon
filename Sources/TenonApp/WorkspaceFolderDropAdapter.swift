// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore
import UniformTypeIdentifiers

/// Finder transports both files and folders as `public.file-url`. AppKit performs the
/// semantic folder check here, before the destination advertises `.copy` or lights up.
enum WorkspaceFolderDropPasteboard {
    static func folderURLs(in pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.folder.identifier],
            ]
        )
        return (objects as? [NSURL])?.map { $0 as URL } ?? []
    }
}

/// The actual AppKit drag destination. SwiftUI's type declaration cannot express
/// "transported as file URL, but admit only folders", because it rejects the Finder drag
/// before the provider callback when registered as `public.folder`.
@MainActor
final class WorkspaceFolderDropHostingView<Content: View>: NSHostingView<Content> {
    var onTargetedChange: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
    private(set) var isDropTargeted = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        validate(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        validate(sender)
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        setTargeted(false)
    }

    override func draggingEnded(_: any NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let folders = WorkspaceFolderDropPasteboard.folderURLs(in: sender.draggingPasteboard)
        sender.numberOfValidItemsForDrop = folders.count
        setTargeted(false)
        guard !folders.isEmpty else { return false }
        onDrop(folders)
        return true
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    private func validate(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let folders = WorkspaceFolderDropPasteboard.folderURLs(in: sender.draggingPasteboard)
        sender.numberOfValidItemsForDrop = folders.count
        setTargeted(!folders.isEmpty)
        return folders.isEmpty ? [] : .copy
    }

    private func setTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        onTargetedChange(targeted)
    }
}

/// Makes the hosted SwiftUI content itself the AppKit destination, so there is no
/// transparent overlay whose hit-testing can miss the drag.
private struct WorkspaceFolderDropHost<Content: View>: NSViewRepresentable {
    let rootView: Content
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context _: Context) -> WorkspaceFolderDropHostingView<Content> {
        let view = WorkspaceFolderDropHostingView(rootView: rootView)
        update(view)
        return view
    }

    func updateNSView(_ view: WorkspaceFolderDropHostingView<Content>, context _: Context) {
        view.rootView = rootView
        update(view)
    }

    private func update(_ view: WorkspaceFolderDropHostingView<Content>) {
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
    }
}

/// T-138 / `WS-FR-025`: a folder dragged from Finder opens or selects its workspace.
/// The core planner owns duplicate/order semantics; this view owns only the native transport
/// boundary and the design-system drop affordance.
struct WorkspaceFolderDropZone<Content: View>: View {
    var store: WorkspaceStore
    let content: Content

    @State private var isTargeted = false

    init(store: WorkspaceStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        WorkspaceFolderDropHost(
            rootView: content,
            isTargeted: $isTargeted,
            onDrop: { folders in
                store.openDroppedFolders(folders, isDirectory: { _ in true })
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(TenonTheme.amber, lineWidth: 2)
                .padding(4)
                .opacity(isTargeted ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
