import Foundation
import UserNotifications

/// System (Notification Center) notifications, gated per event type in
/// Settings → Notifications — a container that restarts by design shouldn't
/// mean turning notifications off entirely.
@MainActor
final class Notifier {
    static let shared = Notifier()

    enum Event: String, CaseIterable, Identifiable {
        case stopped
        case crashed
        case unhealthy
        case restartLoop
        case imageUpdate
        case ghRelease
        case certExpiring

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stopped: return "Container stopped"
            case .crashed: return "Container crashed"
            case .unhealthy: return "Container unhealthy"
            case .restartLoop: return "Restart loop"
            case .imageUpdate: return "Image update available"
            case .ghRelease: return "GitHub release or commit"
            case .certExpiring: return "TLS certificate expiring"
            }
        }

        var hint: String {
            switch self {
            case .stopped: return "A container that was running is no longer running"
            case .crashed: return "Exited with a non-zero code — it failed rather than being told to stop"
            case .unhealthy: return "Its own HEALTHCHECK started failing"
            case .restartLoop: return "Docker is repeatedly restarting a container that keeps dying"
            case .imageUpdate: return "A newer image was published for something you run (and auto-update results)"
            case .ghRelease: return "A repo you watch has new commits or a new release"
            case .certExpiring: return "Your Docker certificates are close to expiry — after that Portside goes dark"
            }
        }
    }

    private var authorizationRequested = false

    private init() {}

    static func isEnabled(_ event: Event) -> Bool {
        ConfigStore.shared.config.notifyRules?[event.rawValue] != false   // default on
    }

    static func setEnabled(_ event: Event, _ enabled: Bool) {
        var rules = ConfigStore.shared.config.notifyRules ?? [:]
        rules[event.rawValue] = enabled
        ConfigStore.shared.config.notifyRules = rules
    }

    func post(_ event: Event, _ body: String) {
        guard Self.isEnabled(event) else { return }
        // UNUserNotificationCenter requires a real app bundle (not `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = "Portside"
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
