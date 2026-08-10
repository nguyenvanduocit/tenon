import Foundation
@testable import TenonApp
import TenonIntentCore
import XCTest

/// T-051. The control socket's two rules, which have never had a test.
///
/// They pull against each other, which is exactly why they are worth pinning: a stale socket
/// file left by a killed app must be reclaimed, and a socket a *live* app is listening on must
/// not be — that second one is T-009's single-instance guarantee. Reclaiming too eagerly would
/// let a second launch steal the socket out from under a running Tenon.
///
/// Every test binds a private path. Each shipped channel uses a well-known user-wide socket, and
/// a test that touched either would fight the developer's own running Tenon for the lock.
final class CLISocketServerTests: XCTestCase {
    func testInstalledBundleIdentifiersResolveTheClosedInstanceChannels() throws {
        XCTAssertEqual(AppInstanceChannel.allCases, [.production, .staging])
        XCTAssertEqual(
            try AppInstanceChannel.resolve(
                bundleIdentifier: "dev.tenon.app",
                isApplicationBundle: true
            ),
            .production
        )
        XCTAssertEqual(
            try AppInstanceChannel.resolve(
                bundleIdentifier: "dev.tenon.app.staging",
                isApplicationBundle: true
            ),
            .staging
        )
        XCTAssertEqual(
            try AppInstanceChannel.resolve(
                bundleIdentifier: nil,
                isApplicationBundle: false
            ),
            .production,
            "swift run and test hosts retain the production-compatible default"
        )
        XCTAssertThrowsError(
            try AppInstanceChannel.resolve(
                bundleIdentifier: "com.example.unrecognized-tenon",
                isApplicationBundle: true
            )
        )
    }

    func testProductionAndStagingCanBothOwnTheirSingletonChannels() throws {
        let root = try makeDirectory(permissions: 0o700)
        let production = CLISocketServer(
            instanceChannel: .production,
            socketRootForTesting: root
        )
        let staging = CLISocketServer(
            instanceChannel: .staging,
            socketRootForTesting: root
        )

        XCTAssertEqual(production.role, .primary)
        XCTAssertEqual(staging.role, .primary)
        XCTAssertNotNil(production.socketPath)
        XCTAssertNotNil(staging.socketPath)
        XCTAssertNotEqual(production.socketPath, staging.socketPath)

        let secondStaging = CLISocketServer(
            instanceChannel: .staging,
            socketRootForTesting: root
        )
        XCTAssertEqual(secondStaging.role, .secondary)
        XCTAssertNil(secondStaging.socketPath)
    }

    func testDegradedStagingClientPathNeverFallsBackToProduction() {
        let degradedStaging = CLISocketServer(
            enabled: false,
            instanceChannel: .staging
        )

        XCTAssertNil(degradedStaging.socketPath)
        XCTAssertEqual(
            degradedStaging.clientSocketPath,
            AppInstanceChannel.staging.socketPath()
        )
        XCTAssertNotEqual(
            degradedStaging.clientSocketPath,
            AppInstanceChannel.production.socketPath()
        )
    }

    func testSingleInstanceClaimCoversTheBindListenWindow() throws {
        let path = try makePath()
        let socketBound = DispatchSemaphore(value: 0)
        let allowSocketSetup = DispatchSemaphore(value: 0)
        let primaryInitialized = DispatchSemaphore(value: 0)
        let primaryBox = ServerBox()

        DispatchQueue.global(qos: .userInitiated).async {
            let server = CLISocketServer(
                overridingPath: path,
                afterBindBeforeListenForTesting: {
                    socketBound.signal()
                    allowSocketSetup.wait()
                }
            )
            primaryBox.store(server)
            primaryInitialized.signal()
        }

        XCTAssertEqual(
            socketBound.wait(timeout: .now() + 2),
            .success,
            "precondition: the first launch must pause after bind but before listen"
        )

        // Let the secondary enter its bounded activation retry while the primary still owns the
        // claim but cannot yet accept. This is the exact startup window the retry protects.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            allowSocketSetup.signal()
        }
        let secondary = CLISocketServer(overridingPath: path)

        XCTAssertEqual(
            secondary.role,
            .secondary,
            "a contender must stand down even before the primary starts listening"
        )
        XCTAssertNil(secondary.socketPath)

        XCTAssertEqual(primaryInitialized.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            primaryBox.load()?.socketPath,
            path,
            "the claim owner must retain the well-known socket"
        )
    }

    func testSocketDirectoryMustBeOwnedByTheExpectedUser() throws {
        let directory = try makeDirectory(permissions: 0o700)

        XCTAssertFalse(
            CLISocketServer.prepareSocketDirectory(
                at: directory,
                expectedOwner: getuid() &+ 1
            ),
            "a predictable /tmp directory owned by another account must never carry the control socket"
        )
    }

    func testSocketDirectoryRejectsGroupOrWorldAccess() throws {
        let directory = try makeDirectory(permissions: 0o755)

        XCTAssertFalse(
            CLISocketServer.prepareSocketDirectory(at: directory, expectedOwner: getuid()),
            "the CLI can carry policy-gated requests, so its directory must remain private"
        )
    }

    func testSocketDirectoryRejectsASymlink() throws {
        let target = try makeDirectory(permissions: 0o700)
        let link = "/tmp/t051-link-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: link)
        }

        XCTAssertFalse(
            CLISocketServer.prepareSocketDirectory(at: link, expectedOwner: getuid()),
            "lstat must reject a symlink even when its destination looks secure"
        )
    }

    func testSocketDirectoryIsCreatedPrivateWhenAbsent() throws {
        let parent = try makeDirectory(permissions: 0o700)
        let directory = "\(parent)/socket-directory"

        XCTAssertTrue(
            CLISocketServer.prepareSocketDirectory(at: directory, expectedOwner: getuid())
        )
        var information = stat()
        XCTAssertEqual(lstat(directory, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(0o777), mode_t(0o700))
    }

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

    func testARegularFileAtTheSocketPathIsPreserved() throws {
        let path = try makePath()
        let sentinel = Data("do-not-delete".utf8)
        try sentinel.write(to: URL(fileURLWithPath: path))

        let server = CLISocketServer(overridingPath: path)

        XCTAssertNil(server.socketPath)
        XCTAssertEqual(server.degradation, .bindFailed(path: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), sentinel)
    }

    func testASymlinkAtTheSocketPathIsPreserved() throws {
        let path = try makePath()
        let target = "\(path).target"
        let sentinel = Data("do-not-follow".utf8)
        try sentinel.write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        let server = CLISocketServer(overridingPath: path)

        XCTAssertNil(server.socketPath)
        XCTAssertEqual(server.degradation, .bindFailed(path: path))
        var information = stat()
        XCTAssertEqual(lstat(path, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), sentinel)
    }

    func testAReleasedClaimIsReusableAfterThePrimaryStops() throws {
        let path = try makePath()
        var first: CLISocketServer? = CLISocketServer(overridingPath: path)
        XCTAssertEqual(first?.socketPath, path)

        first = nil

        let replacement = CLISocketServer(overridingPath: path)
        XCTAssertEqual(replacement.role, .primary)
        XCTAssertEqual(replacement.socketPath, path)
        XCTAssertNil(replacement.degradation)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: claimPath(for: path)),
            "the stable lock inode remains reusable after a crash or orderly shutdown"
        )
    }

    func testAnUnsafeClaimSymlinkIsRejectedAndPreserved() throws {
        let path = try makePath()
        let claimPath = claimPath(for: path)
        let target = "\(claimPath).target"
        let sentinel = Data("claim-target".utf8)
        try sentinel.write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: claimPath, withDestinationPath: target)

        let server = CLISocketServer(overridingPath: path)

        XCTAssertNil(server.socketPath)
        XCTAssertEqual(server.role, .unavailable)
        XCTAssertEqual(server.degradation, .claimUnavailable(path: claimPath))
        var information = stat()
        XCTAssertEqual(lstat(claimPath, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), sentinel)
    }

    func testAClaimWithBroadPermissionsIsRejectedAndPreserved() throws {
        let path = try makePath()
        let claimPath = claimPath(for: path)
        let sentinel = Data("private-claim".utf8)
        try sentinel.write(to: URL(fileURLWithPath: claimPath))
        XCTAssertEqual(chmod(claimPath, 0o644), 0)

        let server = CLISocketServer(overridingPath: path)

        XCTAssertNil(server.socketPath)
        XCTAssertEqual(server.role, .unavailable)
        XCTAssertEqual(server.degradation, .claimUnavailable(path: claimPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: claimPath)), sentinel)
        var information = stat()
        XCTAssertEqual(lstat(claimPath, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(0o777), mode_t(0o644))
    }

    func testANonRegularClaimPathIsRejectedAndPreserved() throws {
        let path = try makePath()
        let claimPath = claimPath(for: path)
        XCTAssertEqual(mkdir(claimPath, 0o600), 0)

        let server = CLISocketServer(overridingPath: path)

        XCTAssertNil(server.socketPath)
        XCTAssertEqual(server.role, .unavailable)
        XCTAssertEqual(server.degradation, .claimUnavailable(path: claimPath))
        var information = stat()
        XCTAssertEqual(lstat(claimPath, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))
    }

    /// The other half. If this ever goes red because the reclamation above got more eager, the
    /// same-channel single-instance guarantee is gone and two apps are fighting over one socket.
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

    func testSocketSymlinkCannotRedirectActivationAcrossChannels() throws {
        let productionPath = try makePath()
        let production = CLISocketServer(overridingPath: productionPath)
        XCTAssertEqual(production.socketPath, productionPath)

        let stagingPath = try makePath()
        try FileManager.default.createSymbolicLink(
            atPath: stagingPath,
            withDestinationPath: productionPath
        )

        let staging = CLISocketServer(overridingPath: stagingPath)

        XCTAssertEqual(staging.role, .primary)
        XCTAssertEqual(staging.degradation, .bindFailed(path: stagingPath))
        XCTAssertNil(staging.socketPath)
        var information = stat()
        XCTAssertEqual(lstat(stagingPath, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
    }

    /// Silent degradation is the defect this card is actually about. The app may keep running
    /// without remote control; it may not do that without saying so.
    func testFailingToBindIsReportedRatherThanSwallowed() throws {
        // The containing directory is valid, but sockaddr_un cannot represent this path.
        let base = try makeDirectory(permissions: 0o700)
        let impossible = "\(base)/\(String(repeating: "x", count: 110))"

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

    // MARK: - Request permits (T-093)

    /// The cap is the app's whole physical exposure to `tenon-cli`, not its decode phase.
    ///
    /// The permit used to be released as soon as a request had been posted to the main actor,
    /// while its descriptor and its pending intent reply were still very much alive. Valid slow
    /// requests could therefore accumulate without limit behind a semaphore that read as free —
    /// the flood this test refuses is the one that looked legitimate at every individual step.
    func testTheRequestCapCoversTheReplyNotOnlyTheDecode() throws {
        let path = try makePath()
        let server = CLISocketServer(
            overridingPath: path,
            admissionGraceForTesting: 0.05,
            requestLifetimeForTesting: 30
        )
        XCTAssertEqual(server.socketPath, path, "precondition: the server must hold the socket")

        let cap = CLISocketServer.maximumConcurrentConnections
        let pending = PendingCompletions()
        let admitted = expectation(description: "every permit is taken")
        admitted.expectedFulfillmentCount = cap
        server.onRequest = { _, complete in
            pending.store(complete)
            admitted.fulfill()
        }

        var clients: [Int32] = []
        for index in 0 ..< cap {
            clients.append(try connectAndSend(to: path, id: "req-\(index)"))
        }
        wait(for: [admitted], timeout: 10)
        XCTAssertEqual(
            server.liveConnectionCount,
            cap,
            "each unanswered request must still hold its permit"
        )

        // The overflow client is answered rather than parked: refusing is what keeps the
        // descriptor count bounded when every in-flight request is legitimate but slow.
        let refused = try connectAndSend(to: path, id: "overflow")
        let response = try readResponse(refused)
        close(refused)
        guard case let .failure(_, error) = response else {
            return XCTFail("an over-cap request must fail, got \(String(describing: response))")
        }
        XCTAssertEqual(error.code, .busy)
        XCTAssertEqual(
            server.liveConnectionCount,
            cap,
            "a refused request must not consume a permit"
        )

        pending.completeAll(.ok(.object(["ok": .bool(true)])))
        for client in clients {
            let reply = try readResponse(client)
            close(client)
            guard case .success = reply else {
                return XCTFail("an answered request must receive its result, got \(String(describing: reply))")
            }
        }
        waitUntil("every permit is returned") { server.liveConnectionCount == 0 }

        // And the channel is usable again, which is what makes the cap backpressure rather
        // than a one-way ratchet.
        let after = expectation(description: "a request is admitted again")
        server.onRequest = { _, complete in
            complete(.ok(.object([:])))
            after.fulfill()
        }
        let reopened = try connectAndSend(to: path, id: "after")
        wait(for: [after], timeout: 10)
        close(reopened)
    }

    /// A handler that never answers must not retire a permit for the life of the process.
    func testAnUnansweredRequestReturnsItsPermitAtTheLifetimeLimit() throws {
        let path = try makePath()
        let server = CLISocketServer(
            overridingPath: path,
            admissionGraceForTesting: 0.05,
            requestLifetimeForTesting: 0.3
        )
        XCTAssertEqual(server.socketPath, path)

        let abandoned = PendingCompletions()
        let admitted = expectation(description: "the request reaches the handler")
        server.onRequest = { _, complete in
            abandoned.store(complete)
            admitted.fulfill()
        }

        let client = try connectAndSend(to: path, id: "never-answered")
        wait(for: [admitted], timeout: 10)

        let response = try readResponse(client)
        close(client)
        guard case let .failure(_, error) = response else {
            return XCTFail("an abandoned request must be settled, got \(String(describing: response))")
        }
        XCTAssertEqual(error.code, .internalError)
        waitUntil("the abandoned permit is returned") { server.liveConnectionCount == 0 }
    }

    // MARK: - Fixture

    /// Deliberately `/tmp` and deliberately short, not `FileManager.temporaryDirectory`.
    ///
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, and the sandboxed temp directory alone
    /// (`/var/folders/<2>/<32>/T/`) spends about half of that — a UUID-named subdirectory under it
    /// produces a path `bind` rejects outright. That is a property of unix sockets, so the fixture
    /// has to respect it rather than work around it.
    private func makePath() throws -> String {
        let base = try makeDirectory(permissions: 0o700)
        let path = "\(base)/tenon.sock"
        XCTAssertLessThan(
            path.utf8.count,
            104,
            "the fixture path must fit sun_path, or every test here fails for the wrong reason"
        )
        return path
    }

    private func makeDirectory(permissions: Int) throws -> String {
        let base = "/tmp/t051-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        XCTAssertEqual(chmod(base, mode_t(permissions)), 0)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: base)
        }
        return base
    }

    /// Connects a real client and writes one framed `ping`, then hands back the descriptor so
    /// the test controls when — and whether — the reply is read.
    private func connectAndSend(to path: String, id: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0, "could not create a client socket")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { storage in
            storage.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        XCTAssertEqual(connected, 0, "client connect failed: \(String(cString: strerror(errno)))")

        var payload = try CLIWireCodec.encodeRequest(CLIRequest(id: id, action: "ping"))
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < payload.count {
                let written = write(fd, base + offset, payload.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        return fd
    }

    private func readResponse(_ fd: Int32, timeout: TimeInterval = 10) throws -> CLIResponse? {
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if let newline = chunk[0 ..< count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0 ..< newline])
                break
            }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
        guard !buffer.isEmpty else { return nil }
        return CLIWireCodec.decodeResponse(buffer)
    }

    /// Pumps the main runloop, because the request path deliberately hops through the main actor
    /// and a blocked test thread would be indistinguishable from the bug.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func claimPath(for socketPath: String) -> String {
        let directory = (socketPath as NSString).deletingLastPathComponent
        return "\(directory)/tenon.lock"
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

/// Holds the completions a test handler was given, so a request can be left deliberately
/// unanswered — the state the permit has to survive.
private final class PendingCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [(CLIResult) -> Void] = []

    func store(_ completion: @escaping (CLIResult) -> Void) {
        lock.withLock { completions.append(completion) }
    }

    func completeAll(_ result: CLIResult) {
        let all = lock.withLock { () -> [(CLIResult) -> Void] in
            let pending = completions
            completions = []
            return pending
        }
        for completion in all { completion(result) }
    }
}

private final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var server: CLISocketServer?

    func store(_ server: CLISocketServer) {
        lock.withLock {
            self.server = server
        }
    }

    func load() -> CLISocketServer? {
        lock.withLock { server }
    }
}
