import Foundation
import Yams

/// Turns a docker-compose file into the specs the deploy pipeline consumes,
/// one per service. This is NOT a full compose engine: it creates containers
/// from services (image / ports / volumes / environment / restart / command /
/// labels / network / limits). `build:`, `depends_on` ordering, healthchecks,
/// secrets, configs and profiles are ignored — with a warning where it matters.
enum ComposeParser {
    struct Result {
        var services: [ContainerSpec]
        var warnings: [String]
        var project: String
    }

    static func parse(yaml text: String) throws -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimpleError("Paste a docker-compose YAML first.")
        }
        let document: Any?
        do {
            document = try Yams.load(yaml: text)
        } catch {
            let firstLine = error.localizedDescription.components(separatedBy: "\n").first ?? "invalid YAML"
            throw SimpleError("YAML parse error: \(firstLine)")
        }
        guard let root = document as? [String: Any],
              let servicesMap = root["services"] as? [String: Any], !servicesMap.isEmpty else {
            throw SimpleError("No \"services:\" section found in the YAML.")
        }

        var warnings: [String] = []
        var services: [ContainerSpec] = []

        for (name, rawService) in servicesMap.sorted(by: { $0.key < $1.key }) {
            guard let service = rawService as? [String: Any] else {
                warnings.append("Skipped \"\(name)\" — not a service map.")
                continue
            }
            if service["build"] != nil && service["image"] == nil {
                warnings.append("Skipped \"\(name)\" — uses build:, which Portside can't do. Give it an image:.")
                continue
            }
            guard let image = service["image"].map({ String(describing: $0) }), !image.isEmpty else {
                warnings.append("Skipped \"\(name)\" — no image:.")
                continue
            }
            if service["depends_on"] != nil {
                warnings.append("\"\(name)\" has depends_on — start order isn't guaranteed.")
            }

            var spec = ContainerSpec()
            spec.image = image
            spec.service = name
            spec.name = (service["container_name"] as? String) ?? name
            spec.ports = parsePorts(service["ports"])
            spec.volumes = parseVolumes(service["volumes"], serviceName: name, warnings: &warnings)
            spec.env = parseEnvironment(service["environment"])
            spec.command = parseCommand(service["command"])
            spec.labels = parseLabels(service["labels"])
            spec.restart = parseRestart(service["restart"])
            spec.network = parseNetwork(service, serviceName: name, warnings: &warnings)
            (spec.memoryMB, spec.cpus) = parseLimits(service, serviceName: name, warnings: &warnings)

            services.append(spec)
        }

        guard !services.isEmpty else {
            throw SimpleError("No usable services with an image: were found.")
        }
        let project = (root["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Result(services: services, warnings: warnings, project: project)
    }

    // MARK: - Field parsers

    private static func asList(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let value { return [value] }
        return []
    }

    /// ports: "h:c", "h:c/proto", "c", "ip:h:c", or long form {published, target, protocol}
    private static func parsePorts(_ value: Any?) -> [ContainerSpec.PortSpec] {
        var ports: [ContainerSpec.PortSpec] = []
        for entry in asList(value) {
            if let map = entry as? [String: Any] {
                guard let target = map["target"] else { continue }
                let published = map["published"] ?? target
                ports.append(ContainerSpec.PortSpec(
                    host: String(describing: published),
                    container: String(describing: target),
                    proto: (map["protocol"] as? String) ?? "tcp"
                ))
                continue
            }
            var text = String(describing: entry)
            var proto = "tcp"
            if let slash = text.firstIndex(of: "/") {
                proto = String(text[text.index(after: slash)...])
                text = String(text[..<slash])
            }
            let segments = text.split(separator: ":").map(String.init)
            let (host, container): (String, String)
            switch segments.count {
            case 1: (host, container) = (segments[0], segments[0])
            case 2: (host, container) = (segments[0], segments[1])
            default: (host, container) = (segments[segments.count - 2], segments[segments.count - 1]) // ip:host:cont → drop ip
            }
            ports.append(ContainerSpec.PortSpec(
                host: host.trimmingCharacters(in: .whitespaces),
                container: container.trimmingCharacters(in: .whitespaces),
                proto: proto.isEmpty ? "tcp" : proto
            ))
        }
        return ports
    }

    /// volumes: "src:dst[:ro]" (named or path); long form {source, target, read_only}
    private static func parseVolumes(
        _ value: Any?, serviceName: String, warnings: inout [String]
    ) -> [ContainerSpec.VolumeSpec] {
        var volumes: [ContainerSpec.VolumeSpec] = []
        for entry in asList(value) {
            if let map = entry as? [String: Any] {
                guard let source = map["source"], let target = map["target"] else { continue }
                let readOnly = (map["read_only"] as? Bool) == true
                volumes.append(ContainerSpec.VolumeSpec(
                    host: String(describing: source),
                    container: String(describing: target) + (readOnly ? ":ro" : "")
                ))
                continue
            }
            let text = String(describing: entry)
            guard let colon = text.firstIndex(of: ":") else {
                warnings.append("\"\(serviceName)\": anonymous volume \"\(text)\" skipped.")
                continue
            }
            volumes.append(ContainerSpec.VolumeSpec(
                host: String(text[..<colon]).trimmingCharacters(in: .whitespaces),
                container: String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return volumes
    }

    /// environment: list ["K=V"] or map {K: V}
    private static func parseEnvironment(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.map { String(describing: $0) }
        }
        if let map = value as? [String: Any] {
            return map.sorted { $0.key < $1.key }.map { key, val in
                "\(key)=\(val is NSNull ? "" : String(describing: val))"
            }
        }
        return []
    }

    /// command: array → Cmd; string → sh -c
    private static func parseCommand(_ value: Any?) -> [String]? {
        if let list = value as? [Any], !list.isEmpty {
            return list.map { String(describing: $0) }
        }
        if let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return ["sh", "-c", text.trimmingCharacters(in: .whitespaces)]
        }
        return nil
    }

    /// labels: list ["k=v"] or map {k: v}
    private static func parseLabels(_ value: Any?) -> [String: String] {
        var labels: [String: String] = [:]
        if let list = value as? [Any] {
            for entry in list {
                let text = String(describing: entry)
                guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
                labels[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
        } else if let map = value as? [String: Any] {
            for (key, val) in map {
                labels[key] = val is NSNull ? "" : String(describing: val)
            }
        }
        return labels
    }

    private static func parseRestart(_ value: Any?) -> String {
        guard let text = (value as? String), !text.isEmpty else { return "" }
        return ["no", "always", "on-failure", "unless-stopped"].contains(text) ? text : "unless-stopped"
    }

    /// network_mode wins; else the first named network (which must already exist).
    private static func parseNetwork(
        _ service: [String: Any], serviceName: String, warnings: inout [String]
    ) -> String {
        if let mode = service["network_mode"] as? String, !mode.isEmpty {
            return mode
        }
        var first: String?
        if let list = service["networks"] as? [Any] {
            first = list.first.map { String(describing: $0) }
        } else if let map = service["networks"] as? [String: Any] {
            first = map.keys.sorted().first
        }
        if let first {
            warnings.append("\"\(serviceName)\" → network \"\(first)\" must already exist on the host.")
            return first
        }
        return ""
    }

    /// limits: mem_limit / cpus (compose v2 style) or deploy.resources.limits (v3)
    private static func parseLimits(
        _ service: [String: Any], serviceName: String, warnings: inout [String]
    ) -> (memoryMB: Double, cpus: Double) {
        let deploy = service["deploy"] as? [String: Any]
        let resources = deploy?["resources"] as? [String: Any]
        let limits = resources?["limits"] as? [String: Any]

        var memoryMB = 0.0
        let memoryValue = service["mem_limit"] ?? limits?["memory"]
        if let memoryValue {
            let text = String(describing: memoryValue).trimmingCharacters(in: .whitespaces)
            if let match = text.wholeMatch(of: /([\d.]+)\s*([kKmMgG])?[bB]?/),
               let amount = Double(match.1) {
                let multiplier: Double
                switch match.2?.lowercased() {
                case "k": multiplier = 1.0 / 1024
                case "g": multiplier = 1024
                default: multiplier = 1
                }
                memoryMB = (amount * multiplier).rounded()
            } else {
                warnings.append("\"\(serviceName)\": couldn't read mem_limit \"\(text)\" — no memory limit applied.")
            }
        }

        var cpus = 0.0
        let cpuValue = service["cpus"] ?? limits?["cpus"]
        if let cpuValue, let parsed = Double(String(describing: cpuValue)) {
            cpus = parsed
        }
        return (memoryMB, cpus)
    }
}
