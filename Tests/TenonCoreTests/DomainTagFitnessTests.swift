import Foundation
import XCTest

/// Keeps the `@domain:` product-ontology layer honest.
///
/// The layer is written by hand because nothing derives it: a call graph says who calls whom,
/// and `rg '^import ' Sources/TenonCore` proves Swift exposes no intra-module edge at all, but
/// neither says which product concern a file serves. Hand-written metadata rots — measured at
/// ~89% in this repo's own `.kanban` ownership blocks, with the obligation stated plainly in
/// CLAUDE.md the whole time. So the vocabulary ships with these assertions or it lies.
///
/// What this cannot check, and no check can: that a file tagged `plugin-host` should *also*
/// carry `plugin-events`. That omission is the original failure tagging exists to reduce, so
/// `docs/domains.md` keeps the symbol-traversal step mandatory rather than selling past it.
final class DomainTagFitnessTests: XCTestCase {
    /// Files under `Sources/` that carry no tag. It is **zero**, and may only stay there.
    ///
    /// The ratchet reached its end: every source file names the product concern it serves, so
    /// an untagged file is now simply a missing line rather than a debt being paid down.
    private static let untaggedFileBudget = 0

    func testEveryUsedDomainIsDeclaredInTheVocabulary() throws {
        let declared = try declaredDomains()
        XCTAssertFalse(declared.isEmpty, "docs/domains.md declares no domains")

        var undeclared: [String] = []
        for file in try sourceFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for domain in Self.domains(inTagLinesOf: contents) where !declared.contains(domain) {
                undeclared.append("\(file.lastPathComponent): \(domain)")
            }
        }

        XCTAssertEqual(
            undeclared.sorted(), [],
            """
            These @domain: tags name a domain that docs/domains.md does not declare. Add the \
            domain there (with its Excludes line), or use an existing one — an uncontrolled \
            vocabulary fragments into #login/#auth/#signin within weeks.
            """
        )
    }

    func testEveryDeclaredDomainIsUsedBySomeFile() throws {
        var unused = try declaredDomains()
        for file in try sourceFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            unused.subtract(Self.domains(inTagLinesOf: contents))
        }

        XCTAssertEqual(
            unused.sorted(), [],
            """
            docs/domains.md declares these domains but no file carries them. A dead entry is \
            how a controlled vocabulary stops being controlled: remove it, or tag the files \
            it was written for.
            """
        )
    }

    func testLongTaggedFilesTagEveryMarkSection() throws {
        var untaggedMarks: [String] = []
        for file in try sourceFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            guard lines.count > 400, Self.fileTagLine(in: lines) != nil else {
                continue
            }
            for (offset, line) in lines.enumerated()
                where line.contains("// MARK:") && !line.contains("@domain:")
            {
                untaggedMarks.append("\(file.lastPathComponent):\(offset + 1)")
            }
        }

        XCTAssertEqual(
            untaggedMarks.sorted(), [],
            """
            A tagged file over 400 lines spans more than one concern, so its file tag alone \
            cannot locate anything. Every // MARK: in it carries its own @domain:. MARK is \
            the unit precisely because it is enumerable — "a block" is not checkable.
            """
        )
    }

    func testUntaggedFileCountDoesNotGrow() throws {
        let untagged = try sourceFiles().filter { file in
            let lines = try? String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
            return Self.fileTagLine(in: lines ?? []) == nil
        }

        XCTAssertLessThanOrEqual(
            untagged.count, Self.untaggedFileBudget,
            """
            \(untagged.count) source files carry no @domain: tag, over the budget of \
            \(Self.untaggedFileBudget). Add `// @domain: <domain>` above the imports of the \
            new file — see docs/domains.md — then lower untaggedFileBudget to match. \
            Untagged now: \(untagged.map(\.lastPathComponent).sorted().prefix(8).joined(separator: ", "))…
            """
        )
    }

    /// Files whose tag names a concern nothing around them shares. Ratchets to zero.
    ///
    /// Every other assertion here checks a tag's *shape*; none opens the file, which is how
    /// three false tags stayed green until a person read `docs/domains.md` against them
    /// (T-106). This one reads the code: a file is isolated when its own domain appears in
    /// no file it references **and** no file that references it.
    ///
    /// Two-way is what makes it usable at all — the one-way version flags 16 files, mostly
    /// composition roots whose neighbours are legitimately everywhere.
    ///
    /// Be clear about its reach: of the three false tags T-106 found by hand, this catches
    /// **one** (`AppStatePaths.swift` claiming `diagnostics`). `EmptyStateCard` was tagged
    /// `agent-lens` while sharing code with an `agent-lens` file, and no structural check
    /// can see that the *concern* was wrong. It is a floor under the obvious cases, not a
    /// substitute for reading the file against the vocabulary. Several entries in today's
    /// budget are leaf utilities that genuinely touch nothing in their own domain, and one
    /// — `EmptyStateCard` — is isolated because it is a second launcher implementation
    /// sharing no code with `LauncherMenu`, which is a finding about the code, not the tag.
    private static let isolatedTagBudget = 8

    /// Long files the MARK rule cannot see. Ratchets to zero.
    ///
    /// `testLongTaggedFilesTagEveryMarkSection` can only constrain a file that HAS MARK
    /// sections, and these declare none — so it passes over them without reading anything.
    /// They are the longest files in the tree, which is exactly where one file-level tag
    /// locates the least.
    private static let unsectionedLongFileBudget = 49

    func testNoTagIsIsolatedFromTheCodeAroundIt() throws {
        var contents: [URL: String] = [:]
        for file in try sourceFiles() {
            contents[file] = try String(contentsOf: file, encoding: .utf8)
        }

        var tags: [URL: Set<String>] = [:]
        var owner: [String: URL] = [:]
        var words: [URL: [String]] = [:]
        for (file, text) in contents {
            let lines = text.components(separatedBy: .newlines)
            guard let tagLine = Self.fileTagLine(in: lines) else { continue }
            tags[file] = Self.domains(inTagLinesOf: tagLine)
            words[file] = Self.words(in: text)
            for name in Self.declaredTypeNames(in: text) where owner[name] == nil {
                owner[name] = file
            }
        }

        var neighbours: [URL: Set<URL>] = [:]
        for (file, tokens) in words {
            for name in Set(tokens) {
                guard let other = owner[name], other != file else {
                    continue
                }
                neighbours[file, default: []].insert(other)
                neighbours[other, default: []].insert(file)
            }
        }

        var population: [String: Int] = [:]
        for domains in tags.values {
            for domain in domains {
                population[domain, default: 0] += 1
            }
        }

        var isolated: [String] = []
        for (file, mine) in tags {
            // A domain covering one file cannot have a same-domain neighbour, so its
            // isolation is arithmetic rather than evidence about the tag.
            if mine.allSatisfy({ (population[$0] ?? 0) < 2 }) {
                continue
            }
            let around = neighbours[file] ?? []
            guard !around.isEmpty else {
                continue
            }
            if around.contains(where: { !(tags[$0] ?? []).isDisjoint(with: mine) }) {
                continue
            }
            isolated.append("\(file.lastPathComponent): \(mine.sorted().joined(separator: ", "))")
        }

        XCTAssertLessThanOrEqual(
            isolated.count, Self.isolatedTagBudget,
            """
            \(isolated.count) files carry a domain that appears in nothing they reference and \
            nothing referencing them, over the budget of \(Self.isolatedTagBudget). Either the \
            tag names the wrong concern — read the file against docs/domains.md — or the file \
            genuinely shares no code with its own domain, which is a finding about the code. \
            Isolated now: \(isolated.sorted().joined(separator: "; "))
            """
        )
    }

    func testLongFilesDeclareTheSectionsTheMarkRuleReads() throws {
        let unsectioned = try sourceFiles().filter { file in
            guard let lines = try? String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines), lines.count > 400 else {
                return false
            }
            return !lines.contains { $0.contains("// MARK:") }
        }

        XCTAssertLessThanOrEqual(
            unsectioned.count, Self.unsectionedLongFileBudget,
            """
            \(unsectioned.count) files over 400 lines declare no // MARK: at all, over the \
            budget of \(Self.unsectionedLongFileBudget). The MARK rule passes over them \
            without checking anything, so one file tag stands for the whole file and locates \
            nothing inside it. Give the new one sections, or split it. \
            Unsectioned now: \(unsectioned.map(\.lastPathComponent).sorted().prefix(8).joined(separator: ", "))…
            """
        )
    }

    func testTagsAreWellFormedSlugs() throws {
        var malformed: [String] = []
        for file in try sourceFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for domain in Self.domains(inTagLinesOf: contents) where !Self.isSlug(domain) {
                malformed.append("\(file.lastPathComponent): '\(domain)'")
            }
        }

        XCTAssertEqual(
            malformed.sorted(), [],
            "@domain: takes lowercase kebab-case slugs, comma separated"
        )
    }
}

// MARK: - Parsing  @domain: plugin-host

private extension DomainTagFitnessTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var vocabularyFile: URL {
        packageRoot
            .appendingPathComponent("docs/domains.md")
    }

    /// Domains are the `## <slug>` headings; prose headings carry spaces or capitals and are
    /// skipped by the slug shape itself, so the two never need separate markup.
    func declaredDomains() throws -> Set<String> {
        let contents = try String(contentsOf: vocabularyFile, encoding: .utf8)
        var result: Set<String> = []
        for line in contents.components(separatedBy: .newlines) where line.hasPrefix("## ") {
            let candidate = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if Self.isSlug(candidate) {
                result.insert(candidate)
            }
        }
        return result
    }

    /// An empty scan would let four of the five assertions pass on nothing — the vacuous
    /// green this whole layer exists to prevent. A scan that finds no source tree is a
    /// broken test, not a clean repo, so it throws rather than returning `[]`.
    struct SourceScanFoundNothing: Error, CustomStringConvertible {
        let root: URL

        var description: String {
            "no .swift files under \(root.path) — DomainTagFitnessTests cannot see the "
                + "source tree, so every assertion in it would pass without checking anything"
        }
    }

    func sourceFiles() throws -> [URL] {
        let root = packageRoot
            .appendingPathComponent("Sources")
            .resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SourceScanFoundNothing(root: root)
        }

        var result: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(file)
            }
        }
        guard !result.isEmpty else {
            throw SourceScanFoundNothing(root: root)
        }
        return result
    }

    static func fileTagLine(in lines: [String]) -> String? {
        lines.first {
            $0.hasPrefix("// @domain:")
        }
    }

    /// Every domain named on any tag line — the file tag and each tagged MARK alike.
    static func domains(inTagLinesOf contents: String) -> Set<String> {
        var result: Set<String> = []
        for line in contents.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "@domain:") else {
                continue
            }
            let list = line[marker.upperBound...]
            for piece in list.components(separatedBy: ",") {
                let domain = piece.trimmingCharacters(in: .whitespaces)
                if !domain.isEmpty {
                    result.insert(domain)
                }
            }
        }
        return result
    }

    /// Every identifier-shaped run in a file, in source order.
    ///
    /// Scanned over UTF-8 rather than `split(whereSeparator:)`, which pays for grapheme
    /// breaking on every one of the tree's ~2.5 MB and turns a fast assertion into a slow
    /// one. Swift identifiers outside this ASCII set exist and are simply not indexed.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(48)

        func flush() {
            if !current.isEmpty {
                result.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }

        for byte in text.utf8 {
            let isWord = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
            if isWord {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    static let declarationKeywords: Set<String> = [
        "struct", "enum", "class", "actor", "protocol",
    ]

    static let declarationModifiers: Set<String> = [
        "public", "internal", "package", "open", "final", "@MainActor", "@objc",
    ]

    /// The types a file declares at top level, and only those.
    ///
    /// Two exclusions carry the whole check. `extension` is not a declaration: an
    /// `extension Task` in one file would otherwise make every file that writes `Task { }`
    /// its neighbour, which is exactly the false edge that hid `AgentLaunchSuggestions`'
    /// wrong tag from an earlier draft of this assertion. And a nested type is skipped by
    /// requiring column zero, because `enum State` inside a provider is not what that file
    /// is *about* — indexing it makes every mention of `State` anywhere an edge.
    ///
    /// A missed owner only removes neighbours, which can only make the check stricter;
    /// a spurious one only adds them, making it more forgiving. Neither invents a failure.
    static func declaredTypeNames(in text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let first = line.first, !first.isWhitespace else {
                continue
            }
            var words = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "@") })[...]
            while let head = words.first, declarationModifiers.contains(String(head)) {
                words = words.dropFirst()
            }
            guard let keyword = words.first, declarationKeywords.contains(String(keyword)),
                  let name = words.dropFirst().first, name.first?.isUppercase == true else {
                continue
            }
            result.append(String(name))
        }
        return result
    }

    static func isSlug(_ candidate: String) -> Bool {
        guard let first = candidate.first, first.isLowercase else {
            return false
        }
        return candidate.allSatisfy {
            $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-"
        }
    }
}
