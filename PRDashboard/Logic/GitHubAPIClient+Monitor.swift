import Foundation
import os

private let monitorLogger = Logger(subsystem: "com.prdashboard", category: "MonitorAcquisition")

// MARK: - Limits

private enum MonitorAcquisitionLimit {
    /// Page size for monitor searches, connections and REST pagination.
    static let pageSize = 100
    /// Aliased sub-queries per batch request.
    static let batchSize = 20
    /// Batched requests allowed in flight at once.
    static let maxInFlight = 3
    /// Headroom below which the monitor stops instead of risking a truncated read.
    static let rateLimitFloor = 200
    /// GitHub search refuses to page past 1,000 results for a single query.
    static let searchResultCap = 1000
    /// Earliest year that can contain a pull request; lower bound of the created-at
    /// windows used to work around the search result cap.
    static let searchFloorYear = 2008
    /// Upper bound on the sub-windows produced by splitting one year or month window.
    static let maximumSubWindows = 40
    /// Safety valve so a misbehaving paginated connection cannot loop forever.
    static let maximumPages = 100
}

private func monitorIncomplete(
    _ kind: MonitorIncompleteReason.Kind,
    _ detail: String? = nil,
    statusCode: Int? = nil
) -> MonitorIncompleteReason {
    MonitorIncompleteReason(kind: kind, statusCode: statusCode, detail: detail)
}

private extension MonitorIncompleteReason {
    /// Maps a thrown error onto the persisted "source is not complete" reason. Decode
    /// and other unexpected failures become GraphQL errors so partially decoded data
    /// can never look like a complete checkpoint.
    static func monitorReason(for error: Error) -> MonitorIncompleteReason {
        if let transportError = error as? MonitorTransportError {
            return transportError.incompleteReason
        }
        return monitorIncomplete(.graphQLErrors, "\(error)")
    }
}

// MARK: - Transport primitives

private struct MonitorAliasedRequest {
    var query: String
    var variables: [String: Any]
}

/// Per-alias result of one aliased batch request.
private enum MonitorAliasOutcome<Payload> {
    case payload(Payload)
    case incomplete(MonitorIncompleteReason)
}

/// Per-PR result of a single-read helper (focused head read, REST pages).
private enum MonitorFetched<Value> {
    case value(Value)
    case incomplete(MonitorIncompleteReason)
}

private struct MonitorBatchOutcome: Sendable {
    var prNodeID: String
    var source: MonitorSourceKind
    var observation: MonitorSourceObservation
}

/// Immutable inputs shared by every source collector of one acquisition pass.
private struct MonitorObservationContext: Sendable {
    var viewerNodeID: String
    /// Head OID captured by the header phase, keyed by PR node ID.
    var capturedHeads: [String: String]
    var observedAt: Date
}

private struct MonitorBatchPassResult: Sendable {
    var outcomes: [MonitorBatchOutcome]
    var stoppedForRateLimit: Bool
}

private struct MonitorThreadCommentsCursor {
    var prNodeID: String
    var threadID: String
    var cursor: String
}

// MARK: - Discovery payloads

private struct MonitorViewerPayload: Decodable {
    struct Viewer: Decodable {
        let id: String
        let login: String
        let databaseId: Int?
    }

    struct DataContainer: Decodable {
        let viewer: Viewer
    }

    let data: DataContainer
}

private struct MonitorSearchPayload: Decodable {
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Owner: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct CommitInfo: Decodable {
        let oid: String?
    }

    struct CommitNode: Decodable {
        let commit: CommitInfo
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL?
        let state: PRState
        let isDraft: Bool?
        let headRefOid: String?
        let updatedAt: Date
        let repository: Repository
        let commits: CommitsContainer?
    }

    struct Search: Decodable {
        let issueCount: Int
        let pageInfo: PageInfo?
        let nodes: [Node]
    }

    struct DataContainer: Decodable {
        let search: Search
    }

    let data: DataContainer
}

private struct MonitorSearchPage {
    var issueCount: Int
    var nodes: [MonitorSearchPayload.Node]
    var hasNextPage: Bool
    var endCursor: String?
}

private struct MonitorSearchReadResult {
    var issueCount: Int
    var nodes: [MonitorSearchPayload.Node]
    var exceededResultCap: Bool
    var reason: MonitorIncompleteReason?
}

private enum MonitorSearchWindowUnit {
    case year
    case month
    case day

    var narrower: MonitorSearchWindowUnit? {
        switch self {
        case .year: return .month
        case .month: return .day
        case .day: return nil
        }
    }

    var component: Calendar.Component {
        switch self {
        case .year: return .year
        case .month: return .month
        case .day: return .day
        }
    }
}

private struct MonitorSearchWindow {
    var start: Date
    /// Inclusive upper bound; windows use the bounded `created:A..B` search form.
    var end: Date
    var unit: MonitorSearchWindowUnit
}

private struct MonitorDiscoveredRecord {
    var reference: PullRequestReference
    var title: String
    var url: URL?
    var lifecycle: PRState
    var headOID: String?
    var updatedAt: Date
    var origins: Set<MonitorOrigin>
}

/// Mutable state for one discovery pass. `queriesIssued` lets the very first query of
/// the pass abort discovery while later failures only degrade a single origin.
private final class MonitorDiscoveryRunState {
    var queriesIssued = 0
}

private final class MonitorDiscoveryAccumulator {
    private var records: [String: MonitorDiscoveredRecord] = [:]
    private var referenceIDsByOrigin: [MonitorOrigin: Set<String>] = [:]

    func add(nodes: [MonitorSearchPayload.Node], origin: MonitorOrigin) {
        for node in nodes {
            let reference = PullRequestReference(
                owner: node.repository.owner.login,
                repo: node.repository.name,
                number: node.number
            )
            let headOID = node.commits?.nodes.first?.commit.oid ?? node.headRefOid
            if var existing = records[node.id] {
                // A PR matched by several searches keeps the union of its origins.
                existing.origins.insert(origin)
                if existing.headOID == nil { existing.headOID = headOID }
                records[node.id] = existing
            } else {
                records[node.id] = MonitorDiscoveredRecord(
                    reference: reference,
                    title: node.title,
                    url: node.url,
                    lifecycle: node.state,
                    headOID: headOID,
                    updatedAt: node.updatedAt,
                    origins: [origin]
                )
            }
            referenceIDsByOrigin[origin, default: []].insert(node.id)
        }
    }

    func referenceCount(for origin: MonitorOrigin) -> Int {
        referenceIDsByOrigin[origin]?.count ?? 0
    }

    var discovered: [MonitorDiscoveryOutcome.DiscoveredReference] {
        records
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { nodeID, record in
                MonitorDiscoveryOutcome.DiscoveredReference(
                    prNodeID: nodeID,
                    reference: record.reference,
                    title: record.title,
                    url: record.url,
                    lifecycle: record.lifecycle,
                    headOID: record.headOID,
                    updatedAt: record.updatedAt,
                    origins: record.origins
                )
            }
    }
}

// MARK: - Observation payloads

private struct MonitorCommitInfo: Decodable {
    let oid: String?
}

private struct MonitorCommitNode: Decodable {
    let commit: MonitorCommitInfo
}

private struct MonitorCommitsContainer: Decodable {
    let nodes: [MonitorCommitNode]
}

private struct MonitorPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct MonitorHeaderPayload: Decodable {
    struct RepositoryMeta: Decodable {
        let isArchived: Bool?
    }

    struct PullRequest: Decodable {
        let id: String
        let state: PRState
        let isDraft: Bool
        let title: String
        let url: URL?
        let baseRefName: String?
        let headRefName: String?
        let updatedAt: Date
        let repository: RepositoryMeta?
        let commits: MonitorCommitsContainer?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorReviewNode: Decodable {
    struct Author: Decodable {
        let login: String?
        let id: String?
    }

    struct Commit: Decodable {
        let oid: String?
    }

    let id: String
    let author: Author?
    let state: String
    let body: String?
    let url: URL?
    let submittedAt: Date?
    let commit: Commit?
}

private struct MonitorReviewsPayload: Decodable {
    struct Reviews: Decodable {
        let nodes: [MonitorReviewNode]
        let pageInfo: MonitorPageInfo?
    }

    struct PullRequest: Decodable {
        let reviews: Reviews?
        let commits: MonitorCommitsContainer?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorCommentNode: Decodable {
    struct Author: Decodable {
        let login: String?
        let id: String?
    }

    let id: String
    let author: Author?
    let body: String?
    let url: URL?
    let createdAt: Date
    let lastEditedAt: Date?
}

private struct MonitorConversationCommentsPayload: Decodable {
    struct Comments: Decodable {
        let nodes: [MonitorCommentNode]
        let pageInfo: MonitorPageInfo?
    }

    struct PullRequest: Decodable {
        let comments: Comments?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorThreadCommentNode: Decodable {
    struct Author: Decodable {
        let login: String?
        let id: String?
    }

    struct ReplyTo: Decodable {
        let id: String?
    }

    struct Review: Decodable {
        let id: String?
        let state: String?
    }

    let id: String
    let author: Author?
    let body: String?
    let url: URL?
    let createdAt: Date
    let lastEditedAt: Date?
    let replyTo: ReplyTo?
    let path: String?
    let line: Int?
    let pullRequestReview: Review?
}

private struct MonitorThreadCommentsPage: Decodable {
    let nodes: [MonitorThreadCommentNode]
    let pageInfo: MonitorPageInfo?
}

private struct MonitorThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String?
    let line: Int?
    let comments: MonitorThreadCommentsPage
}

private struct MonitorReviewThreadsPayload: Decodable {
    struct Threads: Decodable {
        let nodes: [MonitorThreadNode]
        let pageInfo: MonitorPageInfo?
    }

    struct PullRequest: Decodable {
        let reviewThreads: Threads?
        let commits: MonitorCommitsContainer?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

/// Continuation of one review thread's comments, read through `node(id:)`.
private struct MonitorThreadCommentsPayload: Decodable {
    let id: String?
    let comments: MonitorThreadCommentsPage?
}

private struct MonitorReviewer: Decodable {
    let id: String?
    let login: String?
    let slug: String?
    let name: String?
    /// Present when the selection asks for it. Team reviewers are identified this way
    /// because reading Team fields requires an org scope this app does not request.
    let typename: String?

    enum CodingKeys: String, CodingKey {
        case id, login, slug, name
        case typename = "__typename"
    }
}

private struct MonitorReviewRequestNode: Decodable {
    let id: String
    let requestedReviewer: MonitorReviewer?
}

private struct MonitorReviewRequestsPayload: Decodable {
    struct Requests: Decodable {
        let nodes: [MonitorReviewRequestNode]
        let pageInfo: MonitorPageInfo?
    }

    struct PullRequest: Decodable {
        let reviewRequests: Requests?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorTimelineEventNode: Decodable {
    let id: String
    let createdAt: Date?
    let requestedReviewer: MonitorReviewer?
}

private struct MonitorTimelinePageInfo: Decodable {
    let hasPreviousPage: Bool
    let startCursor: String?
}

private struct MonitorTimelinePayload: Decodable {
    struct Items: Decodable {
        let nodes: [MonitorTimelineEventNode]
        let pageInfo: MonitorTimelinePageInfo?
    }

    struct PullRequest: Decodable {
        let timelineItems: Items?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorHeadOnlyPayload: Decodable {
    struct PullRequest: Decodable {
        let commits: MonitorCommitsContainer?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

private struct MonitorStandaloneCheckNode: Decodable {
    struct CheckSuite: Decodable {
        struct WorkflowRun: Decodable {
            let databaseId: Int?
            let runAttempt: Int?
        }

        let workflowRun: WorkflowRun?
    }

    let id: String?
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: URL?
    let checkSuite: CheckSuite?
    let context: String?
    let state: String?
    let targetUrl: URL?
}

private struct MonitorRollupContexts: Decodable {
    let nodes: [MonitorStandaloneCheckNode]
    let pageInfo: MonitorPageInfo?
}

private struct MonitorRollup: Decodable {
    let contexts: MonitorRollupContexts?
}

private struct MonitorCheckCommitInfo: Decodable {
    let oid: String?
    let statusCheckRollup: MonitorRollup?
}

private struct MonitorStatusCheckRollupPayload: Decodable {
    struct CommitNode: Decodable {
        let commit: MonitorCheckCommitInfo
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct PullRequest: Decodable {
        let commits: CommitsContainer?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    let repository: Repository?
}

// MARK: - REST payloads

private struct MonitorWorkflowRunsPage: Decodable {
    let totalCount: Int
    let workflowRuns: [MonitorWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

private struct MonitorWorkflowRun: Decodable {
    let id: Int
    let name: String?
    let workflowName: String?
    let runAttempt: Int?
    let status: String?
    let conclusion: String?
    let headSha: String?
    let htmlUrl: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case workflowName = "workflow_name"
        case runAttempt = "run_attempt"
        case status
        case conclusion
        case headSha = "head_sha"
        case htmlUrl = "html_url"
    }
}

private struct MonitorWorkflowJobsPage: Decodable {
    let totalCount: Int
    let jobs: [MonitorWorkflowJob]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case jobs
    }
}

private struct MonitorWorkflowJob: Decodable {
    let id: Int
    let name: String?
    let workflowName: String?
    let runAttempt: Int?
    let status: String?
    let conclusion: String?
    let htmlUrl: URL?
    let startedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case workflowName = "workflow_name"
        case runAttempt = "run_attempt"
        case status
        case conclusion
        case htmlUrl = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - Monitor acquisition

extension GitHubAPIClient: MonitorAcquisitionProviding {
    var rateLimitHeadroom: RateLimitInfo { rateLimitInfo }

    // MARK: Viewer identity

    func fetchViewerIdentity() async throws -> MonitorViewerIdentity {
        let data = try await monitorExecuteGraphQL(
            query: Self.monitorViewerIdentityQuery,
            operation: "MonitorViewerIdentity"
        )
        let payload = try JSONDecoder.githubDecoder.decode(MonitorViewerPayload.self, from: data)
        return MonitorViewerIdentity(
            nodeID: payload.data.viewer.id,
            login: payload.data.viewer.login,
            databaseID: payload.data.viewer.databaseId
        )
    }

    // MARK: Discovery

    func fetchMonitorDiscovery(
        scope: MonitorDiscoveryScope
    ) async throws -> MonitorDiscoveryOutcome {
        let viewer = try await fetchViewerIdentity()
        let accumulator = MonitorDiscoveryAccumulator()
        let state = MonitorDiscoveryRunState()
        var coverage: [MonitorDiscoveryCoverage.QueryResult] = []
        var stoppedForRateLimit = false

        for (origin, searchQuery) in Self.monitorDiscoveryQueries(scope: scope, login: viewer.login) {
            if stoppedForRateLimit {
                coverage.append(
                    MonitorDiscoveryCoverage.QueryResult(
                        origin: origin,
                        isComplete: false,
                        incompleteReason: monitorIncomplete(.rateLimited, "rate limit headroom exhausted"),
                        referenceCount: accumulator.referenceCount(for: origin)
                    )
                )
                continue
            }

            let reason: MonitorIncompleteReason?
            do {
                reason = try await monitorDiscoverOrigin(
                    origin: origin,
                    searchQuery: searchQuery,
                    state: state,
                    accumulator: accumulator
                )
            } catch {
                // Only a failure of the very first query of the pass lands here:
                // without a single usable search, discovery has nothing to report.
                monitorLogger.error(
                    "Monitor discovery aborted before any search completed: \(String(describing: error), privacy: .public)"
                )
                throw error
            }

            if reason?.kind == .rateLimited {
                stoppedForRateLimit = true
            } else if let reason {
                monitorLogger.warning(
                    "Monitor discovery origin \(origin.rawValue, privacy: .public) incomplete: \(reason.kind.rawValue, privacy: .public)"
                )
            }

            coverage.append(
                MonitorDiscoveryCoverage.QueryResult(
                    origin: origin,
                    isComplete: reason == nil,
                    incompleteReason: reason,
                    referenceCount: accumulator.referenceCount(for: origin)
                )
            )
        }

        return MonitorDiscoveryOutcome(
            discovered: accumulator.discovered,
            coverage: MonitorDiscoveryCoverage(queries: coverage, attemptedAt: Date())
        )
    }

    /// Reads one origin search in full, splitting by created-at windows when the
    /// result set exceeds the search cap. Throws only for the first query of the pass.
    private func monitorDiscoverOrigin(
        origin: MonitorOrigin,
        searchQuery: String,
        state: MonitorDiscoveryRunState,
        accumulator: MonitorDiscoveryAccumulator
    ) async throws -> MonitorIncompleteReason? {
        let probe = try await monitorReadSearchQuery(
            searchQuery: searchQuery,
            state: state,
            stopOverResultCap: MonitorAcquisitionLimit.searchResultCap
        )
        accumulator.add(nodes: probe.nodes, origin: origin)
        if let reason = probe.reason { return reason }
        guard probe.exceededResultCap else { return nil }

        // More than 1,000 results for one query: re-read the origin over bounded
        // created-at windows so each individual query stays under the cap.
        var reason: MonitorIncompleteReason?
        var pending = Self.monitorInitialSearchWindows(now: Date())

        while let window = pending.popLast() {
            let windowQuery = searchQuery
                + " created:\(Self.monitorSearchDate(window.start))..\(Self.monitorSearchDate(window.end))"
            let read = try await monitorReadSearchQuery(
                searchQuery: windowQuery,
                state: state,
                stopOverResultCap: MonitorAcquisitionLimit.searchResultCap
            )

            if read.exceededResultCap {
                guard let narrower = window.unit.narrower else {
                    return monitorIncomplete(.missingCursor, "search window exceeded 1000 results")
                }
                // Partial pages of an over-cap window are dropped on purpose: the
                // narrower windows read the same range completely.
                pending.append(contentsOf: Self.monitorSplitSearchWindow(window, into: narrower))
                continue
            }

            accumulator.add(nodes: read.nodes, origin: origin)
            if let readReason = read.reason {
                if readReason.kind == .rateLimited { return readReason }
                reason = reason ?? readReason
            }
        }

        return reason
    }

    /// Reads every page of one search query. Cursor anomalies and transport failures
    /// are reported in `reason`; only the first query of the pass is thrown.
    private func monitorReadSearchQuery(
        searchQuery: String,
        state: MonitorDiscoveryRunState,
        stopOverResultCap: Int?
    ) async throws -> MonitorSearchReadResult {
        var nodes: [MonitorSearchPayload.Node] = []
        var visitedCursors = Set<String>()
        var cursor: String?
        var issueCount = 0
        var pageCount = 0

        while true {
            if (await monitorRemainingHeadroom()) < MonitorAcquisitionLimit.rateLimitFloor {
                monitorLogger.warning("Monitor discovery stopping: rate limit headroom exhausted")
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: monitorIncomplete(.rateLimited, "rate limit headroom exhausted")
                )
            }
            if pageCount >= MonitorAcquisitionLimit.maximumPages {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: monitorIncomplete(.missingCursor, "search pagination exceeded the page limit")
                )
            }

            let issuedBefore = state.queriesIssued
            let page: MonitorSearchPage
            do {
                page = try await monitorSearchPage(searchQuery: searchQuery, cursor: cursor, state: state)
            } catch {
                if issuedBefore == 0 { throw error }
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: MonitorIncompleteReason.monitorReason(for: error)
                )
            }
            pageCount += 1

            issueCount = page.issueCount
            nodes.append(contentsOf: page.nodes)

            if let cap = stopOverResultCap, issueCount > cap {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: true,
                    reason: nil
                )
            }

            guard page.hasNextPage else {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: nil
                )
            }

            if page.nodes.isEmpty {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: monitorIncomplete(
                        .nonTerminatingEmptyPage,
                        "search returned an empty page that still reports more results"
                    )
                )
            }

            guard let next = page.endCursor, !next.isEmpty else {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: monitorIncomplete(.missingCursor, "search reported more results without a cursor")
                )
            }

            guard visitedCursors.insert(next).inserted else {
                return MonitorSearchReadResult(
                    issueCount: issueCount,
                    nodes: nodes,
                    exceededResultCap: false,
                    reason: monitorIncomplete(.repeatedCursor, "search repeated cursor \(next)")
                )
            }

            cursor = next
        }
    }

    private func monitorSearchPage(
        searchQuery: String,
        cursor: String?,
        state: MonitorDiscoveryRunState
    ) async throws -> MonitorSearchPage {
        var variables: [String: Any] = ["q": searchQuery]
        if let cursor {
            variables["cursor"] = cursor
        }
        state.queriesIssued += 1

        let data = try await monitorExecuteGraphQL(
            query: Self.monitorSearchQuery,
            operation: "MonitorDiscovery",
            variables: variables
        )
        do {
            let payload = try JSONDecoder.githubDecoder.decode(MonitorSearchPayload.self, from: data)
            return MonitorSearchPage(
                issueCount: payload.data.search.issueCount,
                nodes: payload.data.search.nodes,
                hasNextPage: payload.data.search.pageInfo?.hasNextPage ?? false,
                endCursor: payload.data.search.pageInfo?.endCursor
            )
        } catch {
            throw MonitorTransportError.graphQLErrors(["monitor search decode failed: \(error)"])
        }
    }

    // MARK: Observations

    func fetchMonitorObservations(
        for prs: [MonitoredPR],
        viewer: MonitorViewerIdentity,
        sources: Set<MonitorSourceKind>
    ) async -> MonitorSnapshotOutcome {
        guard !prs.isEmpty, !sources.isEmpty else { return .empty }
        let capturedAt = Date()

        var collected: [String: [MonitorSourceKind: MonitorSourceObservation]] = [:]
        var deferralReason: MonitorIncompleteReason?

        // The header is always read: it captures the head every revision-bound source
        // is validated against, and it fills `capturedHeadOID` even when the caller did
        // not request the header source itself.
        let headerPass = await monitorRunSourcePass(
            source: .header,
            prs: prs,
            context: MonitorObservationContext(
                viewerNodeID: viewer.nodeID,
                capturedHeads: [:],
                observedAt: capturedAt
            )
        )
        monitorMerge(headerPass.outcomes, into: &collected)

        var capturedHeads: [String: String] = [:]
        for outcome in headerPass.outcomes {
            if let payload = outcome.observation.payload,
               let headOID = payload.header?.headOID {
                capturedHeads[outcome.prNodeID] = headOID
            }
        }

        var stoppedForRateLimit = headerPass.stoppedForRateLimit
        if stoppedForRateLimit {
            deferralReason = monitorIncomplete(.rateLimited, "rate limit headroom exhausted")
            monitorLogger.warning("Monitor acquisition stopped after the header pass: rate limit headroom exhausted")
        } else {
            let context = MonitorObservationContext(
                viewerNodeID: viewer.nodeID,
                capturedHeads: capturedHeads,
                observedAt: capturedAt
            )
            for source in MonitorSourceKind.allCases where sources.contains(source) && source != .header {
                let pass = await monitorRunSourcePass(source: source, prs: prs, context: context)
                monitorMerge(pass.outcomes, into: &collected)
                if pass.stoppedForRateLimit {
                    stoppedForRateLimit = true
                    deferralReason = monitorIncomplete(.rateLimited, "rate limit headroom exhausted")
                    break
                }
            }
        }

        let emittedAt = Date()
        let cancelled = Task.isCancelled
        let observations = prs.map { pr -> MonitorPRObservation in
            let sourceObservations = MonitorSourceKind.allCases
                .filter { sources.contains($0) }
                .map { source -> MonitorSourceObservation in
                    if let observation = collected[pr.prNodeID]?[source] {
                        return observation
                    }
                    if let deferralReason {
                        return MonitorSourceObservation(
                            source: source,
                            isComplete: false,
                            incompleteReason: deferralReason,
                            payload: nil,
                            observedAt: emittedAt
                        )
                    }
                    if cancelled {
                        return MonitorSourceObservation(
                            source: source,
                            isComplete: false,
                            incompleteReason: monitorIncomplete(.cancelled, "acquisition cancelled"),
                            payload: nil,
                            observedAt: emittedAt
                        )
                    }
                    // Unreachable: every requested source is attempted unless the pass
                    // stopped. A source that was never read is never reported complete.
                    monitorLogger.warning(
                        "Monitor source \(source.rawValue, privacy: .public) was never attempted for a PR"
                    )
                    return MonitorSourceObservation(
                        source: source,
                        isComplete: false,
                        incompleteReason: monitorIncomplete(.unavailable, "source was not attempted"),
                        payload: nil,
                        observedAt: emittedAt
                    )
                }
            // A PR whose header read failed still captured a head in the CI source
            // through its focused head read, so late results are rejected for it too.
            let capturedHeadOID = capturedHeads[pr.prNodeID]
                ?? collected[pr.prNodeID]?[.ci]?.payload?.ci?.headOID
            return MonitorPRObservation(
                prNodeID: pr.prNodeID,
                reference: pr.reference,
                observations: sourceObservations,
                capturedHeadOID: capturedHeadOID,
                capturedAt: capturedAt
            )
        }

        return MonitorSnapshotOutcome(observations: observations, deferralReason: deferralReason)
    }

    private func monitorMerge(
        _ outcomes: [MonitorBatchOutcome],
        into collected: inout [String: [MonitorSourceKind: MonitorSourceObservation]]
    ) {
        for outcome in outcomes {
            collected[outcome.prNodeID, default: [:]][outcome.source] = outcome.observation
        }
    }

    /// Runs one source over every PR in batches, with at most three requests in flight
    /// and a rate-limit check before every batch that is about to start.
    private func monitorRunSourcePass(
        source: MonitorSourceKind,
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> MonitorBatchPassResult {
        let batches = Self.monitorChunk(prs, size: MonitorAcquisitionLimit.batchSize)
        var outcomes: [MonitorBatchOutcome] = []
        var stoppedForRateLimit = false

        await withTaskGroup(of: MonitorBatchPassResult.self) { group in
            var index = 0
            var inFlight = 0

            while inFlight < MonitorAcquisitionLimit.maxInFlight, index < batches.count {
                guard await monitorHasHeadroom() else {
                    stoppedForRateLimit = true
                    break
                }
                let batch = batches[index]
                index += 1
                group.addTask { [self] in
                    let produced = await self.monitorCollectBatch(source: source, prs: batch, context: context)
                    return MonitorBatchPassResult(outcomes: produced, stoppedForRateLimit: false)
                }
                inFlight += 1
            }

            while let produced = await group.next() {
                outcomes.append(contentsOf: produced.outcomes)
                inFlight -= 1
                guard !stoppedForRateLimit, index < batches.count else { continue }
                guard await monitorHasHeadroom() else {
                    stoppedForRateLimit = true
                    continue
                }
                let batch = batches[index]
                index += 1
                group.addTask { [self] in
                    let produced = await self.monitorCollectBatch(source: source, prs: batch, context: context)
                    return MonitorBatchPassResult(outcomes: produced, stoppedForRateLimit: false)
                }
                inFlight += 1
            }
        }

        if stoppedForRateLimit {
            monitorLogger.warning(
                "Monitor source \(source.rawValue, privacy: .public) stopped early: rate limit headroom exhausted"
            )
        }
        return MonitorBatchPassResult(outcomes: outcomes, stoppedForRateLimit: stoppedForRateLimit)
    }

    private func monitorCollectBatch(
        source: MonitorSourceKind,
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        switch source {
        case .header:
            return await monitorCollectHeader(prs: prs, context: context)
        case .reviews:
            return await monitorCollectReviews(prs: prs, context: context)
        case .conversationComments:
            return await monitorCollectConversationComments(prs: prs, context: context)
        case .reviewThreads:
            return await monitorCollectReviewThreads(prs: prs, context: context)
        case .reviewRequests:
            return await monitorCollectReviewRequests(prs: prs, context: context)
        case .ci:
            return await monitorCollectCI(prs: prs, context: context)
        }
    }

    private func monitorHasHeadroom() async -> Bool {
        (await monitorRemainingHeadroom()) >= MonitorAcquisitionLimit.rateLimitFloor
    }

    private func monitorRemainingHeadroom() async -> Int {
        await MainActor.run { self.rateLimitInfo.remaining }
    }

    // MARK: Header

    private func monitorCollectHeader(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        let aliases = await monitorAliasedFirstPage(prs: prs, payloadType: MonitorHeaderPayload.self) { indices in
            Self.monitorBatchRequest(prs: prs, indices: indices, fieldSelection: Self.monitorHeaderFields)
        }

        return prs.enumerated().map { index, pr in
            switch aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "header alias missing")) {
            case .incomplete(let reason):
                return monitorIncompleteOutcome(pr: pr, source: .header, reason: reason, at: context.observedAt)
            case .payload(let payload):
                guard let pullRequest = payload.repository?.pullRequest else {
                    return monitorIncompleteOutcome(
                        pr: pr,
                        source: .header,
                        reason: monitorIncomplete(.missingNode, "pull request not found"),
                        at: context.observedAt
                    )
                }
                guard pullRequest.id == pr.prNodeID else {
                    return monitorIncompleteOutcome(
                        pr: pr,
                        source: .header,
                        reason: monitorIncomplete(.identityMismatch, "header node ID does not match the monitored PR"),
                        at: context.observedAt
                    )
                }
                let snapshot = MonitorHeaderSnapshot(
                    state: pullRequest.state,
                    isDraft: pullRequest.isDraft,
                    title: pullRequest.title,
                    url: pullRequest.url,
                    headOID: pullRequest.commits?.nodes.first?.commit.oid,
                    baseRefName: pullRequest.baseRefName,
                    headRefName: pullRequest.headRefName,
                    updatedAt: pullRequest.updatedAt,
                    isArchived: pullRequest.repository?.isArchived
                )
                return MonitorBatchOutcome(
                    prNodeID: pr.prNodeID,
                    source: .header,
                    observation: MonitorSourceObservation(
                        source: .header,
                        isComplete: true,
                        incompleteReason: nil,
                        payload: MonitorSourcePayload(header: snapshot),
                        observedAt: context.observedAt
                    )
                )
            }
        }
    }

    // MARK: Reviews

    private func monitorCollectReviews(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        let aliases = await monitorAliasedFirstPage(prs: prs, payloadType: MonitorReviewsPayload.self) { indices in
            Self.monitorBatchRequest(
                prs: prs,
                indices: indices,
                fieldSelection: Self.monitorReviewsFields(cursor: false)
            )
        }

        var outcomes: [MonitorBatchOutcome] = []
        for (index, pr) in prs.enumerated() {
            switch aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "reviews alias missing")) {
            case .incomplete(let reason):
                outcomes.append(monitorIncompleteOutcome(pr: pr, source: .reviews, reason: reason, at: context.observedAt))
            case .payload(let payload):
                guard let pullRequest = payload.repository?.pullRequest, let reviews = pullRequest.reviews else {
                    outcomes.append(
                        monitorIncompleteOutcome(
                            pr: pr,
                            source: .reviews,
                            reason: monitorIncomplete(.missingNode, "reviews missing"),
                            at: context.observedAt
                        )
                    )
                    continue
                }

                var collected = Self.monitorReviews(from: reviews.nodes)
                var reason = monitorHeadChangeReason(
                    observed: pullRequest.commits?.nodes.first?.commit.oid,
                    captured: context.capturedHeads[pr.prNodeID]
                )

                if reason == nil, reviews.pageInfo?.hasNextPage == true {
                    if reviews.nodes.isEmpty {
                        reason = monitorIncomplete(
                            .nonTerminatingEmptyPage,
                            "reviews returned an empty page that still reports more"
                        )
                    } else {
                        reason = await monitorCollectReviewPages(
                            pr: pr,
                            cursor: reviews.pageInfo?.endCursor,
                            accumulated: &collected,
                            capturedHead: context.capturedHeads[pr.prNodeID]
                        )
                    }
                }

                outcomes.append(
                    monitorSourceOutcome(
                        pr: pr,
                        source: .reviews,
                        reason: reason,
                        payload: MonitorSourcePayload(reviews: collected),
                        at: context.observedAt
                    )
                )
            }
        }
        return outcomes
    }

    private func monitorCollectReviewPages(
        pr: MonitoredPR,
        cursor: String?,
        accumulated: inout [MonitorReview],
        capturedHead: String?
    ) async -> MonitorIncompleteReason? {
        var cursor = cursor
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard let pageCursor = cursor, !pageCursor.isEmpty else {
                return monitorIncomplete(.missingCursor, "reviews reported more pages without a cursor")
            }
            guard visited.insert(pageCursor).inserted else {
                return monitorIncomplete(.repeatedCursor, "reviews repeated cursor \(pageCursor)")
            }
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return monitorIncomplete(.missingCursor, "reviews pagination exceeded the page limit")
            }
            pageCount += 1

            let request = Self.monitorSingleRequest(
                pr: pr,
                fieldSelection: Self.monitorReviewsFields(cursor: true),
                cursor: pageCursor
            )
            let payload: MonitorReviewsPayload?
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorReviewsPage",
                    variables: request.variables
                )
                payload = try monitorPayloadFromSingleAlias(data, as: MonitorReviewsPayload.self)
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            guard let reviews = payload?.repository?.pullRequest?.reviews else {
                return monitorIncomplete(.missingNode, "reviews page missing")
            }
            if reviews.nodes.isEmpty, reviews.pageInfo?.hasNextPage == true {
                return monitorIncomplete(.nonTerminatingEmptyPage, "reviews returned an empty page that still reports more")
            }
            if let reason = monitorHeadChangeReason(
                observed: payload?.repository?.pullRequest?.commits?.nodes.first?.commit.oid,
                captured: capturedHead
            ) {
                return reason
            }
            accumulated.append(contentsOf: Self.monitorReviews(from: reviews.nodes))

            guard reviews.pageInfo?.hasNextPage == true else { return nil }
            cursor = reviews.pageInfo?.endCursor
        }
    }

    // MARK: Conversation comments

    private func monitorCollectConversationComments(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        let aliases = await monitorAliasedFirstPage(
            prs: prs,
            payloadType: MonitorConversationCommentsPayload.self
        ) { indices in
            Self.monitorBatchRequest(
                prs: prs,
                indices: indices,
                fieldSelection: Self.monitorConversationCommentsFields(cursor: false)
            )
        }

        var outcomes: [MonitorBatchOutcome] = []
        for (index, pr) in prs.enumerated() {
            switch aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "comments alias missing")) {
            case .incomplete(let reason):
                outcomes.append(
                    monitorIncompleteOutcome(pr: pr, source: .conversationComments, reason: reason, at: context.observedAt)
                )
            case .payload(let payload):
                guard let comments = payload.repository?.pullRequest?.comments else {
                    outcomes.append(
                        monitorIncompleteOutcome(
                            pr: pr,
                            source: .conversationComments,
                            reason: monitorIncomplete(.missingNode, "conversation comments missing"),
                            at: context.observedAt
                        )
                    )
                    continue
                }

                var collected = Self.monitorConversationComments(from: comments.nodes)
                var reason: MonitorIncompleteReason?

                if comments.pageInfo?.hasNextPage == true {
                    if comments.nodes.isEmpty {
                        reason = monitorIncomplete(
                            .nonTerminatingEmptyPage,
                            "conversation comments returned an empty page that still reports more"
                        )
                    } else {
                        reason = await monitorCollectConversationCommentPages(
                            pr: pr,
                            cursor: comments.pageInfo?.endCursor,
                            accumulated: &collected
                        )
                    }
                }

                outcomes.append(
                    monitorSourceOutcome(
                        pr: pr,
                        source: .conversationComments,
                        reason: reason,
                        payload: MonitorSourcePayload(conversationComments: collected),
                        at: context.observedAt
                    )
                )
            }
        }
        return outcomes
    }

    private func monitorCollectConversationCommentPages(
        pr: MonitoredPR,
        cursor: String?,
        accumulated: inout [MonitorConversationComment]
    ) async -> MonitorIncompleteReason? {
        var cursor = cursor
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard let pageCursor = cursor, !pageCursor.isEmpty else {
                return monitorIncomplete(.missingCursor, "comments reported more pages without a cursor")
            }
            guard visited.insert(pageCursor).inserted else {
                return monitorIncomplete(.repeatedCursor, "comments repeated cursor \(pageCursor)")
            }
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return monitorIncomplete(.missingCursor, "comments pagination exceeded the page limit")
            }
            pageCount += 1

            let request = Self.monitorSingleRequest(
                pr: pr,
                fieldSelection: Self.monitorConversationCommentsFields(cursor: true),
                cursor: pageCursor
            )
            let payload: MonitorConversationCommentsPayload?
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorCommentsPage",
                    variables: request.variables
                )
                payload = try monitorPayloadFromSingleAlias(data, as: MonitorConversationCommentsPayload.self)
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            guard let comments = payload?.repository?.pullRequest?.comments else {
                return monitorIncomplete(.missingNode, "conversation comments page missing")
            }
            if comments.nodes.isEmpty, comments.pageInfo?.hasNextPage == true {
                return monitorIncomplete(
                    .nonTerminatingEmptyPage,
                    "conversation comments returned an empty page that still reports more"
                )
            }
            accumulated.append(contentsOf: Self.monitorConversationComments(from: comments.nodes))

            guard comments.pageInfo?.hasNextPage == true else { return nil }
            cursor = comments.pageInfo?.endCursor
        }
    }

    // MARK: Review threads

    private func monitorCollectReviewThreads(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        let aliases = await monitorAliasedFirstPage(prs: prs, payloadType: MonitorReviewThreadsPayload.self) { indices in
            Self.monitorBatchRequest(
                prs: prs,
                indices: indices,
                fieldSelection: Self.monitorReviewThreadsFields(cursor: false)
            )
        }

        var outcomes: [MonitorBatchOutcome] = []
        for (index, pr) in prs.enumerated() {
            switch aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "review threads alias missing")) {
            case .incomplete(let reason):
                outcomes.append(
                    monitorIncompleteOutcome(pr: pr, source: .reviewThreads, reason: reason, at: context.observedAt)
                )
            case .payload(let payload):
                guard let pullRequest = payload.repository?.pullRequest,
                      let threads = pullRequest.reviewThreads else {
                    outcomes.append(
                        monitorIncompleteOutcome(
                            pr: pr,
                            source: .reviewThreads,
                            reason: monitorIncomplete(.missingNode, "review threads missing"),
                            at: context.observedAt
                        )
                    )
                    continue
                }

                var collected = threads.nodes.map { Self.monitorReviewThread(from: $0) }
                var commentCursors = Self.monitorPendingCommentCursors(pr: pr, threads: threads.nodes)
                var reason = monitorHeadChangeReason(
                    observed: pullRequest.commits?.nodes.first?.commit.oid,
                    captured: context.capturedHeads[pr.prNodeID]
                )

                if reason == nil, threads.pageInfo?.hasNextPage == true {
                    if threads.nodes.isEmpty {
                        reason = monitorIncomplete(
                            .nonTerminatingEmptyPage,
                            "review threads returned an empty page that still reports more"
                        )
                    } else {
                        reason = await monitorCollectReviewThreadPages(
                            pr: pr,
                            cursor: threads.pageInfo?.endCursor,
                            accumulated: &collected,
                            commentCursors: &commentCursors,
                            capturedHead: context.capturedHeads[pr.prNodeID]
                        )
                    }
                }

                // A sixth or 101st reply lives past the first comment page of its own
                // thread, so every thread that reported more is read to the end.
                if reason == nil, !commentCursors.isEmpty {
                    reason = await monitorCollectThreadCommentPages(cursors: commentCursors, accumulated: &collected)
                }

                outcomes.append(
                    monitorSourceOutcome(
                        pr: pr,
                        source: .reviewThreads,
                        reason: reason,
                        payload: MonitorSourcePayload(reviewThreads: collected),
                        at: context.observedAt
                    )
                )
            }
        }
        return outcomes
    }

    private func monitorCollectReviewThreadPages(
        pr: MonitoredPR,
        cursor: String?,
        accumulated: inout [MonitorReviewThread],
        commentCursors: inout [MonitorThreadCommentsCursor],
        capturedHead: String?
    ) async -> MonitorIncompleteReason? {
        var cursor = cursor
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard let pageCursor = cursor, !pageCursor.isEmpty else {
                return monitorIncomplete(.missingCursor, "review threads reported more pages without a cursor")
            }
            guard visited.insert(pageCursor).inserted else {
                return monitorIncomplete(.repeatedCursor, "review threads repeated cursor \(pageCursor)")
            }
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return monitorIncomplete(.missingCursor, "review thread pagination exceeded the page limit")
            }
            pageCount += 1

            let request = Self.monitorSingleRequest(
                pr: pr,
                fieldSelection: Self.monitorReviewThreadsFields(cursor: true),
                cursor: pageCursor
            )
            let payload: MonitorReviewThreadsPayload?
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorReviewThreadsPage",
                    variables: request.variables
                )
                payload = try monitorPayloadFromSingleAlias(data, as: MonitorReviewThreadsPayload.self)
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            guard let threads = payload?.repository?.pullRequest?.reviewThreads else {
                return monitorIncomplete(.missingNode, "review threads page missing")
            }
            if threads.nodes.isEmpty, threads.pageInfo?.hasNextPage == true {
                return monitorIncomplete(
                    .nonTerminatingEmptyPage,
                    "review threads returned an empty page that still reports more"
                )
            }
            if let reason = monitorHeadChangeReason(
                observed: payload?.repository?.pullRequest?.commits?.nodes.first?.commit.oid,
                captured: capturedHead
            ) {
                return reason
            }

            accumulated.append(contentsOf: threads.nodes.map { Self.monitorReviewThread(from: $0) })
            commentCursors.append(contentsOf: Self.monitorPendingCommentCursors(pr: pr, threads: threads.nodes))

            guard threads.pageInfo?.hasNextPage == true else { return nil }
            cursor = threads.pageInfo?.endCursor
        }
    }

    /// Reads the remaining comment pages of every thread that reported more comments.
    private func monitorCollectThreadCommentPages(
        cursors: [MonitorThreadCommentsCursor],
        accumulated: inout [MonitorReviewThread]
    ) async -> MonitorIncompleteReason? {
        var pending = cursors
        var visited = Set<String>()

        while !pending.isEmpty {
            let batch = Array(pending.prefix(MonitorAcquisitionLimit.batchSize))
            pending.removeFirst(batch.count)

            let request = Self.monitorThreadCommentsRequest(cursors: batch)
            let data: Data
            do {
                data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorThreadCommentsPage",
                    variables: request.variables
                )
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            let aliases: [Int: MonitorAliasOutcome<MonitorThreadCommentsPayload>]
            do {
                aliases = try monitorDecodeAliases(
                    data,
                    payloadType: MonitorThreadCommentsPayload.self,
                    indices: Set(batch.indices),
                    repositoryAliased: false,
                    aliasName: Self.monitorThreadAliasName
                )
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            for (index, entry) in batch.enumerated() {
                let outcome = aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "review thread alias missing"))
                guard case .payload(let payload) = outcome else {
                    if case .incomplete(let reason) = outcome { return reason }
                    return monitorIncomplete(.missingNode, "review thread comments page missing")
                }
                guard let comments = payload.comments else {
                    return monitorIncomplete(.missingNode, "review thread comments page missing")
                }
                if comments.nodes.isEmpty, comments.pageInfo?.hasNextPage == true {
                    return monitorIncomplete(
                        .nonTerminatingEmptyPage,
                        "review thread comments returned an empty page that still reports more"
                    )
                }
                guard let threadIndex = accumulated.firstIndex(where: { $0.id == entry.threadID }) else {
                    return monitorIncomplete(.missingNode, "review thread \(entry.threadID) disappeared while reading replies")
                }
                accumulated[threadIndex].comments.append(contentsOf: comments.nodes.map { Self.monitorThreadComment(from: $0) })

                guard comments.pageInfo?.hasNextPage == true else { continue }
                guard let next = comments.pageInfo?.endCursor, !next.isEmpty else {
                    return monitorIncomplete(.missingCursor, "review thread comments reported more pages without a cursor")
                }
                guard visited.insert("\(entry.threadID):\(next)").inserted else {
                    return monitorIncomplete(.repeatedCursor, "review thread comments repeated cursor \(next)")
                }
                pending.append(
                    MonitorThreadCommentsCursor(prNodeID: entry.prNodeID, threadID: entry.threadID, cursor: next)
                )
            }
        }

        return nil
    }

    private static func monitorPendingCommentCursors(
        pr: MonitoredPR,
        threads: [MonitorThreadNode]
    ) -> [MonitorThreadCommentsCursor] {
        threads.compactMap { thread in
            guard thread.comments.pageInfo?.hasNextPage == true,
                  let cursor = thread.comments.pageInfo?.endCursor,
                  !cursor.isEmpty else {
                return nil
            }
            return MonitorThreadCommentsCursor(prNodeID: pr.prNodeID, threadID: thread.id, cursor: cursor)
        }
    }

    // MARK: Review requests

    private func monitorCollectReviewRequests(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        let aliases = await monitorAliasedFirstPage(prs: prs, payloadType: MonitorReviewRequestsPayload.self) { indices in
            Self.monitorBatchRequest(
                prs: prs,
                indices: indices,
                fieldSelection: Self.monitorReviewRequestsFields(cursor: false)
            )
        }

        var outcomes: [MonitorBatchOutcome] = []
        for (index, pr) in prs.enumerated() {
            switch aliases[index] ?? .incomplete(monitorIncomplete(.missingNode, "review requests alias missing")) {
            case .incomplete(let reason):
                outcomes.append(
                    monitorIncompleteOutcome(pr: pr, source: .reviewRequests, reason: reason, at: context.observedAt)
                )
            case .payload(let payload):
                guard let requests = payload.repository?.pullRequest?.reviewRequests else {
                    outcomes.append(
                        monitorIncompleteOutcome(
                            pr: pr,
                            source: .reviewRequests,
                            reason: monitorIncomplete(.missingNode, "review requests missing"),
                            at: context.observedAt
                        )
                    )
                    continue
                }

                var collected = Self.monitorReviewRequests(from: requests.nodes, viewerNodeID: context.viewerNodeID)
                var reason: MonitorIncompleteReason?

                if requests.pageInfo?.hasNextPage == true {
                    if requests.nodes.isEmpty {
                        reason = monitorIncomplete(
                            .nonTerminatingEmptyPage,
                            "review requests returned an empty page that still reports more"
                        )
                    } else {
                        reason = await monitorCollectReviewRequestPages(
                            pr: pr,
                            cursor: requests.pageInfo?.endCursor,
                            viewerNodeID: context.viewerNodeID,
                            accumulated: &collected
                        )
                    }
                }

                // The `ReviewRequestedEvent` timeline is what proves a *new* request:
                // a shorter list can also mean the request was withdrawn.
                var events: [MonitorReviewRequestEvent] = []
                if reason == nil {
                    switch await monitorCollectReviewRequestEvents(pr: pr, viewerNodeID: context.viewerNodeID) {
                    case .value(let collectedEvents):
                        events = collectedEvents
                    case .incomplete(let eventReason):
                        reason = eventReason
                    }
                }

                outcomes.append(
                    monitorSourceOutcome(
                        pr: pr,
                        source: .reviewRequests,
                        reason: reason,
                        payload: MonitorSourcePayload(
                            reviewRequests: MonitorReviewRequestSnapshot(requests: collected, events: events)
                        ),
                        at: context.observedAt
                    )
                )
            }
        }
        return outcomes
    }

    private func monitorCollectReviewRequestPages(
        pr: MonitoredPR,
        cursor: String?,
        viewerNodeID: String,
        accumulated: inout [MonitorReviewRequest]
    ) async -> MonitorIncompleteReason? {
        var cursor = cursor
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard let pageCursor = cursor, !pageCursor.isEmpty else {
                return monitorIncomplete(.missingCursor, "review requests reported more pages without a cursor")
            }
            guard visited.insert(pageCursor).inserted else {
                return monitorIncomplete(.repeatedCursor, "review requests repeated cursor \(pageCursor)")
            }
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return monitorIncomplete(.missingCursor, "review request pagination exceeded the page limit")
            }
            pageCount += 1

            let request = Self.monitorSingleRequest(
                pr: pr,
                fieldSelection: Self.monitorReviewRequestsFields(cursor: true),
                cursor: pageCursor
            )
            let payload: MonitorReviewRequestsPayload?
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorReviewRequestsPage",
                    variables: request.variables
                )
                payload = try monitorPayloadFromSingleAlias(data, as: MonitorReviewRequestsPayload.self)
            } catch {
                return MonitorIncompleteReason.monitorReason(for: error)
            }

            guard let requests = payload?.repository?.pullRequest?.reviewRequests else {
                return monitorIncomplete(.missingNode, "review requests page missing")
            }
            if requests.nodes.isEmpty, requests.pageInfo?.hasNextPage == true {
                return monitorIncomplete(
                    .nonTerminatingEmptyPage,
                    "review requests returned an empty page that still reports more"
                )
            }
            accumulated.append(contentsOf: Self.monitorReviewRequests(from: requests.nodes, viewerNodeID: viewerNodeID))

            guard requests.pageInfo?.hasNextPage == true else { return nil }
            cursor = requests.pageInfo?.endCursor
        }
    }

    /// Reads `REVIEW_REQUESTED_EVENT` timeline items backwards until the first one.
    private func monitorCollectReviewRequestEvents(
        pr: MonitoredPR,
        viewerNodeID: String
    ) async -> MonitorFetched<[MonitorReviewRequestEvent]> {
        var collected: [MonitorReviewRequestEvent] = []
        var cursor: String?
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return .incomplete(monitorIncomplete(.missingCursor, "review requested events exceeded the page limit"))
            }
            pageCount += 1

            let request = Self.monitorTimelineRequest(pr: pr, cursor: cursor)
            let payload: MonitorTimelinePayload
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorReviewRequestedEvents",
                    variables: request.variables
                )
                payload = try monitorDecodeDataObject(data, as: MonitorTimelinePayload.self)
            } catch {
                return .incomplete(MonitorIncompleteReason.monitorReason(for: error))
            }

            guard let items = payload.repository?.pullRequest?.timelineItems else {
                return .incomplete(monitorIncomplete(.missingNode, "review requested events missing"))
            }
            if items.nodes.isEmpty, items.pageInfo?.hasPreviousPage == true {
                return .incomplete(
                    monitorIncomplete(
                        .nonTerminatingEmptyPage,
                        "review requested events returned an empty page that still reports more"
                    )
                )
            }

            collected.append(contentsOf: items.nodes.map { node in
                let identity = Self.monitorReviewerIdentity(node.requestedReviewer)
                return MonitorReviewRequestEvent(
                    id: node.id,
                    targetType: identity.targetType,
                    login: identity.login,
                    nodeID: node.requestedReviewer?.id,
                    isViewer: identity.targetType == .user && node.requestedReviewer?.id == viewerNodeID,
                    createdAt: node.createdAt ?? Date(timeIntervalSince1970: 0)
                )
            })

            guard items.pageInfo?.hasPreviousPage == true else { return .value(collected) }
            guard let next = items.pageInfo?.startCursor, !next.isEmpty else {
                return .incomplete(
                    monitorIncomplete(.missingCursor, "review requested events reported more pages without a cursor")
                )
            }
            guard visited.insert(next).inserted else {
                return .incomplete(monitorIncomplete(.repeatedCursor, "review requested events repeated cursor \(next)"))
            }
            cursor = next
        }
    }

    // MARK: CI

    private func monitorCollectCI(
        prs: [MonitoredPR],
        context: MonitorObservationContext
    ) async -> [MonitorBatchOutcome] {
        var outcomes: [MonitorBatchOutcome] = []
        for pr in prs {
            outcomes.append(await monitorCollectCISource(pr: pr, context: context))
        }
        return outcomes
    }

    private func monitorCollectCISource(
        pr: MonitoredPR,
        context: MonitorObservationContext
    ) async -> MonitorBatchOutcome {
        let capturedHead = context.capturedHeads[pr.prNodeID]

        // The head the jobs are keyed to. The header pass normally supplies it; when
        // the header could not be read, a focused read still gives a usable revision.
        let headOID: String
        if let capturedHead {
            headOID = capturedHead
        } else {
            switch await monitorReadHead(pr: pr) {
            case .value(let oid):
                headOID = oid
            case .incomplete(let reason):
                return monitorIncompleteOutcome(pr: pr, source: .ci, reason: reason, at: context.observedAt)
            }
        }

        var checks: [MonitorCheckRun] = []
        switch await monitorFetchActionsJobs(pr: pr, headOID: headOID) {
        case .value(let jobs):
            checks.append(contentsOf: jobs)
        case .incomplete(let reason):
            return monitorIncompleteOutcome(pr: pr, source: .ci, reason: reason, at: context.observedAt)
        }

        // Standalone checks and statuses come from the rollup; Actions jobs are skipped
        // there because the REST jobs read above already cover them.
        var observedHead: String?
        switch await monitorFetchStandaloneChecks(pr: pr) {
        case .value(let result):
            checks.append(contentsOf: result.checks)
            observedHead = result.headOID
        case .incomplete(let reason):
            return monitorIncompleteOutcome(pr: pr, source: .ci, reason: reason, at: context.observedAt)
        }

        if let reason = monitorHeadChangeReason(observed: observedHead, captured: capturedHead) {
            return monitorIncompleteOutcome(pr: pr, source: .ci, reason: reason, at: context.observedAt)
        }

        return MonitorBatchOutcome(
            prNodeID: pr.prNodeID,
            source: .ci,
            observation: MonitorSourceObservation(
                source: .ci,
                isComplete: true,
                incompleteReason: nil,
                payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: headOID, checks: checks)),
                observedAt: context.observedAt
            )
        )
    }

    private func monitorReadHead(pr: MonitoredPR) async -> MonitorFetched<String> {
        let request = Self.monitorSingleRequest(
            pr: pr,
            fieldSelection: "commits(last: 1) { nodes { commit { oid } } }",
            cursor: nil
        )
        do {
            let data = try await monitorExecuteGraphQL(
                query: request.query,
                operation: "MonitorHead",
                variables: request.variables
            )
            let payload = try monitorPayloadFromSingleAlias(data, as: MonitorHeadOnlyPayload.self)
            guard let pullRequest = payload?.repository?.pullRequest else {
                return .incomplete(monitorIncomplete(.missingNode, "head read: pull request not found"))
            }
            guard let oid = pullRequest.commits?.nodes.first?.commit.oid else {
                return .incomplete(monitorIncomplete(.missingNode, "head read: no commit reported"))
            }
            return .value(oid)
        } catch {
            return .incomplete(MonitorIncompleteReason.monitorReason(for: error))
        }
    }

    /// Reads the raw Actions jobs of every run created for the captured head SHA.
    private func monitorFetchActionsJobs(
        pr: MonitoredPR,
        headOID: String
    ) async -> MonitorFetched<[MonitorCheckRun]> {
        var checks: [MonitorCheckRun] = []
        var page = 1
        var totalCount = Int.max

        while page <= MonitorAcquisitionLimit.maximumPages {
            let url = monitorActionsRunsURL(pr: pr, headOID: headOID, page: page)
            let pageResult = await monitorFetchREST(url: url, as: MonitorWorkflowRunsPage.self, operation: "actions runs")
            switch pageResult {
            case .incomplete(let reason):
                return .incomplete(reason)
            case .value(let runs):
                totalCount = runs.totalCount
                for run in runs.workflowRuns {
                    guard let runAttempt = run.runAttempt else {
                        return .incomplete(monitorIncomplete(.missingNode, "workflow run without an attempt number"))
                    }
                    let jobsResult = await monitorFetchActionsJobsPage(
                        pr: pr,
                        run: run,
                        runAttempt: runAttempt,
                        headOID: headOID
                    )
                    switch jobsResult {
                    case .incomplete(let reason):
                        return .incomplete(reason)
                    case .value(let jobChecks):
                        checks.append(contentsOf: jobChecks)
                    }
                }
                if runs.workflowRuns.isEmpty || page * MonitorAcquisitionLimit.pageSize >= totalCount {
                    return .value(checks)
                }
            }
            page += 1
        }

        return .incomplete(monitorIncomplete(.missingCursor, "actions runs pagination exceeded the page limit"))
    }

    private func monitorFetchActionsJobsPage(
        pr: MonitoredPR,
        run: MonitorWorkflowRun,
        runAttempt: Int,
        headOID: String
    ) async -> MonitorFetched<[MonitorCheckRun]> {
        var checks: [MonitorCheckRun] = []
        var page = 1
        var totalCount = Int.max

        while page <= MonitorAcquisitionLimit.maximumPages {
            let url = monitorActionsJobsURL(
                pr: pr,
                runID: run.id,
                runAttempt: runAttempt,
                page: page
            )
            let pageResult = await monitorFetchREST(url: url, as: MonitorWorkflowJobsPage.self, operation: "actions jobs")
            switch pageResult {
            case .incomplete(let reason):
                return .incomplete(reason)
            case .value(let jobs):
                totalCount = jobs.totalCount
                checks.append(
                    contentsOf: jobs.jobs.map { job in
                        MonitorCheckRun(
                            id: "job-\(job.id)",
                            origin: .actionsJob,
                            name: job.name ?? "job-\(job.id)",
                            workflowName: job.workflowName ?? run.workflowName ?? run.name,
                            runID: "\(run.id)",
                            runAttempt: runAttempt,
                            headOID: headOID,
                            status: job.status ?? "unknown",
                            conclusion: job.conclusion,
                            url: job.htmlUrl,
                            startedAt: job.startedAt,
                            completedAt: job.completedAt
                        )
                    }
                )
                if jobs.jobs.isEmpty || page * MonitorAcquisitionLimit.pageSize >= totalCount {
                    return .value(checks)
                }
            }
            page += 1
        }

        return .incomplete(monitorIncomplete(.missingCursor, "actions jobs pagination exceeded the page limit"))
    }

    private struct MonitorStandaloneChecks {
        var checks: [MonitorCheckRun]
        var headOID: String?
    }

    /// Reads the standalone checks and statuses of the PR's current head commit.
    private func monitorFetchStandaloneChecks(
        pr: MonitoredPR
    ) async -> MonitorFetched<MonitorStandaloneChecks> {
        var checks: [MonitorCheckRun] = []
        var headOID: String?
        var cursor: String?
        var visited = Set<String>()
        var pageCount = 0

        while true {
            guard pageCount < MonitorAcquisitionLimit.maximumPages else {
                return .incomplete(monitorIncomplete(.missingCursor, "check rollup exceeded the page limit"))
            }
            pageCount += 1

            let request = Self.monitorRollupRequest(pr: pr, cursor: cursor)
            let payload: MonitorStatusCheckRollupPayload
            do {
                let data = try await monitorExecuteGraphQL(
                    query: request.query,
                    operation: "MonitorStandaloneChecks",
                    variables: request.variables
                )
                payload = try monitorDecodeDataObject(data, as: MonitorStatusCheckRollupPayload.self)
            } catch {
                return .incomplete(MonitorIncompleteReason.monitorReason(for: error))
            }

            guard let commit = payload.repository?.pullRequest?.commits?.nodes.first?.commit else {
                return .incomplete(monitorIncomplete(.missingNode, "check rollup missing"))
            }
            if headOID == nil { headOID = commit.oid }

            guard let contexts = commit.statusCheckRollup?.contexts else {
                // No rollup at all is a legitimate empty result.
                return .value(MonitorStandaloneChecks(checks: checks, headOID: headOID))
            }
            if contexts.nodes.isEmpty, contexts.pageInfo?.hasNextPage == true {
                return .incomplete(
                    monitorIncomplete(.nonTerminatingEmptyPage, "check rollup returned an empty page that still reports more")
                )
            }

            switch Self.monitorStandaloneChecks(from: contexts.nodes) {
            case .value(let standalone):
                checks.append(contentsOf: standalone)
            case .incomplete(let reason):
                return .incomplete(reason)
            }

            guard contexts.pageInfo?.hasNextPage == true else {
                return .value(MonitorStandaloneChecks(checks: checks, headOID: headOID))
            }
            guard let next = contexts.pageInfo?.endCursor, !next.isEmpty else {
                return .incomplete(monitorIncomplete(.missingCursor, "check rollup reported more pages without a cursor"))
            }
            guard visited.insert(next).inserted else {
                return .incomplete(monitorIncomplete(.repeatedCursor, "check rollup repeated cursor \(next)"))
            }
            cursor = next
        }
    }

    /// REST read used by the CI source. Every response records rate-limit headers, and
    /// a rejected token is reported to the shared auth handler.
    private func monitorFetchREST<Value: Decodable>(
        url: URL?,
        as payloadType: Value.Type,
        operation: String
    ) async -> MonitorFetched<Value> {
        guard let url else {
            return .incomplete(monitorIncomplete(.unavailable, "\(operation): invalid URL"))
        }

        var request = URLRequest(url: url)
        let requestToken = monitorToken
        request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await monitorSession.data(for: request)
        } catch {
            if Task.isCancelled {
                return .incomplete(monitorIncomplete(.cancelled, "\(operation) cancelled"))
            }
            return .incomplete(MonitorTransportError.network(error).incompleteReason)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .incomplete(MonitorTransportError.invalidResponse.incompleteReason)
        }
        monitorRecordRateLimit(from: httpResponse)

        switch httpResponse.statusCode {
        case 200:
            do {
                return .value(try JSONDecoder.githubDecoder.decode(Value.self, from: data))
            } catch {
                return .incomplete(monitorIncomplete(.graphQLErrors, "\(operation) could not be decoded: \(error)"))
            }
        case 401:
            monitorReportUnauthorized(rejectedToken: requestToken)
            return .incomplete(MonitorTransportError.unauthorized.incompleteReason)
        case 403, 429:
            let remaining = await monitorRemainingHeadroom()
            if Self.monitorIsRateLimitResponse(statusCode: httpResponse.statusCode, data: data)
                || remaining == 0 {
                return .incomplete(
                    monitorIncomplete(.rateLimited, "\(operation) was rate limited", statusCode: httpResponse.statusCode)
                )
            }
            if Self.monitorIsAuthorizationFailure(data: data) {
                monitorReportUnauthorized(rejectedToken: requestToken)
                return .incomplete(MonitorTransportError.unauthorized.incompleteReason)
            }
            return .incomplete(monitorIncomplete(.httpError, "\(operation) failed", statusCode: httpResponse.statusCode))
        default:
            return .incomplete(monitorIncomplete(.httpError, "\(operation) failed", statusCode: httpResponse.statusCode))
        }
    }

    /// The client's own body inspection helpers are file-private, so the monitor
    /// classifies REST failures from the response body it reads itself.
    private static func monitorIsAuthorizationFailure(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("bad credentials")
            || text.contains("requires authentication")
            || text.contains("must authenticate")
    }

    private static func monitorIsRateLimitResponse(statusCode: Int, data: Data) -> Bool {
        if statusCode == 429 { return true }
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("rate limit") || text.contains("abuse")
    }

    private func monitorActionsRunsURL(pr: MonitoredPR, headOID: String, page: Int) -> URL? {
        monitorRESTURL(
            path: "/repos/\(pr.reference.owner)/\(pr.reference.repo)/actions/runs",
            queryItems: [
                URLQueryItem(name: "head_sha", value: headOID),
                URLQueryItem(name: "per_page", value: "\(MonitorAcquisitionLimit.pageSize)"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
        )
    }

    private func monitorActionsJobsURL(
        pr: MonitoredPR,
        runID: Int,
        runAttempt: Int,
        page: Int
    ) -> URL? {
        monitorRESTURL(
            path: "/repos/\(pr.reference.owner)/\(pr.reference.repo)/actions/runs/\(runID)/attempts/\(runAttempt)/jobs",
            queryItems: [
                URLQueryItem(name: "per_page", value: "\(MonitorAcquisitionLimit.pageSize)"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
        )
    }

    private func monitorRESTURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: monitorRESTBaseURL.absoluteString) else { return nil }
        components.path += path
        components.queryItems = queryItems
        return components.url
    }

    // MARK: Mapping helpers

    private func monitorIncompleteOutcome(
        pr: MonitoredPR,
        source: MonitorSourceKind,
        reason: MonitorIncompleteReason,
        at observedAt: Date
    ) -> MonitorBatchOutcome {
        MonitorBatchOutcome(
            prNodeID: pr.prNodeID,
            source: source,
            observation: MonitorSourceObservation(
                source: source,
                isComplete: false,
                incompleteReason: reason,
                payload: nil,
                observedAt: observedAt
            )
        )
    }

    private func monitorSourceOutcome(
        pr: MonitoredPR,
        source: MonitorSourceKind,
        reason: MonitorIncompleteReason?,
        payload: MonitorSourcePayload,
        at observedAt: Date
    ) -> MonitorBatchOutcome {
        guard let reason else {
            return MonitorBatchOutcome(
                prNodeID: pr.prNodeID,
                source: source,
                observation: MonitorSourceObservation(
                    source: source,
                    isComplete: true,
                    incompleteReason: nil,
                    payload: payload,
                    observedAt: observedAt
                )
            )
        }
        return monitorIncompleteOutcome(pr: pr, source: source, reason: reason, at: observedAt)
    }

    /// nil when the captured head is unknown (the header source already reports that as
    /// incomplete) or unchanged; a reason when the PR moved during the pass.
    private func monitorHeadChangeReason(observed: String?, captured: String?) -> MonitorIncompleteReason? {
        guard let observed, let captured, observed != captured else { return nil }
        return monitorIncomplete(.headChanged, "head moved from \(captured) to \(observed) during acquisition")
    }

    private static func monitorReviews(from nodes: [MonitorReviewNode]) -> [MonitorReview] {
        nodes.compactMap { node in
            // PENDING reviews are unpublished drafts: they are not submitted reviews.
            guard node.state != "PENDING" else { return nil }
            return MonitorReview(
                id: node.id,
                author: node.author?.login,
                authorNodeID: node.author?.id,
                state: node.state,
                body: node.body ?? "",
                url: node.url,
                submittedAt: node.submittedAt,
                commitOID: node.commit?.oid
            )
        }
    }

    private static func monitorConversationComments(from nodes: [MonitorCommentNode]) -> [MonitorConversationComment] {
        nodes.map { node in
            MonitorConversationComment(
                id: node.id,
                author: node.author?.login,
                authorNodeID: node.author?.id,
                body: node.body ?? "",
                url: node.url,
                createdAt: node.createdAt,
                lastEditedAt: node.lastEditedAt
            )
        }
    }

    private static func monitorReviewThread(from node: MonitorThreadNode) -> MonitorReviewThread {
        MonitorReviewThread(
            id: node.id,
            isResolved: node.isResolved,
            isOutdated: node.isOutdated,
            path: node.path,
            line: node.line,
            comments: node.comments.nodes.map { monitorThreadComment(from: $0) }
        )
    }

    private static func monitorThreadComment(from node: MonitorThreadCommentNode) -> MonitorThreadComment {
        MonitorThreadComment(
            id: node.id,
            reviewID: node.pullRequestReview?.id,
            author: node.author?.login,
            authorNodeID: node.author?.id,
            body: node.body ?? "",
            url: node.url,
            createdAt: node.createdAt,
            lastEditedAt: node.lastEditedAt,
            replyToID: node.replyTo?.id,
            path: node.path,
            line: node.line
        )
    }

    /// A team request is never the viewer's own direct request: only a User reviewer
    /// whose node ID equals the viewer's can be `isViewer`. Team identity comes from
    /// `__typename` so the query does not select org-scoped Team fields.
    private static func monitorReviewerIdentity(
        _ reviewer: MonitorReviewer?
    ) -> (targetType: MonitorReviewRequest.TargetType, login: String) {
        if reviewer?.typename == "Team" {
            if let slug = reviewer?.slug, !slug.isEmpty { return (.team, slug) }
            return (.team, reviewer?.name ?? "")
        }
        if let slug = reviewer?.slug, !slug.isEmpty {
            return (.team, slug)
        }
        if let login = reviewer?.login, !login.isEmpty {
            return (.user, login)
        }
        if let name = reviewer?.name, !name.isEmpty {
            return (.team, name)
        }
        return (.user, "")
    }

    private static func monitorReviewRequests(
        from nodes: [MonitorReviewRequestNode],
        viewerNodeID: String
    ) -> [MonitorReviewRequest] {
        nodes.map { node in
            let identity = monitorReviewerIdentity(node.requestedReviewer)
            return MonitorReviewRequest(
                id: node.id,
                targetType: identity.targetType,
                login: identity.login,
                nodeID: node.requestedReviewer?.id,
                isViewer: identity.targetType == .user && node.requestedReviewer?.id == viewerNodeID,
                requestedAt: nil
            )
        }
    }

    private static func monitorStandaloneChecks(
        from nodes: [MonitorStandaloneCheckNode]
    ) -> MonitorFetched<[MonitorCheckRun]> {
        var checks: [MonitorCheckRun] = []

        for node in nodes {
            guard let nodeID = node.id else {
                return .incomplete(monitorIncomplete(.missingNode, "check or status without a node ID"))
            }

            // StatusContext carries `context`/`state`; CheckRun carries `name`/`status`.
            if let state = node.state, node.context != nil || node.name == nil {
                checks.append(
                    MonitorCheckRun(
                        id: "status-\(nodeID)",
                        origin: .statusContext,
                        name: node.context ?? "",
                        workflowName: nil,
                        runID: nil,
                        runAttempt: nil,
                        headOID: nil,
                        status: Self.monitorStatusContextStatus(state),
                        conclusion: Self.monitorStatusContextConclusion(state),
                        url: node.targetUrl,
                        startedAt: nil,
                        completedAt: nil
                    )
                )
                continue
            }

            // Check runs backed by a workflow run are already covered by the Actions
            // jobs read; keeping them would duplicate the same job under two identities.
            if node.checkSuite?.workflowRun != nil { continue }

            checks.append(
                MonitorCheckRun(
                    id: "check-\(nodeID)",
                    origin: .checkRun,
                    name: node.name ?? "",
                    workflowName: nil,
                    runID: nil,
                    runAttempt: nil,
                    headOID: nil,
                    status: node.status ?? "unknown",
                    conclusion: node.conclusion,
                    url: node.detailsUrl,
                    startedAt: nil,
                    completedAt: nil
                )
            )
        }

        return .value(checks)
    }

    /// Status contexts use `PENDING/SUCCESS/FAILURE/ERROR/EXPECTED`; the monitor's
    /// failure ladder reads `conclusion`, so ERROR is reported as FAILURE there, the
    /// same way the existing CI ladder treats a StatusContext error.
    private static func monitorStatusContextConclusion(_ state: String) -> String? {
        switch state.uppercased() {
        case "SUCCESS": return "SUCCESS"
        case "FAILURE", "ERROR": return "FAILURE"
        default: return nil
        }
    }

    private static func monitorStatusContextStatus(_ state: String) -> String {
        switch state.uppercased() {
        case "SUCCESS", "FAILURE", "ERROR": return "COMPLETED"
        default: return state
        }
    }

    // MARK: Aliased batch transport

    /// Runs one aliased first-page request per batch, isolating a failing alias by
    /// re-reading subsets instead of letting it invalidate the whole batch.
    private func monitorAliasedFirstPage<Payload: Decodable>(
        prs: [MonitoredPR],
        payloadType: Payload.Type,
        makeRequest: (Set<Int>) -> MonitorAliasedRequest
    ) async -> [Int: MonitorAliasOutcome<Payload>] {
        let indices = Set(prs.indices)
        guard !indices.isEmpty else { return [:] }
        return await monitorAliasedPage(payloadType, indices: indices, makeRequest: makeRequest)
    }

    private func monitorAliasedPage<Payload: Decodable>(
        _ payloadType: Payload.Type,
        indices: Set<Int>,
        makeRequest: (Set<Int>) -> MonitorAliasedRequest
    ) async -> [Int: MonitorAliasOutcome<Payload>] {
        let request = makeRequest(indices)
        do {
            let data = try await monitorExecuteGraphQL(
                query: request.query,
                operation: "MonitorSnapshot",
                variables: request.variables
            )
            return try monitorDecodeAliases(data, payloadType: payloadType, indices: indices)
        } catch let error as MonitorTransportError {
            if case .graphQLErrors = error, indices.count > 1 {
                // The strict transport reports only error messages, not their alias
                // path, so the failing alias is isolated by halving the batch: PRs in
                // a half that succeeds still commit a complete observation.
                let sorted = indices.sorted()
                let half = sorted.count / 2
                var merged = await monitorAliasedPage(
                    payloadType,
                    indices: Set(sorted[0..<half]),
                    makeRequest: makeRequest
                )
                let rest = await monitorAliasedPage(
                    payloadType,
                    indices: Set(sorted[half...]),
                    makeRequest: makeRequest
                )
                merged.merge(rest) { _, new in new }
                return merged
            }
            return indices.reduce(into: [Int: MonitorAliasOutcome<Payload>]()) { result, index in
                result[index] = .incomplete(error.incompleteReason)
            }
        } catch {
            let reason = MonitorIncompleteReason.monitorReason(for: error)
            return indices.reduce(into: [Int: MonitorAliasOutcome<Payload>]()) { result, index in
                result[index] = .incomplete(reason)
            }
        }
    }

    /// Decodes each alias on its own so one unreadable PR cannot invalidate its batch.
    /// Decodes aliased payloads from one response.
    ///
    /// `repositoryAliased` describes where the alias sits: the monitor's batch and
    /// single-PR queries alias the `repository` field, so the alias value is the
    /// repository object itself and is wrapped under `repository` for the payload
    /// decoders. Node-based queries (`node(id:)`) set it to false and pass their
    /// `t_N` alias; repository queries keep the default `pr_N` name.
    private func monitorDecodeAliases<Payload: Decodable>(
        _ data: Data,
        payloadType: Payload.Type,
        indices: Set<Int>,
        repositoryAliased: Bool = true,
        aliasName: (Int) -> String = GitHubAPIClient.monitorAliasName
    ) throws -> [Int: MonitorAliasOutcome<Payload>] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] as? [String: Any] else {
            throw MonitorTransportError.invalidResponse
        }

        var result: [Int: MonitorAliasOutcome<Payload>] = [:]
        for index in indices {
            let alias = aliasName(index)
            guard let value = dataObject[alias] else {
                result[index] = .incomplete(monitorIncomplete(.missingNode, "alias \(alias) is missing from the response"))
                continue
            }
            if value is NSNull {
                result[index] = .incomplete(monitorIncomplete(.missingNode, "alias \(alias) resolved to null"))
                continue
            }
            do {
                let decodedValue = repositoryAliased ? ["repository": value] : value
                let payloadData = try JSONSerialization.data(withJSONObject: decodedValue)
                let payload = try JSONDecoder.githubDecoder.decode(Payload.self, from: payloadData)
                result[index] = .payload(payload)
            } catch {
                result[index] = .incomplete(
                    monitorIncomplete(.graphQLErrors, "alias \(alias) could not be decoded: \(error)")
                )
            }
        }
        return result
    }

    /// Decodes the `pr_0` alias of a single-PR continuation query. Those queries alias
    /// the `repository` field, so the alias value is the repository object and is wrapped
    /// under `repository` to match the payload type. Returns nil when the alias is absent.
    private func monitorPayloadFromSingleAlias<Payload: Decodable>(
        _ data: Data,
        as type: Payload.Type
    ) throws -> Payload? {
        let aliases = try monitorDecodeAliases(data, payloadType: type, indices: [0])
        if case .payload(let payload) = aliases[0] { return payload }
        return nil
    }

    /// Decodes a query whose selection is a literal `repository` field (no alias). The
    /// response body is `{data:{repository:{pullRequest}}}`, and the payload expects the
    /// `repository` object at its top level, so only the `data` envelope is unwrapped.
    private func monitorDecodeDataObject<Payload: Decodable>(_ data: Data, as type: Payload.Type) throws -> Payload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] else {
            throw MonitorTransportError.invalidResponse
        }
        let payloadData = try JSONSerialization.data(withJSONObject: dataObject)
        return try JSONDecoder.githubDecoder.decode(Payload.self, from: payloadData)
    }

    // MARK: Request builders

    private static func monitorAliasName(_ index: Int) -> String { "pr_\(index)" }

    private static func monitorThreadAliasName(_ index: Int) -> String { "t_\(index)" }

    private static func monitorBatchRequest(
        prs: [MonitoredPR],
        indices: Set<Int>,
        fieldSelection: String
    ) -> MonitorAliasedRequest {
        var declarations: [String] = []
        var variables: [String: Any] = [:]
        var bodies: [String] = []

        for index in indices.sorted() where index < prs.count {
            let pr = prs[index]
            declarations.append("$owner_\(index): String!, $name_\(index): String!, $number_\(index): Int!")
            variables["owner_\(index)"] = pr.reference.owner
            variables["name_\(index)"] = pr.reference.repo
            variables["number_\(index)"] = pr.reference.number
            bodies.append(
                """
                  \(monitorAliasName(index)): repository(owner: $owner_\(index), name: $name_\(index)) {
                    pullRequest(number: $number_\(index)) {
                \(fieldSelection)
                    }
                  }
                """
            )
        }

        let query = """
        query MonitorSnapshot(\(declarations.joined(separator: ", "))) {
        \(bodies.joined(separator: "\n"))
        }
        """
        return MonitorAliasedRequest(query: query, variables: variables)
    }

    /// Single-PR request used for continuations. The cursor variable is declared only
    /// when the field selection actually uses `after: $cursor`.
    private static func monitorSingleRequest(
        pr: MonitoredPR,
        fieldSelection: String,
        cursor: String?
    ) -> MonitorAliasedRequest {
        var variables: [String: Any] = [
            "owner": pr.reference.owner,
            "name": pr.reference.repo,
            "number": pr.reference.number
        ]
        let cursorDeclaration: String
        if let cursor {
            variables["cursor"] = cursor
            cursorDeclaration = ", $cursor: String!"
        } else {
            cursorDeclaration = ""
        }

        let query = """
        query MonitorSnapshotPage($owner: String!, $name: String!, $number: Int!\(cursorDeclaration)) {
          \(monitorAliasName(0)): repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
        \(fieldSelection)
            }
          }
        }
        """
        return MonitorAliasedRequest(query: query, variables: variables)
    }

    private static func monitorThreadCommentsRequest(
        cursors: [MonitorThreadCommentsCursor]
    ) -> MonitorAliasedRequest {
        var declarations: [String] = []
        var variables: [String: Any] = [:]
        var bodies: [String] = []

        for (index, entry) in cursors.enumerated() {
            declarations.append("$thread_\(index): ID!, $cursor_\(index): String!")
            variables["thread_\(index)"] = entry.threadID
            variables["cursor_\(index)"] = entry.cursor
            bodies.append(
                """
                  \(monitorThreadAliasName(index)): node(id: $thread_\(index)) {
                    ... on PullRequestReviewThread {
                      id
                \(monitorThreadCommentsFields(cursorVariable: "cursor_\(index)"))
                    }
                  }
                """
            )
        }

        let query = """
        query MonitorThreadComments(\(declarations.joined(separator: ", "))) {
        \(bodies.joined(separator: "\n"))
        }
        """
        return MonitorAliasedRequest(query: query, variables: variables)
    }

    private static func monitorRollupRequest(pr: MonitoredPR, cursor: String?) -> MonitorAliasedRequest {
        var variables: [String: Any] = [
            "owner": pr.reference.owner,
            "name": pr.reference.repo,
            "number": pr.reference.number
        ]
        if let cursor {
            variables["cursor"] = cursor
        }

        let query = """
        query MonitorStandaloneChecks($owner: String!, $name: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              commits(last: 1) {
                nodes {
                  commit {
                    oid
                    statusCheckRollup {
                      contexts(first: 100, after: $cursor) {
                        nodes {
        \(monitorStandaloneCheckFields)
                        }
                        pageInfo { hasNextPage endCursor }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        return MonitorAliasedRequest(query: query, variables: variables)
    }

    private static func monitorTimelineRequest(pr: MonitoredPR, cursor: String?) -> MonitorAliasedRequest {
        var variables: [String: Any] = [
            "owner": pr.reference.owner,
            "name": pr.reference.repo,
            "number": pr.reference.number
        ]
        let cursorDeclaration: String
        let cursorArgument: String
        if let cursor {
            variables["cursor"] = cursor
            cursorDeclaration = ", $cursor: String!"
            cursorArgument = ", before: $cursor"
        } else {
            cursorDeclaration = ""
            cursorArgument = ""
        }

        let query = """
        query MonitorReviewRequestedEvents($owner: String!, $name: String!, $number: Int!\(cursorDeclaration)) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT]\(cursorArgument)) {
                nodes {
                  ... on ReviewRequestedEvent {
                    id
                    createdAt
                    requestedReviewer {
                      \(monitorRequestedReviewerFields)
                    }
                  }
                }
                pageInfo {
                  hasPreviousPage
                  startCursor
                }
              }
            }
          }
        }
        """
        return MonitorAliasedRequest(query: query, variables: variables)
    }

    // MARK: Field selections

    private static let monitorHeaderFields = """
          id
          state
          isDraft
          title
          url
          baseRefName
          headRefName
          updatedAt
          repository { isArchived }
          commits(last: 1) { nodes { commit { oid } } }
    """

    private static func monitorReviewsFields(cursor: Bool) -> String {
        """
          commits(last: 1) { nodes { commit { oid } } }
          reviews(first: 100\(cursor ? ", after: $cursor" : "")) {
            nodes {
              id
              author {
                login
                ... on User { id }
                ... on Bot { id }
                ... on Mannequin { id }
                ... on Organization { id }
              }
              state
              body
              url
              submittedAt
              commit { oid }
            }
            pageInfo { hasNextPage endCursor }
          }
        """
    }

    private static func monitorConversationCommentsFields(cursor: Bool) -> String {
        """
          comments(first: 100\(cursor ? ", after: $cursor" : "")) {
            nodes {
              id
              author {
                login
                ... on User { id }
                ... on Bot { id }
                ... on Mannequin { id }
                ... on Organization { id }
              }
              body
              url
              createdAt
              lastEditedAt
            }
            pageInfo { hasNextPage endCursor }
          }
        """
    }

    private static func monitorThreadCommentsFields(cursorVariable: String?) -> String {
        let argument = cursorVariable.map { ", after: $\($0)" } ?? ""
        return """
              comments(first: 100\(argument)) {
                nodes {
                  id
                  author {
                    login
                    ... on User { id }
                    ... on Bot { id }
                    ... on Mannequin { id }
                    ... on Organization { id }
                  }
                  body
                  url
                  createdAt
                  lastEditedAt
                  replyTo { id }
                  path
                  line
                  pullRequestReview { id state }
                }
                pageInfo { hasNextPage endCursor }
              }
        """
    }

    private static func monitorReviewThreadsFields(cursor: Bool) -> String {
        """
          commits(last: 1) { nodes { commit { oid } } }
          reviewThreads(first: 100\(cursor ? ", after: $cursor" : "")) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
        \(monitorThreadCommentsFields(cursorVariable: nil))
            }
            pageInfo { hasNextPage endCursor }
          }
        """
    }

    /// `Team.id` requires `read:org` or `read:discussion`. Selecting it makes GitHub
    /// reject the whole query for a token that only has `repo`, `read:user` and
    /// `workflow`, even when every reviewer is a user. `__typename` still distinguishes
    /// a team request, which is never treated as the viewer's own request.
    private static let monitorRequestedReviewerFields = """
    __typename
    ... on User { id login }
    """

    private static func monitorReviewRequestsFields(cursor: Bool) -> String {
        """
          reviewRequests(first: 100\(cursor ? ", after: $cursor" : "")) {
            nodes {
              id
              requestedReviewer {
                \(monitorRequestedReviewerFields)
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        """
    }

    private static let monitorStandaloneCheckFields = """
              ... on CheckRun {
                id
                name
                status
                conclusion
                detailsUrl
                checkSuite { workflowRun { databaseId runAttempt } }
              }
              ... on StatusContext {
                id
                context
                state
                targetUrl
              }
    """

    // MARK: Discovery queries

    private static let monitorViewerIdentityQuery = """
    query MonitorViewerIdentity {
      viewer {
        id
        login
        databaseId
      }
    }
    """

    private static let monitorSearchQuery = """
    query MonitorDiscovery($q: String!, $cursor: String) {
      search(type: ISSUE, query: $q, first: 100, after: $cursor) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            state
            isDraft
            headRefOid
            updatedAt
            repository { owner { login } name }
            commits(last: 1) { nodes { commit { oid } } }
          }
        }
      }
    }
    """

    private static func monitorDiscoveryQueries(
        scope: MonitorDiscoveryScope,
        login: String
    ) -> [(MonitorOrigin, String)] {
        var queries: [(MonitorOrigin, String)] = []
        if scope.includeAuthored {
            queries.append((.authored, "is:pr is:open author:\(login)"))
        }
        if scope.includeRequested {
            queries.append((.requested, "is:pr is:open -author:\(login) review-requested:\(login)"))
        }
        if scope.includeReviewed {
            queries.append((.reviewed, "is:pr is:open -author:\(login) reviewed-by:\(login)"))
        }
        if scope.includeCommented {
            queries.append((.commented, "is:pr is:open -author:\(login) commenter:\(login)"))
        }
        return queries
    }

    // MARK: Search windows

    private static let monitorSearchCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar
    }()

    private static let monitorSearchDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func monitorSearchDate(_ date: Date) -> String {
        monitorSearchDateFormatter.string(from: date)
    }

    private static func monitorInitialSearchWindows(now: Date) -> [MonitorSearchWindow] {
        let calendar = monitorSearchCalendar
        let currentYear = max(calendar.component(.year, from: now), MonitorAcquisitionLimit.searchFloorYear)
        var windows: [MonitorSearchWindow] = []

        for year in MonitorAcquisitionLimit.searchFloorYear...currentYear {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let nextStart = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
                continue
            }
            let end = min(nextStart.addingTimeInterval(-1), now)
            guard end >= start else { continue }
            windows.append(MonitorSearchWindow(start: start, end: end, unit: .year))
        }
        return windows
    }

    private static func monitorSplitSearchWindow(
        _ window: MonitorSearchWindow,
        into unit: MonitorSearchWindowUnit
    ) -> [MonitorSearchWindow] {
        let calendar = monitorSearchCalendar
        var windows: [MonitorSearchWindow] = []
        var cursor = window.start

        while cursor <= window.end, windows.count < MonitorAcquisitionLimit.maximumSubWindows {
            guard let next = calendar.date(byAdding: unit.component, value: 1, to: cursor) else { break }
            let end = min(next.addingTimeInterval(-1), window.end)
            windows.append(MonitorSearchWindow(start: cursor, end: end, unit: unit))
            cursor = next
        }
        return windows
    }

    private static func monitorChunk<Element>(_ elements: [Element], size: Int) -> [[Element]] {
        guard size > 0 else { return elements.isEmpty ? [] : [elements] }
        return stride(from: 0, to: elements.count, by: size).map {
            Array(elements[$0..<Swift.min($0 + size, elements.count)])
        }
    }
}
