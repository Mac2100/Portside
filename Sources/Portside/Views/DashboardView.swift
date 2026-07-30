import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var chartRange: ChartRange = .live

    enum ChartRange: String, CaseIterable {
        case live, day, week

        var label: String {
            switch self {
            case .live: return "Live"
            case .day: return "24h"
            case .week: return "7d"
            }
        }

        var window: TimeInterval? {
            switch self {
            case .live: return nil
            case .day: return 86400
            case .week: return 7 * 86400
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = appState.connectionError {
                    ConnectionErrorBanner(message: error)
                }
                metricsRow
                chartsCard
                topConsumers
                hostInfoStrip
            }
            .padding(16)
        }
        .navigationSubtitle(appState.connected ? "Connected" : "Disconnected")
    }

    // MARK: - Metric cards

    private var running: [ContainerSummary] { appState.containers.filter(\.isRunning) }

    /// Jumps to the container list pre-sorted by the tapped metric.
    private func openContainers(sortedBy key: String) {
        UserDefaults.standard.set(key, forKey: "containerSortKey")
        UserDefaults.standard.set(false, forKey: "containerSortAscending")
        appState.page = .containers
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            MetricRingCard(
                title: "CPU",
                value: String(format: "%.1f%%", appState.hostCPU),
                subtitle: "\(appState.systemInfo?.NCPU ?? 0) cores · \(running.count) active",
                percent: appState.hostCPU,
                colorByLoad: true,
                action: { openContainers(sortedBy: "cpu") }
            )
            MetricRingCard(
                title: "Memory",
                value: Format.bytes(appState.hostMemUsed),
                subtitle: "of \(Format.bytes(appState.systemInfo?.MemTotal ?? 0))",
                percent: appState.hostMemPercent,
                colorByLoad: true,
                action: { openContainers(sortedBy: "memory") }
            )
            MetricRingCard(
                title: "Containers",
                value: "\(running.count) of \(appState.containers.count)",
                subtitle: "\(appState.containers.count - running.count) stopped",
                percent: appState.containers.isEmpty
                    ? 0 : Double(running.count) / Double(appState.containers.count) * 100,
                ringLabel: "\(running.count)/\(appState.containers.count)",
                colorByLoad: false,
                action: { openContainers(sortedBy: "state") }
            )
            MetricPlainCard(
                title: "Network",
                value: "↓\(Format.rate(appState.rxRate))",
                secondValue: "↑\(Format.rate(appState.txRate))",
                subtitle: "container traffic"
            )
        }
    }

    // MARK: - History charts

    private struct ChartPoint: Identifiable {
        let id = UUID()
        var time: Date
        var value: Double
        var series: String
    }

    private func historySeries() -> (cpu: [ChartPoint], mem: [ChartPoint], net: [ChartPoint]) {
        if let window = chartRange.window {
            let series = HistoryStore.shared.series(
                window: window, host: appState.activeHost?.host ?? ""
            )
            let cpu = zip(series.times, series.cpu).map { ChartPoint(time: $0, value: $1, series: "CPU") }
            let mem = zip(series.times, series.mem).map { ChartPoint(time: $0, value: $1, series: "Memory") }
            var net = zip(series.times, series.rx).map { ChartPoint(time: $0, value: $1, series: "Down") }
            net.append(contentsOf: zip(series.times, series.tx).map { ChartPoint(time: $0, value: $1, series: "Up") })
            return (cpu, mem, net)
        }
        let history = appState.liveHistory
        let cpu = history.map { ChartPoint(time: $0.time, value: $0.cpu, series: "CPU") }
        let mem = history.map { ChartPoint(time: $0.time, value: $0.mem, series: "Memory") }
        var net = history.map { ChartPoint(time: $0.time, value: $0.rx, series: "Down") }
        net.append(contentsOf: history.map { ChartPoint(time: $0.time, value: $0.tx, series: "Up") })
        return (cpu, mem, net)
    }

    private var chartsCard: some View {
        let series = historySeries()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                CapsuleSegments(
                    options: ChartRange.allCases.map { ($0, $0.label, nil) },
                    selection: $chartRange
                )
            }
            HStack(alignment: .top, spacing: 16) {
                chart(
                    title: "CPU",
                    now: String(format: "%.1f%%", appState.hostCPU),
                    points: series.cpu,
                    percentDomain: true,
                    colors: ["CPU": theme.primary]
                )
                chart(
                    title: "Memory",
                    now: String(format: "%.1f%% (%@)", appState.hostMemPercent, Format.bytes(appState.hostMemUsed)),
                    points: series.mem,
                    percentDomain: true,
                    colors: ["Memory": theme.secondary]
                )
                chart(
                    title: "Network",
                    now: "↓\(Format.rate(appState.rxRate)) ↑\(Format.rate(appState.txRate))",
                    points: series.net,
                    percentDomain: false,
                    colors: ["Down": .green, "Up": .orange]
                )
            }
        }
        .glassCard()
    }

    private func chart(
        title: String, now: String, points: [ChartPoint],
        percentDomain: Bool, colors: [String: Color]
    ) -> some View {
        HistoryChartCard(
            title: title, now: now, points: points,
            percentDomain: percentDomain, colors: colors
        )
    }

    /// One history chart with scrubbing: hover or drag shows the value at
    /// that point in time in the header, with a rule mark on the plot.
    private struct HistoryChartCard: View {
        var title: String
        var now: String
        var points: [ChartPoint]
        var percentDomain: Bool
        var colors: [String: Color]

        @State private var selectedTime: Date?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(headerValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(selectedTime == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
                }
                chartBody
                    .frame(height: 120)
            }
            .frame(maxWidth: .infinity)
        }

        /// Values of every series at the scrubbed time, or the live reading.
        private var headerValue: String {
            guard let selectedTime else { return now }
            let bySeries = Dictionary(grouping: points, by: \.series)
            let parts: [String] = bySeries.keys.sorted().compactMap { series in
                guard let nearest = bySeries[series]?.min(by: {
                    abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime))
                }) else { return nil }
                let value = percentDomain
                    ? String(format: "%.1f%%", nearest.value)
                    : Format.rate(nearest.value)
                return bySeries.count > 1 ? "\(series == "Down" ? "↓" : "↑")\(value)" : value
            }
            let time = selectedTime.formatted(date: .omitted, time: .shortened)
            return "\(time) · \(parts.joined(separator: " "))"
        }

        @ViewBuilder
        private var chartBody: some View {
            let chart = Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Value", point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(colors[point.series] ?? .gray)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Value", point.value),
                        series: .value("Series", point.series),
                        stacking: .unstacked
                    )
                    .foregroundStyle(colors[point.series] ?? .gray)
                    .interpolationMethod(.monotone)
                    .opacity(0.14)
                }
                if let selectedTime {
                    RuleMark(x: .value("Time", selectedTime))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXSelection(value: $selectedTime)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(percentDomain ? "\(Int(number))%" : Format.rate(number))
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.system(size: 8))
                        }
                    }
                }
            }

            if percentDomain {
                chart.chartYScale(domain: 0...100)
            } else {
                chart
            }
        }
    }

    // MARK: - Top consumers

    private var topConsumers: some View {
        HStack(alignment: .top, spacing: 12) {
            TopListCard(
                title: "Top CPU",
                rows: Array(appState.metrics.sorted { $0.cpu > $1.cpu }.prefix(5)),
                maxValue: max(appState.metrics.map(\.cpu).max() ?? 1, 10),
                value: \.cpu,
                format: { String(format: "%.1f%%", $0.cpu) },
                hotAbove: 80
            )
            TopListCard(
                title: "Top Memory",
                rows: Array(appState.metrics.sorted { $0.memUsed > $1.memUsed }.prefix(5)),
                maxValue: Double(appState.metrics.map(\.memUsed).max() ?? 1),
                value: { Double($0.memUsed) },
                format: { Format.bytes($0.memUsed) },
                hotAbove: .infinity
            )
        }
    }

    // MARK: - Host info

    private var hostInfoStrip: some View {
        HStack(spacing: 20) {
            infoItem("Docker", appState.systemInfo?.ServerVersion ?? "—")
            infoItem("Host", appState.systemInfo?.Name ?? "—")
            infoItem("OS", appState.systemInfo?.OperatingSystem ?? "—")
            infoItem("CPUs", appState.systemInfo?.NCPU.map(String.init) ?? "—")
            infoItem("Memory", (appState.systemInfo?.MemTotal).map { Format.bytes($0) } ?? "—")
            Spacer()
        }
        .glassCard(padding: 12)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
    }
}

// MARK: - Building blocks

struct MetricRingCard: View {
    var title: String
    var value: String
    var subtitle: String
    var percent: Double
    var ringLabel: String?
    var colorByLoad: Bool
    var action: (() -> Void)?

    @State private var hovering = false

    init(
        title: String, value: String, subtitle: String, percent: Double,
        ringLabel: String? = nil, colorByLoad: Bool, action: (() -> Void)? = nil
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.percent = percent
        self.ringLabel = ringLabel
        self.colorByLoad = colorByLoad
        self.action = action
    }

    private var ringColor: Color {
        guard colorByLoad else { return .green }
        if percent < 60 { return .green }
        if percent < 80 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(min(percent, 100), 0) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: percent)
                Text(ringLabel ?? "\(Int(percent))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.3)
            }
        }
        .glassCard(padding: 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .help(action != nil ? "Open the container list sorted by \(title.lowercased())" : "")
    }
}

struct MetricPlainCard: View {
    var title: String
    var value: String
    var secondValue: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
            Text(secondValue)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}

struct TopListCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var title: String
    var rows: [ContainerMetrics]
    var maxValue: Double
    var value: (ContainerMetrics) -> Double
    var format: (ContainerMetrics) -> String
    var hotAbove: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if rows.isEmpty {
                Text("No running containers")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
            ForEach(rows) { row in
                Button {
                    appState.selectedContainerID = row.id
                    appState.page = .containers
                } label: {
                    HStack(spacing: 10) {
                        Text(row.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule()
                                    .fill(value(row) > hotAbove ? Color.red : theme.primary)
                                    .frame(width: max(3, geo.size.width * min(value(row) / max(maxValue, 0.01), 1)))
                            }
                        }
                        .frame(height: 6)
                        Text(format(row))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 64, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct ConnectionErrorBanner: View {
    @EnvironmentObject private var appState: AppState
    var message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't reach the Docker host")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings") { appState.page = .settings }
            Button("Retry") { Task { await appState.refresh() } }
        }
        .glassCard(padding: 12)
    }
}
