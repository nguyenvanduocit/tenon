import Foundation

/// The host-owned trust provenance persisted with an installation identity.
///
/// Changing class is an installation boundary, not a hot reload: the old identity may
/// carry standing consent and durable plugin data that code from the other class must not
/// inherit.
public enum PluginInventoryTrust: String, Sendable, Codable {
    case explicitEnablement
    case bundledStandingConsent
}

/// One place plugins are loaded from, and what the host trusts things found there with
/// (T-062).
///
/// Tenon reads more than one inventory because the two have opposite properties. The
/// app bundle's inventory is **sealed and replaceable**: writing into it breaks the
/// code signature, and installing a new build deletes whatever was added. A user
/// inventory is **writable and durable**: it is where a person — or an agent
/// pair-authoring with them — puts a plugin they wrote.
///
/// Trust follows the inventory, never the file's location alone: everything in the
/// bundle was accepted when the user installed Tenon, and nothing in a user inventory
/// was. That keeps standing consent host-owned (T-033) and stops "put the file in the
/// right folder" from being a way to grant authority.
public struct PluginInventory: Sendable {
    public let root: URL
    public let authorization: PluginHostAuthorization
    /// Whether newly authored plugins may be written here. False for the app bundle:
    /// a write there breaks the seal and is erased by the next install.
    public let isWritable: Bool
    /// Whether discovery may execute a plugin that has no durable installation decision yet.
    /// Writable, user-authored inventories set this to false because in-process
    /// JavaScriptCore is an execution boundary, not a hard process sandbox.
    public let enablesNewPluginsByDefault: Bool

    public init(
        root: URL,
        authorization: PluginHostAuthorization,
        isWritable: Bool,
        enablesNewPluginsByDefault: Bool = true
    ) {
        self.root = root
        self.authorization = authorization
        self.isWritable = isWritable
        self.enablesNewPluginsByDefault = enablesNewPluginsByDefault
    }
}

/// Which inventory a discovered plugin came from — a pure rule, so the trust decision
/// that depends on it is assertable without a host.
public enum PluginInventoryResolution {
    /// Discovery only ever yields direct children of a root, so ownership is exact
    /// parent equality rather than a path-prefix test. Prefix matching would have to
    /// answer for `..`, symlinks, and one root nested inside another; equality has no
    /// such cases, and anything it cannot place is unowned — which callers treat as
    /// untrusted.
    public static func inventory(
        for pluginDirectory: URL,
        in inventories: [PluginInventory]
    ) -> PluginInventory? {
        // Compared by path, not by URL: a root built with `isDirectory: true` carries a
        // trailing slash that `deletingLastPathComponent` may not reproduce, and two
        // URLs that name the same directory must not fail to match over that.
        let parent = pluginDirectory
            .standardizedFileURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        return inventories.first {
            $0.root.standardizedFileURL.path == parent
        }
    }
}
