import AppKit
import SwiftUI

/// An action list, not a metrics feed: crashes with exit codes, restart loops,
/// failing health checks, pending updates, and reclaimable junk. Nothing that
/// appears and vanishes on its own.
struct InsightsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var crashLogs = CrashLogStore.shared

    @State private var crashLogEntry: CrashLogEntry?
    @State private var showImageCleanup = false
    @State private var volumePrune: VolumePruneRequest?
    @State private var confirmPruneStopped = false

    var body: some View {
        let attention = appState.attentionItems
        let updates = appState.updateItems
        let housekeeping = appState.housekeepingItems
        let all = attention + updates + housekeeping

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if all.isEmpty {
                    allClear
                } else {
                    if !attention.isEmpty {
                        section("Needs attention", symbol: "exclamationmark.triangle", items: attention)
                    }
                    if !updates.isEmpty {
                        section("Updates", symbol: "square.and.arrow.down", items: updates)
                    }
                    if !housekeeping.isEmpty {
                        section(
                            "Housekeeping", symbol: "paintbrush",
                            meta: InsightsBuilder.storageSummary(state: appState),
                            items: housekeeping
                        )
                    }
                }
            }
            .padding(16)
        }
        .navigationSubtitle("Insights")
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await appState.checkImageUpdates(force: true, announce: true)
                        await appState.checkGitHubWatch(announce: true)
                    }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .disabled(appState.checkingImageUpdates)
                .help("Check image updates and watched repos now")
            }
        }
        .sheet(item: $crashLogEntry) { entry in
            CrashLogSheet(entry: entry)
        }
        .sheet(isPresented: $showImageCleanup) {
            ImageCleanupSheet()
        }
        .sheet(item: $volumePrune) { request in
            VolumePruneSheet(request: request)
        }
        .confirmationDialog(
            "Remove ALL stopped containers?",
            isPresented: $confirmPruneStopped, titleVisibility: .visible
        ) {
            Button("Delete every stopped container", role: .destructive) {
                Task { await pruneStopped() }
            }
        } message: {
            Text("Their config, ports and logs are deleted. Images, volumes and bind-mounted data are untouched — but you'll have to recreate the containers themselves.")
        }
    }

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.title3.weight(.semibold))
            Text("Nothing needs your attention — no broken containers, no updates waiting, nothing to clean up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            let meta = InsightsBuilder.storageSummary(state: appState)
            if !meta.isEmpty {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func section(
        _ title: String, symbol: String, meta: String = "", items: [InsightItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                let worst = items.map(\.severity).min() ?? .info
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(worst.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(worst.color.opacity(0.14), in: Capsule())
                Spacer()
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(items) { item in
                InsightRow(item: item, onAction: handle)
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: InsightItem.Action) {
        switch action {
        case .viewLogs(let id, let name):
            appState.logTarget = (id, name)
        case .viewCrashLog(let file):
            crashLogEntry = crashLogs.entries.first { $0.file == file }
        case .startContainer(let id):
            if let container = appState.containers.first(where: { $0.Id == id }) {
                Task { await appState.perform(.start, on: container) }
            }
        case .applyImageUpdate(let image):
            if let update = appState.imageUpdates.first(where: { $0.image == image }) {
                Task { await appState.applyImageUpdate(update) }
            }
        case .installAppUpdate:
            if case .updateAvailable(_, let url) = appState.updates.status {
                SelfUpdater.shared.install(from: url)
            }
        case .ghDeploy(let repo):
            Task { await appState.ghDeploy(repo: repo) }
        case .ghView(let url):
            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
        case .ghMarkSeen(let repo):
            appState.markGHSeen(repo)
        case .viewDanglingImages:
            appState.page = .images
        case .viewUnusedVolumes:
            appState.page = .volumes
        case .openImageCleanup:
            showImageCleanup = true
        case .pruneStoppedContainers:
            confirmPruneStopped = true
        case .pruneVolumes:
            volumePrune = VolumePruneRequest(volumes: unusedVolumeNames())
        }
    }

    private func unusedVolumeNames() -> [String] {
        appState.volumes
            .filter { volume in
                !appState.containers.contains { container in
                    (container.Mounts ?? []).contains { $0.kind == "volume" && $0.Name == volume.Name }
                }
            }
            .map(\.Name)
    }

    private func pruneStopped() async {
        guard let client = appState.client else { return }
        do {
            let result = try await client.pruneContainers()
            let count = result.ContainersDeleted?.count ?? 0
            ToastCenter.shared.show(
                "Removed \(count) stopped container\(count == 1 ? "" : "s")",
                detail: "Reclaimed \(Format.bytes(result.SpaceReclaimed ?? 0))"
            )
            await appState.refresh()
        } catch {
            ToastCenter.shared.show("Prune failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Row

struct InsightRow: View {
    @EnvironmentObject private var appState: AppState
    var item: InsightItem
    var onAction: (InsightItem.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Severity is the first thing the eye should hit: a colored bar,
            // then the glyph, then the words.
            RoundedRectangle(cornerRadius: 2)
                .fill(item.severity.color.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 1)
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.severity.color)
                .frame(width: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.chips.isEmpty {
                    chipRow
                }
            }

            Spacer(minLength: 8)

            if !item.value.isEmpty {
                Text(item.value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.severity.color)
            }

            HStack(spacing: 6) {
                ForEach(Array(item.actions.enumerated()), id: \.offset) { _, entry in
                    Button(entry.label) { onAction(entry.action) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(entry.destructive ? .orange : nil)
                }
            }
        }
        .glassCard(padding: 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if let containerID = item.containerID {
                appState.selectedContainerID = containerID
                appState.page = .containers
            }
        }
    }

    private var chipRow: some View {
        FlowChips(chips: item.chips) { containerID in
            appState.selectedContainerID = containerID
            appState.page = .containers
        }
    }
}

/// Compact wrapping chip row for container names.
struct FlowChips: View {
    var chips: [(String, String?)]
    var onTap: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90, maximum: 200), spacing: 4, alignment: .leading)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button {
                    if let id = chip.1 { onTap(id) }
                } label: {
                    Text(chip.0)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Crash log sheet

struct CrashLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CrashLogStore.shared
    var entry: CrashLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.name) — crash log")
                        .font(.headline)
                    Text("Captured \(entry.time.briefFormatted)\(entry.exitCode.map { " · exit \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    store.remove(entry)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(store.text(of: entry) ?? "(missing)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(width: 720, height: 480)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.file
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (store.text(of: entry) ?? "").write(to: url, atomically: true, encoding: .utf8)
        ToastCenter.shared.show("Saved to \(url.path)")
    }
}

// MARK: - Volume prune (type-to-confirm)

struct VolumePruneRequest: Identifiable {
    let id = UUID()
    var volumes: [String]
}

/// Pruning volumes wipes every unused volume's contents at once — the single
/// most destructive action in the app. Name the victims, then make the user
/// type the phrase. Clicking OK twice is a reflex; typing is a decision.
struct VolumePruneSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var request: VolumePruneRequest

    @State private var phrase = ""
    @State private var working = false

    init(request: VolumePruneRequest) {
        self.request = request
    }

    private let requiredPhrase = "delete volumes"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prune \(request.volumes.count) unused volume\(request.volumes.count == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text("The data inside these volumes is destroyed — databases, configs, anything a container left behind. There is no undo. Bind mounts (host folders) are not affected.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !request.volumes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(request.volumes, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Type \"\(requiredPhrase)\" to confirm:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(requiredPhrase, text: $phrase)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Destroy \(request.volumes.count) volume\(request.volumes.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await prune() }
                }
                .disabled(phrase.trimmingCharacters(in: .whitespaces) != requiredPhrase || working)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func prune() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }
        do {
            let result = try await client.pruneVolumes()
            let count = result.VolumesDeleted?.count ?? 0
            ToastCenter.shared.show(
                "Removed \(count) volume\(count == 1 ? "" : "s")",
                detail: "Reclaimed \(Format.bytes(result.SpaceReclaimed ?? 0))"
            )
            dismiss()
            await appState.refresh()
        } catch {
            ToastCenter.shared.show("Prune failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Activity feed

struct ActivityView: View {
    @EnvironmentObject private var appState: AppState

    private static let goodActions: Set<String> = ["start", "unpause", "create", "pull"]
    private static let badActions: Set<String> = ["die", "kill", "stop", "destroy", "oom"]

    var body: some View {
        Group {
            if appState.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No events yet")
                        .font(.headline)
                    Text("Container starts, stops, crashes and image pulls appear here in real time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.events.reversed()) { event in
                    HStack(spacing: 10) {
                        Text(event.time.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 76, alignment: .leading)
                        Text(baseAction(event))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(actionColor(event))
                            .frame(width: 90, alignment: .leading)
                        Text(event.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        if event.type != "container" {
                            Text("(\(event.type))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(event.extra)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationSubtitle("Activity")
    }

    private func baseAction(_ event: DockerEvent) -> String {
        let base = event.action.split(separator: ":").first.map(String.init) ?? event.action
        return base.replacingOccurrences(of: "health_status", with: "health")
    }

    private func actionColor(_ event: DockerEvent) -> Color {
        let base = event.action.split(separator: ":").first.map(String.init) ?? ""
        if Self.goodActions.contains(base) { return .green }
        if Self.badActions.contains(base) { return .red }
        if base == "restart" || base == "pause" { return .orange }
        if base.hasPrefix("health_status") {
            return event.action.contains("unhealthy") ? .red : .green
        }
        return .secondary
    }
}
