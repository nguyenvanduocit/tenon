import Foundation
@testable import TenonIntentCore
import XCTest

final class IntentDispatchRuleTests: XCTestCase {
    func testJSONPointerExtractsEscapedObjectAndArrayPaths() throws {
        let capability = try CapabilityID("filesystem.read")
        let binding = IntentCapabilityBinding(
            capability: capability,
            filesystemPathPointers: [
                try IntentJSONPointer("/nested/a~1b/~0root"),
                try IntentJSONPointer("/paths/1"),
            ]
        )

        let requirements = try IntentDispatchRule(
            intentID: try IntentID("file.read.v1"),
            capabilityBindings: [binding],
            exposure: IntentExposure(
                discoverableBy: [.plugin],
                invocableBy: [.plugin]
            ),
            trustedDefault: nil,
            allowsAutomaticSelection: true,
            providerConsent: .never,
            admissionClass: .interactive
        ).capabilityRequirements(
            input: .object([
                "nested": .object([
                    "a/b": .object(["~root": .string("/repo/README.md")]),
                ]),
                "paths": .array([
                    .string("/repo/first"),
                    .string("/repo/second"),
                ]),
            ])
        )

        XCTAssertEqual(
            requirements,
            [
                CapabilityRequirement(
                    capability: capability,
                    filesystemPaths: ["/repo/README.md", "/repo/second"]
                ),
            ]
        )
    }

    func testJSONPointerRejectsInvalidEscapesAndNonCanonicalArrayIndices() throws {
        XCTAssertThrowsError(try IntentJSONPointer("relative"))
        XCTAssertThrowsError(try IntentJSONPointer("/bad~"))
        XCTAssertThrowsError(try IntentJSONPointer("/bad~2escape"))

        let binding = IntentCapabilityBinding(
            capability: try CapabilityID("filesystem.read"),
            filesystemPathPointers: [try IntentJSONPointer("/paths/01")]
        )
        let rule = try rule(capabilityBindings: [binding])

        XCTAssertThrowsError(
            try rule.capabilityRequirements(
                input: .object(["paths": .array([.string("/repo/file")])])
            )
        ) { error in
            XCTAssertEqual(
                error as? IntentDispatchRuleError,
                .missingPathValue("/paths/01")
            )
        }
    }

    func testPathBindingAcceptsStringArraysAndRejectsMixedValues() throws {
        let binding = IntentCapabilityBinding(
            capability: try CapabilityID("filesystem.read"),
            filesystemPathPointers: [try IntentJSONPointer("/paths")]
        )
        let rule = try rule(capabilityBindings: [binding])

        XCTAssertEqual(
            try rule.capabilityRequirements(
                input: .object([
                    "paths": .array([.string("/repo/a"), .string("/repo/b")]),
                ])
            ).first?.filesystemPaths,
            ["/repo/a", "/repo/b"]
        )
        XCTAssertThrowsError(
            try rule.capabilityRequirements(
                input: .object([
                    "paths": .array([.string("/repo/a"), .integer(1)]),
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? IntentDispatchRuleError,
                .pathValueIsNotString("/paths")
            )
        }
    }

    func testNetworkBindingCanonicalizesAbsoluteHTTPHosts() throws {
        let binding = IntentCapabilityBinding(
            capability: try CapabilityID("network.fetch"),
            networkURLPointers: [
                try IntentJSONPointer("/primary"),
                try IntentJSONPointer("/mirrors"),
            ]
        )
        let rule = try rule(capabilityBindings: [binding])

        XCTAssertEqual(
            try rule.capabilityRequirements(
                input: .object([
                    "primary": .string("https://Example.COM:443/data"),
                    "mirrors": .array([
                        .string("http://[2001:0db8:0:0:0:0:0:1]/index"),
                        .string("https://bücher.example/"),
                    ]),
                ])
            ).first?.networkHosts,
            ["example.com", "2001:db8::1", "xn--bcher-kva.example"]
        )
    }

    func testNetworkBindingRejectsAmbiguousOrNonHTTPURLs() throws {
        let binding = IntentCapabilityBinding(
            capability: try CapabilityID("network.fetch"),
            networkURLPointers: [try IntentJSONPointer("/url")]
        )
        let rule = try rule(capabilityBindings: [binding])

        for invalidURL in [
            "/relative",
            "file:///tmp/secret",
            "https://user:password@example.com/private",
            "https://example.com:99999/path",
            "https://example.com%2Fevil.test/path",
        ] {
            XCTAssertThrowsError(
                try rule.capabilityRequirements(
                    input: .object(["url": .string(invalidURL)])
                )
            ) { error in
                XCTAssertEqual(
                    error as? IntentDispatchRuleError,
                    .invalidNetworkURL(pointer: "/url", value: invalidURL)
                )
            }
        }

        XCTAssertThrowsError(
            try rule.capabilityRequirements(
                input: .object(["url": .array([.string("https://example.com"), .integer(1)])])
            )
        ) { error in
            XCTAssertEqual(
                error as? IntentDispatchRuleError,
                .networkURLValueIsNotString("/url")
            )
        }
    }

    func testDispatcherLimitsRejectUnusableReserveAndTimeoutConfigurations() throws {
        XCTAssertThrowsError(
            try IntentDispatcherLimits(
                maxInFlightRequests: 1,
                reservedInteractiveRequests: 1
            )
        )
        XCTAssertThrowsError(
            try IntentDispatcherLimits(
                maxInFlightEncodedBytes: 1,
                reservedInteractiveBytes: 1
            )
        )
        XCTAssertThrowsError(try IntentDispatcherLimits(maximumTimeout: .zero))
        XCTAssertThrowsError(try IntentDispatcherLimits(maximumCausalDepth: 0))
        XCTAssertNoThrow(try IntentDispatcherLimits(progressMinimumInterval: .zero))
    }

    private func rule(
        capabilityBindings: [IntentCapabilityBinding]
    ) throws -> IntentDispatchRule {
        try IntentDispatchRule(
            intentID: IntentID("file.read.v1"),
            capabilityBindings: capabilityBindings,
            exposure: IntentExposure(
                discoverableBy: [.plugin],
                invocableBy: [.plugin]
            ),
            trustedDefault: nil,
            allowsAutomaticSelection: true,
            providerConsent: .never,
            admissionClass: .interactive
        )
    }
}
