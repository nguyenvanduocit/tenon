// @domain: workspace-model
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
        /// T-097: how the person marked and tinted this workspace. Absent in every document
        /// written before customisation existed, which is the whole migration: a missing
        /// key decodes to nil and restores as `WorkspaceAppearance.default`, so an older
        /// catalog comes back looking exactly as it did.
        public var appearance: AppearanceRecord?
        /// Sleep Workspace: whether this workspace shows in the sidebar's main list.
        /// Absent in every document written before this field existed, which decodes to
        /// nil and restores as `.visible` — the same forward-compatibility shape
        /// `appearance: AppearanceRecord?` already has.
        public var visibility: String?
        public var tabs: [TabRecord]
        public var activeTabID: UUID

        public init(
            id: UUID,
            name: String,
            path: String,
            appearance: AppearanceRecord? = nil,
            visibility: String? = nil,
            tabs: [TabRecord],
            activeTabID: UUID
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.appearance = appearance
            self.visibility = visibility
            self.tabs = tabs
            self.activeTabID = activeTabID
        }
    }

    /// Written as raw tokens rather than as the enums themselves: a mark or tint this build
    /// has never heard of degrades that one value to Tenon's default and keeps the workspace,
    /// exactly as an unknown pane content degrades one pane.
    public struct AppearanceRecord: Equatable, Sendable, Codable {
        public var symbol: String?
        public var accent: String?
        public var customIconID: UUID?
        public var customIconPNG: Data?

        public init(
            symbol: String?,
            accent: String?,
            customIconID: UUID? = nil,
            customIconPNG: Data? = nil
        ) {
            self.symbol = symbol
            self.accent = accent
            self.customIconID = customIconID
            self.customIconPNG = customIconPNG
        }
    }

    public struct TabRecord: Equatable, Sendable, Codable {
        public var id: UUID
        public var slots: [SlotRecord]
        public var activeSlotID: UUID?
        /// T-105: the number the tab is called by until its content names itself. Optional
        /// because catalogs written before tabs had one must still restore — those get their
        /// numbers from strip order at load, once, and keep them from then on.
        public var number: Int?

        public init(id: UUID, slots: [SlotRecord], activeSlotID: UUID?, number: Int? = nil) {
            self.id = id
            self.slots = slots
            self.activeSlotID = activeSlotID
            self.number = number
        }
    }

    public struct SlotRecord: Equatable, Sendable, Codable {
        public var id: UUID
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var content: ContentRecord
        /// T-031: what the pane looked like at quit — the placeholder a restored,
        /// not-yet-viewed pane renders without building a surface, and (for `cwd`) the
        /// directory its fresh shell spawns into on first view. Cosmetic and fail-soft:
        /// a cwd that is no longer a directory is dropped at restore, degrading the one
        /// pane to its workspace path.
        public var title: String?
        public var cwd: String?
        /// A user-pinned pane label. Separate from `title`, which is the last dynamic PTY
        /// title used only for an unmaterialised restore placeholder.
        public var customTitle: String?

        public init(
            id: UUID,
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            content: ContentRecord,
            title: String? = nil,
            cwd: String? = nil,
            customTitle: String? = nil
        ) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.content = content
            self.title = title
            self.cwd = cwd
            self.customTitle = customTitle
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
        public var agentSession: AgentSessionRecord?

        public init(
            type: String,
            path: String? = nil,
            pluginID: String? = nil,
            viewID: String? = nil,
            diff: DiffRecord? = nil,
            agentSession: AgentSessionRecord? = nil
        ) {
            self.type = type
            self.path = path
            self.pluginID = pluginID
            self.viewID = viewID
            self.diff = diff
            self.agentSession = agentSession
        }
    }

    public struct AgentSessionRecord: Equatable, Sendable, Codable {
        public var provider: String
        public var sessionID: String
        public var transcriptPath: String
        public var title: String?

        public init(
            provider: String,
            sessionID: String,
            transcriptPath: String,
            title: String?
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.transcriptPath = transcriptPath
            self.title = title
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

    /// Capture the live catalog and the T-031 placeholder data `SurfacePool` holds (last
    /// title and cwd). Entries for panes outside the catalog (already closed) are not
    /// recorded.
    ///
    /// `agentSessions` carries the one fact a terminal pane cannot rebuild for itself
    /// (T-145): which recorded session was running in it. The pane→session binding lives in
    /// memory for the life of the process, so a pane that was doing the work at quit is
    /// exactly the pane that would come back with no route to its own transcript. Its caller
    /// decides eligibility; this only writes down what it is handed.
    public static func document(
        capturing catalog: WorkspaceCatalog,
        titles: [UUID: String] = [:],
        cwds: [UUID: URL] = [:],
        agentSessions: [UUID: AgentSessionRef] = [:]
    ) -> Document {
        Document(
            workspaces: catalog.workspaces.map { workspace in
                WorkspaceRecord(
                    id: workspace.id,
                    name: workspace.name,
                    path: workspace.path.path,
                    appearance: appearanceRecord(of: workspace.appearance),
                    visibility: visibilityRecord(of: workspace.visibility),
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
                                    content: record(
                                        of: slot.content,
                                        agentSession: agentSessions[slot.id]
                                    ),
                                    title: titles[slot.id],
                                    cwd: cwds[slot.id]?.path,
                                    customTitle: slot.customTitle
                                )
                            },
                            activeSlotID: tab.activeSlotID,
                            number: tab.number
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
        var titles: [UUID: String] = [:]
        var cwds: [UUID: URL] = [:]

        for workspaceRecord in document.workspaces {
            guard isDirectory(workspaceRecord.path),
                  !seenWorkspaceIDs.contains(workspaceRecord.id)
            else { continue }

            var tabs: [Tab] = []
            var workspaceTitles: [UUID: String] = [:]
            var workspaceCwds: [UUID: URL] = [:]

            for tabRecord in workspaceRecord.tabs {
                guard !seenTabIDs.contains(tabRecord.id) else { continue }

                var slots: [WorkspaceSlot] = []
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
                        ),
                        customTitle: slotRecord.customTitle
                    ))
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

                // A catalog written before T-105 records no number, so the tab takes its
                // place in the restored strip — once. From the next launch the recorded
                // number is what comes back, and reordering stops renaming anything.
                tabs.append(Tab(
                    id: tabRecord.id,
                    slots: slots,
                    activeSlotID: activeSlotID,
                    number: tabRecord.number ?? tabs.count + 1
                ))
                seenTabIDs.insert(tabRecord.id)
                workspaceTitles.merge(tabTitles) { _, new in new }
                workspaceCwds.merge(tabCwds) { _, new in new }
            }

            guard !tabs.isEmpty else { continue }
            let activeTabID = tabs.contains(where: { $0.id == workspaceRecord.activeTabID })
                ? workspaceRecord.activeTabID
                : tabs[0].id
            guard Workspace.isValid(tabs: tabs, activeTabID: activeTabID) else { continue }

            let workspacePath = URL(
                fileURLWithPath: workspaceRecord.path,
                isDirectory: true
            )
            workspaces.append(Workspace(
                id: workspaceRecord.id,
                // A name that survived as whitespace, or as a document hand-edited to
                // nothing, comes back as the derived default rather than as a blank row.
                name: WorkspaceName.sanitized(workspaceRecord.name)
                    ?? WorkspaceName.derived(for: workspacePath),
                path: workspacePath,
                appearance: appearance(of: workspaceRecord.appearance),
                visibility: visibility(of: workspaceRecord.visibility),
                tabs: tabs,
                activeTabID: activeTabID
            ))
            seenWorkspaceIDs.insert(workspaceRecord.id)
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
                )
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
                name: WorkspaceName.derived(for: launchDirectory),
                path: launchDirectory,
                content: launchContent
            )
        }
        return RestoredWorkspaceCatalog(
            catalog: catalog,
            titles: restored.titles,
            cwds: restored.cwds
        )
    }

    /// The default appearance writes nothing: an uncustomised catalog produces the same
    /// bytes it produced before customisation existed, so the common document does not grow
    /// a key that says "unchanged".
    private static func appearanceRecord(
        of appearance: WorkspaceAppearance
    ) -> AppearanceRecord? {
        guard !appearance.isDefault else { return nil }
        return AppearanceRecord(
            symbol: appearance.symbol.rawValue,
            accent: appearance.accent?.rawValue,
            customIconID: appearance.customIcon?.id,
            customIconPNG: appearance.customIcon?.pngData
        )
    }

    private static func appearance(of record: AppearanceRecord?) -> WorkspaceAppearance {
        guard let record else { return .default }
        let customIcon: WorkspaceCustomIcon? = if let id = record.customIconID,
                                                  let png = record.customIconPNG
        {
            WorkspaceCustomIcon(id: id, pngData: png)
        } else {
            nil
        }
        return WorkspaceAppearance(
            symbol: record.symbol.flatMap(WorkspaceSymbol.init(rawValue:)) ?? .default,
            accent: record.accent.flatMap(AccentColor.init(rawValue:)),
            customIcon: customIcon
        )
    }

    /// `.visible` writes nothing, matching `appearanceRecord`'s "default writes nothing"
    /// shape — an uncustomised catalog produces the same document either way.
    private static func visibilityRecord(of visibility: WorkspaceVisibility) -> String? {
        visibility == .background ? "background" : nil
    }

    private static func visibility(of record: String?) -> WorkspaceVisibility {
        record == "background" ? .background : .visible
    }

    private static func sessionRecord(of ref: AgentSessionRef) -> AgentSessionRecord {
        AgentSessionRecord(
            provider: ref.provider.rawValue,
            sessionID: ref.sessionID,
            transcriptPath: ref.transcriptPath,
            title: ref.title
        )
    }

    /// The session a record can still be read as, or nil for every reason it cannot be: no
    /// session written down, a provider this build cannot name, a transcript no longer on
    /// disk, or a reference the value type refuses. One answer for both content kinds that
    /// carry a session, so a pane restored from a terminal and a pane restored from the
    /// session list cannot drift apart on what counts as readable.
    private static func sessionRef(
        of record: ContentRecord,
        isFileReadable: (String) -> Bool
    ) -> AgentSessionRef? {
        guard let session = record.agentSession,
              let provider = AgentSessionProvider(rawValue: session.provider),
              isFileReadable(session.transcriptPath)
        else { return nil }
        return AgentSessionRef(
            provider: provider,
            sessionID: session.sessionID,
            transcriptPath: session.transcriptPath,
            title: session.title
        )
    }

    private static func record(
        of content: SlotContent,
        agentSession: AgentSessionRef? = nil
    ) -> ContentRecord {
        switch content {
        case .terminal:
            // Recorded as the terminal it is, with the session travelling beside it: the
            // reading is what this pane comes back AS, and the shell is what it falls back
            // to when the transcript is gone. A build that has never heard of the field
            // reads the type it already knows and opens a terminal.
            return ContentRecord(
                type: "terminal",
                agentSession: agentSession.map(sessionRecord(of:))
            )
        case .changes:
            return ContentRecord(type: "changes")
        case .automation:
            return ContentRecord(type: "automation")
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
        case .agentSession(let ref):
            return ContentRecord(type: "agentSession", agentSession: sessionRecord(of: ref))
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
            // A terminal that was running an agent comes back reading that session, which is
            // the same pane the session list's "Details" opens: the transcript, the evidence,
            // and the offer to resume. With nothing readable at the path there is no reading
            // to draw and the pane is still a terminal — this is the one content kind whose
            // degraded form is not the blank pane, because the pane it degrades to is real.
            if let ref = sessionRef(of: record, isFileReadable: isFileReadable) {
                return .agentSession(ref)
            }
            return .terminal
        case "changes":
            return .changes
        case "automation":
            return .automation
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
        case "agentSession":
            // A transcript that is gone is the whole content: there is no session to read and
            // nothing the pane could honestly draw, so it comes back as the blank pane holding
            // its place in the layout — the same answer a deleted file's pane gives.
            guard let ref = sessionRef(of: record, isFileReadable: isFileReadable) else {
                return .empty
            }
            return .agentSession(ref)
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

/// What restore hands back: the validated catalog and the T-031 placeholder data (last
/// recorded title and cwd per pane) the shell seeds through
/// `SurfacePool.setTitle`/`seedSpawnDirectory` — all without building a surface.
public struct RestoredWorkspaceCatalog: Equatable, Sendable {
    public let catalog: WorkspaceCatalog
    public let titles: [UUID: String]
    public let cwds: [UUID: URL]

    public init(
        catalog: WorkspaceCatalog,
        titles: [UUID: String] = [:],
        cwds: [UUID: URL] = [:]
    ) {
        self.catalog = catalog
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
            self.commitScheduledWrite()
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
