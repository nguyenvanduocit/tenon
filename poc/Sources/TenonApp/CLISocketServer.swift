// @domain: cli-control
import Foundation
import TenonCore
import TenonIntentCore

/// The CLI control socket and its sibling advisory lock enforce Tenon's per-channel
/// single-instance rule. Production keeps `/tmp/tenon-<uid>/tenon.sock`; staging owns a
/// separate namespace. Whoever holds that channel's `tenon.lock` may create or reclaim its
/// socket; a second launch in the same channel tells that primary to come to the front and exits.
///
/// Threading: a dedicated background thread runs the blocking `accept`/`read` loop; each valid
/// request hops to the main actor via `onRequest`; the resulting async intent dispatch holds only
/// its own client fd open, never the accept loop.
///
/// Security is local-trust: the socket dir is `0o700`, the socket file `0o600`, and both the
/// listening and accepted fds are `FD_CLOEXEC`, so the control channel never leaks into a spawned PTY.
/// Safety invariant for the POSIX/Thread bridge:
/// - the listener descriptor is published once before its thread starts and
///   closed only by `deinit`;
/// - the accept loop owns every accepted descriptor until it hands that
///   descriptor to a single connection handler;
/// - app callbacks are read and invoked only after hopping to the main queue;
/// - the background thread captures the server weakly, so it cannot extend the
///   listener lifetime.
///
/// An async Unix-domain listener can remove this conformance together with the
/// explicit Thread bridge when the deployment stack provides one.
final class CLISocketServer: @unchecked Sendable {
    enum Role: Equatable {
        /// This process bound the socket — it is the running app in this channel.
        case primary
        /// Another app already holds the socket; it has been asked to activate. The caller must exit.
        case secondary
        /// This process could not prove ownership of the channel claim and must not start a UI.
        case unavailable
    }

    /// Assigned by `TenonApp` once `pool` exists. Invoked on the MAIN thread for each valid request;
    /// the handler must call the provided closure exactly once with the result.
    var onRequest: ((CLIAction, @escaping (CLIResult) -> Void) -> Void)?

    let role: Role

    /// Why this process ended up without a control socket, when it did.
    ///
    /// The app deliberately keeps running in that case — a terminal workspace is still useful
    /// without remote control — but it must not do so in silence. `tenon-cli` can only report
    /// that nothing is listening at the well-known path, which reads as "Tenon is not running"
    /// about an app that is on screen, and sent one session hunting a bug that did not exist.
    enum Degradation: Equatable {
        /// The `/tmp/tenon-<uid>` directory could not be created.
        case socketDirectoryUnavailable
        /// Nothing was listening on the path and binding it still failed.
        case bindFailed(path: String)
        /// The stable per-user claim file was unsafe or could not be opened/locked.
        case claimUnavailable(path: String)

        var message: String {
            switch self {
            case .socketDirectoryUnavailable:
                "could not create the socket directory"
            case let .bindFailed(path):
                "could not bind \(path)"
            case let .claimUnavailable(path):
                "could not acquire the single-instance claim at \(path)"
            }
        }
    }

    /// `nil` when this process holds a control socket, or is a secondary that is about to exit.
    private(set) var degradation: Degradation?

    /// The bound socket path (primary only), available right after `init` so it can be exported as
    /// `TENON_SOCKET_PATH` into terminals.
    private(set) var socketPath: String?

    /// The path child processes must target even if this server could not bind. Keeping the
    /// channel path non-empty makes degradation local instead of silently routing to production.
    var clientSocketPath: String {
        socketPath ?? instanceChannel.socketPath()
    }

    private let instanceChannel: AppInstanceChannel

    private var listenFD: Int32 = -1
    /// Held until after the listening socket is removed, so no contender can inspect or reclaim
    /// the path while this server is still tearing it down.
    private var claimFD: Int32 = -1
    static let maximumConcurrentConnections = 8
    /// How long a burst may wait for a free permit before the app answers `busy`.
    ///
    /// Short, because it runs on the accept thread: a legitimate burst of fast requests clears
    /// well inside it, and a flood of slow ones is told so immediately instead of parking
    /// descriptors the cap was supposed to exclude.
    private static let admissionGrace: TimeInterval = 0.25
    /// The backstop that makes the cap unconditional. A handler that never calls its completion
    /// would otherwise retire one permit for the life of the process; after this the request is
    /// settled as an internal error and its permit returns.
    private static let requestLifetimeLimit: TimeInterval = 120
    private let admissionGrace: TimeInterval
    private let requestLifetimeLimit: TimeInterval
    private let connectionSlots = DispatchSemaphore(
        value: maximumConcurrentConnections
    )
    private let liveConnections = LiveConnections()
    private let connectionQueue = DispatchQueue(
        label: "dev.tenon.cli-connections",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// In-flight requests: accepted, not yet answered. The cap this counts against covers the
    /// descriptor, the main-actor hop and the async intent reply, so it is the app's whole
    /// physical exposure to `tenon-cli` rather than its decode phase.
    var liveConnectionCount: Int { liveConnections.count }

    /// `enabled: false` disables the socket + single-instance handshake entirely (role stays
    /// `.primary`, nothing binds). Used when hosting XCTest, where the app must not `exit(0)` on a
    /// live instance and must not touch the real control socket.
    /// - Parameter overridingPath: test seam only. The shipped app always uses the well-known
    ///   channel path; a test that used it would fight the developer's own running Tenon for the
    ///   single-instance lock.
    /// - Parameter socketRootForTesting: replaces `/tmp` while preserving channel derivation.
    /// - Parameter admissionGraceForTesting: shortens the wait for a free permit so a cap test
    ///   does not spend a quarter second per refused connection.
    /// - Parameter requestLifetimeForTesting: shortens the never-settled backstop.
    init(
        enabled: Bool = true,
        instanceChannel: AppInstanceChannel = .production,
        overridingPath: String? = nil,
        socketRootForTesting: String? = nil,
        afterBindBeforeListenForTesting: (() -> Void)? = nil,
        admissionGraceForTesting: TimeInterval? = nil,
        requestLifetimeForTesting: TimeInterval? = nil
    ) {
        self.instanceChannel = instanceChannel
        admissionGrace = admissionGraceForTesting ?? Self.admissionGrace
        requestLifetimeLimit = requestLifetimeForTesting ?? Self.requestLifetimeLimit
        guard enabled else {
            role = .primary
            return
        }
        let path: String?
        if let overridingPath {
            let directory = (overridingPath as NSString).deletingLastPathComponent
            path = Self.prepareSocketDirectory(at: directory, expectedOwner: geteuid())
                ? overridingPath
                : nil
        } else {
            path = if let socketRootForTesting {
                Self.wellKnownPath(
                    for: instanceChannel,
                    socketRoot: socketRootForTesting
                )
            } else {
                Self.wellKnownPath(for: instanceChannel)
            }
        }

        guard let path else {
            role = .unavailable
            reportDegradation(.socketDirectoryUnavailable)
            return
        }

        let directory = (path as NSString).deletingLastPathComponent
        let claimPath = "\(directory)/tenon.lock"
        switch Self.acquireSingleInstanceClaim(in: directory, expectedOwner: geteuid()) {
        case let .acquired(descriptor):
            claimFD = descriptor
        case .heldByPrimary:
            // The claim covers the primary's bind/listen window, where connect may legitimately
            // fail even though that launch has already won the singleton election.
            Self.requestActivationWhenReady(at: path)
            role = .secondary
            return
        case .unavailable:
            role = .unavailable
            reportDegradation(.claimUnavailable(path: claimPath))
            return
        }

        // Only the claim owner may inspect, reclaim, or bind the socket pathname. This keeps the
        // entire stale-check/bind/listen sequence serial even though none of those syscalls alone
        // spans the whole election.
        if let fd = Self.bindAndListen(
            at: path,
            afterBindBeforeListenForTesting: afterBindBeforeListenForTesting
        ) {
            listenFD = fd
            socketPath = path
            role = .primary
            startAcceptThread()
            return
        }

        // bind() failed — most likely another instance won the atomic claim.
        if Self.probeLiveInstance(at: path) {
            close(claimFD)
            claimFD = -1
            Self.requestActivation(at: path)
            role = .secondary
            return
        }

        // A killed process leaves a socket node behind. Reclaim only that exact node type: a
        // regular file or symlink is never disposable just because it occupies our pathname.
        if Self.reclaimStaleSocket(at: path) {
            if let fd = Self.bindAndListen(at: path) {
                listenFD = fd
                socketPath = path
                role = .primary
                startAcceptThread()
                return
            }
            if Self.probeLiveInstance(at: path) {
                close(claimFD)
                claimFD = -1
                Self.requestActivation(at: path)
                role = .secondary
                return
            }
        }

        // No live instance and we still can't bind: degrade to running without a control socket.
        role = .primary
        reportDegradation(.bindFailed(path: path))
    }

    /// Records the reason and says it out loud exactly once. Both halves matter: the value is what
    /// a test can assert, the log is what a human or an agent has to go on when `tenon-cli` says
    /// nothing is listening.
    private func reportDegradation(_ reason: Degradation) {
        degradation = reason
        TenonLog.cli.error("running without a control socket — \(reason.message, privacy: .public)")
    }

    deinit {
        liveConnections.drain()
        if listenFD >= 0 { close(listenFD) }
        if let socketPath { _ = Self.reclaimStaleSocket(at: socketPath) }
        if claimFD >= 0 { close(claimFD) }
    }

    // MARK: - Path & single-instance handshake  @domain: cli-control

    private static func wellKnownPath(
        for instanceChannel: AppInstanceChannel,
        socketRoot: String = "/tmp"
    ) -> String? {
        let directory = instanceChannel.socketDirectoryPath(root: socketRoot)
        guard prepareSocketDirectory(at: directory, expectedOwner: geteuid()) else { return nil }
        return "\(directory)/tenon.sock"
    }

    /// Creates the private directory, or verifies an existing path without following symlinks.
    ///
    /// The name under `/tmp` is predictable by design, so successful `createDirectory` alone is
    /// not proof that this user controls it: that API silently accepts an existing directory.
    /// This check is internal so hostile-path tests can exercise the production predicate.
    static func prepareSocketDirectory(at path: String, expectedOwner: uid_t) -> Bool {
        var information = stat()
        if lstat(path, &information) == 0 {
            return isPrivateSocketDirectory(information, expectedOwner: expectedOwner)
        }
        guard errno == ENOENT else { return false }

        if mkdir(path, 0o700) != 0 {
            // Another process may have created the predictable directory after our lstat.
            guard errno == EEXIST else { return false }
        }

        guard lstat(path, &information) == 0 else { return false }
        return isPrivateSocketDirectory(information, expectedOwner: expectedOwner)
    }

    private static func isPrivateSocketDirectory(
        _ information: stat,
        expectedOwner: uid_t
    ) -> Bool {
        let fileType = information.st_mode & mode_t(S_IFMT)
        let permissions = information.st_mode & mode_t(0o777)
        return fileType == mode_t(S_IFDIR)
            && information.st_uid == expectedOwner
            && permissions == mode_t(0o700)
    }

    private enum ClaimAcquisition {
        case acquired(Int32)
        case heldByPrimary
        case unavailable
    }

    /// Opens and locks the stable claim inode without following either directory or file symlinks.
    /// The file is intentionally never unlinked: crashes release `flock` with the descriptor, and
    /// retaining one inode prevents two processes from locking different generations of its name.
    private static func acquireSingleInstanceClaim(
        in directory: String,
        expectedOwner: uid_t
    ) -> ClaimAcquisition {
        let directoryFD = Darwin.open(
            directory,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else { return .unavailable }
        defer { close(directoryFD) }

        var directoryInformation = stat()
        guard fstat(directoryFD, &directoryInformation) == 0,
              isPrivateSocketDirectory(directoryInformation, expectedOwner: expectedOwner)
        else { return .unavailable }

        let claimFD = "tenon.lock".withCString { name in
            Darwin.openat(
                directoryFD,
                name,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard claimFD >= 0 else { return .unavailable }

        var claimInformation = stat()
        let claimIsSafe = fstat(claimFD, &claimInformation) == 0
            && claimInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && claimInformation.st_uid == expectedOwner
            && claimInformation.st_mode & mode_t(0o777) == mode_t(0o600)
            && claimInformation.st_nlink == 1
        guard claimIsSafe else {
            close(claimFD)
            return .unavailable
        }

        while flock(claimFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            let lockError = errno
            close(claimFD)
            return lockError == EWOULDBLOCK || lockError == EAGAIN
                ? .heldByPrimary
                : .unavailable
        }
        return .acquired(claimFD)
    }

    private static func reclaimStaleSocket(at path: String) -> Bool {
        var information = stat()
        guard lstat(path, &information) == 0 else { return false }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return false }
        return unlink(path) == 0
    }

    /// True if a process is currently accepting on `path` (a `connect` succeeds).
    private static func probeLiveInstance(at path: String) -> Bool {
        guard isSocketNode(at: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return connectSocket(fd, to: path) == 0
    }

    /// The singleton claim is acquired before `listen`, so a contender can arrive during that
    /// small setup window. Give the claim owner a bounded amount of time to become reachable
    /// instead of silently losing the one activation request.
    private static func requestActivationWhenReady(at path: String) {
        for attempt in 0..<25 {
            if requestActivation(at: path) { return }
            if attempt < 24 { usleep(10_000) }
        }
    }

    /// Tell the already-running app to come to the front (`app.focus`), best-effort.
    @discardableResult
    private static func requestActivation(at path: String) -> Bool {
        guard isSocketNode(at: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard connectSocket(fd, to: path) == 0 else { return false }
        let request = CLIRequest(id: "single-instance-activate", action: "app.focus")
        guard let data = try? CLIWireCodec.encodeRequest(request) else {
            return false
        }
        writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var scratch = [UInt8](repeating: 0, count: 256)
        _ = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return true
    }

    /// `connect(2)` follows filesystem symlinks. Check the pathname itself first so a hostile
    /// staging symlink can never redirect activation to production's live socket.
    private static func isSocketNode(at path: String) -> Bool {
        var information = stat()
        return lstat(path, &information) == 0
            && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }

    // MARK: - Socket setup  @domain: cli-control

    private static func bindAndListen(
        at path: String,
        afterBindBeforeListenForTesting: (() -> Void)? = nil
    ) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        guard withSocketAddress(path, { bind(fd, $0, $1) }) == 0 else { close(fd); return nil }
        afterBindBeforeListenForTesting?()
        guard chmod(path, 0o600) == 0 else {
            close(fd)
            _ = reclaimStaleSocket(at: path)
            return nil
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            _ = reclaimStaleSocket(at: path)
            return nil
        }
        return fd
    }

    private static func connectSocket(_ fd: Int32, to path: String) -> Int32 {
        withSocketAddress(path) { connect(fd, $0, $1) }
    }

    /// Build a `sockaddr_un` for `path` and hand it to a socket syscall. Returns `-1` if the path is
    /// too long for `sun_path`.
    private static func withSocketAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else { return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (index, byte) in pathBytes.enumerated() { dst[index] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    private func startAcceptThread() {
        let descriptor = listenFD
        let handler: @Sendable (Int32) -> Void = { [weak self] client in
            guard let self else {
                close(client)
                return
            }
            // A stalled client consumes one of a fixed number of permits, never the
            // accept thread and never an unbounded task/thread allocation. The permit
            // spans the whole request — read, main-actor hop, intent dispatch, reply —
            // because the descriptor and the pending reply are exactly what the cap exists
            // to bound.
            guard self.connectionSlots.wait(
                timeout: .now() + self.admissionGrace
            ) == .success else {
                Self.writeAndClose(client, .failure(
                    id: nil,
                    error: CLIError(
                        code: .busy,
                        message: "Tenon already has \(Self.maximumConcurrentConnections) requests in flight"
                    )
                ))
                return
            }
            let permit = ConnectionPermit(
                descriptor: client,
                slots: self.connectionSlots,
                registry: self.liveConnections
            )
            self.liveConnections.insert(permit)
            self.connectionQueue.async { [weak self] in
                guard let self else {
                    permit.settle { _ in }
                    return
                }
                self.handleConnection(permit)
            }
        }
        let thread = Thread {
            Self.acceptLoop(
                descriptor: descriptor,
                handle: handler
            )
        }
        thread.name = "tenon.cli-socket"
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: - Accept loop (background thread)  @domain: cli-control

    private static func acceptLoop(
        descriptor: Int32,
        handle: @escaping @Sendable (Int32) -> Void
    ) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            Self.setCloseOnExec(client)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handle(client)
        }
    }

    /// Runs on `connectionQueue` while holding a strong `self`, so the read phase can use the
    /// permit's descriptor directly: nothing else settles a permit until the request has been
    /// handed to the main actor, and `SO_RCVTIMEO` bounds the read itself.
    private func handleConnection(_ permit: ConnectionPermit) {
        switch readLine(permit.descriptor) {
        case .closed:
            permit.settle { _ in }
        case .tooLarge:
            permit.settle(with: .failure(
                id: nil,
                error: CLIError(code: .payloadTooLarge, message: "request exceeds \(CLIProtocol.maxPayloadSize) bytes")
            ))
        case .line(let data):
            dispatch(data, on: permit)
        }
    }

    private func dispatch(_ data: Data, on permit: ConnectionPermit) {
        switch CLIWireCodec.decodeRequest(data) {
        case .rejected(let response):
            permit.settle(with: response)
        case .ok(let request):
            switch CLIActionParser.parse(request) {
            case .failure(let error):
                permit.settle(with: .failure(id: request.id, error: error))
            case .success(let action):
                startLifetimeWatchdog(for: permit, id: request.id)
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        permit.settle { _ in }
                        return
                    }
                    guard let handler = self.onRequest else {
                        self.settleOffMain(permit, .failure(
                            id: request.id,
                            error: CLIError(code: .notReady, message: "Tenon is still starting up")
                        ))
                        return
                    }
                    handler(action) { result in
                        self.settleOffMain(
                            permit,
                            result.response(id: request.id)
                        )
                    }
                }
            }
        }
    }

    /// A handler that never calls its completion must not retire a permit permanently. The
    /// watchdog and the real reply race into the same once-settlement guard, so whichever
    /// arrives first is the only answer the client sees.
    private func startLifetimeWatchdog(for permit: ConnectionPermit, id: String) {
        let limit = requestLifetimeLimit
        connectionQueue.asyncAfter(deadline: .now() + limit) { [weak permit] in
            permit?.settle(with: .failure(
                id: id,
                error: CLIError(
                    code: .internalError,
                    message: "request was not answered within \(Int(limit))s"
                )
            ))
        }
    }

    // MARK: - Read / write  @domain: cli-control

    private enum ReadOutcome { case line(Data); case tooLarge; case closed }

    private func readLine(_ fd: Int32) -> ReadOutcome {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if let newlineIndex = chunk[0..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newlineIndex])
                return .line(buffer)
            }
            buffer.append(contentsOf: chunk[0..<count])
            if CLIWireCodec.validate(payloadSize: buffer.count) != nil { return .tooLarge }
        }
        return buffer.isEmpty ? .closed : .line(buffer)
    }

    /// Writes to a descriptor this server still owns outright — the refusal path, before any
    /// permit exists. Every descriptor that reached a permit is closed by `ConnectionPermit`.
    private static func writeAndClose(_ fd: Int32, _ response: CLIResponse) {
        guard let data = try? CLIWireCodec.encode(response) else {
            close(fd)
            return
        }
        Self.writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        close(fd)
    }

    private func settleOffMain(_ permit: ConnectionPermit, _ response: CLIResponse) {
        connectionQueue.async {
            permit.settle(with: response)
        }
    }

    fileprivate static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if written == 0 { break }
                offset += written
            }
        }
    }
}

// MARK: - Request permits  @domain: cli-control

/// One accepted request, from `accept` to the last byte of its reply.
///
/// The permit exists because a cap that ends at decode is not a cap: the descriptor, the
/// main-actor hop and the async intent reply all outlive the closure that used to release the
/// slot, so a flood of valid slow requests could hold arbitrarily many descriptors while the
/// semaphore read as free. Here the slot returns when the client's connection ends, and never
/// before.
///
/// Settlement is exactly once. The real reply, the never-answered watchdog and server teardown
/// all funnel through the same guard, so at most one of them writes, closes the descriptor and
/// returns the slot — the others become no-ops rather than a double close of a descriptor the
/// kernel may already have reissued.
private final class ConnectionPermit: @unchecked Sendable {
    let descriptor: Int32

    private let slots: DispatchSemaphore
    private weak var registry: LiveConnections?
    private let lock = NSLock()
    private var isSettled = false

    init(descriptor: Int32, slots: DispatchSemaphore, registry: LiveConnections) {
        self.descriptor = descriptor
        self.slots = slots
        self.registry = registry
    }

    /// Hands the descriptor to `body` exactly once, then closes it and returns the slot.
    func settle(_ body: (Int32) -> Void) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        lock.unlock()

        body(descriptor)
        close(descriptor)
        slots.signal()
        registry?.remove(self)
    }

    func settle(with response: CLIResponse) {
        settle { fd in
            guard let data = try? CLIWireCodec.encode(response) else { return }
            CLISocketServer.writeAll(fd, data)
            shutdown(fd, SHUT_WR)
        }
    }

    deinit {
        // Reached only if the permit was dropped without settling, which would leak both the
        // descriptor and the slot. Closing here keeps the cap true even then.
        settle { _ in }
    }
}

/// The in-flight set, so teardown can end requests that are still waiting on a reply instead of
/// leaving their clients blocked on a descriptor nobody owns any more.
private final class LiveConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: [ObjectIdentifier: ConnectionPermit] = [:]

    var count: Int {
        lock.withLock { permits.count }
    }

    func insert(_ permit: ConnectionPermit) {
        lock.withLock { permits[ObjectIdentifier(permit)] = permit }
    }

    func remove(_ permit: ConnectionPermit) {
        _ = lock.withLock { permits.removeValue(forKey: ObjectIdentifier(permit)) }
    }

    func drain() {
        let pending = lock.withLock { () -> [ConnectionPermit] in
            let values = Array(permits.values)
            permits.removeAll()
            return values
        }
        for permit in pending {
            permit.settle(with: .failure(
                id: nil,
                error: CLIError(code: .notReady, message: "Tenon stopped listening")
            ))
        }
    }
}
