import Foundation

/// GitHub watching (latest release and latest default-branch commit) and
/// Git Deploy — pulling a bind-mounted app folder from GitHub inside a
/// throwaway `alpine/git` container, then restarting the app container.
enum GitHubService {
    struct RepoStatus {
        var repo: String
        var tag: String
        var name: String
        var url: String
        var commit: Commit?

        struct Commit {
            var sha: String
            var shortSha: String
            var message: String
            var url: String
        }
    }

    /// Something new on a watched repo since it was last marked seen.
    struct WatchFinding: Identifiable, Equatable {
        var repo: String
        var kind: Kind
        var what: String       // tag or short sha
        var title: String
        var url: String
        var markSeen: GitHubSeen

        var id: String { "\(repo)@\(what)" }

        enum Kind: Equatable { case release, commit }
    }

    static func cleanRepo(_ input: String) -> String? {
        let cleaned = input.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://www.github.com/", with: "")
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pattern = /^[\w.-]+\/[\w.-]+$/
        return cleaned.wholeMatch(of: pattern) != nil ? cleaned : nil
    }

    static func repoFromURL(_ url: String) -> String? {
        guard let match = url.firstMatch(of: /github\.com\/([\w.-]+\/[\w.-]+?)(?:\.git)?(?:\/|$)/) else {
            return nil
        }
        return String(match.1)
    }

    private static func request(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Portside", forHTTPHeaderField: "User-Agent")
        if let token = Keychain.gitHubToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Latest release (or tag as fallback) and latest default-branch commit.
    static func latest(repo rawRepo: String) async throws -> RepoStatus {
        guard let repo = cleanRepo(rawRepo) else {
            throw SimpleError("Use the owner/repo form, e.g. linuxserver/docker-sonarr")
        }
        var status = RepoStatus(
            repo: repo, tag: "", name: "",
            url: "https://github.com/\(repo)/releases", commit: nil
        )

        struct Release: Decodable {
            var tag_name: String?
            var name: String?
            var html_url: String?
        }
        let (releaseData, releaseCode) = try await request(
            URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        )
        if releaseCode == 200, let release = try? JSONDecoder().decode(Release.self, from: releaseData) {
            status.tag = release.tag_name ?? ""
            status.name = release.name ?? release.tag_name ?? ""
            status.url = release.html_url ?? status.url
        } else if releaseCode == 404 {
            struct Tag: Decodable { var name: String? }
            let (tagData, tagCode) = try await request(
                URL(string: "https://api.github.com/repos/\(repo)/tags?per_page=1")!
            )
            if tagCode == 200, let tags = try? JSONDecoder().decode([Tag].self, from: tagData),
               let first = tags.first?.name {
                status.tag = first
                status.name = first
                status.url = "https://github.com/\(repo)/tags"
            }
        } else if releaseCode == 401 || releaseCode == 403 {
            let hint = Keychain.gitHubToken == nil
                ? " — add a token in Settings → Git Deploy for private repos and higher rate limits"
                : ""
            throw SimpleError("GitHub HTTP \(releaseCode)\(hint)")
        }

        struct CommitEntry: Decodable {
            var sha: String?
            var html_url: String?
            var commit: Inner?
            struct Inner: Decodable {
                var message: String?
            }
        }
        let (commitData, commitCode) = try await request(
            URL(string: "https://api.github.com/repos/\(repo)/commits?per_page=1")!
        )
        if commitCode == 200,
           let commits = try? JSONDecoder().decode([CommitEntry].self, from: commitData),
           let first = commits.first, let sha = first.sha {
            status.commit = RepoStatus.Commit(
                sha: sha,
                shortSha: String(sha.prefix(7)),
                message: (first.commit?.message ?? "").components(separatedBy: "\n").first ?? "",
                url: first.html_url ?? "https://github.com/\(repo)/commits"
            )
        } else if commitCode == 404 && status.tag.isEmpty {
            throw SimpleError("Repo not found (or private — add a token in Settings → Git Deploy)")
        }

        if status.tag.isEmpty && status.commit == nil {
            throw SimpleError("No releases, tags or commits found")
        }
        return status
    }

    // MARK: - Git Deploy

    struct DeployResult {
        var deployed: String
        var restarted: Bool
        var restartError: String?
        var output: String
    }

    private static func gitBase(_ repoURL: String) -> String {
        repoURL.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
    }

    /// Runs a one-shot `alpine/git` container bind-mounted to the app folder.
    /// The token is handed over only at run time as an env var — it is never
    /// written into the repo's `.git/config` on the host.
    private static func runGitContainer(
        client: DockerClient,
        folder: String,
        shellCommand: String,
        registries: [RegistryCredential]
    ) async throws -> (exitCode: Int, output: String) {
        try await client.pull(
            image: "alpine/git",
            auth: RegistryClient.authHeader(image: "alpine/git", saved: registries)
        )
        var payload: [String: Any] = [
            "Image": "alpine/git",
            "Entrypoint": ["/bin/sh", "-c"],
            "Cmd": [shellCommand],
            "HostConfig": [
                "Binds": ["\(folder):/git"],
                "AutoRemove": false,
                "NetworkMode": "bridge"
            ]
        ]
        if let token = Keychain.gitHubToken, !token.isEmpty {
            payload["Env"] = ["GT=\(token)"]
        }
        let id = try await client.createRaw(
            payload: payload,
            name: "portside-gitdeploy-\(String(Int(Date().timeIntervalSince1970), radix: 36))"
        )
        defer {
            Task { try? await client.remove(id: id, force: true) }
        }
        try await client.perform(.start, id: id)
        let exitCode = try await client.wait(id: id, timeout: 180)
        // timestamps stay off — the caller parses "<sha> <message>" lines.
        let output = (try? await client.logs(id: id, tail: 200, timestamps: false)) ?? ""
        return (exitCode, output)
    }

    /// Lists recent commits for the rollback picker. Fetches; changes nothing on disk.
    static func versions(
        client: DockerClient,
        deploy: GitDeployConfig,
        registries: [RegistryCredential]
    ) async throws -> [(sha: String, message: String)] {
        guard !deploy.folder.isEmpty, !deploy.repoUrl.isEmpty else {
            throw SimpleError("Not configured — set the repo and folder first.")
        }
        let branch = deploy.branch.isEmpty ? "main" : deploy.branch
        let command = [
            "cd /git",
            "git config --global --add safe.directory /git",
            "git rev-parse --git-dir >/dev/null 2>&1 || git init -q",
            "git fetch --tags \"https://x-access-token:$GT@\(gitBase(deploy.repoUrl)).git\" \"\(branch)\"",
            "git --no-pager log FETCH_HEAD --oneline -20"
        ].joined(separator: " && ")
        let result = try await runGitContainer(
            client: client, folder: deploy.folder, shellCommand: command, registries: registries
        )
        guard result.exitCode == 0 else {
            let tail = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw SimpleError(tail.isEmpty ? "git failed" : tail)
        }
        return result.output.split(separator: "\n").compactMap { line in
            guard let match = line.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /([0-9a-f]{7,40})\s+(.*)/) else { return nil }
            return (String(match.1), String(match.2))
        }
    }

    /// Deploys: pull to latest (`ref == nil`) or roll back to a commit, then
    /// restarts the linked container.
    static func deploy(
        client: DockerClient,
        deploy: GitDeployConfig,
        ref: String?,
        restartContainerID: String?,
        registries: [RegistryCredential]
    ) async throws -> DeployResult {
        guard !deploy.folder.isEmpty, !deploy.repoUrl.isEmpty else {
            throw SimpleError("Not configured — set the repo and folder first.")
        }
        let branch = deploy.branch.isEmpty ? "main" : deploy.branch
        let resetTo = (ref?.isEmpty == false && ref != "latest") ? ref! : "FETCH_HEAD"
        let command = [
            "cd /git",
            "git config --global --add safe.directory /git",
            "git rev-parse --git-dir >/dev/null 2>&1 || git init -q",
            "git remote get-url origin >/dev/null 2>&1 || git remote add origin \"\(deploy.repoUrl)\"",
            "git remote set-url origin \"\(deploy.repoUrl)\"",
            "git fetch --tags \"https://x-access-token:$GT@\(gitBase(deploy.repoUrl)).git\" \"\(branch)\"",
            "git reset --hard \(resetTo)",
            "echo \"===PORTSIDE-DEPLOYED===\"",
            "git --no-pager log -1 --format=\"%h %s\""
        ].joined(separator: " && ")

        let result = try await runGitContainer(
            client: client, folder: deploy.folder, shellCommand: command, registries: registries
        )
        guard result.exitCode == 0 else {
            let tail = result.output.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw SimpleError(tail.isEmpty ? "git failed" : tail)
        }

        var restarted = false
        var restartError: String?
        if let restartContainerID {
            do {
                try await client.perform(.restart, id: restartContainerID)
                restarted = true
            } catch {
                restartError = "Files updated, but the container restart failed: \(error.localizedDescription)"
            }
        }
        let deployedLine = result.output
            .components(separatedBy: "===PORTSIDE-DEPLOYED===").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return DeployResult(
            deployed: deployedLine, restarted: restarted,
            restartError: restartError, output: result.output
        )
    }
}
