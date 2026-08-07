import Foundation

/// Installs the `tenon-cli` binary into the user's PATH so agents and scripts can drive Tenon from
/// any terminal. No admin required: it copies into `~/.local/bin`. The binary is self-contained
/// (TenonCore is statically linked), so it runs from anywhere once copied.
enum CLICommandInstaller {
    static let binaryName = "tenon-cli"

    /// A user-writable bin dir — no sudo, works for every launch method.
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    static var installedURL: URL {
        installDirectory.appendingPathComponent(binaryName)
    }

    /// The binary to copy FROM: the auxiliary executable bundled in `Tenon.app` (`Contents/MacOS`),
    /// else a sibling of the running executable — which covers `swift run tenon`, where the
    /// self-contained SwiftPM `tenon-cli` sits next to `tenon` in the build products dir.
    static var sourceURL: URL? {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: binaryName),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(binaryName),
           fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedURL.path)
    }

    /// The neutral command belongs to production. Staging panes already receive their bundled
    /// CLI and channel socket through the terminal environment, but must not replace the global
    /// command used by production.
    static func canInstall(in instanceChannel: AppInstanceChannel) -> Bool {
        instanceChannel == .production && sourceURL != nil
    }

    enum InstallError: Error, CustomStringConvertible {
        case sourceNotFound
        case productionOnly
        case failed(String)

        var description: String {
            switch self {
            case .sourceNotFound:
                return "Could not find a tenon-cli binary to install from this build."
            case .productionOnly:
                return "Only production Tenon may replace the global tenon-cli command."
            case .failed(let detail):
                return "Install failed: \(detail)"
            }
        }
    }

    /// Copy `tenon-cli` into `~/.local/bin`, replacing any prior copy, and mark it executable.
    @discardableResult
    static func install(in instanceChannel: AppInstanceChannel) throws -> URL {
        guard instanceChannel == .production else {
            throw InstallError.productionOnly
        }
        guard let source = sourceURL else { throw InstallError.sourceNotFound }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: installedURL.path) {
                try fileManager.removeItem(at: installedURL)
            }
            try fileManager.copyItem(at: source, to: installedURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        return installedURL
    }
}
