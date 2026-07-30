import Foundation
import TenonCore

/// The CLI control socket, which doubles as Tenon's single-instance lock. There is exactly one
/// well-known socket per user (`/tmp/tenon-<uid>/tenon.sock`): whoever binds it is the one running
/// app; a second launch finds it already held, tells the primary to come to the front, and exits.
/// So the app is a true singleton and the socket path is stable — an agent never has to disambiguate
/// between instances.
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
        /// This process bound the socket — it is the one running app.
        case primary
        /// Another app already holds the socket; it has been asked to activate. The caller must exit.
        case secondary
    }

    /// Assigned by `TenonApp` once `pool` exists. Invoked on the MAIN thread for each valid request;
    /// the handler must call the provided closure exactly once with the result.
    var onRequest: ((CLIAction, @escaping (CLIResult) -> Void) -> Void)?

    let role: Role

    /// The bound socket path (primary only), available right after `init` so it can be exported as
    /// `TENON_SOCKET_PATH` into terminals.
    private(set) var socketPath: String?

    private var listenFD: Int32 = -1

    /// `enabled: false` disables the socket + single-instance handshake entirely (role stays
    /// `.primary`, nothing binds). Used when hosting XCTest, where the app must not `exit(0)` on a
    /// live instance and must not touch the real control socket.
    init(enabled: Bool = true) {
        guard enabled else {
            role = .primary
            return
        }
        let path = Self.wellKnownPath()

        // Someone already listening? Then we are a second launch: activate them and bow out.
        if let path, Self.probeLiveInstance(at: path) {
            Self.requestActivation(at: path)
            role = .secondary
            return
        }

        guard let path else {
            // Couldn't even make the socket dir; run without a control socket rather than not at all.
            role = .primary
            return
        }

        unlink(path)
        if let fd = Self.bindAndListen(at: path) {
            listenFD = fd
            socketPath = path
            role = .primary
            startAcceptThread()
            return
        }

        // bind() failed — most likely another instance won a launch race between our probe and bind.
        if Self.probeLiveInstance(at: path) {
            Self.requestActivation(at: path)
            role = .secondary
            return
        }

        // No live instance and we still can't bind: degrade to running without a control socket.
        role = .primary
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
        if let socketPath { unlink(socketPath) }
    }

    // MARK: - Path & single-instance handshake

    private static func wellKnownPath() -> String? {
        let directory = "/tmp/tenon-\(getuid())"
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return "\(directory)/tenon.sock"
    }

    /// True if a process is currently accepting on `path` (a `connect` succeeds).
    private static func probeLiveInstance(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return connectSocket(fd, to: path) == 0
    }

    /// Tell the already-running app to come to the front (`app.focus`), best-effort.
    private static func requestActivation(at path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard connectSocket(fd, to: path) == 0 else { return }
        let request = CLIRequest(id: "single-instance-activate", action: "app.focus")
        guard let data = try? CLIWireCodec.encodeRequest(request) else {
            return
        }
        writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var scratch = [UInt8](repeating: 0, count: 256)
        _ = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - Socket setup

    private static func bindAndListen(at path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        guard withSocketAddress(path, { bind(fd, $0, $1) }) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); unlink(path); return nil }
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
            self.handleConnection(client)
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

    // MARK: - Accept loop (background thread)

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
            handle(client)
        }
    }

    private func handleConnection(_ client: Int32) {
        switch readLine(client) {
        case .closed:
            close(client)
        case .tooLarge:
            writeAndClose(client, .failure(
                id: nil,
                error: CLIError(code: .payloadTooLarge, message: "request exceeds \(CLIProtocol.maxPayloadSize) bytes")
            ))
        case .line(let data):
            dispatch(data, on: client)
        }
    }

    private func dispatch(_ data: Data, on client: Int32) {
        switch CLIWireCodec.decodeRequest(data) {
        case .rejected(let response):
            writeAndClose(client, response)
        case .ok(let request):
            switch CLIActionParser.parse(request) {
            case .failure(let error):
                writeAndClose(client, .failure(id: request.id, error: error))
            case .success(let action):
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let handler = self.onRequest else {
                        self.writeAndClose(client, .failure(
                            id: request.id,
                            error: CLIError(code: .notReady, message: "Tenon is still starting up")
                        ))
                        return
                    }
                    handler(action) { result in
                        self.writeAndClose(client, result.response(id: request.id))
                    }
                }
            }
        }
    }

    // MARK: - Read / write

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

    private func writeAndClose(_ fd: Int32, _ response: CLIResponse) {
        guard let data = try? CLIWireCodec.encode(response) else {
            close(fd)
            return
        }
        Self.writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        close(fd)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
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
