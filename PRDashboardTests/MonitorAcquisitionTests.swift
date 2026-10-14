import XCTest
@testable import PRDashboard

/// Drives `GitHubAPIClient`'s monitor acquisition against a fixture transport and checks
/// the completeness contract: complete reads carry their payload, a head change is
/// reported as `headChanged`, and one source or origin failing never blanks the others.
@MainActor
final class MonitorAcquisitionTests: XCTestCase {
    private var session: URLSession!
    private let viewer = MonitorViewerIdentity(nodeID: "U_VIEWER", login: "octocat", databaseID: 1)
    private let reference = PullRequestReference(owner: "owner", repo: "repo", number: 7)

    override func setUp() {
        super.setUp()
        MonitorAcquisitionFixture.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorAcquisitionFixture.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MonitorAcquisitionFixture.reset()
        session = nil
        super.tearDown()
    }

    private func makeClient() -> GitHubAPIClient {
        GitHubAPIClient(token: "fixture-token", session: session)
    }

    private func monitoredPR(nodeID: String = "PR_NODE_1") -> MonitoredPR {
        MonitoredPR(
            prNodeID: nodeID,
            reference: reference,
            origins: [.authored],
            discoveredAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Reviews pagination

    func testReviewsPaginatePastOnePageAndSkipPendingReviews() async {
        MonitorAcquisitionFixture.reset { request in
            let query = MonitorAcquisitionFixture.queryName(request)
            if query == "MonitorSnapshot", MonitorAcquisitionFixture.queryText(request).contains("reviews(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviews": [
                        "nodes": [Self.review(id: "R1", state: "COMMENTED")],
                        "pageInfo": ["hasNextPage": true, "endCursor": "cursor-1"]
                    ],
                    "commits": Self.commits("sha1")
                ])
            }
            if query == "MonitorSnapshotPage" {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviews": [
                        "nodes": [
                            Self.review(id: "R2", state: "PENDING"),
                            Self.review(id: "R3", state: "APPROVED")
                        ],
                        "pageInfo": ["hasNextPage": false, "endCursor": nil]
                    ],
                    "commits": Self.commits("sha1")
                ])
            }
            return Self.headerResponse()
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.reviews]
        )

        let reviews = outcome.observations.first?.observation(for: .reviews)
        XCTAssertEqual(reviews?.isComplete, true, "reviews that paginate to the end are a complete source read")
        let stored = reviews?.payload?.reviews ?? []
        XCTAssertEqual(stored.map(\.id), ["R1", "R3"], "the second page is collected and a PENDING review is never stored")
    }

    // MARK: - Thread comment pagination

    func testThreadCommentPaginationCollectsRepliesBeyondTheFirstPage() async {
        MonitorAcquisitionFixture.reset { request in
            let query = MonitorAcquisitionFixture.queryName(request)
            let text = MonitorAcquisitionFixture.queryText(request)
            if query == "MonitorSnapshot", text.contains("reviewThreads(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviewThreads": [
                        "nodes": [[
                            "id": "T1",
                            "isResolved": false,
                            "isOutdated": false,
                            "path": "a.swift",
                            "line": 3,
                            "comments": [
                                "nodes": (1...5).map { Self.threadComment(id: "C\($0)") },
                                "pageInfo": ["hasNextPage": true, "endCursor": "thread-cursor"]
                            ]
                        ]],
                        "pageInfo": ["hasNextPage": false, "endCursor": nil]
                    ],
                    "commits": Self.commits("sha1")
                ])
            }
            if query == "MonitorThreadComments" {
                return MonitorAcquisitionFixture.nodeAlias([
                    "id": "T1",
                    "comments": [
                        "nodes": [Self.threadComment(id: "C6"), Self.threadComment(id: "C101")],
                        "pageInfo": ["hasNextPage": false, "endCursor": nil]
                    ]
                ])
            }
            return Self.headerResponse()
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.reviewThreads]
        )

        let threads = outcome.observations.first?.observation(for: .reviewThreads)
        XCTAssertEqual(threads?.isComplete, true, "thread comment pagination that terminates is a complete source read")
        let commentIDs = threads?.payload?.reviewThreads?.first?.comments.map(\.id) ?? []
        XCTAssertTrue(commentIDs.contains("C6"), "the sixth reply, past the first page, must be collected")
        XCTAssertTrue(commentIDs.contains("C101"), "a reply past the first hundred must be collected")
    }

    // MARK: - Head change

    func testHeadChangeMarksRevisionBoundSourcesIncomplete() async {
        MonitorAcquisitionFixture.reset { request in
            if request.url?.path.contains("/actions/runs") == true {
                return MonitorAcquisitionFixture.http(
                    status: 200,
                    body: MonitorAcquisitionFixture.encode(["total_count": 0, "workflow_runs": []])
                )
            }
            let query = MonitorAcquisitionFixture.queryName(request)
            let text = MonitorAcquisitionFixture.queryText(request)
            if query == "MonitorSnapshot", text.contains("reviews(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviews": ["nodes": [Self.review(id: "R1", state: "COMMENTED")], "pageInfo": ["hasNextPage": false]],
                    "commits": Self.commits("sha2")
                ])
            }
            if query == "MonitorSnapshot", text.contains("reviewThreads(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviewThreads": ["nodes": [], "pageInfo": ["hasNextPage": false]],
                    "commits": Self.commits("sha2")
                ])
            }
            if query == "MonitorSnapshot", text.contains("comments(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "comments": ["nodes": [Self.issueComment(id: "IC1")], "pageInfo": ["hasNextPage": false]]
                ])
            }
            if query == "MonitorStandaloneChecks" {
                return MonitorAcquisitionFixture.repositoryPullRequest(["commits": Self.commits("sha2")])
            }
            return Self.headerResponse(head: "sha1")
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.reviews, .reviewThreads, .conversationComments, .ci]
        )

        let observation = outcome.observations.first
        XCTAssertEqual(
            observation?.observation(for: .reviews)?.incompleteReason?.kind,
            .headChanged,
            "reviews must report the head change"
        )
        XCTAssertEqual(
            observation?.observation(for: .reviewThreads)?.incompleteReason?.kind,
            .headChanged,
            "review threads must report the head change"
        )
        XCTAssertEqual(
            observation?.observation(for: .ci)?.incompleteReason?.kind,
            .headChanged,
            "ci must report the head change"
        )
        XCTAssertEqual(
            observation?.observation(for: .conversationComments)?.isComplete,
            true,
            "conversation comments are not bound to a revision and stay complete"
        )
        XCTAssertEqual(
            observation?.observation(for: .conversationComments)?.payload?.conversationComments?.map(\.id),
            ["IC1"],
            "the conversation comments payload must be kept"
        )
    }

    // MARK: - Discovery cursor isolation

    func testDiscoveryMissingCursorMarksOnlyThatOriginIncomplete() async throws {
        MonitorAcquisitionFixture.reset { request in
            if MonitorAcquisitionFixture.queryName(request) == "MonitorViewerIdentity" {
                return MonitorAcquisitionFixture.json([
                    "data": ["viewer": ["id": "VIEWER", "login": "viewer", "databaseId": 1]]
                ])
            }
            let variables = MonitorAcquisitionFixture.variables(request)
            let query = variables["q"] as? String ?? ""
            if query.contains(" author:") {
                return Self.searchResponse(nodes: [Self.searchNode(id: "PR_A", number: 1)], hasNextPage: true, endCursor: nil)
            }
            return Self.searchResponse(nodes: [Self.searchNode(id: "PR_B", number: 2)], hasNextPage: false, endCursor: nil)
        }

        let outcome = try await makeClient().fetchMonitorDiscovery(scope: .all)
        let authored = outcome.coverage.queries.first { $0.origin == .authored }
        let reviewed = outcome.coverage.queries.first { $0.origin == .reviewed }

        XCTAssertEqual(authored?.isComplete, false, "an origin whose page reports more results but no cursor is incomplete")
        XCTAssertEqual(authored?.incompleteReason?.kind, .missingCursor)
        XCTAssertEqual(reviewed?.isComplete, true, "the other origin must stay complete when one origin has a bad cursor")
    }

    // MARK: - CI isolation and identity

    func testRESTJobFailureIsolatesOnlyTheCISource() async {
        MonitorAcquisitionFixture.reset { request in
            if request.url?.path.contains("/actions/runs") == true {
                return MonitorAcquisitionFixture.http(status: 500, body: Data())
            }
            let text = MonitorAcquisitionFixture.queryText(request)
            if text.contains("comments(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "comments": ["nodes": [Self.issueComment(id: "C1")], "pageInfo": ["hasNextPage": false]]
                ])
            }
            return Self.headerResponse()
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.conversationComments, .ci]
        )

        let observation = outcome.observations.first
        XCTAssertEqual(observation?.observation(for: .ci)?.isComplete, false, "a failing runs endpoint must mark the CI source incomplete")
        XCTAssertEqual(
            observation?.observation(for: .conversationComments)?.isComplete,
            true,
            "the conversation comments source must stay complete when the CI source fails"
        )
        XCTAssertEqual(
            observation?.observation(for: .conversationComments)?.payload?.conversationComments?.map(\.id),
            ["C1"],
            "the unaffected source keeps its payload"
        )
    }

    func testCIAcquisitionCollectsActionsJobsAndStandaloneChecks() async {
        MonitorAcquisitionFixture.reset { request in
            let path = request.url?.path ?? ""
            if path.contains("/actions/runs"), path.contains("/jobs") {
                return MonitorAcquisitionFixture.http(status: 200, body: Self.jobsBody())
            }
            if path.contains("/actions/runs") {
                return MonitorAcquisitionFixture.http(status: 200, body: Self.runsBody())
            }
            if MonitorAcquisitionFixture.queryName(request) == "MonitorStandaloneChecks" {
                return MonitorAcquisitionFixture.repositoryPullRequest([
                    "commits": ["nodes": [["commit": [
                        "oid": "sha1",
                        "statusCheckRollup": ["contexts": [
                            "nodes": [
                                Self.standaloneCheck(),
                                Self.workflowBackedCheck()
                            ],
                            "pageInfo": ["hasNextPage": false, "endCursor": nil]
                        ]]
                    ]]]]
                ])
            }
            return Self.headerResponse()
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.ci]
        )

        let checks = outcome.observations.first?.observation(for: .ci)?.payload?.ci?.checks ?? []
        let job = checks.first { $0.origin == .actionsJob }
        XCTAssertEqual(job?.runID, "555", "an Actions job keeps its workflow run id")
        XCTAssertEqual(job?.runAttempt, 2, "an Actions job keeps the attempt it ran in")
        XCTAssertEqual(job?.headOID, "sha1", "an Actions job is keyed to the captured head")
        XCTAssertTrue(checks.contains { $0.origin == .checkRun && $0.id == "check-900" }, "a standalone check keeps its own identity")
        XCTAssertFalse(
            checks.contains { $0.id == "check-901" },
            "a check that belongs to a workflow run is not duplicated as a standalone check"
        )
    }

    func testReviewRequestsAvoidOrgScopedTeamFieldsAndStillDetectTheViewer() async {
        var queries: [String] = []
        MonitorAcquisitionFixture.reset { request in
            let text = MonitorAcquisitionFixture.queryText(request)
            if !text.isEmpty { queries.append(text) }
            let query = MonitorAcquisitionFixture.queryName(request)
            if query == "MonitorSnapshot", text.contains("reviewRequests(first:") {
                return MonitorAcquisitionFixture.aliasedPullRequest([
                    "reviewRequests": [
                        "nodes": [
                            [
                                "id": "RR1",
                                "requestedReviewer": [
                                    "__typename": "User",
                                    "id": "U_VIEWER",
                                    "login": "octocat"
                                ]
                            ],
                            [
                                "id": "RR2",
                                "requestedReviewer": ["__typename": "Team"]
                            ]
                        ],
                        "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]
                    ]
                ])
            }
            if query == "MonitorReviewRequestedEvents" {
                return MonitorAcquisitionFixture.repositoryPullRequest([
                    "timelineItems": [
                        "nodes": [
                            [
                                "id": "E1",
                                "createdAt": "2023-11-14T22:00:00Z",
                                "requestedReviewer": [
                                    "__typename": "User",
                                    "id": "U_VIEWER",
                                    "login": "octocat"
                                ]
                            ],
                            [
                                "id": "E2",
                                "createdAt": "2023-11-14T22:01:00Z",
                                "requestedReviewer": ["__typename": "Team"]
                            ]
                        ],
                        "pageInfo": ["hasPreviousPage": false, "startCursor": NSNull()]
                    ]
                ])
            }
            return Self.headerResponse()
        }

        let outcome = await makeClient().fetchMonitorObservations(
            for: [monitoredPR()],
            viewer: viewer,
            sources: [.reviewRequests]
        )

        let observation = outcome.observations.first?.observation(for: .reviewRequests)
        XCTAssertEqual(observation?.isComplete, true, "review requests must complete without read:org")
        XCTAssertFalse(
            queries.contains { $0.contains("on Team") },
            "review request queries must not select Team fields that require read:org"
        )
        XCTAssertTrue(
            queries.contains { $0.contains("reviewRequests(first:") && $0.contains("__typename") && $0.contains("on User") },
            "the list query still identifies a user reviewer"
        )
        XCTAssertTrue(
            queries.contains { $0.contains("REVIEW_REQUESTED_EVENT") && !$0.contains("on Team") },
            "the timeline query must use the same org-safe reviewer selection"
        )
        let requests = observation?.payload?.reviewRequests?.requests ?? []
        XCTAssertEqual(requests.map(\.id), ["RR1", "RR2"])
        XCTAssertEqual(requests.map(\.targetType), [.user, .team])
        XCTAssertEqual(requests.map(\.isViewer), [true, false], "only the viewer's own user request is actionable")
        let events = observation?.payload?.reviewRequests?.events ?? []
        XCTAssertEqual(events.map(\.id), ["E1", "E2"])
        XCTAssertEqual(events.map(\.targetType), [.user, .team])
        XCTAssertEqual(events.map(\.isViewer), [true, false])
    }


    // MARK: - Fixture builders

    private static func headerResponse(head: String = "sha1") -> (HTTPURLResponse, Data) {
        MonitorAcquisitionFixture.aliasedPullRequest([
            "id": "PR_NODE_1",
            "state": "OPEN",
            "isDraft": false,
            "title": "Add feature",
            "url": "https://github.com/owner/repo/pull/7",
            "baseRefName": "main",
            "headRefName": "feature",
            "updatedAt": "2023-11-14T22:13:20Z",
            "repository": ["isArchived": false],
            "commits": commits(head)
        ])
    }

    private static func review(id: String, state: String) -> [String: Any] {
        [
            "id": id,
            "author": ["login": "alice"],
            "state": state,
            "body": "",
            "url": "https://github.com/owner/repo/pull/7#pullrequestreview-\(id)",
            "submittedAt": "2023-11-14T22:13:20Z",
            "commit": ["oid": "sha1"]
        ]
    }

    private static func threadComment(id: String) -> [String: Any] {
        [
            "id": id,
            "author": ["login": "alice"],
            "body": "note",
            "url": "https://github.com/owner/repo/pull/7#discussion_r\(id)",
            "createdAt": "2023-11-14T22:13:20Z",
            "path": "a.swift",
            "line": 3,
            "pullRequestReview": ["id": "R1", "state": "COMMENTED"]
        ]
    }

    private static func issueComment(id: String) -> [String: Any] {
        [
            "id": id,
            "author": ["login": "alice"],
            "body": "hello",
            "url": "https://github.com/owner/repo/pull/7#issuecomment-\(id)",
            "createdAt": "2023-11-14T22:13:20Z",
        ]
    }

    private static func commits(_ oid: String) -> [String: Any] {
        ["nodes": [["commit": ["oid": oid]]]]
    }

    private static func searchNode(id: String, number: Int) -> [String: Any] {
        [
            "id": id,
            "number": number,
            "title": "PR \(number)",
            "url": "https://github.com/owner/repo/pull/\(number)",
            "state": "OPEN",
            "isDraft": false,
            "headRefOid": "sha1",
            "updatedAt": "2023-11-14T22:13:20Z",
            "repository": ["owner": ["login": "owner"], "name": "repo"],
            "commits": commits("sha1")
        ]
    }

    private static func searchResponse(nodes: [[String: Any]], hasNextPage: Bool, endCursor: String?) -> (HTTPURLResponse, Data) {
        var pageInfo: [String: Any] = ["hasNextPage": hasNextPage]
        if let endCursor {
            pageInfo["endCursor"] = endCursor
        }
        let body: [String: Any] = [
            "data": [
                "search": [
                    "issueCount": nodes.count,
                    "pageInfo": pageInfo,
                    "nodes": nodes
                ]
            ]
        ]
        return MonitorAcquisitionFixture.json(body)
    }

    private static func runsBody() -> Data {
        MonitorAcquisitionFixture.encode([
            "total_count": 1,
            "workflow_runs": [[
                "id": 555,
                "name": "CI",
                "run_attempt": 2,
                "status": "completed",
                "conclusion": "failure",
                "html_url": "https://github.com/owner/repo/actions/runs/555",
                "head_sha": "sha1"
            ]]
        ])
    }

    private static func jobsBody() -> Data {
        MonitorAcquisitionFixture.encode([
            "total_count": 1,
            "jobs": [[
                "id": 777,
                "name": "build",
                "status": "completed",
                "conclusion": "failure",
                "html_url": "https://github.com/owner/repo/actions/runs/555/job/777",
                "started_at": "2023-11-14T22:00:00Z",
                "completed_at": "2023-11-14T22:10:00Z"
            ]]
        ])
    }

    private static func standaloneCheck() -> [String: Any] {
        [
            "__typename": "CheckRun",
            "id": "900",
            "name": "lint",
            "conclusion": "FAILURE",
            "status": "COMPLETED",
            "detailsUrl": "https://example.com/lint"
        ]
    }

    private static func workflowBackedCheck() -> [String: Any] {
        [
            "__typename": "CheckRun",
            "id": "901",
            "name": "build",
            "conclusion": "FAILURE",
            "status": "COMPLETED",
            "detailsUrl": "https://example.com/build",
            "checkSuite": ["workflowRun": ["databaseId": 555, "runAttempt": 2]]
        ]
    }
}

private final class MonitorAcquisitionFixture: URLProtocol {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func reset(handler: Handler? = nil) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func queryText(_ request: URLRequest) -> String {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        return object["query"] as? String ?? ""
    }

    static func queryName(_ request: URLRequest) -> String {
        let text = queryText(request)
        guard let range = text.range(of: "query ") else { return "" }
        let rest = text[range.upperBound...]
        return String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func variables(_ request: URLRequest) -> [String: Any] {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object["variables"] as? [String: Any] ?? [:]
    }

    /// Body for a query that aliases `repository`: the code reads `data.pr_0` and wraps
    /// that value under `repository` itself, so the alias value is the pull request.
    static func aliasedPullRequest(_ pullRequest: [String: Any], alias: String = "pr_0") -> (HTTPURLResponse, Data) {
        json(["data": [alias: ["pullRequest": pullRequest]]])
    }

    /// Body for a query whose selection is a literal `repository` field.
    static func repositoryPullRequest(_ pullRequest: [String: Any]) -> (HTTPURLResponse, Data) {
        json(["data": ["repository": ["pullRequest": pullRequest]]])
    }

    /// Body for a `node(id:)` alias: the alias value is the node object, unwrapped.
    static func nodeAlias(_ node: [String: Any], alias: String = "t_0") -> (HTTPURLResponse, Data) {
        json(["data": [alias: node]])
    }

    static func json(_ body: [String: Any]) -> (HTTPURLResponse, Data) {
        http(status: 200, body: encode(body))
    }

    static func http(status: Int, body: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/graphql")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    static func encode(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = Self.materializedRequest(from: request)
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func materializedRequest(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var body = Data()
        while true {
            let count = stream.read(buffer, maxLength: capacity)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        var materialized = request
        materialized.httpBodyStream = nil
        materialized.httpBody = body
        return materialized
    }
}
