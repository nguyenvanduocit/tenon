// @domain: cli-control
import Darwin
import Foundation

enum AppInstanceChannelResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unrecognizedInstalledBundleIdentifier(String)

    var description: String {
        switch self {
        case let .unrecognizedInstalledBundleIdentifier(identifier):
            "Tenon has an unsupported installed bundle identifier: \(identifier)"
        }
    }
}

/// The closed set of installed Tenon identities that may run side by side.
///
/// A channel is host lifecycle state, not a caller principal or a wire-protocol field.
/// Each channel stays a singleton within itself while owning separate local transport and
/// durable state. Production keeps every legacy path so existing CLI discovery and user
/// state continue to work without migration.
enum AppInstanceChannel: String, CaseIterable, Sendable {
    case production
    case staging

    static let productionBundleIdentifier = "com.firegroup.tenon"
    static let stagingBundleIdentifier = "com.firegroup.tenon.staging"

    static func resolve(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isApplicationBundle: Bool = Bundle.main.bundleURL.pathExtension == "app"
    ) throws -> AppInstanceChannel {
        switch bundleIdentifier {
        case Self.productionBundleIdentifier: .production
        case Self.stagingBundleIdentifier: .staging
        case _ where !isApplicationBundle: .production
        case let identifier:
            throw AppInstanceChannelResolutionError
                .unrecognizedInstalledBundleIdentifier(identifier ?? "<missing>")
        }
    }

    var applicationSupportDirectoryName: String {
        switch self {
        case .production: "Tenon"
        case .staging: "Tenon Staging"
        }
    }

    func socketDirectoryPath(
        uid: uid_t = getuid(),
        root: String = "/tmp"
    ) -> String {
        let directoryName = switch self {
        case .production: "tenon-\(uid)"
        case .staging: "tenon-staging-\(uid)"
        }
        return (root as NSString).appendingPathComponent(directoryName)
    }

    func socketPath(uid: uid_t = getuid(), root: String = "/tmp") -> String {
        (socketDirectoryPath(uid: uid, root: root) as NSString)
            .appendingPathComponent("tenon.sock")
    }
}
