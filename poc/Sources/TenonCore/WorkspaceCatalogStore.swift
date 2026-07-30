import Foundation
import TenonIntentCore

/// The version-1 wire schema for the persisted workspace catalog, and the pure rules that
/// capture a live catalog into it and restore one out of it.
///
/// The schema is a DTO layer, deliberately not `Codable` on the domain types: `Tab`,
/// `Workspace` and `WorkspaceCatalog` enforce their invariants with preconditions, and a
/// decoder init would make those preconditions reachable from a hostile or stale file.
/// Restore validates first and constructs only what already passed, so a corrupt document
/// degrades or drops — it never traps a launch.
///
/// Forward compatibility: unknown object fields are ignored at every level, and an unknown
/// pane content `type` degrades that one pane to `.empty` while the rest of the catalog
/// restores. The top-level `version` bumps only for incompatible rewrites; a document whose
/// version is newer than this build understands is not restored at all (same shapes could
/// carry different semantics, so best-effort would restore something silently wrong).
public enum WorkspaceCatalogSnapshot {
    public static let version = 1

    public struct Document: Equatable, Sendable, Codable {
        public var version: Int
        public var workspaces: [WorkspaceRecord]
        public var activeWorkspaceID: UUID

        public init(
            version: Int = WorkspaceCatalogSnapshot.version,
            workspaces: [WorkspaceRecord],
            activeWorkspaceID: UUID
        ) {
            self.version = version
            self.workspaces = workspaces
            self.activeWorkspaceID = activeWorkspaceID
        }
    }

    public struct WorkspaceRecord: Equatable, Sendable, Codable {
        public var id: UUID
        public var name: String
        public var path: String
        public var tabs: [TabRecord]
        public var activeTabID: UUID

        public init(
            id: UUID,
            name: String,
            path: String,
            tabs: [TabRecord],
            activeTabID: UUID
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.tabs = tabs
            self.activeTabID = activeTabID
        }
    }

    public struct TabRecord: Equatable, Sendable, Codable {
        public var id: UUID
        public var slots: [SlotRecord]
        public var activeSlotID: UUID?

        public init(id: UUID, slots: [SlotRecord], activeSlotID: UUID?) {
            self.id = id
            self.slots = slots
            self.activeSlotID = activeSlotID
        }
    }

    public struct SlotRecord: Equatable, Sendable, Codable {
        public var id: UUID
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var content: ContentRecord
        /// T-030's per-pane "Set Project Directory…" override. A human choice, so it
        /// round-trips verbatim: no re-resolution, no existence check.
        public var projectRootPin: String?
        /// T-031: what the pane looked like at quit — the placeholder a restored,
        /// not-yet-viewed pane renders without building a surface, and (for `cwd`) the
        /// directory its fresh shell spawns into on first view. Cosmetic and fail-soft:
        /// a cwd that is no longer a directory is dropped at restore, degrading the one
        /// pane to its workspace path.
        public var title: String?
        public var cwd: String?

        public init(
            id: UUID,
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            content: ContentRecord,
            projectRootPin: String? = nil,
            title: String? = nil,
            cwd: String? = nil
        ) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.content = content
            self.projectRootPin = projectRootPin
            self.title = title
            self.cwd = cwd
        }
    }

    /// Type-tagged so a content kind this build has never heard of decodes fine and
    /// degrades one pane, instead of failing the whole document decode.
    public struct ContentRecord: Equatable, Sendable, Codable {
        public var type: String
        public var path: String?
        public var pluginID: String?
        public var viewID: String?
        public var diff: DiffRecord?

        public init(
            type: String,
            path: String? = nil,
            pluginID: String? = nil,
            viewID: String? = nil,
            diff: DiffRecord? = nil
        ) {
            self.type = type
            self.path = path
            self.pluginID = pluginID
            self.viewID = viewID
            self.diff = diff
        }
    }

    public struct DiffRecord: Equatable, Sendable, Codable {
        public var repoPath: String
        public var filePath: String
        public var staged: Bool
        public var untracked: Bool
        public var origPath: String?
        public var fileName: String
        public var title: String

        public init(
            repoPath: String,
            filePath: String,
            staged: Bool,
            untracked: Bool,
            origPath: String?,
            fileName: String,
            title: String
        ) {
            self.repoPath = repoPath
            self.filePath = filePath
            self.staged = staged
            self.untracked = untracked
            self.origPath = origPath
            self.fileName = fileName
            self.title = title
        }
    }

    /// Capture the live catalog and the per-pane state `SurfacePool` holds: pins, plus
    /// the T-031 placeholder data (last title, last cwd). Entries for panes outside the
    /// catalog (already closed) are not recorded.
    public static func document(
        capturing catalog: WorkspaceCatalog,
        pins: [UUID: URL],
        titles: [UUID: String] = [:],
        cwds: [UUID: URL] = [:]
    ) -> Document {
        Document(
            workspaces: catalog.workspaces.map { workspace in
                WorkspaceRecord(
                    id: workspace.id,
                    name: workspace.name,
                    path: workspace.path.path,
                    tabs: workspace.tabs.map { tab in
                        TabRecord(
                            id: tab.id,
                            slots: tab.slots.map { slot in
                                SlotRecord(
                                    id: slot.id,
                                    x: slot.rect.x,
                                    y: slot.rect.y,
                                    width: slot.rect.width,
                                    height: slot.rect.height,
                                    content: record(of: slot.content),
                                    projectRootPin: pins[slot.id]?.path,
                                    title: titles[slot.id],
                                    cwd: cwds[slot.id]?.path
                                )
                            },
                            activeSlotID: tab.activeSlotID
                        )
                    },
                    activeTabID: workspace.activeTabID
                )
            },
            activeWorkspaceID: catalog.activeWorkspaceID
        )
    }

    /// Rebuild a catalog from a document, fail-soft at every level:
    ///
    /// - a workspace whose folder no longer exists is dropped, never resurrected, and
    ///   never takes the others with it; nothing restorable at all returns nil;
    /// - a structurally invalid tab (broken layout, duplicated identity) is dropped;
    /// - a pane whose content cannot be honoured — deleted file, unknown plugin view,
    ///   vanished diff repo, or a content type from a newer build — degrades to `.empty`,
    ///   keeping its place in the layout;
    /// - a pane's project-root pin survives verbatim even when its pane degrades;
    /// - saved active selections are honoured when their target survived, and fall back
    ///   to the first survivor when it did not.
    public static func restore(
        _ document: Document,
        isDirectory: (String) -> Bool,
        isFileReadable: (String) -> Bool,
        isKnownPluginView: (_ pluginID: String, _ viewID: String) -> Bool
    ) -> RestoredWorkspaceCatalog? {
        var seenWorkspaceIDs = Set<UUID>()
        var seenTabIDs = Set<UUID>()
        var seenSlotIDs = Set<UUID>()
        var workspaces: [Workspace] = []
        var pins: [UUID: URL] = [:]
        var titles: [UUID: String] = [:]
        var cwds: [UUID: URL] = [:]

        for workspaceRecord in document.workspaces {
            guard isDirectory(workspaceRecord.path),
                  !seenWorkspaceIDs.contains(workspaceRecord.id)
            else { continue }

            var tabs: [Tab] = []
            var workspacePins: [UUID: URL] = [:]
            var workspaceTitles: [UUID: String] = [:]
            var workspaceCwds: [UUID: URL] = [:]

            for tabRecord in workspaceRecord.tabs {
                guard !seenTabIDs.contains(tabRecord.id) else { continue }

                var slots: [WorkspaceSlot] = []
                var tabPins: [UUID: URL] = [:]
                var tabTitles: [UUID: String] = [:]
                var tabCwds: [UUID: URL] = [:]
                var identitiesHold = true
                for slotRecord in tabRecord.slots {
                    guard seenSlotIDs.insert(slotRecord.id).inserted else {
                        identitiesHold = false
                        break
                    }
                    slots.append(WorkspaceSlot(
                        id: slotRecord.id,
                        rect: GridRect(
                            x: slotRecord.x,
                            y: slotRecord.y,
                            width: slotRecord.width,
                            height: slotRecord.height
                        ),
                        content: content(
                            of: slotRecord.content,
                            isDirectory: isDirectory,
                            isFileReadable: isFileReadable,
                            isKnownPluginView: isKnownPluginView
                        )
                    ))
                    if let pin = slotRecord.projectRootPin {
                        tabPins[slotRecord.id] = URL(
                            fileURLWithPath: pin,
                            isDirectory: true
                        )
                    }
                    // T-031 placeholder data. Purely cosmetic (plus the spawn directory),
                    // so it degrades value by value: an empty title is no title, and a
                    // cwd that stopped being a directory falls back to the workspace path
                    // by simply not being seeded.
                    if let title = slotRecord.title, !title.isEmpty {
                        tabTitles[slotRecord.id] = title
                    }
                    if let cwd = slotRecord.cwd, isDirectory(cwd) {
                        tabCwds[slotRecord.id] = URL(
                            fileURLWithPath: cwd,
                            isDirectory: true
                        )
                    }
                }
                guard identitiesHold,
                      SpatialLayout.isValid(slots.map(\.spatialSlot))
                else {
                    seenSlotIDs.subtract(slots.map(\.id))
                    continue
                }

                let activeSlotID: UUID?
                if slots.isEmpty {
                    activeSlotID = nil
                } else if let recorded = tabRecord.activeSlotID,
                          slots.contains(where: { $0.id == recorded })
                {
                    activeSlotID = recorded
                } else {
                    activeSlotID = slots[0].id
                }

                tabs.append(Tab(
                    id: tabRecord.id,
                    slots: slots,
                    activeSlotID: activeSlotID
                ))
                seenTabIDs.insert(tabRecord.id)
                workspacePins.merge(tabPins) { _, new in new }
                workspaceTitles.merge(tabTitles) { _, new in new }
                workspaceCwds.merge(tabCwds) { _, new in new }
            }

            guard !tabs.isEmpty else { continue }
            let activeTabID = tabs.contains(where: { $0.id == workspaceRecord.activeTabID })
                ? workspaceRecord.activeTabID
                : tabs[0].id
            guard Workspace.isValid(tabs: tabs, activeTabID: activeTabID) else { continue }

            workspaces.append(Workspace(
                id: workspaceRecord.id,
                name: workspaceRecord.name,
                path: URL(fileURLWithPath: workspaceRecord.path, isDirectory: true),
                tabs: tabs,
                activeTabID: activeTabID
            ))
            seenWorkspaceIDs.insert(workspaceRecord.id)
            pins.merge(workspacePins) { _, new in new }
            titles.merge(workspaceTitles) { _, new in new }
            cwds.merge(workspaceCwds) { _, new in new }
        }

        guard !workspaces.isEmpty else { return nil }
        let activeWorkspaceID = workspaces.contains(where: {
            $0.id == document.activeWorkspaceID
        })
            ? document.activeWorkspaceID
            : workspaces[0].id
        // Everything the domain preconditions assert was validated piecewise above; this
        // final gate keeps them unreachable even if the rules above ever drift apart.
        guard WorkspaceCatalog.isValid(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID
        ) else { return nil }

        return RestoredWorkspaceCatalog(
            catalog: WorkspaceCatalog(
                workspaces: workspaces,
                activeWorkspaceID: activeWorkspaceID
            ),
            pins: pins,
            titles: titles,
            cwds: cwds
        )
    }

    /// Launch precedence: a bare launch restores the saved catalog as saved; an explicit
    /// launch directory adds a workspace for that folder — or selects the open one — and
    /// never replaces the restored tree. With nothing restored, the launch directory (or
    /// the caller's fallback) seeds a fresh single-workspace catalog, exactly as before
    /// this store existed.
    public static func launchCatalog(
        restored: RestoredWorkspaceCatalog?,
        launchDirectory: URL?,
        launchContent: SlotContent,
        fallbackDirectory: URL
    ) -> RestoredWorkspaceCatalog {
        guard let restored else {
            return RestoredWorkspaceCatalog(
                catalog: WorkspaceCatalog(
                    path: launchDirectory ?? fallbackDirectory,
                    content: launchContent
                ),
                pins: [:]
            )
        }
        guard let launchDirectory else { return restored }

        var catalog = restored.catalog
        let launchKey = RecentWorkspaceStore.folderKey(launchDirectory)
        if let open = catalog.workspaces.first(where: {
            RecentWorkspaceStore.folderKey($0.path) == launchKey
        }) {
            catalog.selectWorkspace(open.id)
        } else {
            catalog.addWorkspace(
                name: launchDirectory.lastPathComponent,
                path: launchDirectory,
                content: launchContent
            )
        }
        return RestoredWorkspaceCatalog(
            catalog: catalog,
            pins: restored.pins,
            titles: restored.titles,
            cwds: restored.cwds
        )
    }

    private static func record(of content: SlotContent) -> ContentRecord {
        switch content {
        case .terminal:
            return ContentRecord(type: "terminal")
        case .changes:
            return ContentRecord(type: "changes")
        case .docs:
            return ContentRecord(type: "docs")
        case .empty:
            return ContentRecord(type: "empty")
        case .file(let path):
            return ContentRecord(type: "file", path: path)
        case let .pluginView(pluginID, viewID):
            return ContentRecord(
                type: "pluginView",
                pluginID: pluginID.rawValue,
                viewID: viewID
            )
        case .diff(let request):
            switch request.source {
            case let .git(repoPath, path, staged, untracked, origPath):
                return ContentRecord(type: "diff", diff: DiffRecord(
                    repoPath: repoPath,
                    filePath: path,
                    staged: staged,
                    untracked: untracked,
                    origPath: origPath,
                    fileName: request.fileName,
                    title: request.title
                ))
            case .inline:
                // The two texts are live plugin state, not workspace structure — the
                // same reason a pane's cwd is not persisted. The pane survives as a
                // blank one holding the layout.
                return ContentRecord(type: "empty")
            }
        }
    }

    private static func content(
        of record: ContentRecord,
        isDirectory: (String) -> Bool,
        isFileReadable: (String) -> Bool,
        isKnownPluginView: (String, String) -> Bool
    ) -> SlotContent {
        switch record.type {
        case "terminal":
            return .terminal
        case "changes":
            return .changes
        case "docs":
            return .docs
        case "empty":
            return .empty
        case "file":
            guard let path = record.path, isFileReadable(path) else { return .empty }
            return .file(path: path)
        case "pluginView":
            guard let rawPluginID = record.pluginID,
                  let viewID = record.viewID,
                  let pluginID = try? PluginID(rawPluginID),
                  isKnownPluginView(rawPluginID, viewID)
            else { return .empty }
            return .pluginView(pluginID: pluginID, viewID: viewID)
        case "diff":
            guard let diff = record.diff, isDirectory(diff.repoPath) else { return .empty }
            return .diff(DiffRequest(
                source: .git(
                    repoPath: diff.repoPath,
                    path: diff.filePath,
                    staged: diff.staged,
                    untracked: diff.untracked,
                    origPath: diff.origPath
                ),
                fileName: diff.fileName,
                title: diff.title
            ))
        default:
            return .empty
        }
    }
}

/// What restore hands back: the validated catalog, the per-pane project-root pins the
/// shell re-applies through `SurfacePool.pinProjectRoot`, and the T-031 placeholder data
/// (last recorded title and cwd per pane) the shell seeds through
/// `SurfacePool.setTitle`/`seedRestoredDirectory` — all without building a surface.
public struct RestoredWorkspaceCatalog: Equatable, Sendable {
    public let catalog: WorkspaceCatalog
    public let pins: [UUID: URL]
    public let titles: [UUID: String]
    public let cwds: [UUID: URL]

    public init(
        catalog: WorkspaceCatalog,
        pins: [UUID: URL],
        titles: [UUID: String] = [:],
        cwds: [UUID: URL] = [:]
    ) {
        self.catalog = catalog
        self.pins = pins
        self.titles = titles
        self.cwds = cwds
    }
}

/// Persists the workspace catalog document, mirroring `SettingsStore`'s durability
/// (`DurableJSONFile` exclusive lock + atomic replace) but with write coalescing: every
/// workspace mutation notes a change, and one debounced write lands per burst. `flush()`
/// is the quit path — it writes whatever is pending without waiting.
public actor WorkspaceCatalogStore {
    public static let maxDocumentBytes = 16 * 1024 * 1024

    private let fileURL: URL
    private let debounce: Duration
    private var pending: WorkspaceCatalogSnapshot.Document?
    private var scheduled: Task<Void, Never>?
    public private(set) var writeCount = 0
    public private(set) var lastWriteError: String?

    public init(fileURL: URL, debounce: Duration = .milliseconds(500)) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    /// Launch-time read. Returns nil — never throws, never traps — for a missing,
    /// oversized, syntactically corrupt, ambiguous (duplicate keys), undecodable, or
    /// newer-versioned file. Declining to restore leaves the file's bytes untouched.
    public static func loadDocument(
        at fileURL: URL
    ) -> WorkspaceCatalogSnapshot.Document? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let document = try? DurableJSONFile.withExclusiveLock(for: fileURL) {
            () -> WorkspaceCatalogSnapshot.Document? in
            guard let data = try? Data(contentsOf: fileURL),
                  data.count <= maxDocumentBytes,
                  let version = try? StrictJSONDocument.topLevelVersion(in: data),
                  version == WorkspaceCatalogSnapshot.version
            else { return nil }
            return try? JSONDecoder().decode(
                WorkspaceCatalogSnapshot.Document.self,
                from: data
            )
        }
        return document ?? nil
    }

    /// Record the latest state and schedule one write per debounce window. Callers hand
    /// over a full document every time; the last one in the window is what lands.
    public func noteChange(_ document: WorkspaceCatalogSnapshot.Document) {
        pending = document
        guard scheduled == nil else { return }
        scheduled = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            await self.commitScheduledWrite()
        }
    }

    /// Write whatever is pending right now — the quit path, where a debounce window
    /// would outlive the process.
    public func flush() {
        scheduled?.cancel()
        scheduled = nil
        writePending()
    }

    private func commitScheduledWrite() {
        guard !Task.isCancelled else { return }
        scheduled = nil
        writePending()
    }

    private func writePending() {
        guard let document = pending else { return }
        pending = nil
        do {
            try Self.write(document, to: fileURL)
            writeCount += 1
            lastWriteError = nil
        } catch {
            // Persistence failure must not take the session down; the state stays live
            // in memory and the next mutation retries.
            lastWriteError = String(describing: error)
        }
    }

    private static func write(
        _ document: WorkspaceCatalogSnapshot.Document,
        to fileURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try DurableJSONFile.withExclusiveLock(for: fileURL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
            ]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
