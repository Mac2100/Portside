import AppKit
import SwiftTerm
import SwiftUI

/// Interactive console: `docker exec` into a running container over the
/// hijacked TLS stream, rendered by SwiftTerm (full xterm-256color).
struct TerminalPageView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var session = TerminalSessionModel()

    @State private var selectedContainerID = ""

    private var running: [ContainerSummary] {
        appState.containers.filter(\.isRunning).sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
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

                Circle()
                    .fill(session.connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(session.connected ? session.connectedName : "Not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                if session.connected {
                    Button("Disconnect") { session.disconnect() }
                } else {
                    Button("Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedContainerID.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider().opacity(0.4)

            TerminalHostView(session: session)
                .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        }
        .navigationSubtitle("Terminal")
        .onAppear {
            if let target = appState.terminalTarget {
                selectedContainerID = target
                appState.terminalTarget = nil
                connect()
            } else if selectedContainerID.isEmpty {
                selectedContainerID = running.first?.Id ?? ""
            }
        }
        .onChange(of: selectedContainerID) {
            if session.connected { connect() }
        }
        .onDisappear { session.disconnect() }
    }

    private func connect() {
        guard !selectedContainerID.isEmpty,
              let container = running.first(where: { $0.Id == selectedContainerID }) else { return }
        session.connect(
            client: appState.client, containerID: container.Id, name: container.name
        )
    }
}

/// Owns the exec session: bridges SwiftTerm's input to the Docker socket and
/// the socket's output back into the terminal.
@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published var connected = false
    @Published var connectedName = ""

    weak var terminalView: TerminalView?

    private var exec: DockerClient.ExecSession?
    private var readTask: Task<Void, Never>?
    private var client: DockerClient?

    func connect(client: DockerClient?, containerID: String, name: String) {
        disconnect()
        guard let client else { return }
        self.client = client
        let cols = terminalView?.getTerminal().cols ?? 80
        let rows = terminalView?.getTerminal().rows ?? 24

        Task {
            do {
                let session = try await client.openShell(
                    containerID: containerID, cols: cols, rows: rows
                )
                self.exec = session
                self.connected = true
                self.connectedName = name
                self.terminalView?.getTerminal().resetToInitialState()
                self.readTask = Task { [weak self] in
                    do {
                        for try await chunk in session.stream.incoming {
                            await MainActor.run {
                                self?.terminalView?.feed(byteArray: ArraySlice([UInt8](chunk)))
                            }
                        }
                    } catch { }
                    await MainActor.run {
                        guard let self else { return }
                        self.terminalView?.feed(text: "\r\n[session closed]\r\n")
                        self.connected = false
                    }
                }
            } catch {
                ToastCenter.shared.show("Console failed", detail: error.localizedDescription, style: .error)
            }
        }
    }

    func disconnect() {
        readTask?.cancel()
        readTask = nil
        exec?.stream.close()
        exec = nil
        connected = false
    }

    func send(_ data: ArraySlice<UInt8>) {
        exec?.stream.write(Data(data))
    }

    func resize(cols: Int, rows: Int) {
        guard let exec, let client else { return }
        Task { try? await client.resizeExec(execID: exec.execID, cols: cols, rows: rows) }
    }
}

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionModel

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.95, alpha: 1)
        session.terminalView = view
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        session.terminalView = view
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSessionModel

        init(session: TerminalSessionModel) {
            self.session = session
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in
                self.session.send(bytes[...])
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.session.resize(cols: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        nonisolated func scrolled(source: TerminalView, position: Double) {}

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
            }
        }

        nonisolated func bell(source: TerminalView) {}

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                Task { @MainActor in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }

        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
