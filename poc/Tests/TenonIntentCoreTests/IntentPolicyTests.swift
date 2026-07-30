import Foundation
@testable import TenonIntentCore
import XCTest

final class IntentPolicyTests: XCTestCase {
    func testPluginInvocationWithoutExactDeclaredUseIsDenied() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: caller)

        let decision = await engine.authorize(
            invocation(intent: intent, caller: caller, capability: capability)
        )

        XCTAssertEqual(decision.verdict, .denied(.undeclaredUse(intent)))
        let snapshot = await engine.snapshot()
        XCTAssertEqual(decision.policyRevision, snapshot.revision)
    }

    func testDeclaredUseDoesNotGrantCapability() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)

        let decision = await engine.authorize(
            invocation(intent: intent, caller: caller, capability: capability)
        )

        XCTAssertEqual(decision.verdict, .denied(.missingCapability(capability)))
    }

    func testMatchingDeclaredUseGrantAndExposureAllowInvocation() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: caller)

        let decision = await engine.authorize(
            invocation(intent: intent, caller: caller, capability: capability)
        )

        XCTAssertEqual(decision.verdict, .allowed)
    }

    func testWorkspaceAndPaneScopeMustBothMatchOneGrant() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("workspace.focus-pane.v1")
        let capability = try CapabilityID("workspace.control")
        let allowedWorkspace = UUID()
        let allowedPane = UUID()
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .only([allowedWorkspace]),
                        panes: .only([allowedPane]),
                        filesystem: .none
                    )
                ),
            ],
            for: caller
        )

        let wrongWorkspace = UUID()
        let workspaceDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                scope: InvocationScope(workspaceID: wrongWorkspace, paneID: allowedPane)
            )
        )
        XCTAssertEqual(
            workspaceDecision.verdict,
            .denied(.workspaceOutsideGrant(capability: capability, workspaceID: wrongWorkspace))
        )

        let wrongPane = UUID()
        let paneDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                scope: InvocationScope(workspaceID: allowedWorkspace, paneID: wrongPane)
            )
        )
        XCTAssertEqual(
            paneDecision.verdict,
            .denied(.paneOutsideGrant(capability: capability, paneID: wrongPane))
        )
    }

    func testScopedGrantDeniesMissingWorkspaceContext() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("workspace.snapshot.v1")
        let capability = try CapabilityID("workspace.read")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .only([UUID()]),
                        panes: .any,
                        filesystem: .none
                    )
                ),
            ],
            for: caller
        )

        let decision = await engine.authorize(
            invocation(intent: intent, caller: caller, capability: capability)
        )

        XCTAssertEqual(decision.verdict, .denied(.workspaceRequired(capability)))
    }

    func testCanonicalFilesystemRootAllowsDescendantsButNotPrefixSiblings() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("file.read.v1")
        let capability = try CapabilityID("filesystem.read")
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-policy-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        let prefixSibling = base.appendingPathComponent("allowed-escape")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixSibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try CanonicalFilesystemRoot(
            path: allowed.appendingPathComponent("child/..").path
        )
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .roots([root])
                    )
                ),
            ],
            for: caller
        )

        let inside = allowed.appendingPathComponent("folder/../file.txt").path
        let insideDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                filesystemPaths: [inside]
            )
        )
        XCTAssertEqual(insideDecision.verdict, .allowed)

        let outside = prefixSibling.appendingPathComponent("secret.txt").path
        let outsideDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                filesystemPaths: [outside]
            )
        )
        XCTAssertEqual(
            outsideDecision.verdict,
            .denied(.filesystemPathOutsideGrant(capability: capability, path: outside))
        )
    }

    func testRelativeFilesystemArgumentIsDeniedInsteadOfResolvedAgainstProcessCWD() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("file.read.v1")
        let capability = try CapabilityID("filesystem.read")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .all
                    )
                ),
            ],
            for: caller
        )

        let decision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                filesystemPaths: ["relative/file.txt"]
            )
        )

        XCTAssertEqual(
            decision.verdict,
            .denied(.invalidFilesystemPath(capability: capability, path: "relative/file.txt"))
        )
    }

    func testNetworkGrantMatchesExactWildcardIDNAndIPv6Hosts() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.fetch")
        let intent = try IntentID("network.fetch.v1")
        let capability = try CapabilityID("network.fetch")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none,
                        network: .hosts([
                            try NetworkHostPattern("api.example.com"),
                            try NetworkHostPattern("*.cdn.example.com"),
                            try NetworkHostPattern("xn--bcher-kva.example"),
                            try NetworkHostPattern("2001:db8::1"),
                        ])
                    )
                ),
            ],
            for: caller
        )

        for host in [
            "API.EXAMPLE.COM.",
            "assets.cdn.example.com",
            "xn--bcher-kva.example",
            "[2001:0db8:0:0:0:0:0:1]",
        ] {
            let decision = await engine.authorize(
                invocation(
                    intent: intent,
                    caller: caller,
                    capability: capability,
                    networkHosts: [host]
                )
            )
            XCTAssertEqual(decision.verdict, .allowed, host)
        }
    }

    func testNetworkAuthorizationMakesPrivateEndpointAuthorityExplicit()
        async throws
    {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.fetch-private")
        let intent = try IntentID("network.fetch.v1")
        let capability = try CapabilityID("network.fetch")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none,
                        network: .hosts([
                            try NetworkHostPattern("api.example.com"),
                            try NetworkHostPattern("127.0.0.1"),
                        ])
                    )
                ),
            ],
            for: caller
        )

        let publicHost = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                networkHosts: ["api.example.com"]
            )
        )
        XCTAssertEqual(
            publicHost.authorizedNetworkHosts,
            [
                AuthorizedNetworkHost(
                    requestedHost: "api.example.com",
                    canonicalHost: "api.example.com",
                    allowsPrivateEndpoints: false
                )
            ]
        )

        let privateLiteral = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                networkHosts: ["127.0.0.1"]
            )
        )
        XCTAssertEqual(
            privateLiteral.authorizedNetworkHosts,
            [
                AuthorizedNetworkHost(
                    requestedHost: "127.0.0.1",
                    canonicalHost: "127.0.0.1",
                    allowsPrivateEndpoints: true
                )
            ]
        )
    }

    func testNetworkWildcardExcludesRootAndPrefixSibling() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.fetch")
        let intent = try IntentID("network.fetch.v1")
        let capability = try CapabilityID("network.fetch")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none,
                        network: .hosts([try NetworkHostPattern("*.example.com")])
                    )
                ),
            ],
            for: caller
        )

        for host in ["example.com", "example.com.evil.test"] {
            let decision = await engine.authorize(
                invocation(
                    intent: intent,
                    caller: caller,
                    capability: capability,
                    networkHosts: [host]
                )
            )
            XCTAssertEqual(
                decision.verdict,
                .denied(.networkHostOutsideGrant(capability: capability, host: host))
            )
        }
    }

    func testNetworkGrantRejectsMalformedHostAndOverbroadWildcard() async throws {
        XCTAssertThrowsError(try NetworkHostPattern("*.com"))
        XCTAssertThrowsError(try NetworkHostPattern("bad_host.example"))

        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.fetch")
        let intent = try IntentID("network.fetch.v1")
        let capability = try CapabilityID("network.fetch")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none,
                        network: .all
                    )
                ),
            ],
            for: caller
        )

        let decision = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                capability: capability,
                networkHosts: ["bad_host.example"]
            )
        )
        XCTAssertEqual(
            decision.verdict,
            .denied(.invalidNetworkHost(capability: capability, host: "bad_host.example"))
        )
    }

    func testDiscoveryAndInvocationAudienceExposureAreIndependent() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let cli = IntentPrincipal(
            id: "cli:local",
            kind: .cli,
            sessionRevision: 1
        )
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(
            IntentExposure(discoverableBy: [.plugin], invocableBy: []),
            for: intent
        )
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: caller)

        let pluginDiscovery = await engine.discover(
            PolicyDiscoveryRequest(
                intent: intent,
                caller: caller,
                requiredCapabilities: [capability]
            )
        )
        XCTAssertEqual(pluginDiscovery.verdict, .allowed)

        let invocationDecision = await engine.authorize(
            invocation(intent: intent, caller: caller, capability: capability)
        )
        XCTAssertEqual(
            invocationDecision.verdict,
            .denied(.audienceCannotInvoke(intent: intent, audience: .plugin))
        )

        let cliDiscovery = await engine.discover(
            PolicyDiscoveryRequest(
                intent: intent,
                caller: cli,
                requiredCapabilities: []
            )
        )
        XCTAssertEqual(
            cliDiscovery.verdict,
            .denied(.intentNotDiscoverable(intent: intent, audience: .cli))
        )
    }

    func testPolicySnapshotsRemainImmutableAndRevisionChangesOnlyForEffectiveMutation() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        let initial = await engine.snapshot()
        XCTAssertEqual(initial.revision, PolicyRevision(0))

        try await engine.setExposure(pluginExposure, for: intent)
        let afterExposure = await engine.snapshot()
        XCTAssertEqual(afterExposure.revision, PolicyRevision(1))

        try await engine.setExposure(pluginExposure, for: intent)
        let afterNoOp = await engine.snapshot()
        XCTAssertEqual(afterNoOp.revision, PolicyRevision(1))

        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: caller)
        let current = await engine.snapshot()

        XCTAssertEqual(afterExposure.revision, PolicyRevision(1))
        XCTAssertNil(afterExposure.declaredUses[caller])
        XCTAssertNil(afterExposure.grants[caller])
        XCTAssertEqual(current.revision, PolicyRevision(3))
        XCTAssertEqual(current.declaredUses[caller], [intent])
        XCTAssertEqual(current.grants[caller], [unrestrictedGrant(capability)])
    }

    func testProviderConsentIsIgnoredWithoutMutatingPolicyWhenFingerprintChanges() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let intent = try IntentID("file.open.v1")
        let provider = try ProviderID("dev.tenon.editor")
        let fingerprintV1 = try PolicyFingerprint(
            canonicalPolicy: .object([
                "capabilities": .array([.string("filesystem.read")]),
                "scope": .string("workspace"),
            ])
        )
        let fingerprintV2 = try PolicyFingerprint(
            canonicalPolicy: .object([
                "capabilities": .array([
                    .string("filesystem.read"),
                    .string("filesystem.write"),
                ]),
                "scope": .string("all-files"),
            ])
        )
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)

        let firstKey = ProviderConsentKey(
            contract: intent,
            providerID: provider,
            policyFingerprint: fingerprintV1
        )
        let beforeConsent = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                consent: .required(firstKey)
            )
        )
        XCTAssertEqual(beforeConsent.verdict, .denied(.providerConsentRequired(firstKey)))

        try await engine.recordProviderConsent(.allow, for: firstKey)
        let consented = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                consent: .required(firstKey)
            )
        )
        XCTAssertEqual(consented.verdict, .allowed)

        let changedKey = ProviderConsentKey(
            contract: intent,
            providerID: provider,
            policyFingerprint: fingerprintV2
        )
        let beforeChangedAuthorization = await engine.snapshot()
        let changed = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                consent: .required(changedKey)
            )
        )
        XCTAssertEqual(
            changed.verdict,
            .denied(
                .providerConsentStale(
                    contract: intent,
                    providerID: provider,
                    consentedFingerprint: fingerprintV1,
                    currentFingerprint: fingerprintV2
                )
            )
        )
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot, beforeChangedAuthorization)
        XCTAssertEqual(snapshot.providerConsents[firstKey], .allow)
    }

    func testProviderConsentDoesNotCrossContractMajor() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git")
        let v1 = try IntentID("file.open.v1")
        let v2 = try IntentID("file.open.v2")
        let provider = try ProviderID("dev.tenon.editor")
        let fingerprint = try PolicyFingerprint(canonicalPolicy: .object(["effect": .string("read")]))
        try await engine.setExposure(pluginExposure, for: v1)
        try await engine.setExposure(pluginExposure, for: v2)
        try await engine.replaceDeclaredUses([v1, v2], for: caller)

        let v1Key = ProviderConsentKey(
            contract: v1,
            providerID: provider,
            policyFingerprint: fingerprint
        )
        try await engine.recordProviderConsent(.allow, for: v1Key)

        let v2Key = ProviderConsentKey(
            contract: v2,
            providerID: provider,
            policyFingerprint: fingerprint
        )
        let decision = await engine.authorize(
            invocation(intent: v2, caller: caller, consent: .required(v2Key))
        )

        XCTAssertEqual(decision.verdict, .denied(.providerConsentRequired(v2Key)))
    }

    func testCallerConsentRequirementCannotCrossCallerOrContract() async throws {
        let engine = PolicyEngine()
        let caller = pluginPrincipal("plugin:dev.tenon.git:installation")
        let otherCaller = pluginPrincipal("plugin:dev.tenon.files:installation")
        let intent = try IntentID("terminal.write.v1")
        let otherIntent = try IntentID("workspace.pane.close.v1")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: caller)
        try await engine.grantStandingConsent(contract: intent, caller: caller)

        let grantedKey = CallerConsentKey(caller: caller, contract: intent)
        let granted = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                callerConsent: .required(grantedKey)
            )
        )
        XCTAssertEqual(granted.verdict, .allowed)

        let wrongContractKey = CallerConsentKey(
            caller: caller,
            contract: otherIntent
        )
        let wrongContract = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                callerConsent: .required(wrongContractKey)
            )
        )
        XCTAssertEqual(
            wrongContract.verdict,
            .denied(
                .callerConsentContractMismatch(
                    expected: intent,
                    provided: otherIntent
                )
            )
        )

        let wrongCallerKey = CallerConsentKey(
            caller: otherCaller,
            contract: intent
        )
        let wrongCaller = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                callerConsent: .required(wrongCallerKey)
            )
        )
        XCTAssertEqual(
            wrongCaller.verdict,
            .denied(
                .callerConsentCallerMismatch(
                    expectedID: caller.id,
                    expectedKind: caller.kind,
                    providedID: otherCaller.id,
                    providedKind: otherCaller.kind
                )
            )
        )

        try await engine.revokeStandingConsent(contract: intent, caller: caller)
        let revoked = await engine.authorize(
            invocation(
                intent: intent,
                caller: caller,
                callerConsent: .required(grantedKey)
            )
        )
        XCTAssertEqual(
            revoked.verdict,
            .denied(.callerConsentRequired(grantedKey))
        )
    }

    func testProviderNestedInvocationUsesProviderAuthorityInsteadOfCallerGrant() async throws {
        let engine = PolicyEngine()
        let originalCaller = pluginPrincipal("plugin:dev.tenon.automation")
        let providerCaller = pluginPrincipal("plugin:dev.tenon.provider")
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(pluginExposure, for: intent)
        try await engine.replaceDeclaredUses([intent], for: originalCaller)
        try await engine.replaceDeclaredUses([intent], for: providerCaller)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: originalCaller)

        let original = await engine.authorize(
            invocation(intent: intent, caller: originalCaller, capability: capability)
        )
        XCTAssertEqual(original.verdict, .allowed)

        let nested = await engine.authorize(
            invocation(intent: intent, caller: providerCaller, capability: capability)
        )
        XCTAssertEqual(nested.verdict, .denied(.missingCapability(capability)))
    }

    func testPrincipalRevisionAndKindCannotReuseAnotherGenerationPolicy() async throws {
        let engine = PolicyEngine()
        let active = pluginPrincipal("plugin:dev.tenon.git:installation")
        let reloaded = IntentPrincipal(
            id: active.id,
            kind: active.kind,
            sessionRevision: active.sessionRevision + 1
        )
        let kindSpoof = IntentPrincipal(
            id: active.id,
            kind: .agent,
            sessionRevision: active.sessionRevision
        )
        let intent = try IntentID("terminal.run.v1")
        let capability = try CapabilityID("terminal.write")
        try await engine.setExposure(
            IntentExposure(
                discoverableBy: [.plugin, .agent],
                invocableBy: [.plugin, .agent]
            ),
            for: intent
        )
        try await engine.replaceDeclaredUses([intent], for: active)
        try await engine.replaceGrants([unrestrictedGrant(capability)], for: active)

        let reloadedDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: reloaded,
                capability: capability
            )
        )
        XCTAssertEqual(
            reloadedDecision.verdict,
            .denied(.undeclaredUse(intent))
        )

        let kindSpoofDecision = await engine.authorize(
            invocation(
                intent: intent,
                caller: kindSpoof,
                capability: capability
            )
        )
        XCTAssertEqual(
            kindSpoofDecision.verdict,
            .denied(.missingCapability(capability))
        )

        try await engine.removePrincipal(active)
        let snapshot = await engine.snapshot()
        XCTAssertNil(snapshot.declaredUses[active])
        XCTAssertNil(snapshot.grants[active])
        let removed = await engine.authorize(
            invocation(intent: intent, caller: active, capability: capability)
        )
        XCTAssertEqual(removed.verdict, .denied(.undeclaredUse(intent)))
    }

    func testRevisionExhaustionFailsBeforeChangingPolicyState() async throws {
        let engine = PolicyEngine(initialRevisionForTesting: UInt64.max)
        let intent = try IntentID("terminal.run.v1")

        await XCTAssertThrowsErrorAsync(
            try await engine.setExposure(pluginExposure, for: intent)
        ) { error in
            XCTAssertEqual(error as? PolicyEngineError, .revisionExhausted)
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.revision, PolicyRevision(UInt64.max))
        XCTAssertTrue(snapshot.exposures.isEmpty)
    }

    func testRevisionWaiterPublishesAfterStateMutationAndCancelsWithoutLeak() async throws {
        let engine = PolicyEngine()
        let intent = try IntentID("terminal.run.v1")
        let initial = await engine.snapshot().revision
        let waiter = Task {
            try await engine.waitForRevision(after: initial)
        }
        await Task.yield()

        try await engine.setExposure(pluginExposure, for: intent)

        let published = try await waiter.value
        let snapshot = await engine.snapshot()
        XCTAssertEqual(published, snapshot.revision)
        XCTAssertEqual(snapshot.exposures[intent], pluginExposure)

        let cancelled = Task {
            try await engine.waitForRevision(after: published)
        }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected revision waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testPolicyPublicValuesAreSendable() {
        assertSendable(CapabilityID.self)
        assertSendable(CanonicalFilesystemRoot.self)
        assertSendable(CapabilityGrant.self)
        assertSendable(CapabilityGrantScope.self)
        assertSendable(IntentExposure.self)
        assertSendable(PolicyFingerprint.self)
        assertSendable(ProviderConsentKey.self)
        assertSendable(CallerConsentKey.self)
        assertSendable(CallerConsentRequirement.self)
        assertSendable(PolicySnapshot.self)
        assertSendable(PolicyDecision.self)
        assertSendable(PolicyEngine.self)
    }

    func testCapabilityIDRejectsNonCanonicalSpellings() throws {
        XCTAssertEqual(try CapabilityID("filesystem.read").rawValue, "filesystem.read")
        XCTAssertEqual(try CapabilityID("network").rawValue, "network")

        for invalid in ["", "Filesystem.read", ".filesystem", "filesystem.", "file_system"] {
            XCTAssertThrowsError(try CapabilityID(invalid))
        }
    }

    private var pluginExposure: IntentExposure {
        IntentExposure(discoverableBy: [.plugin], invocableBy: [.plugin])
    }

    private func pluginPrincipal(_ id: String) -> IntentPrincipal {
        IntentPrincipal(id: id, kind: .plugin, sessionRevision: 1)
    }

    private func unrestrictedGrant(_ capability: CapabilityID) -> CapabilityGrant {
        CapabilityGrant(
            capability: capability,
            scope: CapabilityGrantScope(
                workspaces: .any,
                panes: .any,
                filesystem: .all
            )
        )
    }

    private func invocation(
        intent: IntentID,
        caller: IntentPrincipal,
        capability: CapabilityID? = nil,
        scope: InvocationScope = InvocationScope(),
        filesystemPaths: [String] = [],
        networkHosts: [String] = [],
        consent: ProviderConsentRequirement = .notRequired,
        callerConsent: CallerConsentRequirement = .notRequired
    ) -> PolicyInvocationRequest {
        PolicyInvocationRequest(
            envelope: IntentEnvelope(
                requestID: UUID(),
                traceID: UUID(),
                parentRequestID: nil,
                name: intent,
                input: .object([:]),
                caller: caller,
                scope: scope,
                deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                target: nil,
                idempotencyKey: nil
            ),
            capabilityRequirements: capability.map {
                [
                    CapabilityRequirement(
                        capability: $0,
                        filesystemPaths: filesystemPaths,
                        networkHosts: networkHosts
                    ),
                ]
            } ?? [],
            providerConsent: consent,
            callerConsent: callerConsent
        )
    }

    private func assertSendable(_: (some Sendable).Type) {}
}
