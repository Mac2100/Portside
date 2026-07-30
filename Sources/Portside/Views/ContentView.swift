import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .overlay(ToastHostView())
        .overlay(UpdateProgressOverlay())
        .overlay(logPanel)
        .overlay(commandPalette)
        .background(UpdateAlertHost(updates: appState.updates))
        .navigationTitle("Portside")
    }

    @ViewBuilder
    private var detail: some View {
        if appState.store.config.hosts.isEmpty {
            WelcomeView()
        } else {
            switch appState.page {
            case .dashboard: DashboardView()
            case .insights: InsightsView()
            case .activity: ActivityView()
            case .containers: ContainersView()
            case .images: ImagesView()
            case .volumes: VolumesView()
            case .networks: NetworksView()
            case .terminal: TerminalPageView()
            case .files: FilesView()
            case .settings: SettingsView()
            }
        }
    }

    @ViewBuilder
    private var logPanel: some View {
        if let target = appState.logTarget {
            LogPanelView(containerID: target.id, containerName: target.name)
                .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder
    private var commandPalette: some View {
        if appState.showCommandPalette {
            CommandPaletteView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            List(selection: pageSelection) {
                Section {
                    row(.dashboard)
                    row(.insights, badge: appState.alertCount)
                    row(.activity)
                }
                Section("Docker") {
                    row(.containers, badge: appState.containers.filter(\.isRunning).count, badgeColor: .green)
                    row(.images)
                    row(.volumes)
                    row(.networks)
                }
                Section("Tools") {
                    row(.terminal)
                    row(.files)
                }
                Section {
                    row(.settings)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)
            footer
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    private var pageSelection: Binding<Page?> {
        Binding(
            get: { appState.page },
            set: { newValue in
                if let newValue { appState.page = newValue }
            }
        )
    }

    private func row(_ page: Page, badge: Int = 0, badgeColor: Color = .red) -> some View {
        Label(page.title, systemImage: page.symbol)
            .badge(badge > 0 ? Text("\(badge)").foregroundStyle(badgeColor) : nil)
            .tag(page)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                theme.glyph(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Portside")
                        .font(.system(size: 14, weight: .semibold))
                    connectionLabel
                }
                Spacer()
            }
            if appState.store.config.hosts.count > 1 {
                Picker("Host", selection: hostSelection) {
                    ForEach(appState.store.config.hosts) { host in
                        Text(host.name).tag(host.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var connectionLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(appState.connected ? Color.green : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
            Text(
                appState.connected
                    ? "\(appState.activeHost?.host ?? ""):\(appState.activeHost.map { String($0.port) } ?? "")"
                    : "Disconnected"
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var hostSelection: Binding<String> {
        Binding(
            get: { appState.store.config.activeHostId ?? "" },
            set: { appState.switchHost(id: $0) }
        )
    }

    private var footer: some View {
        HStack {
            if let refreshed = appState.lastRefreshed {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Welcome (no hosts yet)

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            theme.glyph(size: 72)
            Text("Welcome to Portside")
                .font(.title.weight(.semibold))
            Text("Manage Docker on your NAS — or any TLS-enabled Docker host —\nwithout opening a browser tab.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                appState.page = .settings
            } label: {
                Label("Add a Docker Host", systemImage: "plus")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Update alert & progress (self-update UX)

struct UpdateAlertHost: View {
    @ObservedObject var updates: UpdateChecker

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                if case .updateAvailable = updates.status { return true }
                return false
            },
            set: { newValue in
                if !newValue { updates.status = .idle }
            }
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Update Available", isPresented: isPresented) {
                if case .updateAvailable(_, let url) = updates.status {
                    Button("Install & Relaunch") {
                        SelfUpdater.shared.install(from: url)
                    }
                    Button("View Release Notes") {
                        NSWorkspace.shared.open(UpdateChecker.releasesPage)
                    }
                    Button("Later", role: .cancel) {}
                }
            } message: {
                if case .updateAvailable(let version, _) = updates.status {
                    Text("Portside \(version) is available — you're on \(AppVersion.current). The update downloads, installs in place, and relaunches automatically.")
                }
            }
    }
}

struct UpdateProgressOverlay: View {
    @ObservedObject private var updater = SelfUpdater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .downloading:
                progressCard(
                    title: "Downloading update…",
                    detail: "\(Int(updater.downloadProgress * 100))%",
                    progress: updater.downloadProgress
                )
            case .installing:
                progressCard(title: "Installing update…", detail: "Swapping the app in place", progress: nil)
            case .relaunching:
                progressCard(title: "Relaunching…", detail: nil, progress: nil)
            case .idle, .failed:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: updater.phase)
    }

    private func progressCard(title: String, detail: String?, progress: Double?) -> some View {
        VStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 220)
            } else {
                ProgressView()
            }
            Text(title).font(.callout.weight(.medium))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .glassCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.25))
    }
}
