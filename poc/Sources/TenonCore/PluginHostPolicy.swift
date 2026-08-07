// @domain: intent-bus, plugin-contributions
//
// The pure half of the host: rules and projections that take values in and give values back,
// with no session, no runtime and no ordering of their own. They are separated from the
// coordinator because they are the part that can be read — and tested — without knowing what
// the host is doing at the time.
import Foundation
import Observation
import TenonIntentCore

// MARK: - Pure policy and projection helpers  @domain: intent-bus, plugin-contributions

extension PluginHost {
    nonisolated static func pluginDispatchRule(
        declaration: IntentContractDeclaration,
        providerID: ProviderID
    ) throws -> IntentDispatchRule {
        return try IntentDispatchRule(
            intentID: declaration.name,
            capabilityBindings: [],
            exposure: IntentExposure(
                discoverableBy: declaration.audiences,
                invocableBy: declaration.audiences
            ),
            trustedDefault: providerID,
            allowsAutomaticSelection: true,
            providerConsent: .never,
            admissionClass: declaration.audiences.contains(.user)
                ? .interactive
                : .background,
            valueLimits: .default,
            maximumTimeout: .seconds(30)
        )
    }

    nonisolated static func capabilityGrants(
        for manifest: PluginManifest
    ) throws -> Set<CapabilityGrant> {
        // `terminal.read` used to be excluded here, and that was right when it existed
        // only to gate delivery of `terminal.*` EVENTs — a permission with no capability
        // behind it. It has since been bound as the capability for the three terminal read
        // intents (`CoreIntentCatalog.swift`: viewport read, scrollback read, wait), and
        // the exclusion was never revisited, so every one of them was ungrantable: a plugin
        // could declare the permission and the use, pass every other check, and still be
        // refused with `missing-capability`. Nothing is loosened by granting it — the event
        // gate reads `manifest.permissions` directly and is untouched, and a caller still
        // needs both the declared permission and the declared use.
        let capabilityPermissions = Set(
            manifest.permissions.filter(PluginManifest.knownPermissions.contains)
        )
        let networkPatterns = try Set(
            manifest.networkAllowlist.map(NetworkHostPattern.init)
        )

        return try Set(
            capabilityPermissions.map { permission in
                let filesystem: FilesystemGrantScope = [
                    "filesystem.read",
                    "filesystem.write",
                    "process.exec",
                    "shell.open",
                ].contains(permission) ? .all : .none
                let network: NetworkGrantScope
                switch permission {
                case "network":
                    network = .hosts(networkPatterns)
                case "web.view":
                    // A visible browser pane is an explicit all-network authority: the
                    // user can see its address and navigate links/redirects. Background
                    // `network.fetch` remains constrained to the manifest allowlist.
                    network = .all
                default:
                    network = .none
                }
                return CapabilityGrant(
                    capability: try CapabilityID(permission),
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: filesystem,
                        network: network
                    )
                )
            }
        )
    }

    nonisolated static func policyFingerprint(
        manifest: PluginManifest,
        installation: PluginInstallationKey,
        approvedOpenIntentIDs: Set<IntentID>
    ) throws -> PolicyFingerprint {
        try PolicyFingerprint(
            canonicalPolicy: .object([
                "pluginID": .string(manifest.id.rawValue),
                "installationID": .string(
                    installation.installationID.uuidString.lowercased()
                ),
                "permissions": .array(
                    manifest.permissions.sorted().map(IntentValue.string)
                ),
                "networkAllow": .array(
                    manifest.networkAllowlist.sorted().map(
                        IntentValue.string
                    )
                ),
                "provides": .array(
                    manifest.intents.provides.map(\.name.rawValue)
                        .sorted().map(IntentValue.string)
                ),
                "approvedOpenIntents": .array(
                    approvedOpenIntentIDs.map(\.rawValue)
                        .sorted().map(IntentValue.string)
                ),
            ])
        )
    }

    nonisolated static func isValidSettingValue(
        _ value: IntentValue,
        for specification: PluginSettingSpec
    ) -> Bool {
        switch (specification.type, value) {
        case (.string, .string), (.boolean, .bool),
             (.number, .number), (.number, .integer):
            return true
        case let (.select, .string(selected)):
            return specification.options?.contains {
                $0.value == selected
            } == true
        default:
            return false
        }
    }

    nonisolated static func intentDiscoveryValue(
        _ snapshot: IntentDiscoverySnapshot
    ) -> IntentValue {
        .object([
            "revision": .object([
                "catalog": .integer(Int64(snapshot.revision.catalog)),
                "rules": .integer(Int64(snapshot.revision.rules)),
                "policy": .integer(
                    Int64(snapshot.revision.policy.rawValue)
                ),
                "providers": .string(
                    Self.encodedProviderRevision(
                        snapshot.revision.providers
                    )
                ),
                "session": .integer(
                    Int64(snapshot.revision.principal.sessionRevision)
                ),
            ]),
            "items": .array(
                snapshot.items.map { item in
                    .object([
                        "name": .string(item.name.rawValue),
                        "title": item.title.map(IntentValue.string)
                            ?? .null,
                        "description": item.description.map(
                            IntentValue.string
                        ) ?? .null,
                        "deprecated": .bool(item.deprecated),
                        "inputSchema": item.inputSchema,
                        "outputSchema": item.outputSchema,
                        "providers": .array(
                            item.activeProviders.map {
                                .string($0.rawValue)
                            }
                        ),
                    ])
                }
            ),
        ])
    }

    nonisolated static func sortViewReferences(
        _ lhs: ViewInstanceReference,
        _ rhs: ViewInstanceReference
    ) -> Bool {
        (
            lhs.pluginID.rawValue,
            lhs.viewID,
            lhs.instanceID
        ) < (
            rhs.pluginID.rawValue,
            rhs.viewID,
            rhs.instanceID
        )
    }

    nonisolated static func diagnostic(for error: any Error) -> String {
        return String(describing: error)
    }

    nonisolated static func encodedProviderRevision(
        _ revision: ProviderRegistryRevision
    ) -> String {
        guard let data = try? JSONEncoder().encode(revision),
              let value = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return value
    }
}
