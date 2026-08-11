import Foundation
import XCTest

/// The scripts are a product surface, so they get the same fitness treatment the source does.
/// Three rules, all readable off the tree with no window and no build:
///
/// 1. One door. The root holds exactly one executable and it is the dispatcher; everything a
///    person types is a `scripts/<verb>.sh` that introduces itself to that dispatcher.
/// 2. One road out. Exactly one file in the repository creates a GitHub release.
/// 3. No document, comment or workflow names a script path that no longer exists — the failure
///    mode a rename produces is silent until someone types the command or CI runs the step.
final class ScriptSurfaceFitnessTests: XCTestCase {
    func testTheRepositoryRootHoldsOneExecutableAndItIsTheDispatcher() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        )
        let executables = try contents
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
                return values.isRegularFile == true && values.isExecutable == true
            }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            executables,
            ["tenon"],
            """
            The root is the one place a person looks for something to run, so exactly one thing \
            there may be runnable. Found: \(executables.isEmpty ? "nothing" : executables.joined(separator: ", ")).
            """
        )
    }

    func testEveryTypedVerbIntroducesItselfToTheDispatcher() throws {
        let scripts = try FileManager.default
            .contentsOfDirectory(at: scriptsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sh" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(scripts.isEmpty, "scripts/ holds no verbs at all")

        let groups: Set<String> = ["everyday", "release", "upkeep"]
        for script in scripts {
            let verb = script.deletingPathExtension().lastPathComponent
            let body = try String(contentsOf: script, encoding: .utf8)
            let description = metadata(body, "tenon")
            let group = metadata(body, "tenon-group")

            XCTAssertFalse(
                description.isEmpty,
                """
                scripts/\(verb).sh has no `# tenon:` line, so `./tenon` lists the verb with an \
                empty description. The dispatcher reads its list out of the scripts precisely so \
                a verb cannot be described in two places and disagree with itself.
                """
            )
            XCTAssertTrue(
                groups.contains(group),
                """
                scripts/\(verb).sh declares group "\(group)", which `./tenon` does not print as a \
                heading, so the verb falls through to "other". Expected one of: \
                \(groups.sorted().joined(separator: ", ")).
                """
            )
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: script.path),
                "scripts/\(verb).sh is not executable, so `./tenon \(verb)` reports no such verb"
            )
        }
    }

    func testExactlyOneRoadCreatesAGitHubRelease() throws {
        var creators: [String] = []
        for file in try automationFiles() {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard body.contains("gh release create") else { continue }
            creators.append(relativePath(file))
        }

        XCTAssertEqual(
            creators.sorted(),
            ["scripts/publish.sh"],
            """
            Two roads publishing one tag is invariant 6 at the script layer: whichever runs \
            second fails on the release the first already made. Found: \
            \(creators.sorted().joined(separator: ", ")).
            """
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: packageRoot.appendingPathComponent(".github/workflows/release.yml").path
            ),
            "release.yml is the deleted road; a shim or dry-run remnant is still a second road"
        )
    }

    func testOperatorDocumentsAndWorkflowsNameOnlyScriptsThatExist() throws {
        var stale: [String] = []
        for file in try operatorFacingFiles() {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for named in scriptPaths(in: body) where !namesSomethingReal(named) {
                stale.append("\(relativePath(file)) names \(named)")
            }
        }

        XCTAssertEqual(
            stale.sorted(),
            [],
            """
            A moved script leaves no compile error behind: the reader finds out by typing the \
            command, and CI finds out by failing the step. Stale references:
            \(stale.sorted().joined(separator: "\n"))
            """
        )
    }
}

private extension ScriptSurfaceFitnessTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var scriptsRoot: URL {
        packageRoot.appendingPathComponent("scripts", isDirectory: true)
    }

    func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
    }

    func metadata(_ body: String, _ key: String) -> String {
        let marker = "# \(key): "
        for line in body.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// Everything that can name a script and be believed: the workflows that run them and the
    /// scripts that call each other.
    func automationFiles() throws -> [URL] {
        var files = try shellFiles()
        let workflows = packageRoot.appendingPathComponent(".github/workflows", isDirectory: true)
        if let found = try? FileManager.default.contentsOfDirectory(
            at: workflows,
            includingPropertiesForKeys: nil
        ) {
            files.append(contentsOf: found.filter { $0.pathExtension == "yml" })
        }
        return files
    }

    func shellFiles() throws -> [URL] {
        let roots = [scriptsRoot, scriptsRoot.appendingPathComponent("internal", isDirectory: true)]
        return try roots.flatMap { root -> [URL] in
            try FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { ["sh", "swift", "terminfo"].contains($0.pathExtension) }
        }
    }

    /// The documents an operator reads before typing something, plus the dispatcher and the
    /// scripts' own comments. Dated evidence under `docs/reports/` is deliberately excluded:
    /// it records what was true on its date and is never edited to stay current.
    func operatorFacingFiles() throws -> [URL] {
        let named = [
            "README.md",
            "CLAUDE.md",
            "CHANGELOG.md",
            "project.yml",
            "Package.swift",
            "tenon",
            "docs/development.md",
            "docs/operations.md",
            "docs/releasing.md",
        ].map { packageRoot.appendingPathComponent($0) }
        return try named + automationFiles()
    }

    /// A path is only a claim about the tree when something marks it as one. Two things do:
    /// an anchor — `./something.sh`, or a path under `scripts/` — and backticks, which in these
    /// documents mean "this exact file". A bare unquoted word ending in `.sh` is usually a shell
    /// variable, and stays out.
    ///
    /// The backtick half is not decoration. It is the hole the first version of this gate left:
    /// `docs/operations.md` told the operator to fetch Ghostty "through `setup-ghosttykit.sh`"
    /// for a day after that script was renamed, and the anchored pattern could not see it.
    func scriptPaths(in body: String) -> Set<String> {
        let patterns = [
            "(\\./|scripts/)[A-Za-z0-9_./-]*\\.(sh|swift|terminfo)",
            // Unanchored, so it stays off `.swift`: a backticked bare `PluginHost.swift` is a
            // source file being discussed, while a backticked bare `install.sh` is a thing to run.
            "`[A-Za-z0-9_-]+\\.(sh|terminfo)`",
        ]
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var found: Set<String> = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: body, range: range) {
                guard let matched = Range(match.range, in: body) else { continue }
                var path = String(body[matched])
                path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if path.hasPrefix("./") { path.removeFirst(2) }
                found.insert(path)
            }
        }
        return found
    }

    /// A name with no slash names a file, not a location: `install.sh` is the one in `scripts/`.
    /// Resolve it the way a reader would before calling it stale.
    func namesSomethingReal(_ named: String) -> Bool {
        let candidates: [URL] = named.contains("/")
            ? [packageRoot.appendingPathComponent(named)]
            : [
                packageRoot.appendingPathComponent(named),
                scriptsRoot.appendingPathComponent(named),
                scriptsRoot.appendingPathComponent("internal").appendingPathComponent(named),
            ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
