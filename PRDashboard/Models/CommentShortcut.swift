import Foundation

/// Where a comment shortcut can be used.
enum CommentShortcutContext: String, Codable, CaseIterable {
    /// New top-level comment on the PR conversation.
    case pullRequest
    /// Reply to a conversation (issue) comment on the PR.
    case issueComment
    /// Reply to an inline review comment in a review thread.
    case reviewComment

    var displayName: String {
        switch self {
        case .pullRequest: return String(localized: "PR comment")
        case .issueComment: return String(localized: "Conversation reply")
        case .reviewComment: return String(localized: "Review comment reply")
        }
    }
}

/// User-defined comment template. Replaces team/org specific automation: the whole
/// feature is configuration, with an empty default.
struct CommentShortcut: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var template: String
    /// Contexts this shortcut offers itself in. Empty means every context.
    var contexts: Set<CommentShortcutContext>
    /// `owner/repo` scopes. Empty means every repository.
    var repositoryScopes: [String]
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        displayName: String,
        template: String,
        contexts: Set<CommentShortcutContext> = [],
        repositoryScopes: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.template = template
        self.contexts = contexts
        self.repositoryScopes = repositoryScopes
        self.isEnabled = isEnabled
    }

    func applies(to context: CommentShortcutContext, repository: String) -> Bool {
        guard isEnabled else { return false }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if !contexts.isEmpty, !contexts.contains(context) { return false }
        if !repositoryScopes.isEmpty {
            let normalized = repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = repositoryScopes.contains { scope in
                scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
            }
            guard matches else { return false }
        }
        return true
    }

    /// Renders the template with already-validated context values.
    func render(with values: CommentShortcutValues) throws -> String {
        try CommentShortcutTemplate.render(template: template, values: values)
    }
}

/// Template variables available to a shortcut. Deliberately closed: anything else is
/// an error rather than being replaced by empty text from another PR.
enum CommentShortcutVariable: String, CaseIterable {
    case repository
    case pr_number
    case pr_url
    case head_sha
    case diff_url
    case comment_url
    case comment_body

    var isCommentOnly: Bool {
        switch self {
        case .comment_url, .comment_body: return true
        default: return false
        }
    }
}

/// Canonical values resolved from the current account's API (never from the page).
struct CommentShortcutValues: Equatable {
    let context: CommentShortcutContext
    let repository: String
    let prNumber: Int
    let prURL: URL?
    let headSHA: String?
    let commentURL: URL?
    let commentBody: String?

    func value(for variable: CommentShortcutVariable) throws -> String {
        switch variable {
        case .repository:
            return repository
        case .pr_number:
            return String(prNumber)
        case .pr_url:
            return try requireString(prURL?.absoluteString, for: variable)
        case .head_sha:
            return try requireString(headSHA, for: variable)
        case .diff_url:
            guard let prURL else {
                throw CommentShortcutError.missingContext(variable: variable.rawValue, context: context)
            }
            return prURL.appendingPathComponent("files").absoluteString
        case .comment_url:
            guard context != .pullRequest else {
                throw CommentShortcutError.variableNotAvailableInContext(
                    variable: variable.rawValue,
                    context: context
                )
            }
            return try requireString(commentURL?.absoluteString, for: variable)
        case .comment_body:
            guard context != .pullRequest else {
                throw CommentShortcutError.variableNotAvailableInContext(
                    variable: variable.rawValue,
                    context: context
                )
            }
            return try requireString(commentBody, for: variable)
        }
    }

    private func requireString(_ value: String?, for variable: CommentShortcutVariable) throws -> String {
        guard let value, !value.isEmpty else {
            throw CommentShortcutError.missingContext(variable: variable.rawValue, context: context)
        }
        return value
    }
}

enum CommentShortcutError: LocalizedError, Equatable {
    case emptyTemplate
    case malformedPlaceholder(String)
    case unknownVariable(String)
    case missingContext(variable: String, context: CommentShortcutContext)
    case variableNotAvailableInContext(variable: String, context: CommentShortcutContext)

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return String(localized: "The shortcut template is empty.")
        case .malformedPlaceholder(let text):
            return String(localized: "Malformed template placeholder: \(text)")
        case .unknownVariable(let name):
            return String(localized: "Unknown template variable: \(name)")
        case .missingContext(let variable, _):
            return String(localized: "Cannot resolve \(variable) for the current comment.")
        case .variableNotAvailableInContext(let variable, _):
            return String(localized: "\(variable) is only available when replying to a comment.")
        }
    }
}

enum CommentShortcutTemplate {
    static let openDelimiter = "{{"
    static let closeDelimiter = "}}"

    static func render(template: String, values: CommentShortcutValues) throws -> String {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommentShortcutError.emptyTemplate
        }

        var output = ""
        var remainder = Substring(template)
        while let openRange = remainder.range(of: openDelimiter) {
            output += remainder[remainder.startIndex..<openRange.lowerBound]
            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: closeDelimiter) else {
                throw CommentShortcutError.malformedPlaceholder(
                    String(remainder[openRange.lowerBound...])
                )
            }
            let name = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let variable = CommentShortcutVariable(rawValue: name) else {
                throw CommentShortcutError.unknownVariable(String(name))
            }
            output += try values.value(for: variable)
            remainder = afterOpen[closeRange.upperBound...]
        }
        output += remainder
        return output
    }

    /// Template validation for the settings UI. Returns nil when the template is valid.
    static func validate(template: String) -> CommentShortcutError? {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyTemplate
        }
        var remainder = Substring(template)
        while let openRange = remainder.range(of: openDelimiter) {
            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: closeDelimiter) else {
                return .malformedPlaceholder(String(remainder[openRange.lowerBound...]))
            }
            let name = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard CommentShortcutVariable(rawValue: name) != nil else {
                return .unknownVariable(String(name))
            }
            remainder = afterOpen[closeRange.upperBound...]
        }
        return nil
    }

    static func placeholders(in template: Substring) -> [CommentShortcutVariable] {
        var found: [CommentShortcutVariable] = []
        var remainder = template
        while let openRange = remainder.range(of: openDelimiter) {
            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: closeDelimiter) else { break }
            let name = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let variable = CommentShortcutVariable(rawValue: name), !found.contains(variable) {
                found.append(variable)
            }
            remainder = afterOpen[closeRange.upperBound...]
        }
        return found
    }
}
