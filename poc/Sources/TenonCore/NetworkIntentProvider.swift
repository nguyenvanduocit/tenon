import Foundation
import Network
import TenonIntentCore

struct NetworkResolvedEndpoint: Sendable, Equatable, Hashable {
    let address: String
    let isPublic: Bool
}

struct NetworkEndpointResolver: Sendable {
    typealias Operation = @Sendable (String) throws -> [NetworkResolvedEndpoint]

    static let system = NetworkEndpointResolver { host in
        try SystemNetworkEndpointResolver.resolve(host: host)
    }

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func resolve(_ host: String) throws -> [NetworkResolvedEndpoint] {
        try operation(host)
    }
}

/// One-request, bounded HTTP transport for `network.fetch.v1`.
///
/// Redirects are returned to the caller instead of followed: authorization is evaluated for
/// the input URL's host, so transparently following a redirect would escape that grant.
public struct NetworkIntentProvider: Sendable {
    public let bindings: [IntentProviderBinding]

    public init() throws {
        try self.init(resolver: .system)
    }

    init(resolver: NetworkEndpointResolver) throws {
        let codes = try ErrorCodes()
        bindings = [
            IntentProviderBinding(intentID: try CoreIntentName.networkFetch.intentID) {
                envelope,
                context in
                await Self.fetch(
                    envelope: envelope,
                    context: context,
                    codes: codes,
                    resolver: resolver
                )
            }
        ]
    }
}

private extension NetworkIntentProvider {
    struct ErrorCodes: Sendable {
        let networkFailed: IntentErrorCode
        let responseUnavailable: IntentErrorCode

        init() throws {
            networkFailed = .domain(
                try IntentDomainErrorCode("dev.tenon.core.network-failed")
            )
            responseUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.network-response-unavailable"
                )
            )
        }
    }

    struct Header: Sendable {
        let name: String
        let value: String
    }

    struct Request: Sendable {
        let scheme: String
        let host: String
        let port: UInt16
        let requestTarget: String
        let method: String
        let headers: [Header]
        let body: Data?
        let timeout: TimeInterval
    }

    enum TransportOutcome: Sendable {
        case response(status: Int, headers: [Header], body: Data)
        case networkFailure(reason: String, retryable: Bool)
        case responseUnavailable(reason: String)
        case cancelled
    }

    static let methods = Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"])
    static let maximumBodyBytes = CoreIntentPayloadPolicy.maximumInlineTextCharacters
    static let maximumResponseHeaderEncodedBytes =
        CoreIntentPayloadPolicy.maximumEncodedBytes
            - maximumBodyBytes
            - 4 * 1_024

    static func fetch(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes,
        resolver: NetworkEndpointResolver
    ) async -> IntentProviderReply {
        do {
            let request = try request(from: envelope)
            guard let authorization = context.authorizedNetworkHost(
                for: request.host
            ),
                authorization.canonicalHost == request.host
            else {
                return .failure(
                    IntentProviderFailure(
                        code: .kernel(.handlerFailed),
                        details: .object([
                            "reason": .string(
                                "network-authorization-binding-missing"
                            )
                        ])
                    )
                )
            }
            try context.checkCancellation()
            let endpoints = try await Task.detached(priority: Task.currentPriority) {
                try resolver.resolve(request.host)
            }.value
            guard !endpoints.isEmpty else {
                return CoreIntentProviderSupport.failure(
                    code: codes.networkFailed,
                    reason: "endpoint-resolution-empty",
                    retryable: true
                )
            }
            guard authorization.allowsPrivateEndpoints
                || endpoints.allSatisfy(\.isPublic)
            else {
                return CoreIntentProviderSupport.failure(
                    code: codes.networkFailed,
                    reason: "private-network-endpoint-denied"
                )
            }
            let transport = PinnedHTTPTransport(
                maximumBodyBytes: maximumBodyBytes
            )
            let worker = Task.detached(priority: Task.currentPriority) {
                await transport.perform(request, endpoints: endpoints)
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                transport.cancel()
                worker.cancel()
            }
            if ContinuousClock.now >= envelope.deadline {
                return .failure(
                    IntentProviderFailure(code: .kernel(.deadlineExceeded))
                )
            }
            try context.checkCancellation()

            switch outcome {
            case let .response(status, headers, body):
                guard let text = String(data: body, encoding: .utf8),
                      text.count <= CoreIntentPayloadPolicy.maximumInlineTextCharacters
                else {
                    return CoreIntentProviderSupport.failure(
                        code: codes.responseUnavailable,
                        reason: "response-body-is-not-inline-utf8"
                    )
                }
                let output = IntentValue.object([
                    "status": .integer(Int64(status)),
                    "headers": .array(
                        headers.map { header in
                            .object([
                                "name": .string(header.name),
                                "value": .string(header.value),
                            ])
                        }
                    ),
                    "body": CoreIntentProviderSupport.textOutput(text),
                ])
                do {
                    try output.validate()
                } catch {
                    return CoreIntentProviderSupport.failure(
                        code: codes.responseUnavailable,
                        reason: "inline-response-limit-exceeded"
                    )
                }
                return .success(output)
            case let .networkFailure(reason, retryable):
                return CoreIntentProviderSupport.failure(
                    code: codes.networkFailed,
                    reason: reason,
                    retryable: retryable
                )
            case let .responseUnavailable(reason):
                return CoreIntentProviderSupport.failure(
                    code: codes.responseUnavailable,
                    reason: reason
                )
            case .cancelled:
                return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
            }
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            let code: IntentKernelErrorCode =
                ContinuousClock.now >= envelope.deadline
                    ? .deadlineExceeded
                    : .cancelled
            return .failure(IntentProviderFailure(code: .kernel(code)))
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.networkFailed,
                reason: "request-could-not-start"
            )
        }
    }

    static func request(from envelope: IntentEnvelope) throws -> Request {
        let input = try CoreIntentProviderSupport.object(envelope.input)
        let rawURL = try CoreIntentProviderSupport.string("url", in: input)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user() == nil,
              url.password() == nil,
              let normalizedURL = URL(string: url.absoluteString),
              let rawHost = normalizedURL.host(),
              let canonicalHost = try? NetworkHostPattern(rawHost).rawValue
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField("url")
        }

        let method = try CoreIntentProviderSupport.string("method", in: input)
        guard methods.contains(method) else {
            throw CoreIntentProviderInputError.missingOrInvalidField("method")
        }

        let headers = try CoreIntentProviderSupport.optionalObjectArray(
            "headers",
            in: input
        ).map { header in
            Header(
                name: try CoreIntentProviderSupport.string("name", in: header),
                value: try CoreIntentProviderSupport.string("value", in: header)
            )
        }
        guard headers.count <= 256,
              headers.allSatisfy({
                  !$0.name.isEmpty
                      && $0.name.utf8.count <= 8_192
                      && $0.value.utf8.count <= 16_384
                      && !$0.name.contains("\r")
                      && !$0.name.contains("\n")
                      && !$0.value.contains("\r")
                      && !$0.value.contains("\n")
                      && ![
                          "connection",
                          "content-length",
                          "host",
                          "transfer-encoding",
                      ].contains($0.name.lowercased())
              })
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField("headers")
        }

        let body: Data?
        if let text = try CoreIntentProviderSupport.optionalTextInput(
            "body",
            in: input
        ) {
            let data = Data(text.utf8)
            guard data.count <= maximumBodyBytes else {
                throw CoreIntentProviderInputError.missingOrInvalidField(
                    "body"
                )
            }
            body = data
        } else {
            body = nil
        }

        let requestedMilliseconds = try CoreIntentProviderSupport.optionalInteger(
            "timeoutMs",
            in: input
        )
        if let requestedMilliseconds,
           !(1 ... 60_000).contains(requestedMilliseconds)
        {
            throw CoreIntentProviderInputError.missingOrInvalidField("timeoutMs")
        }
        let remaining = CoreIntentProviderSupport.remainingSeconds(
            until: envelope.deadline
        )
        guard remaining > 0 else {
            throw CoreIntentProviderExecutionError.deadlineExceeded
        }
        let requested = requestedMilliseconds.map {
            TimeInterval($0) / 1_000
        }

        let port = url.port
            ?? (scheme == "https" ? 443 : 80)
        guard let port = UInt16(exactly: port) else {
            throw CoreIntentProviderInputError.missingOrInvalidField("url")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false
            ? components?.percentEncodedPath ?? "/"
            : "/"
        let requestTarget = components?.percentEncodedQuery.map {
            path + "?" + $0
        } ?? path

        return Request(
            scheme: scheme,
            host: canonicalHost,
            port: port,
            requestTarget: requestTarget,
            method: method,
            headers: headers,
            body: body,
            timeout: max(0.001, min(requested ?? remaining, remaining))
        )
    }
}

enum SystemNetworkEndpointResolver {
    static func resolve(host: String) throws -> [NetworkResolvedEndpoint] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &head)
        guard status == 0, let head else {
            throw URLError(.dnsLookupFailed)
        }
        defer { freeaddrinfo(head) }

        var endpoints: Set<NetworkResolvedEndpoint> = []
        var current: UnsafeMutablePointer<addrinfo>? = head
        while let info = current?.pointee {
            defer { current = info.ai_next }
            guard info.ai_family == AF_INET || info.ai_family == AF_INET6,
                  let address = info.ai_addr
            else {
                continue
            }
            var buffer = [CChar](
                repeating: 0,
                count: Int(NI_MAXHOST)
            )
            let rendered = getnameinfo(
                address,
                info.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rendered == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            }
            let value = String(decoding: bytes, as: UTF8.self)
            endpoints.insert(
                NetworkResolvedEndpoint(
                    address: value,
                    isPublic: isPublicAddress(value)
                )
            )
        }
        return endpoints.sorted { $0.address < $1.address }
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            return isPublicIPv4(value)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
                return false
            }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF,
               bytes[11] == 0xFF
            {
                let mappedIPv4 = bytes[12 ... 15].reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                return isPublicIPv4(mappedIPv4)
            }
            if bytes[0] & 0xFE == 0xFC { return false }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
            if bytes[0] == 0xFF { return false }
            return true
        }
        return false
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        !(
            value >> 24 == 0
                || value >> 24 == 10
                || value >> 24 == 127
                || value >> 16 == 0xA9FE
                || value >> 20 == 0xAC1
                || value >> 16 == 0xC0A8
                || value >> 22 == 0x0191
                || value >> 24 >= 224
        )
    }
}

private final class PinnedHTTPTransport: @unchecked Sendable {
    private let maximumBodyBytes: Int
    private let lock = NSLock()
    private var activeConnection: PinnedHTTPConnection?
    private var wasCancelled = false

    init(maximumBodyBytes: Int) {
        self.maximumBodyBytes = maximumBodyBytes
    }

    func perform(
        _ request: NetworkIntentProvider.Request,
        endpoints: [NetworkResolvedEndpoint]
    ) async -> NetworkIntentProvider.TransportOutcome {
        var lastFailure: NetworkIntentProvider.TransportOutcome =
            .networkFailure(
                reason: "transport-failed",
                retryable: true
            )
        for endpoint in endpoints {
            if lock.withLock({ wasCancelled }) {
                return .cancelled
            }
            let connection = PinnedHTTPConnection(
                request: request,
                endpoint: endpoint,
                maximumBodyBytes: maximumBodyBytes
            )
            lock.withLock {
                activeConnection = connection
            }
            let outcome = await connection.perform()
            lock.withLock {
                if activeConnection === connection {
                    activeConnection = nil
                }
            }
            switch outcome {
            case .networkFailure:
                lastFailure = outcome
            default:
                return outcome
            }
        }
        return lastFailure
    }

    func cancel() {
        let connection = lock.withLock {
            wasCancelled = true
            return activeConnection
        }
        connection?.cancel()
    }
}

private final class PinnedHTTPConnection: @unchecked Sendable {
    private let request: NetworkIntentProvider.Request
    private let endpoint: NetworkResolvedEndpoint
    private let maximumBodyBytes: Int
    private let queue = DispatchQueue(
        label: "dev.tenon.network-fetch.\(UUID().uuidString)"
    )
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation:
        CheckedContinuation<NetworkIntentProvider.TransportOutcome, Never>?
    private var completedOutcome: NetworkIntentProvider.TransportOutcome?
    private var parser: PinnedHTTPResponseParser
    private var wasCancelled = false

    init(
        request: NetworkIntentProvider.Request,
        endpoint: NetworkResolvedEndpoint,
        maximumBodyBytes: Int
    ) {
        self.request = request
        self.endpoint = endpoint
        self.maximumBodyBytes = maximumBodyBytes
        parser = PinnedHTTPResponseParser(
            maximumBodyBytes: maximumBodyBytes,
            requestMethod: request.method
        )
    }

    func perform() async -> NetworkIntentProvider.TransportOutcome {
        let connection = makeConnection()
        lock.withLock {
            self.connection = connection
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: NetworkIntentProvider.TransportOutcome? =
                    lock.withLock {
                        if let completedOutcome {
                            return completedOutcome
                        }
                        self.continuation = continuation
                        return nil
                    }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                installHandlers(on: connection)
                connection.start(queue: queue)
                queue.asyncAfter(
                    deadline: .now() + request.timeout
                ) { [weak self] in
                    self?.finish(
                        .networkFailure(
                            reason: "transport-timeout",
                            retryable: true
                        )
                    )
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.withLock {
            wasCancelled = true
        }
        finish(.cancelled)
    }

    private func makeConnection() -> NWConnection {
        let port = NWEndpoint.Port(rawValue: request.port)!
        let parameters: NWParameters
        if request.scheme == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                request.host
            )
            parameters = NWParameters(
                tls: tls,
                tcp: NWProtocolTCP.Options()
            )
        } else {
            parameters = .tcp
        }
        return NWConnection(
            host: NWEndpoint.Host(endpoint.address),
            port: port,
            using: parameters
        )
    }

    private func installHandlers(on connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                sendRequest(on: connection)
            case .failed:
                finish(
                    .networkFailure(
                        reason: "transport-failed",
                        retryable: true
                    )
                )
            case .cancelled:
                let cancelled = lock.withLock { wasCancelled }
                if cancelled {
                    finish(.cancelled)
                }
            default:
                break
            }
        }
    }

    private func sendRequest(on connection: NWConnection) {
        let data: Data
        do {
            data = try requestData()
        } catch {
            finish(
                .networkFailure(
                    reason: "request-encoding-failed",
                    retryable: false
                )
            )
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    finish(
                        .networkFailure(
                            reason: "request-send-failed",
                            retryable: true
                        )
                    )
                } else {
                    receive(on: connection)
                }
            }
        )
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                finish(
                    .networkFailure(
                        reason: "response-read-failed-\(error)",
                        retryable: true
                    )
                )
                return
            }
            let result = parser.consume(
                data ?? Data(),
                isComplete: isComplete
            )
            switch result {
            case .needMore:
                if isComplete {
                    finish(
                        .networkFailure(
                            reason: "response-was-incomplete",
                            retryable: false
                        )
                    )
                } else {
                    receive(on: connection)
                }
            case let .finished(outcome):
                finish(outcome)
            }
        }
    }

    private func requestData() throws -> Data {
        let defaultPort = request.scheme == "https" ? 443 : 80
        let bracketedHost = request.host.contains(":")
            ? "[\(request.host)]"
            : request.host
        let host = request.port == defaultPort
            ? bracketedHost
            : "\(bracketedHost):\(request.port)"
        var lines = [
            "\(request.method) \(request.requestTarget) HTTP/1.1",
            "Host: \(host)",
            "Accept-Encoding: identity",
            "Connection: close",
        ]
        lines.append(contentsOf: request.headers.map {
            "\($0.name): \($0.value)"
        })
        lines.append("Content-Length: \(request.body?.count ?? 0)")
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        if let body = request.body {
            data.append(body)
        }
        return data
    }

    private func finish(
        _ outcome: NetworkIntentProvider.TransportOutcome
    ) {
        let resources = lock.withLock {
            guard completedOutcome == nil else {
                return (
                    nil as CheckedContinuation<
                        NetworkIntentProvider.TransportOutcome,
                        Never
                    >?,
                    nil as NWConnection?
                )
            }
            completedOutcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            let connection = self.connection
            self.connection = nil
            return (continuation, connection)
        }
        resources.1?.stateUpdateHandler = nil
        resources.1?.cancel()
        resources.0?.resume(returning: outcome)
    }
}

private struct PinnedHTTPResponseParser {
    enum Result {
        case needMore
        case finished(NetworkIntentProvider.TransportOutcome)
    }

    private let maximumBodyBytes: Int
    private let maximumHeaderBytes = 16 * 1_024
    private let maximumWireBytes: Int
    private let requestMethod: String
    private var buffer = Data()
    private var response: ParsedResponse?
    private var receivedWireBytes = 0

    init(maximumBodyBytes: Int, requestMethod: String) {
        self.maximumBodyBytes = maximumBodyBytes
        self.requestMethod = requestMethod
        maximumWireBytes = maximumBodyBytes + 32 * 1_024
    }

    mutating func consume(_ data: Data, isComplete: Bool) -> Result {
        let (nextWireBytes, wireBytesOverflow) = receivedWireBytes
            .addingReportingOverflow(data.count)
        guard !wireBytesOverflow,
              nextWireBytes <= maximumWireBytes,
              data.count <= maximumWireBytes,
              buffer.count <= maximumWireBytes - data.count
        else {
            return .finished(
                .responseUnavailable(reason: "response-body-limit-exceeded")
            )
        }
        receivedWireBytes = nextWireBytes
        buffer.append(data)

        while response == nil {
            guard let boundary = buffer.range(
                of: Data("\r\n\r\n".utf8)
            ) else {
                if buffer.count > maximumHeaderBytes {
                    return .finished(
                        .responseUnavailable(
                            reason: "response-headers-limit-exceeded"
                        )
                    )
                }
                return .needMore
            }
            guard boundary.lowerBound <= maximumHeaderBytes else {
                return .finished(
                    .responseUnavailable(
                        reason: "response-headers-limit-exceeded"
                    )
                )
            }
            let headerData = buffer[..<boundary.lowerBound]
            do {
                let parsed = try parseHeaders(Data(headerData))
                buffer.removeSubrange(..<boundary.upperBound)
                if (100 ... 199).contains(parsed.status) {
                    continue
                }
                response = parsed
            } catch let error as HTTPParserError {
                return .finished(error.outcome)
            } catch {
                return .finished(
                    .networkFailure(
                        reason: "response-headers-invalid",
                        retryable: false
                    )
                )
            }
        }

        guard let response else { return .needMore }
        if response.hasNoBody {
            return .finished(
                .response(
                    status: response.status,
                    headers: response.headers,
                    body: Data()
                )
            )
        }
        if response.isChunked {
            switch decodeChunked(buffer) {
            case .incomplete:
                return isComplete
                    ? .finished(
                        .networkFailure(
                            reason: "chunked-response-incomplete",
                            retryable: false
                        )
                    )
                    : .needMore
            case .invalid:
                return .finished(
                    .networkFailure(
                        reason: "chunked-response-invalid",
                        retryable: false
                    )
                )
            case let .complete(body):
                guard body.count <= maximumBodyBytes else {
                    return .finished(
                        .responseUnavailable(
                            reason: "response-body-limit-exceeded"
                        )
                    )
                }
                return .finished(
                    .response(
                        status: response.status,
                        headers: response.headers,
                        body: body
                    )
                )
            }
        }
        if let contentLength = response.contentLength {
            guard contentLength <= maximumBodyBytes else {
                return .finished(
                    .responseUnavailable(
                        reason: "response-body-limit-exceeded"
                    )
                )
            }
            guard buffer.count >= contentLength else {
                return isComplete
                    ? .finished(
                        .networkFailure(
                            reason: "response-body-incomplete",
                            retryable: false
                        )
                    )
                    : .needMore
            }
            return .finished(
                .response(
                    status: response.status,
                    headers: response.headers,
                    body: Data(buffer.prefix(contentLength))
                )
            )
        }
        guard buffer.count <= maximumBodyBytes else {
            return .finished(
                .responseUnavailable(reason: "response-body-limit-exceeded")
            )
        }
        guard isComplete else { return .needMore }
        return .finished(
            .response(
                status: response.status,
                headers: response.headers,
                body: buffer
            )
        )
    }

    private func parseHeaders(_ data: Data) throws -> ParsedResponse {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw HTTPParserError.invalidHeaders
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTPParserError.invalidHeaders
        }
        let statusComponents = statusLine.split(separator: " ")
        guard statusComponents.count >= 2,
              statusComponents[0].hasPrefix("HTTP/1."),
              let status = Int(statusComponents[1]),
              (100 ... 599).contains(status)
        else {
            throw HTTPParserError.invalidHeaders
        }

        var headers: [NetworkIntentProvider.Header] = []
        var aggregateEncodedBytes = 2
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPParserError.invalidHeaders
            }
            let name = String(line[..<separator])
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.count <= 8_192,
                  value.utf8.count <= 16_384
            else {
                throw HTTPParserError.headersLimitExceeded
            }
            let headerValue = IntentValue.object([
                "name": .string(name),
                "value": .string(value),
            ])
            guard let accounting = try? headerValue.accounting() else {
                throw HTTPParserError.headersLimitExceeded
            }
            let separatorBytes = headers.isEmpty ? 0 : 1
            let (withValue, valueOverflow) = aggregateEncodedBytes
                .addingReportingOverflow(accounting.encodedBytes)
            let (nextTotal, separatorOverflow) = withValue
                .addingReportingOverflow(separatorBytes)
            guard !valueOverflow,
                  !separatorOverflow,
                  nextTotal
                  <= NetworkIntentProvider.maximumResponseHeaderEncodedBytes
            else {
                throw HTTPParserError.headersLimitExceeded
            }
            aggregateEncodedBytes = nextTotal
            headers.append(
                NetworkIntentProvider.Header(name: name, value: value)
            )
        }

        let contentLengths = headers
            .filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .compactMap { Int($0.value) }
        guard Set(contentLengths).count <= 1 else {
            throw HTTPParserError.invalidHeaders
        }
        let transferEncodings = headers
            .filter {
                $0.name.caseInsensitiveCompare("Transfer-Encoding")
                    == .orderedSame
            }
            .map { $0.value.lowercased() }
        let isChunked = transferEncodings.contains {
            $0.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.contains("chunked")
        }
        guard !(isChunked && !contentLengths.isEmpty) else {
            throw HTTPParserError.invalidHeaders
        }
        return ParsedResponse(
            status: status,
            headers: headers.sorted {
                let left = $0.name.lowercased()
                let right = $1.name.lowercased()
                return left == right ? $0.value < $1.value : left < right
            },
            contentLength: contentLengths.first,
            isChunked: isChunked,
            hasNoBody: requestMethodHasNoResponseBody(status: status)
        )
    }

    private func requestMethodHasNoResponseBody(status: Int) -> Bool {
        requestMethod == "HEAD"
            || (100 ... 199).contains(status)
            || status == 204
            || status == 304
    }

    private func decodeChunked(_ data: Data) -> ChunkedResult {
        var index = data.startIndex
        var body = Data()
        let delimiter = Data("\r\n".utf8)
        while true {
            guard let lineRange = data.range(
                of: delimiter,
                in: index ..< data.endIndex
            ) else {
                return .incomplete
            }
            guard lineRange.lowerBound - index <= 128,
                  let line = String(
                      data: data[index ..< lineRange.lowerBound],
                      encoding: .ascii
                  ),
                  let sizeText = line.split(separator: ";").first,
                  let size = Int(sizeText, radix: 16),
                  size >= 0
            else {
                return .invalid
            }
            index = lineRange.upperBound
            if size == 0 {
                guard data.count >= index + 2 else { return .incomplete }
                return data[index ..< index + 2] == delimiter
                    ? .complete(body)
                    : .invalid
            }
            guard size <= maximumBodyBytes,
                  body.count <= maximumBodyBytes - size,
                  data.count >= index + size + 2
            else {
                return size > maximumBodyBytes
                    || body.count > maximumBodyBytes - size
                    ? .complete(Data(repeating: 0, count: maximumBodyBytes + 1))
                    : .incomplete
            }
            body.append(data[index ..< index + size])
            index += size
            guard data[index ..< index + 2] == delimiter else {
                return .invalid
            }
            index += 2
        }
    }

    private struct ParsedResponse {
        let status: Int
        let headers: [NetworkIntentProvider.Header]
        let contentLength: Int?
        let isChunked: Bool
        let hasNoBody: Bool
    }

    private enum ChunkedResult {
        case incomplete
        case invalid
        case complete(Data)
    }
}

private enum HTTPParserError: Error {
    case invalidHeaders
    case headersLimitExceeded

    var outcome: NetworkIntentProvider.TransportOutcome {
        switch self {
        case .invalidHeaders:
            .networkFailure(
                reason: "response-headers-invalid",
                retryable: false
            )
        case .headersLimitExceeded:
            .responseUnavailable(
                reason: "response-headers-limit-exceeded"
            )
        }
    }
}
