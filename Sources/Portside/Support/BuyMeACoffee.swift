import SwiftUI

/// The one place the "Buy Me a Coffee" destination lives.
enum BuyMeACoffee {
    static let url = URL(string: "https://www.buymeacoffee.com/Mac2100")!
}

/// Yellow support capsule, styled after the button on buymeacoffee.com.
struct BuyMeACoffeeButton: View {
    /// Brand yellow (#FFDD00), the same colour as the official button image.
    private static let brandYellow = Color(red: 1.0, green: 0.867, blue: 0.0)

    var body: some View {
        Link(destination: BuyMeACoffee.url) {
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
