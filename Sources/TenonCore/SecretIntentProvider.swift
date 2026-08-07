// @domain: intent-bus
import Foundation
import TenonIntentCore

/// Keychain-backed bindings for the caller's immutable plugin-installation namespace.
///
/// The namespace is derived only from the host-minted principal. Neither the intent input nor
/// a mutable plugin display/directory name can select another installation's secrets.
public struct SecretIntentProvider: Sendable {
    public let bindings: [IntentProviderBinding]

    public init(store: SecretStore) throws {
        let failureCode = IntentErrorCode.domain(
            try IntentDomainErrorCode("dev.tenon.core.secret-store-failed")
        )
        bindings = [
            IntentProviderBinding(
                intentID: try CoreIntentName.secretsGet.intentID
            ) { envelope, context in
                do {
                    try context.checkCancellation()
                    let object = try CoreIntentProviderSupport.object(
                        envelope.input
                    )
                    let key = try CoreIntentProviderSupport.string(
                        "key",
                        in: object
                    )
                    let installation = try Self.installation(
                        for: envelope.caller
                    )
                    let value = try await store.value(
                        forKey: key,
                        installation: installation
                    )
                    try context.checkCancellation()
                    return .success(
                        .object([
                            "value": value.map(IntentValue.string) ?? .null
                        ])
                    )
                } catch let error as CoreIntentProviderInputError {
                    return CoreIntentProviderSupport.invalidInputFailure(error)
                } catch is CancellationError {
                    throw CancellationError()
                } catch PrincipalError.invalidPluginPrincipal {
                    return Self.denied()
                } catch {
                    return Self.storeFailure(code: failureCode)
                }
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.secretsSet.intentID
            ) { envelope, context in
                do {
                    try context.checkCancellation()
                    let object = try CoreIntentProviderSupport.object(
                        envelope.input
                    )
                    let key = try CoreIntentProviderSupport.string(
                        "key",
                        in: object
                    )
                    let value = try CoreIntentProviderSupport.string(
                        "value",
                        in: object
                    )
                    let installation = try Self.installation(
                        for: envelope.caller
                    )
                    try await store.setValue(
                        value,
                        forKey: key,
                        installation: installation
                    )
                    try context.checkCancellation()
                    return .success(.object([:]))
                } catch let error as CoreIntentProviderInputError {
                    return CoreIntentProviderSupport.invalidInputFailure(error)
                } catch is CancellationError {
                    throw CancellationError()
                } catch PrincipalError.invalidPluginPrincipal {
                    return Self.denied()
                } catch {
                    return Self.storeFailure(code: failureCode)
                }
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.secretsDelete.intentID
            ) { envelope, context in
                do {
                    try context.checkCancellation()
                    let object = try CoreIntentProviderSupport.object(
                        envelope.input
                    )
                    let key = try CoreIntentProviderSupport.string(
                        "key",
                        in: object
                    )
                    let installation = try Self.installation(
                        for: envelope.caller
                    )
                    _ = try await store.removeValue(
                        forKey: key,
                        installation: installation
                    )
                    try context.checkCancellation()
                    return .success(.object([:]))
                } catch let error as CoreIntentProviderInputError {
                    return CoreIntentProviderSupport.invalidInputFailure(error)
                } catch is CancellationError {
                    throw CancellationError()
                } catch PrincipalError.invalidPluginPrincipal {
                    return Self.denied()
                } catch {
                    return Self.storeFailure(code: failureCode)
                }
            },
        ]
    }
}

private extension SecretIntentProvider {
    enum PrincipalError: Error, Sendable {
        case invalidPluginPrincipal
    }

    static func installation(
        for principal: IntentPrincipal
    ) throws -> PluginInstallationKey {
        let prefix = "plugin:"
        guard principal.kind == .plugin,
              principal.audience == .plugin,
              principal.id.hasPrefix(prefix)
        else {
            throw PrincipalError.invalidPluginPrincipal
        }

        let identity = principal.id.dropFirst(prefix.count)
        guard let separator = identity.lastIndex(of: ":"),
              separator != identity.startIndex,
              identity.index(after: separator) != identity.endIndex,
              let installationID = UUID(
                  uuidString: String(identity[identity.index(after: separator)...])
              ),
              let pluginID = try? PluginID(String(identity[..<separator]))
        else {
            throw PrincipalError.invalidPluginPrincipal
        }

        return PluginInstallationKey(
            pluginID: pluginID,
            installationID: installationID
        )
    }

    static func denied() -> IntentProviderReply {
        .failure(
            IntentProviderFailure(
                code: .kernel(.denied),
                details: .object([
                    "reason": .string("plugin-installation-principal-required")
                ])
            )
        )
    }

    static func storeFailure(code: IntentErrorCode) -> IntentProviderReply {
        CoreIntentProviderSupport.failure(
            code: code,
            reason: "secret-store-operation-failed"
        )
    }
}
