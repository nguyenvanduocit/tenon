import XCTest
@testable import TenonCore

/// T-092: the journal is the thing that has to survive the incident, so the tests are about
/// survival — it stays bounded, it tolerates damage, and it reads back.
final class DiagnosticsJournalTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func journal(ceiling: Int = DiagnosticsJournal.defaultCeiling) -> DiagnosticsJournal {
        DiagnosticsJournal(fileURL: scratch.appendingPathComponent("health.jsonl"), ceiling: ceiling)
    }

    private func record(_ n: Int) -> DiagnosticsRecord {
        DiagnosticsRecord(
            at: Date(timeIntervalSince1970: TimeInterval(n)),
            kind: "stall",
            message: "record \(n)",
            figures: ["n": "\(n)"]
        )
    }

    func testRecordsReadBackInOrderWithTheirFigures() {
        let subject = journal()
        subject.append(record(1))
        subject.append(record(2))

        let held = subject.records()

        XCTAssertEqual(held.map(\.message), ["record 1", "record 2"])
        XCTAssertEqual(held.last?.figures["n"], "2")
        XCTAssertEqual(held.first?.at, Date(timeIntervalSince1970: 1))
    }

    func testJournalCreatesItsDirectory() {
        let nested = scratch
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("health.jsonl")
        let subject = DiagnosticsJournal(fileURL: nested)

        subject.append(record(1))

        XCTAssertEqual(subject.records().count, 1, "The journal must make its own home.")
    }

    /// The behaviour that keeps diagnostics from becoming the outage: the file stops growing.
    func testJournalStaysBoundedAndDropsOldestFirst() throws {
        let subject = journal(ceiling: 50)

        for n in 1...200 { subject.append(record(n)) }

        let held = subject.records()
        XCTAssertEqual(held.count, 50, "The ceiling is the ceiling.")
        XCTAssertEqual(held.first?.message, "record 151", "Oldest records go first.")
        XCTAssertEqual(held.last?.message, "record 200", "The newest record is always kept.")

        let size = try Data(contentsOf: scratch.appendingPathComponent("health.jsonl")).count
        for n in 201...400 { subject.append(record(n)) }
        let sizeLater = try Data(contentsOf: scratch.appendingPathComponent("health.jsonl")).count

        XCTAssertEqual(
            sizeLater / 1024, size / 1024,
            "200 more records must not grow the file — it is bounded, not merely trimmed once."
        )
    }

    /// A process killed mid-write leaves a partial last line. Losing that line is acceptable;
    /// losing the rest of the evidence is not — and a force quit is exactly how the T-091
    /// hang ended.
    func testATruncatedLastLineDoesNotCostTheEarlierRecords() throws {
        let file = scratch.appendingPathComponent("health.jsonl")
        let subject = journal()
        subject.append(record(1))
        subject.append(record(2))

        let text = try String(contentsOf: file, encoding: .utf8)
        try Data((text + "{\"at\":\"2026-08-07T00:00:00Z\",\"kind\":\"sta").utf8).write(to: file)

        XCTAssertEqual(
            subject.records().map(\.message), ["record 1", "record 2"],
            "A half-written line is skipped, not fatal."
        )
    }

    func testAppendingAfterATruncatedTailRepairsTheBoundary() throws {
        let file = scratch.appendingPathComponent("health.jsonl")
        let subject = journal()
        subject.append(record(1))
        let text = try String(contentsOf: file, encoding: .utf8)
        try Data((text + "{\"kind\":\"partial").utf8).write(to: file)

        XCTAssertTrue(subject.append(record(2)))
        XCTAssertEqual(
            subject.records().map(\.message),
            ["record 1", "record 2"],
            "a crash fragment must not swallow the first record of the next run"
        )
    }

    func testInvalidUTF8LineDoesNotEraseNeighboringRecordsOrNextAppend() throws {
        let file = scratch.appendingPathComponent("health.jsonl")
        let subject = journal()
        subject.append(record(1))
        subject.append(record(2))
        let valid = try Data(contentsOf: file).split(separator: UInt8(ascii: "\n"))
        var damaged = Data(valid[0])
        damaged.append(UInt8(ascii: "\n"))
        damaged.append(0xFF)
        damaged.append(UInt8(ascii: "\n"))
        damaged.append(Data(valid[1]))
        damaged.append(UInt8(ascii: "\n"))
        try damaged.write(to: file)

        XCTAssertEqual(subject.records().map(\.message), ["record 1", "record 2"])
        XCTAssertTrue(subject.append(record(3)))
        XCTAssertEqual(
            subject.records().map(\.message),
            ["record 1", "record 2", "record 3"]
        )
    }

    func testRecordAndJournalByteCeilingsAreEnforced() throws {
        let file = scratch.appendingPathComponent("health.jsonl")
        let subject = DiagnosticsJournal(
            fileURL: file,
            ceiling: 100,
            maximumRecordBytes: 256,
            maximumJournalBytes: 1_024
        )
        XCTAssertFalse(
            subject.append(
                DiagnosticsRecord(at: Date(), kind: "stall", message: String(repeating: "x", count: 300))
            )
        )
        for n in 1...40 {
            XCTAssertTrue(subject.append(record(n)))
        }

        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_024)
        XCTAssertEqual(subject.records().last?.message, "record 40")
        XCTAssertLessThan(subject.records().count, 40)
    }

    func testAppendReportsAnUnwritableTargetWithoutThrowing() throws {
        let directoryTarget = scratch.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryTarget,
            withIntermediateDirectories: true
        )
        let subject = DiagnosticsJournal(fileURL: directoryTarget)

        XCTAssertFalse(subject.append(record(1)))
        XCTAssertEqual(subject.records(), [])
    }

    func testExportProducesAReadableFileContainingTheRecords() throws {
        let subject = journal()
        subject.append(
            DiagnosticsRecord(
                at: Date(timeIntervalSince1970: 0),
                kind: "stall",
                message: "main runloop stalled",
                figures: ["seconds": "6", "rssMB": "204"]
            )
        )
        let destination = scratch.appendingPathComponent("export.txt")

        try subject.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(text.contains("main runloop stalled"), text)
        XCTAssertTrue(text.contains("rssMB=204"), "Figures travel with the record: \(text)")
        XCTAssertTrue(text.contains("records: 1"), text)
    }

    func testConcurrentExportsToTheSameDestinationRemainWhole() throws {
        let subject = journal()
        for n in 1...100 { XCTAssertTrue(subject.append(record(n))) }
        let destination = scratch.appendingPathComponent("concurrent-export.txt")
        let queue = DispatchQueue(label: "diagnostics-export-test", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = ExportFailureLog()

        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try subject.export(to: destination)
                } catch {
                    failures.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.isEmpty, "concurrent export failures: \(failures.count)")

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "Tenon diagnostics export").count - 1, 1)
        XCTAssertTrue(text.contains("records: 100"), text)
        XCTAssertTrue(text.contains("record 1"), text)
        XCTAssertTrue(text.contains("record 100"), text)
    }

    func testExportIncludesOnlyCommittedIncidentArtifactsBelowDiagnosticsRoot() throws {
        let subject = journal()
        let relative = "incidents/run/0001/sample.txt"
        let artifact = scratch.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("captured stack evidence".utf8).write(to: artifact)
        subject.append(
            DiagnosticsRecord(
                at: Date(timeIntervalSince1970: 0),
                kind: "stall-sample-completed",
                message: "stack sample committed",
                figures: ["sampleFile": relative]
            )
        )
        subject.append(
            DiagnosticsRecord(
                at: Date(timeIntervalSince1970: 1),
                kind: "stall-sample-completed",
                message: "malicious path",
                figures: ["sampleFile": "../../outside.txt"]
            )
        )
        let destination = scratch.appendingPathComponent("bundle.txt")

        try subject.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(text.contains("captured stack evidence"), text)
        XCTAssertTrue(text.contains("[artifact path rejected]"), text)
    }

    func testExportRejectsAnIncidentArtifactSymlinkThatEscapesDiagnostics() throws {
        let subject = journal()
        let outside = scratch.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("PRIVATE-OUTSIDE-DIAGNOSTICS".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let link = scratch.appendingPathComponent("incidents/run/0001/sample.txt")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        subject.append(
            DiagnosticsRecord(
                at: Date(),
                kind: "stall-sample-completed",
                message: "stack sample committed",
                figures: ["sampleFile": "incidents/run/0001/sample.txt"]
            )
        )
        let destination = scratch.appendingPathComponent("symlink-export.txt")

        try subject.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(text.contains("[artifact unavailable or not a regular file]"), text)
        XCTAssertFalse(text.contains("PRIVATE-OUTSIDE-DIAGNOSTICS"), text)
    }

    func testExportRejectsAnIntermediateIncidentDirectorySymlink() throws {
        let subject = journal()
        let outside = scratch.deletingLastPathComponent()
            .appendingPathComponent("outside-dir-\(UUID().uuidString)", isDirectory: true)
        let outsideSample = outside.appendingPathComponent("0001/sample.txt")
        try FileManager.default.createDirectory(
            at: outsideSample.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("PRIVATE-PARENT-SYMLINK".utf8).write(to: outsideSample)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let incidents = scratch.appendingPathComponent("incidents", isDirectory: true)
        try FileManager.default.createDirectory(at: incidents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: incidents.appendingPathComponent("run"),
            withDestinationURL: outside
        )
        subject.append(
            DiagnosticsRecord(
                at: Date(),
                kind: "stall-sample-completed",
                message: "stack sample committed",
                figures: ["sampleFile": "incidents/run/0001/sample.txt"]
            )
        )
        let destination = scratch.appendingPathComponent("parent-symlink-export.txt")

        try subject.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(text.contains("[artifact unavailable or not a regular file]"), text)
        XCTAssertFalse(text.contains("PRIVATE-PARENT-SYMLINK"), text)
    }

    func testExportRefusesToOverwriteJournalOrCommittedArtifact() throws {
        let subject = journal()
        let relative = "incidents/run/0001/sample.txt"
        let artifact = scratch.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("evidence".utf8).write(to: artifact)
        subject.append(
            DiagnosticsRecord(
                at: Date(),
                kind: "stall-sample-completed",
                message: "stack sample committed",
                figures: ["sampleFile": relative]
            )
        )

        XCTAssertThrowsError(try subject.export(to: subject.fileURL))
        XCTAssertThrowsError(try subject.export(to: artifact))
        XCTAssertEqual(subject.records().count, 1)
        XCTAssertEqual(try String(contentsOf: artifact, encoding: .utf8), "evidence")
    }

    func testReadingAJournalThatWasNeverWrittenIsEmptyRatherThanAnError() {
        XCTAssertEqual(journal().records(), [])
    }
}

private final class ExportFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error] = []

    var isEmpty: Bool { lock.withLock { failures.isEmpty } }
    var count: Int { lock.withLock { failures.count } }

    func append(_ error: Error) {
        lock.withLock { failures.append(error) }
    }
}
