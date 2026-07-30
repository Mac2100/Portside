import Foundation

/// Exports a container's live configuration as a `docker run` command or a
/// `compose.yml` — so it can be rebuilt anywhere. Everything is derived from
/// `/containers/{id}/json` (inspect); the list API doesn't carry env, restart
/// policy, limits or the full binds.
enum ContainerExport {
    private static let skipLabelPrefixes = [
        "com.docker.compose.",     // compose re-adds these itself
        "org.opencontainers.",     // baked into the image, not user config
        "desktop.docker."
    ]

    struct Bits {
        var name: String
        var image: String
        var ports: [(host: String, inner: String)]
        var binds: [String]
        var env: [String]
        var labels: [(String, String)]
        var restart: String
        var networkMode: String
        var networks: [String]
        var memory: Int64
        var nanoCPUs: Int64
        var privileged: Bool
        var devices: [String]
        var capAdd: [String]
        var entrypoint: [String]
        var command: [String]
        var user: String
        var workingDir: String
        var tty: Bool
    }

    static func bits(from details: ContainerDetails) -> Bits {
        let config = details.Config
        let host = details.HostConfig

        var ports: [(String, String)] = []
        for (inner, bindings) in (host?.PortBindings ?? [:]).sorted(by: { $0.key < $1.key }) {
            for binding in bindings ?? [] {
                let ip = (binding.HostIp?.isEmpty == false && binding.HostIp != "0.0.0.0")
                    ? "\(binding.HostIp!):" : ""
                ports.append(("\(ip)\(binding.HostPort ?? "")", inner))
            }
        }

        // Prefer HostConfig.Binds (source:target:mode); fall back to Mounts.
        var binds = host?.Binds ?? []
        if binds.isEmpty {
            binds = (details.Mounts ?? [])
                .filter { $0.kind == "bind" || $0.kind == "volume" }
                .compactMap { mount in
                    guard let dest = mount.Destination else { return nil }
                    let source = mount.kind == "volume" ? (mount.Name ?? "") : (mount.Source ?? "")
                    guard !source.isEmpty else { return nil }
                    return "\(source):\(dest)\(mount.RW == false ? ":ro" : "")"
                }
        }

        // Env includes values baked into the image (PATH, LANG…) — inspect
        // can't tell them apart from user config, so keep them and say so in
        // the header comment. The most universal ones are dropped.
        let env = (config?.Env ?? []).filter { entry in
            !["PATH=", "HOME=", "HOSTNAME=", "TERM="].contains { entry.hasPrefix($0) }
        }

        let labels = (config?.Labels ?? [:])
            .filter { key, _ in !skipLabelPrefixes.contains { key.hasPrefix($0) } }
            .sorted { $0.key < $1.key }

        var restart = ""
        if let policy = host?.RestartPolicy?.Name, !policy.isEmpty, policy != "no" {
            if policy == "on-failure", let retries = host?.RestartPolicy?.MaximumRetryCount, retries > 0 {
                restart = "on-failure:\(retries)"
            } else {
                restart = policy
            }
        }

        let networks = (details.NetworkSettings?.Networks ?? [:]).keys
            .filter { !["bridge", "host", "none"].contains($0) }
            .sorted()

        let devices = (host?.Devices ?? []).map { device in
            let permissions = (device.CgroupPermissions?.isEmpty == false && device.CgroupPermissions != "rwm")
                ? ":\(device.CgroupPermissions!)" : ""
            return "\(device.PathOnHost ?? ""):\(device.PathInContainer ?? "")\(permissions)"
        }

        return Bits(
            name: details.name,
            image: config?.Image ?? "",
            ports: ports,
            binds: binds,
            env: env,
            labels: labels.map { ($0.key, $0.value) },
            restart: restart,
            networkMode: host?.NetworkMode ?? "",
            networks: networks,
            memory: host?.Memory ?? 0,
            nanoCPUs: host?.NanoCpus ?? 0,
            privileged: host?.Privileged ?? false,
            devices: devices,
            capAdd: host?.CapAdd ?? [],
            entrypoint: config?.Entrypoint ?? [],
            command: config?.Cmd ?? [],
            user: config?.User ?? "",
            workingDir: config?.WorkingDir ?? "",
            tty: config?.Tty ?? false
        )
    }

    /// Shell-quotes only when needed, so the output stays readable.
    private static func quote(_ value: String) -> String {
        let safe = value.allSatisfy {
            $0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)
        }
        return safe && !value.isEmpty
            ? value
            : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func dockerRun(_ b: Bits) -> String {
        var lines = ["docker run -d \\"]
        func add(_ segment: String) { lines.append("  \(segment) \\") }

        add("--name \(quote(b.name))")
        if !b.restart.isEmpty { add("--restart \(b.restart)") }
        if !b.networkMode.isEmpty && !["default", "bridge"].contains(b.networkMode) {
            add("--network \(quote(b.networkMode))")
        }
        for port in b.ports {
            let pieces = port.inner.split(separator: "/")
            let inner = pieces.first.map(String.init) ?? port.inner
            let proto = pieces.count > 1 ? String(pieces[1]) : "tcp"
            add("-p \(quote(port.host)):\(inner)\(proto == "udp" ? "/udp" : "")")
        }
        for bind in b.binds { add("-v \(quote(bind))") }
        for entry in b.env { add("-e \(quote(entry))") }
        for (key, value) in b.labels { add("--label \(quote("\(key)=\(value)"))") }
        if b.memory > 0 { add("--memory \(b.memory / 1_048_576)m") }
        if b.nanoCPUs > 0 { add("--cpus \(String(format: "%.2f", Double(b.nanoCPUs) / 1e9))") }
        if b.privileged { add("--privileged") }
        for device in b.devices { add("--device \(quote(device))") }
        for cap in b.capAdd { add("--cap-add \(quote(cap))") }
        if !b.user.isEmpty { add("--user \(quote(b.user))") }
        if !b.workingDir.isEmpty { add("--workdir \(quote(b.workingDir))") }
        if b.tty { add("-t") }
        if let entry = b.entrypoint.first { add("--entrypoint \(quote(entry))") }

        var last = quote(b.image)
        if !b.command.isEmpty {
            last += " " + b.command.map(quote).joined(separator: " ")
        }
        lines.append("  \(last)")

        return """
        # \(b.name) — exported from Portside on \(Date().formatted(date: .abbreviated, time: .shortened))
        # Env vars include values baked into the image (inspect can't tell them apart).
        # Review before running; bind-mount paths must exist on the target host.

        \(lines.joined(separator: "\n"))
        """
    }

    static func composeYAML(_ b: Bits) -> String {
        var y: [String] = []
        let service = b.name.isEmpty
            ? "app"
            : b.name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        y.append("# \(b.name) — exported from Portside on \(Date().formatted(date: .abbreviated, time: .shortened))")
        y.append("# Env vars include values baked into the image (inspect can't tell them apart).")
        y.append("")
        y.append("services:")
        y.append("  \(service):")
        y.append("    image: \(b.image)")
        y.append("    container_name: \(b.name)")
        if !b.restart.isEmpty { y.append("    restart: \(b.restart)") }
        if b.networkMode == "host" { y.append("    network_mode: host") }
        if b.privileged { y.append("    privileged: true") }
        if !b.user.isEmpty { y.append("    user: \"\(b.user)\"") }
        if !b.workingDir.isEmpty { y.append("    working_dir: \(b.workingDir)") }
        if !b.ports.isEmpty {
            y.append("    ports:")
            for port in b.ports {
                y.append("      - \"\(port.host):\(port.inner.replacingOccurrences(of: "/tcp", with: ""))\"")
            }
        }
        if !b.binds.isEmpty {
            y.append("    volumes:")
            for bind in b.binds { y.append("      - \"\(bind)\"") }
        }
        if !b.env.isEmpty {
            y.append("    environment:")
            for entry in b.env {
                guard let equals = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<equals])
                let value = String(entry[entry.index(after: equals)...])
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                y.append("      - \(key)=\(value)")
            }
        }
        if !b.labels.isEmpty {
            y.append("    labels:")
            for (key, value) in b.labels { y.append("      - \"\(key)=\(value)\"") }
        }
        if !b.devices.isEmpty {
            y.append("    devices:")
            for device in b.devices { y.append("      - \"\(device)\"") }
        }
        if !b.capAdd.isEmpty {
            y.append("    cap_add:")
            for cap in b.capAdd { y.append("      - \(cap)") }
        }
        if b.memory > 0 { y.append("    mem_limit: \(b.memory / 1_048_576)m") }
        if b.nanoCPUs > 0 { y.append("    cpus: \(String(format: "%.2f", Double(b.nanoCPUs) / 1e9))") }
        if !b.command.isEmpty {
            let encoded = (try? JSONSerialization.data(withJSONObject: b.command))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            y.append("    command: \(encoded)")
        }
        if !b.networks.isEmpty {
            y.append("    networks:")
            for network in b.networks { y.append("      - \(network)") }
            y.append("")
            y.append("networks:")
            for network in b.networks {
                y.append("  \(network):")
                y.append("    external: true")
            }
        }
        return y.joined(separator: "\n") + "\n"
    }
}
