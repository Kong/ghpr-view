import XCTest
@testable import PRDashboard

final class PRPanelPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)


    func testCategoryScopesKeepExistingRoleSectionsAndMergedHistoryInAll() {
        let authored = makePR(1)
        let review = makePR(2, category: .reviewRequest)
        let mention = makePR(3)
        let merged = makePR(4, mergedAt: now)
        var list = makeList([authored, review])
        list.mentionedPullRequests = [mention]
        list.directMentionPullRequests = [mention]
        list.mergedPullRequests = [merged]
        let projection = project(list)

        XCTAssertEqual(projection.displayedRowIDs(for: .all).map(\.prID), [1, 2, 3, 3, 4])
        XCTAssertEqual(projection.displayedRowIDs(for: .myPRs).map(\.section), [.authored])
        XCTAssertEqual(projection.displayedRowIDs(for: .reviews).map(\.section), [.reviewRequests])
        XCTAssertEqual(projection.displayedRowIDs(for: .mentions).map(\.section), [.mentioned, .directMentions])
        XCTAssertEqual(PRPanelCategory.allCases, [.all, .myPRs, .reviews, .mentions])
    }

    func testUnknownQuotaDoesNotPretendToBeKnownOrBlockInitialHeadroom() {
        let unknown = RateLimitInfo.empty
        XCTAssertFalse(unknown.isAvailable)
        XCTAssertFalse(unknown.isLow)
        XCTAssertTrue(unknown.hasHeadroomForMentions)
        XCTAssertTrue(unknown.hasHeadroomForDetails)

        let rest = RateLimitInfo(limit: 5_000, remaining: 4_000, resetDate: now)
        let graphQL = RateLimitInfo(limit: 5_000, remaining: 2_000, resetDate: now)
        XCTAssertNotEqual(rest, graphQL, "Independent API pools retain their own quota values")
    }
    func testScopedQueriesAndCombinedFacetsPreserveMatchingIDs() {
        var passing = makePR(1)
        passing.approvalCount = 2
        passing.githubLabels = [GitHubLabel(name: "Backend", color: nil)]
        passing.githubMilestone = GitHubMilestone(title: "3.14")
        passing.jiraTicket = "DEMO-42"
        var failing = makePR(2)
        failing.ciStatus = .failure
        failing.githubLabels = [GitHubLabel(name: "Frontend", color: nil)]
        failing.githubMilestone = GitHubMilestone(title: "3.15")
        var unknown = makePR(3)
        unknown.ciStatus = .unknown
        let conflict = makePR(4, hasBaseConflicts: true)
        let list = makeList([passing, failing, unknown, conflict])

        XCTAssertEqual(project(list, query: "jira:DEMO-42").filteredPRs.map(\.id), [1])
        XCTAssertEqual(project(list, query: "ci:failure").filteredPRs.map(\.id), [2, 3])
        XCTAssertEqual(project(list, query: "pr:conflict").filteredPRs.map(\.id), [4])
        XCTAssertEqual(project(list, query: "approval:>=2").filteredPRs.map(\.id), [1])
        for query in ["ci:purple", "pr:closed", "approval:>=x"] {
            XCTAssertTrue(project(list, query: query).filteredPRs.isEmpty)
        }
        XCTAssertEqual(project(list, query: "approval:-1").filteredPRs.map(\.id), [])
        let facets: [FacetFieldID: Set<String>] = [
            .githubLabel: ["backend", "frontend"], .githubMilestone: ["3.14"]
        ]
        XCTAssertEqual(project(list, selections: facets).filteredPRs.map(\.id), [1])
        XCTAssertTrue(project(list, query: "unmatched", selections: facets).filteredPRs.isEmpty)
        XCTAssertEqual(project(list, selections: facets).facetChips.count, 3)
        XCTAssertEqual(project(list, query: "ci:failure").facetOptions[.githubLabel]?.map(\.key), ["frontend"])
    }

    func testPinMovesWithinRoleIdentityAndRetainsOriginalOrdering() {
        let zOld = makePR(1, repo: "z", age: 300, title: "Pinned source order first")
        let aOld = makePR(2, repo: "a", age: 200)
        let aNew = makePR(3, repo: "a", age: 100)
        let zNew = makePR(4, repo: "z", age: 0)
        let list = makeList([zOld, aOld, aNew, zNew])
        let before = project(list)
        XCTAssertEqual(before.displayedRowIDs(for: .authored).map(\.prID), [3, 2, 4, 1])
        let pinned = project(list, pins: [zOld.pinIdentifier, aOld.pinIdentifier])
        XCTAssertEqual(pinned.pinnedAuthoredPRs.map(\.id), [1, 2])
        XCTAssertEqual(pinned.displayedRowIDs(for: .authored).map(\.prID), [1, 2, 3, 4])
        let id = PRPanelRowID(section: .authored, prID: 1)
        XCTAssertTrue(before.displayedRowIDs(for: .authored).contains(id))
        XCTAssertTrue(pinned.displayedRowIDs(for: .authored).contains(id))
        XCTAssertEqual(pinned.pr(for: id)?.title, zOld.title)
        XCTAssertNil(pinned.pr(for: PRPanelRowID(section: .reviewRequests, prID: 1)))
    }

    func testMergedWindowIsInclusiveRollingAndDeduplicatesBeforeSorting() {
        let boundary = makePR(1, repo: "z", mergedAt: now.addingTimeInterval(-86400))
        let expired = makePR(2, mergedAt: now.addingTimeInterval(-86401))
        let recent = makePR(3, repo: "a", mergedAt: now.addingTimeInterval(-60))
        let duplicate = makePR(1, repo: "z", mergedAt: now)
        let undated = makePR(4)
        var list = makeList([])
        list.mergedPullRequests = [boundary, expired, recent, duplicate, undated]
        let projection = project(list)
        XCTAssertEqual(projection.mergedLast24hPRs.map(\.id), [3, 1])
        XCTAssertEqual(projection.pr(for: PRPanelRowID(section: .mergedToday, prID: 1))?.mergedAt, boundary.mergedAt)
        XCTAssertEqual(projection.groupedMergedLast24hPRs.map { $0.0 }, ["example/a", "example/z"])
        let later = PRPanelProjection.make(prList: list, searchText: "", selections: [:], pinnedIdentifiers: [], configuration: .default, now: now.addingTimeInterval(1))
        XCTAssertEqual(later.mergedLast24hPRs.map(\.id), [1, 3])
    }

    func testCachedMergedRowsExpireWithoutSourcePublicationAndRevealLaterDuplicate() {
        let boundary = makePR(1, mergedAt: now.addingTimeInterval(-86400))
        let duplicate = makePR(1, mergedAt: now)
        let recent = makePR(2, mergedAt: now.addingTimeInterval(-60))
        var list = makeList([])
        list.mergedPullRequests = [boundary, duplicate, recent]
        var cache = PRPanelProjectionCache()
        func read(at date: Date) -> PRPanelProjection {
            cache.projection(revision: 1, now: date) { clock in
                PRPanelProjection.make(
                    prList: list, searchText: "", selections: [:], pinnedIdentifiers: [],
                    configuration: .default, now: clock
                )
            }
        }
        let beforeBoundary = read(at: now.addingTimeInterval(-1))
        XCTAssertEqual(beforeBoundary.mergedLast24hPRs.map(\.id), [2, 1])
        let atBoundary = read(at: now)
        XCTAssertEqual(atBoundary.mergedLast24hPRs.map(\.id), [2, 1])
        XCTAssertEqual(atBoundary.mergedLast24hPRs.last?.mergedAt, boundary.mergedAt)

        let afterBoundary = read(at: now.addingTimeInterval(1))
        XCTAssertEqual(afterBoundary.mergedLast24hPRs.map(\.id), [1, 2])
        XCTAssertEqual(afterBoundary.mergedLast24hPRs.first?.mergedAt, duplicate.mergedAt)
        XCTAssertEqual(read(at: now.addingTimeInterval(86400)).mergedLast24hPRs.map(\.id), [1])
        XCTAssertTrue(read(at: now.addingTimeInterval(86401)).mergedLast24hPRs.isEmpty)

        // A corrected wall clock must restore rows that re-enter the rolling window.
        XCTAssertEqual(read(at: now).mergedLast24hPRs.map(\.id), [2, 1])
    }

    @MainActor
    func testClockExpiryPublishesNewSnapshotAndUpdatesCoordinatorWithoutSourceRevision() {
        let boundary = makePR(1, mergedAt: now.addingTimeInterval(-86400))
        let duplicate = makePR(1, mergedAt: now)
        let expires = makePR(2, mergedAt: now.addingTimeInterval(-86400))
        var list = makeList([])
        list.mergedPullRequests = [boundary, duplicate, expires]
        var cache = PRPanelProjectionCache()
        let sourceRevision: UInt64 = 7
        func snapshot(at clock: Date) -> PRPanelSnapshot {
            let projection = cache.projection(revision: sourceRevision, now: clock) {
                PRPanelProjection.make(prList: list, searchText: "", selections: [:],
                                       pinnedIdentifiers: [], configuration: .default, now: $0)
            }
            return PRPanelSnapshot(
                prList: list, projection: projection, rateLimitInfo: .empty, restRateLimitInfo: .empty,
                configuration: .default, jiraConnectionState: .configured,
                pinnedIdentifiers: [], activeFacetSelections: [:], activityReminderCount: 0,
                openingPRIDs: [], updatingBranchPRIDs: [], loadingHoverDetailPRIDs: [],
                facetChips: [], facetOptions: projection.facetOptions, labelSuggestions: [],
                savedViews: [], now: clock,
                presentationRevision: sourceRevision &+ cache.publicationGeneration
            )
        }
        let coordinator = PanelInteractionCoordinator()
        let initial = snapshot(at: now)
        coordinator.receive(snapshot: initial, reason: .userIntent)
        let initialCommit = coordinator.commitRevision
        // The fixed fixture clock and inclusive boundary produce no extra publication.
        XCTAssertEqual(snapshot(at: now).presentationRevision, initial.presentationRevision)
        XCTAssertEqual(coordinator.displayedStructure?.mergedLast24hPRs.count, 2)
        XCTAssertEqual(coordinator.displayedStructure?.pr(for: PRPanelRowID(section: .mergedToday, prID: 1))?.mergedAt, boundary.mergedAt)

        let expired = snapshot(at: now.addingTimeInterval(1))
        XCTAssertNotEqual(expired.presentationRevision, initial.presentationRevision)
        // This is the same revision gate used by PRPanelView.onChange.
        if expired.presentationRevision != initial.presentationRevision {
            coordinator.receive(snapshot: expired)
        }
        XCTAssertGreaterThan(coordinator.commitRevision, initialCommit)
        XCTAssertEqual(coordinator.displayedStructure?.mergedLast24hPRs.map(\.id), [1])
        XCTAssertEqual(coordinator.displayedSnapshot?.projection.mergedLast24hPRs.first?.mergedAt, duplicate.mergedAt)
        XCTAssertEqual(coordinator.displayedSnapshot?.presentationRevision, expired.presentationRevision)
    }

    func testSourceDeduplicationKeepsFirstFactsButRolesKeepDistinctIdentities() {
        let authored = makePR(1)
        let mentioned = makePR(1, title: "Mentioned version")
        var list = makeList([authored])
        list.mentionedPullRequests = [mentioned]
        list.directMentionPullRequests = [mentioned]
        let projection = project(list)
        XCTAssertEqual(projection.sourcePRs.count, 1)
        XCTAssertEqual(projection.sourcePRs.first?.title, authored.title)
        let authoredID = PRPanelRowID(section: .authored, prID: 1)
        let mentionID = PRPanelRowID(section: .mentioned, prID: 1)
        XCTAssertNotEqual(authoredID, mentionID)
        XCTAssertEqual(projection.pr(for: mentionID)?.title, "Mentioned version")
        XCTAssertEqual(projection.displayedRowIDs(for: .directMentions).map(\.prID), [1])
    }

    func testSameIDFactsAndConfigurationChangeAreNotLostToPREquality() {
        var first = makePR(1)
        first.approvalCount = 2
        var config = Configuration.default
        config.minimumApprovalsForReadyToMerge = 2
        let before = project(makeList([first]), configuration: config)
        XCTAssertEqual(before.summaryReadyToMerge, 1)
        var changed = makePR(1, title: "New title")
        changed.approvalCount = first.approvalCount
        changed.ciStatus = .unknown
        changed.changesRequestedCount = 1
        XCTAssertEqual(first, changed, "Model equality intentionally does not detect changed facts")
        let after = project(makeList([changed]), configuration: config)
        XCTAssertEqual(after.pr(for: PRPanelRowID(section: .authored, prID: 1))?.title, "New title")
        XCTAssertEqual(after.summaryCIFailing, 1)
        XCTAssertEqual(after.summaryChangesRequested, 1)
        XCTAssertEqual(after.summaryReadyToMerge, 0)
        config.minimumApprovalsForReadyToMerge = 3
        XCTAssertEqual(project(makeList([first]), configuration: config).summaryReadyToMerge, 0)
    }

    func testSummaryCountsKeepTheirOriginalSourceScopes() {
        var authored = makePR(1)
        authored.ciStatus = .unknown
        var review = makePR(2, category: .reviewRequest)
        review.ciStatus = .pending
        review.checkPendingCount = 1
        review.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])
        var mentionOnly = makePR(3)
        mentionOnly.ciStatus = .failure
        var list = makeList([authored, review])
        list.mentionedPullRequests = [mentionOnly]
        let projection = project(list)
        XCTAssertEqual(projection.summaryCIFailing, 1, "Mention-only PRs are outside the original CI summary source")
        XCTAssertEqual(projection.summaryCIRunning, 1)
        XCTAssertEqual(projection.summaryWaitingForMyReview, 1)
    }

    func testQueryDiagnosticsShareAliasAndComparatorSemantics() {
        let invalid = [
            "ci:purple": "Unknown CI filter",
            "pr:closed": "Unknown PR filter",
            "pr:": "Use pr:conflict",
            "approval:>=x": "Use approval:<number> or a comparison such as approval:>=2"
        ]
        var pr = makePR(1, hasBaseConflicts: true)
        pr.approvalCount = 2
        pr.jiraTicket = "ci:fail"
        let list = makeList([pr])
        for (query, message) in invalid {
            XCTAssertEqual(PRSearchScope.validationMessage(for: query), message)
            XCTAssertTrue(project(list, query: query).filteredPRs.isEmpty)
        }
        for query in ["ci:", "ci:value", "ci:green", "pr:conflicts", "approval:", "approval:>= 2", "approval:==2", "jira:ci:fail"] {
            XCTAssertNil(PRSearchScope.validationMessage(for: query), query)
            XCTAssertEqual(project(list, query: query).filteredPRs.map(\.id), [1], query)
        }
        XCTAssertNil(PRSearchScope.validationMessage(for: "approval:-1"))
        XCTAssertTrue(project(list, query: "approval:-1").filteredPRs.isEmpty)
        XCTAssertNil(PRSearchScope.validationMessage(for: "unknown:value"))
        XCTAssertEqual(PRSearchScope.parse("unknown:value").term, "unknown:value")
        XCTAssertEqual(PRSearchScope.suggestions(for: "ci:purple").map(\.query), ["ci:pass", "ci:failure", "ci:running"])
        XCTAssertEqual(PRSearchScope.suggestions(for: "pr:closed").map(\.query), ["pr:conflict"])
        for (query, matches) in [("approval:<2", false), ("approval:<=2", true), ("approval:>2", false), ("approval:>=2", true), ("approval:=2", true)] {
            XCTAssertEqual(!project(list, query: query).filteredPRs.isEmpty, matches, query)
        }
    }

    func testActionsResolveCurrentSameIDLinksAndRejectChangedRevisionWrites() throws {
        let captured = makePR(1)
        var changed = makePR(1, repo: "renamed", title: "Updated facts")
        changed.headCommitOid = "new-sha"
        changed.jiraTicket = "DEMO-99"
        let neighbor = makePR(2)
        let list = makeList([neighbor, changed])
        let latest = try PRPanelActionResolver.resolve(
            id: captured.id, capturedHeadCommitOID: captured.headCommitOid,
            requiresUnchangedHead: false, in: list
        ).get()
        XCTAssertEqual(latest.id, captured.id)
        XCTAssertEqual(latest.url, changed.url)
        XCTAssertEqual(latest.jiraTicket, "DEMO-99")
        XCTAssertEqual(latest.repoFullName, changed.repoFullName)
        XCTAssertEqual(PRPanelActionResolver.jiraIssueKey(requested: "demo-99", for: latest), "DEMO-99")
        XCTAssertNil(PRPanelActionResolver.jiraIssueKey(requested: "DEMO-42", for: latest))
        XCTAssertThrowsError(try PRPanelActionResolver.resolve(
            id: captured.id, capturedHeadCommitOID: captured.headCommitOid,
            requiresUnchangedHead: true, in: list
        ).get()) { error in
            XCTAssertEqual(error as? PRPanelActionError, .changedRevision)
            XCTAssertEqual((error as? PRPanelActionError)?.message, "PR changed. Reopen the menu and try again.")
        }
        XCTAssertEqual(try PRPanelActionResolver.resolve(
            id: changed.id, capturedHeadCommitOID: changed.headCommitOid,
            requiresUnchangedHead: true, in: list
        ).get().id, changed.id)
        XCTAssertThrowsError(try PRPanelActionResolver.resolve(
            id: captured.id, capturedHeadCommitOID: captured.headCommitOid,
            requiresUnchangedHead: false, in: makeList([neighbor])
        ).get()) { error in
            XCTAssertEqual(error as? PRPanelActionError, .unavailable)
        }
    }

    func testActionLookupIncludesEveryRoleAndNeverFallsBackToNeighbor() {
        let target = makePR(7)
        var list = makeList([makePR(1)])
        list.mentionedPullRequests = [target]
        XCTAssertEqual(PRPanelActionResolver.latestPR(id: 7, in: list)?.id, 7)
        list.mentionedPullRequests = []
        list.directMentionPullRequests = [target]
        XCTAssertEqual(PRPanelActionResolver.latestPR(id: 7, in: list)?.id, 7)
        list.directMentionPullRequests = []
        list.mergedPullRequests = [target]
        XCTAssertEqual(PRPanelActionResolver.latestPR(id: 7, in: list)?.id, 7)
        XCTAssertNil(PRPanelActionResolver.latestPR(id: 8, in: list))
    }

    private func project(
        _ list: PRList, query: String = "", selections: [FacetFieldID: Set<String>] = [:],
        pins: Set<String> = [], configuration: Configuration = .default
    ) -> PRPanelProjection {
        PRPanelProjection.make(prList: list, searchText: query, selections: selections,
                               pinnedIdentifiers: pins, configuration: configuration, now: now)
    }

    private func makeList(_ prs: [PullRequest]) -> PRList {
        PRList(lastUpdated: now, pullRequests: prs, isLoading: false, error: nil)
    }

    private func makePR(
        _ id: Int, repo: String = "project", age: TimeInterval = 0,
        category: PRCategory = .authored, title: String? = nil,
        mergedAt: Date? = nil, hasBaseConflicts: Bool = false
    ) -> PullRequest {
        let date = now.addingTimeInterval(-age)
        return PullRequest(
            id: id, number: id, title: title ?? "Example PR \(id)", author: "example-user", authorAvatarURL: nil,
            repositoryOwner: "example", repositoryName: repo,
            url: URL(string: "https://github.com/example/\(repo)/pull/\(id)")!,
            state: mergedAt == nil ? .open : .merged, isDraft: false, createdAt: date.addingTimeInterval(-3600), updatedAt: date,
            mergedAt: mergedAt, body: nil, conversationComments: [], lastCommitAt: date, headCommitOid: "fixed-sha",
            reviewThreads: [], category: category, hasBaseConflicts: hasBaseConflicts, ciStatus: .success,
            checkSuccessCount: 1, checkFailureCount: 0, checkPendingCount: 0, githubCIState: "success",
            myLastReviewState: nil, myLastReviewAt: nil, reviewRequestedAt: nil, myThreadsAllResolved: false,
            approvalCount: 0, changesRequestedCount: 0, ciExtendedInfo: nil
        )
    }
}
