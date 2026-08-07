// @domain: diagnostics

import Foundation

/// One thing worth knowing afterwards.
///
/// `figures` is deliberately `[String: String]` rather than a fixed shape: what is worth
/// recording beside a stall will change, and a journal whose schema has to be migrated to add
/// a number is a journal people stop adding numbers to.
public struct DiagnosticsRecord: Codable, Equatable, Sendable {
    public let at: Date
    public let kind: String
    public let message: String
    public let figures: [String: String]

    public init(at: Date, kind: String, message: String, figures: [String: String] = [:]) {
        self.at = at
        self.kind = kind
        self.message = message
        self.figures = figures
    }
}

/// A bounded, append-only record of what the app noticed about itself.
///
/// Bounded because invariant 10 says every queue and lifetime is, and because a diagnostics
/// file that grows without limit becomes its own outage — the T-091 hang would have written a
/// record a second for two hours. When the ceiling is reached the OLDEST records go: a stall
/// that is still happening matters more than one that resolved yesterday.
///
/// JSON Lines rather than one JSON document, so a record survives a process that dies
/// mid-write: a truncated last line loses that line and nothing else.
public final class DiagnosticsJournal: @unchecked Sendable {
    /// How many records to keep. At roughly one record per escalation interval, this is days
    /// of stalls, and a few hundred kilobytes at most.
    public static let defaultCeiling = 2000

    /// Where the journal is written. Public because a sibling artifact — a stack sample taken
    /// the moment a stall is seen — belongs beside it.
    public let fileURL: URL
    private let ceiling: Int
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL, ceiling: Int = DiagnosticsJournal.defaultCeiling) {
        self.fileURL = fileURL
        self.ceiling = max(1, ceiling)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Where the journal lives for a real run.
    public static func defaultFileURL(
        applicationSupport: URL
    ) -> URL {
        applicationSupport
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("health.jsonl", isDirectory: false)
    }

    /// Append one record, trimming to the ceiling if needed.
    ///
    /// Failures here are swallowed on purpose: diagnostics must never be the reason a session
    /// ends. A journal that cannot be written is a lost record, not a crash.
    public func append(_ record: DiagnosticsRecord) {
        lock.lock()
        defer { lock.unlock() }

        guard let line = try? encoder.encode(record),
              let text = String(data: line, encoding: .utf8)
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((text + "\n").utf8))
            } else {
                try Data((text + "\n").utf8).write(to: fileURL)
            }
        } catch {
            return
        }

        trimIfNeeded()
    }

    /// Every record currently held, oldest first. A line that will not decode is skipped
    /// rather than failing the read — one bad line must not cost the rest of the evidence.
    public func records() -> [DiagnosticsRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    /// Fold the journal into one file a person can attach to a report.
    ///
    /// Plain text rather than the raw JSONL: the point of exporting is that somebody reads it.
    @discardableResult
    public func export(to destination: URL) throws -> URL {
        let held = records()
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Tenon diagnostics export",
            "records: \(held.count)",
            "",
        ]
        for record in held {
            var line = "\(formatter.string(from: record.at))  [\(record.kind)]  \(record.message)"
            if !record.figures.isEmpty {
                let figures = record.figures
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                line += "  (\(figures))"
            }
            lines.append(line)
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: destination)
        return destination
    }

    private func readLocked() -> [DiagnosticsRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(DiagnosticsRecord.self, from: lineData)
            }
    }

    private func trimIfNeeded() {
        let held = readLocked()
        guard held.count > ceiling else { return }

        let kept = held.suffix(ceiling)
        let rewritten = kept
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        try? Data((rewritten + "\n").utf8).write(to: fileURL)
    }
}
