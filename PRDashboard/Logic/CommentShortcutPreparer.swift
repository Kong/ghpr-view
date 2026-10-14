import Foundation

enum CommentShortcutPreparationError: LocalizedError, Equatable {
    case shortcutUnavailable
    case shortcutNotApplicable
    case missingPullRequest
    case contextMismatch(String)
    case headChanged(expected: String, actual: String)
    case templateFailed(String)

    var errorDescription: String? {
        switch self {
        case .shortcutUnavailable:
            return String(localized: "That comment shortcut is no longer configured.")
        case .shortcutNotApplicable:
            return String(localized: "That comment shortcut does not apply to this PR or comment.")
        case .missingPullRequest:
            return String(localized: "This page is not a pull request.")
        case .contextMismatch(let detail):
            return String(localized: "The draft was not prepared: \(detail)")
        case .headChanged(let expected, let actual):
            return String(localized: "The pull request moved from \(expected.prefix(7)) to \(actual.prefix(7)); reload the page before commenting.")
        case .templateFailed(let detail):
            return String(localized: "The comment template could not be rendered: \(detail)")
        }
    }
}

/// Builds a comment draft from a configured shortcut and canonical API context.
///
/// The result is plain text for GitHub's own composer. Nothing here posts a comment,
/// presses Enter or otherwise writes to GitHub.
@MainActor
enum CommentShortcutPreparer {
    static func prepare(
        request: BrowserBridgeRouter.BrowserCommentShortcutRequest,
        configuration: Configuration,
        apiClient: GitHubAPIClient
    ) async throws -> CommentShortcutDraft {
        guard let shortcut = configuration.commentShortcuts.first(where: { $0.id == request.shortcutID }),
              shortcut.isEnabled else {
            throw CommentShortcutPreparationError.shortcutUnavailable
        }
        let repository = request.page.repository
        guard let number = request.page.prNumber else {
            throw CommentShortcutPreparationError.missingPullRequest
        }

        let context = try context(for: request.commentPermalink)
        guard shortcut.applies(to: context, repository: repository) else {
            throw CommentShortcutPreparationError.shortcutNotApplicable
        }

        let headSHA = try await apiClient.fetchPullRequestHeadSHA(repository: repository, number: number)
        if let expected = request.expectedHeadSHA, !expected.isEmpty, expected != headSHA {
            throw CommentShortcutPreparationError.headChanged(expected: expected, actual: headSHA)
        }

        var commentURL: URL?
        var commentBody: String?
        if let permalink = request.commentPermalink {
            let permalinkURL = try permalinkURL(permalink)
            let canonical = try await apiClient.fetchCommentContext(
                repository: repository,
                permalink: permalinkURL
            )
            if let canonicalNumber = canonical.pullRequestNumber, canonicalNumber != number {
                throw CommentShortcutPreparationError.contextMismatch(
                    "the comment belongs to #\(canonicalNumber), not #\(number)"
                )
            }
            commentURL = canonical.url ?? permalinkURL
            commentBody = canonical.body
        }

        let prURL = URL(string: "https://github.com/\(repository)/pull/\(number)")
        let values = CommentShortcutValues(
            context: context,
            repository: repository,
            prNumber: number,
            prURL: prURL,
            headSHA: headSHA,
            commentURL: commentURL,
            commentBody: commentBody
        )

        let draft: String
        do {
            draft = try shortcut.render(with: values)
        } catch {
            throw CommentShortcutPreparationError.templateFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        return CommentShortcutDraft(
            shortcutID: shortcut.id,
            context: context,
            repository: repository,
            prNumber: number,
            prURL: prURL?.absoluteString,
            headSHA: headSHA,
            diffURL: prURL?.appendingPathComponent("files").absoluteString,
            commentURL: commentURL?.absoluteString,
            commentBody: commentBody,
            draft: draft
        )
    }

    /// Advertises only metadata, so a page can never read or alter a template.
    static func catalog(from configuration: Configuration) -> [CommentShortcutDescriptor] {
        configuration.commentShortcuts
            .filter(\.isEnabled)
            .map {
                CommentShortcutDescriptor(
                    id: $0.id,
                    displayName: $0.displayName,
                    contexts: $0.contexts.isEmpty ? CommentShortcutContext.allCases : Array($0.contexts),
                    repositoryScopes: $0.repositoryScopes
                )
            }
    }

    private static func context(for permalink: String?) throws -> CommentShortcutContext {
        guard let permalink, !permalink.isEmpty else { return .pullRequest }
        let fragment = URL(string: permalink)?.fragment ?? ""
        if fragment.hasPrefix("discussion_") { return .reviewComment }
        if fragment.hasPrefix("issuecomment-") { return .issueComment }
        throw CommentShortcutPreparationError.contextMismatch("the comment link is not a supported comment")
    }

    private static func permalinkURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw CommentShortcutPreparationError.contextMismatch("the comment link is not a URL")
        }
        return url
    }
}

extension PRManager {
    /// Resolves a comment draft for the browser bridge. Read-only: it never posts.
    func prepareCommentShortcut(
        _ request: BrowserBridgeRouter.BrowserCommentShortcutRequest
    ) async throws -> CommentShortcutDraft {
        try await CommentShortcutPreparer.prepare(
            request: request,
            configuration: configuration,
            apiClient: apiClient
        )
    }

    func commentShortcutCatalog() -> [CommentShortcutDescriptor] {
        CommentShortcutPreparer.catalog(from: configuration)
    }
}
