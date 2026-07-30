import Foundation

// MARK: - Hosts

/// A Docker host reachable over TLS (QNAP Container Station, or any
/// `dockerd --tlsverify` endpoint). Certificates are stored per host under
/// Application Support; `tlsInsecure` waives chain verification for hosts whose
/// certificates no longer chain to the imported CA.
struct DockerHost: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var host: String
    var port: Int

    init(id: String = UUID().uuidString, name: String, host: String, port: Int = 2376) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}

// MARK: - Containers

struct ContainerSummary: Identifiable, Decodable, Equatable {
    var Id: String
    var Names: [String]?
    var Image: String?
    var ImageID: String?
    var State: String?
    var Status: String?
    var Created: Int?
    var Ports: [PortBinding]?
    var Labels: [String: String]?
    var Mounts: [MountSummary]?
    var NetworkSettings: NetworkSummary?

    var id: String { Id }

    struct PortBinding: Decodable, Equatable, Hashable {
        var IP: String?
        var PrivatePort: Int
        var PublicPort: Int?
        var kind: String?

        private enum CodingKeys: String, CodingKey {
            case IP, PrivatePort, PublicPort
            case kind = "Type"
        }
    }

    struct MountSummary: Decodable, Equatable {
        var kind: String?
        var Name: String?
        var Source: String?
        var Destination: String?

        private enum CodingKeys: String, CodingKey {
            case Name, Source, Destination
            case kind = "Type"
        }
    }

    struct NetworkSummary: Decodable, Equatable {
        var Networks: [String: NetworkEndpoint]?
    }

    struct NetworkEndpoint: Decodable, Equatable {
        var IPAddress: String?
    }

    /// Container name without the leading slash Docker prepends.
    var name: String {
        (Names?.first ?? String(Id.prefix(12))).withoutLeadingSlash
    }

    var stateLowercased: String { (State ?? "").lowercased() }
    var isRunning: Bool { stateLowercased == "running" }
    var isRestarting: Bool { stateLowercased == "restarting" }
    var isPaused: Bool { stateLowercased == "paused" }
    var isExited: Bool { stateLowercased == "exited" }

    var isUnhealthy: Bool { (Status ?? "").localizedCaseInsensitiveContains("(unhealthy)") }
    var isHealthy: Bool { (Status ?? "").localizedCaseInsensitiveContains("(healthy)") }
    var isHealthStarting: Bool { (Status ?? "").localizedCaseInsensitiveContains("(health: starting)") }

    /// Non-zero exit code parsed from a "Exited (137) 2 hours ago" status.
    var crashExitCode: Int? {
        guard let status = Status,
              let match = status.firstMatch(of: /Exited \((\d+)\)/),
              let code = Int(match.1), code != 0 else { return nil }
        return code
    }

    var composeProject: String? {
        let value = Labels?["com.docker.compose.project"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    var composeService: String? {
        let value = Labels?["com.docker.compose.service"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Lowest published port — the best guess for "open its web UI".
    var primaryWebPort: Int? {
        Ports?.compactMap(\.PublicPort).min()
    }

    var shortImage: String {
        let image = (Image ?? "").split(separator: "@").first.map(String.init) ?? ""
        return image
    }
}

// MARK: - Inspect (full container configuration)

struct ContainerDetails: Decodable {
    var Id: String?
    var Name: String?
    var Created: String?
    var RestartCount: Int?
    var State: DetailState?
    var Config: DetailConfig?
    var HostConfig: HostConfigDetails?
    var Mounts: [MountDetails]?
    var NetworkSettings: NetworkSettingsDetails?

    struct DetailState: Decodable {
        var Running: Bool?
        var Health: Health?

        struct Health: Decodable {
            var Status: String?
        }
    }

    struct DetailConfig: Decodable {
        var Image: String?
        var Hostname: String?
        var Env: [String]?
        var Cmd: [String]?
        var Entrypoint: [String]?
        var User: String?
        var WorkingDir: String?
        var Tty: Bool?
        var Labels: [String: String]?
        var ExposedPorts: [String: EmptyObject]?
    }

    struct HostConfigDetails: Decodable {
        var Binds: [String]?
        var PortBindings: [String: [HostPort]?]?
        var RestartPolicy: RestartPolicy?
        var NetworkMode: String?
        var Memory: Int64?
        var NanoCpus: Int64?
        var Privileged: Bool?
        var Devices: [Device]?
        var CapAdd: [String]?

        struct HostPort: Decodable {
            var HostIp: String?
            var HostPort: String?
        }

        struct RestartPolicy: Decodable {
            var Name: String?
            var MaximumRetryCount: Int?
        }

        struct Device: Decodable {
            var PathOnHost: String?
            var PathInContainer: String?
            var CgroupPermissions: String?
        }
    }

    struct MountDetails: Decodable {
        var kind: String?
        var Name: String?
        var Source: String?
        var Destination: String?
        var RW: Bool?

        private enum CodingKeys: String, CodingKey {
            case Name, Source, Destination, RW
            case kind = "Type"
        }
    }

    struct NetworkSettingsDetails: Decodable {
        var Networks: [String: NetworkEndpointDetails]?
    }

    struct NetworkEndpointDetails: Decodable {
        var Aliases: [String]?
    }

    struct EmptyObject: Decodable {}

    var name: String { (Name ?? "").withoutLeadingSlash }
}

// MARK: - Stats

/// One sample from `/containers/{id}/stats?stream=false`.
struct ContainerStatsSample: Decodable {
    var cpu_stats: CPUStats?
    var precpu_stats: CPUStats?
    var memory_stats: MemoryStats?
    var networks: [String: NetworkStats]?
    var blkio_stats: BlkioStats?
    var pids_stats: PidsStats?

    struct CPUStats: Decodable {
        var cpu_usage: CPUUsage?
        var system_cpu_usage: Int64?
        var online_cpus: Int?

        struct CPUUsage: Decodable {
            var total_usage: Int64?
            var percpu_usage: [Int64]?
        }
    }

    struct MemoryStats: Decodable {
        var usage: Int64?
        var limit: Int64?
        var stats: Inner?

        struct Inner: Decodable {
            var cache: Int64?
        }
    }

    struct NetworkStats: Decodable {
        var rx_bytes: Int64?
        var tx_bytes: Int64?
    }

    struct BlkioStats: Decodable {
        var io_service_bytes_recursive: [BlkioEntry]?

        struct BlkioEntry: Decodable {
            var op: String?
            var value: Int64?
        }
    }

    struct PidsStats: Decodable {
        var current: Int?
    }

    /// Derived metrics matching `docker stats` semantics.
    struct Computed {
        var cpuPercent: Double
        var memUsed: Int64
        var memLimit: Int64
        var memPercent: Double
        var rxBytes: Int64
        var txBytes: Int64
        var blockRead: Int64
        var blockWrite: Int64
        var pids: Int
    }

    func computed(hostCPUs fallbackCPUs: Int) -> Computed {
        let cpuDelta = Double((cpu_stats?.cpu_usage?.total_usage ?? 0) - (precpu_stats?.cpu_usage?.total_usage ?? 0))
        let sysDelta = Double((cpu_stats?.system_cpu_usage ?? 0) - (precpu_stats?.system_cpu_usage ?? 0))
        let cpus = cpu_stats?.online_cpus
            ?? cpu_stats?.cpu_usage?.percpu_usage?.count
            ?? max(fallbackCPUs, 1)
        let cpu = sysDelta > 0 ? (cpuDelta / sysDelta) * Double(cpus) * 100 : 0

        let memUsed = max(0, (memory_stats?.usage ?? 0) - (memory_stats?.stats?.cache ?? 0))
        let memLimit = memory_stats?.limit ?? 0
        let memPct = memLimit > 0 ? Double(memUsed) / Double(memLimit) * 100 : 0

        let rx = (networks ?? [:]).values.reduce(Int64(0)) { $0 + ($1.rx_bytes ?? 0) }
        let tx = (networks ?? [:]).values.reduce(Int64(0)) { $0 + ($1.tx_bytes ?? 0) }
        let entries = blkio_stats?.io_service_bytes_recursive ?? []
        let read = entries.filter { $0.op?.lowercased() == "read" }.reduce(Int64(0)) { $0 + ($1.value ?? 0) }
        let write = entries.filter { $0.op?.lowercased() == "write" }.reduce(Int64(0)) { $0 + ($1.value ?? 0) }

        return Computed(
            cpuPercent: cpu, memUsed: memUsed, memLimit: memLimit, memPercent: memPct,
            rxBytes: rx, txBytes: tx, blockRead: read, blockWrite: write,
            pids: pids_stats?.current ?? 0
        )
    }
}

// MARK: - Images / volumes / networks

struct ImageSummary: Identifiable, Decodable, Equatable {
    var Id: String
    var RepoTags: [String]?
    var RepoDigests: [String]?
    var Size: Int64?
    var Created: Int?

    var id: String { Id }

    var tags: [String] {
        (RepoTags ?? []).filter { $0 != "<none>:<none>" }
    }

    var isDangling: Bool { tags.isEmpty }

    var shortID: String {
        Id.replacingOccurrences(of: "sha256:", with: "").prefix(12).description
    }
}

struct ImageDetails: Decodable {
    var RepoDigests: [String]?
}

struct VolumeSummary: Identifiable, Decodable, Equatable {
    var Name: String
    var Driver: String?
    var Mountpoint: String?

    var id: String { Name }
}

struct VolumeList: Decodable {
    var Volumes: [VolumeSummary]?
}

struct NetworkSummary: Identifiable, Decodable, Equatable {
    var Id: String
    var Name: String
    var Driver: String?
    var Scope: String?
    var Internal: Bool?
    var Attachable: Bool?
    var IPAM: IPAM?

    var id: String { Id }

    struct IPAM: Decodable, Equatable {
        var Config: [Config]?

        struct Config: Decodable, Equatable {
            var Subnet: String?
        }
    }

    var subnet: String? { IPAM?.Config?.first?.Subnet }

    static let builtinNames: Set<String> = ["bridge", "host", "none"]
    var isBuiltin: Bool { Self.builtinNames.contains(Name) }
}

// MARK: - System

struct SystemInfo: Decodable {
    var ServerVersion: String?
    var NCPU: Int?
    var MemTotal: Int64?
    var OperatingSystem: String?
    var Name: String?
}

/// `/system/df` — disk usage, used by Insights housekeeping.
struct DiskUsage: Decodable {
    var LayersSize: Int64?
    var Images: [ImageSummary]?
    var Containers: [ContainerSummary]?
    var Volumes: [VolumeUsage]?

    struct VolumeUsage: Decodable {
        var Name: String?
        var UsageData: UsageData?

        struct UsageData: Decodable {
            var Size: Int64?
            var RefCount: Int?
        }
    }
}

// MARK: - Events

struct DockerEvent: Identifiable, Equatable {
    let id = UUID()
    var time: Date
    var type: String
    var action: String
    var name: String
    var extra: String
    var host: String

    /// Parses one line of the `/events` NDJSON stream. Filters out the noise
    /// generated by the app's own polling (exec, top, archive, prune).
    static func parse(line: String, host: String) -> DockerEvent? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let action = raw["Action"] as? String ?? ""
        if action.hasPrefix("exec_") || action == "top" || action.hasPrefix("archive") || action == "prune" {
            return nil
        }
        let type = raw["Type"] as? String ?? "container"
        guard ["container", "image", "volume", "network"].contains(type) else { return nil }
        let actor = raw["Actor"] as? [String: Any]
        let attrs = actor?["Attributes"] as? [String: String] ?? [:]
        let actorID = actor?["ID"] as? String ?? ""
        let seconds = raw["time"] as? Double ?? Date().timeIntervalSince1970
        let exitCode = attrs["exitCode"]
        return DockerEvent(
            time: Date(timeIntervalSince1970: seconds),
            type: type,
            action: action,
            name: attrs["name"] ?? attrs["image"] ?? String(actorID.prefix(12)),
            extra: exitCode.map { "exit \($0)" } ?? (type == "image" ? (attrs["name"] ?? "") : ""),
            host: host
        )
    }
}

// MARK: - Deploy / edit specifications

/// Everything needed to create (or recreate) a container. Built by the deploy
/// wizard, the compose importer, and the container editor.
struct ContainerSpec {
    var image: String = ""
    var name: String = ""
    var ports: [PortSpec] = []
    var volumes: [VolumeSpec] = []
    var env: [String] = []
    var command: [String]?
    var labels: [String: String] = [:]
    var restart: String = "unless-stopped"
    var network: String = ""
    /// Memory limit in MB; 0 = unlimited.
    var memoryMB: Double = 0
    /// CPU quota in cores; 0 = unlimited.
    var cpus: Double = 0
    /// Compose project name (stamps compose labels so the result groups as a stack).
    var project: String = ""
    /// Compose service name within the project.
    var service: String = ""

    struct PortSpec: Identifiable {
        let id = UUID()
        var host: String = ""
        var container: String = ""
        var proto: String = "tcp"
    }

    struct VolumeSpec: Identifiable {
        let id = UUID()
        var host: String = ""
        var container: String = ""
    }

    struct EnvSpec: Identifiable {
        let id = UUID()
        var value: String = ""
    }

    /// The JSON body for `POST /containers/create`.
    func createPayload() -> [String: Any] {
        var exposed: [String: Any] = [:]
        var bindings: [String: Any] = [:]
        for port in ports where !port.container.isEmpty {
            let key = "\(port.container)/\(port.proto.isEmpty ? "tcp" : port.proto)"
            exposed[key] = [String: Any]()
            bindings[key] = [["HostPort": port.host.isEmpty ? port.container : port.host]]
        }
        let binds = volumes
            .filter { !$0.host.isEmpty && !$0.container.isEmpty }
            .map { "\($0.host):\($0.container)" }

        var allLabels = labels
        if !project.isEmpty {
            // Stamp the same labels `docker compose up` would — that's what makes
            // Portside (and anything else that reads them) treat these containers
            // as one stack.
            allLabels["com.docker.compose.project"] = project
            allLabels["com.docker.compose.service"] = service.isEmpty ? name : service
        }

        var hostConfig: [String: Any] = [:]
        if !bindings.isEmpty { hostConfig["PortBindings"] = bindings }
        if !binds.isEmpty { hostConfig["Binds"] = binds }
        if !restart.isEmpty && restart != "no" { hostConfig["RestartPolicy"] = ["Name": restart] }
        if !network.isEmpty { hostConfig["NetworkMode"] = network }
        if memoryMB > 0 { hostConfig["Memory"] = Int64(memoryMB * 1024 * 1024) }
        if cpus > 0 { hostConfig["NanoCpus"] = Int64(cpus * 1e9) }

        var payload: [String: Any] = ["Image": image, "HostConfig": hostConfig]
        if let command, !command.isEmpty { payload["Cmd"] = command }
        if !allLabels.isEmpty { payload["Labels"] = allLabels }
        let cleanEnv = env.filter { $0.contains("=") }
        if !cleanEnv.isEmpty { payload["Env"] = cleanEnv }
        if !exposed.isEmpty { payload["ExposedPorts"] = exposed }
        return payload
    }
}

// MARK: - Crash logs

struct CrashLogEntry: Identifiable, Codable, Equatable {
    var file: String
    var name: String
    var containerId: String
    var exitCode: Int?
    var status: String
    var time: Date

    var id: String { file }
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024 && index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", amount, units[index])
    }

    static func bytes(_ value: Double) -> String {
        bytes(Int64(value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }

    static func relative(_ unixSeconds: Int?) -> String {
        guard let unixSeconds, unixSeconds > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: Double(unixSeconds))
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

extension String {
    /// Container names arrive from Docker with a leading slash; strip it.
    var withoutLeadingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}
