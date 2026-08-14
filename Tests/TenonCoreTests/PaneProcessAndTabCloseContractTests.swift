import Foundation
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// T-132 (a) and (c): two answers the app already holds and no caller outside the host
/// could ask for.
///
/// `SurfacePool.terminalProvenance(for:)` has published `(ttyName, foregroundPID)` per
/// pane since the resource monitor needed it, and `WorkspaceCatalog.closeTab` has closed
/// tabs since the tab bar had a close button. Both were reachable only from Swift inside
/// the app bundle. These assertions pin the two contracts that open them to the `cli`
/// audience — shape, authority, capability, and lane — without a window.
final class PaneProcessAndTabCloseContractTests: XCTestCase {
    // MARK: - (a) terminal.process.read.v1

    func testProcessReadNamesTheProcessAndAsksForNothingButTerminalRead() throws {
        let name = try XCTUnwrap(
            CoreIntentName(rawValue: "terminal.process.read.v1"),
            "terminal.process.read.v1 is not in the closed core inventory"
        )
        let definition = try definition(name)
        let contract = definition.declaration

        XCTAssertEqual(contract.audiences, [.plugin, .cli, .agent])
        XCTAssertEqual(name.audienceProfile, .programmatic)
        XCTAssertEqual(name.executionLane, .terminalImmediate)

        // A read of what is already running effects nothing, so it may not be gated behind
        // a prompt: `confirmation: .never` is the whole difference between a supervision
        // primitive and a dialog a script cannot answer.
        XCTAssertEqual(contract.effects.kind, .read)
        XCTAssertEqual(contract.effects.confirmation, .never)
        XCTAssertFalse(contract.effects.external)

        XCTAssertEqual(
            definition.dispatchRule.capabilityBindings.map(\.capability.rawValue),
            ["terminal.read"],
            "process provenance is a terminal read and must ask for nothing wider"
        )

        XCTAssertEqual(
            try propertyNames(contract.inputSchema),
            [],
            "the pane comes from invocation scope, not from input"
        )
        XCTAssertEqual(
            try propertyNames(contract.outputSchema),
            ["foregroundPID", "paneID", "ttyName"]
        )
        XCTAssertEqual(
            try requiredNames(contract.outputSchema),
            ["foregroundPID", "paneID", "ttyName"],
            """
            A pane that has never materialised has no PTY and no foreground process. \
            Both fields are required and nullable so the answer says "not known" \
            explicitly rather than by omitting a key.
            """
        )
    }

    // MARK: - (c) workspace.tab.close.v1

    func testTabCloseIsDestructiveUnderPolicyAndDeclaresItsRefusal() throws {
        let name = try XCTUnwrap(
            CoreIntentName(rawValue: "workspace.tab.close.v1"),
            "workspace.tab.close.v1 is not in the closed core inventory"
        )
        let definition = try definition(name)
        let contract = definition.declaration

        XCTAssertEqual(contract.audiences, [.plugin, .cli, .agent])
        XCTAssertEqual(name.audienceProfile, .programmatic)
        XCTAssertEqual(name.executionLane, .workspace)

        // Exactly `workspace.pane.close.v2`'s classification: closing a tab destroys every
        // pane under it, and standing consent — not a dialog per call — is the gate.
        XCTAssertEqual(contract.effects.kind, .destructive)
        XCTAssertEqual(contract.effects.confirmation, .policy)

        XCTAssertEqual(
            definition.dispatchRule.capabilityBindings.map(\.capability.rawValue),
            ["workspace.control"]
        )
        XCTAssertEqual(try propertyNames(contract.inputSchema), [])
        XCTAssertEqual(try propertyNames(contract.outputSchema), [])

        // The refusal is declared, not implied. `WorkspaceCatalog.closeTab` returns no
        // events for a workspace's only tab (`Workspace.swift:613`), and a scripted caller
        // meets that case first: it must come back as a named domain error rather than as
        // a success that closed nothing.
        XCTAssertEqual(
            Set(contract.domainErrors.map(\.rawValue)),
            [
                "dev.tenon.core.tab-not-found",
                "dev.tenon.core.close-refused",
            ]
        )
    }

    /// Both new contracts are sealed, trusted-provider, and inside the shared bounds every
    /// other core intent obeys — the checks the catalog's own coherence test applies to the
    /// whole table, asserted here for the two entries this task adds.
    func testBothNewContractsObeyTheSharedCoreRules() throws {
        let trusted = try CoreIntentCatalog.trustedProviderID()
        for raw in ["terminal.process.read.v1", "workspace.tab.close.v1"] {
            let name = try XCTUnwrap(CoreIntentName(rawValue: raw), raw)
            let definition = try definition(name)
            XCTAssertEqual(definition.declaration.contractClass, .sealed, raw)
            XCTAssertEqual(definition.dispatchRule.trustedDefault, trusted, raw)
            XCTAssertEqual(definition.dispatchRule.valueLimits, .default, raw)
            XCTAssertGreaterThan(definition.dispatchRule.maximumTimeout, .zero, raw)
            XCTAssertLessThanOrEqual(
                definition.dispatchRule.maximumTimeout,
                .seconds(60),
                raw
            )
            XCTAssertEqual(
                definition.dispatchRule.exposure.invocableBy,
                definition.declaration.audiences,
                raw
            )
        }
    }
}

private extension PaneProcessAndTabCloseContractTests {
    func definition(_ name: CoreIntentName) throws -> CoreIntentDefinition {
        try XCTUnwrap(
            try CoreIntentCatalog.definitions().first {
                $0.declaration.name.rawValue == name.rawValue
            },
            "\(name.rawValue) has no definition in the core table"
        )
    }

    func propertyNames(_ schema: IntentValue) throws -> [String] {
        let object = try XCTUnwrap(schema.objectValue)
        let properties = object["properties"]?.objectValue ?? [:]
        return properties.keys.sorted()
    }

    func requiredNames(_ schema: IntentValue) throws -> [String] {
        let object = try XCTUnwrap(schema.objectValue)
        guard case let .array(required)? = object["required"] else { return [] }
        return required.compactMap { value in
            if case let .string(name) = value { return name }
            return nil
        }.sorted()
    }
}
