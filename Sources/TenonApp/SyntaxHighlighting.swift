// @domain: editor-and-diff
import AppKit
import STPluginNeon
// TreeSitterResource defines TreeSitterLanguage. It's an internal module of the
// plugin package (not re-exported by STPluginNeon), but it must be imported
// directly: this toolchain enforces MemberImportVisibility, so an enum case is
// only usable when its defining module is imported.
@preconcurrency import TreeSitterResource
// Base query files, for languages whose highlights inherit another language's
// (see `highlightsData(for:)`).
import TreeSitterCQueries
import TreeSitterJavaScriptQueries
import TreeSitterTypeScriptQueries
// Injection query files, for languages that embed other languages (see
// `injectionsData(for:)`). Like the base-query modules above, these are
// internal plugin targets imported directly for MemberImportVisibility.
import TreeSitterHTMLQueries
import TreeSitterMarkdownQueries
import TreeSitterPHPQueries
import TreeSitterRustQueries
// Tenon's standalone TSX grammar module, for `SyntaxLanguage.tsx`.
import TenonTreeSitterTSX

/// A grammar the editor can highlight with: one of the plugin's bundled languages,
/// or TSX, which Tenon vendors.
///
/// tree-sitter-typescript ships JSX as a **separate grammar** because `<tag>` is
/// ambiguous with TypeScript's `<T>x` type assertion. The plugin product
/// provides the TypeScript grammar; Tenon's standalone `TreeSitterTSX` product
/// provides the JSX-capable grammar through its `TenonTreeSitterTSX` module.
/// See `Vendor/TreeSitterTSX`.
enum SyntaxLanguage: Hashable {
    case bundled(TreeSitterLanguage)
    case tsx

    /// The tree-sitter grammar, as `TreeSitterLanguage.parser` hands it over.
    var parser: OpaquePointer {
        switch self {
        case .bundled(let language): language.parser
        case .tsx: tree_sitter_tsx()
        }
    }
}

/// Tree-sitter syntax highlighting for the source editor. `SourceEditorView`
/// asks for a plugin per file; unsupported file types get `nil` and render as
/// plain text. The highlighter itself lives in `SyntaxHighlightPlugin`.
enum SyntaxHighlighting {
    /// The theme handed to the highlighter, paired with an **empty** font table.
    ///
    /// The empty fonts are deliberate. The highlighter would otherwise tag each
    /// token with `theme.font(forToken:)` and reset the view to SF Mono,
    /// discarding the editor's own font. With no fonts, every token
    /// keeps the editor's own font and only the foreground color changes.
    ///
    /// The colours are declared here rather than taken from the plugin's bundled
    /// `Theme.default`. That one reads an **asset catalog**, and SwiftPM does not run
    /// `actool` — it copies `.xcassets` into the bundle uncompiled, so every
    /// `NSColor(named:)` comes back nil and the plugin's own initializer force-unwraps
    /// it. Under Xcode it works and under `swift run` it is a launch crash. Declaring
    /// the palette in code also means the editor's colours are ours to theme.
    ///
    /// `STPluginNeonAppKit.Theme` is fully qualified because `TenonTheme` is not it —
    /// this is the highlighter's palette, not the app chrome's.
    @MainActor
    static let theme = STPluginNeonAppKit.Theme(
        colors: STPluginNeonAppKit.Theme.Colors(colors: palette),
        fonts: STPluginNeonAppKit.Theme.Fonts(fonts: [:])
    )

    /// One capture colour, light and dark. Each is a dynamic `NSColor`, so the editor
    /// follows the window appearance the way the asset-backed original did.
    private struct Swatch {
        let light: Int
        let lightAlpha: CGFloat
        let dark: Int
        let darkAlpha: CGFloat

        init(light: Int, lightAlpha: CGFloat = 1, dark: Int, darkAlpha: CGFloat = 1) {
            self.light = light
            self.lightAlpha = lightAlpha
            self.dark = dark
            self.darkAlpha = darkAlpha
        }

        var color: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return Self.make(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            }
        }

        private static func make(_ hex: Int, alpha: CGFloat) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    /// Xcode's default source palette — the same colours the plugin's asset catalog
    /// carries, so a file here looks like a file in the editor this was modelled on.
    /// `plain` is deliberately absent: the fallback for an unmatched capture should be
    /// the editor's own text colour, which `SyntaxHighlightPlugin` supplies.
    private static let palette: [String: NSColor] = [
        "boolean": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "comment": Swatch(light: 0x000000, lightAlpha: 0.50, dark: 0xFFFFFF, darkAlpha: 0.55).color,
        "constructor": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "function.call": Swatch(light: 0x0B4F79, dark: 0xF4B086).color,
        "include": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "keyword": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "keyword.function": Swatch(light: 0x326D74, dark: 0xCD928B).color,
        "keyword.return": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "method": Swatch(light: 0x326D74, dark: 0xCD928B).color,
        "number": Swatch(light: 0x1C00CF, dark: 0xE3FF30).color,
        "operator": Swatch(light: 0x000000, dark: 0xFFFFFF).color,
        "parameter": Swatch(light: 0x000000, dark: 0xFFFFFF).color,
        "property": Swatch(light: 0x326D74, dark: 0xCD928B).color,
        "punctuation.special": Swatch(light: 0x9B2393, dark: 0x64DC6C).color,
        "string": Swatch(light: 0x990000, dark: 0x66FFFF).color,
        "text.literal": Swatch(light: 0x990000, dark: 0x66FFFF).color,
        "text.title": Swatch(light: 0x1C00CF, dark: 0xE3FF30).color,
        "type": Swatch(light: 0x0B4F79, dark: 0xF4B086).color,
        "variable": Swatch(light: 0x000000, dark: 0xFFFFFF).color,
        "variable.builtin": Swatch(light: 0x326D74, dark: 0xCD928B).color,
    ]

    /// A syntax-highlighting plugin for `path`, or `nil` when the file type has
    /// no bundled grammar (the editor then shows plain text).
    @MainActor
    static func plugin(for path: String) -> SyntaxHighlightPlugin? {
        guard let language = language(for: path) else { return nil }
        return SyntaxHighlightPlugin(
            theme: theme,
            language: language,
            highlightsData: highlightsData(for: language),
            injectionsData: injectionsData(for: language)
        )
    }

    /// The combined highlights query for a language: the query files it
    /// *inherits* (nvim-treesitter's `; inherits:` convention) concatenated
    /// ahead of its own, so the language-specific captures win. SwiftTreeSitter
    /// doesn't resolve inheritance, so without this TypeScript (inherits
    /// JavaScript) and C++ (inherits C) lose comments, strings and base
    /// keywords — everything defined only in the parent's query.
    ///
    /// JSX is the one addition that goes *last* rather than first: its
    /// `@tag`/`@attribute` captures have to beat the generic `(identifier)`
    /// rules both parents apply to the same node, so that `<main>` and `<Foo>`
    /// come out looking alike.
    static func highlightsData(for language: SyntaxLanguage) -> Data {
        var urls: [URL] = []
        switch language {
        case .tsx:
            // TSX inherits *both* parents. It contributes no query of its own:
            // tree-sitter-typescript's tsx and typescript highlights are the
            // same file, and only TypeScript's is built into the plugin.
            urls = [
                TreeSitterJavaScriptQueries.Query.highlightsFileURL,
                TreeSitterTypeScriptQueries.Query.highlightsFileURL,
                TreeSitterJavaScriptQueries.Query.highlightsJSXFileURL,
            ]
        case .bundled(let language):
            switch language {
            case .typescript:
                urls.append(TreeSitterJavaScriptQueries.Query.highlightsFileURL)
            case .cpp:
                urls.append(TreeSitterCQueries.Query.highlightsFileURL)
            default:
                break
            }
            if let own = language.highlightQueryURL {
                urls.append(own)
            }
            // The JavaScript grammar parses JSX too (`.jsx`, and `.js` in
            // practice), but keeps its element captures in a second file.
            if language == .javascript {
                urls.append(TreeSitterJavaScriptQueries.Query.highlightsJSXFileURL)
            }
        }

        var data = Data()
        for url in urls {
            guard let chunk = try? Data(contentsOf: url) else { continue }
            data.append(chunk)
            data.append(0x0A) // keep concatenated query files on separate lines
        }
        return data
    }

    /// The injections query for a language that embeds *other* languages — e.g.
    /// markdown fenced code blocks (` ```sh `), HTML `<script>`/`<style>`, PHP's
    /// interleaved HTML, Rust macro bodies — or `nil` for a self-contained
    /// language. When non-nil, `SyntaxHighlightCoordinator` sub-parses each
    /// embedded region with its own grammar so, say, a shell block's comments
    /// get the comment color instead of rendering as plain text.
    ///
    /// The single `.scm` isn't inheritance-merged (unlike `highlightsData`):
    /// injection queries don't use nvim's `; inherits:` convention.
    static func injectionsData(for language: SyntaxLanguage) -> Data? {
        let url: URL
        switch language {
        case .bundled(.markdown): url = TreeSitterMarkdownQueries.Query.injectionsFileURL
        case .bundled(.html):     url = TreeSitterHTMLQueries.Query.injectionsFileURL
        case .bundled(.php):      url = TreeSitterPHPQueries.Query.injectionsFileURL
        case .bundled(.rust):     url = TreeSitterRustQueries.Query.injectionsFileURL
        default:                  return nil
        }
        return try? Data(contentsOf: url)
    }

    /// The tree-sitter language named by an injection's `@injection.language`
    /// capture — the info string after a code fence (` ```bash `), or a name a
    /// grammar hard-codes (HTML injects `"javascript"`/`"css"`). Resolved
    /// against a small alias table and then the file-extension map, since fence
    /// info strings are usually just extensions (`sh`, `js`, `py`). Names with
    /// no bundled grammar (`text`, `diff`, `markdown_inline`, …) return `nil`
    /// and that region is left as plain text.
    static func language(forInjectionName name: String) -> SyntaxLanguage? {
        let key = name.lowercased()
        if key == tsxExtension || key == "typescriptreact" { return .tsx }
        if let language = injectionAliases[key] { return .bundled(language) }
        return byExtension[key].map(SyntaxLanguage.bundled)
    }

    /// Long-form injection names not already covered by `byExtension` (which
    /// handles `sh`, `js`, `ts`, `py`, `rb`, `rs`, `cpp`, `c++`, `yml`, …).
    private static let injectionAliases: [String: TreeSitterLanguage] = [
        "shell": .bash, "shellscript": .bash, "shell-script": .bash,
        "javascript": .javascript, "node": .javascript, "javascriptreact": .javascript,
        "typescript": .typescript,
        "python": .python,
        "ruby": .ruby,
        "rust": .rust,
        "golang": .go,
        "cplusplus": .cpp,
        "csharp": .csharp, "c#": .csharp,
        "markdown": .markdown,
    ]

    /// The tree-sitter language for a file, matched by extension first and
    /// then by a few well-known extensionless names.
    static func language(for path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        // Kept out of `byExtension`, which only holds the plugin's own grammars.
        if ext == tsxExtension { return .tsx }
        if let language = byExtension[ext] {
            return .bundled(language)
        }
        return byName[name].map(SyntaxLanguage.bundled)
    }

    /// The one extension that needs the vendored grammar. `.mts`/`.cts` stay on
    /// plain TypeScript — only `.tsx` may contain JSX.
    private static let tsxExtension = "tsx"

    private static let byExtension: [String: TreeSitterLanguage] = [
        "swift": .swift,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "json": .json, "jsonc": .json, "json5": .json,
        "py": .python, "pyi": .python, "pyw": .python,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "rs": .rust,
        "go": .go,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp,
        "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "h++": .cpp,
        "cs": .csharp,
        "css": .css,
        "html": .html, "htm": .html, "xhtml": .html,
        "java": .java,
        "php": .php, "phtml": .php,
        "sh": .bash, "bash": .bash, "zsh": .bash, "ksh": .bash,
        "sql": .sql,
        "toml": .toml,
        "yaml": .yaml, "yml": .yaml,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown, "mdx": .markdown,
    ]

    private static let byName: [String: TreeSitterLanguage] = [
        ".bashrc": .bash, ".bash_profile": .bash, ".profile": .bash,
        ".zshrc": .bash, ".zprofile": .bash, ".zshenv": .bash,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "brewfile": .ruby,
    ]
}
