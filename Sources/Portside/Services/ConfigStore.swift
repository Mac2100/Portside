import Foundation
import Security

/// Container customisation saved locally (never sent to the host).
struct ContainerCustomization: Codable, Equatable {
    var nickname: String?
    var tint: String?
    var icon: String?
}

/// Per-repo GitHub watch configuration.
struct GitHubWatchConfig: Codable, Equatable {
    var container: String?
    /// "notify" (alert + button), "auto" (deploy immediately), "scheduled" (nightly window).
    var mode: String?
}

struct GitHubSeen: Codable, Equatable {
    var tag: String?
    var sha: String?
}

/// Git Deploy configuration for one container.
struct GitDeployConfig: Codable, Equatable {
    var repoUrl: String = ""
    var branch: String = "main"
    var folder: String = ""
}

/// The persisted application configuration. Stored as JSON at
/// `~/Library/Application Support/Portside/config.json` — the same file the
/// previous Electron version used, so hosts, groups, customisations and
/// notification rules carry over on first launch of V3.
struct AppConfig: Codable {
    var hosts: [DockerHost] = []
    var activeHostId: String?
    var tlsInsecure: Bool = false

    var theme: String?                       // "system" | "light" | "dark"
    var accent: String?                      // V3 accent theme id
    var refreshInterval: Double?             // seconds between polls (V2 stored ms)
    var trayEnabled: Bool?
    var alertBadge: Bool?
    var stackGrouping: Bool?
    var containerView: String?               // "grid" | "list"

    var notifyRules: [String: Bool]?
    var gcGroups: [String: String]?          // container name → manual group
    var gcCustom: [String: ContainerCustomization]?
    var collapsedGroups: [String: Bool]?

    var autoUpdate: [String: Bool]?          // container name → auto-update opt-in
    var updEnabled: Bool?
    var updInterval: Double?                 // ms between image update checks (0 = off)
    var updNotified: [String]?               // images already notified about
    var updAutoApplied: [String: String]?    // image → last auto-applied digest

    var ghEnabled: Bool?
    var ghInterval: Double?                  // ms between GitHub checks (0 = off)
    var ghWatch: [String]?
    var ghIgnored: [String]?
    var ghSeen: [String: GitHubSeen]?
    var ghWatchCfg: [String: GitHubWatchConfig]?
    var ghDeployTime: String?                // "HH:mm" nightly deploy window
    var gitDeploys: [String: GitDeployConfig]?

    var certNotifiedOn: String?
    var registries: [RegistryCredential]?

    private enum CodingKeys: String, CodingKey {
        case hosts, activeHostId, tlsInsecure, theme, accent, refreshInterval
        case trayEnabled, alertBadge, stackGrouping, containerView
        case notifyRules, gcGroups, gcCustom, collapsedGroups
        case autoUpdate, updEnabled, updInterval, updNotified, updAutoApplied
        case ghEnabled, ghInterval, ghWatch, ghIgnored, ghSeen, ghWatchCfg
        case ghDeployTime, gitDeploys, certNotifiedOn, registries
    }

    init() {}

    /// Tolerant decoding: a malformed or legacy value for any single field must
    /// not discard the whole config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decode([DockerHost].self, forKey: .hosts)) ?? []
        activeHostId = try? c.decode(String.self, forKey: .activeHostId)
        tlsInsecure = (try? c.decode(Bool.self, forKey: .tlsInsecure)) ?? false
        theme = try? c.decode(String.self, forKey: .theme)
        accent = try? c.decode(String.self, forKey: .accent)
        refreshInterval = try? c.decode(Double.self, forKey: .refreshInterval)
        trayEnabled = try? c.decode(Bool.self, forKey: .trayEnabled)
        alertBadge = try? c.decode(Bool.self, forKey: .alertBadge)
        stackGrouping = try? c.decode(Bool.self, forKey: .stackGrouping)
        containerView = try? c.decode(String.self, forKey: .containerView)
        notifyRules = try? c.decode([String: Bool].self, forKey: .notifyRules)
        gcGroups = try? c.decode([String: String].self, forKey: .gcGroups)
        gcCustom = try? c.decode([String: ContainerCustomization].self, forKey: .gcCustom)
        collapsedGroups = try? c.decode([String: Bool].self, forKey: .collapsedGroups)
        autoUpdate = try? c.decode([String: Bool].self, forKey: .autoUpdate)
        updEnabled = try? c.decode(Bool.self, forKey: .updEnabled)
        updInterval = try? c.decode(Double.self, forKey: .updInterval)
        updNotified = try? c.decode([String].self, forKey: .updNotified)
        updAutoApplied = try? c.decode([String: String].self, forKey: .updAutoApplied)
        ghEnabled = try? c.decode(Bool.self, forKey: .ghEnabled)
        ghInterval = try? c.decode(Double.self, forKey: .ghInterval)
        ghWatch = try? c.decode([String].self, forKey: .ghWatch)
        ghIgnored = try? c.decode([String].self, forKey: .ghIgnored)
        ghSeen = try? c.decode([String: GitHubSeen].self, forKey: .ghSeen)
        ghWatchCfg = try? c.decode([String: GitHubWatchConfig].self, forKey: .ghWatchCfg)
        ghDeployTime = try? c.decode(String.self, forKey: .ghDeployTime)
        gitDeploys = try? c.decode([String: GitDeployConfig].self, forKey: .gitDeploys)
        certNotifiedOn = try? c.decode(String.self, forKey: .certNotifiedOn)
        registries = try? c.decode([RegistryCredential].self, forKey: .registries)
    }
}

/// Owns the persisted configuration and the on-disk certificate layout.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet { save() }
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Portside", isDirectory: true)
    }

    private static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.configURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var migrated = decoded
            // V2 stored the refresh interval in milliseconds.
            if let interval = migrated.refreshInterval, interval > 1000 {
                migrated.refreshInterval = interval / 1000
            }
            config = migrated
        } else {
            config = AppConfig()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    // MARK: - Hosts

    var activeHost: DockerHost? {
        config.hosts.first { $0.id == config.activeHostId } ?? config.hosts.first
    }

    func addHost(name: String, address: String, port: Int) -> DockerHost {
        let host = DockerHost(name: name.isEmpty ? address : name, host: address, port: port)
        config.hosts.append(host)
        if config.hosts.count == 1 {
            config.activeHostId = host.id
        }
        return host
    }

    func updateHost(_ host: DockerHost) {
        guard let index = config.hosts.firstIndex(where: { $0.id == host.id }) else { return }
        config.hosts[index] = host
    }

    func removeHost(id: String) {
        config.hosts.removeAll { $0.id == id }
        if config.activeHostId == id {
            config.activeHostId = config.hosts.first?.id
        }
    }

    // MARK: - Certificates

    /// Per-host certificates win over the shared set: `certs/<hostId>/`, then `certs/`.
    static func certsDirectory(forHostID hostID: String?) -> URL {
        let root = supportDirectory.appendingPathComponent("certs", isDirectory: true)
        if let hostID {
            let hostDir = root.appendingPathComponent(hostID, isDirectory: true)
            if certsComplete(at: hostDir) { return hostDir }
        }
        return root
    }

    static func certsComplete(at directory: URL) -> Bool {
        ["ca.pem", "cert.pem", "key.pem"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The directory the Settings status panel should display: the per-host
    /// set as soon as it contains *any* of the three files (so imports are
    /// visible immediately, even while incomplete), otherwise the shared set.
    static func displayCertsDirectory(forHostID hostID: String?) -> (url: URL, isHostSpecific: Bool) {
        let root = supportDirectory.appendingPathComponent("certs", isDirectory: true)
        if let hostID {
            let hostDir = root.appendingPathComponent(hostID, isDirectory: true)
            let hasAny = ["ca.pem", "cert.pem", "key.pem"].contains {
                FileManager.default.fileExists(atPath: hostDir.appendingPathComponent($0).path)
            }
            if hasAny { return (hostDir, true) }
        }
        return (root, false)
    }

    /// Classifies and copies imported PEM files into place. Folders (e.g. the
    /// unzipped Container Station bundle) are expanded to the certificate
    /// files inside them. Returns the target file names written, and any of
    /// the three that are still missing.
    static func importCertificates(files: [URL], hostID: String?) throws -> (placed: [String], missing: [String]) {
        let root = supportDirectory.appendingPathComponent("certs", isDirectory: true)
        let directory = hostID.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var expanded: [URL] = []
        for file in files {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: file, includingPropertiesForKeys: nil
                )) ?? []
                expanded.append(contentsOf: children.filter {
                    ["pem", "crt", "cer", "key"].contains($0.pathExtension.lowercased())
                })
            } else {
                expanded.append(file)
            }
        }
        guard !expanded.isEmpty else {
            throw SimpleError("No certificate files found — select ca.pem, cert.pem and key.pem (or the folder containing them).")
        }

        var placed: [String] = []
        for file in expanded {
            let content = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent.lowercased()
            let target: String
            if content.contains("PRIVATE KEY") {
                target = "key.pem"
            } else if TLSIdentity.pemBlock(in: content, types: ["CERTIFICATE"]) != nil {
                // The Container Station bundle names its files ca.pem and
                // cert.pem — the filename is the most reliable signal, so it
                // wins. Content-based self-signed detection is only the
                // fallback for files named something else.
                if name.hasPrefix("ca") || name.contains("root") {
                    target = "ca.pem"
                } else if name.hasPrefix("cert") || name.contains("client") {
                    target = "cert.pem"
                } else {
                    target = Self.looksLikeCA(pem: content) ? "ca.pem" : "cert.pem"
                }
            } else {
                throw SimpleError("\(file.lastPathComponent) is not a valid PEM certificate or key")
            }
            try content.write(to: directory.appendingPathComponent(target), atomically: true, encoding: .utf8)
            placed.append("\(file.lastPathComponent) → \(target)")
        }
        let missing = ["ca.pem", "cert.pem", "key.pem"].filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return (placed, missing)
    }

    private static func looksLikeCA(pem: String) -> Bool {
        guard let block = TLSIdentity.pemBlock(in: pem, types: ["CERTIFICATE"]),
              let cert = SecCertificateCreateWithData(nil, block.der as CFData) else { return false }
        // Self-signed check: the certificate is its own anchor.
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    static func resetCertificates(hostID: String?) {
        let root = supportDirectory.appendingPathComponent("certs", isDirectory: true)
        let directory = hostID.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        for name in ["ca.pem", "cert.pem", "key.pem"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Client factory

    /// Builds a client for a host, loading its certificates. Throws with a
    /// user-actionable message when material is missing or unreadable.
    func makeClient(for host: DockerHost) throws -> DockerClient {
        let identity = try TLSIdentity.load(
            certsDirectory: Self.certsDirectory(forHostID: host.id)
        )
        return DockerClient(host: host, identity: identity, insecure: config.tlsInsecure)
    }
}
