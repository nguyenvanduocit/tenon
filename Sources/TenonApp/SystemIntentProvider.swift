// @domain: intent-bus
import AppKit
import Foundation
import TenonCore
import TenonIntentCore

@MainActor
final class SystemIntentProvider {
    private struct ErrorCodes {
        let pathNotFound: IntentErrorCode
        let externalOpenFailed: IntentErrorCode
        let clipboardUnavailable: IntentErrorCode
        let invalidURL: IntentErrorCode

        init() throws {
            pathNotFound = .domain(
                try IntentDomainErrorCode("dev.tenon.core.path-not-found")
            )
            invalidURL = .domain(
                try IntentDomainErrorCode("dev.tenon.core.invalid-url")
            )
            externalOpenFailed = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.external-open-failed"
                )
            )
            clipboardUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.clipboard-unavailable"
                )
            )
        }
    }

    private let codes: ErrorCodes

    init() throws {
        codes = try ErrorCodes()
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.fileReveal.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.reveal(
                    envelope: envelope,
                    context: context
                )
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.fileOpen.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.open(
                    envelope: envelope,
                    context: context
                )
                try context.checkCancellation()
                return reply
            },
            // The trusted default handler for an address. It is deliberately the plainest
            // possible one — hand it to the system — so that removing every plugin leaves
            // Tenon opening links exactly the way it always has.
            IntentProviderBinding(
                intentID: try CoreIntentName.urlOpen.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.openAddress(
                    envelope: envelope,
                    context: context
                )
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.clipboardWrite.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.copy(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
        ]
    }
}

private extension SystemIntentProvider {
    func reveal(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) -> IntentProviderReply {
        do {
            let url = try authorizedFileURL(
                from: envelope.input,
                context: context
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return AppIntentProviderSupport.emptySuccess
        } catch AuthorizedFilesystemPathError.unavailable {
            return AppIntentProviderSupport.failure(
                code: codes.pathNotFound,
                reason: "path-not-found"
            )
        } catch AuthorizedFilesystemPathError.becameSymlink {
            return AppIntentProviderSupport.failure(
                code: codes.externalOpenFailed,
                reason: "authorized-path-became-symlink"
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("path")
            )
        }
    }

    func open(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) -> IntentProviderReply {
        do {
            let url = try authorizedFileURL(
                from: envelope.input,
                context: context
            )
            guard NSWorkspace.shared.open(url) else {
                return AppIntentProviderSupport.failure(
                    code: codes.externalOpenFailed,
                    reason: "workspace-open-refused"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch AuthorizedFilesystemPathError.unavailable {
            return AppIntentProviderSupport.failure(
                code: codes.pathNotFound,
                reason: "path-not-found"
            )
        } catch AuthorizedFilesystemPathError.becameSymlink {
            return AppIntentProviderSupport.failure(
                code: codes.externalOpenFailed,
                reason: "authorized-path-became-symlink"
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("path")
            )
        }
    }

    func openAddress(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let requested = try AppIntentProviderSupport.string("url", in: object)
            guard let url = URL(string: requested),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host,
                  !host.isEmpty
            else {
                return AppIntentProviderSupport.failure(
                    code: codes.invalidURL,
                    reason: "not-an-absolute-web-address"
                )
            }
            // The capability binding names `/url`, so policy has already decided this host
            // is one the caller may reach. Asking again is the check that keeps a resolved
            // grant from drifting from the value actually opened.
            guard context.authorizedNetworkHost(for: host) != nil else {
                return AppIntentProviderSupport.failure(
                    code: codes.invalidURL,
                    reason: "host-not-authorized"
                )
            }
            guard NSWorkspace.shared.open(url) else {
                return AppIntentProviderSupport.failure(
                    code: codes.externalOpenFailed,
                    reason: "workspace-open-refused"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("url")
            )
        }
    }

    func copy(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let text = try AppIntentProviderSupport.string("text", in: object)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                return AppIntentProviderSupport.failure(
                    code: codes.clipboardUnavailable,
                    reason: "pasteboard-write-failed"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func authorizedFileURL(
        from input: IntentValue,
        context: IntentProviderContext
    ) throws -> URL {
        let object = try AppIntentProviderSupport.object(input)
        let requestedPath = try AppIntentProviderSupport.string(
            "path",
            in: object
        )
        guard let path = context.authorizedFilesystemPath(
            for: requestedPath
        ) else {
            throw AppIntentInputError.missingOrInvalidField("path")
        }
        return URL(
            fileURLWithPath: try path.validatedResolvedPath()
        )
    }
}
