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

        init() throws {
            pathNotFound = .domain(
                try IntentDomainErrorCode("dev.tenon.core.path-not-found")
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
