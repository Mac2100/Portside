import SwiftUI

/// The inspector column shown next to the container list.
struct ContainerDetailView: View {
    @EnvironmentObject private var appState: AppState
    var container: ContainerSummary
    var onEdit: () -> Void

    @State private var stats: ContainerStatsSample.Computed?
    @State private var exportTarget: ContainerSummary?
    @State private var gitDeployTarget: ContainerSummary?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                actionButtons
                if container.isRunning, let stats {
                    statsSection(stats)
                }
                infoSection
                portsSection
                mountsSection
            }
            .padding(14)
        }
        .task(id: container.Id) {
            await loadStats()
        }
        .sheet(item: $exportTarget) { target in
            ExportSheet(container: target)
        }
        .sheet(item: $gitDeployTarget) { target in
            GitDeploySheet(container: target)
        }
        .sheet(isPresented: $confirmRemove) {
            RemoveContainersSheet(names: [container.name]) {
                Task { await appState.removeContainer(container) }
            }
        }
    }

    private func loadStats() async {
        while !Task.isCancelled {
            if container.isRunning, let client = appState.client,
               let sample = try? await client.stats(id: container.Id) {
                stats = sample.computed(hostCPUs: appState.systemInfo?.NCPU ?? 1)
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(of: container))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                StateBadge(container: container)
            }
            Spacer()
            Button {
                appState.selectedContainerID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if container.isRunning {
                    Button {
                        Task { await appState.perform(.stop, on: container) }
                    } label: { Label("Stop", systemImage: "stop.fill") }
                        .tint(.orange)
                    Button {
                        Task { await appState.perform(.restart, on: container) }
                    } label: { Label("Restart", systemImage: "arrow.clockwise") }
                } else {
                    Button {
                        Task { await appState.perform(.start, on: container) }
                    } label: { Label("Start", systemImage: "play.fill") }
                        .tint(.green)
                }
                Button {
                    appState.logTarget = (container.Id, container.name)
                } label: { Label("Logs", systemImage: "text.alignleft") }
            }
            HStack(spacing: 6) {
                Button("Edit…") { onEdit() }
                    .help("Edit ports, volumes, env, image…")
                Button("Export…") { exportTarget = container }
                    .help("Export as compose.yml or docker run — rebuild this container anywhere")
                Button("Deploy…") { gitDeployTarget = container }
                    .help("Pull latest from GitHub and restart")
                Button(role: .destructive) {
                    confirmRemove = true
                } label: { Text("Remove") }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func statsSection(_ stats: ContainerStatsSample.Computed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Live stats")
            gauge("CPU", value: String(format: "%.2f%%", stats.cpuPercent),
                  percent: stats.cpuPercent, warn: stats.cpuPercent > 80)
            gauge("Memory", value: "\(Format.bytes(stats.memUsed)) / \(Format.bytes(stats.memLimit))",
                  percent: stats.memPercent, warn: stats.memPercent > 85)
            detailRow("Network", "↓\(Format.bytes(stats.rxBytes)) · ↑\(Format.bytes(stats.txBytes))")
            detailRow("Disk I/O", "R \(Format.bytes(stats.blockRead)) · W \(Format.bytes(stats.blockWrite))")
            detailRow("PIDs", "\(stats.pids)")
        }
        .glassCard(padding: 12)
    }

    private func gauge(_ label: String, value: String, percent: Double, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(warn ? Color.red : Color.accentColor)
                        .frame(width: max(3, geo.size.width * min(percent / 100, 1)))
                }
            }
            .frame(height: 5)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Info")
            detailRow("Image", container.Image ?? "—", monospaced: true)
            detailRow("ID", String(container.Id.prefix(24)), monospaced: true)
            detailRow("Created", Format.relative(container.Created))
            detailRow("Status", container.Status ?? "—")
            if let project = container.composeProject {
                detailRow("Compose", project)
            }
        }
        .glassCard(padding: 12)
    }

    @ViewBuilder
    private var portsSection: some View {
        let ports = (container.Ports ?? []).filter { $0.PublicPort != nil }
        if !ports.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Ports")
                ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                    Button {
                        appState.openWebUI(for: container, port: port.PublicPort)
                    } label: {
                        HStack {
                            Text("\(port.IP ?? "0.0.0.0"):\(port.PublicPort ?? 0) → \(port.PrivatePort)/\(port.kind ?? "tcp")")
                                .font(.system(size: 11, design: .monospaced))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
            }
            .glassCard(padding: 12)
        }
    }

    @ViewBuilder
    private var mountsSection: some View {
        let mounts = container.Mounts ?? []
        if !mounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Mounts")
                ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mount.Destination ?? "—")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text(mount.Source ?? mount.Name ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .glassCard(padding: 12)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var container: ContainerSummary

    @State private var tab = "compose"
    @State private var composeText = ""
    @State private var runText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export — \(container.name)")
                    .font(.headline)
                Spacer()
                CapsuleSegments(
                    options: [("compose", "compose.yml", nil), ("run", "docker run", nil)],
                    selection: $tab
                )
            }
            .padding(14)
            Divider()
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(14)
            } else {
                ScrollView {
                    Text(tab == "compose" ? composeText : runText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab == "compose" ? composeText : runText, forType: .string)
                    ToastCenter.shared.show("Copied to clipboard")
                }
                Button("Save…") { save() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 460)
        .task {
            guard let client = appState.client else { return }
            do {
                let details = try await client.inspect(id: container.Id)
                let bits = ContainerExport.bits(from: details)
                composeText = ContainerExport.composeYAML(bits)
                runText = ContainerExport.dockerRun(bits)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        let isCompose = tab == "compose"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isCompose
            ? "\(container.name)-compose.yml"
            : "\(container.name)-docker-run.sh"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (isCompose ? composeText : runText).write(to: url, atomically: true, encoding: .utf8)
        ToastCenter.shared.show("Saved to \(url.path)")
    }
}

// MARK: - Edit container sheet (recreate with modified config)

struct EditContainerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var container: ContainerSummary

    @State private var image = ""
    @State private var name = ""
    @State private var ports: [ContainerSpec.PortSpec] = []
    @State private var volumes: [ContainerSpec.VolumeSpec] = []
    @State private var env: [ContainerSpec.EnvSpec] = []
    @State private var restart = "unless-stopped"
    @State private var network = "bridge"
    @State private var memoryMB = ""
    @State private var cpus = ""
    @State private var loading = true
    @State private var working = false
    @State private var confirmRecreate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit — \(container.name)")
                .font(.headline)
                .padding(14)
            Divider()
            if loading {
                ProgressView("Loading current config…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ContainerSpecForm(
                        image: $image, name: $name, ports: $ports, volumes: $volumes,
                        env: $env, restart: $restart, network: $network,
                        memoryMB: $memoryMB, cpus: $cpus,
                        networks: appState.networks.map(\.Name)
                    )
                    .padding(14)
                }
            }
            Divider()
            HStack {
                Text("The container is stopped, recreated and restarted. If anything fails, the original is restored.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Recreating…" : "Recreate container") {
                    confirmRecreate = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || image.isEmpty || loading)
            }
            .padding(14)
        }
        .frame(width: 560, height: 560)
        .task { await load() }
        .confirmationDialog(
            "Recreate \"\(container.name)\" with the new settings?",
            isPresented: $confirmRecreate, titleVisibility: .visible
        ) {
            Button("Recreate") { Task { await save() } }
        }
    }

    private func load() async {
        guard let client = appState.client else { return }
        do {
            let details = try await client.inspect(id: container.Id)
            image = details.Config?.Image ?? ""
            name = details.name
            ports = (details.HostConfig?.PortBindings ?? [:])
                .sorted { $0.key < $1.key }
                .flatMap { key, bindings -> [ContainerSpec.PortSpec] in
                    let containerPort = key.split(separator: "/").first.map(String.init) ?? key
                    let proto = key.split(separator: "/").count > 1 ? String(key.split(separator: "/")[1]) : "tcp"
                    return (bindings ?? []).map {
                        ContainerSpec.PortSpec(host: $0.HostPort ?? containerPort, container: containerPort, proto: proto)
                    }
                }
            volumes = (details.HostConfig?.Binds ?? []).compactMap { bind in
                guard let colon = bind.firstIndex(of: ":") else { return nil }
                return ContainerSpec.VolumeSpec(
                    host: String(bind[..<colon]),
                    container: String(bind[bind.index(after: colon)...])
                )
            }
            env = (details.Config?.Env ?? []).map { ContainerSpec.EnvSpec(value: $0) }
            restart = details.HostConfig?.RestartPolicy?.Name.flatMap { $0.isEmpty ? nil : $0 } ?? "no"
            network = details.HostConfig?.NetworkMode ?? "bridge"
            if let memory = details.HostConfig?.Memory, memory > 0 {
                memoryMB = String(memory / 1_048_576)
            }
            if let nano = details.HostConfig?.NanoCpus, nano > 0 {
                cpus = String(format: "%.2f", Double(nano) / 1e9)
            }
            loading = false
        } catch {
            ToastCenter.shared.show("Inspect failed", detail: error.localizedDescription, style: .error)
            dismiss()
        }
    }

    /// Applies the edits on top of the container's live config via the shared
    /// stop → rename → create → start → delete dance (with rollback).
    private func save() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }
        let newImage = image.trimmingCharacters(in: .whitespaces)
        let newName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? container.name : name.trimmingCharacters(in: .whitespaces)

        do {
            if newImage != container.Image {
                ToastCenter.shared.show("Pulling \(newImage)…", style: .info)
                try await client.pull(
                    image: newImage,
                    auth: RegistryClient.authHeader(
                        image: newImage, saved: appState.store.config.registries ?? []
                    )
                )
            }

            let portSpecs = ports
            let volumeSpecs = volumes
            let envValues = env.map(\.value).filter { $0.contains("=") }
            let restartValue = restart
            let networkValue = network
            let memoryValue = Double(memoryMB) ?? 0
            let cpusValue = Double(cpus) ?? 0

            _ = try await client.replace(id: container.Id) { raw in
                var payload = DockerClient.recreatePayload(fromRaw: raw, image: newImage)
                var hostConfig = payload["HostConfig"] as? [String: Any] ?? [:]

                var exposed: [String: Any] = [:]
                var bindings: [String: Any] = [:]
                for port in portSpecs where !port.container.isEmpty {
                    let key = "\(port.container)/\(port.proto.isEmpty ? "tcp" : port.proto)"
                    exposed[key] = [String: Any]()
                    bindings[key] = [["HostPort": port.host.isEmpty ? port.container : port.host]]
                }
                payload["ExposedPorts"] = exposed.isEmpty ? nil : exposed
                hostConfig["PortBindings"] = bindings

                hostConfig["Binds"] = volumeSpecs
                    .filter { !$0.host.isEmpty && !$0.container.isEmpty }
                    .map { "\($0.host):\($0.container)" }

                payload["Env"] = envValues
                hostConfig["RestartPolicy"] = restartValue == "no"
                    ? ["Name": ""] : ["Name": restartValue]
                if !networkValue.isEmpty {
                    let previousNetwork = hostConfig["NetworkMode"] as? String
                    hostConfig["NetworkMode"] = networkValue
                    // Preserved endpoints only make sense on the same network.
                    if previousNetwork != networkValue {
                        payload.removeValue(forKey: "NetworkingConfig")
                    }
                }
                hostConfig["Memory"] = memoryValue > 0 ? Int64(memoryValue * 1_048_576) : 0
                hostConfig["NanoCpus"] = cpusValue > 0 ? Int64(cpusValue * 1e9) : 0
                payload["HostConfig"] = hostConfig
                return (newName, payload)
            }
            ToastCenter.shared.show("\(newName) recreated")
            dismiss()
            await appState.refresh()
        } catch {
            ToastCenter.shared.show(
                "Edit failed — original container restored",
                detail: error.localizedDescription, style: .error
            )
        }
    }
}

// MARK: - Git Deploy sheet

struct GitDeploySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var container: ContainerSummary

    @State private var repoURL = ""
    @State private var branch = "main"
    @State private var folder = ""
    @State private var output = ""
    @State private var working = false
    @State private var versions: [(sha: String, message: String)] = []
    @State private var selectedVersion = ""

    private var hasToken: Bool { Keychain.gitHubToken?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git Deploy — \(container.name)")
                .font(.headline)
            Text("Pulls the app folder from GitHub inside a throwaway alpine/git container, then restarts this container. The token is passed only at run time — it is never written to the host.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Repository", text: $repoURL, prompt: Text("github.com/owner/repo"))
                TextField("Branch", text: $branch)
                TextField("App folder on host", text: $folder, prompt: Text("/share/Container/myapp"))
            }
            .textFieldStyle(.roundedBorder)

            if !hasToken {
                Label("No GitHub token yet — add one in Settings → Git Deploy before deploying.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !versions.isEmpty {
                Picker("Roll back to", selection: $selectedVersion) {
                    ForEach(Array(versions.enumerated()), id: \.element.sha) { index, version in
                        Text("\(index == 0 ? "● latest · " : "")\(version.sha.prefix(7)) · \(version.message.prefix(56))")
                            .tag(version.sha)
                    }
                }
            }

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Versions…") { Task { await loadVersions() } }
                    .disabled(working || !isConfigured)
                if !versions.isEmpty {
                    Button("Deploy selected") { Task { await deploy(ref: selectedVersion) } }
                        .disabled(working || selectedVersion.isEmpty)
                }
                Spacer()
                Button("Close") {
                    saveConfig()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(working ? "Deploying…" : "Deploy latest") { Task { await deploy(ref: nil) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !isConfigured || !hasToken)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear { load() }
    }

    private var isConfigured: Bool {
        !repoURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !folder.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        let saved = appState.store.config.gitDeploys?[container.name]
        repoURL = saved?.repoUrl ?? ""
        branch = saved?.branch ?? "main"
        folder = saved?.folder ?? ""
        if folder.isEmpty {
            // Best guess: the container's /app bind mount, or its first bind.
            Task {
                guard let client = appState.client,
                      let details = try? await client.inspect(id: container.Id) else { return }
                let binds = (details.Mounts ?? []).filter { $0.kind == "bind" }
                let appBind = binds.first { $0.Destination == "/app" }
                    ?? binds.first { $0.Destination?.hasSuffix("/app") == true }
                    ?? binds.first
                if let source = appBind?.Source, folder.isEmpty {
                    folder = source
                }
            }
        }
    }

    /// Closing always persists whatever is filled in — no silent data loss.
    private func saveConfig() {
        guard isConfigured || !(repoURL.isEmpty && folder.isEmpty) else { return }
        var deploys = appState.store.config.gitDeploys ?? [:]
        deploys[container.name] = GitDeployConfig(
            repoUrl: repoURL.trimmingCharacters(in: .whitespaces),
            branch: branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : branch.trimmingCharacters(in: .whitespaces),
            folder: folder.trimmingCharacters(in: .whitespaces)
        )
        appState.store.config.gitDeploys = deploys
        appState.syncGHWatchFromGitDeploy()   // configuring Git Deploy is all it takes to watch the repo
    }

    private func loadVersions() async {
        guard let client = appState.client else { return }
        saveConfig()
        guard let deploy = appState.store.config.gitDeploys?[container.name] else { return }
        working = true
        defer { working = false }
        do {
            versions = try await GitHubService.versions(
                client: client, deploy: deploy,
                registries: appState.store.config.registries ?? []
            )
            selectedVersion = versions.first?.sha ?? ""
        } catch {
            ToastCenter.shared.show("Couldn't list versions", detail: error.localizedDescription, style: .error)
        }
    }

    private func deploy(ref: String?) async {
        guard let client = appState.client else { return }
        saveConfig()
        guard let deploy = appState.store.config.gitDeploys?[container.name] else { return }
        working = true
        defer { working = false }
        output = (ref == nil ? "Pulling latest…" : "Rolling back…")
        do {
            let result = try await GitHubService.deploy(
                client: client, deploy: deploy, ref: ref,
                restartContainerID: container.Id,
                registries: appState.store.config.registries ?? []
            )
            output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let restartError = result.restartError {
                ToastCenter.shared.show("Deployed with a warning", detail: restartError, style: .error)
            } else {
                ToastCenter.shared.show(
                    "Deployed \(result.deployed)",
                    detail: result.restarted ? "Container restarted" : nil
                )
            }
            appState.scheduleRefresh(after: 1.5)
        } catch {
            output = error.localizedDescription
            ToastCenter.shared.show("Deploy failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Shared spec form (edit + deploy wizard)

struct ContainerSpecForm: View {
    @Binding var image: String
    @Binding var name: String
    @Binding var ports: [ContainerSpec.PortSpec]
    @Binding var volumes: [ContainerSpec.VolumeSpec]
    @Binding var env: [ContainerSpec.EnvSpec]
    @Binding var restart: String
    @Binding var network: String
    @Binding var memoryMB: String
    @Binding var cpus: String
    var networks: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Image")
                TextField("linuxserver/sonarr:latest", text: $image)
                    .textFieldStyle(.roundedBorder)
                fieldLabel("Name")
                TextField("container name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Ports (host → container)")
                ForEach($ports) { $port in
                    HStack(spacing: 6) {
                        TextField("host e.g. 8080", text: $port.host)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        TextField("container e.g. 80", text: $port.container)
                        Picker("", selection: $port.proto) {
                            Text("tcp").tag("tcp")
                            Text("udp").tag("udp")
                        }
                        .labelsHidden()
                        .frame(width: 64)
                        removeButton { ports.removeAll { $0.id == port.id } }
                    }
                    .textFieldStyle(.roundedBorder)
                }
                addButton("Add port") { ports.append(ContainerSpec.PortSpec()) }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Volumes (host path → container path)")
                ForEach($volumes) { $volume in
                    HStack(spacing: 6) {
                        TextField("/share/Container/app", text: $volume.host)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        TextField("/config", text: $volume.container)
                        removeButton { volumes.removeAll { $0.id == volume.id } }
                    }
                    .textFieldStyle(.roundedBorder)
                }
                addButton("Add volume") { volumes.append(ContainerSpec.VolumeSpec()) }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Environment (KEY=value)")
                ForEach($env) { $entry in
                    HStack(spacing: 6) {
                        TextField("TZ=America/New_York", text: $entry.value)
                            .textFieldStyle(.roundedBorder)
                        removeButton { env.removeAll { $0.id == entry.id } }
                    }
                }
                addButton("Add variable") { env.append(ContainerSpec.EnvSpec()) }
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Restart policy")
                    Picker("", selection: $restart) {
                        Text("unless-stopped").tag("unless-stopped")
                        Text("always").tag("always")
                        Text("on-failure").tag("on-failure")
                        Text("no").tag("no")
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Network")
                    Picker("", selection: $network) {
                        Text("bridge").tag("bridge")
                        Text("host").tag("host")
                        ForEach(networks.filter { !NetworkSummary.builtinNames.contains($0) }, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Memory limit (MB, blank = unlimited)")
                    TextField("e.g. 512", text: $memoryMB)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("CPU limit (cores, blank = unlimited)")
                    TextField("e.g. 1.5", text: $cpus)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func addButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "plus")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
}
