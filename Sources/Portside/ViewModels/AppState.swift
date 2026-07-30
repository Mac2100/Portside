import AppKit
import Foundation
import SwiftUI

/// Sidebar destinations.
enum Page: String, CaseIterable, Identifiable {
    case dashboard, insights, activity, containers, images, volumes, networks, terminal, files, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .insights: return "Insights"
        case .activity: return "Activity"
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .insights: return "lightbulb"
        case .activity: return "list.bullet.rectangle"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .settings: return "gearshape"
        }
    }
}

/// Live per-container metrics derived from the last stats poll.
struct ContainerMetrics: Identifiable, Equatable {
    var id: String
    var name: String
    var cpu: Double
    var memUsed: Int64
    var memPercent: Double
    var netRate: Double
    var blockRate: Double
}

/// One point of host-level history for the live chart.
struct HostSample: Identifiable, Equatable {
    var id: Date { time }
    var time: Date
    var cpu: Double
    var mem: Double
    var rx: Double
    var tx: Double
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = ConfigStore.shared
    let updates = UpdateChecker()

    // MARK: - Navigation

    @Published var page: Page = .dashboard
    @Published var selectedContainerID: String?
    /// Container to preselect when jumping to the terminal or files page.
    @Published var terminalTarget: String?
    @Published var filesTarget: String?
    /// Log panel target (id, name); nil = closed.
    @Published var logTarget: (id: String, name: String)?
    @Published var showCommandPalette = false

    // MARK: - Connection & data

    @Published private(set) var client: DockerClient?
    @Published var connectionError: String?
    @Published private(set) var connected = false

    @Published var systemInfo: SystemInfo?
    @Published var containers: [ContainerSummary] = []
    @Published var images: [ImageSummary] = []
    @Published var volumes: [VolumeSummary] = []
    @Published var networks: [NetworkSummary] = []
    @Published var diskUsage: DiskUsage?
    @Published var inspectCache: [String: ContainerDetails] = [:]

    // MARK: - Metrics

    @Published var metrics: [ContainerMetrics] = []
    @Published var hostCPU: Double = 0
    @Published var hostMemUsed: Int64 = 0
    @Published var hostMemPercent: Double = 0
    @Published var rxRate: Double = 0
    @Published var txRate: Double = 0
    @Published var liveHistory: [HostSample] = []
    @Published var lastRefreshed: Date?
    /// Rolling per-container CPU history for card sparklines.
    @Published var cpuSparklines: [String: [Double]] = [:]

    // MARK: - Activity

    @Published var events: [DockerEvent] = []

    // MARK: - Update checking

    @Published var imageUpdates: [ImageUpdateResult] = []
    @Published var imageUpdatesCheckedAt: Date?
    @Published var checkingImageUpdates = false
    @Published var ghFindings: [GitHubService.WatchFinding] = []
    @Published var ghLatest: [String: GitHubService.RepoStatus] = [:]

    // MARK: - Private state

    private var pollTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var previousRunningIDs: Set<String>?
    private var previousUnhealthy: Set<String> = []
    private var previousLooping: Set<String> = []
    private var previousNet: (rx: Int64, tx: Int64, time: Date)?
    private var previousPerIO: [String: (net: Int64, block: Int64, time: Date)] = [:]
    private var lastInspectFetch = Date.distantPast
    private var lastDiskUsageFetch = Date.distantPast
    private var lastImageCheck = Date.distantPast
    private var lastGHCheck = Date.distantPast
    private var autoUpdating = false
    private var ghDeploying = false
    private var ghAutoTried: [String: String] = [:]
    private var ghNightlyRanOn: String?
    private var refreshGeneration = 0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        connectToActiveHost()
        updates.checkOnLaunchIfEnabled()
        startSchedulers()
    }

    var activeHost: DockerHost? { store.activeHost }

    var refreshInterval: TimeInterval {
        let value = store.config.refreshInterval ?? 10
        return value <= 0 ? 0 : max(value, 3)
    }

    func connectToActiveHost() {
        pollTask?.cancel()
        eventsTask?.cancel()
        client = nil
        connected = false
        connectionError = nil
        resetPerHostState()

        guard let host = store.activeHost else {
            connectionError = "Add your Docker host in Settings to get started."
            page = .settings
            return
        }
        do {
            client = try store.makeClient(for: host)
        } catch {
            connectionError = error.localizedDescription
            page = .settings
            return
        }
        startPolling()
        startEventStream()
        Task { await checkCertificateExpiry() }
    }

    func switchHost(id: String) {
        guard store.config.activeHostId != id else { return }
        store.config.activeHostId = id
        connectToActiveHost()
        if let host = store.activeHost {
            ToastCenter.shared.show("Switched to \(host.name)", style: .info)
        }
    }

    private func resetPerHostState() {
        containers = []
        images = []
        volumes = []
        networks = []
        metrics = []
        inspectCache = [:]
        diskUsage = nil
        events = []
        imageUpdates = []
        liveHistory = []
        cpuSparklines = [:]
        previousRunningIDs = nil
        previousUnhealthy = []
        previousLooping = []
        previousNet = nil
        previousPerIO = [:]
        lastInspectFetch = .distantPast
        lastDiskUsageFetch = .distantPast
        lastImageCheck = .distantPast
        hostCPU = 0
        hostMemUsed = 0
        hostMemPercent = 0
        rxRate = 0
        txRate = 0
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.refreshGeneration == generation else { return }
                await self.refresh()
                let interval = self.refreshInterval
                if interval == 0 { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func restartPolling() {
        startPolling()
    }

    func refresh() async {
        guard let client else { return }
        do {
            let info = try await client.info()
            systemInfo = info
            connected = true
            connectionError = nil

            let list = try await client.containers()
            notifyStateTransitions(previous: containers, current: list, client: client)
            containers = list

            async let imagesResult = client.images()
            async let volumesResult = client.volumes()
            async let networksResult = client.networks()
            if let fetched = try? await imagesResult { images = fetched }
            if let fetched = try? await volumesResult { volumes = fetched }
            if let fetched = try? await networksResult { networks = fetched }

            await collectStats(client: client, info: info)

            let now = Date()
            if now.timeIntervalSince(lastInspectFetch) > 60 {
                lastInspectFetch = now
                await refreshInspectCache(client: client)
            }
            if now.timeIntervalSince(lastDiskUsageFetch) > 60 {
                lastDiskUsageFetch = now
                diskUsage = try? await client.diskUsage()
            }

            lastRefreshed = now
            MenuBarController.shared.update(with: self)
            updateDockBadge()
        } catch {
            connected = false
            connectionError = error.localizedDescription
        }
    }

    private func collectStats(client: DockerClient, info: SystemInfo) async {
        let running = containers.filter(\.isRunning)
        let cpuCount = max(info.NCPU ?? 1, 1)
        let now = Date()

        let samples: [(ContainerSummary, ContainerStatsSample)] = await withTaskGroup(
            of: (ContainerSummary, ContainerStatsSample?).self
        ) { group in
            for container in running {
                group.addTask {
                    (container, try? await client.stats(id: container.Id))
                }
            }
            var collected: [(ContainerSummary, ContainerStatsSample)] = []
            for await (container, sample) in group {
                if let sample, sample.cpu_stats != nil {
                    collected.append((container, sample))
                }
            }
            return collected
        }

        var cpuSum = 0.0
        var memSum: Int64 = 0
        var rxSum: Int64 = 0
        var txSum: Int64 = 0
        var perContainer: [ContainerMetrics] = []

        for (container, sample) in samples {
            let computed = sample.computed(hostCPUs: cpuCount)
            cpuSum += computed.cpuPercent
            memSum += computed.memUsed
            rxSum += computed.rxBytes
            txSum += computed.txBytes

            let totalNet = computed.rxBytes + computed.txBytes
            let totalBlock = computed.blockRead + computed.blockWrite
            var netRate = 0.0
            var blockRate = 0.0
            if let previous = previousPerIO[container.Id] {
                let dt = now.timeIntervalSince(previous.time)
                if dt > 0.5 {
                    netRate = max(0, Double(totalNet - previous.net) / dt)
                    blockRate = max(0, Double(totalBlock - previous.block) / dt)
                }
            }
            previousPerIO[container.Id] = (totalNet, totalBlock, now)

            perContainer.append(ContainerMetrics(
                id: container.Id, name: container.name,
                cpu: computed.cpuPercent, memUsed: computed.memUsed,
                memPercent: computed.memPercent, netRate: netRate, blockRate: blockRate
            ))

            var sparkline = cpuSparklines[container.Id] ?? []
            sparkline.append(computed.cpuPercent)
            if sparkline.count > 40 { sparkline.removeFirst(sparkline.count - 40) }
            cpuSparklines[container.Id] = sparkline
        }
        metrics = perContainer.sorted { $0.cpu > $1.cpu }

        hostCPU = min(cpuSum / Double(cpuCount), 100)
        hostMemUsed = memSum
        let memTotal = info.MemTotal ?? 0
        hostMemPercent = memTotal > 0 ? Double(memSum) / Double(memTotal) * 100 : 0

        if let previous = previousNet {
            let dt = now.timeIntervalSince(previous.time)
            if dt > 0.5 {
                rxRate = max(0, Double(rxSum - previous.rx) / dt)
                txRate = max(0, Double(txSum - previous.tx) / dt)
            }
        }
        previousNet = (rxSum, txSum, now)

        liveHistory.append(HostSample(time: now, cpu: hostCPU, mem: hostMemPercent, rx: rxRate, tx: txRate))
        if liveHistory.count > 120 { liveHistory.removeFirst(liveHistory.count - 120) }
        HistoryStore.shared.append(
            cpu: hostCPU, mem: hostMemPercent, rx: rxRate, tx: txRate,
            host: client.host.host
        )
    }

    private func refreshInspectCache(client: DockerClient) async {
        let running = containers.filter(\.isRunning)
        let details: [(String, ContainerDetails)] = await withTaskGroup(
            of: (String, ContainerDetails?).self
        ) { group in
            for container in running {
                group.addTask { (container.Id, try? await client.inspect(id: container.Id)) }
            }
            var collected: [(String, ContainerDetails)] = []
            for await (id, detail) in group {
                if let detail { collected.append((id, detail)) }
            }
            return collected
        }
        inspectCache = Dictionary(uniqueKeysWithValues: details)
    }

    // MARK: - State-transition notifications

    /// Edge-triggered notifications: previously-running containers that
    /// stopped or crashed (with an immediate crash log snapshot), and newly
    /// unhealthy / newly looping containers.
    private func notifyStateTransitions(
        previous: [ContainerSummary], current: [ContainerSummary], client: DockerClient
    ) {
        let isFirstPoll = previousRunningIDs == nil
        let runningNow = Set(current.filter(\.isRunning).map(\.Id))
        if let previousRunning = previousRunningIDs {
            for id in previousRunning where !runningNow.contains(id) {
                guard let container = current.first(where: { $0.Id == id }) else { continue }
                if let exitCode = container.crashExitCode {
                    Notifier.shared.post(.crashed, "\(container.name) crashed — exit code \(exitCode)")
                    // Grab the logs NOW: if this container gets recreated, they're gone.
                    Task {
                        let text = (try? await client.logs(id: container.Id)) ?? ""
                        CrashLogStore.shared.capture(
                            name: container.name, containerID: container.Id,
                            exitCode: exitCode, status: container.Status ?? "", text: text
                        )
                    }
                } else {
                    Notifier.shared.post(.stopped, "\(container.name) stopped — \(container.Status ?? "")")
                }
            }
        }
        previousRunningIDs = runningNow

        let unhealthyNow = Set(current.filter(\.isUnhealthy).map(\.Id))
        let loopingNow = Set(current.filter(\.isRestarting).map(\.Id))
        let nameOf: (String) -> String = { id in
            current.first { $0.Id == id }?.name ?? String(id.prefix(12))
        }
        if !isFirstPoll {
            for id in unhealthyNow.subtracting(previousUnhealthy) {
                Notifier.shared.post(.unhealthy, "\(nameOf(id)) is unhealthy — its health check is failing")
            }
            for id in loopingNow.subtracting(previousLooping) {
                Notifier.shared.post(.restartLoop, "\(nameOf(id)) is in a restart loop — it keeps dying and Docker keeps restarting it")
            }
        }
        previousUnhealthy = unhealthyNow
        previousLooping = loopingNow
    }

    // MARK: - Events

    private func startEventStream() {
        eventsTask?.cancel()
        guard let client else { return }
        eventsTask = Task { [weak self] in
            // Seed the feed with the last 24h so it isn't empty on first open.
            if let history = try? await client.eventHistory() {
                await MainActor.run {
                    guard let self else { return }
                    var merged = history
                    merged.append(contentsOf: self.events)
                    self.events = Array(merged.sorted { $0.time < $1.time }.suffix(500))
                }
            }
            // Live stream with automatic reconnect — a hiccup must not kill
            // Activity for good.
            while !Task.isCancelled {
                do {
                    for try await event in client.events() {
                        await MainActor.run {
                            guard let self else { return }
                            self.events.append(event)
                            if self.events.count > 500 { self.events.removeFirst(self.events.count - 500) }
                        }
                    }
                } catch { }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - Container actions

    /// Runs a container action with toasts; returns success.
    @discardableResult
    func perform(_ action: DockerClient.ContainerAction, on container: ContainerSummary) async -> Bool {
        guard let client else { return false }
        let verbs = action.confirmVerb
        ToastCenter.shared.show("\(verbs.1) \(displayName(of: container))…", style: .info)
        do {
            try await client.perform(action, id: container.Id)
            ToastCenter.shared.show("\(verbs.2) \(displayName(of: container))")
            scheduleRefresh(after: 1.5)
            return true
        } catch {
            ToastCenter.shared.show("\(verbs.0) failed", detail: error.localizedDescription, style: .error)
            return false
        }
    }

    @discardableResult
    func removeContainer(_ container: ContainerSummary) async -> Bool {
        guard let client else { return false }
        do {
            try await client.remove(id: container.Id, force: true)
            ToastCenter.shared.show("Removed \(displayName(of: container))")
            if selectedContainerID == container.Id { selectedContainerID = nil }
            scheduleRefresh(after: 1)
            return true
        } catch {
            ToastCenter.shared.show("Remove failed", detail: error.localizedDescription, style: .error)
            return false
        }
    }

    /// Bulk action over many containers, filtered to the ones the action makes
    /// sense for. Returns (succeeded, failures).
    func performBulk(_ action: String, ids: [String]) async -> (Int, [String]) {
        guard let client else { return (0, []) }
        var failures: [String] = []
        var succeeded = 0
        for id in ids {
            let name = containers.first { $0.Id == id }?.name ?? String(id.prefix(12))
            do {
                switch action {
                case "start": try await client.perform(.start, id: id)
                case "stop": try await client.perform(.stop, id: id)
                case "restart": try await client.perform(.restart, id: id)
                case "remove": try await client.remove(id: id, force: true)
                default: continue
                }
                succeeded += 1
            } catch {
                failures.append("\(name) (\(error.localizedDescription))")
            }
        }
        scheduleRefresh(after: 1)
        return (succeeded, failures)
    }

    func scheduleRefresh(after seconds: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await refresh()
        }
    }

    func openWebUI(for container: ContainerSummary, port: Int? = nil) {
        guard let host = activeHost,
              let webPort = port ?? container.primaryWebPort,
              let url = URL(string: "http://\(host.host):\(webPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Customisation & grouping

    func customization(of name: String) -> ContainerCustomization {
        store.config.gcCustom?[name] ?? ContainerCustomization()
    }

    func displayName(of container: ContainerSummary) -> String {
        customization(of: container.name).nickname ?? container.name
    }

    /// Manual group wins over the compose project label.
    func groupInfo(of container: ContainerSummary) -> (name: String, isStack: Bool)? {
        if let manual = store.config.gcGroups?[container.name] {
            return (manual, false)
        }
        guard store.config.stackGrouping != false, let project = container.composeProject else {
            return nil
        }
        return (project, true)
    }

    /// Every container in a stack — including stopped ones a filter hides,
    /// because "Stop all" must mean all.
    func stackMembers(project: String) -> [ContainerSummary] {
        containers.filter { $0.composeProject == project }
    }

    // MARK: - Insights

    var attentionItems: [InsightItem] {
        InsightsBuilder.attention(state: self)
    }

    var updateItems: [InsightItem] {
        InsightsBuilder.updates(state: self)
    }

    var housekeepingItems: [InsightItem] {
        InsightsBuilder.housekeeping(state: self)
    }

    /// Only real, durable problems count toward the badge.
    var alertCount: Int {
        guard store.config.alertBadge != false else { return 0 }
        return (attentionItems + updateItems + housekeepingItems)
            .filter { $0.severity == .critical || $0.severity == .warning }
            .count
    }

    private func updateDockBadge() {
        let count = alertCount
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : ""
    }

    // MARK: - Image updates

    func checkImageUpdates(force: Bool, announce: Bool) async {
        guard store.config.updEnabled != false || announce else { return }
        guard let client else { return }
        if !force, let checkedAt = imageUpdatesCheckedAt,
           Date().timeIntervalSince(checkedAt) < 6 * 3600, !imageUpdates.isEmpty {
            return
        }
        checkingImageUpdates = true
        defer { checkingImageUpdates = false }
        do {
            let results = try await ImageUpdateService.check(
                client: client, registries: store.config.registries ?? []
            )
            imageUpdates = results
            imageUpdatesCheckedAt = Date()
            let available = results.filter(\.updateAvailable)
            if announce {
                ToastCenter.shared.show(
                    available.isEmpty
                        ? "Everything is up to date"
                        : "\(available.count) image update\(available.count == 1 ? "" : "s") available",
                    style: available.isEmpty ? .success : .info
                )
            } else {
                // Notify once per image (not on every re-check).
                let notified = Set(store.config.updNotified ?? [])
                let fresh = available.filter { !notified.contains($0.image) }
                if !fresh.isEmpty {
                    Notifier.shared.post(
                        .imageUpdate,
                        "Image update\(fresh.count == 1 ? "" : "s") available: \(fresh.map(\.shortName).joined(separator: ", "))"
                    )
                }
            }
            store.config.updNotified = available.map(\.image)
            await autoApplyUpdates(available)
        } catch {
            if announce {
                ToastCenter.shared.show("Update check failed", detail: error.localizedDescription, style: .error)
            }
        }
    }

    /// Applies the update for one image (all its containers), with toasts.
    func applyImageUpdate(_ update: ImageUpdateResult) async {
        guard let client else { return }
        ToastCenter.shared.show("Pulling \(update.image) — this can take a few minutes…", style: .info)
        var succeeded = 0
        for container in update.containers {
            do {
                try await ImageUpdateService.apply(
                    containerID: container.id, client: client,
                    registries: store.config.registries ?? []
                )
                succeeded += 1
                ToastCenter.shared.show("\(container.name) updated")
            } catch {
                ToastCenter.shared.show("\(container.name) update failed", detail: error.localizedDescription, style: .error)
            }
        }
        if succeeded > 0, let digest = update.remoteDigest {
            var applied = store.config.updAutoApplied ?? [:]
            applied[update.image] = digest
            store.config.updAutoApplied = applied
        }
        await checkImageUpdates(force: true, announce: false)
        await refresh()
    }

    /// Auto-update: redeploys opted-in containers ONLY when the registry has
    /// something new, and never the same digest twice — if the check still
    /// reports an update after applying this exact digest, something is off
    /// (registry quirk); surface it instead of looping forever.
    private func autoApplyUpdates(_ available: [ImageUpdateResult]) async {
        guard !autoUpdating, let client else { return }
        let optIn = store.config.autoUpdate ?? [:]
        let alreadyApplied = store.config.updAutoApplied ?? [:]

        var jobs: [(ImageUpdateResult, ImageUpdateResult.AffectedContainer)] = []
        for update in available {
            if let digest = update.remoteDigest, alreadyApplied[update.image] == digest { continue }
            for container in update.containers where optIn[container.name] == true {
                jobs.append((update, container))
            }
        }
        guard !jobs.isEmpty else { return }

        autoUpdating = true
        defer { autoUpdating = false }

        var appliedDigests = alreadyApplied
        var applied = 0
        for (update, container) in jobs {
            ToastCenter.shared.show("Auto-updating \(container.name) (\(update.shortName))…", style: .info)
            do {
                try await ImageUpdateService.apply(
                    containerID: container.id, client: client,
                    registries: store.config.registries ?? []
                )
                applied += 1
                if let digest = update.remoteDigest { appliedDigests[update.image] = digest }
                ToastCenter.shared.show("\(container.name) auto-updated")
                Notifier.shared.post(.imageUpdate, "\(container.name) was updated to the latest \(update.shortName) image")
            } catch {
                ToastCenter.shared.show("\(container.name) auto-update failed", detail: error.localizedDescription, style: .error)
                Notifier.shared.post(.imageUpdate, "Auto-update of \(container.name) failed — the old container was restored")
            }
        }
        if applied > 0 {
            store.config.updAutoApplied = appliedDigests
            await checkImageUpdates(force: true, announce: false)
            await refresh()
        }
    }

    // MARK: - GitHub watching

    func ghMode(for repo: String) -> String {
        store.config.ghWatchCfg?[repo]?.mode ?? "notify"
    }

    func ghConfig(for repo: String) -> GitHubWatchConfig {
        store.config.ghWatchCfg?[repo] ?? GitHubWatchConfig()
    }

    func setGHConfig(for repo: String, _ config: GitHubWatchConfig) {
        var all = store.config.ghWatchCfg ?? [:]
        all[repo] = config
        store.config.ghWatchCfg = all
    }

    var ghDeployTime: String {
        store.config.ghDeployTime ?? "03:00"
    }

    /// Git Deploy is the single source of truth: any repo configured on a
    /// container is watched automatically. Repos explicitly removed stay removed.
    func syncGHWatchFromGitDeploy() {
        let ignored = Set(store.config.ghIgnored ?? [])
        var watch = store.config.ghWatch ?? []
        var configs = store.config.ghWatchCfg ?? [:]
        var changed = false
        for (containerName, deploy) in store.config.gitDeploys ?? [:] {
            guard let repo = GitHubService.repoFromURL(deploy.repoUrl), !ignored.contains(repo) else { continue }
            if !watch.contains(repo) {
                watch.append(repo)
                changed = true
            }
            if configs[repo]?.container == nil {
                var config = configs[repo] ?? GitHubWatchConfig()
                config.container = containerName
                configs[repo] = config
                changed = true
            }
        }
        if changed {
            store.config.ghWatch = watch
            store.config.ghWatchCfg = configs
        }
    }

    func checkGitHubWatch(announce: Bool) async {
        if store.config.ghEnabled == false && !announce { return }
        syncGHWatchFromGitDeploy()
        let watch = store.config.ghWatch ?? []
        guard !watch.isEmpty else {
            ghFindings = []
            return
        }
        let previous = Set(ghFindings.map(\.id))
        var found: [GitHubService.WatchFinding] = []
        for repo in watch {
            do {
                let status = try await GitHubService.latest(repo: repo)
                ghLatest[status.repo] = status
                let seen = store.config.ghSeen?[status.repo] ?? GitHubSeen()
                let markSeen = GitHubSeen(
                    tag: status.tag.isEmpty ? seen.tag : status.tag,
                    sha: status.commit?.sha ?? seen.sha
                )
                if !status.tag.isEmpty, let seenTag = seen.tag, !seenTag.isEmpty, seenTag != status.tag {
                    found.append(GitHubService.WatchFinding(
                        repo: status.repo, kind: .release, what: status.tag,
                        title: "\(status.tag)\(status.name.isEmpty || status.name == status.tag ? "" : " · \(status.name)")",
                        url: status.url, markSeen: markSeen
                    ))
                } else if let commit = status.commit, let seenSha = seen.sha, !seenSha.isEmpty, seenSha != commit.sha {
                    found.append(GitHubService.WatchFinding(
                        repo: status.repo, kind: .commit, what: commit.shortSha,
                        title: "latest: \(commit.message.prefix(70))",
                        url: commit.url, markSeen: markSeen
                    ))
                } else if (!status.tag.isEmpty && (seen.tag ?? "").isEmpty)
                            || (status.commit != nil && (seen.sha ?? "").isEmpty) {
                    // First sighting of this repo: baseline it silently.
                    var all = store.config.ghSeen ?? [:]
                    all[status.repo] = markSeen
                    store.config.ghSeen = all
                }
            } catch {
                if announce {
                    ToastCenter.shared.show(repo, detail: error.localizedDescription, style: .error)
                }
            }
        }
        ghFindings = found

        let fresh = found.filter { !previous.contains($0.id) }
        if !fresh.isEmpty {
            let lines = fresh.map { finding in
                let base = finding.kind == .commit
                    ? "New commits on \(finding.repo) (\(finding.what))"
                    : "New release: \(finding.repo) \(finding.what)"
                let config = ghConfig(for: finding.repo)
                guard config.container != nil else { return base }
                switch ghMode(for: finding.repo) {
                case "scheduled": return "\(base) — deploys tonight at \(ghDeployTime)"
                case "auto": return "\(base) — deploying now"
                default: return base
                }
            }
            Notifier.shared.post(.ghRelease, lines.joined(separator: "\n"))
        }
        await ghAutoDeploy(found)
    }

    func markGHSeen(_ repo: String) {
        guard let finding = ghFindings.first(where: { $0.repo == repo }) else { return }
        var all = store.config.ghSeen ?? [:]
        all[repo] = finding.markSeen
        store.config.ghSeen = all
        ghFindings.removeAll { $0.repo == repo }
    }

    /// Deploys the linked container for a watched repo (Git Deploy: pull latest
    /// into the bind-mounted folder, then restart).
    @discardableResult
    func ghDeploy(repo: String) async -> Bool {
        guard let client else { return false }
        let config = ghConfig(for: repo)
        guard let containerName = config.container,
              let deploy = store.config.gitDeploys?[containerName] else {
            ToastCenter.shared.show(
                "Link this repo to a container first",
                detail: "Settings → GitHub Watch", style: .error
            )
            return false
        }
        let container = containers.first { $0.name == containerName }
        ToastCenter.shared.show("Deploying \(repo) → \(containerName)…", style: .info)
        do {
            let result = try await GitHubService.deploy(
                client: client, deploy: deploy, ref: nil,
                restartContainerID: container?.Id,
                registries: store.config.registries ?? []
            )
            if let restartError = result.restartError {
                ToastCenter.shared.show("Deployed with a warning", detail: restartError, style: .error)
            } else {
                ToastCenter.shared.show(
                    "\(containerName) deployed",
                    detail: "\(result.deployed)\(result.restarted ? " · restarted" : "")"
                )
            }
            Notifier.shared.post(.ghRelease, "\(containerName) deployed from \(repo)")
            markGHSeen(repo)
            scheduleRefresh(after: 1.5)
            return true
        } catch {
            ToastCenter.shared.show("Deploy failed", detail: error.localizedDescription, style: .error)
            Notifier.shared.post(.ghRelease, "Deploy of \(containerName) failed — open Git Deploy for details")
            return false
        }
    }

    /// Auto mode: pushes get deployed hands-free, immediately. Each new
    /// commit/release is attempted ONCE — failures wait for input (or the next
    /// push) instead of retrying every check.
    private func ghAutoDeploy(_ findings: [GitHubService.WatchFinding]) async {
        guard !ghDeploying else { return }
        let jobs = findings.filter {
            ghMode(for: $0.repo) == "auto"
                && ghConfig(for: $0.repo).container != nil
                && ghAutoTried[$0.repo] != $0.what
        }
        guard !jobs.isEmpty else { return }
        ghDeploying = true
        defer { ghDeploying = false }
        for finding in jobs {
            ghAutoTried[finding.repo] = finding.what
            ToastCenter.shared.show("Auto-deploying \(finding.repo) (\(finding.what))…", style: .info)
            await ghDeploy(repo: finding.repo)
        }
    }

    /// Nightly mode: queued pushes deploy inside a 10-minute window at the
    /// configured time (covers sleep/wake jitter); at most once per day.
    private func ghScheduledTick() async {
        guard store.config.ghEnabled != false, !ghDeploying else { return }
        let queued = ghFindings.filter {
            ghMode(for: $0.repo) == "scheduled"
                && ghConfig(for: $0.repo).container != nil
                && ghAutoTried[$0.repo] != $0.what
        }
        guard !queued.isEmpty else { return }

        let parts = ghDeployTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let calendar = Calendar.current
        let now = Date()
        guard let target = calendar.date(
            bySettingHour: parts[0], minute: parts[1], second: 0, of: now
        ) else { return }
        let todayKey = now.formatted(date: .complete, time: .omitted)
        guard ghNightlyRanOn != todayKey else { return }
        let sinceTarget = now.timeIntervalSince(target)
        guard sinceTarget >= 0 && sinceTarget <= 600 else { return }

        ghNightlyRanOn = todayKey
        ghDeploying = true
        defer { ghDeploying = false }
        ToastCenter.shared.show("Nightly deploy window — deploying \(queued.count) app\(queued.count == 1 ? "" : "s")…", style: .info)
        for finding in queued {
            ghAutoTried[finding.repo] = finding.what
            await ghDeploy(repo: finding.repo)
        }
    }

    // MARK: - Schedulers

    /// One 30-second heartbeat drives the image-update clock, the GitHub
    /// clock, and the nightly deploy window.
    private func startSchedulers() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            // Initial checks shortly after launch.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.checkImageUpdates(force: false, announce: false)
            await self?.checkGitHubWatch(announce: false)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                let now = Date()

                let imageInterval = (self.store.config.updInterval ?? 3_600_000) / 1000
                if imageInterval > 0, now.timeIntervalSince(self.lastImageCheck) >= imageInterval {
                    self.lastImageCheck = now
                    await self.checkImageUpdates(force: true, announce: false)
                }

                let ghInterval = (self.store.config.ghInterval ?? 900_000) / 1000
                if ghInterval > 0, now.timeIntervalSince(self.lastGHCheck) >= ghInterval {
                    self.lastGHCheck = now
                    await self.checkGitHubWatch(announce: false)
                }

                await self.ghScheduledTick()
            }
        }
    }

    // MARK: - Certificate expiry

    /// When the host's Docker certs expire, Portside can't talk to it at all —
    /// it just goes quiet. Warn well before that happens, at most once a day.
    private func checkCertificateExpiry() async {
        let warnDays = 21
        let today = Date().formatted(date: .complete, time: .omitted)
        guard store.config.certNotifiedOn != today else { return }

        let directory = ConfigStore.certsDirectory(forHostID: store.activeHost?.id)
        for file in ["ca.pem", "cert.pem"] {
            guard let summary = TLSIdentity.summary(ofPEMFile: directory.appendingPathComponent(file)),
                  let expiry = summary.notValidAfter else { continue }
            let days = Int(expiry.timeIntervalSinceNow / 86400)
            if summary.isExpired {
                Notifier.shared.post(.certExpiring, "Your Docker certificate \(file) has EXPIRED — Portside can't reach the host until you re-import it")
                store.config.certNotifiedOn = today
                return
            } else if days <= warnDays {
                Notifier.shared.post(.certExpiring, "Your Docker certificate \(file) expires in \(days) day\(days == 1 ? "" : "s") — re-import it before it does")
                store.config.certNotifiedOn = today
                return
            }
        }
    }
}
