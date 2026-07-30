import SwiftUI

struct Toast: Identifiable, Equatable {
    enum Style {
        case success, info, error

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .info: return .blue
            case .error: return .orange
            }
        }
    }

    let id = UUID()
    let message: String
    let detail: String?
    let style: Style
}

/// Transient bottom-trailing notifications ("container restarted", "image pulled", …).
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var toasts: [Toast] = []

    private init() {}

    func show(_ message: String, detail: String? = nil, style: Toast.Style = .success) {
        let toast = Toast(message: message, detail: detail, style: style)
        withAnimation(.spring(duration: 0.3)) {
            toasts.append(toast)
            if toasts.count > 3 {
                toasts.removeFirst(toasts.count - 3)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.toasts.removeAll { $0.id == toast.id }
            }
        }
    }
}

struct ToastHostView: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                HStack(spacing: 9) {
                    Image(systemName: toast.style.symbol)
                        .foregroundStyle(toast.style.color)
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.message)
                            .font(.callout.weight(.medium))
                        if let detail = toast.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(18)
        .allowsHitTesting(false)
    }
}
