import Foundation

/// Single source of truth for the app version.
/// `scripts/make_app.sh` extracts this value to stamp Info.plist and name the DMG.
enum AppVersion {
    static let marketing = "3.0.3"

    /// Prefers the bundle version when running from a built .app, falls back to
    /// the compiled-in constant when running via `swift run`.
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? marketing
    }
}
