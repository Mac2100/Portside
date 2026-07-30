import AppKit
import SwiftUI

/// The menu bar companion: a status item with an alert count and a graphical
/// popover — host rings, CPU sparkline, and per-container quick actions. The
/// app keeps monitoring (and notifying) with the main window closed.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = MenuBarModel()

    private override init() {
        super.init()
    }

    func setup() {
        if ConfigStore.shared.config.trayEnabled != false {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "sailboat.fill", accessibilityDescription: "Portside"
                )
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = item
        } else {
            popover?.close()
            popover = nil
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    /// Refreshes the status item title (alert count) and popover data.
    func update(with state: AppState) {
        model.refresh(from: state)
        let alerts = state.alertCount
        statusItem?.button?.title = alerts > 0 ? " \(alerts)" : ""
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(model: model)
                .environmentObject(AppState.shared)
                .environment(\.appTheme, ThemeStore.shared.theme)
                .tint(ThemeStore.shared.theme.primary)
        )
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        self.popover = popover
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Portside", action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Portside", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil   // one-shot: left click must open the popover again
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Portside" }?
            .makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Snapshot of the data the popover renders (kept separate from AppState so
/// the popover updates cheaply on each poll).
@MainActor
final class MenuBarModel: ObservableObject {
    struct ContainerEntry: Identifiable {
        var id: String
        var name: String
        var state: String
        var cpu: Double?
    }

    @Published var cpu: Double = 0
    @Published var memPercent: Double = 0
    @Published var memText = ""
    @Published var running = 0
    @Published var total = 0
    @Published var history: [Double] = []
    @Published var containers: [ContainerEntry] = []

    func refresh(from state: AppState) {
        cpu = state.hostCPU
        memPercent = state.hostMemPercent
        memText = Format.bytes(state.hostMemUsed)
        running = state.containers.filter(\.isRunning).count
        total = state.containers.count
        history = state.liveHistory.suffix(40).map(\.cpu)
        containers = state.containers.prefix(30).map { container in
            ContainerEntry(
                id: container.Id,
                name: state.displayName(of: container),
                state: container.stateLowercased,
                cpu: state.metrics.first { $0.id == container.Id }?.cpu
            )
        }
    }
}

struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: MenuBarModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                theme.glyph(size: 22)
                Text("Portside")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Open") { open() }
                    .controlSize(.small)
            }

            HStack(spacing: 18) {
                ring(value: model.cpu, label: "CPU", detail: String(format: "%.0f%%", model.cpu))
                ring(value: model.memPercent, label: "MEM", detail: model.memText)
                ring(
                    value: model.total > 0 ? Double(model.running) / Double(model.total) * 100 : 0,
                    label: "RUN", detail: "\(model.running)/\(model.total)", fixedColor: .green
                )
            }

            SparklineView(values: model.history, color: theme.primary)
                .frame(height: 30)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.containers) { entry in
                        containerRow(entry)
                    }
                }
            }

            Divider()
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 320, height: 480)
    }

    private func ring(value: Double, label: String, detail: String, fixedColor: Color? = nil) -> some View {
        let color = fixedColor ?? (value < 60 ? Color.green : value < 80 ? .yellow : .red)
        return VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(min(value, 100), 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(detail)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .frame(width: 52, height: 52)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func containerRow(_ entry: MenuBarModel.ContainerEntry) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(entry.state == "running" ? Color.green
                      : entry.state == "restarting" ? .orange : .secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let cpu = entry.cpu {
                Text(String(format: "%.0f%%", cpu))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if entry.state == "running" {
                actionButton("arrow.clockwise", help: "Restart") { act(.restart, entry) }
                actionButton("stop.fill", help: "Stop") { act(.stop, entry) }
            } else {
                actionButton("play.fill", help: "Start") { act(.start, entry) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedContainerID = entry.id
            appState.page = .containers
            open()
        }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func act(_ action: DockerClient.ContainerAction, _ entry: MenuBarModel.ContainerEntry) {
        guard let container = appState.containers.first(where: { $0.Id == entry.id }) else { return }
        Task { await appState.perform(action, on: container) }
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Portside" }?
            .makeKeyAndOrderFront(nil)
    }
}
