import SwiftUI

/// ⌘K command palette: jump to any page, open or act on any container.
struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id = UUID()
        var symbol: String
        var label: String
        var subtitle: String
        var run: @MainActor () -> Void
    }

    private var commands: [Command] {
        var all: [Command] = Page.allCases.map { page in
            Command(symbol: page.symbol, label: "Go to \(page.title)", subtitle: "page") { [weak appState] in
                appState?.page = page
            }
        }
        all.append(Command(symbol: "plus", label: "Deploy a container", subtitle: "action") { [weak appState] in
            appState?.page = .containers
        })
        all.append(Command(symbol: "arrow.clockwise", label: "Refresh", subtitle: "action") { [weak appState] in
            Task { await appState?.refresh() }
        })
        all.append(Command(symbol: "square.and.arrow.down", label: "Check for updates", subtitle: "action") { [weak appState] in
            Task { await appState?.updates.check(userInitiated: true) }
        })
        for container in appState.containers {
            let display = appState.displayName(of: container)
            all.append(Command(symbol: "shippingbox", label: "Open \(display)", subtitle: container.State ?? "container") { [weak appState] in
                appState?.selectedContainerID = container.Id
                appState?.page = .containers
            })
            if container.isRunning {
                all.append(Command(symbol: "arrow.clockwise", label: "Restart \(display)", subtitle: "container") { [weak appState] in
                    Task { await appState?.perform(.restart, on: container) }
                })
            } else {
                all.append(Command(symbol: "play.fill", label: "Start \(display)", subtitle: "container") { [weak appState] in
                    Task { await appState?.perform(.start, on: container) }
                })
            }
        }
        return all
    }

    private var filtered: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter {
            "\($0.label) \($0.subtitle)".localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { appState.showCommandPalette = false }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Type a command or container name…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { runSelected() }
                }
                .padding(12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(filtered.prefix(60).enumerated()), id: \.element.id) { index, command in
                                Button {
                                    run(command)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: command.symbol)
                                            .frame(width: 18)
                                            .foregroundStyle(.secondary)
                                        Text(command.label)
                                            .font(.system(size: 13))
                                        Spacer()
                                        Text(command.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                            if filtered.isEmpty {
                                Text("No matches")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedIndex) {
                        proxy.scrollTo(selectedIndex)
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .padding(.top, 90)
        }
        .onAppear {
            focused = true
            selectedIndex = 0
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            appState.showCommandPalette = false
            return .handled
        }
    }

    private func runSelected() {
        guard selectedIndex < filtered.count else { return }
        run(filtered[selectedIndex])
    }

    private func run(_ command: Command) {
        appState.showCommandPalette = false
        command.run()
    }
}
