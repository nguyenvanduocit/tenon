// @domain: intent-bus
import Foundation
import TenonIntentCore

enum StandingConsentStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case tooManyRecords(count: Int, limit: Int)

    var description: String {
        switch self {
        case let .tooManyRecords(count, limit):
            return "Standing consent holds \(count) records, over the limit of \(limit)."
        }
    }
}

/// Where the approvals a person gives are kept between launches.
///
/// Before this existed the `PolicyEngine` held them in memory alone, so "Always allow" was
/// true until the app quit and every relaunch asked the same questions again. Consent
/// belongs to an installation, not to a process (`CallerConsentKey` says so by omitting the
/// session revision), and this is the file that makes the code mean it.
///
/// Reads are fail-soft and writes are fail-closed, deliberately in that direction: an
/// unreadable file costs some prompts, while a write that quietly failed would leave the
/// engine approving on authority nothing recorded.
struct StandingConsentStore: Sendable {
    /// Consent records kept. Reached only by an installation holding thousands of separate
    /// approvals, which is a runaway rather than a workflow — invariant 10 wants a number
    /// here, and this is one no ordinary use meets.
    static let recordLimit = 4_096

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// What an earlier launch left. Anything unreadable — a partial write, a file from a
    /// build that spelled these keys differently, a hand edit — reads as nothing, which
    /// costs prompts and grants no authority.
    func load() -> StandingConsentSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(
                  StandingConsentSnapshot.self,
                  from: data
              ),
              snapshot.contracts.count + snapshot.callers.count <= Self.recordLimit
        else {
            return .empty
        }
        return snapshot
    }

    /// Replaces the file with the state that is about to hold.
    ///
    /// Atomic, because the alternative to a whole file is a truncated one, and a truncated
    /// one is what `load` would then refuse — silently dropping consent the person gave.
    func write(_ snapshot: StandingConsentSnapshot) throws {
        let count = snapshot.contracts.count + snapshot.callers.count
        guard count <= Self.recordLimit else {
            throw StandingConsentStoreError.tooManyRecords(
                count: count,
                limit: Self.recordLimit
            )
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// The kernel's door into this file. Synchronous by contract: the engine runs it before
    /// it remembers a grant, so a failure is the grant's failure. It runs at the speed a
    /// person answers a dialog, on a few kilobytes.
    func writer() -> StandingConsentWriter {
        { snapshot in
            try write(snapshot)
        }
    }
}
