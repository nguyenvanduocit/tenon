// @domain: diagnostics

import Darwin
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
    /// How many records to keep. Independent byte ceilings below prevent a pathological record
    /// from turning the count bound into unbounded disk or memory work.
    public static let defaultCeiling = 2000
    public static let defaultMaximumRecordBytes = 16 * 1024
    public static let defaultMaximumJournalBytes = 4 * 1_048_576
    public static let defaultMaximumExportArtifactCount = 16
    public static let defaultMaximumExportArtifactBytes = 16 * 1_048_576

    /// Where the journal is written. Public because a sibling artifact — a stack sample taken
    /// the moment a stall is seen — belongs beside it.
    public let fileURL: URL
    private let ceiling: Int
    private let maximumRecordBytes: Int
    private let maximumJournalBytes: Int
    private let lock = NSLock()
    private let exportLock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        fileURL: URL,
        ceiling: Int = DiagnosticsJournal.defaultCeiling,
        maximumRecordBytes: Int = DiagnosticsJournal.defaultMaximumRecordBytes,
        maximumJournalBytes: Int = DiagnosticsJournal.defaultMaximumJournalBytes
    ) {
        self.fileURL = fileURL
        self.ceiling = max(1, ceiling)
        self.maximumRecordBytes = max(1, maximumRecordBytes)
        self.maximumJournalBytes = max(self.maximumRecordBytes, maximumJournalBytes, 1)
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
    /// Failures here never throw: diagnostics must not end a session. The Boolean receipt lets
    /// the runtime emit a bounded unified-log error instead of silently pretending persistence
    /// succeeded.
    @discardableResult
    public func append(_ record: DiagnosticsRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let encoded = try? encoder.encode(record),
              encoded.count + 1 <= maximumRecordBytes
        else { return false }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let next = Array((readLocked() + [record]).suffix(ceiling))
            guard let data = boundedEncoding(of: next),
                  data.count <= maximumJournalBytes
            else { return false }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }
        return true
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
        exportLock.lock()
        defer { exportLock.unlock() }
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedJournal = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDestination.path != resolvedJournal.path
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
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
        let artifactPaths = held.flatMap { record in
                switch record.kind {
                case "stall-sample-completed":
                    return [record.figures["sampleFile"]].compactMap { $0 }
                case "stall-transitions-completed":
                    return [record.figures["transitionFile"]].compactMap { $0 }
                default:
                    return []
                }
            }
        let diagnosticsRoot = fileURL.deletingLastPathComponent().standardizedFileURL
        let overwritesArtifact = artifactPaths.contains { relativePath in
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !relativePath.hasPrefix("/"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { return false }
            return diagnosticsRoot.appendingPathComponent(relativePath)
                .standardizedFileURL.resolvingSymlinksInPath().path == resolvedDestination.path
        }
        guard !overwritesArtifact else { throw CocoaError(.fileWriteNoPermission) }
        lines.append("")
        lines.append("incident artifact references: \(artifactPaths.count)")
        var exportedArtifactIdentities = Set<String>()
        var exportedArtifactCount = 0
        var exportedArtifactBytes = 0
        let examinedArtifactPaths = artifactPaths.prefix(Self.defaultMaximumExportArtifactCount)
        for relativePath in examinedArtifactPaths {
            guard exportedArtifactCount < Self.defaultMaximumExportArtifactCount,
                  exportedArtifactBytes < Self.defaultMaximumExportArtifactBytes
            else {
                lines.append("[remaining artifacts omitted: export limit reached]")
                break
            }
            let remainingBytes = Self.defaultMaximumExportArtifactBytes - exportedArtifactBytes
            let artifact = exportedArtifact(
                relativePath: relativePath,
                maximumBytes: min(8 * 1_048_576, remainingBytes)
            )
            if let identity = artifact.identity,
               !exportedArtifactIdentities.insert(identity).inserted {
                continue
            }
            lines.append("")
            lines.append("--- BEGIN \(relativePath) ---")
            lines.append(artifact.text)
            lines.append("--- END \(relativePath) ---")
            exportedArtifactCount += 1
            exportedArtifactBytes += artifact.byteCount
        }
        if artifactPaths.count > examinedArtifactPaths.count {
            lines.append("[remaining artifact references omitted: export limit reached]")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: destination, options: .atomic)
        return destination
    }

    /// Resolve only a run-relative artifact below the diagnostics root. A journal line is
    /// durable input and therefore not trusted to smuggle an absolute or traversing path into
    /// an export. Eight MiB per artifact is enough for `/usr/bin/sample` while keeping export
    /// work explicitly finite.
    private func exportedArtifact(
        relativePath: String,
        maximumBytes: Int
    ) -> (text: String, identity: String?, byteCount: Int) {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return ("[artifact path rejected]", nil, 0) }
        let root = fileURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        guard maximumBytes > 0,
              let artifact = boundedRegularFile(
            below: root,
            components: components,
            maximumBytes: maximumBytes
        ) else {
            return ("[artifact unavailable or not a regular file]", nil, 0)
        }
        let kept = Data(artifact.data.prefix(maximumBytes))
        let text = String(data: kept, encoding: .utf8) ?? "[artifact is not UTF-8 text]"
        let rendered = artifact.data.count > maximumBytes
            ? text + "\n[artifact truncated at bounded export limit]"
            : text
        return (rendered, artifact.identity, kept.count)
    }

    /// Walk descriptor-relative with no-follow at every component, so a parent directory cannot
    /// be swapped to a symlink between lexical validation and open. The leaf is nonblocking and
    /// must be a regular file before at most the limit plus one byte is read.
    private func boundedRegularFile(
        below root: URL,
        components: [String],
        maximumBytes: Int
    ) -> (data: Data, identity: String)? {
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return nil }
        defer { Darwin.close(rootDescriptor) }

        var directoryDescriptor = rootDescriptor
        defer {
            if directoryDescriptor != rootDescriptor { Darwin.close(directoryDescriptor) }
        }
        for component in components.dropLast() {
            let next = Darwin.openat(
                directoryDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else { return nil }
            if directoryDescriptor != rootDescriptor { Darwin.close(directoryDescriptor) }
            directoryDescriptor = next
        }
        guard let leaf = components.last else { return nil }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else { return nil }

        let limit = maximumBytes + 1
        var data = Data()
        data.reserveCapacity(limit)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limit))
        while data.count < limit {
            let requested = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, "\(metadata.st_dev):\(metadata.st_ino)")
    }

    private func readLocked() -> [DiagnosticsRecord] {
        guard let data = boundedJournalTail() else { return [] }
        let decoded = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(DiagnosticsRecord.self, from: Data($0)) }
        return Array(decoded.suffix(ceiling))
    }

    private func boundedJournalTail() -> Data? {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else { return nil }

        let size = max(Int(metadata.st_size), 0)
        let offset = max(size - maximumJournalBytes, 0)
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { return nil }
        var data = Data()
        data.reserveCapacity(min(size, maximumJournalBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maximumJournalBytes {
            let requested = min(buffer.count, maximumJournalBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        if offset > 0, let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data.removeSubrange(data.startIndex...firstNewline)
        } else if offset > 0 {
            data.removeAll(keepingCapacity: false)
        }
        return data
    }

    /// Encode newest-first under both the record-count and byte ceilings. A record larger than
    /// the per-record ceiling is rejected before this point, so the newest receipt always fits.
    private func boundedEncoding(of records: [DiagnosticsRecord]) -> Data? {
        var reversedLines: [Data] = []
        var byteCount = 0
        for record in records.reversed() {
            guard var line = try? encoder.encode(record) else { continue }
            line.append(UInt8(ascii: "\n"))
            guard line.count <= maximumRecordBytes else { continue }
            if byteCount + line.count > maximumJournalBytes { break }
            reversedLines.append(line)
            byteCount += line.count
        }
        guard !reversedLines.isEmpty || records.isEmpty else { return nil }
        var output = Data()
        output.reserveCapacity(byteCount)
        for line in reversedLines.reversed() { output.append(line) }
        return output
    }

}
