// @domain: plugin-events
import Foundation
import TenonIntentCore

/// Who a fact is allowed to reach.
///
/// The routing rules used to live inline in three places in `PluginHost` — the broadcast loop,
/// the targeted send, and the plugin-published fan-out — each restating the same two gates in
/// its own words. That is the shape a rule takes just before one copy of it is forgotten, and
/// these particular rules are the reason a plugin cannot read another plugin's terminal.
///
/// Pure by construction: manifests in, identities out. There is no session, no runtime and no
/// ordering here, so every rule can be asserted without a host.
enum PluginEventRouting {
    /// Events whose name begins here describe what is happening inside somebody's terminal,
    /// and are delivered only to plugins that asked for terminal access.
    static let terminalPrefix = "terminal."
    static let terminalPermission = "terminal.read"

    /// Whether this generation may be told about this event at all.
    ///
    /// The permission gate is separate from the subscription check on purpose: a plugin that
    /// subscribes to `terminal.title-changed` without declaring `terminal.read` is not a
    /// delivery that fails, it is a delivery that never happens.
    static func permits(event: String, manifest: PluginManifest) -> Bool {
        guard event.hasPrefix(terminalPrefix) else { return true }
        return manifest.permissions.contains(terminalPermission)
    }

    /// Whether a plugin may publish this local channel name — the manifest declaration that
    /// makes `tenon.events.emit` a fact about its own subject rather than a broadcast.
    static func mayPublish(local: String, manifest: PluginManifest) -> Bool {
        manifest.events?.publishes.contains(local) == true
    }

    /// The generations that declared this qualified channel, in a stable order so a fan-out is
    /// the same on every render and every run.
    static func observers(
        of qualified: String,
        among manifests: [PluginID: PluginManifest]
    ) -> [PluginID] {
        manifests
            .filter { $0.value.events?.observes.contains(qualified) == true }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }
}
