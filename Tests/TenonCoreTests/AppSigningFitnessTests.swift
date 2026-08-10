import Foundation
import XCTest

/// T-114: the app's code-signing posture, asserted where it can turn red in a second.
///
/// Hardened Runtime is what a Developer ID release requires, and it is a flag the kernel
/// enforces no matter who signed the binary. That makes it testable here, long before a
/// certificate is involved: what the build declares is a file in the tree, and a widening
/// of the entitlement set is exactly the change nobody notices in review.
///
/// The entitlements themselves form a widening cascade — `allow-jit` permits `MAP_JIT`
/// pages and nothing else, `allow-unsigned-executable-memory` drops the restriction on
/// arbitrary RWX, and `disable-executable-page-protection` removes the protection outright.
/// `docs/research-plugin-runtimes.md:994` records that exactly one of them may be set, and
/// JavaScriptCore only ever needs the narrowest. Two others — `disable-library-validation`
/// and `allow-dyld-environment-variables` — are the classic dylib-injection vectors and are
/// unrelated to anything Tenon does: plugins are JavaScript, not Mach-O.
final class AppSigningFitnessTests: XCTestCase {
    /// The one entitlement JavaScriptCore needs under Hardened Runtime.
    private static let requiredEntitlements = ["com.apple.security.cs.allow-jit"]

    /// Entitlements that would widen the runtime past what any Tenon code path uses.
    /// `get-task-allow` is separate from the cascade and belongs here for its own reason:
    /// it permits a debugger to attach, and notarization refuses a build that carries it.
    private static let forbiddenEntitlements = [
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.get-task-allow",
    ]

    func testEntitlementsFileIsAReadablePropertyList() throws {
        let entitlements = try loadEntitlements()
        XCTAssertFalse(
            entitlements.isEmpty,
            "Tenon.entitlements parsed but declares nothing; the build would harden the "
                + "runtime and grant no exception, so JavaScriptCore loses JIT."
        )
    }

    func testEntitlementsGrantJavaScriptCoreTheNarrowestJITException() throws {
        let entitlements = try loadEntitlements()
        for key in Self.requiredEntitlements {
            XCTAssertEqual(
                entitlements[key] as? Bool,
                true,
                "\(key) must be granted: PluginRuntime evaluates plugin JavaScript in "
                    + "JavaScriptCore, which cannot map JIT pages under Hardened Runtime "
                    + "without it."
            )
        }
    }

    func testEntitlementsGrantNothingWiderThanJIT() throws {
        let entitlements = try loadEntitlements()
        for key in Self.forbiddenEntitlements {
            XCTAssertNil(
                entitlements[key],
                "\(key) widens the runtime past anything Tenon needs. If a real failure "
                    + "seems to require it, the cause is worth finding first — plugins are "
                    + "JavaScript and the only embedded binary is a static archive."
            )
        }
    }

    func testReleaseBuildsHardenTheRuntimeAndCarryTheEntitlements() throws {
        let settings = try appTargetSettings()
        XCTAssertTrue(
            settings.contains("CODE_SIGN_ENTITLEMENTS: Tenon.entitlements"),
            "Hardened Runtime without the entitlements file is the same build with JIT "
                + "silently removed, so the app target carries the file unconditionally."
        )

        guard let release = settings.range(of: "\n        Release:\n") else {
            return XCTFail(
                "The Tenon app target declares no Release configuration block, so nothing "
                    + "states what the distributed artifact is built with."
            )
        }
        XCTAssertTrue(
            settings[release.upperBound...].contains("ENABLE_HARDENED_RUNTIME: YES"),
            "Release must harden the runtime: notarization requires it, and a flag added "
                + "at signing time would first be exercised by the one build nobody "
                + "iterates on. Debug stays unhardened so XCUITest and concurrent agents "
                + "keep the attach behaviour they have today."
        )
    }
}

private extension AppSigningFitnessTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func loadEntitlements() throws -> [String: Any] {
        let url = packageRoot.appendingPathComponent("Tenon.entitlements")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SigningFitnessFailure.missingEntitlements(url.path)
        }
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let entitlements = parsed as? [String: Any] else {
            throw SigningFitnessFailure.malformedEntitlements(url.path)
        }
        return entitlements
    }

    /// The `Tenon:` application target's own settings block, isolated so a setting that
    /// belongs to a test bundle cannot satisfy an assertion about the app.
    func appTargetSettings() throws -> String {
        let url = packageRoot.appendingPathComponent("project.yml")
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let start = contents.range(of: "\n  Tenon:\n") else {
            throw SigningFitnessFailure.missingAppTarget
        }
        let rest = contents[start.upperBound...]
        guard let end = rest.range(of: "\n  TenonCoreTests:\n") else {
            throw SigningFitnessFailure.missingAppTarget
        }
        return String(rest[..<end.lowerBound])
    }
}

private enum SigningFitnessFailure: Error, CustomStringConvertible {
    case missingEntitlements(String)
    case malformedEntitlements(String)
    case missingAppTarget

    var description: String {
        switch self {
        case let .missingEntitlements(path):
            return "no entitlements file at \(path)"
        case let .malformedEntitlements(path):
            return "\(path) is not a property list dictionary"
        case .missingAppTarget:
            return "project.yml has no `Tenon:` application target block"
        }
    }
}
