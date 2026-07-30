import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginHostTests: XCTestCase {
    @MainActor
    func testKeyBindingProjectionIsLexicalAndTracksActiveLifecycle()
        async throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alphaID: PluginID = "dev.test.key-alpha"
        let betaID: PluginID = "dev.test.key-beta"
        let alphaIntent = try IntentID(
            "dev.test.key-alpha.open.v1"
        )
        let betaIntent = try IntentID(
            "dev.test.key-beta.open.v1"
        )
        try writePlugin(
            root: root,
            directoryName: "z-alpha",
            manifest: providerManifest(
                id: alphaID.rawValue,
                intent: alphaIntent.rawValue,
                key: "cmd+shift+k"
            )
        )
        try writePlugin(
            root: root,
            directoryName: "a-beta",
            manifest: providerManifest(
                id: betaID.rawValue,
                intent: betaIntent.rawValue,
                key: "shift+command+k"
            )
        )

        let controller = FakeRuntimeController()
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()

        let alphaTarget = KeyBindingTarget(
            pluginID: alphaID,
            intentID: alphaIntent
        )
        let betaTarget = KeyBindingTarget(
            pluginID: betaID,
            intentID: betaIntent
        )
        XCTAssertEqual(
            host.keyBindingIndex.bindings.map(\.target),
            [alphaTarget]
        )
        XCTAssertEqual(
            host.commandIndex.commands.first {
                $0.id == alphaIntent.rawValue
            }?.key?.display,
            "⇧⌘K"
        )
        XCTAssertNil(
            host.commandIndex.commands.first {
                $0.id == betaIntent.rawValue
            }?.key
        )
        XCTAssertNotNil(host.intentPresentation(for: betaTarget))

        let conflictLogCount = host.log.filter {
            $0.contains("assigned to")
        }.count
        let betaRuntime = try await controller.runtime(
            for: betaID,
            index: 0
        )
        await betaRuntime.emitStatus("first publish")
        await betaRuntime.emitStatus("second publish")
        XCTAssertEqual(
            host.log.filter { $0.contains("assigned to") }.count,
            conflictLogCount,
            "unchanged publishes must not duplicate diagnostics"
        )

        try await host.setEnabled(false, pluginID: alphaID)
        XCTAssertEqual(
            host.keyBindingIndex.bindings.map(\.target),
            [betaTarget]
        )
        XCTAssertEqual(
            host.commandIndex.commands.first?.key?.display,
            "⇧⌘K"
        )

        try await host.setEnabled(true, pluginID: alphaID)
        XCTAssertEqual(
            host.keyBindingIndex.bindings.map(\.target),
            [alphaTarget]
        )
        XCTAssertNil(
            host.commandIndex.commands.first {
                $0.id == betaIntent.rawValue
            }?.key
        )
        await host.shutdown()
    }

    @MainActor
    func testPluginLifecycleCallbackObservesPublishedDurableState() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID: PluginID = "dev.test.lifecycle-callback"
        try writePlugin(
            root: root,
            directoryName: "lifecycle-callback",
            manifest: basicManifest(id: pluginID.rawValue)
        )

        let controller = FakeRuntimeController()
        let host = try makeHost(root: root, controller: controller)
        var observed: [[PluginSnapshot]] = []
        host.onPluginLifecycleChanged = { snapshots in
            XCTAssertEqual(
                host.plugins,
                snapshots,
                "the callback must run after the published snapshot changes"
            )
            observed.append(snapshots)
        }

        try await host.loadAll()
        XCTAssertEqual(observed.last?.first?.id, pluginID)
        XCTAssertEqual(observed.last?.first?.isLoaded, true)

        try await host.setEnabled(false, pluginID: pluginID)
        XCTAssertEqual(observed.last?.first?.isEnabled, false)
        XCTAssertEqual(observed.last?.first?.isLoaded, false)

        try await host.uninstall(pluginID: pluginID)
        XCTAssertTrue(observed.last?.isEmpty == true)
        await host.shutdown()
    }

    @MainActor
    func testTargetedEventReachesOnlyTheRequestedPlugin() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = PluginID("dev.test.event-first")
        let secondID = PluginID("dev.test.event-second")
        try writePlugin(
            root: root,
            directoryName: "first",
            manifest: basicManifest(id: firstID.rawValue)
        )
        try writePlugin(
            root: root,
            directoryName: "second",
            manifest: basicManifest(id: secondID.rawValue)
        )

        let controller = FakeRuntimeController()
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()

        await host.emit(
            event: "web.did-navigate",
            payload: .object(["url": .string("https://example.com")]),
            to: firstID
        )
        await host.emit(
            event: "terminal.title-changed",
            payload: .object(["title": .string("secret")]),
            to: firstID
        )

        let first = try await controller.runtime(for: firstID, index: 0)
        let second = try await controller.runtime(for: secondID, index: 0)
        let firstPayloads = await first.emittedPayloads(
            for: "web.did-navigate"
        )
        let secondPayloads = await second.emittedPayloads(
            for: "web.did-navigate"
        )
        let unauthorizedTerminalPayloads = await first.emittedPayloads(
            for: "terminal.title-changed"
        )
        XCTAssertEqual(
            firstPayloads,
            [.object(["url": .string("https://example.com")])]
        )
        XCTAssertEqual(secondPayloads, [])
        XCTAssertEqual(unauthorizedTerminalPayloads, [])
        await host.shutdown()
    }

    func testVisibleWebAndBackgroundNetworkKeepSeparateScopes() throws {
        let manifest = try PluginManifest(
            id: "dev.test.web-policy",
            name: "Web policy",
            version: "1",
            permissions: ["web.view", "network"],
            network: PluginNetworkPolicy(allow: ["api.example.com"])
        )

        let grants = try PluginHost.capabilityGrants(for: manifest)
        let webGrant = try XCTUnwrap(
            grants.first { $0.capability.rawValue == "web.view" }
        )
        let networkGrant = try XCTUnwrap(
            grants.first { $0.capability.rawValue == "network" }
        )

        XCTAssertEqual(webGrant.scope.network, .all)
        XCTAssertEqual(
            networkGrant.scope.network,
            .hosts([try NetworkHostPattern("api.example.com")])
        )
    }

    @MainActor
    func testDuplicatePluginIDIsRejectedBeforeRuntimeConstruction() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin(
            root: root,
            directoryName: "first",
            manifest: basicManifest(id: "dev.test.duplicate")
        )
        try writePlugin(
            root: root,
            directoryName: "second",
            manifest: basicManifest(id: "dev.test.duplicate")
        )

        let controller = FakeRuntimeController()
        let host = try makeHost(root: root, controller: controller)

        do {
            try await host.loadAll()
            XCTFail("duplicate identities must fail manifest preflight")
        } catch {
            XCTAssertEqual(
                error as? PluginHostError,
                .duplicatePluginID(
                    pluginID: PluginID("dev.test.duplicate"),
                    directories: ["first", "second"]
                )
            )
        }
        let runtimeCount = await controller.runtimeCount()
        XCTAssertEqual(runtimeCount, 0)
        await host.shutdown()
    }

    @MainActor
    func testFailedReloadRetainsActiveSessionAndContributions() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.reload")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "old"), for: pluginID)
        await controller.enqueue(.fail("candidate failed"), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()

        let oldIdentity = try XCTUnwrap(host.sessionIdentity(for: pluginID))
        let oldRuntime = try await controller.runtime(for: pluginID, index: 0)
        XCTAssertEqual(host.statusItems.map(\.text), ["old"])

        try basicManifest(id: pluginID.rawValue, version: "2").write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        do {
            try await host.reload(directoryNamed: "reload")
            XCTFail("a failed staged runtime must not replace the active session")
        } catch {
            guard case .runtimeFailed = error as? PluginHostError else {
                return XCTFail("unexpected reload error: \(error)")
            }
        }

        XCTAssertEqual(host.sessionIdentity(for: pluginID), oldIdentity)
        XCTAssertEqual(host.statusItems.map(\.text), ["old"])
        let oldShutdownCount = await oldRuntime.shutdownCount()
        let failedRuntime = try await controller.runtime(
            for: pluginID,
            index: 1
        )
        let failedShutdownCount = await failedRuntime.shutdownCount()
        XCTAssertEqual(oldShutdownCount, 0)
        XCTAssertEqual(failedShutdownCount, 1)
        await host.shutdown()
    }

    @MainActor
    func testActiveRuntimeFailurePerformsTerminalRetirementWithRecoverableIdentity()
        async throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.runtime-failure")
        let intentID = try IntentID("dev.test.runtime-failure.ping.v1")
        try writePlugin(
            root: root,
            directoryName: "runtime-failure",
            manifest: providerManifest(
                id: pluginID.rawValue,
                intent: intentID.rawValue
            )
        )
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "live"), for: pluginID)
        await controller.enqueue(.active(status: "recovered"), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()

        let failedIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        let failedPrincipal = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: failedIdentity.installationID
        ).principal(sessionRevision: failedIdentity.sessionRevision)
        let failedRuntime = try await controller.runtime(
            for: pluginID,
            index: 0
        )
        let policyBeforeFailure = await host.kernel.policy.snapshot()
        XCTAssertNotNil(policyBeforeFailure.declaredUses[failedPrincipal])
        XCTAssertEqual(host.statusItems.map(\.text), ["live"])
        XCTAssertEqual(host.intentPresentations.map(\.intentID), [intentID])

        await failedRuntime.fail()

        XCTAssertNil(host.sessionIdentity(for: pluginID))
        XCTAssertTrue(host.statusItems.isEmpty)
        XCTAssertTrue(host.pluginViews.isEmpty)
        XCTAssertTrue(host.intentPresentations.isEmpty)
        let failedPlugin = try XCTUnwrap(
            host.plugins.first(where: { $0.id == pluginID })
        )
        XCTAssertEqual(
            failedPlugin.installationID,
            failedIdentity.installationID
        )
        XCTAssertTrue(failedPlugin.isEnabled)
        XCTAssertFalse(failedPlugin.isLoaded)
        XCTAssertEqual(
            failedPlugin.error,
            "runtime entered failed phase"
        )

        await host.emit(
            event: "workspace.did-change",
            payload: .object([:]),
            to: pluginID
        )
        let retiredEventPayloads = await failedRuntime.emittedPayloads(
            for: "workspace.did-change"
        )
        XCTAssertTrue(retiredEventPayloads.isEmpty)

        let policy = host.kernel.policy
        await waitUntil {
            let snapshot = await policy.snapshot()
            let shutdownCount = await failedRuntime.shutdownCount()
            return snapshot.declaredUses[failedPrincipal] == nil
                && snapshot.grants[failedPrincipal] == nil
                && shutdownCount == 1
        }

        let palette = IntentPrincipal(
            id: "palette:runtime-failure-tests",
            kind: .palette,
            sessionRevision: 1
        )
        let catalogAfterFailure = await host.kernel.dispatcher.discover(
            for: palette,
            projection: .catalog
        )
        let callableAfterFailure = await host.kernel.dispatcher.discover(
            for: palette,
            projection: .callable
        )
        XCTAssertEqual(
            catalogAfterFailure.items.first(where: { $0.name == intentID })?
                .isAvailable,
            false
        )
        XCTAssertFalse(
            callableAfterFailure.items.contains(where: { $0.name == intentID })
        )
        let policyAfterFailure = await host.kernel.policy.snapshot()
        XCTAssertNil(policyAfterFailure.declaredUses[failedPrincipal])
        XCTAssertNil(policyAfterFailure.grants[failedPrincipal])
        let failedShutdownCount = await failedRuntime.shutdownCount()
        XCTAssertEqual(failedShutdownCount, 1)

        try await host.reload(directoryNamed: "runtime-failure")
        let recoveredIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        XCTAssertEqual(
            recoveredIdentity.installationID,
            failedIdentity.installationID
        )
        XCTAssertEqual(
            recoveredIdentity.sessionRevision,
            failedIdentity.sessionRevision + 1
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["recovered"])
        XCTAssertEqual(host.intentPresentations.map(\.intentID), [intentID])
        XCTAssertNil(
            host.plugins.first(where: { $0.id == pluginID })?.error
        )

        await failedRuntime.emitStaleFailure()

        XCTAssertEqual(
            host.sessionIdentity(for: pluginID),
            recoveredIdentity
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["recovered"])
        let recoveredRuntime = try await controller.runtime(
            for: pluginID,
            index: 1
        )
        let recoveredShutdownCount = await recoveredRuntime.shutdownCount()
        XCTAssertEqual(recoveredShutdownCount, 0)
        await host.shutdown()
    }

    @MainActor
    func testSuccessfulProviderSwapRetiresOldRuntimeAndFiltersStaleCallbacks() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.swap")
        let directory = try writePlugin(
            root: root,
            directoryName: "swap",
            manifest: providerManifest(
                id: pluginID.rawValue,
                intent: "dev.test.swap.ping.v1",
                version: "1"
            )
        )
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "old"), for: pluginID)
        await controller.enqueue(.active(status: "new"), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()

        let oldIdentity = try XCTUnwrap(host.sessionIdentity(for: pluginID))
        let oldRuntime = try await controller.runtime(for: pluginID, index: 0)
        try providerManifest(
            id: pluginID.rawValue,
            intent: "dev.test.swap.ping.v1",
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        try await host.reload(directoryNamed: "swap")

        let newIdentity = try XCTUnwrap(host.sessionIdentity(for: pluginID))
        XCTAssertEqual(newIdentity.installationID, oldIdentity.installationID)
        XCTAssertEqual(
            newIdentity.sessionRevision,
            oldIdentity.sessionRevision + 1
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["new"])
        await waitUntil {
            await oldRuntime.shutdownCount() == 1
        }

        await oldRuntime.emitStatus("stale")
        await Task.yield()
        XCTAssertEqual(host.statusItems.map(\.text), ["new"])
        await host.shutdown()
    }

    @MainActor
    func testConcurrentReloadOrderInversionCannotRestoreOlderCandidate() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.reload.order")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload-order",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let gate = FakeStartGate()
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "v1"), for: pluginID)
        await controller.enqueue(
            .gated(status: "v2", gate: gate),
            for: pluginID
        )
        await controller.enqueue(.active(status: "v3"), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let initialIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        try basicManifest(
            id: pluginID.rawValue,
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let olderReload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-order")
        }
        await waitUntil {
            await gate.hasEntered
        }
        try basicManifest(
            id: pluginID.rawValue,
            version: "3"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        let newerReload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-order")
        }
        await Task.yield()

        await gate.release()
        try await olderReload.value
        try await newerReload.value

        let finalIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        XCTAssertEqual(
            finalIdentity.sessionRevision,
            initialIdentity.sessionRevision + 2
        )
        XCTAssertEqual(
            host.runtimeSnapshot(for: pluginID)?.manifest.version,
            "3"
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["v3"])
        let olderRuntime = try await controller.runtime(
            for: pluginID,
            index: 1
        )
        let olderShutdownCount = await olderRuntime.shutdownCount()
        XCTAssertEqual(olderShutdownCount, 1)
        await host.shutdown()
    }

    @MainActor
    func testUninstallQueuedBehindReloadWinsFinalState() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.reload.uninstall")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload-uninstall",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let gate = FakeStartGate()
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "v1"), for: pluginID)
        await controller.enqueue(
            .gated(status: "v2", gate: gate),
            for: pluginID
        )
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        try basicManifest(
            id: pluginID.rawValue,
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let reload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-uninstall")
        }
        await waitUntil {
            await gate.hasEntered
        }
        let uninstall = Task { @MainActor in
            try await host.uninstall(pluginID: pluginID)
        }
        await Task.yield()

        await gate.release()
        try await reload.value
        try await uninstall.value

        XCTAssertNil(host.sessionIdentity(for: pluginID))
        XCTAssertFalse(host.plugins.contains(where: { $0.id == pluginID }))
        XCTAssertTrue(host.statusItems.isEmpty)
        let candidate = try await controller.runtime(
            for: pluginID,
            index: 1
        )
        let candidateShutdownCount = await candidate.shutdownCount()
        XCTAssertEqual(candidateShutdownCount, 1)
        await host.shutdown()
    }

    @MainActor
    func testDisableReenableQueuedBehindReloadWinsFinalState() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.reload.toggle")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload-toggle",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let gate = FakeStartGate()
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "v1"), for: pluginID)
        await controller.enqueue(
            .gated(status: "v2", gate: gate),
            for: pluginID
        )
        await controller.enqueue(
            .active(status: "reenabled"),
            for: pluginID
        )
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let initialIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        try basicManifest(
            id: pluginID.rawValue,
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let reload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-toggle")
        }
        await waitUntil {
            await gate.hasEntered
        }
        let toggle = Task { @MainActor in
            try await host.setEnabled(false, pluginID: pluginID)
            try await host.setEnabled(true, pluginID: pluginID)
        }
        await Task.yield()

        await gate.release()
        try await reload.value
        try await toggle.value

        let finalIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        XCTAssertEqual(
            finalIdentity.installationID,
            initialIdentity.installationID
        )
        XCTAssertEqual(
            finalIdentity.sessionRevision,
            initialIdentity.sessionRevision + 2
        )
        XCTAssertEqual(
            host.plugins.first(where: { $0.id == pluginID })?.isEnabled,
            true
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["reenabled"])
        await host.shutdown()
    }

    @MainActor
    func testCancelledQueuedReloadCompletesBeforeOwnerReleaseAndTailStillRuns() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.reload.cancel")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload-cancel",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let ownerGate = FakeStartGate()
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "v1"), for: pluginID)
        await controller.enqueue(
            .gated(status: "v2", gate: ownerGate),
            for: pluginID
        )
        await controller.enqueue(.active(status: "v4"), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let initialIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        try basicManifest(
            id: pluginID.rawValue,
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let ownerReload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-cancel")
        }
        await waitUntil {
            await ownerGate.hasEntered
        }

        try basicManifest(
            id: pluginID.rawValue,
            version: "3"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        let cancelledCompletion = FakeCompletionProbe()
        let cancelledReload = Task { @MainActor () -> Bool in
            let wasCancelled: Bool
            do {
                try await host.reload(directoryNamed: "reload-cancel")
                wasCancelled = false
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                wasCancelled = false
            }
            await cancelledCompletion.complete()
            return wasCancelled
        }
        await Task.yield()

        try basicManifest(
            id: pluginID.rawValue,
            version: "4"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        let tailReload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload-cancel")
        }
        await Task.yield()

        cancelledReload.cancel()
        await waitUntil {
            await cancelledCompletion.isComplete
        }
        let cancelledBeforeOwnerRelease = await cancelledCompletion.isComplete
        let runtimeCountBeforeOwnerRelease = await controller.runtimeCount()
        XCTAssertTrue(cancelledBeforeOwnerRelease)
        XCTAssertEqual(runtimeCountBeforeOwnerRelease, 2)

        await ownerGate.release()
        try await ownerReload.value
        let wasCancelled = await cancelledReload.value
        try await tailReload.value

        XCTAssertTrue(wasCancelled)
        let finalIdentity = try XCTUnwrap(
            host.sessionIdentity(for: pluginID)
        )
        XCTAssertEqual(
            finalIdentity.sessionRevision,
            initialIdentity.sessionRevision + 2
        )
        XCTAssertEqual(
            host.runtimeSnapshot(for: pluginID)?.manifest.version,
            "4"
        )
        XCTAssertEqual(host.statusItems.map(\.text), ["v4"])
        let finalRuntimeCount = await controller.runtimeCount()
        XCTAssertEqual(finalRuntimeCount, 3)
        await host.shutdown()
    }

    @MainActor
    func testDisablePersistsAcrossHostRestartAndReenableKeepsInstallation() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.toggle")
        try writePlugin(
            root: root,
            directoryName: "toggle",
            manifest: basicManifest(id: pluginID.rawValue)
        )

        let firstController = FakeRuntimeController()
        await firstController.enqueue(.active(status: nil), for: pluginID)
        let firstHost = try makeHost(
            root: root,
            controller: firstController
        )
        try await firstHost.loadAll()
        let firstIdentity = try XCTUnwrap(
            firstHost.sessionIdentity(for: pluginID)
        )
        try await firstHost.setEnabled(false, pluginID: pluginID)
        XCTAssertNil(firstHost.sessionIdentity(for: pluginID))
        XCTAssertEqual(
            firstHost.plugins.first(where: { $0.id == pluginID })?.isEnabled,
            false
        )
        await firstHost.shutdown()

        let secondController = FakeRuntimeController()
        await secondController.enqueue(.active(status: nil), for: pluginID)
        let secondHost = try makeHost(
            root: root,
            controller: secondController
        )
        try await secondHost.loadAll()
        XCTAssertNil(secondHost.sessionIdentity(for: pluginID))
        let disabledRuntimeCount = await secondController.runtimeCount()
        XCTAssertEqual(disabledRuntimeCount, 0)
        XCTAssertEqual(
            secondHost.plugins.first(where: { $0.id == pluginID })?
                .installationID,
            firstIdentity.installationID
        )

        try await secondHost.setEnabled(true, pluginID: pluginID)

        let reenabledIdentity = try XCTUnwrap(
            secondHost.sessionIdentity(for: pluginID)
        )
        XCTAssertEqual(
            reenabledIdentity.installationID,
            firstIdentity.installationID
        )
        XCTAssertEqual(
            reenabledIdentity.sessionRevision,
            firstIdentity.sessionRevision + 1
        )
        await secondHost.shutdown()
    }

    @MainActor
    func testUninstallLeavesDeclaredContractUnavailableAndReinstallGetsFreshIdentity() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.uninstall")
        let intentID = try IntentID("dev.test.uninstall.ping.v1")
        try writePlugin(
            root: root,
            directoryName: "uninstall",
            manifest: providerManifest(
                id: pluginID.rawValue,
                intent: intentID.rawValue
            )
        )
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: nil), for: pluginID)
        await controller.enqueue(.active(status: nil), for: pluginID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let oldIdentity = try XCTUnwrap(host.sessionIdentity(for: pluginID))

        try await host.uninstall(pluginID: pluginID)

        let palette = IntentPrincipal(
            id: "palette:plugin-host-tests",
            kind: .palette,
            sessionRevision: 1
        )
        let catalog = await host.kernel.dispatcher.discover(
            for: palette,
            projection: .catalog
        )
        let callable = await host.kernel.dispatcher.discover(
            for: palette,
            projection: .callable
        )
        let declaration = try XCTUnwrap(
            catalog.items.first(where: { $0.name == intentID })
        )
        XCTAssertFalse(declaration.isAvailable)
        XCTAssertFalse(callable.items.contains(where: { $0.name == intentID }))

        try await host.reload(directoryNamed: "uninstall")

        let newIdentity = try XCTUnwrap(host.sessionIdentity(for: pluginID))
        XCTAssertNotEqual(newIdentity.installationID, oldIdentity.installationID)
        XCTAssertEqual(newIdentity.sessionRevision, 1)
        await host.shutdown()
    }

    @MainActor
    func testShutdownIsConcurrentSafeAndIdempotent() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = PluginID("dev.test.shutdown.first")
        let secondID = PluginID("dev.test.shutdown.second")
        try writePlugin(
            root: root,
            directoryName: "first",
            manifest: basicManifest(id: firstID.rawValue)
        )
        try writePlugin(
            root: root,
            directoryName: "second",
            manifest: basicManifest(id: secondID.rawValue)
        )
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: nil), for: firstID)
        await controller.enqueue(.active(status: nil), for: secondID)
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let firstRuntime = try await controller.runtime(
            for: firstID,
            index: 0
        )
        let secondRuntime = try await controller.runtime(
            for: secondID,
            index: 0
        )

        let firstShutdown = Task { @MainActor in
            await host.shutdown()
        }
        let secondShutdown = Task { @MainActor in
            await host.shutdown()
        }
        await firstShutdown.value
        await secondShutdown.value
        await host.shutdown()

        XCTAssertTrue(host.loadedPluginIDs.isEmpty)
        let firstShutdownCount = await firstRuntime.shutdownCount()
        let secondShutdownCount = await secondRuntime.shutdownCount()
        XCTAssertEqual(firstShutdownCount, 1)
        XCTAssertEqual(secondShutdownCount, 1)
    }

    @MainActor
    func testShutdownWaitsForInFlightReloadAndClosesCommittedCandidate() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("dev.test.shutdown.reload")
        let directory = try writePlugin(
            root: root,
            directoryName: "reload",
            manifest: basicManifest(id: pluginID.rawValue, version: "1")
        )
        let gate = FakeStartGate()
        let controller = FakeRuntimeController()
        await controller.enqueue(.active(status: "old"), for: pluginID)
        await controller.enqueue(
            .gated(status: "new", gate: gate),
            for: pluginID
        )
        let host = try makeHost(root: root, controller: controller)
        try await host.loadAll()
        let oldRuntime = try await controller.runtime(
            for: pluginID,
            index: 0
        )
        try basicManifest(
            id: pluginID.rawValue,
            version: "2"
        ).write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let reload = Task { @MainActor in
            try await host.reload(directoryNamed: "reload")
        }
        await waitUntil {
            await gate.hasEntered
        }
        let shutdown = Task { @MainActor in
            await host.shutdown()
        }
        await Task.yield()
        let oldCountBeforeRelease = await oldRuntime.shutdownCount()
        XCTAssertEqual(oldCountBeforeRelease, 0)

        await gate.release()
        try await reload.value
        await shutdown.value

        let newRuntime = try await controller.runtime(
            for: pluginID,
            index: 1
        )
        let oldShutdownCount = await oldRuntime.shutdownCount()
        let newShutdownCount = await newRuntime.shutdownCount()
        XCTAssertEqual(oldShutdownCount, 1)
        XCTAssertEqual(newShutdownCount, 1)
        XCTAssertTrue(host.loadedPluginIDs.isEmpty)
    }
}

private extension PluginHostTests {
    func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-plugin-host-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    @discardableResult
    func writePlugin(
        root: URL,
        directoryName: String,
        manifest: String
    ) throws -> URL {
        let directory = root.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try manifest.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "// fake runtime does not evaluate JavaScript".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    func basicManifest(
        id: String,
        version: String = "1"
    ) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(id)",
          "version": "\(version)",
          "permissions": [],
          "intents": {
            "uses": [],
            "provides": []
          }
        }
        """
    }

    func providerManifest(
        id: String,
        intent: String,
        version: String = "1",
        key: String? = nil
    ) -> String {
        let keyField = key.map { #", "key": "\#($0)""# } ?? ""
        return """
        {
          "id": "\(id)",
          "name": "\(id)",
          "version": "\(version)",
          "intents": {
            "uses": [],
            "provides": [
              {
                "name": "\(intent)",
                "title": "Ping",
                "audiences": ["plugin", "palette"],
                "effects": {
                  "kind": "read",
                  "idempotency": "none",
                  "confirmation": "never",
                  "external": false
                },
                "inputSchema": {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "type": "object"
                },
                "outputSchema": {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "type": "object"
                },
                "palette": {
                  "category": "Tests",
                  "keywords": []\(keyField)
                }
              }
            ]
          }
        }
        """
    }

    @MainActor
    func makeHost(
        root: URL,
        controller: FakeRuntimeController
    ) throws -> PluginHost {
        let stateRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-state",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        return try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory,
            invocationScopeProvider: { InvocationScope() },
            runtimeFactory: PluginHostRuntimeFactory { configuration in
                try await controller.make(configuration: configuration)
            }
        )
    }

    @MainActor
    func waitUntil(
        attempts: Int = 1_000,
        predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0 ..< attempts {
            if await predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }
}

private enum FakeRuntimePlan: Sendable {
    case active(status: String?)
    case gated(status: String?, gate: FakeStartGate)
    case fail(String)
}

private enum FakeRuntimeError: Error, Sendable {
    case plannedFailure(String)
}

private actor FakeRuntimeController {
    private var plans: [PluginID: [FakeRuntimePlan]] = [:]
    private var runtimes: [PluginID: [FakePluginRuntime]] = [:]

    func enqueue(_ plan: FakeRuntimePlan, for pluginID: PluginID) {
        plans[pluginID, default: []].append(plan)
    }

    func make(
        configuration: PluginRuntimeConfiguration
    ) throws -> any PluginHostRuntime {
        let pluginID = configuration.manifest.id
        let plan = plans[pluginID]?.isEmpty == false
            ? plans[pluginID]!.removeFirst()
            : .active(status: nil)
        let runtime = FakePluginRuntime(
            configuration: configuration,
            plan: plan
        )
        runtimes[pluginID, default: []].append(runtime)
        return runtime
    }

    func runtimeCount() -> Int {
        runtimes.values.reduce(0) { $0 + $1.count }
    }

    func runtime(
        for pluginID: PluginID,
        index: Int
    ) throws -> FakePluginRuntime {
        guard let runtime = runtimes[pluginID]?[safe: index] else {
            throw FakeRuntimeError.plannedFailure(
                "missing fake runtime \(pluginID.rawValue)[\(index)]"
            )
        }
        return runtime
    }
}

private actor FakePluginRuntime: PluginHostRuntime {
    nonisolated let manifest: PluginManifest
    nonisolated let directory: URL

    private let plan: FakeRuntimePlan
    private let stateChange: PluginRuntimeConfiguration.StateChange
    private var phase: PluginRuntimePhase = .initialized
    private var revision: UInt64 = 0
    private var statusBarText: String?
    private var shutdownInvocationCount = 0
    private var emittedEvents: [String: [IntentValue]] = [:]

    init(
        configuration: PluginRuntimeConfiguration,
        plan: FakeRuntimePlan
    ) {
        manifest = configuration.manifest
        directory = configuration.directory
        stateChange = configuration.onStateChange
        self.plan = plan
    }

    func start() async throws -> PluginRuntimeStartResult {
        switch plan {
        case let .fail(diagnostic):
            phase = .failed
            throw FakeRuntimeError.plannedFailure(diagnostic)
        case let .gated(status, gate):
            await gate.enterAndWait()
            return makeStartResult(status: status)
        case let .active(status):
            return makeStartResult(status: status)
        }
    }

    private func makeStartResult(
        status: String?
    ) -> PluginRuntimeStartResult {
        phase = .active
        revision = 1
        statusBarText = status
        return PluginRuntimeStartResult(
            bindings: manifest.intents.provides.map { provision in
                IntentProviderBinding(intentID: provision.name) {
                    _, _ in .success(.object([:]))
                }
            },
            snapshot: makeSnapshot()
        )
    }

    func snapshot() -> PluginRuntimeSnapshot {
        makeSnapshot()
    }

    func handles(event _: String) -> Bool {
        true
    }

    func isViewInstanced(_: String) -> Bool {
        false
    }

    func emit(event: String, payload: IntentValue) throws {
        emittedEvents[event, default: []].append(payload)
    }

    func invokeViewSelect(
        viewID _: String,
        instanceID _: String?,
        itemID _: String,
        value _: IntentValue?
    ) throws -> Bool {
        false
    }

    func invokeViewSubmit(
        viewID _: String,
        instanceID _: String?,
        itemID _: String,
        text _: String
    ) throws -> Bool {
        false
    }

    func openViewInstance(
        viewID _: String,
        instanceID _: String
    ) throws {}

    func closeViewInstance(
        viewID _: String,
        instanceID _: String
    ) throws {}

    func shutdown(
        timeout _: TimeInterval
    ) -> PluginRuntimeShutdownReport {
        if phase != .stopped {
            shutdownInvocationCount += 1
            phase = .stopped
            revision += 1
        }
        return PluginRuntimeShutdownReport(
            executorResult: .stopped,
            createdThreadIdentifier: nil,
            destroyedThreadIdentifier: nil,
            cancelledProviderCalls: 0,
            lateProviderReplyCount: 0
        )
    }

    func emitStatus(_ text: String) async {
        revision += 1
        statusBarText = text
        await stateChange(makeSnapshot())
    }

    func fail() async {
        phase = .failed
        revision += 1
        await stateChange(makeSnapshot())
    }

    func emitStaleFailure() async {
        revision += 1
        await stateChange(makeSnapshot(phase: .failed))
    }

    func shutdownCount() -> Int {
        shutdownInvocationCount
    }

    func emittedPayloads(for event: String) -> [IntentValue] {
        emittedEvents[event] ?? []
    }

    private func makeSnapshot(
        phase phaseOverride: PluginRuntimePhase? = nil
    ) -> PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(
            revision: revision,
            manifest: manifest,
            phase: phaseOverride ?? phase,
            statusBarText: statusBarText,
            views: [],
            openViewInstances: [],
            permissionViolations: [],
            runtimeThreadIdentifier: nil,
            pendingNestedIntentCount: 0,
            lateProviderReplyCount: 0
        )
    }
}

private actor FakeStartGate {
    private(set) var hasEntered = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        hasEntered = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor FakeCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
