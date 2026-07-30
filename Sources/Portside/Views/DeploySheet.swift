import SwiftUI
import UniformTypeIdentifiers

/// Deploy wizard: pull an image and create a container with ports, volumes,
/// env, restart policy and resource limits — no YAML required.
struct DeploySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var ports: [ContainerSpec.PortSpec] = [ContainerSpec.PortSpec()]
    @State private var volumes: [ContainerSpec.VolumeSpec] = [ContainerSpec.VolumeSpec()]
    @State private var env: [ContainerSpec.EnvSpec] = [ContainerSpec.EnvSpec()]
    @State private var restart = "unless-stopped"
    @State private var network = "bridge"
    @State private var memoryMB = ""
    @State private var cpus = ""
    @State private var working = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Deploy a container")
                .font(.headline)
                .padding(14)
            Divider()
            ScrollView {
                ContainerSpecForm(
                    image: $image, name: $name, ports: $ports, volumes: $volumes,
                    env: $env, restart: $restart, network: $network,
                    memoryMB: $memoryMB, cpus: $cpus,
                    networks: appState.networks.map(\.Name)
                )
                .padding(14)
            }
            Divider()
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Deploying…" : "Deploy") {
                    Task { await deploy() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || image.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 560)
    }

    private func deploy() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }

        var spec = ContainerSpec()
        spec.image = image.trimmingCharacters(in: .whitespaces)
        spec.name = name.trimmingCharacters(in: .whitespaces)
        spec.ports = ports.filter { !$0.container.isEmpty }
        spec.volumes = volumes.filter { !$0.host.isEmpty && !$0.container.isEmpty }
        spec.env = env.map(\.value).filter { $0.contains("=") }
        spec.restart = restart
        spec.network = network == "bridge" ? "" : network
        spec.memoryMB = Double(memoryMB) ?? 0
        spec.cpus = Double(cpus) ?? 0

        status = "Pulling \(spec.image) — can take a few minutes…"
        do {
            try await client.pull(
                image: spec.image,
                auth: RegistryClient.authHeader(image: spec.image, saved: appState.store.config.registries ?? [])
            )
            status = "Creating container…"
            let id = try await client.create(spec: spec, name: spec.name.isEmpty ? nil : spec.name)
            try await client.perform(.start, id: id)
            ToastCenter.shared.show("\(spec.name.isEmpty ? spec.image : spec.name) deployed and running")
            dismiss()
            await appState.refresh()
            appState.page = .containers
        } catch {
            status = ""
            ToastCenter.shared.show("Deploy failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Compose import

/// Paste (or open) a docker-compose file, preview the services it defines,
/// and create them as containers — grouped as a stack via compose labels.
struct ComposeImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var yamlText = ""
    @State private var project = ""
    @State private var parsed: ComposeParser.Result?
    @State private var parseError: String?
    @State private var working = false
    @State private var status = ""
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import from YAML")
                    .font(.headline)
                Spacer()
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open file…", systemImage: "doc")
                }
            }
            .padding(14)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $yamlText)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        TextField("Stack name (optional)", text: $project)
                            .textFieldStyle(.roundedBorder)
                        Button("Preview") { parse() }
                            .disabled(yamlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .frame(minWidth: 300)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let parseError {
                            Label(parseError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if let parsed {
                            Text("Will create \(parsed.services.count) container\(parsed.services.count == 1 ? "" : "s"):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(parsed.services.enumerated()), id: \.offset) { _, service in
                                servicePreview(service)
                            }
                            ForEach(parsed.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Paste a docker-compose file and press Preview.\n\nThis creates containers from services (image, ports, volumes, environment, restart, command, labels, network, limits). build:, depends_on ordering, healthchecks and secrets are not supported.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 240)
            }

            Divider()
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create containers") {
                    Task { await create() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || parsed == nil)
            }
            .padding(14)
        }
        .frame(width: 720, height: 540)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.yaml, .plainText, .data]
        ) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    yamlText = text
                    parse()
                }
            }
        }
    }

    private func servicePreview(_ service: ContainerSpec) -> some View {
        var bits: [String] = []
        if !service.ports.isEmpty {
            bits.append(service.ports.map { "\($0.host)→\($0.container)/\($0.proto)" }.joined(separator: ", "))
        }
        if !service.volumes.isEmpty { bits.append("\(service.volumes.count) vol") }
        if !service.env.isEmpty { bits.append("\(service.env.count) env") }
        if service.command != nil { bits.append("command") }
        if !service.restart.isEmpty { bits.append("restart: \(service.restart)") }
        if !service.network.isEmpty { bits.append("net: \(service.network)") }
        return VStack(alignment: .leading, spacing: 2) {
            Text(service.name)
                .font(.system(size: 12, weight: .semibold))
            Text(service.image)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if !bits.isEmpty {
                Text(bits.joined(separator: "  ·  "))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func parse() {
        do {
            let result = try ComposeParser.parse(yaml: yamlText)
            parsed = result
            parseError = nil
            if project.isEmpty && !result.project.isEmpty {
                project = result.project
            }
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    private func create() async {
        guard let client = appState.client, let parsed else { return }
        working = true
        defer { working = false }
        var created = 0
        var failed = 0
        for var spec in parsed.services {
            status = "Creating \(spec.name)…"
            // The stack name → compose labels → grouped as a stack in Portside.
            spec.project = project.trimmingCharacters(in: .whitespaces)
            do {
                try await client.pull(
                    image: spec.image,
                    auth: RegistryClient.authHeader(image: spec.image, saved: appState.store.config.registries ?? [])
                )
                let id = try await client.create(spec: spec, name: spec.name)
                try await client.perform(.start, id: id)
                created += 1
            } catch {
                failed += 1
                ToastCenter.shared.show("\(spec.name) failed", detail: error.localizedDescription, style: .error)
            }
        }
        status = ""
        ToastCenter.shared.show(
            "Created \(created) container\(created == 1 ? "" : "s")\(failed > 0 ? " · \(failed) failed" : "")",
            style: failed > 0 ? .error : .success
        )
        if created > 0 {
            dismiss()
            await appState.refresh()
            appState.page = .containers
        }
    }
}
