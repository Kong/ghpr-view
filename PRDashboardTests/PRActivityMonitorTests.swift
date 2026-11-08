import XCTest
@testable import PRDashboard

/// End-to-end monitor behavior with a fake acquisition source and fake channels:
/// silent baseline, no duplicate events, source sequences, relevance, action items,
/// digest windowing and per-channel receipts.
@MainActor
final class PRActivityMonitorTests: XCTestCase {
    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let viewer = MonitorViewerIdentity(nodeID: "U_VIEWER", login: "octocat", databaseID: 42)
    private let reference = PullRequestReference(owner: "owner", repo: "repo", number: 42)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-monitor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Harness

    private func makeMonitor(
        configuration: Configuration = .default,
        store: PRActivityStore? = nil,
        acquisition: FakeMonitorAcquisition? = nil,
        channels: [PRActivityDigestChannel] = [],
        isMuted: @escaping (PullRequestReference) -> Bool = { _ in false }
    ) -> (PRActivityMonitor, FakeMonitorAcquisition) {
        let fake = acquisition ?? FakeMonitorAcquisition(viewer: viewer)
        let monitor = PRActivityMonitor(
            store: store ?? PRActivityStore(directoryURL: directory),
            configuration: configuration,
            clock: { [weak self] in self?.now ?? Date() },
            isMuted: isMuted
        )
        monitor.setAcquisition(fake)
        monitor.setChannels(channels)
        monitor.setViewerForTesting(viewer)
        return (monitor, fake)
    }

    private func observation(
        source: MonitorSourceKind,
        payload: MonitorSourcePayload,
        prNodeID: String = "PR_42"
    ) -> MonitorSourceObservation {
        MonitorSourceObservation(
            source: source,
            isComplete: true,
            incompleteReason: nil,
            payload: payload,
            observedAt: now
        )
    }

    private func header(headOID: String = "sha1", state: PRState = .open, title: String = "Add feature") -> MonitorSourcePayload {
        MonitorSourcePayload(header: MonitorHeaderSnapshot(
            state: state,
            isDraft: false,
            title: title,
            url: URL(string: "https://github.com/owner/repo/pull/42"),
            headOID: headOID,
            baseRefName: "main",
            headRefName: "feature",
            updatedAt: now,
            isArchived: false
        ))
    }

    private func review(id: String = "R_1", state: String = "CHANGES_REQUESTED", author: String = "alice", authorNodeID: String = "U_ALICE", commit: String = "sha1") -> MonitorReview {
        MonitorReview(
            id: id,
            author: author,
            authorNodeID: authorNodeID,
            state: state,
            body: "please fix",
            url: URL(string: "https://github.com/owner/repo/pull/42#pullrequestreview-\(id)"),
            submittedAt: now,
            commitOID: commit
        )
    }

    private func thread(id: String = "T_1", resolved: Bool = false, comments: [MonitorThreadComment]) -> MonitorReviewThread {
        MonitorReviewThread(id: id, isResolved: resolved, isOutdated: false, path: "a.swift", line: 3, comments: comments)
    }

    private func comment(id: String, author: String = "alice", authorNodeID: String = "U_ALICE", replyTo: String? = nil, body: String = "text") -> MonitorThreadComment {
        MonitorThreadComment(
            id: id,
            reviewID: "R_1",
            author: author,
            authorNodeID: authorNodeID,
            body: body,
            url: URL(string: "https://github.com/owner/repo/pull/42#discussion_r\(id)"),
            createdAt: now,
            lastEditedAt: nil,
            replyToID: replyTo,
            path: "a.swift",
            line: 3
        )
    }

    private func conversationComment(id: String, body: String = "hello", author: String = "alice", authored: Date? = nil) -> MonitorConversationComment {
        MonitorConversationComment(
            id: id,
            author: author,
            authorNodeID: "U_ALICE",
            body: body,
            url: URL(string: "https://github.com/owner/repo/pull/42#issuecomment-\(id)"),
            createdAt: authored ?? now,
            lastEditedAt: nil
        )
    }

    private func setObservation(_ fake: FakeMonitorAcquisition, _ observations: [MonitorSourceObservation]) {
        fake.observationOutcome = MonitorSnapshotOutcome(
            observations: [
                MonitorPRObservation(
                    prNodeID: "PR_42",
                    reference: reference,
                    observations: observations,
                    capturedHeadOID: "sha1",
                    capturedAt: now
                )
            ],
            deferralReason: nil
        )
    }

    private func discoveredPR(_ fake: FakeMonitorAcquisition, origins: Set<MonitorOrigin> = [.authored]) {
        fake.discoveryOutcome = MonitorDiscoveryOutcome(
            discovered: [
                MonitorDiscoveryOutcome.DiscoveredReference(
                    prNodeID: "PR_42",
                    reference: reference,
                    title: "Add feature",
                    url: URL(string: "https://github.com/owner/repo/pull/42"),
                    lifecycle: .open,
                    headOID: "sha1",
                    updatedAt: now,
                    origins: origins
                )
            ],
            coverage: MonitorDiscoveryCoverage(queries: [], attemptedAt: now)
        )
    }

    // MARK: - Baseline and idempotency

    func testFirstCompleteObservationEstablishesBaselineWithoutEvents() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
            observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [thread(comments: [comment(id: "C_1")])])),
        ])

        await monitor.runPassForTesting()

        let state = try? XCTUnwrap(monitor.currentStateForTesting())
        XCTAssertEqual(state?.events.count, 0, "The first observation must record a baseline instead of replaying history")
        XCTAssertEqual(state?.monitoredPRs.count, 1)
        XCTAssertFalse(state?.monitoredPRs.first?.isExplicitlyTracked ?? true)
        XCTAssertEqual(monitor.snapshot.actionItems.count, 0)
    }

    func testRepeatedIdenticalObservationProducesNoDuplicateEvents() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        let baseline: [MonitorSourceObservation] = [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ]
        setObservation(fake, baseline)
        await monitor.runPassForTesting()
        setObservation(fake, baseline)
        await monitor.runPassForTesting()

        XCTAssertEqual(monitor.currentStateForTesting()?.events.count, 0, "An unchanged snapshot must not create events")
        XCTAssertEqual(monitor.currentStateForTesting()?.monitoredPRs.first?.sequence(for: .reviews), 0)
    }

    // MARK: - Event derivation

    func testNewReviewRequestsChangesAndBecomesAnActionItem() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        // Production always reads every source on the first pass, so the baseline
        // covers all of them.
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [])),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [])),
            observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()

        let state = try? XCTUnwrap(monitor.currentStateForTesting())
        XCTAssertEqual(state?.events.count, 1, "A first-time review must produce exactly one event")
        XCTAssertEqual(state?.events.first?.kind, .reviewSubmitted)
        XCTAssertEqual(state?.monitoredPRs.first?.sequence(for: .reviews), 1)

        let item = try? XCTUnwrap(state?.actionItems.first)
        XCTAssertEqual(item?.reasons, [.authoredPRReviewFeedback])
        XCTAssertEqual(item?.actionKinds, [.reviewFeedback])
        XCTAssertEqual(item?.state, .open)
    }

    func testThreadResolveReopenResolveProducesThreeDistinctEvents() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        let openThread = thread(resolved: false, comments: [comment(id: "C_1")])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [openThread])),
        ])
        await monitor.runPassForTesting()

        for resolved in [true, false, true] {
            setObservation(fake, [
                observation(source: .header, payload: header()),
                observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [thread(resolved: resolved, comments: [comment(id: "C_1")])])),
            ])
            await monitor.runPassForTesting()
        }

        let events = monitor.currentStateForTesting()?.events.filter { $0.kind == .threadResolved } ?? []
        XCTAssertEqual(events.count, 2, "Two resolves separated by a reopen are two changes")
        XCTAssertEqual(Set(events.map(\.id)).count, 2, "Each resolve needs its own stable event identity")
        let reopens = monitor.currentStateForTesting()?.events.filter { $0.kind == .threadReopened } ?? []
        XCTAssertEqual(reopens.count, 1)
    }

    func testThreadReplyAndEditedCommentAreDetectedWithoutTouchingCounts() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.reviewed])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [conversationComment(id: "IC_1")])),
            observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [thread(comments: [comment(id: "C_1")])])),
        ])
        await monitor.runPassForTesting()

        var edited = conversationComment(id: "IC_1")
        edited.lastEditedAt = now.addingTimeInterval(120)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [edited, conversationComment(id: "IC_2", body: "another")])),
            observation(source: .reviewThreads, payload: MonitorSourcePayload(reviewThreads: [thread(comments: [comment(id: "C_1"), comment(id: "C_2", replyTo: "C_1")])])),
        ])
        await monitor.runPassForTesting()

        let kinds = Set((monitor.currentStateForTesting()?.events ?? []).map(\.kind))
        XCTAssertTrue(kinds.contains(.conversationCommentEdited), "An early comment edit must be detected even when the comment count is unchanged")
        XCTAssertTrue(kinds.contains(.conversationCommentAdded))
        XCTAssertTrue(kinds.contains(.threadReplyAdded), "A reply appended to an existing thread must be detected")
    }

    func testPendingReviewIsNeverStoredAsSubmitted() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [observation(source: .header, payload: header())])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review(state: "PENDING")])),
        ])
        await monitor.runPassForTesting()

        XCTAssertEqual(monitor.currentStateForTesting()?.events.count, 0, "A pending review is not a submitted review")
        XCTAssertEqual(monitor.currentStateForTesting()?.monitoredPRs.first?.checkpoint(for: .reviews)?.reviews?.count, 0)
    }

    func testIncompleteSourceKeepsPreviousCheckpointAndReportsReason() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            MonitorSourceObservation(
                source: .reviews,
                isComplete: false,
                incompleteReason: MonitorIncompleteReason(kind: .repeatedCursor, statusCode: nil, detail: "cursor repeated"),
                payload: nil,
                observedAt: now
            ),
        ])
        await monitor.runPassForTesting()

        let pr = monitor.currentStateForTesting()?.monitoredPRs.first
        XCTAssertEqual(pr?.unhealthyReason(for: .reviews)?.kind, .repeatedCursor)
        XCTAssertEqual(pr?.checkpoint(for: .reviews)?.reviews?.count, 1, "An incomplete read must not replace the checkpoint")
        XCTAssertEqual(pr?.sequence(for: .reviews), 0, "An incomplete read must not advance the source sequence")
        XCTAssertEqual(monitor.currentStateForTesting()?.events.count, 0)
    }

    func testPushedCommitAfterReviewNeedsRereviewAndNotAfterReviewingIt() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.reviewed])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_MINE", state: "APPROVED", author: "octocat", authorNodeID: "U_VIEWER", commit: "sha1")
            ])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header(headOID: "sha2")),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_MINE", state: "APPROVED", author: "octocat", authorNodeID: "U_VIEWER", commit: "sha1")
            ])),
        ])
        await monitor.runPassForTesting()

        XCTAssertEqual(
            monitor.currentStateForTesting()?.actionItems.first?.reasons,
            [.myReviewNeedsRereview],
            "Pushing a new revision after the viewer's review needs a re-review"
        )

        // Reviewing the new head retires the item on the next head comparison.
        setObservation(fake, [
            observation(source: .header, payload: header(headOID: "sha2")),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_MINE", state: "APPROVED", author: "octocat", authorNodeID: "U_VIEWER", commit: "sha1"),
                review(id: "R_MINE_2", state: "APPROVED", author: "octocat", authorNodeID: "U_VIEWER", commit: "sha2"),
            ])),
        ])
        await monitor.runPassForTesting()

        let events = monitor.currentStateForTesting()?.events ?? []
        let rereviewEvents = events.filter { $0.kind == .pushedNewCommit }
        XCTAssertEqual(rereviewEvents.count, 1, "The stored commit already covers the new head")
    }

    func testDismissedViewerReviewIsActionable() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.reviewed])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_MINE", state: "APPROVED", author: "octocat", authorNodeID: "U_VIEWER")
            ])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_MINE", state: "DISMISSED", author: "octocat", authorNodeID: "U_VIEWER")
            ])),
        ])
        await monitor.runPassForTesting()

        let item = monitor.currentStateForTesting()?.actionItems.first
        XCTAssertEqual(item?.reasons, [.myApprovalDismissed])
        XCTAssertEqual(item?.actionKinds, [.reReview])
    }

    func testViewerActionsAndBotChatterDoNotCreateActionItems() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [])),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [
                MonitorConversationComment(
                    id: "IC_SELF",
                    author: "octocat",
                    authorNodeID: "U_VIEWER",
                    body: "note to self",
                    url: nil,
                    createdAt: now,
                    lastEditedAt: nil
                ),
                MonitorConversationComment(
                    id: "IC_BOT",
                    author: "dependabot[bot]",
                    authorNodeID: "U_BOT",
                    body: "bumped deps",
                    url: nil,
                    createdAt: now,
                    lastEditedAt: nil
                ),
            ])),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [
                review(id: "R_BOT", state: "COMMENTED", author: "codex[bot]", authorNodeID: "U_AGENT")
            ])),
        ])
        await monitor.runPassForTesting()

        let state = monitor.currentStateForTesting()
        XCTAssertEqual(state?.events.count, 3, "History still records the raw activity")
        XCTAssertEqual(state?.actionItems.count, 0, "Neither the viewer's own comment nor bot chatter is actionable")
    }

    func testDirectMentionFromBotStillBecomesAnActionItem() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.reviewed])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [])),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .conversationComments, payload: MonitorSourcePayload(conversationComments: [
                MonitorConversationComment(
                    id: "IC_MENTION",
                    author: "review-bot[bot]",
                    authorNodeID: "U_BOT",
                    body: "@octocat please confirm the rollout plan",
                    url: nil,
                    createdAt: now,
                    lastEditedAt: nil
                )
            ])),
        ])
        await monitor.runPassForTesting()

        XCTAssertEqual(
            monitor.currentStateForTesting()?.actionItems.first?.reasons,
            [.authoredPRDirectMention],
            "An explicit request to the user must survive bot suppression"
        )
    }

    func testCIFailureOnCurrentHeadIsActionableAndOldHeadFailureIsIgnored() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header(headOID: "sha2")),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "FAILURE")
            ]))),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header(headOID: "sha2")),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha2", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "FAILURE"),
                check(id: "job-2", headOID: "sha2", conclusion: "FAILURE"),
            ]))),
        ])
        await monitor.runPassForTesting()

        let failures = (monitor.currentStateForTesting()?.events ?? []).filter { $0.kind == .ciCheckFailed }
        XCTAssertEqual(failures.count, 1, "A failure from a superseded head must not be reported")
        XCTAssertEqual(failures.first?.revision.headOID, "sha2")
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.reasons, [.authoredPRCIFailure])
    }

    func testCIRecoveryRetiresTheFailureItem() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        // Baseline with a passing check, then a failure, then the recovery.
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "SUCCESS")
            ]))),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "FAILURE")
            ]))),
        ])
        await monitor.runPassForTesting()
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.reasons, [.authoredPRCIFailure])

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "SUCCESS")
            ]))),
        ])
        await monitor.runPassForTesting()

        let state = monitor.currentStateForTesting()
        XCTAssertEqual(state?.events.filter { $0.kind == .ciCheckRecovered }.count, 1)
        XCTAssertEqual(state?.actionItems.first?.state, .recovered)
        XCTAssertFalse(state?.actionItems.first?.isActionable(now: now) ?? true)
    }

    func testRecoveredCIFailureIsNotSentOnTheNextWindow() async {
        let channel = FakeDigestChannel(isAvailable: true, binding: [:], failure: SlackClientError.rateLimited(retryAfter: 30))
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "SUCCESS")
            ]))),
        ])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "FAILURE")
            ]))),
        ])
        await monitor.runPassForTesting()

        monitor.runDigestForTesting()
        await waitForDelivery(channel)
        XCTAssertEqual(monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status, .failed)

        channel.failure = nil
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "SUCCESS")
            ]))),
        ])
        await monitor.runPassForTesting()
        now = now.addingTimeInterval(PRActivityMonitor.digestWindow + 60)
        let attempts = channel.attemptCount
        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(channel.attemptCount, attempts, "A CI failure that later passed must not be sent")
        XCTAssertTrue(channel.deliveredBatches.isEmpty)
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.state, .recovered)
        XCTAssertEqual(
            monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status,
            .superseded
        )
    }

    func testSuccessfulRerunInvalidatesTheEarlierFailure() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: []))),
        ])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-1", headOID: "sha1", conclusion: "FAILURE")
            ]))),
        ])
        await monitor.runPassForTesting()
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.reasons, [.authoredPRCIFailure])

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-2", headOID: "sha1", conclusion: "SUCCESS")
            ]))),
        ])
        await monitor.runPassForTesting()

        let item = monitor.currentStateForTesting()?.actionItems.first
        XCTAssertEqual(item?.state, .recovered, "A later successful attempt invalidates the earlier failure")
        XCTAssertFalse(item?.isActionable(now: now) ?? true)
    }

    func testOneJobPassingDoesNotInvalidateADifferentFailingJob() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: []))),
        ])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-build", headOID: "sha1", conclusion: "FAILURE", name: "build", runID: "run-build"),
                check(id: "job-lint", headOID: "sha1", conclusion: "FAILURE", name: "lint", runID: "run-lint"),
            ]))),
        ])
        await monitor.runPassForTesting()

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .ci, payload: MonitorSourcePayload(ci: MonitorCISnapshot(headOID: "sha1", checks: [
                check(id: "job-build", headOID: "sha1", conclusion: "SUCCESS", name: "build", runID: "run-build"),
                check(id: "job-lint", headOID: "sha1", conclusion: "FAILURE", name: "lint", runID: "run-lint"),
            ]))),
        ])
        await monitor.runPassForTesting()

        let item = monitor.currentStateForTesting()?.actionItems.first
        XCTAssertEqual(item?.state, .open, "A different job that is still failing stays a reminder")
        XCTAssertEqual(item?.pendingEventIDs.count, 1)
    }

    func testUnwatchedRepositoryIsNotMonitoredOrNotified() async {
        var configuration = Configuration.default
        configuration.repositories = ["owner/repo", "example-org/"]
        let channel = deliveredChannel()
        let (monitor, fake) = makeMonitor(configuration: configuration, channels: [channel])
        fake.discoveryOutcome = MonitorDiscoveryOutcome(
            discovered: [
                MonitorDiscoveryOutcome.DiscoveredReference(
                    prNodeID: "PR_42",
                    reference: reference,
                    title: "Add feature",
                    url: URL(string: "https://github.com/owner/repo/pull/42"),
                    lifecycle: .open,
                    headOID: "sha1",
                    updatedAt: now,
                    origins: [.authored]
                ),
                MonitorDiscoveryOutcome.DiscoveredReference(
                    prNodeID: "PR_WIN",
                    reference: PullRequestReference(owner: "xiaocang", repo: "easydict_win32", number: 234),
                    title: "Side project",
                    url: URL(string: "https://github.com/xiaocang/easydict_win32/pull/234"),
                    lifecycle: .open,
                    headOID: "sha1",
                    updatedAt: now,
                    origins: [.authored]
                )
            ],
            coverage: MonitorDiscoveryCoverage(queries: [], attemptedAt: now)
        )
        setObservation(fake, [observation(source: .header, payload: header())])
        await monitor.runPassForTesting()

        let repos = Set(monitor.currentStateForTesting()?.monitoredPRs.map(\.reference.repoFullName) ?? [])
        XCTAssertEqual(repos, ["owner/repo"], "An authored PR outside the PR list filter is not activity")
        XCTAssertFalse(configuration.isRepositoryNotified("xiaocang/easydict_win32"))
        XCTAssertTrue(configuration.isRepositoryNotified("example-org/example-repo"))
        XCTAssertTrue(configuration.collectsActivity(for: "xiaocang/easydict_win32", explicitlyTracked: true))
    }

    func testNarrowingRepositoryFilterCancelsAnUnsentDigestWithoutAnotherPass() async {
        let channel = deliveredChannel()
        let (monitor, _) = makeMonitor(configuration: .default, channels: [channel])
        let side = PullRequestReference(owner: "xiaocang", repo: "easydict_win32", number: 234)
        let event = PRActivityEvent(
            id: "event-side",
            identityKey: "review:R_side:COMMENTED",
            kind: .reviewSubmitted,
            prNodeID: "PR_WIN",
            reference: side,
            actor: "codex",
            actorNodeID: "U_CODEX",
            isFromViewer: false,
            subjectIsViewer: false,
            isBotActor: true,
            containsDirectMention: false,
            occurredAt: now,
            url: nil,
            revision: PRActivityRevision(headOID: "sha1", reviewID: "R_side"),
            sourceChangeSequence: 1
        )
        var state = PRActivityAccountState(
            account: MonitorAccountKey(endpoint: "", viewerNodeID: viewer.nodeID, login: viewer.login),
            updatedAt: now
        )
        state.events = [event]
        state.monitoredPRs = [
            MonitoredPR(
                prNodeID: "PR_WIN",
                reference: side,
                origins: [.authored],
                lifecycle: .open,
                title: "Side project",
                discoveredAt: now,
                lastObservedAt: now
            )
        ]
        state.actionItems = [
            PRActionItem(
                id: "item-side",
                prNodeID: "PR_WIN",
                reference: side,
                reasons: [.authoredPRReviewFeedback],
                actionKinds: [.reviewFeedback],
                eventIDs: [event.id],
                revision: event.revision,
                state: .open,
                createdAt: now,
                stateUpdatedAt: now,
                snoozedUntil: nil,
                coveredEventIDs: [],
                evidenceURLs: []
            )
        ]
        state.digest.batches = [
            DigestBatch(
                id: "digest-side",
                createdAt: now,
                entries: [],
                coveredEventIDs: [event.id],
                coveredActionItemIDs: ["item-side"],
                omittedEntryCount: 0,
                deliveries: [
                    DigestDelivery(
                        channel: .macOS,
                        status: .failed,
                        attemptedAt: now,
                        completedAt: now,
                        receipt: nil,
                        failureMessage: "rate limited",
                        targetWorkspace: nil,
                        targetUserID: nil
                    )
                ]
            )
        ]
        monitor.setStateForTesting(state, viewer: viewer)

        var narrowed = Configuration.default
        narrowed.repositories = ["example-org/other-repo"]
        monitor.applyConfiguration(narrowed)
        monitor.retryDigestBatch(id: "digest-side")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(channel.deliveredBatches.isEmpty, "Retrying after the filter changes must not send the excluded repository")
        XCTAssertEqual(channel.attemptCount, 0)
        XCTAssertEqual(
            monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status,
            .superseded
        )
    }

    func testHandledItemReopensOnlyForNewActivity() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [observation(source: .header, payload: header()), observation(source: .reviews, payload: MonitorSourcePayload(reviews: []))])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review(id: "R_1")])),
        ])
        await monitor.runPassForTesting()

        let item = try? XCTUnwrap(monitor.currentStateForTesting()?.actionItems.first)
        monitor.markHandled(itemID: item?.id ?? "")
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.state, .handled)

        // Repeating the same snapshot keeps it handled.
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review(id: "R_1")])),
        ])
        await monitor.runPassForTesting()
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.state, .handled)

        // A new review reopens it while the handled history stays recorded.
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review(id: "R_1"), review(id: "R_2", state: "COMMENTED")])),
        ])
        await monitor.runPassForTesting()

        let reopened = monitor.currentStateForTesting()?.actionItems.first
        XCTAssertEqual(reopened?.state, .open)
        XCTAssertFalse(reopened?.coveredEventIDs.isEmpty ?? true, "The handled version must stay recorded")
        XCTAssertEqual(reopened?.pendingEventIDs.count, 1)
    }

    func testMergedPRSupersedesOpenItems() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake)
        setObservation(fake, [observation(source: .header, payload: header()), observation(source: .reviews, payload: MonitorSourcePayload(reviews: []))])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.state, .open)

        setObservation(fake, [
            observation(source: .header, payload: header(state: .merged)),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()

        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first?.state, .superseded)
        XCTAssertEqual(monitor.snapshot.actionItems.first?.isActionable(now: now), false)
    }

    // MARK: - Digests

    private func deliveredChannel(binding: [String: String] = [:]) -> FakeDigestChannel {
        FakeDigestChannel(isAvailable: true, binding: binding)
    }

    private func seedActionableItem(_ monitor: PRActivityMonitor, _ fake: FakeMonitorAcquisition) async {
        discoveredPR(fake)
        setObservation(fake, [observation(source: .header, payload: header()), observation(source: .reviews, payload: MonitorSourcePayload(reviews: []))])
        await monitor.runPassForTesting()
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()
    }

    func testDigestIsDeliveredOncePerWindowAndNotRepeatedWithoutNewWork() async {
        let channel = deliveredChannel()
        let (monitor, fake) = makeMonitor(
            configuration: .default,
            channels: [channel]
        )
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        await waitForDelivery(channel)
        XCTAssertEqual(channel.deliveredBatches.count, 1, "One batch must be delivered for the new work")

        let announced = monitor.currentStateForTesting()?.digest.announcedEventIDs.count ?? 0
        XCTAssertGreaterThan(announced, 0, "A delivered batch marks its events as announced")

        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(channel.deliveredBatches.count, 1, "The same work must not be announced twice without a new window and new events")

        now = now.addingTimeInterval(PRActivityMonitor.digestWindow + 60)
        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(channel.deliveredBatches.count, 1, "A later window with no new events must stay silent")
    }

    func testFailedDeliveryKeepsEventsAnnounceableForTheNextWindow() async {
        let channel = FakeDigestChannel(isAvailable: true, binding: [:], failure: SlackClientError.rateLimited(retryAfter: 30))
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        await waitForDelivery(channel)

        let batch = monitor.currentStateForTesting()?.digest.batches.first
        XCTAssertEqual(batch?.deliveries.first?.status, .failed)
        XCTAssertTrue(
            monitor.currentStateForTesting()?.digest.announcedEventIDs.isEmpty ?? false,
            "A failed delivery must not mark the work as announced"
        )

        channel.failure = nil
        now = now.addingTimeInterval(PRActivityMonitor.digestWindow + 60)
        monitor.runDigestForTesting()
        let deadline = Date().addingTimeInterval(2)
        while channel.deliveredBatches.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(channel.deliveredBatches.count, 1, "The retried batch must reach the channel")
        XCTAssertEqual(monitor.currentStateForTesting()?.digest.batches.count, 1, "A failed delivery is retried in place, not cloned into a second reminder")
    }

    func testAbandonedSendingDeliveryBecomesUnknownWithoutResending() async throws {
        let channel = FakeDigestChannel(isAvailable: true, binding: [:])
        let store = PRActivityStore(directoryURL: directory)
        try seedDigestBatch(store: store, status: .sending)
        let (monitor, _) = makeMonitor(store: store, channels: [channel])

        await monitor.runPassForTesting()

        XCTAssertEqual(channel.attemptCount, 0, "An interrupted send must not be delivered again on startup")
        let delivery = monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first
        XCTAssertEqual(delivery?.status, .unknown, "A sending delivery without a receipt must become unknown")
        XCTAssertEqual(
            delivery?.failureMessage,
            "Delivery was interrupted before a receipt was saved."
        )
    }

    func testSuccessfulSendStaysDeliveredWhenPausedDuringDelivery() async throws {
        let channel = SuspendingDigestChannel()
        let store = PRActivityStore(directoryURL: directory)
        try seedDigestBatch(store: store, status: .pending, coveredEventIDs: ["E_1"])
        let (monitor, _) = makeMonitor(store: store, channels: [channel])

        await monitor.runPassForTesting()
        let started = Date().addingTimeInterval(2)
        while channel.attemptCount == 0, Date() < started {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(channel.attemptCount, 1, "The pending delivery should be in flight")
        monitor.setPaused(true)
        channel.resume(with: DigestReceipt(channelID: "C_TEST", workspace: nil, messageTimestamp: "1.0", recipientUserID: nil))

        let deadline = Date().addingTimeInterval(2)
        while monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status != .delivered,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let state = monitor.currentStateForTesting()
        XCTAssertEqual(state?.digest.batches.first?.deliveries.first?.status, .delivered, "A receipt must be kept even if the pass generation changed")
        XCTAssertTrue(
            state?.digest.announcedEventIDs.contains("E_1") ?? false,
            "The covered events must be recorded as announced"
        )
    }

    func testDiscoveryFailureStaysVisible() async {
        let (monitor, fake) = makeMonitor()
        fake.discoveryError = MonitorTransportError.unauthorized

        await monitor.runPassForTesting()

        let coverage = monitor.currentStateForTesting()?.discoveryCoverage
        XCTAssertEqual(coverage?.isComplete, false, "A failed discovery pass must show the incomplete banner")
        let incomplete = Set(coverage?.incompleteOrigins ?? [])
        for origin in MonitorOrigin.allCases {
            XCTAssertTrue(incomplete.contains(origin), "\(origin.rawValue) must be reported incomplete")
        }
    }

    private func seedDigestBatch(
        store: PRActivityStore,
        status: DigestDeliveryStatus,
        coveredEventIDs: [String] = ["E_1"]
    ) throws {
        let account = MonitorAccountKey(endpoint: "", viewerNodeID: viewer.nodeID, login: viewer.login)
        var state = PRActivityAccountState(account: account, updatedAt: now)
        state.digest.batches = [
            DigestBatch(
                id: "batch-1",
                createdAt: now,
                entries: [],
                coveredEventIDs: coveredEventIDs,
                coveredActionItemIDs: [],
                omittedEntryCount: 0,
                deliveries: [
                    DigestDelivery(
                        channel: .macOS,
                        status: status,
                        attemptedAt: status == .sending ? now : nil,
                        completedAt: nil,
                        receipt: nil,
                        failureMessage: nil,
                        targetWorkspace: nil,
                        targetUserID: nil
                    )
                ]
            )
        ]
        try store.persist(state)
    }

    func testExplicitTrackingDoesNotDuplicateAnAlreadyActionableEvent() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.authored])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [])),
        ])
        await monitor.runPassForTesting()
        monitor.setExplicitTracking(prNodeID: "PR_42", eventKinds: nil)

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()

        let items = monitor.currentStateForTesting()?.actionItems ?? []
        XCTAssertEqual(items.count, 1, "Tracking must not add a second reminder for an event that is already actionable")
        XCTAssertEqual(items.first?.reasons, [.authoredPRReviewFeedback])
        XCTAssertEqual(items.first?.eventIDs.count, 1)
    }

    func testExplicitTrackingStillRemindsWhenNothingElseMatches() async {
        let (monitor, fake) = makeMonitor()
        discoveredPR(fake, origins: [.reviewed])
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [])),
        ])
        await monitor.runPassForTesting()
        monitor.setExplicitTracking(prNodeID: "PR_42", eventKinds: nil)

        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])
        await monitor.runPassForTesting()

        let items = monitor.currentStateForTesting()?.actionItems ?? []
        XCTAssertEqual(items.count, 1, "A tracked PR still gets one reminder when no more specific reason matches")
        XCTAssertEqual(items.first?.reasons, [.explicitlyTracked])
    }

    func testDigestDoesNotCloneAnEventAlreadyOwnedByABatch() {
        let event = makeStoredEvent(id: "event-1")
        let shared = makeItem(id: "item-review", reason: .authoredPRReviewFeedback, action: .reviewFeedback, eventIDs: [event.id])
        let duplicate = makeItem(id: "item-tracked", reason: .explicitlyTracked, action: .reviewFeedback, eventIDs: [event.id])
        var state = PRActivityAccountState(
            account: MonitorAccountKey(endpoint: "", viewerNodeID: viewer.nodeID, login: viewer.login),
            updatedAt: now
        )
        state.events = [event]
        state.actionItems = [shared, duplicate]
        state.monitoredPRs = [makeMonitoredPR()]

        let digest = PRActivityEngine.makeDigest(
            state: state,
            configuration: .default,
            now: now,
            mutedNodeIDs: []
        )
        XCTAssertEqual(digest?.entries.first?.eventCount, 1, "One event cited by two items is still one change")
        XCTAssertEqual(digest?.coveredEventIDs, [event.id])

        state.digest.batches = [
            DigestBatch(
                id: "digest-old",
                createdAt: now,
                entries: [],
                coveredEventIDs: [event.id],
                coveredActionItemIDs: [shared.id],
                omittedEntryCount: 0,
                deliveries: [
                    DigestDelivery(
                        channel: .macOS,
                        status: .failed,
                        attemptedAt: now,
                        completedAt: now,
                        receipt: nil,
                        failureMessage: "rate limited",
                        targetWorkspace: nil,
                        targetUserID: nil
                    )
                ]
            )
        ]
        XCTAssertNil(
            PRActivityEngine.makeDigest(state: state, configuration: .default, now: now, mutedNodeIDs: []),
            "An event already owned by a batch must not be cloned into another notification"
        )
    }

    func testRemindersCollapseItemsThatShareAnEventAndKeepDistinctEventsSeparate() {
        let shared = makeItem(id: "item-review", reason: .authoredPRReviewFeedback, action: .reviewFeedback, eventIDs: ["event-1"])
        let duplicate = makeItem(id: "item-tracked", reason: .explicitlyTracked, action: .reviewFeedback, eventIDs: ["event-1"])
        let other = makeItem(id: "item-ci", reason: .authoredPRCIFailure, action: .fixCI, eventIDs: ["event-2"])

        let collapsed = PRActivityEngine.reminders(from: [shared, duplicate])
        XCTAssertEqual(collapsed.count, 1, "Two items citing the same event are one reminder")
        XCTAssertEqual(Set(collapsed[0].itemIDs), Set([shared.id, duplicate.id]))
        XCTAssertEqual(collapsed[0].eventIDs, ["event-1"])

        let separate = PRActivityEngine.reminders(from: [shared, other])
        XCTAssertEqual(separate.count, 2, "A review and a CI failure stay separate reminders")
    }

    func testUnknownDeliveryOutcomeIsNotRetriedAutomatically() async {
        let channel = FakeDigestChannel(
            isAvailable: true,
            binding: [:],
            failure: SlackClientError.responseLost("timed out")
        )
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        await waitForDelivery(channel)

        XCTAssertEqual(monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status, .unknown)

        now = now.addingTimeInterval(PRActivityMonitor.digestWindow + 60)
        let attemptsBefore = channel.attemptCount
        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(channel.attemptCount, attemptsBefore, "An unknown outcome is never retried automatically")
    }

    func testDeliveryRefusesAChangedTargetBinding() async {
        let channel = deliveredChannel(binding: ["workspace": "T_OLD", "user": "U_OLD"])
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        // Binding changes between batch creation and delivery: the batch must not be
        // delivered to the new target.
        channel.binding = ["workspace": "T_NEW", "user": "U_NEW"]
        await waitForDelivery(channel)

        XCTAssertTrue(channel.deliveredBatches.isEmpty, "A batch bound to another target must never be delivered")
        XCTAssertEqual(monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.status, .failed)
        XCTAssertNotNil(monitor.currentStateForTesting()?.digest.batches.first?.deliveries.first?.failureMessage)
    }

    func testDigestCapsEntriesAndReportsTheOmittedCount() async {
        let channel = deliveredChannel()
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        fake.discoveryOutcome = MonitorDiscoveryOutcome(
            discovered: (1...7).map { index in
                MonitorDiscoveryOutcome.DiscoveredReference(
                    prNodeID: "PR_\(index)",
                    reference: PullRequestReference(owner: "owner", repo: "repo", number: index),
                    title: "PR \(index)",
                    url: nil,
                    lifecycle: .open,
                    headOID: "sha1",
                    updatedAt: now,
                    origins: [.authored]
                )
            },
            coverage: MonitorDiscoveryCoverage(queries: [], attemptedAt: now)
        )
        fake.observationOutcome = MonitorSnapshotOutcome(
            observations: (1...7).map { index in
                MonitorPRObservation(
                    prNodeID: "PR_\(index)",
                    reference: PullRequestReference(owner: "owner", repo: "repo", number: index),
                    observations: [
                        observation(source: .reviews, payload: MonitorSourcePayload(reviews: []), prNodeID: "PR_\(index)")
                    ],
                    capturedHeadOID: nil,
                    capturedAt: now
                )
            },
            deferralReason: nil
        )
        await monitor.runPassForTesting()

        fake.observationOutcome = MonitorSnapshotOutcome(
            observations: (1...7).map { index in
                MonitorPRObservation(
                    prNodeID: "PR_\(index)",
                    reference: PullRequestReference(owner: "owner", repo: "repo", number: index),
                    observations: [
                        observation(
                            source: .reviews,
                            payload: MonitorSourcePayload(reviews: [review(id: "R_\(index)")]),
                            prNodeID: "PR_\(index)"
                        )
                    ],
                    capturedHeadOID: nil,
                    capturedAt: now
                )
            },
            deferralReason: nil
        )
        await monitor.runPassForTesting()
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.count, 7)

        monitor.runDigestForTesting()
        await waitForDelivery(channel)

        let batch = try? XCTUnwrap(channel.deliveredBatches.first)
        XCTAssertEqual(batch?.entries.count, 5, "A digest shows at most five PRs")
        XCTAssertEqual(batch?.omittedEntryCount, 2)
        XCTAssertEqual(monitor.currentStateForTesting()?.events.count, 7, "Omitted entries stay in local history")
    }

    func testMutedPRIsCollectedButNotDelivered() async {
        let channel = deliveredChannel()
        let (monitor, fake) = makeMonitor(
            configuration: .default,
            channels: [channel],
            isMuted: { _ in true }
        )
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(channel.deliveredBatches.isEmpty, "A muted PR must not be delivered")
        XCTAssertEqual(monitor.currentStateForTesting()?.events.count, 1, "Muting must not stop collection")
    }

    func testDigestSkippedWhenNoChannelIsAvailable() async {
        let channel = FakeDigestChannel(isAvailable: false, binding: [:])
        let (monitor, fake) = makeMonitor(configuration: .default, channels: [channel])
        await seedActionableItem(monitor, fake)

        monitor.runDigestForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(channel.deliveredBatches.isEmpty)
        XCTAssertNil(monitor.currentStateForTesting()?.digest.lastAutoDigestAt, "An unavailable channel must not consume the window")
    }

    // MARK: - Store failure

    func testFailedDismissRetainsReminderAndPublishesErrorUntilRetryCommits() async throws {
        try await assertReminderWriteFailure(snooze: false)
    }

    func testFailedSnoozeRetainsReminderAndPublishesErrorUntilRetryCommits() async throws {
        try await assertReminderWriteFailure(snooze: true)
    }

    private func assertReminderWriteFailure(snooze: Bool) async throws {
        let channel = deliveredChannel()
        let store = PRActivityStore(directoryURL: directory)
        let (monitor, fake) = makeMonitor(store: store, channels: [channel])
        await seedActionableItem(monitor, fake)
        let before = try XCTUnwrap(monitor.snapshot.actionItems.first)
        XCTAssertEqual(before.state, .open)
        let savedDirectory = directory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.moveItem(at: savedDirectory, to: directory)
            }
        }
        try Data("blocked directory".utf8).write(to: directory)
        now = now.addingTimeInterval(10)
        let until = now.addingTimeInterval(3600)
        if snooze {
            monitor.snooze(itemIDs: [before.id], until: until)
        } else {
            monitor.markHandled(itemIDs: [before.id])
        }
        XCTAssertEqual(monitor.snapshot.actionItems.first, before)
        XCTAssertEqual(monitor.currentStateForTesting()?.actionItems.first, before)
        XCTAssertFalse(monitor.snapshot.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(channel.deliveredBatches.isEmpty)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: savedDirectory, to: directory)
        restored = true
        now = now.addingTimeInterval(10)
        if snooze {
            monitor.snooze(itemIDs: [before.id], until: until)
        } else {
            monitor.markHandled(itemIDs: [before.id])
        }
        let committed = try XCTUnwrap(monitor.snapshot.actionItems.first)
        XCTAssertEqual(committed.state, snooze ? .snoozed : .handled)
        XCTAssertEqual(committed.stateUpdatedAt, now)
        XCTAssertEqual(committed.snoozedUntil, snooze ? until : nil)
        XCTAssertEqual(committed.coveredEventIDs, before.eventIDs)
        XCTAssertEqual(Set(committed.coveredEventIDs).count, committed.coveredEventIDs.count)
        XCTAssertEqual(monitor.snapshot.actionItems.count, 1)
        XCTAssertNil(monitor.snapshot.errorMessage)
        let account = try XCTUnwrap(monitor.snapshot.account)
        XCTAssertEqual(try store.load(account: account)?.actionItems, [committed])
        XCTAssertTrue(channel.deliveredBatches.isEmpty)
    }

    func testFailedPersistDoesNotAdvanceCommittedObservation() async throws {
        let unwritableDirectory = URL(fileURLWithPath: "/dev/null/ghpr-activity")
        let brokenStore = PRActivityStore(directoryURL: unwritableDirectory)
        let (monitor, fake) = makeMonitor(store: brokenStore)
        discoveredPR(fake)
        setObservation(fake, [
            observation(source: .header, payload: header()),
            observation(source: .reviews, payload: MonitorSourcePayload(reviews: [review()])),
        ])

        await monitor.runPassForTesting()

        let state = monitor.currentStateForTesting()
        XCTAssertTrue(
            state?.events.isEmpty ?? false,
            "A failed write must not commit the pass's events into memory"
        )
        XCTAssertTrue(
            state?.monitoredPRs.first?.checkpoint(for: .reviews) == nil,
            "A failed write must not commit the pass's checkpoints either"
        )
        XCTAssertNotNil(monitor.snapshot.errorMessage, "The failure must be visible instead of silently swallowed")
    }

    func testCorruptHistoryStopsMonitoringWithAnError() async throws {
        let store = PRActivityStore(directoryURL: directory)
        let key = MonitorAccountKey(endpoint: "", viewerNodeID: viewer.nodeID, login: viewer.login)
        try Data("{ broken".utf8).write(to: store.fileURL(for: key))

        let (monitor, fake) = makeMonitor(store: store)
        discoveredPR(fake)
        setObservation(fake, [observation(source: .header, payload: header())])

        await monitor.runPassForTesting()

        XCTAssertNil(monitor.currentStateForTesting(), "A corrupt history must not be replaced by a fresh empty state")
        XCTAssertNotNil(monitor.snapshot.errorMessage)
    }

    // MARK: - Helpers

    private func check(
        id: String,
        headOID: String?,
        conclusion: String?,
        name: String = "build",
        runID: String = "run-1"
    ) -> MonitorCheckRun {
        MonitorCheckRun(
            id: id,
            origin: .actionsJob,
            name: name,
            workflowName: "CI",
            runID: runID,
            runAttempt: headOID == "sha2" ? 2 : 1,
            headOID: headOID,
            status: "COMPLETED",
            conclusion: conclusion,
            url: nil,
            startedAt: now,
            completedAt: now
        )
    }

    private func makeStoredEvent(id: String) -> PRActivityEvent {
        PRActivityEvent(
            id: id,
            identityKey: "review:R_1:CHANGES_REQUESTED",
            kind: .reviewSubmitted,
            prNodeID: "PR_42",
            reference: reference,
            actor: "alice",
            actorNodeID: "U_ALICE",
            isFromViewer: false,
            subjectIsViewer: false,
            isBotActor: false,
            containsDirectMention: false,
            occurredAt: now,
            url: nil,
            revision: PRActivityRevision(headOID: "sha1", reviewID: "R_1"),
            sourceChangeSequence: 1
        )
    }

    private func makeItem(
        id: String,
        reason: PRActionReason,
        action: PRActionKind,
        eventIDs: [String]
    ) -> PRActionItem {
        PRActionItem(
            id: id,
            prNodeID: "PR_42",
            reference: reference,
            reasons: [reason],
            actionKinds: [action],
            eventIDs: eventIDs,
            revision: .empty,
            state: .open,
            createdAt: now,
            stateUpdatedAt: now,
            snoozedUntil: nil,
            coveredEventIDs: [],
            evidenceURLs: []
        )
    }

    private func makeMonitoredPR() -> MonitoredPR {
        MonitoredPR(
            prNodeID: "PR_42",
            reference: reference,
            origins: [.authored],
            lifecycle: .open,
            title: "Add feature",
            discoveredAt: now,
            lastObservedAt: now
        )
    }

    private func waitForDelivery(_ channel: FakeDigestChannel, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while channel.attemptCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the monitor's receipt bookkeeping finish.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

// MARK: - Fakes

private final class FakeMonitorAcquisition: MonitorAcquisitionProviding {
    var rateLimitHeadroom: RateLimitInfo = RateLimitInfo(limit: 5000, remaining: 5000, resetDate: Date())
    var viewerIdentity: MonitorViewerIdentity?
    var discoveryOutcome = MonitorDiscoveryOutcome(
        discovered: [],
        coverage: MonitorDiscoveryCoverage(queries: [], attemptedAt: Date())
    )
    var observationOutcome: MonitorSnapshotOutcome = .empty
    var discoveryError: Error?

    init(viewer: MonitorViewerIdentity) {
        viewerIdentity = viewer
    }

    func fetchViewerIdentity() async throws -> MonitorViewerIdentity {
        guard let viewerIdentity else { throw MonitorTransportError.unauthorized }
        return viewerIdentity
    }

    func fetchMonitorDiscovery(scope: MonitorDiscoveryScope) async throws -> MonitorDiscoveryOutcome {
        if let discoveryError { throw discoveryError }
        return discoveryOutcome
    }

    func fetchMonitorObservations(
        for prs: [MonitoredPR],
        viewer: MonitorViewerIdentity,
        sources: Set<MonitorSourceKind>
    ) async -> MonitorSnapshotOutcome {
        observationOutcome
    }
}

@MainActor
private final class FakeDigestChannel: PRActivityDigestChannel {
    let channel: DigestChannel = .macOS
    var isAvailable: Bool
    var binding: [String: String]
    var failure: Error?
    private(set) var deliveredBatches: [DigestBatch] = []
    private(set) var attemptCount = 0

    init(isAvailable: Bool, binding: [String: String], failure: Error? = nil) {
        self.isAvailable = isAvailable
        self.binding = binding
        self.failure = failure
    }

    var targetBinding: [String: String] { binding }

    func deliver(_ batch: DigestBatch) async throws -> DigestReceipt {
        attemptCount += 1
        if let failure { throw failure }
        deliveredBatches.append(batch)
        return DigestReceipt(channelID: "C_TEST", workspace: "T_TEST", messageTimestamp: "1.0", recipientUserID: "U_TEST")
    }
}

@MainActor
private final class SuspendingDigestChannel: PRActivityDigestChannel {
    let channel: DigestChannel = .macOS
    var isAvailable = true
    var binding: [String: String] = [:]
    private(set) var attemptCount = 0
    private var continuation: CheckedContinuation<DigestReceipt, Never>?

    var targetBinding: [String: String] { binding }

    func deliver(_ batch: DigestBatch) async throws -> DigestReceipt {
        attemptCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with receipt: DigestReceipt) {
        continuation?.resume(returning: receipt)
        continuation = nil
    }
}
