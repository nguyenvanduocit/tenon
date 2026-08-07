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
    /// Files under `Sources/` that predate the tag layer. This number may only go **down**.
    ///
    /// It is a ratchet, not a target: a new untagged file turns this red, and the fix is one
    /// line at the top of that file. Lower it whenever you tag a batch.
    private static let untaggedFileBudget = 146

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
            .deletingLastPathComponent()
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

    static func isSlug(_ candidate: String) -> Bool {
        guard let first = candidate.first, first.isLowercase else {
            return false
        }
        return candidate.allSatisfy {
            $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-"
        }
    }
}
