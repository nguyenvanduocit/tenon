import Foundation

/// The manifest carried inside a single-file plugin (T-047).
///
/// A plugin's manifest is load-bearing — permissions and `intents.uses` are read *before*
/// any JavaScript is evaluated — so "just a .js file" still has to declare itself. Embedding
/// the declaration as a leading comment keeps declare-before-eval while collapsing the
/// packaging to one file.
///
/// This type does exactly one thing: find the JSON. Validating it is `PluginManifest`'s job
/// and stays there, so a single-file plugin and a directory plugin are held to the same
/// rules by the same decoder — the alternative, a second lenient path, is how two plugins
/// with the same declaration end up with different authority.
public enum PluginManifestHeader {
    /// Opens the header block. Chosen so the file is still valid JavaScript: a plugin author
    /// can run it through a linter or a formatter without the declaration being mangled.
    public static let opening = "/* tenon-manifest"
    public static let closing = "*/"

    /// The header must start the file. Trailing content before it would let a script run
    /// code — or hide a second header — above its own declaration.
    public static let maximumHeaderBytes = 64 * 1024

    /// The JSON between the markers, or `nil` when this is not a single-file plugin.
    ///
    /// Leading whitespace is allowed and nothing else is: a file whose first non-blank
    /// characters are not the opening marker has no header, rather than a header somewhere
    /// further down. "Somewhere further down" is unbounded to search and impossible to
    /// reason about when a file has two.
    public static func json(in source: String) throws -> String? {
        let trimmed = source.drop { $0.isWhitespace }
        guard trimmed.hasPrefix(opening) else { return nil }

        let afterOpening = trimmed.dropFirst(opening.count)
        guard let closingRange = afterOpening.range(of: closing) else {
            throw PluginManifestHeaderError.unterminatedHeader
        }
        let body = afterOpening[afterOpening.startIndex ..< closingRange.lowerBound]
        guard body.utf8.count <= maximumHeaderBytes else {
            throw PluginManifestHeaderError.headerTooLarge(bytes: body.utf8.count)
        }
        let json = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty else {
            throw PluginManifestHeaderError.emptyHeader
        }
        return json
    }

    /// Whether a file looks like a single-file plugin, without decoding it. Used by
    /// discovery so a stray `.js` in the plugins root is skipped rather than reported as a
    /// broken plugin — a file that never claimed to be one should not fail a reload.
    public static func hasHeader(_ source: String) -> Bool {
        source.drop { $0.isWhitespace }.hasPrefix(opening)
    }
}

public enum PluginManifestHeaderError: Error, Sendable, Equatable {
    case unterminatedHeader
    case emptyHeader
    case headerTooLarge(bytes: Int)

    public var suggestion: String {
        switch self {
        case .unterminatedHeader:
            "the `\(PluginManifestHeader.opening)` block is never closed — add `\(PluginManifestHeader.closing)` after the JSON"
        case .emptyHeader:
            "the `\(PluginManifestHeader.opening)` block is empty — it must contain the same JSON a manifest.json would"
        case let .headerTooLarge(bytes):
            "the manifest header is \(bytes) bytes; the limit is \(PluginManifestHeader.maximumHeaderBytes)"
        }
    }
}
