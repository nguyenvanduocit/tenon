// @domain: intent-bus
import Foundation
import TenonIntentCore

/// One plugin's permission to serve one delegable contract.
///
/// The pair is the whole grant: approving `dev.tenon.browser` for `url.open.v1` says
/// nothing about any other plugin or any other contract. Naming the plugin in the record —
/// rather than approving a contract and letting whoever binds it win — is what makes the
/// question a person answers ("let *this* plugin open addresses?") the same question the
/// policy enforces.
public struct OpenHandlerApproval: Hashable, Codable, Sendable {
    public let pluginID: PluginID
    public let intentID: IntentID

    public init(pluginID: PluginID, intentID: IntentID) {
        self.pluginID = pluginID
        self.intentID = intentID
    }
}

/// What a person has agreed to let plugins open, and what is still only an offer.
///
/// A handler sees everything the person opens through it — every address, every path. That
/// is a privacy surface rather than a detail, so approval is explicit, per plugin, listed
/// with the plugin's own identity, and revocable. Nothing is granted by installing.
/// See `docs/design-open-handlers.md`.
public actor OpenHandlerApprovals {
    private let fileURL: URL
    public private(set) var approvals: Set<OpenHandlerApproval>

    public init(fileURL: URL, preloaded: Set<OpenHandlerApproval>? = nil) {
        self.fileURL = fileURL
        approvals = preloaded ?? Self.read(from: fileURL)
    }

    /// Launch-time read seam, matching `RecentStore`: the app reads during its concurrent
    /// preparation phase and constructs the UI-owned store from the immutable result.
    package static func load(from fileURL: URL) -> Set<OpenHandlerApproval> {
        read(from: fileURL)
    }

    /// The contracts this plugin may serve. This is the exact value
    /// `ProviderActivationCoordinator` takes as `approvedOpenIntentIDs`, so what a person
    /// sees in settings and what the kernel enforces are one fact.
    public func approvedIntentIDs(for pluginID: PluginID) -> Set<IntentID> {
        Set(approvals.filter { $0.pluginID == pluginID }.map(\.intentID))
    }

    public func isApproved(pluginID: PluginID, intentID: IntentID) -> Bool {
        approvals.contains(OpenHandlerApproval(pluginID: pluginID, intentID: intentID))
    }

    public func approve(pluginID: PluginID, intentID: IntentID) {
        let approval = OpenHandlerApproval(pluginID: pluginID, intentID: intentID)
        guard !approvals.contains(approval) else { return }
        approvals.insert(approval)
        Self.write(approvals, to: fileURL)
    }

    /// Revoking is immediate and total for that pair. The person's configured default is
    /// the kernel's to drop — `ProviderRegistry` already clears a configured default when
    /// the provider behind it retires, and revocation retires this binding.
    public func revoke(pluginID: PluginID, intentID: IntentID) {
        let approval = OpenHandlerApproval(pluginID: pluginID, intentID: intentID)
        guard approvals.contains(approval) else { return }
        approvals.remove(approval)
        Self.write(approvals, to: fileURL)
    }

    /// Every approval this plugin held, dropped at once. Uninstalling a plugin must not
    /// leave a grant behind that a later plugin claiming the same id would inherit.
    public func revokeAll(for pluginID: PluginID) {
        let remaining = approvals.filter { $0.pluginID != pluginID }
        guard remaining != approvals else { return }
        approvals = remaining
        Self.write(approvals, to: fileURL)
    }

    private static func read(from fileURL: URL) -> Set<OpenHandlerApproval> {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                  [OpenHandlerApproval].self,
                  from: data
              )
        else {
            return []
        }
        return Set(decoded)
    }

    private static func write(_ approvals: Set<OpenHandlerApproval>, to fileURL: URL) {
        // Sorted so the file is stable to read and to diff; a grant list is something a
        // person may want to inspect outside the app.
        let ordered = approvals.sorted {
            ($0.pluginID.rawValue, $0.intentID.rawValue)
                < ($1.pluginID.rawValue, $1.intentID.rawValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ordered) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// One row of the approval surface: a plugin offering to handle something, with the
/// identity a person needs in order to answer.
public struct OpenHandlerOffer: Equatable, Sendable, Identifiable {
    public let pluginID: PluginID
    public let pluginName: String
    public let intentID: IntentID
    public let contractTitle: String
    public let isApproved: Bool

    public var id: String { "\(pluginID.rawValue)|\(intentID.rawValue)" }

    public init(
        pluginID: PluginID,
        pluginName: String,
        intentID: IntentID,
        contractTitle: String,
        isApproved: Bool
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.intentID = intentID
        self.contractTitle = contractTitle
        self.isApproved = isApproved
    }
}
