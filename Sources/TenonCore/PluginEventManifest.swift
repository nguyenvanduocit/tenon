// @domain: plugin-events
import Foundation
import TenonIntentCore

/// What a plugin may publish, and what it asks to observe (T-049).
///
/// Two declarations, two gates, and neither names the other side. A publisher states only
/// the **local** name of a channel it owns; the host prefixes it with the publishing
/// plugin's id when the fact goes out. So a plugin cannot name `automation.fired`, or
/// another plugin's channel, or anything host-owned — not because a check refuses it, but
/// because it never gets to say a full name at all. Forgery is structurally unavailable
/// rather than defended against.
///
/// An observer states the full name it wants. That is the second gate: publishing makes a
/// fact available, and observing is still a declared authority, so a plugin cannot listen to
/// traffic it never asked for in its manifest.
///
/// Neither side names the other, which is what keeps this an EVENT. The moment a publisher
/// had to list its consumers it would be a fan-out command with the dependency inverted —
/// exactly the shape T-042 rejected.
public struct PluginEventManifest: Sendable, Equatable, Codable {
    /// Local channel names this plugin may publish, without the owning prefix.
    public let publishes: [String]
    /// Fully qualified channel names this plugin asks to receive.
    public let observes: [String]

    /// Bounds (invariant 10). A manifest is a fixed declaration, so the bound belongs here
    /// rather than at emit time.
    public static let maximumChannelsPerPlugin = 32
    public static let maximumChannelNameCharacters = 128

    /// The separator between an owning plugin id and a local channel name. A local name may
    /// not contain it, so `<owner>/<local>` parses back unambiguously and a plugin cannot
    /// smuggle a second owner into its own declaration.
    public static let ownerSeparator = "/"

    public init(publishes: [String] = [], observes: [String] = []) throws {
        try Self.validate(publishes, allowOwnerPrefix: false, field: "publishes")
        try Self.validate(observes, allowOwnerPrefix: true, field: "observes")
        self.publishes = publishes
        self.observes = observes
    }

    /// The full name a fact published on `local` by `owner` travels under.
    public static func qualified(local: String, owner: PluginID) -> String {
        owner.rawValue + ownerSeparator + local
    }

    private static func validate(
        _ names: [String],
        allowOwnerPrefix: Bool,
        field: String
    ) throws {
        guard names.count <= maximumChannelsPerPlugin else {
            throw PluginEventManifestError.tooManyChannels(
                field: field,
                count: names.count
            )
        }
        var seen: Set<String> = []
        for name in names {
            guard !name.isEmpty,
                  name.count <= maximumChannelNameCharacters,
                  // No whitespace and no control characters: a channel name is an
                  // identifier, and one that can carry them is one that can be made to
                  // look like another.
                  name.unicodeScalars.allSatisfy({
                      !CharacterSet.whitespacesAndNewlines.contains($0)
                          && !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                throw PluginEventManifestError.invalidChannelName(name)
            }
            if allowOwnerPrefix {
                // An observed name is `<owner>/<local>`: exactly one separator, and neither
                // side empty.
                let parts = name.components(separatedBy: ownerSeparator)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw PluginEventManifestError.invalidChannelName(name)
                }
            } else {
                guard !name.contains(ownerSeparator) else {
                    throw PluginEventManifestError.invalidChannelName(name)
                }
            }
            guard seen.insert(name).inserted else {
                throw PluginEventManifestError.duplicateChannel(name)
            }
        }
    }
}

public enum PluginEventManifestError: Error, Sendable, Equatable {
    case tooManyChannels(field: String, count: Int)
    case invalidChannelName(String)
    case duplicateChannel(String)
}
