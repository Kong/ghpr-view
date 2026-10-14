import Foundation

/// Canonical comment context resolved from GitHub, never from the page.
struct GitHubPRCommentContext: Equatable {
    enum Kind: String, Equatable {
        case reviewComment
        case issueComment
    }

    let kind: Kind
    let body: String
    let url: URL?
    /// Pull request number GitHub associates with the comment, used to reject a
    /// permalink that belongs to a different PR.
    let pullRequestNumber: Int?
}

enum GitHubCommentContextError: LocalizedError, Equatable {
    case unsupportedPermalink
    case notFound
    case mismatchedPullRequest(expected: Int, found: Int?)
    case malformedRepository(String)
    case missingHeadRevision

    var errorDescription: String? {
        switch self {
        case .unsupportedPermalink:
            return String(localized: "The comment link could not be recognized.")
        case .notFound:
            return String(localized: "The comment was not found on GitHub.")
        case .mismatchedPullRequest(let expected, let found):
            return String(localized: "The comment belongs to a different pull request (\(found.map(String.init) ?? "unknown") instead of \(expected)).")
        case .malformedRepository(let repository):
            return String(localized: "Repository \"\(repository)\" is not in owner/name form.")
        case .missingHeadRevision:
            return String(localized: "GitHub did not report a head revision for this pull request.")
        }
    }
}

extension GitHubAPIClient {
    /// Resolves the comment behind a GitHub permalink through the REST API so the body,
    /// the permalink and the PR association are canonical. The browser's copy of any of
    /// those is treated as a hint only.
    func fetchCommentContext(repository: String, permalink: URL) async throws -> GitHubPRCommentContext {
        let parts = try Self.splitRepository(repository)
        let target = try Self.commentPermalinkTarget(permalink)

        let path = target.kind == .reviewComment
            ? "repos/\(parts.owner)/\(parts.name)/pulls/comments/\(target.commentID)"
            : "repos/\(parts.owner)/\(parts.name)/issues/comments/\(target.commentID)"
        let object = try await monitorRESTJSON(path: path)

        guard let body = object["body"] as? String else {
            throw GitHubCommentContextError.notFound
        }
        let url = (object["html_url"] as? String).flatMap(URL.init(string:))

        let pullRequestNumber: Int?
        if let pullRequestURL = object["pull_request_url"] as? String {
            pullRequestNumber = Self.pullRequestNumber(fromAPIPullRequestURL: pullRequestURL)
        } else {
            pullRequestNumber = Self.pullRequestNumber(fromHTMLPermalink: url)
        }

        return GitHubPRCommentContext(
            kind: target.kind,
            body: body,
            url: url,
            pullRequestNumber: pullRequestNumber
        )
    }

    /// Head revision of a pull request, read from the API so a page cannot claim a
    /// revision the PR does not have.
    func fetchPullRequestHeadSHA(repository: String, number: Int) async throws -> String {
        let parts = try Self.splitRepository(repository)
        let object = try await monitorRESTJSON(path: "repos/\(parts.owner)/\(parts.name)/pulls/\(number)")
        guard let head = object["head"] as? [String: Any],
              let sha = head["sha"] as? String,
              !sha.isEmpty else {
            throw GitHubCommentContextError.missingHeadRevision
        }
        return sha
    }

    // MARK: - Private

    private func monitorRESTJSON(path: String) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: monitorRESTBaseURL) else {
            throw MonitorTransportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let token = monitorToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await monitorSession.data(for: request)
        } catch {
            if Task.isCancelled { throw MonitorTransportError.network(CancellationError()) }
            throw MonitorTransportError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MonitorTransportError.invalidResponse
        }
        monitorRecordRateLimit(from: httpResponse)

        switch httpResponse.statusCode {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MonitorTransportError.invalidResponse
            }
            return object
        case 401, 403:
            monitorReportUnauthorized(rejectedToken: token)
            throw MonitorTransportError.unauthorized
        case 404:
            throw GitHubCommentContextError.notFound
        case 429:
            throw MonitorTransportError.rateLimited(reset: nil)
        default:
            throw MonitorTransportError.http(httpResponse.statusCode)
        }
    }

    private static func splitRepository(_ repository: String) throws -> (owner: String, name: String) {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
            throw GitHubCommentContextError.malformedRepository(repository)
        }
        return (String(components[0]), String(components[1]))
    }

    private static func commentPermalinkTarget(
        _ permalink: URL
    ) throws -> (kind: GitHubPRCommentContext.Kind, commentID: String) {
        let fragment = permalink.fragment ?? ""
        if let range = fragment.range(of: "issuecomment-"), !fragment.hasPrefix("discussion_") {
            let id = fragment[range.upperBound...].prefix { $0.isNumber }
            guard !id.isEmpty else { throw GitHubCommentContextError.unsupportedPermalink }
            return (.issueComment, String(id))
        }
        if let range = fragment.range(of: "discussion_r") {
            let id = fragment[range.upperBound...].prefix { $0.isNumber }
            guard !id.isEmpty else { throw GitHubCommentContextError.unsupportedPermalink }
            return (.reviewComment, String(id))
        }
        throw GitHubCommentContextError.unsupportedPermalink
    }

    private static func pullRequestNumber(fromAPIPullRequestURL url: String) -> Int? {
        guard let range = url.range(of: "/pulls/") else { return nil }
        return Int(url[range.upperBound...].prefix { $0.isNumber })
    }

    private static func pullRequestNumber(fromHTMLPermalink url: URL?) -> Int? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let pullIndex = components.firstIndex(of: "pull"),
              components.index(after: pullIndex) < components.endIndex else {
            return nil
        }
        return Int(components[components.index(after: pullIndex)])
    }
}
