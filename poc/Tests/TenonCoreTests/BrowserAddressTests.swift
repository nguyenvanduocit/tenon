import XCTest

@testable import TenonCore

final class BrowserAddressTests: XCTestCase {
    private let search = "https://duckduckgo.com/?q=%s"

    // MARK: - Bare hosts get a scheme

    func testBareDomainBecomesHTTPS() {
        XCTAssertEqual(
            BrowserAddress.resolve("example.com", searchTemplate: search),
            URL(string: "https://example.com")
        )
    }

    func testSubdomainWithPathBecomesHTTPS() {
        XCTAssertEqual(
            BrowserAddress.resolve("sub.example.com/a/b", searchTemplate: search),
            URL(string: "https://sub.example.com/a/b")
        )
    }

    func testDomainWithPortAndQueryKeepsThemUnderHTTPS() {
        XCTAssertEqual(
            BrowserAddress.resolve("sub.example.com:9000/p?q=1", searchTemplate: search),
            URL(string: "https://sub.example.com:9000/p?q=1")
        )
    }

    // MARK: - localhost / IP prefer http

    func testLocalhostWithPortBecomesHTTP() {
        XCTAssertEqual(
            BrowserAddress.resolve("localhost:4321", searchTemplate: search),
            URL(string: "http://localhost:4321")
        )
    }

    func testBareLocalhostBecomesHTTP() {
        XCTAssertEqual(
            BrowserAddress.resolve("localhost", searchTemplate: search),
            URL(string: "http://localhost")
        )
    }

    func testIPv4WithPortAndPathBecomesHTTP() {
        XCTAssertEqual(
            BrowserAddress.resolve("127.0.0.1:8080/path", searchTemplate: search),
            URL(string: "http://127.0.0.1:8080/path")
        )
    }

    // MARK: - Explicit schemes pass through untouched

    func testHTTPSIsLeftAsIs() {
        XCTAssertEqual(
            BrowserAddress.resolve("https://example.com/x", searchTemplate: search),
            URL(string: "https://example.com/x")
        )
    }

    func testExplicitSchemeWinsOverDotlessHost() {
        XCTAssertEqual(
            BrowserAddress.resolve("http://foo", searchTemplate: search),
            URL(string: "http://foo")
        )
    }

    func testAboutBlankPassesThrough() {
        XCTAssertEqual(
            BrowserAddress.resolve("about:blank", searchTemplate: search),
            URL(string: "about:blank")
        )
    }

    // MARK: - Whitespace is trimmed

    func testLeadingAndTrailingWhitespaceTrimmed() {
        XCTAssertEqual(
            BrowserAddress.resolve("  github.com/a/b  ", searchTemplate: search),
            URL(string: "https://github.com/a/b")
        )
    }

    // MARK: - Non-URL input becomes a search

    func testMultiWordInputBecomesSearch() {
        XCTAssertEqual(
            BrowserAddress.resolve("hello world", searchTemplate: search),
            URL(string: "https://duckduckgo.com/?q=hello%20world")
        )
    }

    func testSingleDotlessWordBecomesSearch() {
        XCTAssertEqual(
            BrowserAddress.resolve("swift", searchTemplate: search),
            URL(string: "https://duckduckgo.com/?q=swift")
        )
    }

    func testTextContainingDotButWithSpaceBecomesSearch() {
        XCTAssertEqual(
            BrowserAddress.resolve("buy example.com domain", searchTemplate: search),
            URL(string: "https://duckduckgo.com/?q=buy%20example.com%20domain")
        )
    }

    // MARK: - Empty input resolves to nothing

    func testEmptyInputIsNil() {
        XCTAssertNil(BrowserAddress.resolve("", searchTemplate: search))
    }

    func testWhitespaceOnlyInputIsNil() {
        XCTAssertNil(BrowserAddress.resolve("   ", searchTemplate: search))
    }
}
