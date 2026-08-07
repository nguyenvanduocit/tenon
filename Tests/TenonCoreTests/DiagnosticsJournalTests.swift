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

    func testReadingAJournalThatWasNeverWrittenIsEmptyRatherThanAnError() {
        XCTAssertEqual(journal().records(), [])
    }
}
