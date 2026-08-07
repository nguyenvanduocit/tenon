@testable import TenonCore
import XCTest

/// T-047: finding the manifest inside a single-file plugin.
///
/// This type only locates the JSON — validating it stays with `PluginManifest`, so a
/// single-file plugin and a directory plugin are held to the same rules by the same
/// decoder. These tests therefore pin *where a header is and is not*, which is the only
/// question this type answers.
final class PluginManifestHeaderTests: XCTestCase {
    func testAHeaderAtTheTopOfTheFileIsFound() throws {
        let source = """
        /* tenon-manifest
        { "id": "dev.tenon.example", "name": "example", "version": "1" }
        */
        tenon.statusBar.set("hello");
        """

        let json = try XCTUnwrap(try PluginManifestHeader.json(in: source))
        XCTAssertEqual(
            json,
            #"{ "id": "dev.tenon.example", "name": "example", "version": "1" }"#
        )
    }

    func testLeadingBlankLinesAreAllowed() throws {
        let source = "\n\n   /* tenon-manifest\n{\"id\":\"a.b\"}\n*/\nvar x = 1;"
        XCTAssertEqual(try PluginManifestHeader.json(in: source), "{\"id\":\"a.b\"}")
    }

    /// The header must open the file. Anything above it could run before the plugin has
    /// declared what it is allowed to do — and a file with two headers has no answer to
    /// "which one is the declaration".
    func testAHeaderThatDoesNotStartTheFileIsNotAHeader() throws {
        let source = """
        var sneaky = 1;
        /* tenon-manifest
        { "id": "dev.tenon.example" }
        */
        """

        XCTAssertNil(try PluginManifestHeader.json(in: source))
        XCTAssertFalse(PluginManifestHeader.hasHeader(source))
    }

    /// An ordinary script in the plugins root is not a broken plugin. It never claimed to
    /// be one, so discovery skips it rather than failing a reload over it.
    func testAPlainScriptHasNoHeaderAndIsNotAnError() throws {
        let source = "// just a script\nconsole.log(1);"
        XCTAssertNil(try PluginManifestHeader.json(in: source))
        XCTAssertFalse(PluginManifestHeader.hasHeader(source))
    }

    /// A file that *did* claim to be a plugin and got it wrong must fail loudly — the
    /// difference between this and the case above is the whole point of `hasHeader`.
    func testAClaimedHeaderThatIsBrokenThrows() {
        XCTAssertThrowsError(
            try PluginManifestHeader.json(in: "/* tenon-manifest\n{\"id\":\"a.b\"}")
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestHeaderError,
                .unterminatedHeader
            )
        }
        XCTAssertThrowsError(
            try PluginManifestHeader.json(in: "/* tenon-manifest\n   \n*/\n")
        ) { error in
            XCTAssertEqual(error as? PluginManifestHeaderError, .emptyHeader)
        }
    }

    func testTheHeaderIsBounded() {
        let huge = String(
            repeating: "x",
            count: PluginManifestHeader.maximumHeaderBytes + 1
        )
        XCTAssertThrowsError(
            try PluginManifestHeader.json(in: "/* tenon-manifest\n\(huge)\n*/")
        ) { error in
            guard case .headerTooLarge = error as? PluginManifestHeaderError else {
                return XCTFail("expected headerTooLarge, got \(error)")
            }
        }
    }

    /// Every failure names what to do about it — a plugin author reading a diagnostic
    /// should not have to read this file to act on it.
    func testEveryFailureCarriesASuggestion() {
        for error: PluginManifestHeaderError in [
            .unterminatedHeader,
            .emptyHeader,
            .headerTooLarge(bytes: 1),
        ] {
            XCTAssertFalse(error.suggestion.isEmpty, "\(error)")
        }
    }
}
