// @domain: workspace-model
import Foundation

/// The app's own version, resolved from whichever build produced this binary.
///
/// A sibling of `AppMark`: both are facts about the running build that the shell reports
/// rather than computes. This one is read by Settings, which is where a person goes to ask
/// what they are running — the workspace list is not.
struct AppVersion: Equatable, Sendable {
    let short: String
    let build: String

    /// The one rendering of a version anywhere in the app.
    var summary: String { "v\(short) (\(build))" }

    static let current = AppVersion.read(from: .main)

    /// A build with no version keys is reported as unknown rather than silently as zero:
    /// `swift run tenon` has no `Info.plist`, and a blank field there would read as a
    /// shipped version of nothing.
    static let unknown = "—"

    static func read(from bundle: Bundle) -> AppVersion {
        AppVersion(
            short: string(bundle, "CFBundleShortVersionString"),
            build: string(bundle, "CFBundleVersion")
        )
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String {
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return unknown
        }
        return value
    }
}
