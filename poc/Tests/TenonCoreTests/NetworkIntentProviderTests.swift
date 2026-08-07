import Darwin
import Foundation
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

final class NetworkIntentProviderTests: XCTestCase {
    func testFetchReturnsBoundedResponseAndDoesNotFollowRedirects() async throws {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }

        let bindings = try loopbackProvider().bindings
        let successReply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/success")),
                "method": .string("POST"),
                "headers": .array([
                    .object([
                        "name": .string("X-Request"),
                        "value": .string("value"),
                    ])
                ]),
                "body": .object([
                    "kind": .string("inline"),
                    "text": .string("body"),
                ]),
                "timeoutMs": .integer(2_000),
            ]),
            bindings: bindings
        )
        let success = try object(try successValue(successReply))
        XCTAssertEqual(try integer(success["status"]), 201)
        XCTAssertEqual(
            try string(try object(success["body"])["text"]),
            "created"
        )
        XCTAssertTrue(
            try array(success["headers"]).contains { value in
                let header = try object(value)
                return try string(header["name"]).caseInsensitiveCompare(
                    "X-Tenon-Test"
                ) == .orderedSame
                    && string(header["value"]) == "yes"
            }
        )

        let largeReply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/large")),
                "method": .string("GET"),
            ]),
            bindings: bindings
        )
        try assertFailure(
            largeReply,
            code: "dev.tenon.core.network-response-unavailable",
            reason: "response-body-limit-exceeded"
        )

        let redirectReply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/redirect")),
                "method": .string("GET"),
            ]),
            bindings: bindings
        )
        let redirect = try object(try successValue(redirectReply))
        XCTAssertEqual(try integer(redirect["status"]), 302)

        let headReply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/success")),
                "method": .string("HEAD"),
            ]),
            bindings: bindings
        )
        let head = try object(try successValue(headReply))
        XCTAssertEqual(try integer(head["status"]), 201)
        XCTAssertEqual(
            try string(try object(head["body"])["text"]),
            ""
        )
        XCTAssertEqual(server.requestCount, 4)
    }

    func testFetchRejectsUnsupportedInputAndInvalidURLBeforeTransport() async throws {
        let bindings = try loopbackProvider().bindings
        let resourceReply = try await invoke(
            input: .object([
                "url": .string("https://tenon.test/resource"),
                "method": .string("POST"),
                "body": .object([
                    "kind": .string("resource"),
                    "resourceID": .string("resource-1"),
                ]),
            ]),
            bindings: bindings
        )
        try assertFailure(
            resourceReply,
            code: "tenon.invalid-input"
        )

        let invalidReply = try await invoke(
            input: .object([
                "url": .string("file:///etc/passwd"),
                "method": .string("GET"),
            ]),
            bindings: bindings
        )
        try assertFailure(invalidReply, code: "tenon.invalid-input")
    }

    func testFetchRejectsAggregateHeadersBeforeOutputMaterialization()
        async throws
    {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }

        let reply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/large-headers")),
                "method": .string("GET"),
            ]),
            bindings: try loopbackProvider().bindings
        )
        try assertFailure(
            reply,
            code: "dev.tenon.core.network-response-unavailable",
            reason: "response-headers-limit-exceeded"
        )
    }

    func testFetchSkipsInformationalResponsesUntilFinalResponse()
        async throws
    {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }

        let reply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/informational")),
                "method": .string("GET"),
            ]),
            bindings: try loopbackProvider().bindings
        )
        let response = try object(try successValue(reply))
        XCTAssertEqual(try integer(response["status"]), 200)
        XCTAssertEqual(
            try string(try object(response["body"])["text"]),
            "final"
        )
        XCTAssertFalse(
            try array(response["headers"]).contains { value in
                try string(object(value)["name"])
                    .caseInsensitiveCompare("Link") == .orderedSame
            }
        )
    }

    func testFetchCanonicalizesProviderLookupExactlyLikePolicy()
        async throws
    {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let canonicalHost = "pinned.tenon.test"
        let resolver = NetworkEndpointResolver { host in
            guard host == canonicalHost else { return [] }
            return [
                NetworkResolvedEndpoint(
                    address: "127.0.0.1",
                    isPublic: false
                )
            ]
        }
        let provider = try NetworkIntentProvider(resolver: resolver)

        let reply = try await invoke(
            input: .object([
                "url": .string(
                    server.url(
                        host: "Pinned.Tenon.Test.",
                        path: "/success"
                    )
                ),
                "method": .string("GET"),
            ]),
            bindings: provider.bindings,
            authorizedHost: AuthorizedNetworkHost(
                requestedHost: canonicalHost,
                canonicalHost: canonicalHost,
                allowsPrivateEndpoints: true
            )
        )
        XCTAssertEqual(
            try integer(try object(try successValue(reply))["status"]),
            201
        )
    }

    func testFetchPinsAuthorizedResolutionAndRejectsMixedPrivateDNSAnswers()
        async throws
    {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let pinnedHost = "pinned.tenon.test"
        let resolver = NetworkEndpointResolver { host in
            if host == pinnedHost {
                return [
                    NetworkResolvedEndpoint(
                        address: "127.0.0.1",
                        isPublic: false
                    )
                ]
            }
            return [
                NetworkResolvedEndpoint(
                    address: "93.184.216.34",
                    isPublic: true
                ),
                NetworkResolvedEndpoint(
                    address: "127.0.0.1",
                    isPublic: false
                ),
            ]
        }
        let provider = try NetworkIntentProvider(resolver: resolver)

        let pinnedReply = try await invoke(
            input: .object([
                "url": .string(
                    server.url(host: pinnedHost, path: "/success")
                ),
                "method": .string("GET"),
            ]),
            bindings: provider.bindings,
            authorizedHost: AuthorizedNetworkHost(
                requestedHost: pinnedHost,
                canonicalHost: pinnedHost,
                allowsPrivateEndpoints: true
            )
        )
        XCTAssertEqual(
            try integer(try object(try successValue(pinnedReply))["status"]),
            201
        )

        let reboundHost = "rebind.tenon.test"
        let deniedReply = try await invoke(
            input: .object([
                "url": .string("http://\(reboundHost):8080/secret"),
                "method": .string("GET"),
            ]),
            bindings: provider.bindings,
            authorizedHost: AuthorizedNetworkHost(
                requestedHost: reboundHost,
                canonicalHost: reboundHost,
                allowsPrivateEndpoints: false
            )
        )
        try assertFailure(
            deniedReply,
            code: "dev.tenon.core.network-failed",
            reason: "private-network-endpoint-denied"
        )
    }

    func testPastDeadlineDoesNotStartNetworkRequest() async throws {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }

        let reply = try await invoke(
            input: .object([
                "url": .string(server.url(path: "/deadline")),
                "method": .string("GET"),
            ]),
            bindings: try NetworkIntentProvider().bindings,
            deadline: .now
        )
        try assertFailure(reply, code: "tenon.deadline-exceeded")
        XCTAssertEqual(server.requestCount, 0)
    }

    func testAddressClassificationRejectsIPv4MappedPrivateIPv6() {
        XCTAssertFalse(
            SystemNetworkEndpointResolver.isPublicAddress(
                "::ffff:127.0.0.1"
            )
        )
        XCTAssertTrue(
            SystemNetworkEndpointResolver.isPublicAddress(
                "::ffff:93.184.216.34"
            )
        )
    }

    func testAddressClassificationRejectsSpecialPurposeRanges() {
        for address in [
            "100.64.0.1", "192.0.0.1", "192.0.2.1", "198.18.0.1",
            "198.51.100.1", "203.0.113.1", "240.0.0.1",
            "2001:db8::1", "2001::1", "2001:20::1", "64:ff9b:1::1",
            "64:ff9b::127.0.0.1", "2002:7f00:1::1",
        ] {
            XCTAssertFalse(
                SystemNetworkEndpointResolver.isPublicAddress(address),
                address
            )
        }
        for address in ["93.184.216.34", "2606:4700:4700::1111"] {
            XCTAssertTrue(
                SystemNetworkEndpointResolver.isPublicAddress(address),
                address
            )
        }
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    enum ServerError: Error {
        case socketFailed
        case bindFailed
        case addressFailed
        case listenFailed
    }

    private let listeningSocket: Int32
    private let port: UInt16
    private let lock = NSLock()
    private var serverTask: Task<Void, Never>?
    private var stopped = false
    private var recordedRequestCount = 0

    var requestCount: Int {
        lock.withLock { recordedRequestCount }
    }

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ServerError.socketFailed }
        listeningSocket = socket

        var reuseAddress: Int32 = 1
        _ = withUnsafePointer(to: &reuseAddress) {
            Darwin.setsockopt(
                socket,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socket,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socket)
            throw ServerError.bindFailed
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &boundLength)
            }
        }
        guard addressResult == 0 else {
            Darwin.close(socket)
            throw ServerError.addressFailed
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        guard Darwin.listen(socket, 4) == 0 else {
            Darwin.close(socket)
            throw ServerError.listenFailed
        }
        serverTask = Task.detached { [weak self] in
            self?.serve()
        }
    }

    deinit {
        stop()
    }

    func url(path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    func url(host: String, path: String) -> String {
        "http://\(host):\(port)\(path)"
    }

    func stop() {
        let task = lock.withLock {
            guard !stopped else { return nil as Task<Void, Never>? }
            stopped = true
            let task = serverTask
            serverTask = nil
            return task
        }
        task?.cancel()
        Darwin.shutdown(listeningSocket, SHUT_RDWR)
        Darwin.close(listeningSocket)
    }

    private func serve() {
        while !Task.isCancelled {
            let client = Darwin.accept(listeningSocket, nil, nil)
            guard client >= 0 else { break }
            respond(to: client)
            Darwin.close(client)
        }
    }

    private func respond(to client: Int32) {
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while request.count < 64 * 1_024 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(buffer, count: count)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }
        let path = requestPath(from: request)
        lock.withLock {
            recordedRequestCount += 1
        }
        if path == "/informational" {
            send(
                Data(
                    (
                        "HTTP/1.1 100 Continue\r\n"
                            + "X-Interim: continue\r\n\r\n"
                            + "HTTP/1.1 103 Early Hints\r\n"
                            + "Link: </style.css>; rel=preload\r\n\r\n"
                            + "HTTP/1.1 200 OK\r\n"
                            + "X-Final: yes\r\n"
                            + "Content-Length: 5\r\n"
                            + "Connection: close\r\n\r\n"
                            + "final"
                    ).utf8
                ),
                to: client
            )
            return
        }

        let status: String
        let headers: [String]
        let body: Data
        switch path {
        case "/success":
            status = "201 Created"
            headers = ["X-Tenon-Test: yes"]
            body = Data("created".utf8)
        case "/large":
            status = "200 OK"
            headers = []
            body = Data(
                repeating: 0x61,
                count: CoreIntentPayloadPolicy.maximumInlineTextCharacters + 1
            )
        case "/redirect":
            status = "302 Found"
            headers = ["Location: \(url(path: "/escaped"))"]
            body = Data()
        case "/large-headers":
            status = "200 OK"
            headers = (0 ..< 16).map {
                "X-Tenon-Large-\($0): \(String(repeating: "h", count: 1_024))"
            }
            body = Data()
        default:
            status = "500 Internal Server Error"
            headers = []
            body = Data("unexpected".utf8)
        }

        let head = (
            ["HTTP/1.1 \(status)"]
                + headers
                + [
                    "Content-Length: \(body.count)",
                    "Connection: close",
                    "",
                    "",
                ]
        ).joined(separator: "\r\n")
        send(Data(head.utf8), to: client)
        send(body, to: client)
    }

    private func requestPath(from data: Data) -> String {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first
        else {
            return ""
        }
        let components = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return "" }
        return String(components[1])
    }

    private func send(_ data: Data, to socket: Int32) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(
                    socket,
                    baseAddress.advanced(by: sent),
                    buffer.count - sent,
                    0
                )
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

private extension NetworkIntentProviderTests {
    enum TestError: Error {
        case missingBinding
        case expectedSuccess
        case expectedFailure
        case unexpectedValue
    }

    func invoke(
        input: IntentValue,
        bindings: [IntentProviderBinding],
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        authorizedHost: AuthorizedNetworkHost? = nil
    ) async throws -> IntentProviderReply {
        let intentID = try CoreIntentName.networkFetch.intentID
        guard let binding = bindings.first(where: { $0.intentID == intentID }) else {
            throw TestError.missingBinding
        }
        let envelope = IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
            caller: IntentPrincipal(
                id: "test:network-provider",
                kind: .plugin,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: deadline,
            target: nil,
            idempotencyKey: nil
        )
        let host: AuthorizedNetworkHost
        if let authorizedHost {
            host = authorizedHost
        } else {
            let inputObject = try object(input)
            let rawURL = try string(inputObject["url"])
            let rawHost = URL(string: rawURL)?.host() ?? "invalid"
            let requestedHost = try NetworkHostPattern(rawHost).rawValue
            host = AuthorizedNetworkHost(
                requestedHost: requestedHost,
                canonicalHost: requestedHost,
                allowsPrivateEndpoints: true
            )
        }
        let context = IntentProviderContext(
            requestID: envelope.requestID,
            authorizedNetworkHosts: [host],
            nestedSend: { request in
                .failure(
                    error: IntentError(
                        code: .kernel(.internal),
                        details: .string(request.intentID.rawValue),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: nil
                )
            }
        )
        return try await binding.invoke(envelope: envelope, context: context)
    }

    func successValue(_ reply: IntentProviderReply) throws -> IntentValue {
        guard case let .success(value) = reply else {
            if case let .failure(failure) = reply {
                XCTFail(
                    "Expected success, got \(failure.code.rawValue) "
                        + "\(String(describing: failure.details))"
                )
            }
            throw TestError.expectedSuccess
        }
        return value
    }

    func assertFailure(
        _ reply: IntentProviderReply,
        code: String,
        reason: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .failure(failure) = reply else {
            XCTFail("Expected failure", file: file, line: line)
            throw TestError.expectedFailure
        }
        XCTAssertEqual(failure.code.rawValue, code, file: file, line: line)
        if let reason {
            let details = try object(failure.details)
            XCTAssertEqual(
                try string(details["reason"]),
                reason,
                file: file,
                line: line
            )
        }
    }

    func object(_ value: IntentValue?) throws -> [String: IntentValue] {
        guard case let .object(object)? = value else {
            throw TestError.unexpectedValue
        }
        return object
    }

    func array(_ value: IntentValue?) throws -> [IntentValue] {
        guard case let .array(array)? = value else {
            throw TestError.unexpectedValue
        }
        return array
    }

    func string(_ value: IntentValue?) throws -> String {
        guard case let .string(string)? = value else {
            throw TestError.unexpectedValue
        }
        return string
    }

    func integer(_ value: IntentValue?) throws -> Int64 {
        guard case let .integer(integer)? = value else {
            throw TestError.unexpectedValue
        }
        return integer
    }

    func loopbackProvider() throws -> NetworkIntentProvider {
        try NetworkIntentProvider(
            resolver: NetworkEndpointResolver { _ in
                [
                    NetworkResolvedEndpoint(
                        address: "127.0.0.1",
                        isPublic: false
                    )
                ]
            }
        )
    }
}
