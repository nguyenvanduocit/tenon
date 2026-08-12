// @domain: attention
import Foundation

/// The pure rule behind `terminal.wait.v1` with `tui-idle`: a terminal screen
/// counts as idle after `stableSamples` consecutive identical readings. The
/// provider owns the cancellation-aware polling clock; this value owns only
/// the decision and stays headless-testable.
public struct IdleDetector: Sendable {
    public let stableSamples: Int
    private var lastSample: Int?
    private var streak: Int = 0

    public init(stableSamples: Int = 3) {
        self.stableSamples = max(1, stableSamples)
    }

    /// Feed one screen sample. Returns `true` once the screen has been unchanged for
    /// `stableSamples` consecutive readings.
    ///
    /// A sample is a fingerprint rather than the screen's characters, because the only question
    /// asked of it is the `==` below — and answering that with rendered text costs one Swift
    /// `String` per row plus a regular expression per row, five times a second, per pane (T-141).
    public mutating func record(_ sample: Int) -> Bool {
        if sample == lastSample {
            streak += 1
        } else {
            lastSample = sample
            streak = 1
        }
        return streak >= stableSamples
    }
}
