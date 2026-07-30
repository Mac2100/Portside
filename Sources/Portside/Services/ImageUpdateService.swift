import Foundation

/// The image update checker: compares locally recorded digests against the
/// registry's, per image, and applies updates by pulling and recreating the
/// affected containers (config preserved, rollback on failure).
struct ImageUpdateResult: Identifiable, Equatable {
    var image: String
    var shortName: String
    var containers: [AffectedContainer]
    var updateAvailable: Bool
    var remoteDigest: String?
    var note: String?
    var error: String?

    var id: String { image }

    struct AffectedContainer: Equatable {
        var id: String
        var name: String
        var state: String
    }
}

enum ImageUpdateService {
    /// Checks every image with running or stopped containers against its registry.
    /// Runs at most four registry lookups concurrently.
    static func check(
        client: DockerClient,
        registries: [RegistryCredential]
    ) async throws -> [ImageUpdateResult] {
        let containers = try await client.containers()
        var byImage: [String: [ImageUpdateResult.AffectedContainer]] = [:]
        for container in containers {
            guard let image = container.Image, !image.hasPrefix("sha256:") else { continue }
            byImage[image, default: []].append(
                ImageUpdateResult.AffectedContainer(
                    id: container.Id, name: container.name, state: container.State ?? ""
                )
            )
        }

        var results: [ImageUpdateResult] = []
        let images = Array(byImage.keys)
        for batch in stride(from: 0, to: images.count, by: 4).map({ Array(images[$0..<min($0 + 4, images.count)]) }) {
            let batchResults = await withTaskGroup(of: ImageUpdateResult.self) { group in
                for image in batch {
                    group.addTask {
                        await checkOne(
                            image: image,
                            containers: byImage[image] ?? [],
                            client: client,
                            registries: registries
                        )
                    }
                }
                var collected: [ImageUpdateResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: batchResults)
        }
        return results.sorted { $0.shortName < $1.shortName }
    }

    private static func checkOne(
        image: String,
        containers: [ImageUpdateResult.AffectedContainer],
        client: DockerClient,
        registries: [RegistryCredential]
    ) async -> ImageUpdateResult {
        let short = image.split(separator: "@").first.map(String.init)?
            .split(separator: "/").last.map(String.init)?
            .split(separator: ":").first.map(String.init) ?? image
        var result = ImageUpdateResult(
            image: image, shortName: short, containers: containers, updateAvailable: false
        )
        do {
            let details = try await client.imageDetails(reference: image)
            let localDigests = (details.RepoDigests ?? [])
                .filter { $0.contains("@") }
                .compactMap { $0.split(separator: "@").last.map(String.init) }
            guard !localDigests.isEmpty else {
                result.note = "local build"
                return result
            }
            let remote = try await RegistryClient.remoteManifest(image: image, saved: registries)
            result.remoteDigest = remote.digest
            var known = Set(remote.platformDigests)
            if let digest = remote.digest { known.insert(digest) }
            // Up to date if ANY locally recorded digest matches the list digest
            // or any platform digest — comparing only the list digest caused
            // eternal "update available" for some images.
            result.updateAvailable = !known.isEmpty && !localDigests.contains { known.contains($0) }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// Pulls the container's image and recreates it from its live config.
    /// Returns the new container ID.
    @discardableResult
    static func apply(
        containerID: String,
        client: DockerClient,
        registries: [RegistryCredential]
    ) async throws -> String {
        let raw = try await client.inspectRaw(id: containerID)
        guard let config = raw["Config"] as? [String: Any],
              let image = config["Image"] as? String else {
            throw SimpleError("Inspect failed")
        }
        let name = ((raw["Name"] as? String) ?? "").withoutLeadingSlash

        try await client.pull(image: image, auth: RegistryClient.authHeader(image: image, saved: registries))

        return try await client.replace(id: containerID) { inspected in
            (name, DockerClient.recreatePayload(fromRaw: inspected, image: image))
        }
    }
}
