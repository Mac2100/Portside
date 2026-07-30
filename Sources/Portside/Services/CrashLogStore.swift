import Foundation

/// Crash log snapshots. When a container dies, its logs are captured *at that
/// moment* — if the container is later recreated (auto-update, edit, redeploy)
/// Docker's copy is gone, but this one survives. The newest forty are kept.
@MainActor
final class CrashLogStore: ObservableObject {
    static let shared = CrashLogStore()

    @Published private(set) var entries: [CrashLogEntry] = []

    private static let keepCount = 40

    private var directory: URL {
        ConfigStore.supportDirectory.appendingPathComponent("crashlogs", isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        // V2 stored `time` as ms since epoch; V3 uses Codable dates. Try both.
        if let decoded = try? JSONDecoder().decode([CrashLogEntry].self, from: data) {
            entries = decoded
            return
        }
        struct LegacyEntry: Decodable {
            var file: String
            var name: String
            var containerId: String?
            var exitCode: FlexibleInt?
            var status: String?
            var time: Double
        }
        struct FlexibleInt: Decodable {
            var value: Int?
            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                value = (try? single.decode(Int.self)) ?? (try? single.decode(String.self)).flatMap(Int.init)
            }
        }
        if let legacy = try? JSONDecoder().decode([LegacyEntry].self, from: data) {
            entries = legacy.map {
                CrashLogEntry(
                    file: $0.file, name: $0.name, containerId: $0.containerId ?? "",
                    exitCode: $0.exitCode?.value, status: $0.status ?? "",
                    time: Date(timeIntervalSince1970: $0.time / 1000)
                )
            }
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func entry(forContainerName name: String) -> CrashLogEntry? {
        entries.first { $0.name == name }
    }

    func capture(name: String, containerID: String, exitCode: Int?, status: String, text: String) {
        let now = Date()
        let safeName = name.replacingOccurrences(
            of: "[^\\w.-]", with: "_", options: .regularExpression
        )
        let file = "\(safeName)-\(Int(now.timeIntervalSince1970 * 1000)).log"
        let header = """
        # \(name) — crashed \(now.formatted(date: .abbreviated, time: .standard))
        # exit code: \(exitCode.map(String.init) ?? "?")
        # status: \(status)
        # container: \(containerID)
        # captured by Portside the moment the crash was detected — the container may since have been recreated


        """
        try? (header + (text.isEmpty ? "(no log output)" : text))
            .write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)

        entries.insert(
            CrashLogEntry(
                file: file, name: name, containerId: containerID,
                exitCode: exitCode, status: status, time: now
            ),
            at: 0
        )
        // Trim old snapshots so this can't grow forever.
        while entries.count > Self.keepCount {
            let removed = entries.removeLast()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(removed.file))
        }
        saveIndex()
    }

    func text(of entry: CrashLogEntry) -> String? {
        // Never let a crafted name escape the crashlog directory.
        let safe = (entry.file as NSString).lastPathComponent
        return try? String(contentsOf: directory.appendingPathComponent(safe), encoding: .utf8)
    }

    func remove(_ entry: CrashLogEntry) {
        let safe = (entry.file as NSString).lastPathComponent
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(safe))
        entries.removeAll { $0.file == entry.file }
        saveIndex()
    }
}
