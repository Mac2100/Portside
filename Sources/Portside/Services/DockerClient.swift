import Foundation

/// Typed Docker Engine API client for one host. Stateless besides the
/// transport configuration — every call opens its own connection.
final class DockerClient: @unchecked Sendable {
    let host: DockerHost
    private let transport: DockerTransport

    init(host: DockerHost, identity: TLSIdentity, insecure: Bool) {
        self.host = host
        self.transport = DockerTransport(
            host: host.host, port: host.port, identity: identity, insecure: insecure
        )
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?/+"))) ?? value
    }

    // MARK: - System

    func info() async throws -> SystemInfo {
        try await transport.requestJSON(SystemInfo.self, "GET", "/info")
    }

    func diskUsage() async throws -> DiskUsage {
        try await transport.requestJSON(DiskUsage.self, "GET", "/system/df", timeout: 30)
    }

    // MARK: - Containers

    func containers(all: Bool = true) async throws -> [ContainerSummary] {
        try await transport.requestJSON([ContainerSummary].self, "GET", "/containers/json?all=\(all)")
    }

    func inspect(id: String) async throws -> ContainerDetails {
        try await transport.requestJSON(ContainerDetails.self, "GET", "/containers/\(id)/json")
    }

    /// Raw inspect JSON, used when recreating a container (the full config is
    /// echoed back to `create` and round-tripping through typed models would
    /// silently drop fields Portside doesn't know about).
    func inspectRaw(id: String) async throws -> [String: Any] {
        let response = try await transport.request("GET", "/containers/\(id)/json")
        guard (200..<300).contains(response.status) else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw DockerTransport.TransportError.badResponse
        }
        return object
    }

    func stats(id: String) async throws -> ContainerStatsSample {
        try await transport.requestJSON(
            ContainerStatsSample.self, "GET",
            "/containers/\(id)/stats?stream=false", timeout: 20
        )
    }

    enum ContainerAction: String {
        case start, stop, restart, pause, unpause

        var confirmVerb: (String, String, String) {
            switch self {
            case .start: return ("Start", "Starting", "Started")
            case .stop: return ("Stop", "Stopping", "Stopped")
            case .restart: return ("Restart", "Restarting", "Restarted")
            case .pause: return ("Pause", "Pausing", "Paused")
            case .unpause: return ("Resume", "Resuming", "Resumed")
            }
        }
    }

    func perform(_ action: ContainerAction, id: String) async throws {
        let response = try await transport.request("POST", "/containers/\(id)/\(action.rawValue)", timeout: 40)
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    func remove(id: String, force: Bool = true) async throws {
        let response = try await transport.request("DELETE", "/containers/\(id)?force=\(force)", timeout: 60)
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    func rename(id: String, to name: String) async throws {
        let response = try await transport.request(
            "POST", "/containers/\(id)/rename?name=\(Self.percentEncode(name))"
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    func wait(id: String, timeout: TimeInterval = 180) async throws -> Int {
        struct WaitResult: Decodable { var StatusCode: Int? }
        let result = try await transport.requestJSON(WaitResult.self, "POST", "/containers/\(id)/wait", timeout: timeout)
        return result.StatusCode ?? -1
    }

    /// Fetches the log tail with Docker's multiplexed framing stripped.
    func logs(id: String, tail: Int = 200, timestamps: Bool = false) async throws -> String {
        let response = try await transport.request(
            "GET",
            "/containers/\(id)/logs?stdout=true&stderr=true&tail=\(tail)&timestamps=\(timestamps)",
            timeout: 20
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        return Self.demultiplex(response.body)
    }

    /// Follows the log stream. Yields demultiplexed text as it arrives; the
    /// stream ends when the container stops logging or the consumer cancels.
    func followLogs(id: String, tail: Int = 200) -> AsyncThrowingStream<Data, Error> {
        let upstream = transport.stream(
            "GET",
            "/containers/\(id)/logs?follow=true&stdout=true&stderr=true&tail=\(tail)"
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                var demuxer = StreamDemuxer()
                do {
                    for try await chunk in upstream {
                        let payload = demuxer.push(chunk)
                        if !payload.isEmpty { continuation.yield(payload) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Create / recreate

    func create(spec: ContainerSpec, name: String?) async throws -> String {
        var path = "/containers/create"
        if let name, !name.isEmpty { path += "?name=\(Self.percentEncode(name))" }
        let response = try await transport.request(
            "POST", path, body: encode(spec.createPayload()), timeout: 40
        )
        struct Created: Decodable { var Id: String? }
        guard response.status < 400,
              let created = try? JSONDecoder().decode(Created.self, from: response.body),
              let id = created.Id else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        return id
    }

    func createRaw(payload: [String: Any], name: String) async throws -> String {
        let response = try await transport.request(
            "POST", "/containers/create?name=\(Self.percentEncode(name))",
            body: encode(payload), timeout: 40
        )
        struct Created: Decodable { var Id: String? }
        guard response.status < 400,
              let created = try? JSONDecoder().decode(Created.self, from: response.body),
              let id = created.Id else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        return id
    }

    /// The stop → rename → create → start → delete dance shared by image
    /// updates and container edits, with rollback: if the replacement fails to
    /// start, the original is renamed back and restarted.
    func replace(
        id: String,
        buildPayload: ([String: Any]) throws -> (name: String, payload: [String: Any])
    ) async throws -> String {
        let raw = try await inspectRaw(id: id)
        let oldName = ((raw["Name"] as? String) ?? "").withoutLeadingSlash
        let state = raw["State"] as? [String: Any]
        let wasRunning = state?["Running"] as? Bool ?? false

        let (newName, payload) = try buildPayload(raw)

        if wasRunning {
            _ = try? await transport.request("POST", "/containers/\(id)/stop?t=20", timeout: 40)
        }
        let backupName = "\(oldName)-old-\(String(Int(Date().timeIntervalSince1970), radix: 36))"
        try await rename(id: id, to: backupName)

        var newID: String?
        do {
            let created = try await createRaw(payload: payload, name: newName)
            newID = created
            try await perform(.start, id: created)
            try? await remove(id: id, force: true)
            return created
        } catch {
            // Rollback: remove the half-made container, restore the old name, restart.
            if let newID { try? await remove(id: newID, force: true) }
            try? await rename(id: id, to: oldName)
            if wasRunning { try? await perform(.start, id: id) }
            throw error
        }
    }

    /// Rebuilds a create payload from a live inspect, preserving network
    /// endpoints (aliases, static IPs) and dropping the auto-generated hostname.
    static func recreatePayload(fromRaw raw: [String: Any], image: String? = nil) -> [String: Any] {
        var payload = raw["Config"] as? [String: Any] ?? [:]
        if let image { payload["Image"] = image }
        payload["HostConfig"] = raw["HostConfig"] as? [String: Any] ?? [:]

        let id = raw["Id"] as? String ?? ""
        if let hostname = payload["Hostname"] as? String, id.hasPrefix(hostname) {
            payload.removeValue(forKey: "Hostname")
        }

        let networkSettings = raw["NetworkSettings"] as? [String: Any]
        let networks = networkSettings?["Networks"] as? [String: Any] ?? [:]
        var endpoints: [String: Any] = [:]
        for (net, value) in networks {
            var endpoint: [String: Any] = [:]
            let config = value as? [String: Any]
            if let aliases = config?["Aliases"] as? [String] {
                endpoint["Aliases"] = aliases.filter { !id.hasPrefix($0) }
            }
            if let ipam = config?["IPAMConfig"] {
                endpoint["IPAMConfig"] = ipam
            }
            endpoints[net] = endpoint
        }
        if !endpoints.isEmpty {
            payload["NetworkingConfig"] = ["EndpointsConfig": endpoints]
        }
        return payload
    }

    // MARK: - Images

    func images() async throws -> [ImageSummary] {
        try await transport.requestJSON([ImageSummary].self, "GET", "/images/json")
    }

    func imageDetails(reference: String) async throws -> ImageDetails {
        try await transport.requestJSON(
            ImageDetails.self, "GET", "/images/\(Self.percentEncode(reference))/json"
        )
    }

    /// Pulls an image, streaming Docker's progress JSON. `auth` is the
    /// base64-encoded X-Registry-Auth payload for private registries.
    func pull(image: String, auth: String?, progress: (@Sendable (String) -> Void)? = nil) async throws {
        let ref = image.split(separator: "@").first.map(String.init) ?? image
        var repo = ref
        var tag = "latest"
        // The tag is the text after the last ':' — but only if it comes after
        // the last '/' (registry ports have colons too).
        if let colon = ref.lastIndex(of: ":") {
            let lastSlash = ref.lastIndex(of: "/")
            if lastSlash == nil || colon > lastSlash! {
                tag = String(ref[ref.index(after: colon)...])
                repo = String(ref[..<colon])
            }
        }
        var headers: [String: String] = [:]
        if let auth { headers["X-Registry-Auth"] = auth }

        var errorMessage: String?
        let stream = transport.stream(
            "POST",
            "/images/create?fromImage=\(Self.percentEncode(repo))&tag=\(Self.percentEncode(tag))",
            headers: headers,
            body: Data()
        )
        var buffer = Data()
        for try await chunk in stream {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let error = object["error"] as? String {
                    errorMessage = error
                }
                if let status = object["status"] as? String {
                    progress?(status)
                }
            }
        }
        if let errorMessage {
            throw SimpleError("Pull failed: \(errorMessage)")
        }
    }

    func removeImage(id: String, force: Bool) async throws {
        // Image IDs are passed with the "sha256:" prefix stripped: the plain
        // hex is path-safe, and percent-encoding the colon confuses routing.
        let ref = id.replacingOccurrences(of: "sha256:", with: "")
        let response = try await transport.request(
            "DELETE", "/images/\(ref)\(force ? "?force=true" : "")", timeout: 60
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    struct PruneResult: Decodable {
        var ImagesDeleted: [ImageDeleteItem]?
        var ContainersDeleted: [String]?
        var VolumesDeleted: [String]?
        var SpaceReclaimed: Int64?

        struct ImageDeleteItem: Decodable {
            var Untagged: String?
            var Deleted: String?
        }
    }

    /// `all: false` prunes dangling images only; `all: true` removes every
    /// image no container uses (dangling included).
    func pruneImages(all: Bool) async throws -> PruneResult {
        let filters = all
            ? "?filters=" + Self.percentEncode(#"{"dangling":["false"]}"#)
            : ""
        return try await transport.requestJSON(
            PruneResult.self, "POST", "/images/prune\(filters)", timeout: 90
        )
    }

    func pruneContainers() async throws -> PruneResult {
        try await transport.requestJSON(PruneResult.self, "POST", "/containers/prune", timeout: 90)
    }

    func pruneVolumes() async throws -> PruneResult {
        try await transport.requestJSON(PruneResult.self, "POST", "/volumes/prune", timeout: 90)
    }

    // MARK: - Volumes / networks

    func volumes() async throws -> [VolumeSummary] {
        try await transport.requestJSON(VolumeList.self, "GET", "/volumes").Volumes ?? []
    }

    func removeVolume(name: String, force: Bool) async throws {
        let response = try await transport.request(
            "DELETE", "/volumes/\(Self.percentEncode(name))\(force ? "?force=true" : "")", timeout: 60
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    func networks() async throws -> [NetworkSummary] {
        try await transport.requestJSON([NetworkSummary].self, "GET", "/networks")
    }

    func removeNetwork(id: String) async throws {
        let response = try await transport.request(
            "DELETE", "/networks/\(Self.percentEncode(id))", timeout: 30
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    // MARK: - Events

    /// Live `/events` stream, yielding parsed events line by line.
    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        let hostAddress = host.host
        let upstream = transport.stream("GET", "/events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await chunk in upstream {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let line = buffer.subdata(in: buffer.startIndex..<newline)
                            buffer.removeSubrange(buffer.startIndex...newline)
                            if let text = String(data: line, encoding: .utf8),
                               let event = DockerEvent.parse(line: text, host: hostAddress) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Backfills the last 24 hours of events so the Activity feed isn't empty
    /// until something happens after the live stream connects.
    func eventHistory() async throws -> [DockerEvent] {
        let now = Int(Date().timeIntervalSince1970)
        let response = try await transport.request(
            "GET", "/events?since=\(now - 86400)&until=\(now)", timeout: 25
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        let hostAddress = host.host
        guard let text = String(data: response.body, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            DockerEvent.parse(line: String($0), host: hostAddress)
        }
    }

    // MARK: - Exec

    struct ExecSession {
        let execID: String
        let stream: DockerTransport.HijackedStream
    }

    /// Opens an interactive shell in a running container (TTY mode), returning
    /// the hijacked stream the terminal reads from and writes to.
    func openShell(containerID: String, cols: Int, rows: Int) async throws -> ExecSession {
        let createBody = try encode([
            "AttachStdin": true, "AttachStdout": true, "AttachStderr": true, "Tty": true,
            "Env": ["TERM=xterm-256color"],
            "Cmd": ["/bin/sh", "-c", "if [ -x /bin/bash ]; then exec /bin/bash; else exec /bin/sh; fi"]
        ])
        struct ExecCreated: Decodable { var Id: String? }
        let created = try await transport.requestJSON(
            ExecCreated.self, "POST", "/containers/\(containerID)/exec", body: createBody
        )
        guard let execID = created.Id else {
            throw SimpleError("Exec create failed — is the container running?")
        }
        let startBody = try encode(["Detach": false, "Tty": true])
        let stream = try await transport.upgrade("/exec/\(execID)/start", body: startBody)
        if cols > 0 && rows > 0 {
            try? await resizeExec(execID: execID, cols: cols, rows: rows)
        }
        return ExecSession(execID: execID, stream: stream)
    }

    func resizeExec(execID: String, cols: Int, rows: Int) async throws {
        _ = try await transport.request("POST", "/exec/\(execID)/resize?h=\(rows)&w=\(cols)")
    }

    /// One-shot exec that captures stdout+stderr (used by the file browser's
    /// directory listings).
    func execCapture(containerID: String, command: String, timeout: TimeInterval = 25) async throws -> String {
        let createBody = try encode([
            "AttachStdout": true, "AttachStderr": true, "Tty": false,
            "Cmd": ["/bin/sh", "-c", command]
        ])
        struct ExecCreated: Decodable { var Id: String? }
        let created = try await transport.requestJSON(
            ExecCreated.self, "POST", "/containers/\(containerID)/exec", body: createBody
        )
        guard let execID = created.Id else {
            throw SimpleError("Exec create failed — is the container running?")
        }
        let startBody = try encode(["Detach": false, "Tty": false])
        let response = try await transport.request(
            "POST", "/exec/\(execID)/start", body: startBody, timeout: timeout
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
        return Self.demultiplex(response.body)
    }

    // MARK: - Archive (file browser)

    func downloadArchive(containerID: String, path: String, maxBytes: Int = 50 * 1024 * 1024) async throws -> Data {
        var collected = Data()
        let stream = transport.stream(
            "GET",
            "/containers/\(containerID)/archive?path=\(Self.percentEncode(path))"
        )
        for try await chunk in stream {
            collected.append(chunk)
            if collected.count > maxBytes {
                throw SimpleError("File too large (>\(maxBytes / 1_048_576) MB)")
            }
        }
        return collected
    }

    func uploadArchive(containerID: String, directory: String, tar: Data) async throws {
        let response = try await transport.request(
            "PUT",
            "/containers/\(containerID)/archive?path=\(Self.percentEncode(directory))",
            headers: ["Content-Type": "application/x-tar"],
            body: tar,
            timeout: 120
        )
        guard response.status < 400 else {
            throw DockerAPIError(status: response.status, body: response.body)
        }
    }

    // MARK: - Multiplexed stream demuxing

    /// Docker's non-TTY streams frame stdout/stderr as
    /// `[type(1), 0, 0, 0, len(4, BE), payload…]`. Strips headers; if the data
    /// doesn't look framed (TTY mode), passes it through unchanged.
    static func demultiplex(_ data: Data) -> String {
        var demuxer = StreamDemuxer()
        let payload = demuxer.push(data)
        return String(data: payload, encoding: .utf8)
            ?? String(decoding: payload, as: UTF8.self)
    }
}

/// Incremental demuxer for Docker's multiplexed stream framing. Detects on the
/// first bytes whether the stream is framed or raw and behaves accordingly.
struct StreamDemuxer {
    private var buffer = Data()
    private var mode: Mode = .undetermined

    private enum Mode { case undetermined, multiplexed, raw }

    mutating func push(_ chunk: Data) -> Data {
        buffer.append(chunk)
        if mode == .undetermined {
            guard buffer.count >= 8 else { return Data() }
            let bytes = [UInt8](buffer.prefix(4))
            mode = (bytes[0] <= 2 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0)
                ? .multiplexed : .raw
        }
        switch mode {
        case .raw:
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        case .multiplexed:
            var output = Data()
            while buffer.count >= 8 {
                let header = [UInt8](buffer.prefix(8))
                let length = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
                guard buffer.count >= 8 + length else { break }
                output.append(buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: 8)..<buffer.index(buffer.startIndex, offsetBy: 8 + length)))
                buffer.removeFirst(8 + length)
            }
            return output
        case .undetermined:
            return Data()
        }
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Minimal tar (for the Docker archive API)

enum Tar {
    /// Extracts the first regular file from a tar archive.
    static func extractFirstFile(_ data: Data) -> (name: String, content: Data)? {
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = cString(header, 0, 100)
            let sizeText = cString(header, 124, 12).trimmingCharacters(in: .whitespaces)
            let size = Int(sizeText, radix: 8) ?? 0
            let type = header[156]
            offset += 512
            if type == UInt8(ascii: "0") || type == 0 {
                let end = min(offset + size, bytes.count)
                return (name, Data(bytes[offset..<end]))
            }
            offset += ((size + 511) / 512) * 512
        }
        return nil
    }

    /// Builds a single-file tar archive (ustar) for uploads.
    static func create(name: String, content: Data, mode: UInt32 = 0o644) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        write(&header, String(name.prefix(99)), at: 0)
        write(&header, String(format: "%07o", mode & 0o7777), at: 100)
        write(&header, "0000000", at: 108)
        write(&header, "0000000", at: 116)
        write(&header, String(format: "%011o", content.count), at: 124)
        write(&header, String(format: "%011o", Int(Date().timeIntervalSince1970)), at: 136)
        for i in 148..<156 { header[i] = UInt8(ascii: " ") }   // checksum placeholder
        header[156] = UInt8(ascii: "0")
        write(&header, "ustar", at: 257)
        write(&header, "00", at: 263)
        let checksum = header.reduce(0) { $0 + Int($1) }
        write(&header, String(format: "%06o", checksum), at: 148)
        header[154] = 0
        header[155] = UInt8(ascii: " ")

        var archive = Data(header)
        archive.append(content)
        let padding = (512 - content.count % 512) % 512
        archive.append(Data(repeating: 0, count: padding + 1024))
        return archive
    }

    private static func cString(_ bytes: [UInt8], _ start: Int, _ length: Int) -> String {
        let slice = bytes[start..<min(start + length, bytes.count)]
        let terminated = slice.prefix { $0 != 0 }
        return String(decoding: terminated, as: UTF8.self)
    }

    private static func write(_ buffer: inout [UInt8], _ text: String, at offset: Int) {
        for (index, byte) in text.utf8.enumerated() where offset + index < buffer.count {
            buffer[offset + index] = byte
        }
    }
}
