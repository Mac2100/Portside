import SwiftUI
import AppKit

// MARK: - Themes

struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// App glyph used in the sidebar header and About panel.
    func glyph(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: primary.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

enum Themes {
    static let all: [AppTheme] = [
        AppTheme(
            id: "harbor", name: "Harbor",
            primary: Color(red: 0.11, green: 0.42, blue: 0.86),
            secondary: Color(red: 0.09, green: 0.66, blue: 0.72)
        ),
        AppTheme(
            id: "teal", name: "Teal",
            primary: Color(red: 0.05, green: 0.58, blue: 0.53),
            secondary: Color(red: 0.22, green: 0.78, blue: 0.63)
        ),
        AppTheme(
            id: "violet", name: "Violet",
            primary: Color(red: 0.42, green: 0.31, blue: 0.87),
            secondary: Color(red: 0.66, green: 0.44, blue: 0.95)
        ),
        AppTheme(
            id: "sunset", name: "Sunset",
            primary: Color(red: 0.94, green: 0.42, blue: 0.16),
            secondary: Color(red: 0.90, green: 0.20, blue: 0.50)
        ),
        AppTheme(
            id: "forest", name: "Forest",
            primary: Color(red: 0.13, green: 0.55, blue: 0.28),
            secondary: Color(red: 0.35, green: 0.78, blue: 0.55)
        ),
        AppTheme(
            id: "graphite", name: "Graphite",
            primary: Color(red: 0.35, green: 0.37, blue: 0.42),
            secondary: Color(red: 0.55, green: 0.58, blue: 0.64)
        )
    ]

    static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var themeID: String {
        didSet { ConfigStore.shared.config.accent = themeID }
    }
    @Published var appearance: AppearanceMode {
        didSet {
            ConfigStore.shared.config.theme = appearance.rawValue
            applyAppearance()
        }
    }

    var theme: AppTheme {
        Themes.theme(id: themeID)
    }

    private init() {
        let config = ConfigStore.shared.config
        themeID = config.accent ?? "harbor"
        appearance = AppearanceMode(rawValue: config.theme ?? "") ?? .system
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = Themes.all[0]
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Shared components

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14, padding: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

/// Rounded search field matching the in-content control row.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .frame(width: 200)
    }
}

/// Capsule segmented control used for tab switches and view toggles.
struct CapsuleSegments<T: Hashable>: View {
    let options: [(value: T, label: String, symbol: String?)]
    @Binding var selection: T
    var showLabels = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = option.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if showLabels {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            selection == option.value
                                ? AnyShapeStyle(.background)
                                : AnyShapeStyle(Color.clear)
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            selection == option.value
                                ? Color.primary.opacity(0.12)
                                : Color.clear,
                            lineWidth: 1
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option.value ? .primary : .secondary)
                .help(option.label)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }
}

/// Status dot + label for a container state.
struct StateBadge: View {
    let container: ContainerSummary

    private var color: Color {
        if container.isRunning { return container.isUnhealthy ? .orange : .green }
        if container.isRestarting || container.isPaused { return .orange }
        return .secondary.opacity(0.7)
    }

    private var label: String {
        (container.State ?? "unknown").capitalized
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(container.isRunning ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// The per-container tint palette (auto-assigned by name hash, overridable).
enum ContainerTint {
    static let palette: [String] = [
        "#5DCAA5", "#85B7EB", "#7F77DD", "#EF9F27", "#97C459", "#F0997B", "#58A6FF", "#BC8CFF"
    ]

    static func auto(for name: String) -> String {
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static func color(hex: String) -> Color {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func color(for container: ContainerSummary, custom: ContainerCustomization) -> Color {
        color(hex: custom.tint ?? auto(for: container.name))
    }

    /// Monogram fallback icon: the first alphanumeric character.
    static func monogram(for name: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        return cleaned.first.map { String($0).uppercased() } ?? "#"
    }
}

extension Date {
    var briefFormatted: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
