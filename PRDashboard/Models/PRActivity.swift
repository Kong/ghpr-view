import Foundation

// MARK: - Account identity

/// Identity of a monitored GitHub account.
///
/// The GraphQL endpoint plus viewer node ID is the authoritative identity. The login
/// is display/search metadata only: a login can be renamed or reused, so it must never
/// be used as a storage key or to decide which account an observation belongs to.
struct MonitorAccountKey: Hashable, Codable {
    /// Normalized GraphQL endpoint. Empty string means the default GitHub endpoint.
    let endpoint: String
    /// Stable viewer node ID reported by GitHub (e.g. "MDQ6VXNlcjE=").
    let viewerNodeID: String
    /// Login observed when the account was first bound. Display and search only.
    var login: String

    init(endpoint: String, viewerNodeID: String, login: String) {
        self.endpoint = MonitorAccountKey.normalize(endpoint)
        self.viewerNodeID = viewerNodeID
        self.login = login
    }

    static func normalize(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix("/") { return String(trimmed.dropLast()) }
        return trimmed
    }

    var displayName: String { login.isEmpty ? viewerNodeID : login }

    /// Filesystem-safe, deterministic slug for the versioned store directory.
    var storageSlug: String {
        let host = URL(string: endpoint)?.host ?? "github.com"
        let safeHost = host.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let safeID = viewerNodeID.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return "\(String(safeHost))-\(String(safeID))"
    }
}

// MARK: - Monitored PR

/// Why the monitor keeps observing a PR. Multiple origins are kept per PR instead of
/// collapsing into a single `PRCategory`, because the user can be the author of a PR
/// that also has a direct review request.
enum MonitorOrigin: String, Codable, CaseIterable {
    case authored
    case requested
    case reviewed
    case commented
    /// Explicitly tracked by the user from the activity UI.
    case explicit
}

/// Data sources observed per monitored PR. Each source is acquired, versioned and
/// checkpointed independently so one failing source never invalidates the others.
enum MonitorSourceKind: String, Codable, CaseIterable {
    case header
    case reviews
    case conversationComments
    case reviewThreads
    case reviewRequests
    case ci
}

struct MonitorIncompleteReason: Codable, Equatable {
    enum Kind: String, Codable {
        case missingNode
        case missingCursor
        case repeatedCursor
        case nonTerminatingEmptyPage
        case graphQLErrors
        case httpError
        case rateLimited
        case notAuthorized
        case identityMismatch
        case headChanged
        case sourceChanged
        case cancelled
        case superseded
        case unavailable
    }

    let kind: Kind
    var statusCode: Int?
    var detail: String?
}

/// GitHub rejected a call because the token lacks a scope. `requiredAnyOf` means any
/// one listed scope would satisfy the query.
struct GitHubScopeDenial: Equatable {
    var requiredAnyOf: [String]
    var granted: [String]

    /// Collapsed warning text. Names the missing permission instead of `graphQLErrors`.
    var warningQualifier: String {
        String(localized: "missing scope: \(requiredAnyOf.joined(separator: " or "))")
    }

    var explanation: String {
        let grantedText = granted.joined(separator: ", ")
        if requiredAnyOf.count == 1, let only = requiredAnyOf.first {
            if grantedText.isEmpty {
                return String(localized: "Missing permission: \(only).")
            }
            return String(localized: "Missing permission: \(only). Current token: \(grantedText).")
        }
        let needed = requiredAnyOf.joined(separator: ", ")
        if grantedText.isEmpty {
            return String(localized: "Missing permission: one of \(needed).")
        }
        return String(localized: "Missing permission: one of \(needed). Current token: \(grantedText).")
    }

    static func parse(_ text: String) -> GitHubScopeDenial? {
        guard let required = scopeList(in: text, after: "requires one of the following scopes:") else {
            return nil
        }
        let granted = scopeList(in: text, after: "has only been granted the:") ?? []
        return GitHubScopeDenial(requiredAnyOf: required, granted: granted)
    }

    private static func scopeList(in text: String, after marker: String) -> [String]? {
        guard let markerRange = text.range(of: marker, options: .caseInsensitive) else { return nil }
        let tail = text[markerRange.upperBound...]
        guard let open = tail.firstIndex(of: "["),
              let close = tail[open...].firstIndex(of: "]") else {
            return nil
        }
        let scopes = tail[tail.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { token -> String? in
                let unquoted = token
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                return unquoted.isEmpty ? nil : unquoted
            }
        return scopes.isEmpty ? nil : scopes
    }
}

extension MonitorIncompleteReason {
    var scopeDenial: GitHubScopeDenial? {
        guard let detail else { return nil }
        return GitHubScopeDenial.parse(detail)
    }

    /// Qualifier shown in the collapsed observation warning.
    var warningQualifier: String {
        scopeDenial?.warningQualifier ?? kind.rawValue
    }

    /// Detail shown when the warning is expanded. Scope denials name the missing
    /// permission instead of repeating GitHub's raw paragraph.
    var warningDetail: String? {
        if let denial = scopeDenial {
            return denial.explanation
        }
        return detail
    }
}

/// A persisted, complete view of one source for one PR.
struct MonitorSourcePayload: Codable, Equatable {
    var header: MonitorHeaderSnapshot?
    var reviews: [MonitorReview]?
    var conversationComments: [MonitorConversationComment]?
    var reviewThreads: [MonitorReviewThread]?
    var reviewRequests: MonitorReviewRequestSnapshot?
    var ci: MonitorCISnapshot?
}

struct MonitorHeaderSnapshot: Codable, Equatable {
    var state: PRState
    var isDraft: Bool
    var title: String
    var url: URL?
    var headOID: String?
    var baseRefName: String?
    var headRefName: String?
    var updatedAt: Date
    var isArchived: Bool?
}

struct MonitorReview: Codable, Equatable, Identifiable {
    let id: String
    var author: String?
    var authorNodeID: String?
    /// Raw GitHub review state (APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED).
    /// PENDING reviews are never stored here: they are not submitted reviews.
    var state: String
    var body: String
    var url: URL?
    var submittedAt: Date?
    var commitOID: String?

    var isDismissed: Bool { state == ReviewState.dismissed.rawValue }
}

struct MonitorConversationComment: Codable, Equatable, Identifiable {
    let id: String
    var author: String?
    var authorNodeID: String?
    var body: String
    var url: URL?
    var createdAt: Date
    var lastEditedAt: Date?
}

struct MonitorThreadComment: Codable, Equatable, Identifiable {
    let id: String
    /// Review that published this comment, when GitHub reports one.
    var reviewID: String?
    var author: String?
    var authorNodeID: String?
    var body: String
    var url: URL?
    var createdAt: Date
    var lastEditedAt: Date?
    /// Parent comment inside the same thread. nil for the thread root comment.
    var replyToID: String?
    var path: String?
    var line: Int?
}

struct MonitorReviewThread: Codable, Equatable, Identifiable {
    let id: String
    var isResolved: Bool
    /// Outdated is not resolved: an outdated thread can still be unresolved.
    var isOutdated: Bool
    var path: String?
    var line: Int?
    var comments: [MonitorThreadComment]

    var rootCommentID: String? { comments.first?.id }
}

struct MonitorReviewRequest: Codable, Equatable, Identifiable {
    enum TargetType: String, Codable {
        case user
        case team
    }

    let id: String
    var targetType: TargetType
    var login: String
    var nodeID: String?
    /// True when this request targets the monitored viewer directly.
    var isViewer: Bool
    var requestedAt: Date?
}

/// A `ReviewRequestedEvent` with a stable ID, used to detect a *new* re-request
/// instead of inferring one from an incomplete list diff.
struct MonitorReviewRequestEvent: Codable, Equatable, Identifiable {
    let id: String
    var targetType: MonitorReviewRequest.TargetType
    var login: String
    var nodeID: String?
    var isViewer: Bool
    var createdAt: Date
}

struct MonitorReviewRequestSnapshot: Codable, Equatable {
    var requests: [MonitorReviewRequest]
    var events: [MonitorReviewRequestEvent]
}

struct MonitorCheckRun: Codable, Equatable, Identifiable {
    enum Origin: String, Codable {
        case actionsJob
        case checkRun
        case statusContext
    }

    let id: String
    var origin: Origin
    var name: String
    var workflowName: String?
    var runID: String?
    var runAttempt: Int?
    var headOID: String?
    var status: String
    var conclusion: String?
    var url: URL?
    var startedAt: Date?
    var completedAt: Date?

    var isFailure: Bool {
        guard let conclusion else { return false }
        return MonitorCheckRun.failureConclusions.contains(conclusion.uppercased())
    }

    var isSuccessful: Bool { conclusion?.uppercased() == "SUCCESS" }

    static let failureConclusions: Set<String> = [
        "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE",
    ]
}

struct MonitorCISnapshot: Codable, Equatable {
    var headOID: String?
    var checks: [MonitorCheckRun]
}

/// Result of acquiring one source: either a complete snapshot or an explicit reason
/// why the source is not complete. Incomplete sources never advance a checkpoint.
struct MonitorSourceObservation: Codable, Equatable {
    let source: MonitorSourceKind
    var isComplete: Bool
    var incompleteReason: MonitorIncompleteReason?
    /// Present only when `isComplete`.
    var payload: MonitorSourcePayload?
    var observedAt: Date
}

struct MonitorPRObservation: Codable, Equatable {
    let prNodeID: String
    var reference: PullRequestReference
    var observations: [MonitorSourceObservation]
    /// Head OID captured while acquiring, used to reject results that arrive after
    /// the PR moved on.
    var capturedHeadOID: String?
    var capturedAt: Date

    func observation(for source: MonitorSourceKind) -> MonitorSourceObservation? {
        observations.first { $0.source == source }
    }
}

/// Discovery coverage per origin search. Search only discovers; it never deletes.
struct MonitorDiscoveryCoverage: Codable, Equatable {
    struct QueryResult: Codable, Equatable {
        var origin: MonitorOrigin
        var isComplete: Bool
        var incompleteReason: MonitorIncompleteReason?
        var referenceCount: Int
    }

    var queries: [QueryResult]
    var attemptedAt: Date

    var isComplete: Bool { queries.allSatisfy(\.isComplete) }
    var incompleteOrigins: [MonitorOrigin] { queries.filter { !$0.isComplete }.map(\.origin) }
}

// MARK: - Committed checkpoints

/// Compact, body-free record of the last complete observation of one source. Only
/// what event derivation needs is stored: bodies would make the store grow without
/// bound on busy PRs, and mention detection is evaluated on the fresh payload.
struct CheckpointReview: Codable, Equatable {
    let id: String
    var author: String?
    var authorNodeID: String?
    var state: String
    var submittedAt: Date?
    var commitOID: String?
}

struct CheckpointComment: Codable, Equatable {
    let id: String
    var author: String?
    var authorNodeID: String?
    var isBot: Bool
    var createdAt: Date
    var lastEditedAt: Date?
    /// Whether this comment directly mentions the monitored viewer.
    var mentionsViewer: Bool
}

struct CheckpointThread: Codable, Equatable {
    let id: String
    var isResolved: Bool
    var isOutdated: Bool
    var path: String?
    var line: Int?
    /// Comment IDs in thread order.
    var commentIDs: [String]
    var rootAuthorNodeID: String?
    /// Every distinct comment author in the thread, used for "my thread" relevance.
    var participantNodeIDs: [String]
}

struct CheckpointReviewRequests: Codable, Equatable {
    var requestIDs: [String]
    var eventIDs: [String]
}

struct CheckpointCheck: Codable, Equatable {
    let id: String
    var origin: MonitorCheckRun.Origin
    var name: String
    var runID: String?
    var runAttempt: Int?
    var headOID: String?
    var status: String
    var conclusion: String?
    var url: URL?

    var isFailed: Bool {
        guard let conclusion else { return false }
        return MonitorCheckRun.failureConclusions.contains(conclusion.uppercased())
    }

    var isSuccessful: Bool { conclusion?.uppercased() == "SUCCESS" }
}

struct CheckpointCI: Codable, Equatable {
    var headOID: String?
    var checks: [CheckpointCheck]
}

struct MonitorSourceCheckpoint: Codable, Equatable {
    var header: MonitorHeaderSnapshot?
    var reviews: [CheckpointReview]?
    var conversationComments: [CheckpointComment]?
    var threads: [CheckpointThread]?
    var reviewRequests: CheckpointReviewRequests?
    var ci: CheckpointCI?
}

struct MonitoredPR: Codable, Equatable {
    let prNodeID: String
    var reference: PullRequestReference
    var origins: Set<MonitorOrigin>
    var isExplicitlyTracked: Bool
    /// Event kinds to watch when explicitly tracked. nil means "use defaults".
    var trackedEventKinds: Set<PRActivityEventKind>?
    /// Last lifecycle state confirmed by a complete header snapshot.
    var lifecycle: PRState
    var title: String
    var url: URL?
    var headOID: String?
    var discoveredAt: Date
    var lastObservedAt: Date
    var lastCompleteObservationAt: Date?
    /// Per-source change sequence, keyed by `MonitorSourceKind.rawValue`. Incremented
    /// inside the same transaction that commits new events for that source.
    var sourceSequences: [String: Int]
    /// Sources whose last acquisition did not complete, with the reason to display.
    var unhealthySources: [String: MonitorIncompleteReason]
    /// Last committed complete observation per source, keyed by `MonitorSourceKind.rawValue`.
    var checkpoints: [String: MonitorSourceCheckpoint]

    init(
        prNodeID: String,
        reference: PullRequestReference,
        origins: Set<MonitorOrigin>,
        isExplicitlyTracked: Bool = false,
        trackedEventKinds: Set<PRActivityEventKind>? = nil,
        lifecycle: PRState = .open,
        title: String = "",
        url: URL? = nil,
        headOID: String? = nil,
        discoveredAt: Date,
        lastObservedAt: Date,
        lastCompleteObservationAt: Date? = nil,
        sourceSequences: [String: Int] = [:],
        unhealthySources: [String: MonitorIncompleteReason] = [:],
        checkpoints: [String: MonitorSourceCheckpoint] = [:]
    ) {
        self.prNodeID = prNodeID
        self.reference = reference
        self.origins = origins
        self.isExplicitlyTracked = isExplicitlyTracked
        self.trackedEventKinds = trackedEventKinds
        self.lifecycle = lifecycle
        self.title = title
        self.url = url
        self.headOID = headOID
        self.discoveredAt = discoveredAt
        self.lastObservedAt = lastObservedAt
        self.lastCompleteObservationAt = lastCompleteObservationAt
        self.sourceSequences = sourceSequences
        self.unhealthySources = unhealthySources
        self.checkpoints = checkpoints
    }

    func checkpoint(for source: MonitorSourceKind) -> MonitorSourceCheckpoint? {
        checkpoints[source.rawValue]
    }

    mutating func setCheckpoint(_ checkpoint: MonitorSourceCheckpoint, for source: MonitorSourceKind) {
        checkpoints[source.rawValue] = checkpoint
    }

    func sequence(for source: MonitorSourceKind) -> Int {
        sourceSequences[source.rawValue] ?? 0
    }

    mutating func setSequence(_ value: Int, for source: MonitorSourceKind) {
        sourceSequences[source.rawValue] = value
    }

    func unhealthyReason(for source: MonitorSourceKind) -> MonitorIncompleteReason? {
        unhealthySources[source.rawValue]
    }

    mutating func setUnhealthy(_ reason: MonitorIncompleteReason?, for source: MonitorSourceKind) {
        if let reason {
            unhealthySources[source.rawValue] = reason
        } else {
            unhealthySources.removeValue(forKey: source.rawValue)
        }
    }
}

// MARK: - Events

enum PRActivityEventKind: String, Codable, CaseIterable {
    case reviewSubmitted
    case reviewDismissed
    case reviewCommentAdded
    case threadReplyAdded
    case threadResolved
    case threadReopened
    case conversationCommentAdded
    case conversationCommentEdited
    case reviewRequested
    case pushedNewCommit
    case prClosed
    case prMerged
    case prReopened
    case directMention
    case ciCheckFailed
    case ciCheckRecovered
    case ciCheckRerunStarted

    /// Kinds that can never on their own qualify as an actionable item.
    var isStatusOnly: Bool {
        switch self {
        case .ciCheckRecovered, .ciCheckRerunStarted:
            return true
        default:
            return false
        }
    }
}

/// The PR revision an event belongs to. Used to expire action items whose revision
/// was replaced, and to decide whether a later observation still applies.
struct PRActivityRevision: Codable, Equatable {
    var headOID: String?
    var reviewID: String?
    var threadID: String?
    var commentID: String?
    var runID: String?
    var runAttempt: Int?
    var checkID: String?

    static let empty = PRActivityRevision()

    init(
        headOID: String? = nil,
        reviewID: String? = nil,
        threadID: String? = nil,
        commentID: String? = nil,
        runID: String? = nil,
        runAttempt: Int? = nil,
        checkID: String? = nil
    ) {
        self.headOID = headOID
        self.reviewID = reviewID
        self.threadID = threadID
        self.commentID = commentID
        self.runID = runID
        self.runAttempt = runAttempt
        self.checkID = checkID
    }
}

struct PRActivityEvent: Codable, Equatable, Identifiable {
    /// Stable identity: source identity + the source change sequence that produced it.
    /// A repeated complete snapshot produces no new sequence, therefore no new event.
    let id: String
    /// Identity of the underlying source object, e.g. "reviews:<reviewID>:DISMISSED".
    let identityKey: String
    let kind: PRActivityEventKind
    let prNodeID: String
    let reference: PullRequestReference
    let actor: String?
    let actorNodeID: String?
    /// True when the monitored viewer performed the action; such events never notify.
    let isFromViewer: Bool
    /// True when the affected source object belongs to the viewer (for example the
    /// viewer's own review was dismissed, or the viewer's thread got a reply). This is
    /// what makes an event relevant even though somebody else performed it.
    let subjectIsViewer: Bool
    let isBotActor: Bool
    let containsDirectMention: Bool
    let occurredAt: Date
    let url: URL?
    let revision: PRActivityRevision
    /// Source change sequence this event was derived from, persisted with the event.
    let sourceChangeSequence: Int

    static func identity(
        prNodeID: String,
        identityKey: String,
        sequence: Int
    ) -> String {
        "\(prNodeID)|\(identityKey)|\(sequence)"
    }
}

// MARK: - Action items

/// Why an event concerns the user. Recorded without any AI judgement.
enum PRActionReason: String, Codable, CaseIterable {
    case authoredPRReviewFeedback
    case authoredPRCIFailure
    case authoredPRDirectMention
    case myApprovalDismissed
    case myThreadReply
    case myThreadResolved
    case myReviewNeedsRereview
    case reviewRequestedDirectly
    case explicitlyTracked
}

/// Suggested manual action. Never executed automatically.
enum PRActionKind: String, Codable {
    case reviewFeedback
    case fixCI
    case respondToMention
    case reReview
    case resolveThread
    case confirmCI
    case review
}

enum PRActionState: String, Codable {
    case open
    case handled
    case snoozed
    case superseded
    case recovered
    case rerunInProgress
}

struct PRActionItem: Codable, Equatable, Identifiable {
    let id: String
    let prNodeID: String
    var reference: PullRequestReference
    /// Reasons merged into this item (a single PR can be action-worthy for several reasons).
    var reasons: [PRActionReason]
    var actionKinds: [PRActionKind]
    var eventIDs: [String]
    var revision: PRActivityRevision
    var state: PRActionState
    var createdAt: Date
    var stateUpdatedAt: Date
    var snoozedUntil: Date?
    /// Event IDs that were visible when the user marked this handled/snoozed.
    /// Later events always produce a new item, so handling never hides new work.
    var coveredEventIDs: [String]
    /// Evidence links derived from the covered events.
    var evidenceURLs: [URL]

    /// Events that arrived after the user has already handled or snoozed this item.
    var pendingEventIDs: [String] {
        let covered = Set(coveredEventIDs)
        return eventIDs.filter { !covered.contains($0) }
    }

    /// True while this item still needs the user's attention. A snoozed item comes
    /// back only after its snooze expires, and only when new events are not pending
    /// (a new event reopens the item immediately: snoozing covers the shown version).
    func isActionable(now: Date) -> Bool {
        switch state {
        case .open:
            return true
        case .snoozed:
            guard let snoozedUntil else { return true }
            return snoozedUntil <= now
        case .handled, .superseded, .recovered, .rerunInProgress:
            return false
        }
    }
}

// MARK: - Digest

enum DigestChannel: String, Codable, CaseIterable {
    case macOS
    case slack
}

enum DigestDeliveryStatus: String, Codable {
    case pending
    case sending
    case delivered
    case failed
    /// Request may or may not have been received (timeout / crash during send).
    case unknown
}

struct DigestReceipt: Codable, Equatable {
    var channelID: String?
    var workspace: String?
    var messageTimestamp: String?
    var recipientUserID: String?
}

struct DigestDelivery: Codable, Equatable {
    var channel: DigestChannel
    var status: DigestDeliveryStatus
    var attemptedAt: Date?
    var completedAt: Date?
    var receipt: DigestReceipt?
    var failureMessage: String?
    /// Binding of the target this batch was created for. A batch is never delivered to
    /// a different workspace/recipient after a configuration or account switch.
    var targetWorkspace: String?
    var targetUserID: String?
}

struct DigestEntry: Codable, Equatable, Identifiable {
    var id: String { prNodeID }
    let prNodeID: String
    let reference: PullRequestReference
    let title: String
    var reasons: [PRActionReason]
    var actionKinds: [PRActionKind]
    var changeKinds: [PRActivityEventKind]
    var eventCount: Int
    var actionItemIDs: [String]
    var evidenceURLs: [URL]
}

struct DigestBatch: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    var entries: [DigestEntry]
    var coveredEventIDs: [String]
    var coveredActionItemIDs: [String]
    var omittedEntryCount: Int
    var deliveries: [DigestDelivery]

    func delivery(for channel: DigestChannel) -> DigestDelivery? {
        deliveries.first { $0.channel == channel }
    }
}

/// Persisted scheduler state for the global digest window.
struct DigestSchedulerState: Codable, Equatable {
    var lastAutoDigestAt: Date?
    var lastAutoDigestBatchID: String?
    /// Event IDs already included in an automated digest, so the same work is not
    /// re-announced while it stays open.
    var announcedEventIDs: [String]
    /// Batches whose delivery outcome is not fully known and that the user can inspect.
    var batches: [DigestBatch]

    static let empty = DigestSchedulerState(
        lastAutoDigestAt: nil,
        lastAutoDigestBatchID: nil,
        announcedEventIDs: [],
        batches: []
    )
}

// MARK: - Aggregate state

/// Everything the monitor persists for one account.
struct PRActivityAccountState: Codable, Equatable {
    var schemaVersion: Int
    var account: MonitorAccountKey
    var monitoredPRs: [MonitoredPR]
    /// Activity history. Never pruned by marking something handled.
    var events: [PRActivityEvent]
    var actionItems: [PRActionItem]
    var digest: DigestSchedulerState
    /// Coverage of the most recent discovery pass, keyed per origin search.
    var discoveryCoverage: MonitorDiscoveryCoverage?
    /// Set once the first complete observation per PR has silently established a baseline.
    var hasEstablishedBaseline: Bool
    var updatedAt: Date

    static let currentSchemaVersion = 1

    init(account: MonitorAccountKey, updatedAt: Date) {
        self.schemaVersion = PRActivityAccountState.currentSchemaVersion
        self.account = account
        self.monitoredPRs = []
        self.events = []
        self.actionItems = []
        self.digest = .empty
        self.discoveryCoverage = nil
        self.hasEstablishedBaseline = false
        self.updatedAt = updatedAt
    }

    func pr(_ prNodeID: String) -> MonitoredPR? {
        monitoredPRs.first { $0.prNodeID == prNodeID }
    }

    /// Items that still need attention at `now` (open, or snoozed past its expiry).
    func actionableItems(now: Date) -> [PRActionItem] {
        actionItems.filter { $0.isActionable(now: now) }
    }
}
