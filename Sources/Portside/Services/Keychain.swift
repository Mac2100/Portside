import Foundation
import Security

/// Secrets (registry passwords, the shared Git Deploy token) are stored only in
/// the local macOS Keychain — encrypted at rest by the OS, never written to
/// disk by the app, never sent anywhere except the service they belong to.
enum Keychain {
    private static let service = "com.mac2100.Portside"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    static func setSecret(_ secret: String, account: String) -> Bool {
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func secret(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    // MARK: - Well-known accounts

    /// One shared read-only GitHub token used by Git Deploy and the GitHub watcher.
    static var gitHubToken: String? {
        get { secret(account: "github-token") }
        set {
            if let newValue, !newValue.isEmpty {
                setSecret(newValue, account: "github-token")
            } else {
                deleteSecret(account: "github-token")
            }
        }
    }

    static func registrySecret(host: String) -> String? {
        secret(account: "registry:\(host)")
    }

    static func setRegistrySecret(_ secret: String, host: String) {
        setSecret(secret, account: "registry:\(host)")
    }

    static func deleteRegistrySecret(host: String) {
        deleteSecret(account: "registry:\(host)")
    }
}
