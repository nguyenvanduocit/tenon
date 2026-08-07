import Foundation

/// The browser identity Tenon's web surfaces advertise.
///
/// WebKit composes the platform and engine tokens itself and appends
/// `applicationNameForUserAgent` verbatim. With that name unset the string ends at
/// `(KHTML, like Gecko)` — an engine with no browser product — and UA-sniffing sites route
/// it to legacy or unsupported-browser variants. Contributing the product token is the whole
/// rule; the tokens WebKit owns stay WebKit's, which is why this is an application name and
/// never a `customUserAgent` override of the entire string.
enum WebUserAgent {
    /// The engine build WebKit already reports, so the Safari token repeats it rather than
    /// contradicting it.
    static let webKitBuild = "605.1.15"

    /// Safari's marketing version tracks the macOS release from macOS 26 onward (this
    /// machine: macOS 26.4.1, Safari 26.4). Earlier systems shipped Safari versions that do
    /// not match their OS number, so they claim the last Safari of that era instead of a
    /// token that would read as a decade-old browser.
    static func applicationName(
        operatingSystemVersion version: OperatingSystemVersion
    ) -> String {
        let safariVersion = version.majorVersion >= 26
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "18.5"
        return "Version/\(safariVersion) Safari/\(webKitBuild)"
    }

    static var current: String {
        applicationName(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }
}
