import Foundation

/// A saved registry credential: host + username live in the config file, the
/// secret lives in the Keychain.
struct RegistryCredential: Codable, Equatable, Identifiable {
    var host: String
    var username: String

    var id: String { host }
}

/// Talks to container registries directly (Docker Hub, GHCR, private
/// registries): manifest digest lookups for the update checker, credential
/// verification, and the `X-Registry-Auth` payload Docker needs for pulls.
enum RegistryClient {
    struct ImageRef {
        var registry: String
        var repository: String
        var tag: String
    }

    /// Splits an image reference into registry / repository / tag, applying
    /// Docker Hub's defaulting rules.
    static func parse(_ image: String) -> ImageRef {
        var ref = image.split(separator: "@").first.map(String.init) ?? image
        var tag = "latest"
        if let colon = ref.lastIndex(of: ":"),
           ref.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            tag = String(ref[ref.index(after: colon)...])
            ref = String(ref[..<colon])
        }
        var registry = "registry-1.docker.io"
        var repository = ref
        let first = ref.split(separator: "/").first.map(String.init) ?? ""
        if first.contains(".") || first.contains(":") || first == "localhost" {
            registry = first
            repository = String(ref.dropFirst(first.count + 1))
        } else if !ref.contains("/") {
            repository = "library/\(ref)"
        }
        if registry == "docker.io" || registry == "index.docker.io" {
            registry = "registry-1.docker.io"
        }
        if registry == "registry-1.docker.io" && !repository.contains("/") {
            repository = "library/\(repository)"
        }
        return ImageRef(registry: registry, repository: repository, tag: tag)
    }

    /// Normalises user-entered registry hosts so "docker.io", "https://docker.io/"
    /// and "registry-1.docker.io" all match.
    static func normalize(_ host: String) -> String {
        var s = host.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: "https://", with: "")
        s = s.replacingOccurrences(of: "http://", with: "")
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty || s == "docker.io" || s == "index.docker.io" || s == "registry-1.docker.io" {
            return "registry-1.docker.io"
        }
        return s
    }

    static func credential(for registry: String, saved: [RegistryCredential]) -> (username: String, password: String)? {
        let normalized = normalize(registry)
        guard let match = saved.first(where: { normalize($0.host) == normalized }),
              let password = Keychain.registrySecret(host: normalize(match.host)),
              !match.username.isEmpty, !password.isEmpty else { return nil }
        return (match.username, password)
    }

    /// Docker wants the legacy index URL as serveraddress for Hub, the bare host otherwise.
    static func serverAddress(for registry: String) -> String {
        normalize(registry) == "registry-1.docker.io" ? "https://index.docker.io/v1/" : normalize(registry)
    }

    /// The base64 `X-Registry-Auth` header for a pull of `image`, or nil when
    /// no credential is saved for its registry.
    static func authHeader(image: String, saved: [RegistryCredential]) -> String? {
        let ref = parse(image)
        guard let creds = credential(for: ref.registry, saved: saved) else { return nil }
        let payload: [String: String] = [
            "username": creds.username,
            "password": creds.password,
            "serveraddress": serverAddress(for: ref.registry)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Manifest digests

    struct RemoteManifest {
        var digest: String?
        /// A multi-arch tag has one digest for the list AND one per platform;
        /// local RepoDigests may record either, so a match against any counts.
        var platformDigests: [String]
    }

    private static let acceptHeader = [
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json"
    ].joined(separator: ", ")

    static func remoteManifest(image: String, saved: [RegistryCredential]) async throws -> RemoteManifest {
        let ref = parse(image)
        guard let url = URL(string: "https://\(ref.registry)/v2/\(ref.repository)/manifests/\(ref.tag)") else {
            throw SimpleError("Bad image reference: \(image)")
        }

        var request = URLRequest(url: url)
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        var (data, response) = try await URLSession.shared.data(for: request)
        var http = response as? HTTPURLResponse

        if http?.statusCode == 401 {
            // Bearer token dance. With saved credentials the token request gets
            // Basic auth — private repos answer at all, and Docker Hub stops
            // counting us against the anonymous pull limit.
            let authenticate = http?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            guard let realm = firstMatch(authenticate, pattern: "realm=\"([^\"]+)\"") else {
                throw SimpleError("Registry requires authentication")
            }
            let service = firstMatch(authenticate, pattern: "service=\"([^\"]+)\"") ?? ""
            var components = URLComponents(string: realm)
            components?.queryItems = [
                URLQueryItem(name: "service", value: service),
                URLQueryItem(name: "scope", value: "repository:\(ref.repository):pull")
            ]
            guard let tokenURL = components?.url else {
                throw SimpleError("Registry auth endpoint is invalid")
            }
            var tokenRequest = URLRequest(url: tokenURL)
            if let creds = credential(for: ref.registry, saved: saved) {
                let basic = Data("\(creds.username):\(creds.password)".utf8).base64EncodedString()
                tokenRequest.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            }
            let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
            struct TokenResponse: Decodable {
                var token: String?
                var access_token: String?
            }
            let decoded = try? JSONDecoder().decode(TokenResponse.self, from: tokenData)
            guard let token = decoded?.token ?? decoded?.access_token else {
                throw SimpleError(
                    credential(for: ref.registry, saved: saved) != nil
                        ? "Registry rejected the saved credentials"
                        : "Registry token fetch failed"
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
            http = response as? HTTPURLResponse
        }

        switch http?.statusCode {
        case 200:
            break
        case 401, 403:
            throw SimpleError(
                credential(for: ref.registry, saved: saved) != nil
                    ? "Registry denied access — check the credentials in Settings → Registries"
                    : "Private image — add credentials in Settings → Registries"
            )
        case 429:
            throw SimpleError("Registry rate limit hit — add credentials in Settings → Registries to lift it")
        default:
            throw SimpleError("Registry HTTP \(http?.statusCode ?? 0)")
        }

        let digest = http?.value(forHTTPHeaderField: "Docker-Content-Digest")
        var platforms: [String] = []
        struct ManifestList: Decodable {
            var manifests: [Entry]?
            struct Entry: Decodable { var digest: String? }
        }
        if let list = try? JSONDecoder().decode(ManifestList.self, from: data) {
            platforms = (list.manifests ?? []).compactMap(\.digest)
        }
        return RemoteManifest(digest: digest, platformDigests: platforms)
    }

    /// Verifies a credential against `/v2/` before saving — a credential that
    /// silently doesn't work is worse than none.
    static func test(host: String, username: String, password: String) async throws {
        let registry = normalize(host)
        guard let url = URL(string: "https://\(registry)/v2/") else {
            throw SimpleError("Invalid registry host")
        }
        var request = URLRequest(url: url)
        let basic = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw SimpleError("Registry rejected those credentials")
        }
        if status >= 400 && status != 404 {
            throw SimpleError("Registry HTTP \(status)")
        }
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
