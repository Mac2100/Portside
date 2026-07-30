import Foundation
import Network
import Security

/// A minimal HTTP/1.1 client over `NWConnection` with mutual-TLS.
///
/// URLSession cannot present a client certificate *and* hijack the connection
/// the way the Docker exec API requires (`Connection: Upgrade` followed by a
/// raw bidirectional byte stream), so Portside speaks HTTP/1.1 itself: one
/// connection per request, supporting fixed-length, chunked, and
/// read-until-close bodies, plus the upgrade path used by the terminal.
final class DockerTransport: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    enum TransportError: LocalizedError {
        case timeout
        case connectionFailed(String)
        case badResponse
        case tlsRejected

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Request timed out"
            case .connectionFailed(let detail):
                return detail
            case .badResponse:
                return "Malformed HTTP response from the Docker host"
            case .tlsRejected:
                return "Couldn't verify the host: its certificate does not chain to your imported ca.pem. Re-import the certificates from Container Station, or disable verification in Settings."
            }
        }
    }

    let host: String
    let port: Int
    let identity: TLSIdentity
    let insecure: Bool

    init(host: String, port: Int, identity: TLSIdentity, insecure: Bool) {
        self.host = host
        self.port = port
        self.identity = identity
        self.insecure = insecure
    }

    // MARK: - Connection setup

    private func makeConnection() -> NWConnection {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }

        let ca = identity.caCertificate
        let allowAny = insecure
        sec_protocol_options_set_verify_block(options, { _, secTrust, complete in
            if allowAny {
                complete(true)
                return
            }
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            complete(TLSIdentity.evaluate(trust: trust, against: ca))
        }, DispatchQueue.global(qos: .userInitiated))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)

        return NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 2376,
            using: parameters
        )
    }

    private func start(_ connection: NWConnection) async throws {
        let queue = DispatchQueue(label: "portside.docker.connection")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.trySet() { continuation.resume() }
                case .failed(let error):
                    if done.trySet() {
                        continuation.resume(throwing: Self.friendly(error))
                    }
                case .cancelled:
                    if done.trySet() {
                        continuation.resume(throwing: TransportError.connectionFailed("Connection cancelled"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func friendly(_ error: NWError) -> Error {
        if case .tls = error {
            return TransportError.tlsRejected
        }
        return TransportError.connectionFailed("Can't reach the Docker host: \(error.localizedDescription)")
    }

    // MARK: - Requests

    /// Performs a request and buffers the entire response body.
    func request(
        _ method: String,
        _ path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        let connection = makeConnection()
        defer { connection.cancel() }

        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            connection.cancel()
        }
        defer { deadline.cancel() }

        try await start(connection)
        try await send(connection, requestData(method: method, path: path, headers: headers, body: body))

        var reader = HTTPReader(connection: connection)
        let head = try await reader.readHead()
        let data = try await reader.readBody(head: head, method: method)
        return Response(status: head.status, headers: head.headers, body: data)
    }

    /// JSON convenience: decodes the response body into `T`.
    func requestJSON<T: Decodable>(
        _ type: T.Type,
        _ method: String,
        _ path: String,
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> T {
        let response = try await request(method, path, body: body, timeout: timeout)
        guard (200..<300).contains(response.status) else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    /// Performs a request and streams the response body chunk-by-chunk.
    /// Used for `/events`, `logs?follow`, and image pull progress.
    /// The stream finishes when the server closes the connection or the
    /// consumer cancels.
    func stream(
        _ method: String,
        _ path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        onResponse: (@Sendable (Int) -> Void)? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let connection = makeConnection()
            continuation.onTermination = { _ in connection.cancel() }

            Task {
                do {
                    try await self.start(connection)
                    try await self.send(connection, self.requestData(method: method, path: path, headers: headers, body: body))
                    var reader = HTTPReader(connection: connection)
                    let head = try await reader.readHead()
                    onResponse?(head.status)
                    guard (200..<300).contains(head.status) else {
                        let data = try await reader.readBody(head: head, method: method)
                        throw DockerAPIError(status: head.status, body: data)
                    }
                    try await reader.streamBody(head: head) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Upgrade (exec hijack)

    /// A live bidirectional byte stream after a successful `Connection: Upgrade`.
    final class HijackedStream: @unchecked Sendable {
        private let connection: NWConnection
        let incoming: AsyncThrowingStream<Data, Error>

        init(connection: NWConnection, leftover: Data) {
            self.connection = connection
            self.incoming = AsyncThrowingStream { continuation in
                if !leftover.isEmpty { continuation.yield(leftover) }
                continuation.onTermination = { _ in connection.cancel() }
                Self.pump(connection: connection, continuation: continuation)
            }
        }

        private static func pump(
            connection: NWConnection,
            continuation: AsyncThrowingStream<Data, Error>.Continuation
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.yield(data)
                }
                if complete || error != nil {
                    continuation.finish()
                    return
                }
                pump(connection: connection, continuation: continuation)
            }
        }

        func write(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func close() {
            connection.cancel()
        }
    }

    /// POSTs to `path` requesting a connection upgrade; on 101, returns the raw
    /// stream (used by `POST /exec/{id}/start` for the interactive terminal).
    func upgrade(
        _ path: String,
        body: Data,
        timeout: TimeInterval = 15
    ) async throws -> HijackedStream {
        let connection = makeConnection()

        do {
            let deadline = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                connection.cancel()
            }
            defer { deadline.cancel() }

            try await start(connection)
            var headers = [
                "Content-Type": "application/json",
                "Connection": "Upgrade",
                "Upgrade": "tcp"
            ]
            headers["Content-Length"] = String(body.count)
            try await send(connection, requestData(method: "POST", path: path, headers: headers, body: body, includeLength: false))

            var reader = HTTPReader(connection: connection)
            let head = try await reader.readHead()
            // Docker answers 101 Switching Protocols (or, on some builds, 200)
            // and then the socket carries the raw TTY stream.
            guard head.status == 101 || head.status == 200 else {
                let data = try await reader.readBody(head: head, method: "POST")
                throw DockerAPIError(status: head.status, body: data)
            }
            return HijackedStream(connection: connection, leftover: reader.leftover)
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: - Wire format

    private func requestData(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?,
        includeLength: Bool = true
    ) -> Data {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host):\(port)"]
        var merged = headers
        if merged["Content-Type"] == nil && body != nil {
            merged["Content-Type"] = "application/json"
        }
        if includeLength {
            merged["Content-Length"] = String(body?.count ?? 0)
            if merged["Connection"] == nil { merged["Connection"] = "close" }
        }
        for (name, value) in merged {
            lines.append("\(name): \(value)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { data.append(body) }
        return data
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.friendly(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// An error response from the Docker Engine API, carrying its JSON `message`.
struct DockerAPIError: LocalizedError {
    let status: Int
    let message: String

    init(status: Int, body: Data) {
        self.status = status
        struct ErrorBody: Decodable { var message: String? }
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        self.message = decoded?.message ?? "HTTP \(status)"
    }

    var errorDescription: String? { message }
}

// MARK: - HTTP response parsing

private struct HTTPReader {
    let connection: NWConnection
    var buffer = Data()
    var closed = false

    struct Head {
        var status: Int
        var headers: [String: String]
    }

    /// Bytes received past the parsed headers (start of the body — or, after an
    /// upgrade, the first bytes of the raw stream).
    var leftover: Data { buffer }

    init(connection: NWConnection) {
        self.connection = connection
    }

    mutating func receiveMore() async throws -> Bool {
        if closed { return false }
        let (data, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: DockerTransport.TransportError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
        if let data { buffer.append(data) }
        if complete { closed = true }
        return data?.isEmpty == false
    }

    mutating func readHead() async throws -> Head {
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard let text = String(data: headData, encoding: .utf8) else {
                    throw DockerTransport.TransportError.badResponse
                }
                var lines = text.components(separatedBy: "\r\n")
                guard !lines.isEmpty else { throw DockerTransport.TransportError.badResponse }
                let statusLine = lines.removeFirst()
                let parts = statusLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2, let status = Int(parts[1]) else {
                    throw DockerTransport.TransportError.badResponse
                }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[name] = value
                }
                return Head(status: status, headers: headers)
            }
            guard try await receiveMore() || !closed else {
                throw DockerTransport.TransportError.badResponse
            }
            if closed && buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                throw DockerTransport.TransportError.badResponse
            }
        }
    }

    mutating func readBody(head: Head, method: String) async throws -> Data {
        if method == "HEAD" || head.status == 204 || head.status == 304 {
            return Data()
        }
        var collected = Data()
        try await streamBody(head: head) { collected.append($0) }
        return collected
    }

    /// Streams the body according to the framing the server chose.
    mutating func streamBody(head: Head, yield: (Data) -> Void) async throws {
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            try await streamChunked(yield: yield)
        } else if let lengthText = head.headers["content-length"], let length = Int(lengthText) {
            var remaining = length
            while remaining > 0 {
                if buffer.isEmpty {
                    guard try await receiveMore() || !closed else { break }
                    if closed && buffer.isEmpty { break }
                }
                let take = min(remaining, buffer.count)
                if take > 0 {
                    yield(buffer.prefix(take))
                    buffer.removeFirst(take)
                    remaining -= take
                }
            }
        } else {
            // Read until the server closes the connection.
            while true {
                if !buffer.isEmpty {
                    yield(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if closed { break }
                _ = try await receiveMore()
            }
        }
    }

    private mutating func streamChunked(yield: (Data) -> Void) async throws {
        while true {
            // Chunk size line.
            while buffer.range(of: Data("\r\n".utf8)) == nil {
                guard try await receiveMore() || !closed else { return }
                if closed && buffer.range(of: Data("\r\n".utf8)) == nil { return }
            }
            guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return }
            let sizeLine = String(data: buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound), encoding: .utf8) ?? ""
            buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
            let size = Int(sizeLine.split(separator: ";").first.map(String.init) ?? "", radix: 16) ?? 0
            if size == 0 {
                return
            }
            var remaining = size
            while remaining > 0 {
                if buffer.isEmpty {
                    guard try await receiveMore() || !closed else { return }
                    if closed && buffer.isEmpty { return }
                }
                let take = min(remaining, buffer.count)
                yield(buffer.prefix(take))
                buffer.removeFirst(take)
                remaining -= take
            }
            // Trailing CRLF after each chunk.
            while buffer.count < 2 {
                guard try await receiveMore() || !closed else { return }
                if closed && buffer.count < 2 { return }
            }
            buffer.removeFirst(min(2, buffer.count))
        }
    }
}

/// One-shot latch used to guard continuation resumption across state callbacks.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
