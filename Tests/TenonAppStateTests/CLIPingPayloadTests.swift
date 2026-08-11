@testable import TenonApp
@testable import TenonIntentCore
import Foundation
import XCTest

/// T-132 (e): `ping` answers what a script needs to know before it does anything else —
/// which build is running and where its control socket is — and still answers nothing about
/// whether any provider is ready.
///
/// `CLI-FR-014` draws that line, and `docs/design-cli.md:186` says the same: a successful
/// ping proves the control socket is live and the process is up, and no more. Widening the
/// payload is only safe while every added field is a fact about the *process*, so this test
/// pins the exact key set rather than only the additions.
final class CLIPingPayloadTests: XCTestCase {
    func testPingReportsProcessIdentityBuildAndSocketPath() throws {
        let payload = CLICommandExecutor.pingPayload(
            protocolVersion: 3,
            processID: 4242,
            isActive: true,
            version: AppVersion(short: "0.1.0", build: "17"),
            socketPath: "/tmp/tenon-501/tenon.sock"
        )
        XCTAssertEqual(
            payload,
            .object([
                "protocolVersion": .integer(3),
                "pid": .integer(4242),
                "active": .bool(true),
                "version": .string("0.1.0"),
                "build": .string("17"),
                "socketPath": .string("/tmp/tenon-501/tenon.sock"),
            ])
        )
    }

    /// A `swift run tenon` build carries no `Info.plist` version keys. Reporting the em dash
    /// `AppVersion` already uses for that case keeps one rendering of "unknown" in the
    /// product instead of minting a second one on the wire.
    func testAnUnversionedBuildSaysSoRatherThanReportingZero() throws {
        let payload = CLICommandExecutor.pingPayload(
            protocolVersion: 3,
            processID: 1,
            isActive: false,
            version: AppVersion.read(from: Bundle(for: Self.self)),
            socketPath: "/tmp/tenon-501/tenon.sock"
        )
        guard case let .object(fields) = payload else {
            return XCTFail("ping must answer an object")
        }
        XCTAssertEqual(fields["version"], .string(AppVersion.unknown))
        XCTAssertEqual(fields["build"], .string(AppVersion.unknown))
    }

    /// The widening stops here. Anything about contracts, providers, plugins, or health
    /// belongs to `intent.list` and to the monitor `DRM-FR-043` keeps out of the CLI —
    /// a caller must not be able to read readiness out of a liveness probe.
    func testPingClaimsNothingAboutProviderOrPluginReadiness() throws {
        let payload = CLICommandExecutor.pingPayload(
            protocolVersion: 3,
            processID: 7,
            isActive: false,
            version: AppVersion(short: "0.1.0", build: "17"),
            socketPath: "/tmp/tenon-501/tenon.sock"
        )
        guard case let .object(fields) = payload else {
            return XCTFail("ping must answer an object")
        }
        XCTAssertEqual(
            Set(fields.keys),
            [
                "protocolVersion",
                "pid",
                "active",
                "version",
                "build",
                "socketPath",
            ]
        )
        for forbidden in [
            "ready",
            "providers",
            "intents",
            "plugins",
            "health",
            "cpu",
            "memory",
        ] {
            XCTAssertNil(fields[forbidden], forbidden)
        }
    }

    /// The path ping reports is the one the server binds: both derive it from the same
    /// resolved channel, so a staging app can never answer with production's socket.
    func testTheReportedSocketPathIsTheChannelTheServerBinds() throws {
        for channel in AppInstanceChannel.allCases {
            XCTAssertEqual(
                CLICommandExecutor.pingSocketPath(for: channel),
                channel.socketPath(),
                channel.rawValue
            )
        }
        XCTAssertNotEqual(
            AppInstanceChannel.production.socketPath(),
            AppInstanceChannel.staging.socketPath()
        )
    }
}
