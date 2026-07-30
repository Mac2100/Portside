import AppKit
import SwiftUI

/// Slide-over panel streaming a container's logs: follow mode with ANSI
/// colors, pause, search, and export.
struct LogPanelView: View {
    @EnvironmentObject private var appState: AppState

    var containerID: String
    var containerName: String

    @StateObject private var model = LogStreamModel()
    @State private var search = ""

    // Explicit initializer: private @State/@StateObject storage would make the
    // synthesized memberwise initializer private, and this view is created
    // from another file.
    init(containerID: String, containerName: String) {
        self.containerID = containerID
        self.containerName = containerName
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.25)
                .onTapGesture { appState.logTarget = nil }
            panel
                .frame(width: 720)
        }
        .ignoresSafeArea()
        .task(id: containerID) {
            await model.start(client: appState.client, containerID: containerID)
        }
        .onDisappear { model.stop() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.streaming && !model.paused ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(containerName)
                    .font(.headline)
                Spacer()
                SearchField(text: $search, prompt: "Find in logs")
                Button {
                    model.paused.toggle()
                } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                }
                .help(model.paused ? "Resume stream" : "Pause stream")
                Button {
                    save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save logs to a file — Docker discards them when the container is recreated")
                Button {
                    appState.logTarget = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.regularMaterial)

            Divider()

            LogTextView(lines: filteredLines)
                .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        }
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.3), radius: 16, x: -4)
    }

    private var filteredLines: [AttributedString] {
        guard !search.isEmpty else { return model.lines }
        return model.lines.filter {
            String($0.characters).localizedCaseInsensitiveContains(search)
        }
    }

    private func save() {
        Task {
            guard let client = appState.client,
                  let text = try? await client.logs(id: containerID, tail: 5000) else {
                ToastCenter.shared.show("Could not read logs", style: .error)
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(containerName)-\(Date().formatted(.iso8601.year().month().day())).log"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            ToastCenter.shared.show("Saved to \(url.path)")
        }
    }
}

/// Follows the log stream, parsing ANSI colors into attributed lines.
@MainActor
final class LogStreamModel: ObservableObject {
    @Published var lines: [AttributedString] = []
    @Published var streaming = false
    @Published var paused = false {
        didSet {
            if !paused && !buffered.isEmpty {
                lines.append(contentsOf: buffered)
                buffered.removeAll()
                trim()
            }
        }
    }

    private var buffered: [AttributedString] = []
    private var task: Task<Void, Never>?
    private var parser = ANSIParser()
    private var partial = ""

    func start(client: DockerClient?, containerID: String) async {
        stop()
        lines = []
        partial = ""
        parser = ANSIParser()
        guard let client else { return }
        streaming = true
        task = Task { [weak self] in
            do {
                for try await chunk in client.followLogs(id: containerID) {
                    guard let self else { return }
                    let text = String(decoding: chunk, as: UTF8.self)
                    await MainActor.run { self.append(text: text) }
                }
            } catch { }
            await MainActor.run { [weak self] in
                self?.streaming = false
                self?.append(text: "\n── log stream ended ──\n")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        streaming = false
    }

    private func append(text: String) {
        partial += text
        var newLines: [AttributedString] = []
        while let newline = partial.firstIndex(of: "\n") {
            let line = String(partial[..<newline])
            partial = String(partial[partial.index(after: newline)...])
            newLines.append(parser.parse(line: line))
        }
        guard !newLines.isEmpty else { return }
        if paused {
            buffered.append(contentsOf: newLines)
            if buffered.count > 5000 { buffered.removeFirst(buffered.count - 5000) }
        } else {
            lines.append(contentsOf: newLines)
            trim()
        }
    }

    private func trim() {
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
}

/// Renders attributed log lines in a fast NSTextView (SwiftUI Text chokes on
/// thousands of lines).
struct LogTextView: NSViewRepresentable {
    var lines: [AttributedString]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let wasAtBottom = isAtBottom(scroll)

        let combined = NSMutableAttributedString()
        for line in lines {
            let converted = (try? NSAttributedString(line, including: \.appKit))
                ?? NSAttributedString(string: String(line.characters))
            combined.append(converted)
            combined.append(NSAttributedString(string: "\n"))
        }
        textView.textStorage?.setAttributedString(combined)

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isAtBottom(_ scroll: NSScrollView) -> Bool {
        guard let documentView = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= documentView.bounds.height - 40
    }
}

/// Minimal SGR (color/bold) ANSI parser. Cursor-movement sequences are
/// stripped; colors and emphasis are kept.
struct ANSIParser {
    private var currentColor: NSColor?
    private var bold = false

    private static let basicColors: [NSColor] = [
        NSColor(calibratedRed: 0.40, green: 0.42, blue: 0.46, alpha: 1),   // black (visible on dark bg)
        NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.45, alpha: 1),   // red
        NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.42, alpha: 1),   // green
        NSColor(calibratedRed: 0.90, green: 0.72, blue: 0.25, alpha: 1),   // yellow
        NSColor(calibratedRed: 0.40, green: 0.69, blue: 1.00, alpha: 1),   // blue
        NSColor(calibratedRed: 0.80, green: 0.57, blue: 1.00, alpha: 1),   // magenta
        NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.84, alpha: 1),   // cyan
        NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)    // white
    ]
    private static let defaultColor = NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.89, alpha: 1)

    mutating func parse(line: String) -> AttributedString {
        var result = AttributedString()
        var pending = ""

        func flush() {
            guard !pending.isEmpty else { return }
            var piece = AttributedString(pending)
            piece[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] =
                currentColor ?? Self.defaultColor
            piece[AttributeScopes.AppKitAttributes.FontAttribute.self] =
                NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
            result.append(piece)
            pending = ""
        }

        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\u{1B}" {
                // Escape sequence: consume "[...letter".
                flush()
                var cursor = line.index(after: index)
                guard cursor < line.endIndex, line[cursor] == "[" else {
                    index = cursor
                    continue
                }
                cursor = line.index(after: cursor)
                var parameters = ""
                while cursor < line.endIndex, line[cursor].isNumber || line[cursor] == ";" {
                    parameters.append(line[cursor])
                    cursor = line.index(after: cursor)
                }
                if cursor < line.endIndex {
                    let terminator = line[cursor]
                    cursor = line.index(after: cursor)
                    if terminator == "m" {
                        applySGR(parameters)
                    }
                    // Every other CSI sequence is stripped.
                }
                index = cursor
            } else if char == "\r" {
                index = line.index(after: index)
            } else {
                pending.append(char)
                index = line.index(after: index)
            }
        }
        flush()
        return result
    }

    private mutating func applySGR(_ parameters: String) {
        let codes = parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
        var iterator = codes.makeIterator()
        while let code = iterator.next() {
            switch code {
            case 0:
                currentColor = nil
                bold = false
            case 1:
                bold = true
            case 22:
                bold = false
            case 30...37:
                currentColor = Self.basicColors[code - 30]
            case 90...97:
                currentColor = Self.basicColors[code - 90]
            case 39:
                currentColor = nil
            case 38:
                // 38;5;n (256-color) or 38;2;r;g;b (truecolor)
                if let mode = iterator.next() {
                    if mode == 5, let value = iterator.next() {
                        currentColor = Self.color256(value)
                    } else if mode == 2,
                              let red = iterator.next(),
                              let green = iterator.next(),
                              let blue = iterator.next() {
                        currentColor = NSColor(
                            calibratedRed: CGFloat(red) / 255,
                            green: CGFloat(green) / 255,
                            blue: CGFloat(blue) / 255, alpha: 1
                        )
                    }
                }
            default:
                break
            }
        }
    }

    private static func color256(_ value: Int) -> NSColor {
        if value < 16 {
            return basicColors[value % 8]
        }
        if value < 232 {
            let index = value - 16
            let red = CGFloat(index / 36) / 5
            let green = CGFloat((index / 6) % 6) / 5
            let blue = CGFloat(index % 6) / 5
            return NSColor(calibratedRed: 0.2 + red * 0.8, green: 0.2 + green * 0.8, blue: 0.2 + blue * 0.8, alpha: 1)
        }
        let gray = CGFloat(value - 232) / 23
        return NSColor(calibratedWhite: 0.2 + gray * 0.75, alpha: 1)
    }
}
