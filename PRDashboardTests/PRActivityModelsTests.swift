import XCTest
@testable import PRDashboard

/// Storage, configuration and comment-template boundaries.
final class PRActivityModelsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-activity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> PRActivityStore {
        PRActivityStore(fileManager: .default, directoryURL: directory)
    }

    private func account(nodeID: String = "MDQ6VXNlcjE=", login: String = "octocat", endpoint: String = "") -> MonitorAccountKey {
        MonitorAccountKey(endpoint: endpoint, viewerNodeID: nodeID, login: login)
    }

    // MARK: - Configuration back-compatibility

    func testConfigurationDecodesWithoutActivityKeys() throws {
        let json = """
        {
          "refreshInterval": 300,
          "repositories": ["owner/repo"],
          "showDrafts": true,
          "notificationsEnabled": true,
          "refreshOnOpen": false,
          "ciStatusExcludeFilter": "review",
          "pausePollingInLowPowerMode": true,
          "pausePollingOnExpensiveNetwork": true,
          "showMyReviewStatus": false
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertTrue(configuration.monitorEnabled, "Monitoring must default to enabled for existing installs")
        XCTAssertEqual(configuration.digestChannels, [.macOS], "Existing installs must keep delivering to macOS only")
        XCTAssertTrue(configuration.notificationEventKindFilter.isEmpty, "An empty filter means the built-in defaults")
        XCTAssertFalse(configuration.isSlackDeliveryConfigured, "Slack must stay unconfigured until a DM binding is verified")
        XCTAssertTrue(configuration.commentShortcuts.isEmpty, "Comment shortcuts must default to empty")
        XCTAssertFalse(
            configuration.isRepositoryNotified("someone/else"),
            "Activity follows the PR list repository filter when the digest filter is empty"
        )
        XCTAssertTrue(
            configuration.isRepositoryNotified("owner/repo"),
            "An empty digest filter follows the PR list filter"
        )
    }

    func testConfigurationRoundTripsActivityPreferences() throws {
        var configuration = Configuration.default
        configuration.monitorEnabled = false
        configuration.notificationTargets = [DigestChannel.slack.rawValue, DigestChannel.macOS.rawValue]
        configuration.notificationEventKinds = [PRActivityEventKind.ciCheckFailed.rawValue]
        configuration.notificationRepositories = ["owner/repo"]
        configuration.slackEnabled = true
        configuration.slackWorkspaceID = "T123"
        configuration.slackWorkspaceName = "Example"
        configuration.slackUserID = "U123"
        configuration.slackDMChannelID = "D123"
        configuration.commentShortcuts = [
            CommentShortcut(displayName: "Ask for tests", template: "Please add tests for {{pr_url}}")
        ]

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)

        XCTAssertEqual(decoded, configuration)
        XCTAssertTrue(decoded.isSlackDeliveryConfigured)
        XCTAssertTrue(decoded.isRepositoryNotified("OWNER/REPO"), "Repository matching must be case-insensitive")
        XCTAssertFalse(decoded.isRepositoryNotified("other/repo"))
    }

    // MARK: - Store

    func testStoreRoundTripsAccountState() throws {
        let store = makeStore()
        let key = account()
        var state = PRActivityAccountState(account: key, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        state.monitoredPRs = [
            MonitoredPR(
                prNodeID: "PR_1",
                reference: PullRequestReference(owner: "owner", repo: "repo", number: 7),
                origins: [.authored],
                isExplicitlyTracked: true,
                discoveredAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastObservedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]
        state.hasEstablishedBaseline = true

        try store.persist(state)
        let loaded = try XCTUnwrap(try store.load(account: key))

        XCTAssertEqual(loaded.account, key)
        XCTAssertEqual(loaded.monitoredPRs.count, 1)
        XCTAssertEqual(loaded.monitoredPRs[0].prNodeID, "PR_1")
        XCTAssertTrue(loaded.monitoredPRs[0].isExplicitlyTracked)
        XCTAssertTrue(loaded.hasEstablishedBaseline)
    }

    func testStoreKeepsAccountHistoriesSeparate() throws {
        let store = makeStore()
        let first = account(nodeID: "MDQ6VXNlcjE=", login: "alice")
        let second = account(nodeID: "MDQ6VXNlcjI=", login: "bob")

        var firstState = PRActivityAccountState(account: first, updatedAt: Date())
        firstState.events = [makeEvent(prNodeID: "PR_1", id: "event-1")]
        try store.persist(firstState)

        XCTAssertNil(try store.load(account: second), "A different account must not see the first account's history")
        XCTAssertEqual(try store.load(account: first)?.events.count, 1)
        XCTAssertEqual(store.storedAccountSlugs().count, 1)
    }

    func testStoreRejectsCorruptFileAndLeavesItInPlace() throws {
        let store = makeStore()
        let key = account()
        let url = store.fileURL(for: key)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try store.load(account: key)) { error in
            guard case PRActivityStoreError.corruptFile = error else {
                return XCTFail("Expected a corruptFile error, got \(error)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "A corrupt history file must be preserved so the user can recover it"
        )
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "The file must not be rewritten or reset")
    }

    func testStoreWriteFailureLeavesPreviousFileIntact() throws {
        let store = makeStore()
        let key = account()
        var state = PRActivityAccountState(account: key, updatedAt: Date())
        try store.persist(state)
        let before = try Data(contentsOf: store.fileURL(for: key))

        // A directory where the file should be makes the atomic write fail.
        try FileManager.default.removeItem(at: store.fileURL(for: key))
        try FileManager.default.createDirectory(at: store.fileURL(for: key), withIntermediateDirectories: true)

        state.updatedAt = Date().addingTimeInterval(60)
        XCTAssertThrowsError(try store.persist(state)) { error in
            guard case PRActivityStoreError.writeFailed = error else {
                return XCTFail("Expected a writeFailed error, got \(error)")
            }
        }
        XCTAssertNotEqual(try? Data(contentsOf: store.fileURL(for: key)), before)
        XCTAssertNil(try? store.load(account: key)?.updatedAt, "A failed write must not become readable state")
    }

    // MARK: - Comment shortcuts

    func testCommentShortcutRendersSupportedVariables() throws {
        let shortcut = CommentShortcut(displayName: "Ask", template: "{{repository}}#{{pr_number}} @ {{head_sha}}\n{{diff_url}}")
        let values = CommentShortcutValues(
            context: .pullRequest,
            repository: "owner/repo",
            prNumber: 12,
            prURL: URL(string: "https://github.com/owner/repo/pull/12"),
            headSHA: "abc123",
            commentURL: nil,
            commentBody: nil
        )

        XCTAssertEqual(
            try shortcut.render(with: values),
            "owner/repo#12 @ abc123\nhttps://github.com/owner/repo/pull/12/files"
        )
    }

    func testCommentShortcutRejectsUnknownVariable() {
        let shortcut = CommentShortcut(displayName: "Bad", template: "{{ticket}} please")

        XCTAssertEqual(
            CommentShortcutTemplate.validate(template: shortcut.template),
            .unknownVariable("ticket")
        )
    }

    func testCommentShortcutRejectsCommentVariablesOutsideAComment() {
        let shortcut = CommentShortcut(displayName: "Reply", template: "about {{comment_body}}")
        let values = CommentShortcutValues(
            context: .pullRequest,
            repository: "owner/repo",
            prNumber: 12,
            prURL: URL(string: "https://github.com/owner/repo/pull/12"),
            headSHA: nil,
            commentURL: nil,
            commentBody: "text"
        )

        XCTAssertThrowsError(try shortcut.render(with: values)) { error in
            XCTAssertEqual(
                error as? CommentShortcutError,
                .variableNotAvailableInContext(variable: "comment_body", context: .pullRequest)
            )
        }
    }

    func testCommentShortcutReportsMissingContextInsteadOfBorrowingAnotherPR() {
        let shortcut = CommentShortcut(displayName: "SHA", template: "{{head_sha}}")
        let values = CommentShortcutValues(
            context: .reviewComment,
            repository: "owner/repo",
            prNumber: 12,
            prURL: URL(string: "https://github.com/owner/repo/pull/12"),
            headSHA: nil,
            commentURL: nil,
            commentBody: nil
        )

        XCTAssertThrowsError(try shortcut.render(with: values)) { error in
            XCTAssertEqual(
                error as? CommentShortcutError,
                .missingContext(variable: "head_sha", context: .reviewComment)
            )
        }
    }

    func testCommentShortcutApplicabilityHonoursContextsAndRepositories() {
        let shortcut = CommentShortcut(
            displayName: "Ask",
            template: "hi",
            contexts: [.reviewComment],
            repositoryScopes: ["owner/repo"]
        )

        XCTAssertTrue(shortcut.applies(to: .reviewComment, repository: "owner/repo"))
        XCTAssertFalse(shortcut.applies(to: .pullRequest, repository: "owner/repo"))
        XCTAssertFalse(shortcut.applies(to: .reviewComment, repository: "other/repo"))

        var disabled = shortcut
        disabled.isEnabled = false
        XCTAssertFalse(disabled.applies(to: .reviewComment, repository: "owner/repo"))
    }

    func testMonitoredPRCheckpointsRoundTrip() throws {
        var pr = MonitoredPR(
            prNodeID: "PR_9",
            reference: PullRequestReference(owner: "owner", repo: "repo", number: 9),
            origins: [.reviewed],
            discoveredAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        pr.setCheckpoint(
            MonitorSourceCheckpoint(
                header: MonitorHeaderSnapshot(
                    state: .open,
                    isDraft: false,
                    title: "Title",
                    url: nil,
                    headOID: "sha1",
                    baseRefName: "main",
                    headRefName: "feature",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isArchived: false
                ),
                reviews: [CheckpointReview(id: "R_1", author: "alice", authorNodeID: "U_1", state: "APPROVED", submittedAt: nil, commitOID: "sha1")],
                threads: [CheckpointThread(id: "T_1", isResolved: false, isOutdated: false, path: "a.swift", line: 3, commentIDs: ["C_1"], rootAuthorNodeID: "U_1", participantNodeIDs: ["U_1"])]
            ),
            for: .reviewThreads
        )
        pr.setSequence(2, for: .reviewThreads)

        let data = try JSONEncoder().encode(pr)
        let decoded = try JSONDecoder().decode(MonitoredPR.self, from: data)

        XCTAssertEqual(decoded.sequence(for: .reviewThreads), 2)
        XCTAssertEqual(decoded.checkpoint(for: .reviewThreads)?.threads?.first?.commentIDs, ["C_1"])
    }

    func testScopeDenialWarningNamesTheMissingPermission() {
        let detail = "Your token has not been granted the required scopes to execute this query. The 'id' field requires one of the following scopes: ['read:org', 'read:discussion'], but your token has only been granted the: ['read:user', 'repo', 'workflow'] scopes."
        let reason = MonitorIncompleteReason(kind: .graphQLErrors, statusCode: nil, detail: detail)

        XCTAssertEqual(
            reason.warningQualifier,
            "missing scope: read:org or read:discussion",
            "a permission failure must name the missing scope in the collapsed warning"
        )
        XCTAssertEqual(
            reason.warningDetail,
            "Missing permission: one of read:org, read:discussion. Current token: read:user, repo, workflow.",
            "the expanded warning must state which permission is missing and what the token has"
        )

        let other = MonitorIncompleteReason(kind: .graphQLErrors, statusCode: nil, detail: "alias pr_0 could not be decoded")
        XCTAssertEqual(other.warningQualifier, "graphQLErrors", "a non-scope GraphQL error must keep its kind")
        XCTAssertEqual(other.warningDetail, "alias pr_0 could not be decoded")
    }


    // MARK: - Helpers

    private func makeEvent(prNodeID: String, id: String) -> PRActivityEvent {
        PRActivityEvent(
            id: id,
            identityKey: "review:R_1:APPROVED",
            kind: .reviewSubmitted,
            prNodeID: prNodeID,
            reference: PullRequestReference(owner: "owner", repo: "repo", number: 1),
            actor: "alice",
            actorNodeID: "U_1",
            isFromViewer: false,
            subjectIsViewer: false,
            isBotActor: false,
            containsDirectMention: false,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: nil,
            revision: PRActivityRevision(headOID: "sha1", reviewID: "R_1"),
            sourceChangeSequence: 1
        )
    }
}
