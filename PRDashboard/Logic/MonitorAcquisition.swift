import Foundation

/// Viewer identity reported by GitHub. The node ID is the authoritative account
/// identity used by `MonitorAccountKey`; the login is display/search only.
struct MonitorViewerIdentity: Codable, Equatable {
    let nodeID: String
    let login: String
    let databaseID: Int?
}

/// Which discovery searches to run. Each search only discovers PRs; it never removes
/// a PR from monitoring (removal is decided by lifecycle observations, not by search).
struct MonitorDiscoveryScope: Equatable {
    var includeAuthored: Bool
    var includeRequested: Bool
    var includeReviewed: Bool
    var includeCommented: Bool

    static let all = MonitorDiscoveryScope(
        includeAuthored: true,
        includeRequested: true,
        includeReviewed: true,
        includeCommented: true
    )

    init(
        includeAuthored: Bool = true,
        includeRequested: Bool = true,
        includeReviewed: Bool = true,
        includeCommented: Bool = true
    ) {
        self.includeAuthored = includeAuthored
        self.includeRequested = includeRequested
        self.includeReviewed = includeReviewed
        self.includeCommented = includeCommented
    }
}

struct MonitorDiscoveryOutcome: Equatable {
    struct DiscoveredReference: Equatable {
        var prNodeID: String
        var reference: PullRequestReference
        var title: String
        var url: URL?
        var lifecycle: PRState
        var headOID: String?
        var updatedAt: Date
        var origins: Set<MonitorOrigin>
    }

    var discovered: [DiscoveredReference]
    var coverage: MonitorDiscoveryCoverage
}

/// Result of one acquisition pass over a set of PRs. Sources that could not be read
/// completely are reported as incomplete instead of being silently truncated.
struct MonitorSnapshotOutcome: Equatable {
    var observations: [MonitorPRObservation]
    /// Set when the pass stopped early for a global reason (for example exhausted rate
    /// limit headroom): the remaining PRs were not attempted at all.
    var deferralReason: MonitorIncompleteReason?

    static let empty = MonitorSnapshotOutcome(observations: [], deferralReason: nil)
}

/// Read-only acquisition surface used by `PRActivityMonitor`.
///
/// Implementations must:
/// - reuse the existing token, URLSession, proxy and endpoint resolution;
/// - never write to GitHub and never start AI work;
/// - return `isComplete = false` with a reason for anything they could not read in
///   full (dropped node, missing/repeated cursor, GraphQL errors, HTTP failure,
///   rate limit, identity mismatch, or a head change during acquisition);
/// - attribute failures per PR and per source so one broken source never invalidates
///   the others.
protocol MonitorAcquisitionProviding: AnyObject {
    /// Current rate-limit headroom, shared with UI polling.
    var rateLimitHeadroom: RateLimitInfo { get }

    /// Resolves the authenticated viewer's stable identity.
    func fetchViewerIdentity() async throws -> MonitorViewerIdentity

    /// Discovers open PRs the viewer is involved in. Search is only a discovery
    /// mechanism: it never removes a PR from monitoring. Pagination must be split by
    /// created-at windows to work around the 1,000-result search cap, and incomplete
    /// coverage must be reported instead of silently dropping results.
    func fetchMonitorDiscovery(
        scope: MonitorDiscoveryScope
    ) async throws -> MonitorDiscoveryOutcome

    /// Acquires the requested sources for each PR, in full.
    func fetchMonitorObservations(
        for prs: [MonitoredPR],
        viewer: MonitorViewerIdentity,
        sources: Set<MonitorSourceKind>
    ) async -> MonitorSnapshotOutcome
}

/// Errors surfaced by `GitHubAPIClient.monitorExecuteGraphQL` and the monitor REST calls.
enum MonitorTransportError: Error {
    case graphQLErrors([String])
    case http(Int)
    case unauthorized
    case rateLimited(reset: Date?)
    case network(Error)
    case invalidResponse
}

extension MonitorTransportError {
    /// Maps a transport failure onto the persisted "source is not complete" reason.
    var incompleteReason: MonitorIncompleteReason {
        switch self {
        case .graphQLErrors(let messages):
            return MonitorIncompleteReason(kind: .graphQLErrors, statusCode: nil, detail: messages.first)
        case .http(let statusCode):
            return MonitorIncompleteReason(kind: .httpError, statusCode: statusCode, detail: nil)
        case .unauthorized:
            return MonitorIncompleteReason(kind: .notAuthorized, statusCode: 401, detail: nil)
        case .rateLimited:
            return MonitorIncompleteReason(kind: .rateLimited, statusCode: 429, detail: nil)
        case .network(let error):
            return MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: error.localizedDescription)
        case .invalidResponse:
            return MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: nil)
        }
    }
}
