import TenonIntentCore
import XCTest
@testable import TenonCore

final class KeyBindingIndexTests: XCTestCase {
    func testReservedShellBindingWinsWithTypedDiagnostic() throws {
        let request = try makeRequest(
            pluginID: "dev.tenon.git",
            intentID: "dev.tenon.git.refresh.v1",
            key: "cmd+shift+p"
        )
        let chord = try KeyChord(parsing: "cmd+shift+p")

        let index = KeyBindingIndex(
            requests: [request],
            reserved: KeyBindingIndex.shellReserved
        )

        XCTAssertEqual(index.bindings, [])
        XCTAssertEqual(
            index.diagnostics,
            [.reserved(request: request, chord: chord)]
        )
    }

    func testShellReservationDoesNotClaimPluginOwnedWorkspaceKeys() throws {
        for source in [
            "cmd+t",
            "cmd+d",
            "cmd+shift+d",
            "cmd+w",
            "cmd+shift+]",
            "cmd+shift+[",
            "cmd+]",
        ] {
            XCTAssertFalse(
                KeyBindingIndex.shellReserved.contains(
                    try KeyChord(parsing: source)
                ),
                "\(source) belongs to manifest-owned product intents"
            )
        }
        XCTAssertTrue(
            KeyBindingIndex.shellReserved.contains(
                try KeyChord(parsing: "cmd+shift+p")
            )
        )
    }

    func testPluginCollisionWinnerIsLexicalAndIndependentOfLoadOrder() throws {
        let alpha = try makeRequest(
            pluginID: "dev.tenon.alpha",
            intentID: "dev.tenon.alpha.open.v1",
            key: "cmd+shift+k"
        )
        let beta = try makeRequest(
            pluginID: "dev.tenon.beta",
            intentID: "dev.tenon.beta.open.v1",
            key: "shift+command+k"
        )
        let chord = try KeyChord(parsing: "cmd+shift+k")

        let forward = KeyBindingIndex(
            requests: [alpha, beta],
            reserved: []
        )
        let reverse = KeyBindingIndex(
            requests: [beta, alpha],
            reserved: []
        )

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(
            forward.binding(for: chord)?.target,
            alpha.target
        )
        XCTAssertNil(forward.binding(for: beta.target))
        XCTAssertEqual(
            forward.diagnostics,
            [
                .conflict(
                    request: beta,
                    winner: alpha.target,
                    chord: chord
                ),
            ]
        )
    }

    func testInvalidRequestProducesTypedDiagnosticWithoutBinding() throws {
        let request = try makeRequest(
            pluginID: "dev.tenon.git",
            intentID: "dev.tenon.git.refresh.v1",
            key: "git-refresh"
        )

        let index = KeyBindingIndex(requests: [request], reserved: [])

        XCTAssertEqual(index.bindings, [])
        XCTAssertEqual(
            index.diagnostics,
            [
                .invalid(
                    request: request,
                    error: .unknownToken("git-refresh")
                ),
            ]
        )
    }

    func testDistinctBindingsAreSortedByPluginThenIntent() throws {
        let requests = try [
            makeRequest(
                pluginID: "dev.tenon.beta",
                intentID: "dev.tenon.beta.open.v1",
                key: "cmd+b"
            ),
            makeRequest(
                pluginID: "dev.tenon.alpha",
                intentID: "dev.tenon.alpha.refresh.v1",
                key: "cmd+r"
            ),
            makeRequest(
                pluginID: "dev.tenon.alpha",
                intentID: "dev.tenon.alpha.open.v1",
                key: "cmd+o"
            ),
        ]

        let index = KeyBindingIndex(
            requests: requests.shuffled(),
            reserved: []
        )

        XCTAssertEqual(
            index.bindings.map(\.target),
            requests.map(\.target).sorted()
        )
        XCTAssertEqual(index.diagnostics, [])
    }

    private func makeRequest(
        pluginID: String,
        intentID: String,
        key: String
    ) throws -> KeyBindingRequest {
        KeyBindingRequest(
            target: KeyBindingTarget(
                pluginID: try PluginID(pluginID),
                intentID: try IntentID(intentID)
            ),
            rawKey: key
        )
    }
}
