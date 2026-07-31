import TenonIntentCore

/// What one launcher choice leaves behind, decided from the dispatch result alone.
///
/// Every surface that presents the launcher catalog — the tab strip's `+` popover and a
/// tab chip's right-click popover — settles a chosen row through this value, so no
/// surface can record a habit for a command that never ran, and no surface can swallow
/// a failure the human should have seen.
enum LauncherOutcome: Equatable {
    /// The intent ran: the pick becomes frecency and the launcher closes.
    case ran
    /// The intent vanished between ranking and the click (its plugin unloaded).
    case unavailable
    /// The provider answered with an error, reported in place; the launcher stays open.
    case failed(code: String)

    init(_ result: IntentResult?) {
        switch result {
        case nil:
            self = .unavailable
        case .success:
            self = .ran
        case .failure(let failure):
            self = .failed(code: failure.error.code.rawValue)
        }
    }

    /// Only a run that succeeded may teach the ranking.
    var recordsFrecency: Bool { self == .ran }

    /// The launcher closes only behind a success; anything else stays visible where the
    /// click happened.
    var dismisses: Bool { self == .ran }

    var errorMessage: String? {
        switch self {
        case .ran: nil
        case .unavailable: "Intent is no longer available."
        case .failed(let code): code
        }
    }
}
