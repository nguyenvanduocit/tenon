// @domain: agent-lens
import Foundation

/// Whether each provider's Tenon hook is actually installed, and how to try again.
///
/// The install runs at launch, against a file the user owns and other tools also write. It
/// can fail for ordinary reasons — a settings file being rewritten at that moment, a lock
/// held, hand-edited JSON. Without this, that failure is silent and the Session view simply
/// stays empty while work happens, which reads as Tenon being broken rather than as one
/// step not having run.
@MainActor
@Observable
final class AgentHookInstallStatus {
    static let shared = AgentHookInstallStatus()

    private(set) var results: [AgentProvider: AgentHookInstallResult] = [:]
    @ObservationIgnored
    private var installers: [AgentProvider: @MainActor () -> AgentHookInstallResult] = [:]

    /// The composition root owns the paths; this type owns only "did it work, and repeat it".
    func register(
        provider: AgentProvider,
        result: AgentHookInstallResult,
        install: @escaping @MainActor () -> AgentHookInstallResult
    ) {
        installers[provider] = install
        results[provider] = result
    }

    @discardableResult
    func retry(provider: AgentProvider) -> AgentHookInstallResult? {
        guard let install = installers[provider] else { return nil }
        let result = install()
        results[provider] = result
        return result
    }

    func failureReason(for provider: AgentProvider?) -> String? {
        guard let provider, case let .unavailable(reason) = results[provider] else { return nil }
        return reason
    }

    func canRetry(_ provider: AgentProvider?) -> Bool {
        guard let provider else { return false }
        return installers[provider] != nil
    }
}
