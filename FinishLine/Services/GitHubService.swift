import Foundation

/// Reads GitHub Actions results with a fine-grained personal access token
/// (repository permission "Actions: Read-only" is enough).
enum GitHubService {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RunsResponse: Decodable {
        let workflow_runs: [Run]
    }

    private struct Run: Decodable {
        let name: String?
        let path: String?
        let status: String?
        let conclusion: String?
        let html_url: String?
    }

    /// Newest run of every workflow in the repo (build.yml, perf.yml, ...).
    static func latestRuns(owner: String, repo: String, token: String) async throws -> [WorkflowStatus] {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs?per_page=40") else {
            throw APIError(message: "Bad repo name")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401: throw APIError(message: "GitHub token rejected, check it in Settings")
        case 403: throw APIError(message: "GitHub refused (rate limit or token lacks Actions: Read)")
        case 404: throw APIError(message: "Repo \(owner)/\(repo) not found, or the token can't see it")
        default: throw APIError(message: "GitHub error \(code)")
        }

        let runs = try JSONDecoder().decode(RunsResponse.self, from: data).workflow_runs
        // Runs come newest first: keep the first one per workflow file.
        var seen = Set<String>()
        var out: [WorkflowStatus] = []
        for r in runs {
            let rawPath = r.path ?? r.name ?? "workflow"
            let path = rawPath.components(separatedBy: "@").first ?? rawPath
            if seen.contains(path) { continue }
            seen.insert(path)
            out.append(WorkflowStatus(
                name: r.name ?? path,
                path: path,
                status: r.status ?? "unknown",
                conclusion: r.conclusion,
                htmlURL: r.html_url ?? ""
            ))
        }
        return out
    }
}

@MainActor
enum CIRefresher {
    /// Refresh CI for active projects. Returns an error message, or nil if fine.
    @discardableResult
    static func refresh(_ projects: [Project]) async -> String? {
        guard let token = KeychainStore.read("githubToken"), !token.isEmpty else {
            return "Add a GitHub token in Settings to see CI status"
        }
        var lastError: String?
        for p in projects where p.state == .active && p.hasRepo {
            do {
                let runs = try await GitHubService.latestRuns(owner: p.repoOwner, repo: p.repoName, token: token)
                p.apply(runs)
            } catch {
                p.ciSummary = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
        return lastError
    }
}
