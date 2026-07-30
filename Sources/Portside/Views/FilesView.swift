import AppKit
import SwiftUI

/// Container file browser: mapped volumes as quick-jump chips (default view),
/// full-filesystem browsing, download, upload, and in-app editing of config
/// files — all over the Docker exec + archive APIs.
struct FilesView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedContainerID = ""
    @State private var path = "/"
    @State private var entries: [FileEntry] = []
    @State private var mounts: [(destination: String, source: String)] = []
    @State private var loading = false
    @State private var error: String?
    @State private var editorTarget: EditorTarget?

    struct FileEntry: Identifiable {
        var name: String
        var type: EntryType
        var size: Int64
        var date: String
        var permissions: String
        var linkTarget: String?

        var id: String { name }

        enum EntryType { case directory, file, link }
    }

    struct EditorTarget: Identifiable {
        let id = UUID()
        var containerID: String
        var directory: String
        var name: String
        var content: String
    }

    private var running: [ContainerSummary] {
        appState.containers.filter(\.isRunning).sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            mountChips
            Divider().opacity(0.4)
            breadcrumbs
            content
        }
        .navigationSubtitle("Files")
        .onAppear {
            if let target = appState.filesTarget {
                selectedContainerID = target
                appState.filesTarget = nil
            } else if selectedContainerID.isEmpty {
                selectedContainerID = running.first?.Id ?? ""
            }
            if !selectedContainerID.isEmpty {
                Task { await loadMounts(navigate: true) }
            }
        }
        .onChange(of: selectedContainerID) {
            Task { await loadMounts(navigate: true) }
        }
        .sheet(item: $editorTarget) { target in
            FileEditorSheet(target: target) {
                Task { await load(path) }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("Container", selection: $selectedContainerID) {
                if running.isEmpty {
                    Text("No running containers").tag("")
                }
                ForEach(running) { container in
                    Text(container.name).tag(container.Id)
                }
            }
            .frame(maxWidth: 280)
            Spacer()
            Button {
                upload()
            } label: {
                Label("Upload…", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedContainerID.isEmpty)
            Button {
                Task { await load(path) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(selectedContainerID.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var mountChips: some View {
        if !mounts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mounts, id: \.destination) { mount in
                        chip(
                            label: mount.destination,
                            symbol: "externaldrive",
                            active: path.hasPrefix(mount.destination),
                            help: "mapped from \(mount.source)"
                        ) {
                            Task { await load(mount.destination + "/") }
                        }
                    }
                    chip(label: "full fs", symbol: "folder", active: false, help: "Browse the container's entire filesystem") {
                        Task { await load("/") }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    private func chip(label: String, symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    active ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                crumb("/", to: "/")
                let segments = path.split(separator: "/").map(String.init)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    crumb(segment, to: "/" + segments[0...index].joined(separator: "/") + "/")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }

    private func crumb(_ label: String, to target: String) -> some View {
        Button(label) {
            Task { await load(target) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.orange)
                Text("Can't open folder").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(entries) {
                TableColumn("Name") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: entry))
                            .foregroundStyle(entry.type == .directory ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        Text(entry.name)
                            .font(.system(size: 12))
                        if let link = entry.linkTarget {
                            Text("→ \(link)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if entry.type == .directory {
                            Task { await load(path + entry.name + "/") }
                        } else if entry.type == .file, entry.size <= 1_048_576 {
                            Task { await edit(entry) }
                        }
                    }
                }
                .width(min: 240, ideal: 380)
                TableColumn("Size") { entry in
                    Text(entry.type == .file ? Format.bytes(entry.size) : "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Modified") { entry in
                    Text(entry.date)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(120)
                TableColumn("") { entry in
                    HStack(spacing: 4) {
                        if entry.type == .file && entry.size <= 1_048_576 {
                            Button {
                                Task { await edit(entry) }
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("View / edit")
                        }
                        if entry.type == .file {
                            Button {
                                Task { await download(entry) }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Download")
                        }
                    }
                }
                .width(60)
            }
        }
    }

    private func symbol(for entry: FileEntry) -> String {
        switch entry.type {
        case .directory: return "folder.fill"
        case .link: return "link"
        case .file: return "doc"
        }
    }

    // MARK: - Loading

    private func loadMounts(navigate: Bool) async {
        guard let client = appState.client, !selectedContainerID.isEmpty else { return }
        mounts = []
        if let details = try? await client.inspect(id: selectedContainerID) {
            mounts = (details.Mounts ?? [])
                .compactMap { mount in
                    guard let destination = mount.Destination else { return nil }
                    return (destination, mount.Source ?? mount.Name ?? "")
                }
                .sorted { $0.0 < $1.0 }
        }
        if navigate {
            await load(mounts.first.map { $0.destination + "/" } ?? "/")
        }
    }

    private func load(_ target: String) async {
        guard let client = appState.client, !selectedContainerID.isEmpty else { return }
        path = target.hasSuffix("/") ? target : target + "/"
        loading = true
        error = nil
        defer { loading = false }
        do {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            let output = try await client.execCapture(
                containerID: selectedContainerID,
                command: "cd '\(escaped)' && LC_ALL=C ls -lA"
            )
            entries = Self.parseListing(output)
            if entries.isEmpty,
               output.range(of: "can't cd|No such file|Permission denied|not found",
                            options: [.regularExpression, .caseInsensitive]) != nil {
                error = output.components(separatedBy: "\n").first
                entries = []
            }
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    /// Parses `ls -lA` output (busybox and coreutils formats).
    static func parseListing(_ output: String) -> [FileEntry] {
        var result: [FileEntry] = []
        let pattern = /^([dlbcsp-])([rwxsStT-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)(?:,\s*\d+)?\s+(\w+\s+\d+\s+[\d:]+)\s+(.+)$/
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.wholeMatch(of: pattern) else { continue }
            var name = String(match.7)
            var link: String?
            let kind = String(match.1)
            if kind == "l", let range = name.range(of: " -> ") {
                link = String(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
            result.append(FileEntry(
                name: name,
                type: kind == "d" ? .directory : (kind == "l" ? .link : .file),
                size: Int64(match.5) ?? 0,
                date: String(match.6),
                permissions: kind + String(match.2),
                linkTarget: link
            ))
        }
        return result.sorted {
            ($0.type == .directory ? 0 : 1, $0.name.lowercased())
                < ($1.type == .directory ? 0 : 1, $1.name.lowercased())
        }
    }

    // MARK: - File operations

    private func edit(_ entry: FileEntry) async {
        guard let client = appState.client else { return }
        do {
            let archive = try await client.downloadArchive(
                containerID: selectedContainerID, path: path + entry.name, maxBytes: 1_048_576
            )
            guard let file = Tar.extractFirstFile(archive) else {
                throw SimpleError("Empty archive")
            }
            guard !file.content.contains(0) else {
                throw SimpleError("Binary file — use Download instead")
            }
            editorTarget = EditorTarget(
                containerID: selectedContainerID,
                directory: path,
                name: entry.name,
                content: String(decoding: file.content, as: UTF8.self)
            )
        } catch {
            ToastCenter.shared.show("Can't open file", detail: error.localizedDescription, style: .error)
        }
    }

    private func download(_ entry: FileEntry) async {
        guard let client = appState.client else { return }
        do {
            let archive = try await client.downloadArchive(
                containerID: selectedContainerID, path: path + entry.name
            )
            guard let file = Tar.extractFirstFile(archive) else {
                throw SimpleError("Empty archive")
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try file.content.write(to: url)
            ToastCenter.shared.show("Saved to \(url.path)")
        } catch {
            ToastCenter.shared.show("Download failed", detail: error.localizedDescription, style: .error)
        }
    }

    private func upload() {
        guard let client = appState.client, !selectedContainerID.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 100 * 1024 * 1024 else {
                    throw SimpleError("File too large (>100 MB)")
                }
                try await client.uploadArchive(
                    containerID: selectedContainerID,
                    directory: path,
                    tar: Tar.create(name: url.lastPathComponent, content: data)
                )
                ToastCenter.shared.show("Uploaded \(url.lastPathComponent) to \(path)")
                await load(path)
            } catch {
                ToastCenter.shared.show("Upload failed", detail: error.localizedDescription, style: .error)
            }
        }
    }
}

// MARK: - Editor sheet

struct FileEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var target: FilesView.EditorTarget
    var onSaved: () -> Void

    @State private var content = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.directory + target.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save to container") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
            .padding(12)
            Divider()
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
        }
        .frame(width: 720, height: 520)
        .onAppear { content = target.content }
    }

    private func save() async {
        guard let client = appState.client else { return }
        saving = true
        defer { saving = false }
        do {
            try await client.uploadArchive(
                containerID: target.containerID,
                directory: target.directory,
                tar: Tar.create(name: target.name, content: Data(content.utf8))
            )
            ToastCenter.shared.show(
                "\(target.name) saved",
                detail: "Restart the container to apply config changes"
            )
            onSaved()
            dismiss()
        } catch {
            ToastCenter.shared.show("Save failed", detail: error.localizedDescription, style: .error)
        }
    }
}
