import SwiftUI

// MARK: - Shared pieces

enum UsageStatus: String {
    case inUse = "In use"
    case unused = "Unused"
    case dangling = "Dangling"
    case builtin = "Built-in"

    var color: Color {
        switch self {
        case .inUse: return .green
        case .unused: return .secondary
        case .dangling: return .orange
        case .builtin: return .blue
        }
    }
}

struct UsageBadge: View {
    var status: UsageStatus
    var count: Int = 0

    var body: some View {
        Text(count > 1 ? "\(status.rawValue) ×\(count)" : status.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

struct FilterChip: View {
    var label: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    active ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct UsedByLine: View {
    var users: [String]
    var emptyText: String

    var body: some View {
        Group {
            if users.isEmpty {
                Text(emptyText)
            } else {
                let shown = users.prefix(3).joined(separator: ", ")
                let more = users.count > 3 ? " +\(users.count - 3) more" : ""
                Text("Used by \(shown)\(more)")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(2)
    }
}

private let resourceGridColumns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)]

// MARK: - Images

struct ImagesView: View {
    @EnvironmentObject private var appState: AppState

    @State private var filter = "all"
    @State private var showCleanup = false
    @State private var removeTarget: ImageRemoveRequest?

    struct ImageRemoveRequest: Identifiable {
        let id = UUID()
        var image: ImageSummary
        var users: [String]
    }

    private func users(of image: ImageSummary) -> [String] {
        appState.containers
            .filter { container in
                container.ImageID == image.Id
                    || image.tags.contains(container.Image ?? "")
                    || container.Image == image.Id
            }
            .map(\.name)
    }

    private func status(of image: ImageSummary) -> UsageStatus {
        if !users(of: image).isEmpty { return .inUse }
        return image.isDangling ? .dangling : .unused
    }

    var body: some View {
        let rows = appState.images.map { (image: $0, status: status(of: $0), users: users(of: $0)) }
        let visible = filter == "all" ? rows : rows.filter { $0.status.rawValue.lowercased() == filter }

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterChip(label: "All \(rows.count)", active: filter == "all") { filter = "all" }
                FilterChip(label: "In use \(rows.filter { $0.status == .inUse }.count)", active: filter == "in use") { filter = "in use" }
                FilterChip(label: "Unused \(rows.filter { $0.status == .unused }.count)", active: filter == "unused") { filter = "unused" }
                FilterChip(label: "Dangling \(rows.filter { $0.status == .dangling }.count)", active: filter == "dangling") { filter = "dangling" }
                Spacer()
                Button {
                    showCleanup = true
                } label: {
                    Label("Clean up…", systemImage: "paintbrush")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().opacity(0.4)

            ScrollView {
                LazyVGrid(columns: resourceGridColumns, spacing: 12) {
                    ForEach(visible, id: \.image.Id) { row in
                        imageCard(row.image, status: row.status, users: row.users)
                    }
                }
                .padding(14)
            }
        }
        .navigationSubtitle("Images")
        .sheet(isPresented: $showCleanup) { ImageCleanupSheet() }
        .sheet(item: $removeTarget) { request in
            ImageRemoveSheet(request: request)
        }
    }

    private func imageCard(_ image: ImageSummary, status: UsageStatus, users: [String]) -> some View {
        let primaryTag = image.tags.first
        let name = primaryTag.map { tag -> String in
            let base = tag.split(separator: "/").last.map(String.init) ?? tag
            return base.split(separator: ":").first.map(String.init) ?? base
        } ?? "<none> \(image.shortID)"
        let tagText: String = primaryTag.flatMap { tag -> String? in
            guard let colon = tag.lastIndex(of: ":"),
                  colon > (tag.lastIndex(of: "/") ?? tag.startIndex) || !tag.contains("/") else { return "latest" }
            return String(tag[tag.index(after: colon)...])
        } ?? "none"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                UsageBadge(status: status, count: users.count)
                Button {
                    removeTarget = ImageRemoveRequest(image: image, users: users)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Delete image")
            }
            meta("Tag", tagText)
            meta("Size", Format.bytes(image.Size ?? 0))
            meta("Created", Format.relative(image.Created))
            meta("ID", image.shortID)
            if image.tags.count > 1 {
                Text(image.tags.dropFirst().joined(separator: "  "))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            UsedByLine(
                users: users,
                emptyText: status == .dangling
                    ? "Untagged leftover layers — safe to prune."
                    : "No container uses this image."
            )
        }
        .glassCard(padding: 12)
        .help(primaryTag ?? image.Id)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// Deleting one image, with in-use handling: Docker answers 409 when the
/// image is still referenced — force only untags, running containers keep
/// running, so we offer it in plain language.
struct ImageRemoveSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var request: ImagesView.ImageRemoveRequest

    @State private var working = false

    private var label: String {
        request.image.tags.first ?? request.image.shortID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete image \(label)?", systemImage: "trash")
                .font(.headline)
            if request.users.isEmpty {
                Text("It will be pulled again from the registry if you redeploy something that needs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Still used by \(request.users.joined(separator: ", ")). Deleting won't stop those containers, but they can't be recreated until the image is pulled again.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    Task { await remove() }
                }
                .disabled(working)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func remove() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }
        do {
            try await client.removeImage(id: request.image.Id, force: !request.users.isEmpty)
            ToastCenter.shared.show("Deleted \(label)")
            dismiss()
            await appState.refresh()
        } catch let error as DockerAPIError where error.status == 409 {
            // Retry with force — this only removes the tag/layers.
            do {
                try await client.removeImage(id: request.image.Id, force: true)
                ToastCenter.shared.show("Deleted \(label)")
                dismiss()
                await appState.refresh()
            } catch {
                ToastCenter.shared.show("Delete failed", detail: error.localizedDescription, style: .error)
            }
        } catch {
            ToastCenter.shared.show("Delete failed", detail: error.localizedDescription, style: .error)
        }
    }
}

/// One sheet for image cleanup: dangling and unused as two checkboxes with
/// real sizes, and a single prune call — the widest one that's ticked
/// (Docker's "remove unused" already includes dangling; they're a subset).
struct ImageCleanupSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var includeDangling = true
    @State private var includeUnused = false
    @State private var working = false

    private var groups: (dangling: [ImageSummary], unused: [ImageSummary]) {
        var dangling: [ImageSummary] = []
        var unused: [ImageSummary] = []
        for image in appState.images {
            let inUse = appState.containers.contains { container in
                container.ImageID == image.Id || image.tags.contains(container.Image ?? "")
            }
            if inUse { continue }      // in use — never offered
            if image.isDangling { dangling.append(image) } else { unused.append(image) }
        }
        return (dangling, unused)
    }

    var body: some View {
        let (dangling, unused) = groups
        let danglingSize = dangling.reduce(Int64(0)) { $0 + ($1.Size ?? 0) }
        let unusedSize = unused.reduce(Int64(0)) { $0 + ($1.Size ?? 0) }
        let totalCount = includeUnused ? dangling.count + unused.count : (includeDangling ? dangling.count : 0)
        let totalSize = includeUnused ? danglingSize + unusedSize : (includeDangling ? danglingSize : 0)

        VStack(alignment: .leading, spacing: 14) {
            Text("Clean up images")
                .font(.headline)

            option(
                isOn: $includeDangling,
                disabled: dangling.isEmpty,
                title: "\(dangling.count) dangling image\(dangling.count == 1 ? "" : "s")",
                size: dangling.isEmpty ? nil : danglingSize,
                subtitle: "Untagged leftovers from image updates. Nothing can ever use them again — free to delete."
            )
            option(
                isOn: $includeUnused,
                disabled: unused.isEmpty,
                title: "\(unused.count) unused image\(unused.count == 1 ? "" : "s")",
                size: unused.isEmpty ? nil : unusedSize,
                subtitle: "Tagged images no container runs. Deleting is safe, but they get pulled from the registry again next time you need them."
            )

            if totalCount > 0 {
                Text("Reclaims up to **\(Format.bytes(totalSize))** across \(totalCount) image\(totalCount == 1 ? "" : "s") — shared layers mean the real figure can be lower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Removing…" : "Remove") {
                    Task { await clean() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || totalCount == 0)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func option(isOn: Binding<Bool>, disabled: Bool, title: String, size: Int64?, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let size {
                        Text(Format.bytes(size))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("nothing to remove")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled)
    }

    private func clean() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }
        do {
            // One call: all=true prunes every unused image (dangling included).
            let result = try await client.pruneImages(all: includeUnused)
            let deleted = result.ImagesDeleted?.count ?? 0
            ToastCenter.shared.show(
                "Removed \(deleted) image\(deleted == 1 ? "" : "s")",
                detail: "Reclaimed \(Format.bytes(result.SpaceReclaimed ?? 0))"
            )
            dismiss()
            await appState.refresh()
        } catch {
            ToastCenter.shared.show("Cleanup failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Volumes

struct VolumesView: View {
    @EnvironmentObject private var appState: AppState

    @State private var filter = "all"
    @State private var pruneRequest: VolumePruneRequest?
    @State private var destroyTarget: VolumeDestroyRequest?

    struct VolumeDestroyRequest: Identifiable {
        let id = UUID()
        var volume: VolumeSummary
        var users: [String]
    }

    private func users(of volume: VolumeSummary) -> [String] {
        appState.containers
            .filter { container in
                (container.Mounts ?? []).contains { $0.kind == "volume" && $0.Name == volume.Name }
            }
            .map(\.name)
    }

    var body: some View {
        let rows = appState.volumes.map { (volume: $0, users: users(of: $0)) }
        let visible: [(volume: VolumeSummary, users: [String])] = {
            switch filter {
            case "in use": return rows.filter { !$0.users.isEmpty }
            case "unused": return rows.filter { $0.users.isEmpty }
            default: return rows
            }
        }()

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterChip(label: "All \(rows.count)", active: filter == "all") { filter = "all" }
                FilterChip(label: "In use \(rows.filter { !$0.users.isEmpty }.count)", active: filter == "in use") { filter = "in use" }
                FilterChip(label: "Unused \(rows.filter { $0.users.isEmpty }.count)", active: filter == "unused") { filter = "unused" }
                Spacer()
                Button {
                    let doomed = rows.filter { $0.users.isEmpty }.map(\.volume.Name)
                    if doomed.isEmpty {
                        ToastCenter.shared.show("No unused volumes — nothing to prune", style: .info)
                    } else {
                        pruneRequest = VolumePruneRequest(volumes: doomed)
                    }
                } label: {
                    Label("Prune unused…", systemImage: "trash")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().opacity(0.4)

            ScrollView {
                LazyVGrid(columns: resourceGridColumns, spacing: 12) {
                    ForEach(visible, id: \.volume.Name) { row in
                        volumeCard(row.volume, users: row.users)
                    }
                }
                .padding(14)
            }
        }
        .navigationSubtitle("Volumes")
        .sheet(item: $pruneRequest) { request in
            VolumePruneSheet(request: request)
        }
        .sheet(item: $destroyTarget) { request in
            VolumeDestroySheet(request: request)
        }
    }

    private func volumeCard(_ volume: VolumeSummary, users: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(volume.Name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                UsageBadge(status: users.isEmpty ? .unused : .inUse, count: users.count)
                Button {
                    destroyTarget = VolumeDestroyRequest(volume: volume, users: users)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Delete volume")
            }
            Text("Driver: \(volume.Driver ?? "—")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(volume.Mountpoint ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            UsedByLine(users: users, emptyText: "Not attached to any container.")
        }
        .glassCard(padding: 12)
        .help(volume.Name)
    }
}

/// A deleted volume takes its data with it. No undo, no bin, no re-pull —
/// so deleting one makes you type its name.
struct VolumeDestroySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var request: VolumesView.VolumeDestroyRequest

    @State private var phrase = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete volume \"\(request.volume.Name)\"", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text("This destroys the data inside the volume — configs, databases, anything a container keeps there. It cannot be recovered.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if request.users.isEmpty {
                Text("Nothing is using it right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("It is currently mounted by \(request.users.joined(separator: ", ")), which will lose it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Type the volume name to confirm:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(request.volume.Name, text: $phrase)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Destroy volume", role: .destructive) {
                    Task { await destroy() }
                }
                .disabled(phrase.trimmingCharacters(in: .whitespaces) != request.volume.Name || working)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func destroy() async {
        guard let client = appState.client else { return }
        working = true
        defer { working = false }
        do {
            try await client.removeVolume(name: request.volume.Name, force: !request.users.isEmpty)
            ToastCenter.shared.show("Deleted volume \(request.volume.Name)")
            dismiss()
            await appState.refresh()
        } catch {
            ToastCenter.shared.show("Delete failed", detail: error.localizedDescription, style: .error)
        }
    }
}

// MARK: - Networks

struct NetworksView: View {
    @EnvironmentObject private var appState: AppState

    @State private var removeTarget: NetworkSummary?

    private func users(of network: NetworkSummary) -> [String] {
        appState.containers
            .filter { ($0.NetworkSettings?.Networks ?? [:]).keys.contains(network.Name) }
            .map(\.name)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: resourceGridColumns, spacing: 12) {
                ForEach(appState.networks.sorted { $0.Name < $1.Name }) { network in
                    networkCard(network)
                }
            }
            .padding(14)
        }
        .navigationSubtitle("Networks")
        .confirmationDialog(
            "Delete network \"\(removeTarget?.Name ?? "")\"?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let network = removeTarget {
                    Task { await remove(network) }
                }
            }
        } message: {
            Text("Containers you later create can't join it until it's recreated.")
        }
    }

    private func networkCard(_ network: NetworkSummary) -> some View {
        let networkUsers = users(of: network)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(network.Name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                UsageBadge(
                    status: network.isBuiltin ? .builtin : (networkUsers.isEmpty ? .unused : .inUse),
                    count: networkUsers.count
                )
                if !network.isBuiltin {
                    Button {
                        if networkUsers.isEmpty {
                            removeTarget = network
                        } else {
                            ToastCenter.shared.show(
                                "\(network.Name) still has containers attached",
                                detail: "Disconnect or remove \(networkUsers.joined(separator: ", ")) first",
                                style: .error
                            )
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Delete network")
                }
            }
            Text("Driver: \(network.Driver ?? "—") · Scope: \(network.Scope ?? "—")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Subnet: \(network.subnet ?? "—")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if network.Internal == true {
                    Text("internal").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if network.Attachable == true {
                    Text("attachable").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            if !network.isBuiltin || !networkUsers.isEmpty {
                UsedByLine(users: networkUsers, emptyText: "No container is attached.")
            }
        }
        .glassCard(padding: 12)
    }

    private func remove(_ network: NetworkSummary) async {
        guard let client = appState.client else { return }
        do {
            try await client.removeNetwork(id: network.Id)
            ToastCenter.shared.show("Deleted network \(network.Name)")
            await appState.refresh()
        } catch {
            ToastCenter.shared.show("Delete failed", detail: error.localizedDescription, style: .error)
        }
    }
}
