import SwiftUI

/// The one place the "support this app" destinations live.
enum SupportLinks {
    static let buyMeACoffee = URL(string: "https://www.buymeacoffee.com/Mac2100")!
    static let gitHubRepo = URL(string: "https://github.com/\(UpdateChecker.repo)")!
}

/// Yellow support capsule, styled after the button on buymeacoffee.com.
struct BuyMeACoffeeButton: View {
    /// Brand yellow (#FFDD00), the same colour as the official button image.
    private static let brandYellow = Color(red: 1.0, green: 0.867, blue: 0.0)

    var body: some View {
        Link(destination: SupportLinks.buyMeACoffee) {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill")
                Text("Buy Me a Coffee")
                    .fontWeight(.semibold)
            }
            .font(.callout)
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Self.brandYellow))
        }
        .buttonStyle(.plain)
        .help("Support development — buymeacoffee.com/Mac2100")
    }
}

/// The free way to help: a nudge to star the repo.
struct StarOnGitHubButton: View {
    var body: some View {
        Link(destination: SupportLinks.gitHubRepo) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                Text("Star on GitHub")
                    .fontWeight(.semibold)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(.quaternary))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Star \(UpdateChecker.repo) on GitHub")
    }
}

/// Both ways to say thanks, side by side — used in the About panel.
struct SupportButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            BuyMeACoffeeButton()
            StarOnGitHubButton()
        }
    }
}
