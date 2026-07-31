import Foundation
@testable import TenonApp
import XCTest

/// T-051. The control socket's two rules, which have never had a test.
///
/// They pull against each other, which is exactly why they are worth pinning: a stale socket
/// file left by a killed app must be reclaimed, and a socket a *live* app is listening on must
/// not be — that second one is T-009's single-instance guarantee. Reclaiming too eagerly would
/// let a second launch steal the socket out from under a running Tenon.
///
/// Every test binds a private path. The shipped app uses one well-known user-wide socket, and a
/// test that touched it would fight the developer's own running Tenon for the lock.
final class CLISocketServerTests: XCTestCase {
    /// The claim T-051 was wrongly filed on, now pinned so nobody re-files it: a socket file with
    /// nothing behind it is a leftover, not an owner.
    func testAStaleSocketFileIsReclaimed() throws {
        let path = try makePath()
        try leaveStaleSocketFile(at: path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "precondition: the stale file must really be there"
        )

        let server = CLISocketServer(overridingPath: path)

        XCTAssertEqual(server.role, .primary)
        XCTAssertEqual(server.socketPath, path)
        XCTAssertNil(
            server.degradation,
            "a leftover file is not a reason to run without a control socket"
        )
    }

    /// The other half. If this ever goes red because the reclamation above got more eager, the
    /// single-instance guarantee is gone and two apps are fighting over one socket.
    func testALiveListenerKeepsTheSocketAndTheNewcomerStandsDown() throws {
        let path = try makePath()
        let primary = CLISocketServer(overridingPath: path)
        // Assert the socket, not the role: a server that failed to bind is *also* `.primary`, so
        // checking the role alone would let a broken fixture pose as a running app.
        XCTAssertEqual(
            primary.socketPath,
            path,
            "precondition: the first server must actually hold the socket"
        )

        let secondary = CLISocketServer(overridingPath: path)

        XCTAssertEqual(
            secondary.role,
            .secondary,
            "a second launch must defer to the app already listening"
        )
        XCTAssertNil(
            secondary.socketPath,
            "a secondary owns no socket — it is about to exit"
        )
        XCTAssertNil(
            secondary.degradation,
            "standing down for a live instance is the design, not a degradation"
        )
        XCTAssertEqual(
            primary.socketPath,
            path,
            "the running app must keep the socket it bound"
        )
    }

    /// Silent degradation is the defect this card is actually about. The app may keep running
    /// without remote control; it may not do that without saying so.
    func testFailingToBindIsReportedRatherThanSwallowed() throws {
        // A path inside a file — not a directory — so the socket can never be created there, and
        // nothing is listening for the probe to find either.
        let blocker = try makePath()
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: blocker))
        let impossible = blocker + "/tenon.sock"

        let server = CLISocketServer(overridingPath: impossible)

        XCTAssertEqual(
            server.role,
            .primary,
            "the app keeps running — a terminal workspace is useful without remote control"
        )
        XCTAssertNil(server.socketPath)
        XCTAssertEqual(
            server.degradation,
            .bindFailed(path: impossible),
            "the reason must be recorded, and must name the path"
        )
        XCTAssertFalse(
            server.degradation?.message.isEmpty ?? true,
            "the reason must be sayable — this is what reaches the log"
        )
    }

    // MARK: - Fixture

    /// Deliberately `/tmp` and deliberately short, not `FileManager.temporaryDirectory`.
    ///
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, and the sandboxed temp directory alone
    /// (`/var/folders/<2>/<32>/T/`) spends about half of that — a UUID-named subdirectory under it
    /// produces a path `bind` rejects outright. That is a property of unix sockets, so the fixture
    /// has to respect it rather than work around it.
    private func makePath() throws -> String {
        let base = "/tmp/t051-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: base)
        }
        let path = "\(base)/tenon.sock"
        XCTAssertLessThan(
            path.utf8.count,
            104,
            "the fixture path must fit sun_path, or every test here fails for the wrong reason"
        )
        return path
    }

    /// Binds and immediately closes, which is what a killed app leaves behind: the filesystem
    /// entry survives, nothing answers a connect.
    private func leaveStaleSocketFile(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0, "could not create a unix socket")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // A hard failure, never a skip: a skipped fixture reads exactly like a passing test, and
        // an over-long path already silently turned this whole suite green once.
        XCTAssertLessThan(
            bytes.count,
            MemoryLayout.size(ofValue: address.sun_path),
            "path too long for sockaddr_un"
        )
        withUnsafeMutablePointer(to: &address.sun_path) { storage in
            storage.withMemoryRebound(
                to: CChar.self,
                capacity: bytes.count + 1
            ) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // `Darwin.bind` qualified deliberately: unqualified `bind` resolves to NSObject's Cocoa
        // Bindings method, which XCTestCase inherits.
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        XCTAssertEqual(bound, 0, "fixture failed to bind: \(String(cString: strerror(errno)))")
        close(fd)
    }
}
