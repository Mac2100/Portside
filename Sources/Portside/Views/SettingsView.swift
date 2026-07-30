import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var tab: Tab = .hosts

    enum Tab: String, CaseIterable {
        case hosts, general, appearance, notifications, registries, updates, about

        var label: String {
            switch self {
            case .hosts: return "Hosts"
            case .general: return "General"
            case .appearance: return "Appearance"
            case .notifications: return "Notifications"
            case .registries: return "Registries"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .hosts: return "server.rack"
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .notifications: return "bell"
            case .registries: return "key"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CapsuleSegments(
                    options: Tab.allCases.map { ($0, $0.label, $0.symbol) },
                    selection: $tab
                )
                Spacer()
            }
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            ScrollView {
                Group {
                    switch tab {
                    case .hosts: HostsSettings()
                    case .general: GeneralSettings()
                    case .appearance: AppearanceSettings()
                    case .notifications: NotificationSettings()
                    case .registries: RegistrySettings()
                    case .updates: UpdateSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(18)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationSubtitle("Settings")
    }
}

// MARK: - Hosts

struct HostsSettings: View {
    @EnvironmentObject private var appState: AppState

    @State private var newName = ""
    @State private var newAddress = ""
    @State private var newPort = "2376"
    @State private var editingID: String?
    @State private var editName = ""
    @State private var editAddress = ""
    @State private var editPort = ""
    @State private var certInfoRefresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Docker hosts", subtitle: "Each host needs the Docker API over TLS (port 2376 on QNAP Container Station).") {
                ForEach(appState.store.config.hosts) { host in
                    if editingID == host.id {
                        editRow(host)
                    } else {
                        hostRow(host)
                    }
                }
                if appState.store.config.hosts.isEmpty {
                    Text("No hosts yet — add your NAS below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Name", text: $newName)
                        .frame(width: 110)
                    TextField("IP address", text: $newAddress)
                    TextField("Port", text: $newPort)
                        .frame(width: 64)
                    Button("Add") { addHost() }
                        .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            }

            settingsSection("TLS certificates", subtitle: "From Container Station: Preferences → Docker Certificate → Download, then import the unzipped ca.pem, cert.pem and key.pem. Per-host certificates win over the shared set.") {
                certificateStatus
                HStack {
                    Button("Import certificates…") { importCerts(hostID: appState.store.activeHost?.id) }
                    Button("Reset") {
                        ConfigStore.resetCertificates(hostID: appState.store.activeHost?.id)
                        ConfigStore.resetCertificates(hostID: nil)
                        certInfoRefresh += 1
                        ToastCenter.shared.show("Certificates removed", style: .info)
                    }
                }
                Toggle(isOn: Binding(
                    get: { appState.store.config.tlsInsecure },
                    set: { setInsecure($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Skip certificate verification")
                        Text("Without verification Portside can't tell your host apart from anything else answering on that address. Only use this if re-importing the certificates didn't fix the connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func hostRow(_ host: DockerHost) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.switchHost(id: host.id)
            } label: {
                Image(systemName: host.id == appState.store.config.activeHostId
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Make active")

            Text(host.name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Text("\(host.host):\(host.port)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Test") { testHost(host) }
                .controlSize(.small)
            Button("Certs…") { importCerts(hostID: host.id) }
                .controlSize(.small)
                .help("Import certificates just for this host")
            Button {
                editingID = host.id
                editName = host.name
                editAddress = host.host
                editPort = String(host.port)
            } label: {
                Image(systemName: "pencil")
            }
            .controlSize(.small)
            Button {
                appState.store.removeHost(id: host.id)
                appState.connectToActiveHost()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(appState.store.config.hosts.count < 2)
        }
        .padding(.vertical, 2)
    }

    private func editRow(_ host: DockerHost) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: $editName)
                .frame(width: 110)
            TextField("IP address", text: $editAddress)
            TextField("Port", text: $editPort)
                .frame(width: 64)
            Button("Save") {
                var updated = host
                updated.name = editName.trimmingCharacters(in: .whitespaces).isEmpty ? editAddress : editName
                updated.host = editAddress.trimmingCharacters(in: .whitespaces)
                updated.port = Int(editPort) ?? 2376
                appState.store.updateHost(updated)
                editingID = nil
                if host.id == appState.store.config.activeHostId {
                    appState.connectToActiveHost()
                }
                ToastCenter.shared.show("Host updated")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Cancel") { editingID = nil }
                .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var certificateStatus: some View {
        let directory = ConfigStore.certsDirectory(forHostID: appState.store.activeHost?.id)
        let _ = certInfoRefresh   // re-evaluate after import/reset
        VStack(alignment: .leading, spacing: 4) {
            certRow("ca.pem", directory: directory)
            certRow("cert.pem", directory: directory)
            keyRow(directory: directory)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func certRow(_ file: String, directory: URL) -> some View {
        HStack(spacing: 6) {
            if let summary = TLSIdentity.summary(ofPEMFile: directory.appendingPathComponent(file)) {
                Image(systemName: summary.isExpired ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(summary.isExpired ? .red : .green)
                Text(file).font(.system(size: 11, design: .monospaced))
                Text("(\(summary.commonName))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let expiry = summary.notValidAfter {
                    Text("\(summary.isExpired ? "EXPIRED" : "expires") \(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10))
                        .foregroundStyle(summary.isExpired ? Color.red : Color.secondary)
                }
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("\(file) — missing").font(.system(size: 11, design: .monospaced))
            }
            Spacer()
        }
    }

    private func keyRow(directory: URL) -> some View {
        let exists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("key.pem").path
        )
        return HStack(spacing: 6) {
            Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(exists ? .green : .red)
            Text("key.pem — private key").font(.system(size: 11, design: .monospaced))
            Spacer()
        }
    }

    private func addHost() {
        let host = appState.store.addHost(
            name: newName.trimmingCharacters(in: .whitespaces),
            address: newAddress.trimmingCharacters(in: .whitespaces),
            port: Int(newPort) ?? 2376
        )
        newName = ""
        newAddress = ""
        if appState.store.config.hosts.count == 1 {
            appState.connectToActiveHost()
        }
        ToastCenter.shared.show(
            "Added \(host.name)",
            detail: "Use Test to verify, and Certs… if it needs its own certificates"
        )
    }

    private func testHost(_ host: DockerHost) {
        Task {
            do {
                let client = try appState.store.makeClient(for: host)
                let info = try await client.info()
                ToastCenter.shared.show("\(host.name): connected", detail: "Docker \(info.ServerVersion ?? "?")")
            } catch {
                ToastCenter.shared.show("\(host.name): failed", detail: error.localizedDescription, style: .error)
            }
        }
    }

    private func importCerts(hostID: String?) {
        let panel = NSOpenPanel()
        panel.title = "Select certificate files (ca.pem, cert.pem, key.pem)"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let result = try ConfigStore.importCertificates(files: panel.urls, hostID: hostID)
            certInfoRefresh += 1
            if result.missing.isEmpty {
                ToastCenter.shared.show("Certificates imported — reconnecting…")
                appState.connectToActiveHost()
            } else {
                ToastCenter.shared.show(
                    "Imported \(result.placed.count) file\(result.placed.count == 1 ? "" : "s")",
                    detail: "Still need: \(result.missing.joined(separator: ", "))",
                    style: .info
                )
            }
        } catch {
            ToastCenter.shared.show("Import failed", detail: error.localizedDescription, style: .error)
        }
    }

    private func setInsecure(_ value: Bool) {
        appState.store.config.tlsInsecure = value
        appState.connectToActiveHost()
        ToastCenter.shared.show(
            value ? "Certificate verification disabled" : "Certificate verification on",
            style: value ? .error : .success
        )
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Refresh") {
                Picker("Auto refresh", selection: Binding(
                    get: { appState.store.config.refreshInterval ?? 10 },
                    set: {
                        appState.store.config.refreshInterval = $0
                        appState.restartPolling()
                    }
                )) {
                    Text("Every 5 seconds").tag(5.0)
                    Text("Every 10 seconds").tag(10.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Off").tag(0.0)
                }
                .frame(maxWidth: 320)
            }

            settingsSection("Menu bar & Dock") {
                Toggle(isOn: Binding(
                    get: { appState.store.config.trayEnabled != false },
                    set: {
                        appState.store.config.trayEnabled = $0
                        MenuBarController.shared.setEnabled($0)
                        ToastCenter.shared.show(
                            $0 ? "Menu bar companion enabled"
                               : "Menu bar icon hidden — closing the window now quits",
                            style: .info
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Menu bar companion")
                        Text("Live rings and per-container actions in the menu bar; the app keeps monitoring (and notifying) with the window closed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { appState.store.config.alertBadge != false },
                    set: { appState.store.config.alertBadge = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Alert count badge")
                        Text("Shows the number of open Insights alerts on the Dock icon and in the sidebar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLaunchAtLogin($0) }
                )) {
                    Text("Launch at login")
                }
            }

            settingsSection("Containers") {
                Toggle(isOn: Binding(
                    get: { appState.store.config.stackGrouping != false },
                    set: { appState.store.config.stackGrouping = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Group compose stacks automatically")
                        Text("Containers created by docker compose are grouped by their project label, with stack-wide start/stop/restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                ToastCenter.shared.show("Portside will launch at login", style: .info)
            } else {
                try SMAppService.mainApp.unregister()
                ToastCenter.shared.show("Autostart disabled", style: .info)
            }
        } catch {
            ToastCenter.shared.show("Couldn't change autostart", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Appearance") {
                Picker("Mode", selection: $themeStore.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            settingsSection("Accent theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 10) {
                    ForEach(Themes.all) { theme in
                        Button {
                            themeStore.themeID = theme.id
                        } label: {
                            HStack(spacing: 8) {
                                theme.glyph(size: 26)
                                Text(theme.name)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                if themeStore.themeID == theme.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.primary)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(themeStore.themeID == theme.id
                                          ? theme.primary.opacity(0.1) : Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(
                                        themeStore.themeID == theme.id ? theme.primary : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @EnvironmentObject private var appState: AppState
    @State private var refresh = 0

    var body: some View {
        settingsSection("Notifications", subtitle: "Choose exactly which events interrupt you — a container that restarts by design doesn't have to mean turning notifications off entirely.") {
            let _ = refresh
            ForEach(Notifier.Event.allCases) { event in
                Toggle(isOn: Binding(
                    get: { Notifier.isEnabled(event) },
                    set: {
                        Notifier.setEnabled(event, $0)
                        refresh += 1
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.label)
                        Text(event.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Registries

struct RegistrySettings: View {
    @EnvironmentObject private var appState: AppState

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false

    var body: some View {
        settingsSection("Private registries", subtitle: "Credentials are stored in your macOS Keychain. They authenticate update checks and pulls for private images — and lift Docker Hub's anonymous pull limit.") {
            let saved = appState.store.config.registries ?? []
            ForEach(saved) { credential in
                HStack {
                    Text(credential.host)
                        .font(.system(size: 12, design: .monospaced))
                    Text(credential.username)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("saved")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                    Button {
                        remove(credential)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
            }
            if saved.isEmpty {
                Text("No credentials saved — pulls and update checks run anonymously.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Registry (docker.io, ghcr.io, …)", text: $host)
                TextField("Username", text: $username)
                    .frame(width: 120)
                SecureField("Token / password", text: $password)
                    .frame(width: 150)
                Button(testing ? "Checking…" : "Add") {
                    Task { await add() }
                }
                .disabled(testing || host.isEmpty || username.isEmpty || password.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func add() async {
        testing = true
        defer { testing = false }
        do {
            // Verify before saving — a credential that silently doesn't work is worse than none.
            try await RegistryClient.test(host: host, username: username, password: password)
            let normalized = RegistryClient.normalize(host)
            Keychain.setRegistrySecret(password, host: normalized)
            var list = (appState.store.config.registries ?? []).filter {
                RegistryClient.normalize($0.host) != normalized
            }
            list.append(RegistryCredential(host: host.trimmingCharacters(in: .whitespaces), username: username))
            appState.store.config.registries = list
            ToastCenter.shared.show("Credentials for \(host) saved")
            host = ""
            username = ""
            password = ""
        } catch {
            ToastCenter.shared.show("Registry rejected those credentials", detail: error.localizedDescription, style: .error)
        }
    }

    private func remove(_ credential: RegistryCredential) {
        Keychain.deleteRegistrySecret(host: RegistryClient.normalize(credential.host))
        appState.store.config.registries = (appState.store.config.registries ?? [])
            .filter { $0.host != credential.host }
        ToastCenter.shared.show("Removed credentials for \(credential.host)", style: .info)
    }
}

// MARK: - Updates (images + GitHub watch + Git Deploy token)

struct UpdateSettings: View {
    @EnvironmentObject private var appState: AppState

    @State private var newRepo = ""
    @State private var addingRepo = false
    @State private var token = ""
    @State private var tokenRefresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Container image updates", subtitle: "Compares your containers' image digests against the registry. Updating pulls the new image and recreates the container — config preserved, auto-rollback on failure.") {
                Toggle(isOn: Binding(
                    get: { appState.store.config.updEnabled != false },
                    set: { appState.store.config.updEnabled = $0 }
                )) {
                    Text("Check for image updates automatically")
                }
                .toggleStyle(.switch)
                Picker("Check every", selection: Binding(
                    get: { appState.store.config.updInterval ?? 3_600_000 },
                    set: { appState.store.config.updInterval = $0 }
                )) {
                    Text("Hour").tag(3_600_000.0)
                    Text("6 hours").tag(21_600_000.0)
                    Text("Day").tag(86_400_000.0)
                    Text("Never (manual only)").tag(0.0)
                }
                .frame(maxWidth: 320)
                Button("Check now") {
                    Task { await appState.checkImageUpdates(force: true, announce: true) }
                }
                .disabled(appState.checkingImageUpdates)
            }

            settingsSection("Auto-update containers", subtitle: "Opted-in containers are redeployed hands-free when the registry has something new — never the same version twice.") {
                let optIn = appState.store.config.autoUpdate ?? [:]
                let names = Set(appState.containers.map(\.name)).sorted()
                if names.isEmpty {
                    Text("Connect to a host to list containers.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { optIn[name] == true },
                            set: { enabled in
                                var map = appState.store.config.autoUpdate ?? [:]
                                if enabled { map[name] = true } else { map.removeValue(forKey: name) }
                                appState.store.config.autoUpdate = map
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    }
                }
            }

            settingsSection("GitHub watch", subtitle: "Watch repos for new releases and commits. Linked containers can deploy on push — immediately, nightly, or with one click.") {
                Toggle(isOn: Binding(
                    get: { appState.store.config.ghEnabled != false },
                    set: { appState.store.config.ghEnabled = $0 }
                )) {
                    Text("Check watched repos automatically")
                }
                .toggleStyle(.switch)
                HStack {
                    Picker("Check every", selection: Binding(
                        get: { appState.store.config.ghInterval ?? 900_000 },
                        set: { appState.store.config.ghInterval = $0 }
                    )) {
                        Text("15 minutes").tag(900_000.0)
                        Text("Hour").tag(3_600_000.0)
                        Text("6 hours").tag(21_600_000.0)
                        Text("Never (manual only)").tag(0.0)
                    }
                    .frame(maxWidth: 260)
                    DatePickerCompat(time: Binding(
                        get: { appState.ghDeployTime },
                        set: { appState.store.config.ghDeployTime = $0 }
                    ))
                }

                watchList

                HStack(spacing: 8) {
                    TextField("owner/repo", text: $newRepo)
                        .textFieldStyle(.roundedBorder)
                    Button(addingRepo ? "Checking…" : "Watch") {
                        Task { await addRepo() }
                    }
                    .disabled(addingRepo || newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Check now") {
                        Task { await appState.checkGitHubWatch(announce: true) }
                    }
                }
            }

            settingsSection("GitHub token", subtitle: "One shared read-only token, stored in the Keychain. Used by Git Deploy (private repos) and to lift GitHub's anonymous rate limit for watching.") {
                let _ = tokenRefresh
                if Keychain.gitHubToken?.isEmpty == false {
                    HStack {
                        Label("Token saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        Button("Remove") {
                            Keychain.gitHubToken = nil
                            tokenRefresh += 1
                            ToastCenter.shared.show("GitHub token removed", style: .info)
                        }
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    SecureField("github_pat_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Keychain.gitHubToken = token.trimmingCharacters(in: .whitespaces)
                        token = ""
                        tokenRefresh += 1
                        ToastCenter.shared.show("GitHub token saved")
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var watchList: some View {
        let watch = appState.store.config.ghWatch ?? []
        let containerNames = Set(appState.containers.map(\.name)).sorted()
        if watch.isEmpty {
            Text("Not watching any repos yet — add one below. Repos configured in Git Deploy are watched automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        ForEach(watch, id: \.self) { repo in
            let config = appState.ghConfig(for: repo)
            HStack(spacing: 8) {
                Text(repo)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if let latest = appState.ghLatest[repo] {
                    Text([latest.tag, latest.commit.map { "@\($0.shortSha)" } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.system(size: 10))
                        .foregroundStyle(appState.ghFindings.contains { $0.repo == repo } ? .orange : .secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { config.container ?? "" },
                    set: { newValue in
                        var updated = config
                        updated.container = newValue.isEmpty ? nil : newValue
                        if newValue.isEmpty { updated.mode = "notify" }
                        appState.setGHConfig(for: repo, updated)
                    }
                )) {
                    Text("not linked").tag("")
                    ForEach(containerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Container to deploy when this repo changes")
                Picker("", selection: Binding(
                    get: { appState.ghMode(for: repo) },
                    set: { newValue in
                        var updated = config
                        updated.mode = newValue
                        appState.setGHConfig(for: repo, updated)
                    }
                )) {
                    Text("Notify").tag("notify")
                    Text("Auto").tag("auto")
                    Text("Nightly").tag("scheduled")
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(config.container == nil)
                .help("Notify: alert + one-click Deploy · Auto: deploy immediately · Nightly: deploy at the scheduled time")
                Button {
                    removeRepo(repo)
                } label: {
                    Image(systemName: "xmark")
                }
                .controlSize(.small)
                .help("Stop watching")
            }
        }
    }

    private func addRepo() async {
        addingRepo = true
        defer { addingRepo = false }
        do {
            let status = try await GitHubService.latest(repo: newRepo)
            var watch = appState.store.config.ghWatch ?? []
            guard !watch.contains(status.repo) else {
                ToastCenter.shared.show("Already watching \(status.repo)", style: .info)
                return
            }
            watch.append(status.repo)
            // Baseline the current state so only FUTURE commits/releases alert.
            var seen = appState.store.config.ghSeen ?? [:]
            seen[status.repo] = GitHubSeen(tag: status.tag, sha: status.commit?.sha ?? "")
            appState.store.config.ghWatch = watch
            appState.store.config.ghSeen = seen
            appState.store.config.ghIgnored = (appState.store.config.ghIgnored ?? [])
                .filter { $0 != status.repo }   // manual add overrides an earlier removal
            appState.ghLatest[status.repo] = status
            newRepo = ""
            ToastCenter.shared.show("Watching \(status.repo)", detail: "You'll be alerted on the next commit or release")
        } catch {
            ToastCenter.shared.show("Repo not found", detail: error.localizedDescription, style: .error)
        }
    }

    private func removeRepo(_ repo: String) {
        appState.store.config.ghWatch = (appState.store.config.ghWatch ?? []).filter { $0 != repo }
        var seen = appState.store.config.ghSeen ?? [:]
        seen.removeValue(forKey: repo)
        appState.store.config.ghSeen = seen
        var configs = appState.store.config.ghWatchCfg ?? [:]
        configs.removeValue(forKey: repo)
        appState.store.config.ghWatchCfg = configs
        // Remember the removal so auto-sync from Git Deploy doesn't re-add it.
        appState.store.config.ghIgnored = Array(Set((appState.store.config.ghIgnored ?? []) + [repo]))
        appState.ghFindings.removeAll { $0.repo == repo }
    }
}

/// "HH:mm" nightly deploy time as a text field with validation.
struct DatePickerCompat: View {
    @Binding var time: String
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("Nightly deploys at")
                .font(.system(size: 12))
            TextField("03:00", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .onAppear { text = time }
                .onSubmit {
                    if text.wholeMatch(of: /\d{2}:\d{2}/) != nil {
                        time = text
                        ToastCenter.shared.show("Nightly deploys will run at \(text)", style: .info)
                    } else {
                        text = time
                    }
                }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme
    @ObservedObject private var updater = SelfUpdater.shared

    var body: some View {
        VStack(spacing: 14) {
            theme.glyph(size: 64)
            Text("Portside")
                .font(.title2.weight(.semibold))
            Text("Version \(AppVersion.current)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A native macOS app for managing Docker on your NAS\n(or any TLS-enabled Docker host).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Check for Updates…") {
                    Task { await appState.updates.check(userInitiated: true) }
                }
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                }
            }

            if case .checking = appState.updates.status {
                ProgressView().controlSize(.small)
            }
            if let checked = appState.updates.lastChecked {
                Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

// MARK: - Section helper

@ViewBuilder
func settingsSection<Content: View>(
    _ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard()
}
