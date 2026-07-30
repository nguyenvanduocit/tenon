import Foundation

/// The pure rule behind `terminal.wait.v1` with `tui-idle`: a terminal screen
/// counts as idle after `stableSamples` consecutive identical readings. The
/// provider owns the cancellation-aware polling clock; this value owns only
/// the decision and stays headless-testable.
public struct IdleDetector {
    public let stableSamples: Int
    private var lastSample: String?
    private var streak: Int = 0

    public init(stableSamples: Int = 3) {
        self.stableSamples = max(1, stableSamples)
    }

    /// Feed one screen sample. Returns `true` once the screen has been unchanged for
    /// `stableSamples` consecutive readings.
    public mutating func record(_ sample: String) -> Bool {
        if sample == lastSample {
            streak += 1
        } else {
            lastSample = sample
            streak = 1
        }
        return streak >= stableSamples
    }
}
