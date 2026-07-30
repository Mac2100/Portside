import Foundation
import SwiftUI

/// One row on the Insights page: a stable, durable condition with actions —
/// a broken container, an available update, or reclaimable junk. Live metrics
/// (CPU spikes, network hogs) belong on the Dashboard; they flapped in and out
/// of this list and were pure noise.
struct InsightItem: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case critical, warning, info

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var color: Color {
            switch self {
            case .critical: return .red
            case .warning: return .orange
            case .info: return .blue
            }
        }
    }

    enum Action: Equatable {
        case viewLogs(containerID: String, name: String)
        case viewCrashLog(file: String)
        case startContainer(id: String)
        case applyImageUpdate(image: String)
        case installAppUpdate
        case ghDeploy(repo: String)
        case ghView(url: String)
        case ghMarkSeen(repo: String)
        case viewDanglingImages
        case viewUnusedVolumes
        case openImageCleanup
        case pruneStoppedContainers
        case pruneVolumes
    }

    var key: String
    var severity: Severity
    var symbol: String
    var title: String
    var subtitle: String
    var value: String = ""
    /// Container chips shown under the subtitle (label, container id).
    var chips: [(String, String?)] = []
    var actions: [(label: String, action: Action, destructive: Bool)] = []
    /// Clicking the row opens this container's detail.
    var containerID: String?

    var id: String { key }

    static func == (lhs: InsightItem, rhs: InsightItem) -> Bool {
        lhs.key == rhs.key && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.value == rhs.value && lhs.severity == rhs.severity
    }
}

@MainActor
enum InsightsBuilder {
    // MARK: - Needs attention

    static func attention(state: AppState) -> [InsightItem] {
        var items: [InsightItem] = []

        for container in state.containers where container.isUnhealthy {
            items.append(InsightItem(
                key: "unhealthy-\(container.Id)",
                severity: .critical,
                symbol: "heart.slash",
                title: "Unhealthy — \(container.name)",
                subtitle: "Its own HEALTHCHECK is failing · \(container.Status ?? "")",
                actions: [("Logs", .viewLogs(containerID: container.Id, name: container.name), false)],
                containerID: container.Id
            ))
        }

        for container in state.containers where container.isRestarting {
            items.append(InsightItem(
                key: "restarting-\(container.Id)",
                severity: .critical,
                symbol: "arrow.triangle.2.circlepath",
                title: "Restart loop — \(container.name)",
                subtitle: "\(container.Status ?? "") · it keeps dying and Docker keeps bringing it back",
                actions: [("Logs", .viewLogs(containerID: container.Id, name: container.name), false)],
                containerID: container.Id
            ))
        }

        for container in state.containers {
            guard let exitCode = container.crashExitCode else { continue }
            let snapshot = CrashLogStore.shared.entry(forContainerName: container.name)
            var subtitle = "\(container.Status ?? "") · exited with a non-zero code"
            if let snapshot {
                subtitle += " · logs captured \(snapshot.time.formatted(date: .omitted, time: .shortened))"
            }
            var actions: [(String, InsightItem.Action, Bool)] = []
            if let snapshot {
                actions.append(("Crash log", .viewCrashLog(file: snapshot.file), false))
            }
            actions.append(("Logs", .viewLogs(containerID: container.Id, name: container.name), false))
            actions.append(("Start", .startContainer(id: container.Id), false))
            items.append(InsightItem(
                key: "crashed-\(container.Id)",
                severity: .warning,
                symbol: "burst",
                title: "Crashed — \(container.name)",
                subtitle: subtitle,
                value: "exit \(exitCode)",
                actions: actions,
                containerID: container.Id
            ))
        }

        // Restart counts — only worth flagging when it's actually flapping (≥3),
        // and only for containers not already listed above.
        for (id, details) in state.inspectCache {
            let count = details.RestartCount ?? 0
            guard count >= 3,
                  let container = state.containers.first(where: { $0.Id == id }),
                  !container.isRestarting else { continue }
            items.append(InsightItem(
                key: "restarts-\(id)",
                severity: .warning,
                symbol: "repeat",
                title: "\(container.name) has restarted \(count)×",
                subtitle: "Docker has had to bring it back repeatedly — check its logs",
                actions: [("Logs", .viewLogs(containerID: id, name: container.name), false)],
                containerID: id
            ))
        }

        return items.sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
    }

    // MARK: - Updates

    static func updates(state: AppState) -> [InsightItem] {
        var items: [InsightItem] = []

        if case .updateAvailable(let version, _) = state.updates.status {
            items.append(InsightItem(
                key: "app-update",
                severity: .info,
                symbol: "gift",
                title: "Portside \(version) is out",
                subtitle: "You're on \(AppVersion.current)",
                actions: [("Install update", .installAppUpdate, false)]
            ))
        }

        let applied = state.store.config.updAutoApplied ?? [:]
        for update in state.imageUpdates where update.updateAvailable {
            let stuck = update.remoteDigest != nil && applied[update.image] == update.remoteDigest
            items.append(InsightItem(
                key: "img-\(update.image)",
                severity: .warning,
                symbol: stuck ? "exclamationmark.triangle" : "square.and.arrow.down",
                title: stuck
                    ? "\(update.shortName) — updated, but the registry still reports a difference"
                    : "Image update — \(update.shortName)",
                subtitle: stuck
                    ? "\(update.image) · Auto-update already pulled this version; the digest still doesn't match, so auto-update is paused for it. Update manually to retry, or ignore if the container works."
                    : "\(update.image) · Update pulls the new image and recreates these containers (config kept, auto-rollback on failure):",
                chips: update.containers.map { ($0.name, $0.id) },
                actions: [("Update", .applyImageUpdate(image: update.image), false)]
            ))
        }

        for finding in state.ghFindings {
            let config = state.ghConfig(for: finding.repo)
            let mode = state.ghMode(for: finding.repo)
            var subtitle = finding.title
            if let container = config.container {
                switch mode {
                case "scheduled":
                    subtitle += " · queued — \(container) deploys at \(state.ghDeployTime) (or Deploy now)"
                default:
                    subtitle += " · Deploy pulls it onto the host and restarts \(container)"
                }
            }
            var chips: [(String, String?)] = []
            if let container = config.container {
                chips.append((container, state.containers.first { $0.name == container }?.Id))
            }
            var actions: [(String, InsightItem.Action, Bool)] = []
            if config.container != nil {
                actions.append(("Deploy", .ghDeploy(repo: finding.repo), false))
            }
            actions.append(("View", .ghView(url: finding.url), false))
            actions.append(("Seen", .ghMarkSeen(repo: finding.repo), false))
            items.append(InsightItem(
                key: "gh-\(finding.repo)",
                severity: .warning,
                symbol: mode == "scheduled" ? "moon" : "arrow.triangle.branch",
                title: "\(finding.kind == .commit ? "New commits" : "New release") — \(finding.repo)",
                subtitle: subtitle,
                chips: chips,
                actions: actions
            ))
        }

        return items
    }

    // MARK: - Housekeeping

    static func housekeeping(state: AppState) -> [InsightItem] {
        var items: [InsightItem] = []

        let exited = state.containers.filter(\.isExited)
        if !exited.isEmpty {
            items.append(InsightItem(
                key: "stopped",
                severity: .info,
                symbol: "moon.zzz",
                title: "\(exited.count) stopped container\(exited.count == 1 ? "" : "s")",
                subtitle: "Click a name to open it · \"Remove all\" deletes every stopped container (data in volumes and bind mounts is kept)",
                chips: exited.map { ($0.name, $0.Id) },
                actions: [("Remove all", .pruneStoppedContainers, true)]
            ))
        }

        if let usage = state.diskUsage {
            let dangling = (usage.Images ?? []).filter { image in
                image.tags.isEmpty || image.RepoTags?.first == "<none>:<none>"
            }
            if !dangling.isEmpty {
                let reclaimable = dangling.reduce(Int64(0)) { $0 + ($1.Size ?? 0) }
                items.append(InsightItem(
                    key: "dangling",
                    severity: .warning,
                    symbol: "paintbrush",
                    title: "\(dangling.count) dangling image\(dangling.count == 1 ? "" : "s") — ~\(Format.bytes(reclaimable)) reclaimable",
                    subtitle: "Untagged leftover layers from old image versions. Nothing uses them — safe to prune.",
                    actions: [
                        ("View", .viewDanglingImages, false),
                        ("Clean up…", .openImageCleanup, true)
                    ]
                ))
            }

            let unusedVolumes = (usage.Volumes ?? []).filter { $0.UsageData?.RefCount == 0 }
            if !unusedVolumes.isEmpty {
                let size = unusedVolumes.reduce(Int64(0)) { $0 + max($1.UsageData?.Size ?? 0, 0) }
                var subtitle = "Not attached to any container"
                if size > 0 { subtitle += " · ~\(Format.bytes(size))" }
                subtitle += " · pruning deletes their data"
                items.append(InsightItem(
                    key: "unused-volumes",
                    severity: .info,
                    symbol: "externaldrive.badge.xmark",
                    title: "\(unusedVolumes.count) unused volume\(unusedVolumes.count == 1 ? "" : "s")",
                    subtitle: subtitle,
                    actions: [
                        ("View", .viewUnusedVolumes, false),
                        ("Prune", .pruneVolumes, true)
                    ]
                ))
            }
        }

        return items
    }

    /// Storage summary shown next to the Housekeeping heading.
    static func storageSummary(state: AppState) -> String {
        guard let usage = state.diskUsage else { return "" }
        let layers = usage.LayersSize ?? 0
        let volumes = (usage.Volumes ?? []).reduce(Int64(0)) { $0 + max($1.UsageData?.Size ?? 0, 0) }
        return "\(Format.bytes(layers)) images · \(Format.bytes(volumes)) volumes · \((usage.Containers ?? []).count) containers"
    }
}
