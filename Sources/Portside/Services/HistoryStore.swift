import Foundation

/// Host-level metrics history, persisted so the 24h/7d dashboard charts
/// survive relaunches. Samples older than seven days are dropped; writes are
/// batched to once a minute.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    struct Sample: Codable {
        var t: Double        // ms since epoch (kept for V2 file compatibility)
        var cpu: Double
        var mem: Double
        var rx: Double
        var tx: Double
        var host: String?
    }

    struct Series {
        var times: [Date] = []
        var cpu: [Double] = []
        var mem: [Double] = []
        var rx: [Double] = []
        var tx: [Double] = []
    }

    private var samples: [Sample] = []
    private var dirty = false
    private var flushTask: Task<Void, Never>?

    private var fileURL: URL {
        ConfigStore.supportDirectory.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = decoded
        }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.flush()
            }
        }
    }

    func append(cpu: Double, mem: Double, rx: Double, tx: Double, host: String) {
        samples.append(Sample(
            t: Date().timeIntervalSince1970 * 1000,
            cpu: cpu, mem: mem, rx: rx, tx: tx, host: host
        ))
        let cutoff = (Date().timeIntervalSince1970 - 7 * 86400) * 1000
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
        }
        dirty = true
    }

    /// Averages samples for `window` into `buckets` buckets, host-filtered.
    func series(window: TimeInterval, buckets: Int = 120, host: String) -> Series {
        let fromMS = (Date().timeIntervalSince1970 - window) * 1000
        let points = samples.filter { $0.t >= fromMS && ($0.host == nil || $0.host == host) }
        var series = Series()
        guard !points.isEmpty else { return series }

        let bucketSize = window * 1000 / Double(buckets)
        var index = 0
        for bucket in 0..<buckets {
            let end = fromMS + Double(bucket + 1) * bucketSize
            var count = 0
            var cpu = 0.0, mem = 0.0, rx = 0.0, tx = 0.0
            while index < points.count && points[index].t < end {
                cpu += points[index].cpu
                mem += points[index].mem
                rx += points[index].rx
                tx += points[index].tx
                count += 1
                index += 1
            }
            if count > 0 {
                let n = Double(count)
                series.times.append(Date(timeIntervalSince1970: (end - bucketSize / 2) / 1000))
                series.cpu.append(cpu / n)
                series.mem.append(mem / n)
                series.rx.append(rx / n)
                series.tx.append(tx / n)
            }
        }
        return series
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
