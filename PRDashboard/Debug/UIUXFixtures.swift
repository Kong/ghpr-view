#if DEBUG
import Foundation

/// All fixture values are constructed in memory; this type never constructs services.
enum UIUXFixtures {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let supportedCounts = [0, 3, 20, 100]

    enum ParameterError: LocalizedError {
        case invalidCount(String)
        var errorDescription: String? {
            switch self {
            case .invalidCount(let value):
                return "Fixture parameter error: --uiux-count must be 0, 3, 20 or 100 (received \(value))."
            }
        }
    }

    static func count(arguments: [String]) throws -> Int {
        var supplied: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--uiux-count=") {
                supplied.append(String(argument.dropFirst("--uiux-count=".count)))
            } else if argument == "--uiux-count" {
                supplied.append(index + 1 < arguments.count ? arguments[index + 1] : "<missing>")
            }
        }
        guard supplied.count <= 1 else { throw ParameterError.invalidCount("multiple values") }
        guard let value = supplied.first else { return 20 }
        guard let count = Int(value), supportedCounts.contains(count) else {
            throw ParameterError.invalidCount(value)
        }
        return count
    }

    static var configuration: Configuration {
        var value = Configuration.default
        value.showMyReviewStatus = true
        value.minimumApprovalsForReadyToMerge = 2
        value.notificationsEnabled = false
        value.monitorEnabled = false
        value.automaticallyCheckForUpdates = false
        value.jiraServerURL = "https://example.atlassian.net"
        return value
    }

    static func prList(count: Int, reordered: Bool = false, changedFacts: Bool = false) -> PRList {
        let prs = (0..<count).map { pullRequest(index: $0, reordered: reordered, changedFacts: changedFacts) }
        return PRList(
            lastUpdated: now,
            pullRequests: prs.filter { $0.state == .open && ($0.category == .authored || $0.category == .reviewRequest) },
            mentionedPullRequests: prs.filter { $0.category == .mentioned } + (count >= 20 ? Array(prs.prefix(1)) : []),
            directMentionPullRequests: prs.filter { $0.category == .directMention },
            mergedPullRequests: prs.filter { $0.state == .merged },
            isLoading: false, error: nil
        )
    }

    private static func pullRequest(index: Int, reordered: Bool, changedFacts: Bool) -> PullRequest {
        let number = 1001 + index
        let role = index % 5
        let status: CIStatus? = changedFacts ? .failure : [.success, .failure, .pending, .expected, .unknown, nil][index % 6]
        let reviews: [ReviewState?] = [nil, .changesRequested, .changesRequested, .approved]
        let reviewIndex = (index / 5) % reviews.count
        let repo = index % 3 == 0 ? "project" : "a-very-long-repository-name-for-native-panel-layout"
        let stamp = now.addingTimeInterval(-Double(reordered ? 100 - index : index + 1) * 120)
        let threads = (0..<(index % 3)).map { offset in
            ReviewThread(
                id: "fixture-thread-\(number)-\(offset)", isResolved: index % 5 == 4,
                isOutdated: false, path: "Sources/示例.swift", line: 42,
                comments: [ReviewComment(id: "fixture-comment-\(number)-\(offset)", author: "octocat",
                                         body: "Please check this boundary. 请确认边界条件。", createdAt: now.addingTimeInterval(-900))],
                isRead: offset == 1
            )
        }
        return PullRequest(
            id: number, graphqlNodeId: "fixture-node-\(number)", number: number,
            title: changedFacts
                ? "Updated same-ID fixture facts: a longer title changes wrapping while the original interaction target remains protected — 中文更新"
                : index % 2 == 0
                    ? "Preserve the selected pull request while background updates reorder a very long list"
                    : "修复输入法组合期间的列表更新 — Keep 中文 and English titles readable",
            author: index % 2 == 0 ? "octocat" : "example-contributor",
            authorAvatarURL: index % 3 == 0 ? nil : URL(string: "https://avatars.example.invalid/fixture-\(index)"),
            repositoryOwner: "example", repositoryName: repo,
            url: URL(string: "https://github.com/example/\(repo)/pull/\(number)\(changedFacts ? "?fixture=updated" : "")")!,
            state: role == 4 ? .merged : .open, isDraft: index % 7 == 0,
            createdAt: now.addingTimeInterval(-172800), updatedAt: stamp,
            mergedAt: role == 4 ? stamp : nil, body: "Fixture description for DEMO-42. 固定示例。",
            conversationComments: [], lastCommitAt: index % 4 == 0 ? nil : stamp,
            headCommitOid: changedFacts ? "fixture-updated-\(number)" : reordered ? "fixture-reordered-\(number)" : "fixture-head-\(number)",
            baseRefName: "main", headRefName: "fixture/\(number)", baseNeedsUpdate: index % 4 == 0,
            approvalAuthors: ["octocat", "example-reviewer"], changesRequestedAuthors: index % 4 == 1 ? ["octocat"] : [],
            reviewThreads: threads,
            category: role == 0 || role == 4 ? .authored : role == 1 ? .reviewRequest : role == 2 ? .mentioned : .directMention,
            hasBaseConflicts: index % 7 == 2, ciStatus: status,
            checkSuccessCount: status == .success ? 4 : 2,
            checkFailureCount: status == .failure ? 1 : 0,
            checkPendingCount: status == .pending ? 2 : 0,
            githubCIState: status?.rawValue,
            myLastReviewState: role == 1 ? reviews[reviewIndex] : nil,
            myLastReviewAt: now.addingTimeInterval(reviewIndex == 1 ? -30 : -86400),
            reviewRequestedAt: nil, myThreadsAllResolved: reviewIndex == 2,
            approvalCount: index % 4, changesRequestedCount: index % 4 == 1 ? 1 : 0,
            ciExtendedInfo: CIExtendedInfo(isRunning: status == .pending, workflows: [
                CIWorkflowInfo(name: "Build and test / macOS", isWorkflow: true,
                               successCount: 2, failureCount: status == .failure ? 1 : 0,
                               pendingCount: status == .pending ? 2 : 0)
            ]),
            jiraTicket: index % 2 == 0 ? "DEMO-42" : nil,
            jiraTitle: "Deterministic panel fixture / 界面验证", jiraLabels: ["uiux", "示例"],
            jiraStatusName: "In Progress", jiraStatusCategoryKey: "indeterminate",
            jiraUpdatedAt: now, jiraMetadataFetchedAt: now,
            isOpenInCmux: index % 3 == 0, mentionCount: role == 3 ? 2 : index % 4 == 0 ? 1 : 0,
            githubLabels: [GitHubLabel(name: "uiux", color: "0969da"), GitHubLabel(name: "需要审阅", color: "8250df")],
            githubMilestone: GitHubMilestone(title: "Native panel"), jiraProjectKey: "DEMO"
        )
    }

    static func extensionState(for pr: PullRequest) -> PRRowExtensionState {
        let page = GitHubPageContext.pullRequest(repository: pr.repoFullName, number: pr.number)
        let skill = SkillDefinition(id: "fixture-ci-analysis", version: "1", displayName: "Analyze fixture CI",
                                    summary: "Records an intent; no agent is launched.", targets: [.pullRequestRevision],
                                    agents: [.codex], defaultAgent: .codex, isBuiltIn: false,
                                    hasBrowserCompanion: false, isRunnable: true)
        let run = SkillRun(id: "fixture-run-\(pr.id)", skillID: skill.id, agent: .codex,
                           page: page, requestedByClientID: nil, createdAt: now,
                           startedAt: now, completedAt: nil, status: .running,
                           progressMessage: "Fixture run state", progressCurrent: 1, progressTotal: 3,
                           result: nil, error: nil, retryOfRunID: nil)
        let analysis = CIAnalysis(id: "fixture-analysis-\(pr.id)", pageKey: page.key,
                                  repository: pr.repoFullName, prNumber: pr.number, jobName: "Build and test / macOS",
                                  verdict: .needsInvestigation, confidence: .medium, confidenceScore: 0.7,
                                  summary: "Fixture analysis: inspect the failing boundary test.", historyMatches: [],
                                  historyChecked: 3, relatednessScore: nil, relatednessSummary: nil,
                                  reproduction: "Fixture only", failureSignature: "fixture-boundary",
                                  changedFiles: ["Sources/示例.swift"], suggestedAction: "Review diagnostics",
                                  agent: .codex, strictContext: true, durationSeconds: 3, createdAt: now)
        return PRRowExtensionState(runnableSkills: [skill], extensionRun: pr.id % 3 == 0 ? run : nil,
                                   extensionAnalysis: pr.ciStatus == .failure ? analysis : nil,
                                   extensionTags: pr.ciStatus == .failure ? [.needsInvestigation] : [])
    }

    static var activitySnapshot: PRActivitySnapshot {
        var snapshot = PRActivitySnapshot.idle
        snapshot.isRunning = true
        snapshot.isEstablishingBaseline = false
        snapshot.lastPassAt = now
        let states: [PRActionState] = [.open, .handled, .snoozed, .recovered, .superseded]
        for (index, state) in states.enumerated() {
            let reference = PullRequestReference(owner: "example", repo: "project", number: 101 + index)
            let node = "fixture-pr-\(index)"
            let eventID = "fixture-event-\(index)"
            let url = URL(string: "https://github.com/example/project/pull/\(reference.number)")!
            snapshot.monitoredPRs.append(MonitoredPR(prNodeID: node, reference: reference,
                origins: [.authored], title: "Fixture \(state.rawValue) reminder · 中英混排 review context",
                url: url, discoveredAt: now.addingTimeInterval(-7200), lastObservedAt: now))
            snapshot.events.append(PRActivityEvent(id: eventID, identityKey: eventID,
                kind: .reviewSubmitted, prNodeID: node, reference: reference, actor: "octocat",
                actorNodeID: nil, isFromViewer: false, subjectIsViewer: true, isBotActor: false,
                containsDirectMention: false, occurredAt: now.addingTimeInterval(-600 - Double(index * 60)),
                url: url, revision: .empty, sourceChangeSequence: 1))
            snapshot.actionItems.append(PRActionItem(id: "fixture-item-\(index)", prNodeID: node,
                reference: reference, reasons: [.authoredPRReviewFeedback], actionKinds: [.reviewFeedback],
                eventIDs: [eventID], revision: .empty, state: state, createdAt: now.addingTimeInterval(-3600),
                stateUpdatedAt: now, snoozedUntil: state == .snoozed ? now.addingTimeInterval(86400) : nil,
                coveredEventIDs: state == .open ? [] : [eventID], evidenceURLs: [url]))
        }
        let entries = snapshot.actionItems.map { item in
            DigestEntry(prNodeID: item.prNodeID, reference: item.reference,
                title: snapshot.pr(item.prNodeID)?.title ?? "", reasons: item.reasons,
                actionKinds: item.actionKinds, changeKinds: [.reviewSubmitted], eventCount: 1,
                actionItemIDs: [item.id], evidenceURLs: item.evidenceURLs)
        }
        snapshot.batches = (0..<7).map { index in
            DigestBatch(id: "fixture-digest-\(index)", createdAt: now.addingTimeInterval(-Double(index * 1800)),
                entries: entries, coveredEventIDs: snapshot.events.map(\.id),
                coveredActionItemIDs: snapshot.actionItems.map(\.id), omittedEntryCount: index == 6 ? 2 : 0,
                deliveries: [DigestDelivery(channel: .macOS, status: .delivered,
                    attemptedAt: now, completedAt: now, receipt: nil, failureMessage: nil,
                    targetWorkspace: nil, targetUserID: nil)])
        }
        snapshot.lastDigestAt = now
        return snapshot
    }
}
#endif
