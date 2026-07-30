import AppKit
import Foundation

/// In-place self-update: downloads the release DMG, mounts it, swaps the app
/// bundle at its current location (with rollback on failure), and relaunches.
/// No Sparkle dependency; works with the ad-hoc-signed GitHub release builds.
@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()

    enum Phase: Equatable {
        case idle
        case downloading
        case installing
        case relaunching
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// 0…1 while `phase == .downloading`.
    @Published var downloadProgress: Double = 0

    private var progressObservation: NSKeyValueObservation?

    var isBusy: Bool {
        phase == .downloading || phase == .installing || phase == .relaunching
    }

    private init() {}

    /// Kicks off download + install + relaunch. Falls back to opening the URL
    /// in the browser when it isn't a DMG asset.
    func install(from url: URL) {
        guard !isBusy else { return }
        guard url.path.hasSuffix(".dmg") else {
            NSWorkspace.shared.open(url)
            return
        }
        phase = .downloading
        downloadProgress = 0
        Task {
            do {
                let dmg = try await downloadWithProgress(url: url)
                phase = .installing
                let target = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) {
                    try SelfUpdater.performInstall(dmg: dmg, target: target)
                }.value

                phase = .relaunching
                relaunch(target: target)
            } catch {
                phase = .failed(error.localizedDescription)
                ToastCenter.shared.show(
                    "Update failed", detail: error.localizedDescription, style: .error
                )
            }
            progressObservation = nil
        }
    }

    private func downloadWithProgress(url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Portside-update-\(UUID().uuidString).dmg")
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temp,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continuation.resume(throwing: SimpleError(
                        "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                    ))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }
            task.resume()
        }
    }

    // MARK: - Install mechanics (off main thread)

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            throw SimpleError(
                "\((tool as NSString).lastPathComponent) failed: \(message.prefix(200))"
            )
        }
    }

    private nonisolated static func performInstall(dmg: URL, target: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory
            .appendingPathComponent("portside-mount-\(UUID().uuidString)", isDirectory: true)

        try run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-mountpoint", mount.path, "-nobrowse", "-readonly", "-quiet"
        ])
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? fm.removeItem(at: dmg)
        }

        let appName = target.lastPathComponent
        var source = mount.appendingPathComponent(appName)
        if !fm.fileExists(atPath: source.path) {
            let contents = (try? fm.contentsOfDirectory(
                at: mount, includingPropertiesForKeys: nil
            )) ?? []
            guard let anyApp = contents.first(where: { $0.pathExtension == "app" }) else {
                throw SimpleError("No app found inside the update image.")
            }
            source = anyApp
        }

        // Stage a copy outside the (read-only) image before touching the target.
        let stagedDirectory = fm.temporaryDirectory
            .appendingPathComponent("portside-staged-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let staged = stagedDirectory.appendingPathComponent(appName)
        try run("/usr/bin/ditto", [source.path, staged.path])

        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw SimpleError(
                "Cannot write to \(target.deletingLastPathComponent().path). Move Portside to a writable location (like /Applications) and try again."
            )
        }

        // Move the running app aside, then the new version into place; roll back on failure.
        let parked = fm.temporaryDirectory
            .appendingPathComponent("portside-old-\(UUID().uuidString).app")
        try fm.moveItem(at: target, to: parked)
        do {
            do {
                try fm.moveItem(at: staged, to: target)
            } catch {
                // Cross-volume move can fail; fall back to a copy.
                try run("/usr/bin/ditto", [staged.path, target.path])
            }
        } catch {
            try? fm.moveItem(at: parked, to: target)
            throw error
        }
        try? fm.removeItem(at: parked)
        try? fm.removeItem(at: stagedDirectory)
    }

    private func relaunch(target: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(target.path)\""]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
}
