import Foundation
import TenonIntentCore

/// The transport half of `tenon-cli`: find a running app's control socket, send one request, read
/// one response. A neutral shell targets production's compatibility path; a Tenon pane inherits
/// `$TENON_SOCKET_PATH` and therefore targets the production or staging instance that owns it.
enum CLIClient {
    enum ClientError: Error, CustomStringConvertible {
        case notRunning(String)
        case ioFailed(String)
        case badResponse

        var description: String {
            switch self {
            case .notRunning(let path):
                return "Tenon is not running (no control socket at \(path)). Start it with `swift run tenon`."
            case .ioFailed(let detail):
                return "socket I/O failed: \(detail)"
            case .badResponse:
                return "the app returned a response this client could not parse"
            }
        }
    }

    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["TENON_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return "/tmp/tenon-\(getuid())/tenon.sock"
    }

    static func send(_ request: CLIRequest) throws -> CLIResponse {
        let path = socketPath()
        guard isSecureSocketPath(path) else {
            throw ClientError.notRunning(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.ioFailed("socket() failed") }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard connectSocket(fd, to: path) == 0 else {
            throw ClientError.notRunning(path)
        }

        writeAll(fd, try CLIWireCodec.encodeRequest(request))
        shutdown(fd, SHUT_WR)

        let data = readToEnd(fd)
        guard let response = CLIWireCodec.decodeResponse(data) else {
            throw ClientError.badResponse
        }
        return response
    }

    // MARK: - POSIX glue (protocol lives in TenonIntentCore; this is target-local plumbing)

    private static func isSecureSocketPath(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(0o777) == mode_t(0o700)
        else { return false }

        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              socketInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              socketInfo.st_uid == geteuid(),
              socketInfo.st_mode & mode_t(0o777) == mode_t(0o600)
        else { return false }
        return true
    }

    private static func connectSocket(_ fd: Int32, to path: String) -> Int32 {
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
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

    private static func readToEnd(_ fd: Int32) -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
        return buffer
    }
}
