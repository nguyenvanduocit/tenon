// @domain: diagnostics

import Foundation

/// Whether the main runloop is still completing turns, decided from injected times alone.
///
/// The T-091 hang was not a deadlock and not slowness: the main thread never returned from a
/// single runloop-observer call, so the runloop never finished a turn. That is the signal this
/// models — not CPU, not frame rate. A busy app completes turns; a spinning one stops.
///
/// Pure on purpose. It owns no clock, no thread and no timer, so the whole judgement is
/// testable in `TenonCoreTests` without a window — the fitness test CLAUDE.md sets for
/// deciding which layer a rule belongs in. The shell feeds it `beat` from a CFRunLoopObserver
/// and `probe` from a watchdog, and does as it is told.
public struct RunloopHealth: Sendable {
    /// Something worth writing down. `nil` from a call means nothing changed, which is the
    /// overwhelmingly common case and must not produce a record.
    public enum Event: Equatable, Sendable {
        /// The first probe to notice this stall.
        case stalled(duration: TimeInterval)
        /// A stall that is still going, reported at intervals so a long freeze leaves a
        /// trail rather than one line. The T-091 hang lasted about two hours; knowing that
        /// from the journal is the difference between "it froze" and "it froze at 19:11 and
        /// was still frozen at 21:11".
        case stillStalled(duration: TimeInterval)
        /// The runloop completed a turn again.
        case recovered(stallDuration: TimeInterval)
    }

    /// How long without a completed turn counts as stalled. A turn normally completes many
    /// times a second; seconds of silence is already pathological.
    public let threshold: TimeInterval
    /// How often to re-report an ongoing stall.
    public let escalationInterval: TimeInterval

    private var lastBeat: TimeInterval
    private var stallStart: TimeInterval?
    private var lastReport: TimeInterval?

    public init(
        threshold: TimeInterval = 5,
        escalationInterval: TimeInterval = 60,
        startedAt: TimeInterval
    ) {
        self.threshold = threshold
        self.escalationInterval = escalationInterval
        self.lastBeat = startedAt
    }

    /// True while the runloop is considered stalled, for a caller that wants to attach the
    /// state to something else rather than react to a change.
    public var isStalled: Bool { stallStart != nil }

    /// The main runloop completed a turn.
    public mutating func beat(at now: TimeInterval) -> Event? {
        defer {
            lastBeat = now
            stallStart = nil
            lastReport = nil
        }
        guard let stallStart else { return nil }
        return .recovered(stallDuration: now - stallStart)
    }

    /// The watchdog looked. Runs off the main queue, so it still fires while the main queue
    /// is wedged — a probe scheduled on the stalled queue would be stalled with it.
    public mutating func probe(at now: TimeInterval) -> Event? {
        let silence = now - lastBeat
        guard silence >= threshold else { return nil }

        if stallStart == nil {
            stallStart = lastBeat
            lastReport = now
            return .stalled(duration: silence)
        }

        guard let lastReport, now - lastReport >= escalationInterval else { return nil }
        self.lastReport = now
        return .stillStalled(duration: silence)
    }
}
