import Foundation

/// Turns whatever a person typed into the address bar into a `URL`.
///
/// The rules, in order:
/// 1. Blank input resolves to nothing.
/// 2. Input that already carries a scheme (`https://…`, `about:blank`) is used verbatim.
/// 3. Input that *looks like a host* (`example.com`, `localhost:4321`, `127.0.0.1/x`)
///    gets a scheme prepended — `http://` for loopback/IP literals, `https://` otherwise.
/// 4. Anything else is a search query, folded into `searchTemplate` where `%s` marks
///    the spot the percent-encoded query goes.
///
/// Pure and window-free on purpose: this is the one browser rule worth asserting in
/// `TenonCoreTests`.
public enum BrowserAddress {
    public static func resolve(_ rawInput: String, searchTemplate: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if hasExplicitScheme(input) {
            return URL(string: input)
        }

        if !input.contains(" "), let host = hostPart(of: input) {
            let scheme = prefersInsecure(host) ? "http://" : "https://"
            return URL(string: scheme + input)
        }

        return searchURL(for: input, template: searchTemplate)
    }

    // MARK: - Scheme

    private static func hasExplicitScheme(_ input: String) -> Bool {
        if input.contains("://") {
            let scheme = input.prefix { $0 != ":" }
            return isSchemeToken(scheme)
        }
        for prefix in ["about:", "mailto:", "tel:", "data:"] where input.hasPrefix(prefix) {
            return true
        }
        return false
    }

    private static func isSchemeToken<S: StringProtocol>(_ token: S) -> Bool {
        guard let first = token.first, first.isLetter else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
    }

    // MARK: - Host detection

    /// The host label of a host-like input (`sub.example.com:9000/p` → `sub.example.com`),
    /// or `nil` when the input does not read as a host.
    private static func hostPart(of input: String) -> String? {
        let beforePath = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? input
        let host = beforePath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? beforePath
        guard !host.isEmpty else { return nil }

        if host == "localhost" || isIPv4(host) {
            return host
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count >= 2,
           labels.allSatisfy({ !$0.isEmpty }),
           let tld = labels.last,
           tld.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return host
        }

        return nil
    }

    private static func prefersInsecure(_ host: String) -> Bool {
        host == "localhost" || isIPv4(host)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.allSatisfy(\.isNumber), let value = Int(octet) else { return false }
            return value >= 0 && value <= 255
        }
    }

    // MARK: - Search

    private static func searchURL(for query: String, template: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
