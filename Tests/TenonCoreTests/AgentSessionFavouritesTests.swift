import Foundation
@testable import TenonBundledPlugins
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-148: the shipped `claude-sessions` plugin's favourites, driven through the compiled port.
///
/// The claim these tests make is narrow and is the whole point of the feature: a mark
/// **outlives the recent cutoff**. The pane slices its scan to the `limit` setting, so a
/// favourite that merely re-sorted inside that window would disappear from the pane exactly
/// when it becomes worth remembering. Claude's listing keeps a marked transcript out of the
/// slice; Codex's bounded SQLite index is asked a second time, by ID.
///
/// The test keeps the public plugin boundary intact while exercising the compiled program
/// directly, so it does not depend on the registry owner landing in the same worktree turn.
final class AgentSessionFavouritesTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    private enum Fixture {
        static let workspace = "AAAAAAAA-0000-0000-0000-000000000148"
        static let pane = "AAAAAAAA-2222-0000-0000-000000000148"
        static let otherPane = "BBBBBBBB-2222-0000-0000-000000000148"
        static let project = "/tmp/tenon-t148-project"
        static let otherProject = "/tmp/tenon-t148-elsewhere"
        static let claudeHome = "/tmp/tenon-t148-claude"
        static let codexHome = "/tmp/tenon-t148-codex"
        static let visibleLimit = 10
    }

    // MARK: - The cutoff

    /// The defining case. `sess-25` is the 26th newest transcript with the window set to 10,
    /// so without the mark it is not in the pane at all.
    func testAMarkedClaudeSessionSurvivesTheRecentCutoff() async throws {
        let bridge = makeBridge(claudeTranscripts: 30)
        let runtime = try await makeStartedRuntime(
            bridge: bridge,
            favourites: [Favourite(key: "claude:sess-25", project: Fixture.project)]
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)

        let settled = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Favourites")
        }
        XCTAssertTrue(settled, "the pane never published a Favourites group")

        let shown = await texts(of: runtime, instance: Fixture.pane)
        XCTAssertTrue(
            shown.contains("Session 25"),
            "a marked session outside the recent window vanished: \(shown)"
        )
        XCTAssertTrue(shown.contains("Recent"), "the unmarked sessions lost their heading")
        XCTAssertFalse(
            shown.contains("Session 26"),
            "an unmarked session outside the window was pulled in with the marked one"
        )
    }

    /// The same rule for Codex, where the index is queried with a LIMIT rather than sliced
    /// in the plugin — so honouring the mark means a second query, by ID.
    func testAMarkedCodexThreadOutsideTheIndexWindowIsFetchedByID() async throws {
        let bridge = makeBridge(claudeTranscripts: 0, codexThreads: 20)
        let runtime = try await makeStartedRuntime(
            bridge: bridge,
            favourites: [Favourite(key: "codex:thread-18", project: Fixture.project)]
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)

        let settled = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Thread 18")
        }
        let codexShown = await texts(of: runtime, instance: Fixture.pane)
        XCTAssertTrue(
            settled,
            "a marked Codex thread outside the index window never arrived: \(codexShown)"
        )
        let queries = await bridge.codexQueries()
        XCTAssertEqual(
            queries.filter { $0.contains(" IN (") }.count,
            1,
            "the marked thread should cost exactly one extra bounded query: \(queries)"
        )
    }

    // MARK: - Marking

    func testMarkingASessionPersistsAndUnmarkingRemovesIt() async throws {
        let persisted = PersistedFavourites()
        let runtime = try await makeStartedRuntime(
            bridge: makeBridge(claudeTranscripts: 3),
            persist: { key, value in await persisted.record(key, value) }
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)
        _ = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Session 0")
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.pane,
            itemID: "fav:claude:sess-01",
            value: nil
        )
        let marked = await eventually {
            await persisted.keys() == ["claude:sess-01"]
        }
        let writtenKeys = await persisted.keys()
        XCTAssertTrue(marked, "marking did not reach plugin storage: \(writtenKeys)")
        let storageKey = await persisted.storageKey()
        let projects = await persisted.projects()
        XCTAssertEqual(storageKey, "favourites")
        XCTAssertEqual(projects, [Fixture.project])

        let regrouped = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Favourites")
        }
        XCTAssertTrue(regrouped, "the marked row never moved into a Favourites group")

        _ = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.pane,
            itemID: "fav:claude:sess-01",
            value: nil
        )
        let unmarked = await eventually { await persisted.keys().isEmpty }
        let leftBehind = await persisted.keys()
        XCTAssertTrue(unmarked, "unmarking left the record behind: \(leftBehind)")
    }

    /// `AL-NFR-001`: state carried in words, not in a glyph or a colour alone, because the
    /// button's label is also its accessibility label.
    func testTheMarkControlNamesItsStateInWords() async throws {
        let runtime = try await makeStartedRuntime(
            bridge: makeBridge(claudeTranscripts: 2),
            favourites: [Favourite(key: "claude:sess-00", project: Fixture.project)]
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)
        _ = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Favourites")
        }

        let controls = await buttons(of: runtime, instance: Fixture.pane)
            .filter { $0.action.hasPrefix("fav:") }
        XCTAssertEqual(controls.count, 2, "every row needs a mark control: \(controls)")
        let marked = try XCTUnwrap(controls.first { $0.action == "fav:claude:sess-00" })
        let unmarked = try XCTUnwrap(controls.first { $0.action == "fav:claude:sess-01" })
        XCTAssertTrue(
            marked.label.contains("Unfavourite"),
            "a marked row must say so in words, not only with a glyph: \(marked.label)"
        )
        XCTAssertTrue(
            unmarked.label.contains("Favourite"),
            "an unmarked row must name the action it offers: \(unmarked.label)"
        )
        XCTAssertNotEqual(marked.label, unmarked.label)
    }

    // MARK: - Scope, failure, bounds

    func testAFavouriteRecordedForAnotherProjectNeverAppearsInThisPane() async throws {
        let runtime = try await makeStartedRuntime(
            bridge: makeBridge(claudeTranscripts: 3),
            favourites: [Favourite(key: "claude:sess-01", project: Fixture.otherProject)]
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)
        _ = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Session 1")
        }

        let shown = await texts(of: runtime, instance: Fixture.pane)
        XCTAssertFalse(
            shown.contains("Favourites"),
            "another project's mark was shown in this project's pane: \(shown)"
        )
        let control = await buttons(of: runtime, instance: Fixture.pane)
            .first { $0.action == "fav:claude:sess-01" }
        XCTAssertEqual(control?.label.contains("Unfavourite"), false)
    }

    func testARejectedWriteLeavesTheCommittedListVisibleAndSaysSo() async throws {
        let runtime = try await makeStartedRuntime(
            bridge: makeBridge(claudeTranscripts: 3),
            favourites: [Favourite(key: "claude:sess-00", project: Fixture.project)],
            persist: { _, _ in throw FavouriteWriteError.refused }
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)
        _ = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Favourites")
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.pane,
            itemID: "fav:claude:sess-00",
            value: nil
        )
        let reported = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane)
                .contains { $0.contains("Could not save") }
        }
        let shown = await texts(of: runtime, instance: Fixture.pane)
        XCTAssertTrue(reported, "a refused write must say so: \(shown)")
        XCTAssertTrue(
            shown.contains("Favourites"),
            "the committed mark was dropped on a failed write: \(shown)"
        )
    }

    /// Invariant 10. The record is one storage value that only a person grows, but "only by
    /// hand" is not a bound — the oldest mark gives way so the newest is never refused.
    func testTheFavouriteRecordIsBounded() async throws {
        let persisted = PersistedFavourites()
        let seeded = (0 ..< 200).map {
            Favourite(
                key: "claude:archived-\(String(format: "%03d", $0))",
                project: Fixture.project,
                at: 1_000 + $0
            )
        }
        let runtime = try await makeStartedRuntime(
            bridge: makeBridge(claudeTranscripts: 3),
            favourites: seeded,
            persist: { key, value in await persisted.record(key, value) }
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.pane)
        _ = await eventually {
            await self.texts(of: runtime, instance: Fixture.pane).contains("Session 0")
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.pane,
            itemID: "fav:claude:sess-01",
            value: nil
        )
        let written = await eventually { await persisted.keys().count > 0 }
        XCTAssertTrue(written, "the mark never reached storage")

        let keys = await persisted.keys()
        XCTAssertEqual(keys.count, 200, "the record grew past its bound")
        XCTAssertTrue(keys.contains("claude:sess-01"), "the new mark was refused by the bound")
        XCTAssertFalse(
            keys.contains("claude:archived-000"),
            "the oldest mark should be the one that gives way"
        )
    }

    // MARK: - Helpers

    private struct Favourite {
        let key: String
        let project: String
        var at: Int = 1_700_000_000

        var value: IntentValue {
            .object([
                "key": .string(key),
                "project": .string(project),
                "at": .integer(Int64(at)),
            ])
        }
    }

    private enum FavouriteWriteError: Error { case refused }

    private func makeBridge(
        claudeTranscripts: Int,
        codexThreads: Int = 0
    ) -> SessionsBridge {
        SessionsBridge(
            panes: [Fixture.pane: Fixture.project, Fixture.otherPane: Fixture.otherProject],
            workspaceID: Fixture.workspace,
            claudeHome: Fixture.claudeHome,
            transcripts: claudeTranscripts,
            codexThreads: codexThreads
        )
    }

    private func makeStartedRuntime(
        bridge: SessionsBridge,
        favourites: [Favourite] = [],
        persist: @escaping PluginRuntimeConfiguration.PersistStorage = { _, _ in }
    ) async throws -> any PluginHostRuntime {
        let directory = Self.pluginsRoot
            .appendingPathComponent("claude-sessions", isDirectory: true)
        var storage: [String: IntentValue] = [:]
        if !favourites.isEmpty {
            storage["favourites"] = .array(favourites.map(\.value))
        }
        let runtime = try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: try PluginLoader.loadManifest(at: directory),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.send(request) },
                    list: { .array([]) }
                ),
                local: PluginRuntimeLocalState(
                    settings: [
                        "projectPath": .string(""),
                        "claudeHome": .string(Fixture.claudeHome),
                        "codexHome": .string(Fixture.codexHome),
                        "limit": .string(String(Fixture.visibleLimit)),
                    ],
                    storage: storage
                ),
                persistStorage: persist
            )
        )
        _ = try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown(timeout: 2) }
        return runtime
    }

    private func texts(of runtime: any PluginHostRuntime, instance: String) async -> [String] {
        guard let body = await runtime.snapshot().views
            .first(where: { $0.instanceID == instance })?.body
        else {
            return []
        }
        return Self.texts(in: body)
    }

    private func buttons(
        of runtime: any PluginHostRuntime,
        instance: String
    ) async -> [(label: String, action: String)] {
        guard let body = await runtime.snapshot().views
            .first(where: { $0.instanceID == instance })?.body
        else {
            return []
        }
        return Self.buttons(in: body)
    }

    private static func texts(in node: PluginViewNode) -> [String] {
        var out: [String] = []
        switch node {
        case let .text(value, _, _, _):
            out.append(value)
        case let .badge(value, _):
            out.append(value)
        default:
            break
        }
        for child in node.children {
            out.append(contentsOf: texts(in: child))
        }
        return out
    }

    private static func buttons(in node: PluginViewNode) -> [(label: String, action: String)] {
        var out: [(label: String, action: String)] = []
        if case let .button(label, action, _) = node {
            out.append((label: label, action: action.stringValue ?? action.description))
        }
        for child in node.children {
            out.append(contentsOf: buttons(in: child))
        }
        return out
    }

    private func eventually(
        attempts: Int = 300,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

// MARK: - Bridge

/// Answers exactly the intents `claude-sessions` declares, with a Claude transcript
/// directory and a Codex thread index made of numbers rather than files. `sess-00` /
/// `thread-00` is the newest of each; every later index is an hour older, so "outside the
/// window" is a property of the fixture rather than of the clock.
private actor SessionsBridge {
    private let panes: [String: String]
    private let workspaceID: String
    private let claudeHome: String
    private let transcripts: Int
    private let codexThreadCount: Int
    private var recordedCodexQueries: [String] = []

    init(
        panes: [String: String],
        workspaceID: String,
        claudeHome: String,
        transcripts: Int,
        codexThreads: Int
    ) {
        self.panes = panes
        self.workspaceID = workspaceID
        self.claudeHome = claudeHome
        self.transcripts = transcripts
        codexThreadCount = codexThreads
    }

    func codexQueries() -> [String] { recordedCodexQueries }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        let input = request.input.objectValue ?? [:]
        switch request.intentID.rawValue {
        case "workspace.pane.owner.v1":
            guard let paneID = input["paneID"]?.stringValue,
                  let path = panes[paneID]
            else {
                return Self.failure("dev.tenon.core.workspace-unavailable", "pane-unknown")
            }
            return Self.success(.object([
                "workspaceID": .string(workspaceID),
                "workspacePath": .string(path),
            ]))
        case "agent.inventory.v1":
            return Self.success(.object([
                "agents": .array([
                    .object([
                        "id": .string("claude"),
                        "label": .string("Claude Code"),
                        "arguments": .array([]),
                        "habit": .string(""),
                    ])
                ])
            ]))
        case "filesystem.directory.list.v2":
            return listing(input)
        case "process.exec.v1":
            return exec(input)
        default:
            return Self.success(.object([:]))
        }
    }

    private func listing(_ input: [String: IntentValue]) -> IntentResult {
        guard let path = input["path"]?.stringValue, path.hasPrefix(claudeHome) else {
            return Self.failure("dev.tenon.core.path-not-found", "path-not-found")
        }
        guard transcripts > 0 else {
            return Self.failure("dev.tenon.core.path-not-found", "path-not-found")
        }
        let entries = (0 ..< transcripts).map { index in
            IntentValue.object([
                "name": .string("\(Self.claudeID(index)).jsonl"),
                "isDirectory": .bool(false),
                "modifiedAt": .string(Self.timestamp(hoursAgo: index)),
                "sizeBytes": .integer(Int64(4_096 + index)),
            ])
        }
        return Self.success(.object([
            "path": .string(path),
            "entries": .array(entries),
            "nextCursor": .null,
        ]))
    }

    private func exec(_ input: [String: IntentValue]) -> IntentResult {
        let arguments = (input["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
        if arguments.first == "LC_ALL=C" {
            let details = claudeDetails(paths: Array(arguments.dropFirst(3)))
            return Self.success(Self.output(details))
        }
        guard arguments.count >= 4 else { return Self.success(Self.output("")) }
        let query = arguments[3]
        recordedCodexQueries.append(query)
        return Self.success(Self.output(codexRows(for: query)))
    }

    private func claudeDetails(paths: [String]) -> String {
        paths.map { path in
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            let id = name.replacingOccurrences(of: ".jsonl", with: "")
            let index = Int(id.replacingOccurrences(of: "sess-", with: "")) ?? 0
            return "\(path)\t3\t2\tSession \(index)\tSession \(index)\tmain"
        }
        .joined(separator: "\n")
    }

    /// The real index's two shapes: the recent window (`ORDER BY … LIMIT n`) and the
    /// by-ID lookup a marked thread outside that window needs.
    private func codexRows(for query: String) -> String {
        guard codexThreadCount > 0 else { return "[]" }
        let wanted: [Int]
        if let ids = Self.identifiers(in: query) {
            wanted = ids.compactMap { Int($0.replacingOccurrences(of: "thread-", with: "")) }
        } else {
            let limit = Self.limit(in: query) ?? codexThreadCount
            wanted = Array(0 ..< min(limit, codexThreadCount))
        }
        let rows = wanted.filter { $0 < codexThreadCount }.map { index in
            """
            {"id":"\(Self.codexID(index))","mtime":\(Self.epoch(hoursAgo: index)),\
            "title":"Thread \(index)","tokens":100,"branch":"main"}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private static func identifiers(in query: String) -> [String]? {
        guard let start = query.range(of: " IN ("),
              let end = query.range(of: ")", range: start.upperBound ..< query.endIndex)
        else {
            return nil
        }
        return query[start.upperBound ..< end.lowerBound]
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
    }

    private static func limit(in query: String) -> Int? {
        guard let range = query.range(of: "LIMIT ") else { return nil }
        return Int(
            query[range.upperBound...]
                .prefix { $0.isNumber }
        )
    }

    private static func claudeID(_ index: Int) -> String {
        "sess-\(String(format: "%02d", index))"
    }

    private static func codexID(_ index: Int) -> String {
        "thread-\(String(format: "%02d", index))"
    }

    private static let base = Date(timeIntervalSince1970: 1_786_000_000)

    private static func epoch(hoursAgo: Int) -> Int {
        Int(base.timeIntervalSince1970) - hoursAgo * 3_600
    }

    private static func timestamp(hoursAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(epoch(hoursAgo: hoursAgo)))
        )
    }

    private static func output(_ text: String) -> IntentValue {
        .object([
            "exitCode": .integer(0),
            "standardOutput": .object([
                "kind": .string("inline"),
                "text": .string(text),
                "byteCount": .integer(Int64(text.utf8.count)),
            ]),
            "standardError": .object([
                "kind": .string("inline"),
                "text": .string(""),
                "byteCount": .integer(0),
            ]),
        ])
    }

    private static func success(_ value: IntentValue) -> IntentResult {
        .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    private static func failure(_ code: String, _ reason: String) -> IntentResult {
        .failure(
            error: IntentError(
                code: .domain(try! IntentDomainErrorCode(code)),
                details: .object(["reason": .string(reason)]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }
}

/// What the host was asked to persist, in the order it was asked.
private actor PersistedFavourites {
    private var lastKey: String?
    private var lastValue: IntentValue?

    func record(_ key: String, _ value: IntentValue) {
        lastKey = key
        lastValue = value
    }

    func storageKey() -> String? { lastKey }

    func keys() -> [String] {
        (lastValue?.arrayValue ?? []).compactMap {
            $0.objectValue?["key"]?.stringValue
        }
    }

    func projects() -> [String] {
        Array(
            Set(
                (lastValue?.arrayValue ?? []).compactMap {
                    $0.objectValue?["project"]?.stringValue
                }
            )
        )
    }
}
