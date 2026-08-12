// @domain: workspace-model
import Foundation

/// What dropping folders onto the sidebar does, decided as a value before anything is
/// mutated. The rule is small and entirely about identity: a folder already carried by an
/// open workspace surfaces that workspace, anything else opens a new one, and a payload
/// that is not a folder is refused outright rather than reinterpreted as its parent.
///
/// It lives here, apart from the view, because it is the rule and not the gesture — the
/// sidebar's drop is one caller, and every assertion about it holds in `TenonCoreTests`
/// with no window.
public enum WorkspaceFolderDrop {
    /// One decided outcome, in the order the folders arrived.
    public enum Action: Equatable {
        /// This folder is already open: reveal the workspace instead of adding a second
        /// row pointed at the same tree.
        case select(UUID)
        /// Nothing is rooted here yet: open a workspace, named the way every other
        /// newly-opened workspace is named.
        case open(name: String, path: URL)
    }

    /// Decide what a drop of `urls` should do against the currently open `workspaces`.
    ///
    /// `isDirectory` is the one question that has to reach the filesystem, so it comes in
    /// as a parameter; every other rule here is pure. Duplicates inside a single drop
    /// collapse — dropping the same folder twice opens it once — and a folder that this
    /// same drop has already decided to open does not queue a second copy.
    public static func plan(
        urls: [URL],
        workspaces: [Workspace],
        isDirectory: (URL) -> Bool = WorkspaceFolderDrop.directoryOnDisk
    ) -> [Action] {
        var actions: [Action] = []
        var decided: Set<String> = []

        for url in urls {
            guard isDirectory(url) else { continue }
            let folder = RecentWorkspaceStore.folderKey(url)
            guard decided.insert(folder).inserted else { continue }

            if let open = workspaces.first(where: {
                RecentWorkspaceStore.folderKey($0.path) == folder
            }) {
                actions.append(.select(open.id))
            } else {
                actions.append(.open(name: WorkspaceName.derived(for: url), path: url))
            }
        }

        return actions
    }

    /// Whether this URL names a folder right now. Bundles (`.app`, `.xcodeproj`) are
    /// directories to the filesystem and folders to nobody, but the sidebar never sees one:
    /// its drop accepts `public.folder`, which they do not conform to.
    public static func directoryOnDisk(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}

extension WorkspaceStore {
    /// Open every dropped folder, selecting rather than duplicating the ones already open.
    /// The last folder in the drop ends up active, which is what a run of `addWorkspace`
    /// calls already does — so a drop of one folder and a drop of five agree about where
    /// the operator lands.
    public func openDroppedFolders(
        _ urls: [URL],
        isDirectory: (URL) -> Bool = WorkspaceFolderDrop.directoryOnDisk
    ) {
        // Decided against the catalog as it stands before anything moves, so two new
        // folders in one drop are still two opens — reading the catalog per action would
        // let the first mutation change the answer for the second.
        let plan = WorkspaceFolderDrop.plan(
            urls: urls,
            workspaces: catalog.workspaces,
            isDirectory: isDirectory
        )

        for action in plan {
            switch action {
            case .select(let id):
                selectWorkspace(id)
            case .open(let name, let path):
                addWorkspace(name: name, path: path)
            }
        }
    }
}
