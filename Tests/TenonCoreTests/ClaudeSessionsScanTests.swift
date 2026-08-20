import Foundation
@testable import TenonBundledPlugins
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-190: the two failure modes that leave the Agent Sessions list showing
/// `"Untitled Claude session"` even though the transcript has real content.
final class ClaudeSessionsScanTests: XCTestCase {
    // MARK: - The `awk` fallback must read Claude Code's array-format `content`

    /// Claude Code stores `content` as an array of blocks (not a plain string) whenever the
    /// message includes anything besides text, most commonly a pasted screenshot. The title
    /// fallback's `"content":"` marker never matches that shape, so it silently returns "".
    func testAwkFallbackExtractsTextWhenContentIsAnArrayOfBlocks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-claude-sessions-awk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data(
            """
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"screenshot attached, please look"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}
            """.utf8
        ).write(to: transcript)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["LC_ALL=C", "/usr/bin/awk", ClaudeSessionsScan.awk, transcript.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let fields = output
            .trimmingCharacters(in: .newlines)
            .split(separator: "\t", omittingEmptySubsequences: false)

        XCTAssertEqual(process.terminationStatus, 0, "awk did not exit cleanly: \(output)")
        guard fields.count >= 5 else {
            XCTFail("awk emitted fewer fields than expected: \(output)")
            return
        }
        XCTAssertEqual(String(fields[3]), "", "fixture unexpectedly carried an ai-title record")
        XCTAssertEqual(
            String(fields[4]),
            "screenshot attached, please look",
            "the first-message fallback stayed empty for array-format content"
        )
    }

    // MARK: - One bad file in a batch must not blank the rest of the batch

    /// `enrichClaude` sends every listed session's path to one `awk` process. If that one
    /// process exits non-zero, the whole batch used to lose its titles — not just the file
    /// that caused the failure.
    func testABadFileInTheBatchDoesNotBlankTitlesForTheRestOfTheBatch() async throws {
        let bridge = RetryTrackingBridge(goodID: "good-session", badID: "bad-session")
        let caller = ClaudeSessionsIntentCaller { intentID, input in
            await bridge.send(intentID, input)
        }

        let result = await ClaudeSessionsScan.scanClaude(
            project: "/tmp/tenon-t190-project",
            claudeHome: "/tmp/tenon-t190-claude",
            favourites: [],
            limit: 25,
            caller: caller,
            log: { _ in }
        )

        let good = result.sessions.first { $0.id == "good-session" }
        let bad = result.sessions.first { $0.id == "bad-session" }
        XCTAssertEqual(
            good?.title,
            "Good Title",
            "one bad file in the batch blanked a healthy session's title"
        )
        XCTAssertEqual(bad?.title, "")
        let batchCalls = await bridge.execCallCount()
        XCTAssertGreaterThan(
            batchCalls,
            1,
            "a whole-batch awk failure never retried the batch one file at a time"
        )
    }
}

/// Fakes exactly the two intents `ClaudeSessionsScan.scanClaude` needs: a two-entry directory
/// listing, and a `process.exec.v1` whose whole-batch attempt always fails while single-file
/// retries succeed for every path except the deliberately poisoned one.
private actor RetryTrackingBridge {
    private let goodID: String
    private let badID: String
    private var execCalls: [[String]] = []

    init(goodID: String, badID: String) {
        self.goodID = goodID
        self.badID = badID
    }

    func execCallCount() -> Int { execCalls.count }

    func send(_ intentID: IntentID, _ input: IntentValue) -> IntentResult {
        let fields = input.objectValue ?? [:]
        switch intentID.rawValue {
        case "filesystem.directory.list.v2":
            return listing(fields)
        case "process.exec.v1":
            return exec(fields)
        default:
            return Self.success(.object([:]))
        }
    }

    private func listing(_ fields: [String: IntentValue]) -> IntentResult {
        let path = fields["path"]?.stringValue ?? ""
        let entries: [IntentValue] = [goodID, badID].enumerated().map { index, id in
            .object([
                "name": .string("\(id).jsonl"),
                "isDirectory": .bool(false),
                "modifiedAt": .string(Self.timestamp(hoursAgo: index)),
                "sizeBytes": .integer(4_096),
            ])
        }
        return Self.success(.object([
            "path": .string(path),
            "entries": .array(entries),
            "nextCursor": .null,
        ]))
    }

    private func exec(_ fields: [String: IntentValue]) -> IntentResult {
        let arguments = (fields["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
        let paths = Array(arguments.dropFirst(3))
        execCalls.append(paths)
        guard paths.count == 1, let only = paths.first else {
            // The whole-batch attempt always fails, forcing a per-file retry.
            return Self.success(Self.output(exitCode: 2, text: ""))
        }
        guard !only.contains(badID) else {
            return Self.success(Self.output(exitCode: 2, text: ""))
        }
        return Self.success(Self.output(exitCode: 0, text: "\(only)\t1\t1\tGood Title\tignored\tmain"))
    }

    private static func output(exitCode: Int, text: String) -> IntentValue {
        .object([
            "exitCode": .integer(Int64(exitCode)),
            "termination": .string("exited"),
            "standardOutput": .object(["text": .string(text)]),
            "standardError": .object(["text": .string("")]),
        ])
    }

    private static func timestamp(hoursAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(
            from: Date(timeIntervalSince1970: 1_786_000_000 - Double(hoursAgo * 3_600))
        )
    }

    private static func success(_ value: IntentValue) -> IntentResult {
        .success(value: value, requestID: UUID(), providerID: try! ProviderID("dev.tenon.tests"))
    }
}
