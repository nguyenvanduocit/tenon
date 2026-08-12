// @domain: attention
import Foundation

/// Which claim a pane currently has on human attention.
///
/// - `working`: the screen is still changing — an agent or command is producing
///   output. Needs nothing; glanceable.
/// - `idle`: a stable screen with no unacknowledged finish — a shell sitting at
///   its prompt with nothing to report. Never asks for attention.
/// - `finishedUnseen`: a command finished (`commandFinishedCount` rose) while no
///   human was viewing the pane, and none has viewed it since. This is the one
///   state that directs attention; it is reachable only through a real finish,
///   never through mere quietness.
/// - `seen`: the last finish was acknowledged by an actual view (or happened
///   under the human's eyes). Stable and calm until the pane does something new.
/// - `exited`: the shell process is gone. Terminal — no observation resurrects
///   the pane — but not the same as finished: an exit nobody viewed keeps its
///   unseen flag, because a crashed process still needs a human.
public enum PaneActivityState: Equatable, Sendable {
    case working
    case idle
    case finishedUnseen
    case seen
    case exited
}

/// What one input did to the machine. Mutations return events (docs/tdd.md);
/// an empty array means nothing observable changed. `becameUnseen` is the
/// notification seam: it fires exactly when a pane starts needing a human.
public enum PaneActivityEvent: Equatable, Sendable {
    case stateChanged(from: PaneActivityState, to: PaneActivityState)
    case becameUnseen
    case unseenCleared
}

/// The pure attention machine behind tab chips, pane headers, sidebar rollups
/// and completion notifications. Inputs are terminal observations, explicit
/// viewed-ness, and an injected clock; it owns no timer and reads no ambient
/// time, so every transition is deterministic in tests.
///
/// `isUnseen` is the bold-until-viewed bit and rides beside `state` rather than
/// inside it: a pane that finishes unviewed and then starts new output is
/// `working` *and* still bold, because activity is not acknowledgement — only
/// an explicit `setViewed(true)` clears it.
public struct PaneActivity: Sendable {
    /// The slice of a terminal observation the machine consumes. The app shell
    /// maps its own per-surface observation onto this value on the same polling
    /// cadence `terminal.wait.v1` already uses, which is what makes the
    /// embedded `IdleDetector` streak mean "stable across polls".
    public struct Observation: Equatable, Sendable {
        /// A value that changes when the visible screen changes. The machine compares
        /// consecutive samples and never reads the screen, so the shell owes it a fingerprint
        /// rather than rendered characters — see `IdleDetector.record`.
        public let screen: Int
        public let processExited: Bool
        public let commandFinishedCount: Int

        public init(screen: Int, processExited: Bool, commandFinishedCount: Int) {
            self.screen = screen
            self.processExited = processExited
            self.commandFinishedCount = commandFinishedCount
        }
    }

    public private(set) var state: PaneActivityState = .working
    public private(set) var isUnseen = false
    public private(set) var isViewed: Bool
    /// When the current `state` began, in the caller's clock. Untouched by
    /// observations that change nothing, so surfaces can show honest ages.
    public private(set) var stateSince: Date
    /// The injected instant of the most recent finish. Baselining and counter
    /// resets never stamp it — history that predates the machine is not news.
    public private(set) var lastFinishedAt: Date?

    /// The one idle rule (invariant 6): the same detector `terminal.wait.v1`
    /// uses, fed here per observation instead of per wait call.
    private var detector: IdleDetector
    private var screenStable = false
    private var baselined = false
    private var observedFinishes = 0
    private var acknowledgedFinishes = 0
    private var hasExited = false
    private var exitAcknowledged = false
    private var hasAcknowledgedFinishEver = false

    public init(stableSamples: Int = 3, viewed: Bool = false, at now: Date) {
        self.detector = IdleDetector(stableSamples: stableSamples)
        self.isViewed = viewed
        self.stateSince = now
    }

    public mutating func observe(
        _ observation: Observation,
        at now: Date
    ) -> [PaneActivityEvent] {
        // Exited is terminal: whatever a late observation claims, the pane's
        // story ended at the exit and its unseen-ness answers only to viewing.
        guard !hasExited else { return [] }

        screenStable = detector.record(observation.screen)

        if !baselined {
            // The first observation defines "before": finishes that predate the
            // machine never bold.
            baselined = true
            observedFinishes = observation.commandFinishedCount
            acknowledgedFinishes = observation.commandFinishedCount
        } else if observation.commandFinishedCount < observedFinishes {
            // A backend counter reset rebaselines; it never invents attention.
            observedFinishes = observation.commandFinishedCount
            acknowledgedFinishes = observation.commandFinishedCount
        } else if observation.commandFinishedCount > observedFinishes {
            observedFinishes = observation.commandFinishedCount
            lastFinishedAt = now
            if isViewed {
                // A finish under the human's eyes needs no flag: watching it
                // happen is the acknowledgement.
                acknowledgedFinishes = observedFinishes
                hasAcknowledgedFinishEver = true
            }
        }

        if observation.processExited {
            hasExited = true
            exitAcknowledged = isViewed
        }

        return commit(at: now)
    }

    public mutating func setViewed(
        _ viewed: Bool,
        at now: Date
    ) -> [PaneActivityEvent] {
        isViewed = viewed
        if viewed {
            if observedFinishes > acknowledgedFinishes {
                acknowledgedFinishes = observedFinishes
                hasAcknowledgedFinishEver = true
            }
            if hasExited {
                exitAcknowledged = true
            }
        }
        // Un-viewing acknowledges nothing and re-flags nothing: the flag only
        // ever moves through a finish, an exit, or an actual view.
        return commit(at: now)
    }

    private mutating func commit(at now: Date) -> [PaneActivityEvent] {
        var events: [PaneActivityEvent] = []
        let newState = derivedState
        if newState != state {
            events.append(.stateChanged(from: state, to: newState))
            state = newState
            stateSince = now
        }
        let newUnseen = derivedUnseen
        if newUnseen != isUnseen {
            events.append(newUnseen ? .becameUnseen : .unseenCleared)
            isUnseen = newUnseen
        }
        return events
    }

    private var derivedState: PaneActivityState {
        if hasExited { return .exited }
        if !screenStable { return .working }
        if observedFinishes > acknowledgedFinishes { return .finishedUnseen }
        if hasAcknowledgedFinishEver { return .seen }
        return .idle
    }

    private var derivedUnseen: Bool {
        observedFinishes > acknowledgedFinishes || (hasExited && !exitAcknowledged)
    }
}
