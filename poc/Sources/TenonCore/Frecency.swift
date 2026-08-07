// @domain: command-surface
import Foundation

/// Frequency × recency, collapsed into one decaying number per command — the signal
/// that floats a developer's habitual actions to the top of the palette (Firefox's
/// "frecency" lineage). Pure and `Codable` so the host can persist it in a dot-file
/// next to the other plugin stores; the clock is passed in, never read from the wall,
/// so decay is deterministic in tests.
public struct Frecency: Equatable, Codable {
    struct Entry: Equatable, Codable {
        var score: Double
        var lastUsedAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// Time for an idle command's score to halve. Three days: a command run daily
    /// keeps building, one run last week has nearly faded.
    public static let halfLife: TimeInterval = 3 * 24 * 60 * 60

    public init() {}

    /// Record one invocation. The stored score decays to `now` before the new use is
    /// added, so frequency accrues while recency is respected in the same number.
    public mutating func record(_ id: String, at now: Date) {
        let decayed = entries[id].map { $0.score * Frecency.decay(from: $0.lastUsedAt, to: now) } ?? 0
        entries[id] = Entry(score: decayed + 1, lastUsedAt: now)
    }

    /// The command's score as of `now`. Unseen commands score 0.
    public func score(_ id: String, now: Date) -> Double {
        guard let entry = entries[id] else { return 0 }
        return entry.score * Frecency.decay(from: entry.lastUsedAt, to: now)
    }

    /// How many distinct commands have been recorded — for tests and diagnostics.
    public var trackedCount: Int { entries.count }

    private static func decay(from past: Date, to now: Date) -> Double {
        let elapsed = now.timeIntervalSince(past)
        guard elapsed > 0 else { return 1 }
        return pow(0.5, elapsed / halfLife)
    }
}
