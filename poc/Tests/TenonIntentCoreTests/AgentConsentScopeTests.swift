import Foundation
@testable import TenonIntentCore
import XCTest

/// Standing consent answers "may this caller do this kind of thing". For a delegable
/// contract the danger is the payload, not the kind — so an agent, whose payload can be
/// written by whatever page it just read, re-asks every time.
/// See `docs/design-open-handlers.md`.
final class AgentConsentScopeTests: XCTestCase {
    func testAnAgentReAsksEveryTimeForADelegableContract() async throws {
        let contract = try await makeContract(contractClass: .open, confirmation: .policy)

        XCTAssertEqual(
            IntentDispatcher.effectiveConfirmation(
                contract: contract,
                caller: principal(.agent)
            ),
            .always
        )
    }

    /// Every other caller keeps standing consent. A person clicking a file in the explorer
    /// answers once, not once per file.
    func testOtherCallersKeepStandingConsent() async throws {
        let contract = try await makeContract(contractClass: .open, confirmation: .policy)

        for kind in IntentPrincipal.Kind.allCases where kind != .agent {
            XCTAssertEqual(
                IntentDispatcher.effectiveConfirmation(
                    contract: contract,
                    caller: principal(kind)
                ),
                .policy,
                "\(kind) lost its standing consent"
            )
        }
    }

    /// The narrowing is keyed on the contract class, not on the audience alone. An agent
    /// writing to a terminal or fetching a URL still answers once — those are sealed
    /// contracts whose authority is the kind of operation, and re-asking would make an
    /// agent unusable rather than safer.
    func testASealedContractIsUnaffectedForEveryCaller() async throws {
        let contract = try await makeContract(contractClass: .sealed, confirmation: .policy)

        for kind in IntentPrincipal.Kind.allCases {
            XCTAssertEqual(
                IntentDispatcher.effectiveConfirmation(
                    contract: contract,
                    caller: principal(kind)
                ),
                .policy,
                "\(kind) was narrowed on a sealed contract"
            )
        }
    }

    /// A contract that never confirms is not turned into one that does, and one that
    /// already always confirms is unchanged.
    func testTheRuleOnlyNarrowsPolicy() async throws {
        for confirmation in [IntentConfirmation.never, .always] {
            let contract = try await makeContract(
                contractClass: .open,
                confirmation: confirmation
            )
            XCTAssertEqual(
                IntentDispatcher.effectiveConfirmation(
                    contract: contract,
                    caller: principal(.agent)
                ),
                confirmation
            )
        }
    }

    private func principal(_ kind: IntentPrincipal.Kind) -> IntentPrincipal {
        IntentPrincipal(id: "test:\(kind.rawValue)", kind: kind, sessionRevision: 1)
    }

    private func makeContract(
        contractClass: IntentContractClass,
        confirmation: IntentConfirmation
    ) async throws -> IntentContract {
        let declaration = IntentContractDeclaration(
                name: try IntentID("url.open.v1"),
                contractClass: contractClass,
                owner: .core,
                inputSchema: .object([
                    "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                ]),
                outputSchema: .object([
                    "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                ]),
                audiences: [.plugin, .cli, .agent],
                effects: try IntentEffects(
                    kind: .write,
                    idempotency: .none,
                    retentionMilliseconds: nil,
                    confirmation: confirmation,
                    external: true
                ),
                title: "Open address",
                description: "test fixture",
                deprecated: false,
                domainErrors: []
            )
        let compiler = IntentSchemaCompiler()
        async let input = compiler.compile(declaration.inputSchema)
        async let output = compiler.compile(declaration.outputSchema)
        return try await IntentContract(
            declaration: declaration,
            inputSchema: input,
            outputSchema: output
        )
    }
}
