// @domain: diagnostics

import Foundation
import os

/// The app's own log, filterable by subsystem in Console and `log show`.
///
/// Before this, the host's five diagnostics went through `NSLog`, which lands in the same
/// undifferentiated stream as every framework's chatter — the T-091 investigation had to
/// filter Tenon's log by hand and found nothing of the app's own in it. A category per
/// concern is what makes `log show --predicate 'subsystem == "dev.tenon.app"'` a
/// useful first move instead of a wall of XPC noise.
///
/// Distinct from `tenon.log`, which is a plugin's output and is attributed to that
/// generation. This is the host talking about itself.
enum TenonLog {
    static let subsystem = "dev.tenon.app"

    /// Terminal surfaces, libghostty init and PTY lifetime.
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
    /// The local control socket the CLI speaks to.
    static let cli = Logger(subsystem: subsystem, category: "cli")
    /// The app's judgement about its own health.
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    /// Readings of an agent session: the CLI a synthesis ran, and how that run ended.
    ///
    /// A reading is the longest-running thing this host asks for — measured 2026-08-16 at 247 to
    /// 379 seconds over real sessions — and it can end six different ways. Until T-169 it wrote
    /// nothing at all, so an operator reporting "it timed out" left no record saying which
    /// deadline, on which provider, over how much evidence, and the failure had to be
    /// reconstructed by re-running the pipeline outside the app.
    static let agentLens = Logger(subsystem: subsystem, category: "agent-lens")
}
