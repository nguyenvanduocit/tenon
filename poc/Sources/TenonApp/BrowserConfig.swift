import Foundation
import Observation
import TenonCore

/// User-agent presets the browser can pretend to be.
enum BrowserUserAgent: String, CaseIterable, Identifiable {
    case desktop
    case mobile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .mobile: return "Mobile"
        }
    }

    /// A custom `WKWebView.customUserAgent`, or `nil` to keep the platform default.
    var customUAString: String? {
        switch self {
        case .desktop:
            return nil
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
    }
}

/// The search engines offered for non-URL address-bar input.
struct BrowserSearchEngine: Identifiable, Equatable {
    let id: String
    let label: String
    let template: String

    static let all: [BrowserSearchEngine] = [
        .init(id: "duckduckgo", label: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        .init(id: "google", label: "Google", template: "https://www.google.com/search?q=%s"),
        .init(id: "bing", label: "Bing", template: "https://www.bing.com/search?q=%s"),
    ]
}

/// Global browser configuration, shared by every browser pane and persisted to
/// `UserDefaults`. Scope is deliberately app-wide — the empty shell has one browser
/// identity, not one per pane.
@MainActor
@Observable
final class BrowserConfigStore {
    static let shared = BrowserConfigStore()

    var homeURLString: String { didSet { defaults.set(homeURLString, forKey: Keys.home) } }
    var searchEngineID: String { didSet { defaults.set(searchEngineID, forKey: Keys.search) } }
    var userAgent: BrowserUserAgent { didSet { defaults.set(userAgent.rawValue, forKey: Keys.ua) } }
    var remembersLastURL: Bool { didSet { defaults.set(remembersLastURL, forKey: Keys.remember) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let home = "browser.homeURL"
        static let search = "browser.searchEngine"
        static let ua = "browser.userAgent"
        static let remember = "browser.remembersLastURL"
        static func lastURL(_ slot: UUID) -> String { "browser.lastURL.\(slot.uuidString)" }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        homeURLString = defaults.string(forKey: Keys.home) ?? "https://duckduckgo.com"
        searchEngineID = defaults.string(forKey: Keys.search) ?? BrowserSearchEngine.all[0].id
        userAgent = defaults.string(forKey: Keys.ua).flatMap(BrowserUserAgent.init) ?? .desktop
        remembersLastURL = (defaults.object(forKey: Keys.remember) as? Bool) ?? true
    }

    var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine.all.first { $0.id == searchEngineID } ?? BrowserSearchEngine.all[0]
    }

    var searchTemplate: String { searchEngine.template }

    var homeURL: URL {
        BrowserAddress.resolve(homeURLString, searchTemplate: searchTemplate)
            ?? URL(string: "https://duckduckgo.com")!
    }

    /// The last page a pane was showing, when memory is enabled.
    func lastURL(forSlot slot: UUID) -> URL? {
        guard remembersLastURL,
              let stored = defaults.string(forKey: Keys.lastURL(slot))
        else { return nil }
        return URL(string: stored)
    }

    func rememberURL(_ url: URL, forSlot slot: UUID) {
        guard remembersLastURL else { return }
        defaults.set(url.absoluteString, forKey: Keys.lastURL(slot))
    }
}
