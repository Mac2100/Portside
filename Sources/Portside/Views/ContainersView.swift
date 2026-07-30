import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showAll = true
    @State private var view: ViewMode = .grid
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var collapsed = Set<String>()
    @State private var customizeTarget: ContainerSummary?
    @State private var groupSheet: GroupSheetRequest?
    @State private var deploySheet = false
    @State private var composeSheet = false
    @State private var editTarget: ContainerSummary?
    @State private var confirmAction: PendingAction?
    @State private var confirmRemove: PendingRemove?

    enum ViewMode: String { case grid, list }

    struct PendingAction: Identifiable {
        let id = UUID()
        var action: DockerClient.ContainerAction
        var ids: [String]
        var what: String
    }

    struct PendingRemove: Identifiable {
        let id = UUID()
        var ids: [String]
        var what: String
    }

    struct GroupSheetRequest: Identifiable {
        let id = UUID()
        var existing: String?
        var preselect: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().opacity(0.4)
            HSplitView {
                content
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let selected = appState.selectedContainerID,
                   let container = appState.containers.first(where: { $0.Id == selected }) {
                    ContainerDetailView(container: container, onEdit: { editTarget = container })
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { bulkBar }
        }
        .onAppear {
            view = ViewMode(rawValue: appState.store.config.containerView ?? "grid") ?? .grid
            collapsed = Set((appState.store.config.collapsedGroups ?? [:]).filter(\.value).keys)
        }
        .sheet(item: $customizeTarget) { container in
            CustomizeSheet(container: container)
        }
        .sheet(item: $groupSheet) { request in
            GroupSheet(existing: request.existing, preselect: request.preselect) {
                selection.removeAll()
            }
        }
        .sheet(isPresented: $deploySheet) { DeploySheet() }
        .sheet(isPresented: $composeSheet) { ComposeImportSheet() }
        .sheet(item: $editTarget) { container in
            EditContainerSheet(container: container)
        }
        .confirmationDialog(
            confirmAction.map { "\($0.action.confirmVerb.0) \($0.what)?" } ?? "",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = confirmAction {
                Button(pending.action.confirmVerb.0) {
                    runBulk(pending.action.rawValue, ids: pending.ids)
                    confirmAction = nil
                }
            }
        } message: {
            if let pending = confirmAction {
                Text(names(of: pending.ids).joined(separator: ", "))
            }
        }
        .sheet(item: $confirmRemove) { pending in
            RemoveContainersSheet(names: names(of: pending.ids)) {
                runBulk("remove", ids: pending.ids)
            }
        }
    }

    private func names(of ids: [String]) -> [String] {
        ids.map { id in appState.containers.first { $0.Id == id }?.name ?? String(id.prefix(12)) }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            SearchField(text: $search, prompt: "Filter containers")
            Toggle("Running only", isOn: Binding(get: { !showAll }, set: { showAll = !$0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer()
            Button {
                composeSheet = true
            } label: {
                Label("Import YAML", systemImage: "arrow.down.doc")
            }
            Button {
                deploySheet = true
            } label: {
                Label("Deploy", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            CapsuleSegments(
                options: [
                    (ViewMode.grid, "Grid", "square.grid.2x2"),
                    (ViewMode.list, "List", "list.bullet")
                ],
                selection: Binding(
                    get: { view },
                    set: {
                        view = $0
                        appState.store.config.containerView = $0.rawValue
                    }
                ),
                showLabels: false
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Content

    private var visible: [ContainerSummary] {
        var list = appState.containers
        if !showAll { list = list.filter(\.isRunning) }
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || appState.displayName(of: $0).localizedCaseInsensitiveContains(search)
                    || ($0.Image ?? "").localizedCaseInsensitiveContains(search)
            }
        }
        return list.sorted { $0.name < $1.name }
    }

    /// Groups in display order: manual groups and stacks sorted by name, then Ungrouped.
    private var grouped: [(name: String?, isStack: Bool, members: [ContainerSummary])] {
        var groups: [String: (isStack: Bool, members: [ContainerSummary])] = [:]
        var ungrouped: [ContainerSummary] = []
        for container in visible {
            if let info = appState.groupInfo(of: container) {
                groups[info.name, default: (info.isStack, [])].members.append(container)
                groups[info.name]?.isStack = info.isStack
            } else {
                ungrouped.append(container)
            }
        }
        guard !groups.isEmpty else {
            return [(nil, false, ungrouped)]
        }
        var result: [(String?, Bool, [ContainerSummary])] = groups
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.isStack, $0.value.members) }
        if !ungrouped.isEmpty {
            result.append(("Ungrouped", false, ungrouped))
        }
        return result
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                if visible.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                        if let name = group.name {
                            groupSection(name: name, isStack: group.isStack, members: group.members)
                        } else {
                            body(for: group.members)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No containers")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func body(for members: [ContainerSummary]) -> some View {
        if view == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 12)],
                spacing: 12
            ) {
                ForEach(members) { container in
                    ContainerCard(
                        container: container,
                        selected: selection.contains(container.Id),
                        onToggleSelect: { toggleSelection(container.Id) },
                        onCustomize: { customizeTarget = container },
                        onEdit: { editTarget = container }
                    )
                }
            }
        } else {
            VStack(spacing: 1) {
                ForEach(members) { container in
                    ContainerRow(
                        container: container,
                        selected: selection.contains(container.Id),
                        onToggleSelect: { toggleSelection(container.Id) },
                        onCustomize: { customizeTarget = container },
                        onEdit: { editTarget = container }
                    )
                }
            }
        }
    }

    private func groupSection(name: String, isStack: Bool, members: [ContainerSummary]) -> some View {
        let isCollapsed = collapsed.contains(name)
        // A stack's real size includes members the current filter hides.
        let allMembers = isStack ? appState.stackMembers(project: name) : members
        let runningCount = allMembers.filter(\.isRunning).count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    toggleCollapsed(name)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                        if isStack {
                            Text("STACK")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                                .help("Docker Compose project — grouped automatically from its labels")
                        }
                        Text(isStack ? "\(runningCount)/\(allMembers.count)" : "\(members.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if isStack {
                    stackButton("play.fill", help: "Start every container in this stack") {
                        stackAction(.start, project: name)
                    }
                    stackButton("arrow.clockwise", help: "Restart every container in this stack") {
                        stackAction(.restart, project: name)
                    }
                    stackButton("stop.fill", help: "Stop every container in this stack") {
                        stackAction(.stop, project: name)
                    }
                } else if name != "Ungrouped" {
                    stackButton("pencil", help: "Edit group") {
                        groupSheet = GroupSheetRequest(existing: name, preselect: [])
                    }
                    stackButton("xmark", help: "Dissolve group (containers keep running, just ungrouped)") {
                        dissolveGroup(name)
                    }
                }
            }
            if !isCollapsed {
                body(for: members)
            }
        }
    }

    private func stackButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help(help)
    }

    // MARK: - Selection & bulk actions

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleCollapsed(_ name: String) {
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        appState.store.config.collapsedGroups = Dictionary(
            uniqueKeysWithValues: collapsed.map { ($0, true) }
        )
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.system(size: 12, weight: .semibold))
            Divider().frame(height: 16)
            Button("Start") { confirmBulk(.start) }
            Button("Stop") { confirmBulk(.stop) }
            Button("Restart") { confirmBulk(.restart) }
            Button("Group…") {
                groupSheet = GroupSheetRequest(existing: nil, preselect: names(of: Array(selection)))
            }
            Button("Remove", role: .destructive) {
                confirmRemove = PendingRemove(
                    ids: Array(selection),
                    what: "\(selection.count) container\(selection.count == 1 ? "" : "s")"
                )
            }
            Divider().frame(height: 16)
            Button("Clear") { selection.removeAll() }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 20, padding: 0)
        .padding(.bottom, 10)
    }

    /// Only act on the containers the action makes sense for — starting a
    /// running container is a no-op that muddles the count.
    private func idsFor(_ action: DockerClient.ContainerAction, from ids: [String]) -> [String] {
        let members = ids.compactMap { id in appState.containers.first { $0.Id == id } }
        switch action {
        case .start: return members.filter { !$0.isRunning }.map(\.Id)
        case .stop: return members.filter(\.isRunning).map(\.Id)
        default: return members.map(\.Id)
        }
    }

    private func confirmBulk(_ action: DockerClient.ContainerAction) {
        let ids = idsFor(action, from: Array(selection))
        guard !ids.isEmpty else {
            ToastCenter.shared.show("Nothing in the selection to \(action.rawValue)", style: .info)
            return
        }
        confirmAction = PendingAction(
            action: action, ids: ids,
            what: "\(ids.count) container\(ids.count == 1 ? "" : "s")"
        )
    }

    private func stackAction(_ action: DockerClient.ContainerAction, project: String) {
        let ids = idsFor(action, from: appState.stackMembers(project: project).map(\.Id))
        guard !ids.isEmpty else {
            ToastCenter.shared.show("Nothing to \(action.rawValue) in \(project)", style: .info)
            return
        }
        confirmAction = PendingAction(action: action, ids: ids, what: "stack \"\(project)\"")
    }

    private func runBulk(_ action: String, ids: [String]) {
        Task {
            let (succeeded, failures) = await appState.performBulk(action, ids: ids)
            if failures.isEmpty {
                ToastCenter.shared.show("\(action.capitalized) done for \(succeeded) container\(succeeded == 1 ? "" : "s")")
            } else {
                ToastCenter.shared.show(
                    "\(succeeded)/\(ids.count) succeeded",
                    detail: "Failed: \(failures.joined(separator: ", "))",
                    style: .error
                )
            }
            selection.removeAll()
        }
    }

    private func dissolveGroup(_ name: String) {
        var map = appState.store.config.gcGroups ?? [:]
        for (key, value) in map where value == name {
            map.removeValue(forKey: key)
        }
        appState.store.config.gcGroups = map
        collapsed.remove(name)
        ToastCenter.shared.show("Group \"\(name)\" dissolved", style: .info)
    }
}

// MARK: - Card

struct ContainerCard: View {
    @EnvironmentObject private var appState: AppState

    var container: ContainerSummary
    var selected: Bool
    var onToggleSelect: () -> Void
    var onCustomize: () -> Void
    var onEdit: () -> Void

    @State private var hovering = false

    private var custom: ContainerCustomization { appState.customization(of: container.name) }
    private var tint: Color { ContainerTint.color(for: container, custom: custom) }
    private var metrics: ContainerMetrics? { appState.metrics.first { $0.id == container.Id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                iconBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.displayName(of: container))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let service = container.composeService {
                            Text(service)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tint)
                        }
                        Text(container.shortImage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                StateBadge(container: container)
            }

            SparklineView(values: appState.cpuSparklines[container.Id] ?? [], color: tint)
                .frame(height: 30)

            HStack(spacing: 14) {
                statPair("CPU", container.isRunning
                    ? metrics.map { String(format: "%.1f%%", $0.cpu) } ?? "…" : "—")
                statPair("MEM", container.isRunning
                    ? metrics.map { Format.bytes($0.memUsed) } ?? "…" : "—")
                statPair("Status", (container.Status ?? "—")
                    .replacingOccurrences(of: " (healthy)", with: ""))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if container.isRunning {
                    smallButton("Stop", symbol: "stop.fill", tint: .orange) {
                        Task { await appState.perform(.stop, on: container) }
                    }
                    smallButton("Restart", symbol: "arrow.clockwise", tint: nil) {
                        Task { await appState.perform(.restart, on: container) }
                    }
                } else {
                    smallButton("Start", symbol: "play.fill", tint: .green) {
                        Task { await appState.perform(.start, on: container) }
                    }
                }
                Spacer()
                iconButton("text.alignleft", help: "Logs") {
                    appState.logTarget = (container.Id, container.name)
                }
                iconButton("pencil", help: "Edit container") { onEdit() }
                iconButton("paintpalette", help: "Customize (nickname, color, group)") { onCustomize() }
                if container.isRunning, container.primaryWebPort != nil {
                    iconButton("globe", help: "Open web UI") {
                        appState.openWebUI(for: container)
                    }
                }
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    selected ? tint : Color.primary.opacity(0.08),
                    lineWidth: selected ? 2 : 1
                )
        )
        .overlay(alignment: .topTrailing) {
            if hovering || selected {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggleSelect() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(6)
                    .help("Select for bulk actions")
            }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedContainerID =
                appState.selectedContainerID == container.Id ? nil : container.Id
        }
        .contextMenu { ContainerContextMenu(container: container, onCustomize: onCustomize, onEdit: onEdit) }
    }

    private var iconBadge: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 32, height: 32)
            .overlay {
                Text(custom.icon ?? ContainerTint.monogram(for: container.name))
                    .font(.system(size: custom.icon == nil ? 14 : 15, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private func statPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
    }

    private func smallButton(_ label: String, symbol: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}

// MARK: - List row

struct ContainerRow: View {
    @EnvironmentObject private var appState: AppState

    var container: ContainerSummary
    var selected: Bool
    var onToggleSelect: () -> Void
    var onCustomize: () -> Void
    var onEdit: () -> Void

    private var metrics: ContainerMetrics? { appState.metrics.first { $0.id == container.Id } }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggleSelect() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(appState.displayName(of: container))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(container.shortImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)

            StateBadge(container: container)
                .frame(width: 100, alignment: .leading)

            Text(Format.relative(container.Created))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(ports)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 110, alignment: .leading)

            Group {
                Text(container.isRunning ? metrics.map { String(format: "%.1f%%", $0.cpu) } ?? "…" : "—")
                    .frame(width: 56, alignment: .trailing)
                Text(container.isRunning ? metrics.map { Format.bytes($0.memUsed) } ?? "…" : "—")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 11, design: .monospaced))

            Spacer()

            HStack(spacing: 4) {
                if container.isRunning {
                    rowIcon("stop.fill", help: "Stop") {
                        Task { await appState.perform(.stop, on: container) }
                    }
                    rowIcon("arrow.clockwise", help: "Restart") {
                        Task { await appState.perform(.restart, on: container) }
                    }
                    rowIcon("terminal", help: "Console") {
                        appState.terminalTarget = container.Id
                        appState.page = .terminal
                    }
                } else {
                    rowIcon("play.fill", help: "Start") {
                        Task { await appState.perform(.start, on: container) }
                    }
                }
                rowIcon("text.alignleft", help: "Logs") {
                    appState.logTarget = (container.Id, container.name)
                }
                rowIcon("pencil", help: "Edit") { onEdit() }
                if container.isRunning, container.primaryWebPort != nil {
                    rowIcon("globe", help: "Open web UI") {
                        appState.openWebUI(for: container)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedContainerID =
                appState.selectedContainerID == container.Id ? nil : container.Id
        }
        .contextMenu { ContainerContextMenu(container: container, onCustomize: onCustomize, onEdit: onEdit) }
    }

    private var ports: String {
        (container.Ports ?? [])
            .filter { $0.PublicPort != nil }
            .map { "\($0.PublicPort ?? 0)→\($0.PrivatePort)" }
            .sorted()
            .joined(separator: ", ")
    }

    private func rowIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Context menu (shared by card and row)

struct ContainerContextMenu: View {
    @EnvironmentObject private var appState: AppState
    var container: ContainerSummary
    var onCustomize: () -> Void
    var onEdit: () -> Void

    var body: some View {
        if container.isRunning {
            Button("Stop") { Task { await appState.perform(.stop, on: container) } }
            Button("Restart") { Task { await appState.perform(.restart, on: container) } }
            Button("Open Console") {
                appState.terminalTarget = container.Id
                appState.page = .terminal
            }
            Button("Browse Files") {
                appState.filesTarget = container.Id
                appState.page = .files
            }
        } else {
            Button("Start") { Task { await appState.perform(.start, on: container) } }
        }
        Button("Logs") { appState.logTarget = (container.Id, container.name) }
        Divider()
        Button("Edit…") { onEdit() }
        Button("Customize…") { onCustomize() }
        if container.isRunning, container.primaryWebPort != nil {
            Button("Open Web UI") { appState.openWebUI(for: container) }
        }
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            if values.count >= 2 {
                let maxValue = max(values.max() ?? 5, 5) * 1.15
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: width * CGFloat(index) / CGFloat(values.count - 1),
                        y: height - 2 - (height - 6) * CGFloat(min(value, maxValue) / maxValue)
                    )
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.13))
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height - 4))
                    path.addLine(to: CGPoint(x: width, y: height - 4))
                }
                .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
        }
    }
}

// MARK: - Remove confirmation (two-step by design)

/// Removing is the one action you can't take back — the dialog states exactly
/// what is destroyed and requires an explicit second step.
struct RemoveContainersSheet: View {
    @Environment(\.dismiss) private var dismiss
    var names: [String]
    var onConfirm: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Remove \(names.count) container\(names.count == 1 ? "" : "s")?",
                systemImage: "trash"
            )
            .font(.headline)

            Text("The container\(names.count == 1 ? " is" : "s are") deleted — config, ports and logs go with \(names.count == 1 ? "it" : "them"). Data in volumes and bind mounts is kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        Text(name).font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Toggle("I understand this cannot be undone", isOn: $acknowledged)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .disabled(!acknowledged)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

// MARK: - Customize sheet

struct CustomizeSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var container: ContainerSummary

    @State private var nickname = ""
    @State private var tint: String?
    @State private var icon: String?
    @State private var group = ""

    private static let icons = [
        "📦", "🌐", "🗄", "⚙️", "🚀", "🎬", "📮", "🛠", "🐘", "🧱", "📊", "🔔",
        "🔒", "📈", "🧭", "🌱", "🏷", "✂️", "🪧", "🗃"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize — \(container.name)")
                .font(.headline)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ContainerTint.color(hex: tint ?? ContainerTint.auto(for: container.name)).gradient)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(icon ?? ContainerTint.monogram(for: container.name))
                            .font(.system(size: icon == nil ? 18 : 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(nickname.isEmpty ? container.name : nickname)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Saved locally — the container itself is untouched")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            TextField("Nickname (optional)", text: $nickname)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    swatch(nil)
                    ForEach(ContainerTint.palette, id: \.self) { hex in
                        swatch(hex)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34))], spacing: 6) {
                    iconOption(nil)
                    ForEach(Self.icons, id: \.self) { emoji in
                        iconOption(emoji)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Group").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("Group name (optional)", text: $group)
                    .textFieldStyle(.roundedBorder)
                let existing = Set((appState.store.config.gcGroups ?? [:]).values).sorted()
                if !existing.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(existing, id: \.self) { name in
                            Button(name) { group = name }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                }
            }

            HStack {
                Button("Reset to default") {
                    var custom = appState.store.config.gcCustom ?? [:]
                    custom.removeValue(forKey: container.name)
                    appState.store.config.gcCustom = custom
                    var groups = appState.store.config.gcGroups ?? [:]
                    groups.removeValue(forKey: container.name)
                    appState.store.config.gcGroups = groups
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .onAppear {
            let custom = appState.customization(of: container.name)
            nickname = custom.nickname ?? ""
            tint = custom.tint
            icon = custom.icon
            group = appState.store.config.gcGroups?[container.name] ?? ""
        }
    }

    private func swatch(_ hex: String?) -> some View {
        Button {
            tint = hex
        } label: {
            Circle()
                .fill(hex.map { ContainerTint.color(hex: $0) } ?? Color.secondary.opacity(0.3))
                .frame(width: 22, height: 22)
                .overlay {
                    if hex == nil {
                        Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    Circle().strokeBorder(
                        tint == hex ? Color.accentColor : .clear, lineWidth: 2
                    )
                )
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "Automatic" : hex!)
    }

    private func iconOption(_ emoji: String?) -> some View {
        Button {
            icon = emoji
        } label: {
            Text(emoji ?? ContainerTint.monogram(for: container.name))
                .font(.system(size: emoji == nil ? 13 : 16, weight: .bold))
                .frame(width: 32, height: 32)
                .background(
                    icon == emoji ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }

    private func save() {
        var entry = ContainerCustomization()
        if !nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.nickname = nickname.trimmingCharacters(in: .whitespaces)
        }
        entry.tint = tint
        entry.icon = icon

        var custom = appState.store.config.gcCustom ?? [:]
        if entry.nickname == nil && entry.tint == nil && entry.icon == nil {
            custom.removeValue(forKey: container.name)
        } else {
            custom[container.name] = entry
        }
        appState.store.config.gcCustom = custom

        var groups = appState.store.config.gcGroups ?? [:]
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        if trimmedGroup.isEmpty {
            groups.removeValue(forKey: container.name)
        } else {
            groups[container.name] = trimmedGroup
        }
        appState.store.config.gcGroups = groups

        ToastCenter.shared.show("Customization saved")
        dismiss()
    }
}

// MARK: - Group sheet

struct GroupSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var existing: String?
    var preselect: [String]
    var onSaved: () -> Void

    @State private var name = ""
    @State private var members = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing.map { "Edit group — \($0)" }
                 ?? (preselect.isEmpty ? "New group" : "New group — \(preselect.count) selected"))
                .font(.headline)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            let existingGroups = Set((appState.store.config.gcGroups ?? [:]).values).sorted()
            if existing == nil && !existingGroups.isEmpty {
                HStack(spacing: 4) {
                    Text("Add to existing:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(existingGroups, id: \.self) { groupName in
                        Button(groupName) { name = groupName }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.containers.map(\.name).sorted(), id: \.self) { containerName in
                        Toggle(isOn: Binding(
                            get: { members.contains(containerName) },
                            set: { on in
                                if on { members.insert(containerName) } else { members.remove(containerName) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text(containerName).font(.system(size: 12))
                                if let current = appState.store.config.gcGroups?[containerName],
                                   current != existing {
                                    Text("— currently in \(current)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if existing != nil {
                    Button("Dissolve group", role: .destructive) { dissolve() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == "Ungrouped")
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            name = existing ?? ""
            let map = appState.store.config.gcGroups ?? [:]
            var initial = Set(preselect)
            if let existing {
                for (container, groupName) in map where groupName == existing {
                    initial.insert(container)
                }
            }
            members = initial
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "Ungrouped" else { return }
        var map = appState.store.config.gcGroups ?? [:]
        for containerName in appState.containers.map(\.name) {
            if members.contains(containerName) {
                map[containerName] = trimmed
            } else if map[containerName] == trimmed || (existing != nil && map[containerName] == existing) {
                map.removeValue(forKey: containerName)
            }
        }
        appState.store.config.gcGroups = map
        ToastCenter.shared.show("Group \"\(trimmed)\" saved")
        onSaved()
        dismiss()
    }

    private func dissolve() {
        guard let existing else { return }
        var map = appState.store.config.gcGroups ?? [:]
        for (key, value) in map where value == existing {
            map.removeValue(forKey: key)
        }
        appState.store.config.gcGroups = map
        ToastCenter.shared.show("Group dissolved", style: .info)
        dismiss()
    }
}
