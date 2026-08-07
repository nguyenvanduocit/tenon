import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// The git plugin's porcelain-v2 parser, pinned before it is split.
///
/// It is the plugin's one piece of real algorithm — a NUL-delimited record format with four
/// entry kinds, a rename that consumes the following record, and three derived lists — and it
/// had no test at all. These run against the shipped `plugins/git/main.js` in a real runtime,
/// so what they pin is the file that ships.
final class GitPluginParseTests: XCTestCase {
    func testBranchRecordsBecomeTheHeaderModel() async throws {
        let model = try await parse(
            records: [
                "# branch.oid abc123",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +2 -3",
            ]
        )

        XCTAssertEqual(model["branch"], .string("main"))
        XCTAssertEqual(model["upstream"], .string("origin/main"))
        XCTAssertEqual(model["ahead"], .integer(2))
        XCTAssertEqual(model["behind"], .integer(3))
        XCTAssertEqual(model["hasHead"], .bool(true))
        XCTAssertEqual(model["isRepo"], .bool(true))
    }

    func testAnUnbornBranchHasNoHeadAndADetachedOneSaysSo() async throws {
        let unborn = try await parse(
            records: ["# branch.oid (initial)", "# branch.head main"]
        )
        XCTAssertEqual(unborn["hasHead"], .bool(false))

        let detached = try await parse(
            records: ["# branch.oid abc123", "# branch.head (detached)"]
        )
        XCTAssertEqual(detached["branch"], .string("detached HEAD"))
    }

    func testOrdinaryEntriesSplitIntoStagedAndChanged() async throws {
        let model = try await parse(
            records: [
                "# branch.head main",
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>  — eight spaces before the path
                "1 M. N... 100644 100644 100644 aaa bbb staged-only.txt",
                "1 .M N... 100644 100644 100644 aaa bbb worktree-only.txt",
                "1 MM N... 100644 100644 100644 aaa bbb both.txt",
                "? untracked.txt",
            ]
        )

        XCTAssertEqual(paths(model["staged"]), ["staged-only.txt", "both.txt"])
        XCTAssertEqual(
            paths(model["changed"]),
            ["worktree-only.txt", "both.txt", "untracked.txt"]
        )
        XCTAssertEqual(paths(model["merge"]), [])
    }

    /// A rename carries its original path in the *next* record, which the parser must consume
    /// so it is never mistaken for an entry of its own.
    func testARenameConsumesItsOriginalPathRecord() async throws {
        let model = try await parse(
            records: [
                "# branch.head main",
                "2 R. N... 100644 100644 100644 aaa bbb R100 new-name.txt",
                "old-name.txt",
                "1 M. N... 100644 100644 100644 aaa bbb after.txt",
            ]
        )

        XCTAssertEqual(paths(model["staged"]), ["new-name.txt", "after.txt"])
        guard case let .array(staged) = model["staged"] ?? .null,
              case let .object(rename) = staged.first ?? .null
        else {
            return XCTFail("expected a staged rename entry")
        }
        XCTAssertEqual(rename["origPath"], .string("old-name.txt"))
    }

    func testConflictsAreTheirOwnListAndNeverStagedOrChanged() async throws {
        let model = try await parse(
            records: [
                "# branch.head main",
                "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt",
            ]
        )

        XCTAssertEqual(paths(model["merge"]), ["conflicted.txt"])
        XCTAssertEqual(paths(model["staged"]), [])
        XCTAssertEqual(paths(model["changed"]), [])
    }

    func testUnknownAndEmptyRecordsAreIgnored() async throws {
        let model = try await parse(
            records: ["", "# branch.head main", "x nonsense", ""]
        )

        XCTAssertEqual(model["branch"], .string("main"))
        XCTAssertEqual(paths(model["staged"]), [])
        XCTAssertEqual(paths(model["changed"]), [])
    }

    // MARK: - Fixture

    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    /// Runs the shipped parser over NUL-joined records and returns its model.
    private func parse(records: [String]) async throws -> [String: IntentValue] {
        let runtime = try makeRuntime()
        _ = try await runtime.start()
        defer { Task { _ = await runtime.shutdown() } }

        let joined = records.joined(separator: "\u{0}")
        let literal = String(
            decoding: try JSONSerialization.data(
                withJSONObject: [joined],
                options: [.fragmentsAllowed]
            ),
            as: UTF8.self
        )
        let value = try await runtime.evaluateForTesting(
            "JSON.parse(JSON.stringify(parseStatus(\(literal)[0])))"
        )
        guard case let .object(model) = value else {
            throw XCTSkip("parseStatus returned \(value)")
        }
        return model
    }

    private func paths(_ value: IntentValue?) -> [String] {
        guard case let .array(entries) = value ?? .null else { return [] }
        return entries.compactMap { entry in
            guard case let .object(fields) = entry,
                  case let .string(path)? = fields["path"]
            else { return nil }
            return path
        }
    }

    private func makeRuntime() throws -> PluginRuntime {
        let directory = Self.pluginsRoot.appendingPathComponent("git", isDirectory: true)
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginLoader.loadManifest(at: directory),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in
                        .failure(
                            error: IntentError(
                                code: .kernel(.internal),
                                details: nil,
                                retryable: false,
                                retryAfterMilliseconds: nil,
                                outcome: .unknown
                            ),
                            requestID: UUID(),
                            providerID: nil
                        )
                    },
                    list: { .array([]) }
                )
            )
        )
    }
}
