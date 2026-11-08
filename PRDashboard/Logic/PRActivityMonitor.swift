import Foundation
import os

// MARK: - UI-facing snapshot

/// Aggregated monitor state exposed to the UI. Derived from the persisted account
/// state on every change so the view never reads partially applied data.
struct PRActivitySnapshot: Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var account: MonitorAccountKey?
    var lastPassAt: Date?
    var lastDigestAt: Date?
    var coverage: MonitorDiscoveryCoverage?
    var monitoredPRs: [MonitoredPR] = []
    var actionItems: [PRActionItem] = []
    var events: [PRActivityEvent] = []
    var batches: [DigestBatch] = []
    var isEstablishingBaseline: Bool = true
    var errorMessage: String?

    static let idle = PRActivitySnapshot(isRunning: false, isPaused: false, account: nil, lastPassAt: nil, lastDigestAt: nil, coverage: nil)

    func pr(_ prNodeID: String) -> MonitoredPR? {
        monitoredPRs.first { $0.prNodeID == prNodeID }
    }
}

// MARK: - Digest delivery channels

/// One delivery destination for a digest batch. Implementations perform the actual
/// send; the monitor owns batch bookkeeping, receipts and retry eligibility.
@MainActor
protocol PRActivityDigestChannel: AnyObject {
    var channel: DigestChannel { get }
    /// Usable right now (token verified, DM resolved, notifications authorized).
    var isAvailable: Bool { get }
    /// Target binding persisted with the batch so a configuration or account switch can
    /// never deliver an old in-flight batch to a new target.
    var targetBinding: [String: String] { get }
    func deliver(_ batch: DigestBatch) async throws -> DigestReceipt
    /// Removes an already-shown notification when every event in that digest no longer applies.
    func withdrawDeliveredDigest(id: String)
}

extension PRActivityDigestChannel {
    func withdrawDeliveredDigest(id: String) {}
}

/// One activity reminder. Items that cite the same event collapse into one of these
/// so the list and the badge do not repeat it.
struct ActivityReminder: Identifiable, Equatable {
    var id: String
    var itemIDs: [String]
    var reasons: [PRActionReason]
    var actionKinds: [PRActionKind]
    var eventIDs: [String]
    var evidenceURLs: [URL]
    var state: PRActionState
    var stateUpdatedAt: Date
}

// MARK: - Pure engine

/// Event derivation, relevance and action-item bookkeeping. Pure functions only: the
/// monitor owns persistence and scheduling, which keeps every rule unit-testable
/// without network access.
enum PRActivityEngine {
    struct SourceDerivation {
        var events: [PRActivityEvent]
        var checkpoint: MonitorSourceCheckpoint
    }

    // MARK: Bot detection

    static func isBotLogin(_ login: String?) -> Bool {
        guard let login else { return false }
        let lowered = login.lowercased()
        return lowered.hasSuffix("[bot]") || lowered.hasSuffix("-bot") || lowered.hasSuffix("_bot")
    }

    // MARK: Event derivation

    /// Derives events for one complete source observation.
    ///
    /// Returns nil when this source has no committed checkpoint yet: the first complete
    /// observation silently establishes a baseline instead of replaying history.
    static func derive(
        observation: MonitorSourceObservation,
        pr: MonitoredPR,
        viewer: MonitorViewerIdentity,
        now: Date
    ) -> SourceDerivation? {
        guard observation.isComplete, let payload = observation.payload else { return nil }
        let previous = pr.checkpoint(for: observation.source)
        let sequence = pr.sequence(for: observation.source) + 1
        // `pr` must already carry this pass's committed head (the monitor applies the
        // header source before the revision-bound sources) so events are attributed to
        // the revision they were observed on.
        let context = DerivationContext(
            pr: pr,
            viewer: viewer,
            sequence: sequence,
            now: now,
            headOID: pr.headOID
        )

        var checkpoint = MonitorSourceCheckpoint()
        var events: [PRActivityEvent] = []

        switch observation.source {
        case .header:
            guard let header = payload.header else { return nil }
            checkpoint.header = header
            if let previousHeader = previous?.header {
                events = headerEvents(previous: previousHeader, fresh: header, context: context)
            }
        case .reviews:
            guard let reviews = payload.reviews else { return nil }
            let committed = (reviews.filter { $0.state != ReviewState.pending.rawValue })
            checkpoint.reviews = committed.map {
                CheckpointReview(
                    id: $0.id,
                    author: $0.author,
                    authorNodeID: $0.authorNodeID,
                    state: $0.state,
                    submittedAt: $0.submittedAt,
                    commitOID: $0.commitOID
                )
            }
            if let previousReviews = previous?.reviews {
                events = reviewEvents(previous: previousReviews, fresh: committed, context: context)
            }
        case .conversationComments:
            guard let comments = payload.conversationComments else { return nil }
            checkpoint.conversationComments = comments.map { comment in
                CheckpointComment(
                    id: comment.id,
                    author: comment.author,
                    authorNodeID: comment.authorNodeID,
                    isBot: isBotLogin(comment.author),
                    createdAt: comment.createdAt,
                    lastEditedAt: comment.lastEditedAt,
                    mentionsViewer: mentionsViewer(comment.body, viewer: viewer)
                )
            }
            if let previousComments = previous?.conversationComments {
                events = conversationCommentEvents(
                    previous: previousComments,
                    fresh: comments,
                    viewer: viewer,
                    context: context
                )
            }
        case .reviewThreads:
            guard let threads = payload.reviewThreads else { return nil }
            checkpoint.threads = threads.map { thread in
                CheckpointThread(
                    id: thread.id,
                    isResolved: thread.isResolved,
                    isOutdated: thread.isOutdated,
                    path: thread.path,
                    line: thread.line,
                    commentIDs: thread.comments.map(\.id),
                    rootAuthorNodeID: thread.comments.first?.authorNodeID,
                    participantNodeIDs: Array(Set(thread.comments.compactMap(\.authorNodeID)))
                )
            }
            if let previousThreads = previous?.threads {
                events = threadEvents(previous: previousThreads, fresh: threads, viewer: viewer, context: context)
            }
        case .reviewRequests:
            guard let requests = payload.reviewRequests else { return nil }
            checkpoint.reviewRequests = CheckpointReviewRequests(
                requestIDs: requests.requests.map(\.id),
                eventIDs: requests.events.map(\.id)
            )
            if let previousRequests = previous?.reviewRequests {
                // A re-request is only trusted when GitHub reports a new
                // ReviewRequestedEvent ID; a list diff alone is never enough.
                let known = Set(previousRequests.eventIDs)
                events = requests.events
                    .filter { !known.contains($0.id) && $0.isViewer }
                    .map { event in
                        makeEvent(
                            kind: .reviewRequested,
                            identityKey: "reviewRequest:\(event.id)",
                            context: context,
                            actor: nil,
                            actorNodeID: nil,
                            subjectIsViewer: true,
                            containsDirectMention: false,
                            occurredAt: event.createdAt,
                            url: context.pr.url,
                            revision: PRActivityRevision(headOID: context.headOID)
                        )
                    }
            }
        case .ci:
            guard let ci = payload.ci else { return nil }
            checkpoint.ci = CheckpointCI(
                headOID: ci.headOID,
                checks: ci.checks.map {
                    CheckpointCheck(
                        id: $0.id,
                        origin: $0.origin,
                        name: $0.name,
                        runID: $0.runID,
                        runAttempt: $0.runAttempt,
                        headOID: $0.headOID,
                        status: $0.status,
                        conclusion: $0.conclusion,
                        url: $0.url
                    )
                }
            )
            if let previousCI = previous?.ci {
                events = ciEvents(previous: previousCI, fresh: ci, context: context)
            }
        }

        return SourceDerivation(events: events, checkpoint: checkpoint)
    }

    private struct DerivationContext {
        var pr: MonitoredPR
        var viewer: MonitorViewerIdentity
        var sequence: Int
        var now: Date
        var headOID: String?
    }

    private static func makeEvent(
        kind: PRActivityEventKind,
        identityKey: String,
        context: DerivationContext,
        actor: String?,
        actorNodeID: String?,
        subjectIsViewer: Bool,
        containsDirectMention: Bool,
        occurredAt: Date,
        url: URL?,
        revision: PRActivityRevision
    ) -> PRActivityEvent {
        let isFromViewer = actorNodeID != nil && actorNodeID == context.viewer.nodeID
        return PRActivityEvent(
            id: PRActivityEvent.identity(prNodeID: context.pr.prNodeID, identityKey: identityKey, sequence: context.sequence),
            identityKey: identityKey,
            kind: kind,
            prNodeID: context.pr.prNodeID,
            reference: context.pr.reference,
            actor: actor,
            actorNodeID: actorNodeID,
            isFromViewer: isFromViewer,
            subjectIsViewer: subjectIsViewer,
            isBotActor: isBotLogin(actor),
            containsDirectMention: containsDirectMention,
            occurredAt: occurredAt,
            url: url,
            revision: revision,
            sourceChangeSequence: context.sequence
        )
    }

    private static func headerEvents(
        previous: MonitorHeaderSnapshot,
        fresh: MonitorHeaderSnapshot,
        context: DerivationContext
    ) -> [PRActivityEvent] {
        var events: [PRActivityEvent] = []
        if let newHead = fresh.headOID, previous.headOID != newHead {
            events.append(makeEvent(
                kind: .pushedNewCommit,
                identityKey: "header:head:\(newHead)",
                context: context,
                actor: nil,
                actorNodeID: nil,
                subjectIsViewer: false,
                containsDirectMention: false,
                occurredAt: fresh.updatedAt,
                url: context.pr.url,
                revision: PRActivityRevision(headOID: newHead)
            ))
        }
        if previous.state != fresh.state {
            let kind: PRActivityEventKind?
            switch fresh.state {
            case .merged: kind = .prMerged
            case .closed: kind = .prClosed
            case .open: kind = .prReopened
            }
            if let kind {
                events.append(makeEvent(
                    kind: kind,
                    identityKey: "header:state:\(fresh.state.rawValue)",
                    context: context,
                    actor: nil,
                    actorNodeID: nil,
                    subjectIsViewer: false,
                    containsDirectMention: false,
                    occurredAt: fresh.updatedAt,
                    url: context.pr.url,
                    revision: PRActivityRevision(headOID: fresh.headOID)
                ))
            }
        }
        return events
    }

    private static func reviewEvents(
        previous: [CheckpointReview],
        fresh: [MonitorReview],
        context: DerivationContext
    ) -> [PRActivityEvent] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [PRActivityEvent] = []
        for review in fresh {
            let revision = PRActivityRevision(
                headOID: review.commitOID ?? context.headOID,
                reviewID: review.id
            )
            if let committed = previousByID[review.id] {
                if committed.state != review.state, review.state == ReviewState.dismissed.rawValue {
                    events.append(makeEvent(
                        kind: .reviewDismissed,
                        identityKey: "review:\(review.id):DISMISSED",
                        context: context,
                        actor: nil,
                        actorNodeID: nil,
                        subjectIsViewer: review.authorNodeID == context.viewer.nodeID,
                        containsDirectMention: false,
                        occurredAt: review.submittedAt ?? context.now,
                        url: review.url,
                        revision: revision
                    ))
                }
            } else {
                events.append(makeEvent(
                    kind: .reviewSubmitted,
                    identityKey: "review:\(review.id):\(review.state)",
                    context: context,
                    actor: review.author,
                    actorNodeID: review.authorNodeID,
                    subjectIsViewer: review.authorNodeID == context.viewer.nodeID,
                    containsDirectMention: false,
                    occurredAt: review.submittedAt ?? context.now,
                    url: review.url,
                    revision: revision
                ))
            }
        }
        return events
    }

    private static func conversationCommentEvents(
        previous: [CheckpointComment],
        fresh: [MonitorConversationComment],
        viewer: MonitorViewerIdentity,
        context: DerivationContext
    ) -> [PRActivityEvent] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [PRActivityEvent] = []
        for comment in fresh {
            let mentions = mentionsViewer(comment.body, viewer: viewer)
            if let committed = previousByID[comment.id] {
                guard let editedAt = comment.lastEditedAt, editedAt != committed.lastEditedAt else { continue }
                events.append(makeEvent(
                    kind: .conversationCommentEdited,
                    identityKey: "comment:\(comment.id):edited:\(Int(editedAt.timeIntervalSince1970))",
                    context: context,
                    actor: comment.author,
                    actorNodeID: comment.authorNodeID,
                    subjectIsViewer: comment.authorNodeID == viewer.nodeID,
                    containsDirectMention: mentions,
                    occurredAt: editedAt,
                    url: comment.url,
                    revision: PRActivityRevision(headOID: context.headOID, commentID: comment.id)
                ))
            } else {
                events.append(makeEvent(
                    kind: .conversationCommentAdded,
                    identityKey: "comment:\(comment.id)",
                    context: context,
                    actor: comment.author,
                    actorNodeID: comment.authorNodeID,
                    subjectIsViewer: comment.authorNodeID == viewer.nodeID,
                    containsDirectMention: mentions,
                    occurredAt: comment.createdAt,
                    url: comment.url,
                    revision: PRActivityRevision(headOID: context.headOID, commentID: comment.id)
                ))
            }
        }
        return events
    }

    private static func threadEvents(
        previous: [CheckpointThread],
        fresh: [MonitorReviewThread],
        viewer: MonitorViewerIdentity,
        context: DerivationContext
    ) -> [PRActivityEvent] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [PRActivityEvent] = []
        for thread in fresh {
            let committed = previousByID[thread.id]
            let knownCommentIDs = Set(committed?.commentIDs ?? [])
            let participants = Set(committed?.participantNodeIDs ?? [])
            for comment in thread.comments where !knownCommentIDs.contains(comment.id) {
                let isReply = comment.replyToID != nil
                let subjectIsViewer = participants.contains(viewer.nodeID)
                    || comment.authorNodeID == viewer.nodeID
                    || commentedByViewerBefore(thread: thread, comment: comment, viewer: viewer)
                events.append(makeEvent(
                    kind: isReply ? .threadReplyAdded : .reviewCommentAdded,
                    identityKey: "thread:\(thread.id):comment:\(comment.id)",
                    context: context,
                    actor: comment.author,
                    actorNodeID: comment.authorNodeID,
                    subjectIsViewer: subjectIsViewer,
                    containsDirectMention: mentionsViewer(comment.body, viewer: viewer),
                    occurredAt: comment.createdAt,
                    url: comment.url,
                    revision: PRActivityRevision(
                        headOID: context.headOID,
                        reviewID: comment.reviewID,
                        threadID: thread.id,
                        commentID: comment.id
                    )
                ))
            }
            if let committed, committed.isResolved != thread.isResolved {
                let subjectIsViewer = participants.contains(viewer.nodeID)
                    || committed.rootAuthorNodeID == viewer.nodeID
                    || commentedByViewerInCommittedThread(committed: committed, viewer: viewer)
                events.append(makeEvent(
                    kind: thread.isResolved ? .threadResolved : .threadReopened,
                    identityKey: "thread:\(thread.id):state:\(thread.isResolved)",
                    context: context,
                    actor: nil,
                    actorNodeID: nil,
                    subjectIsViewer: subjectIsViewer,
                    containsDirectMention: false,
                    occurredAt: context.now,
                    url: thread.comments.first?.url ?? context.pr.url,
                    revision: PRActivityRevision(headOID: context.headOID, threadID: thread.id)
                ))
            }
        }
        return events
    }

    private static func ciEvents(
        previous: CheckpointCI,
        fresh: MonitorCISnapshot,
        context: DerivationContext
    ) -> [PRActivityEvent] {
        let previousByID = Dictionary(previous.checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentHead = fresh.headOID ?? context.headOID
        var events: [PRActivityEvent] = []
        for check in fresh.checks {
            let onCurrentHead = check.headOID == nil || currentHead == nil || check.headOID == currentHead
            guard onCurrentHead else { continue }
            if let committed = previousByID[check.id] {
                if committed.isFailed, check.isSuccessful {
                    events.append(makeEvent(
                        kind: .ciCheckRecovered,
                        identityKey: "ci:\(check.id):recovered",
                        context: context,
                        actor: nil,
                        actorNodeID: nil,
                        subjectIsViewer: false,
                        containsDirectMention: false,
                        occurredAt: check.completedAt ?? context.now,
                        url: check.url,
                        revision: PRActivityRevision(headOID: currentHead, runID: check.runID, runAttempt: check.runAttempt, checkID: check.id)
                    ))
                } else if !committed.isFailed, check.isFailure {
                    // A job already known to the checkpoint can still finish as a
                    // failure: the conclusion changes while its ID stays the same.
                    events.append(makeEvent(
                        kind: .ciCheckFailed,
                        identityKey: "ci:\(check.id):failed",
                        context: context,
                        actor: nil,
                        actorNodeID: nil,
                        subjectIsViewer: false,
                        containsDirectMention: false,
                        occurredAt: check.completedAt ?? context.now,
                        url: check.url,
                        revision: PRActivityRevision(headOID: currentHead, runID: check.runID, runAttempt: check.runAttempt, checkID: check.id)
                    ))
                }
                continue
            }
            // A new check ID for a job that already existed under the same run/name is a
            // rerun attempt, not a brand-new failure of the same job.
            let previousAttempt = previous.checks.first {
                $0.runID == check.runID && $0.origin == check.origin && $0.name == check.name && $0.id != check.id
            }
            if let previousAttempt {
                events.append(makeEvent(
                    kind: .ciCheckRerunStarted,
                    identityKey: "ci:\(previousAttempt.id):rerun:\(check.id)",
                    context: context,
                    actor: nil,
                    actorNodeID: nil,
                    subjectIsViewer: false,
                    containsDirectMention: false,
                    occurredAt: check.startedAt ?? context.now,
                    url: check.url,
                    revision: PRActivityRevision(headOID: currentHead, runID: check.runID, runAttempt: check.runAttempt, checkID: check.id)
                ))
            }
            if check.isFailure {
                events.append(makeEvent(
                    kind: .ciCheckFailed,
                    identityKey: "ci:\(check.id):failed",
                    context: context,
                    actor: nil,
                    actorNodeID: nil,
                    subjectIsViewer: false,
                    containsDirectMention: false,
                    occurredAt: check.completedAt ?? context.now,
                    url: check.url,
                    revision: PRActivityRevision(headOID: currentHead, runID: check.runID, runAttempt: check.runAttempt, checkID: check.id)
                ))
            }
        }
        return events
    }

    private static func commentedByViewerBefore(
        thread: MonitorReviewThread,
        comment: MonitorThreadComment,
        viewer: MonitorViewerIdentity
    ) -> Bool {
        guard let index = thread.comments.firstIndex(where: { $0.id == comment.id }) else { return false }
        return thread.comments[..<index].contains { $0.authorNodeID == viewer.nodeID }
    }

    private static func commentedByViewerInCommittedThread(
        committed: CheckpointThread,
        viewer: MonitorViewerIdentity
    ) -> Bool {
        committed.participantNodeIDs.contains(viewer.nodeID)
    }

    static func mentionsViewer(_ body: String, viewer: MonitorViewerIdentity) -> Bool {
        guard !viewer.login.isEmpty else { return false }
        return GitHubAPIClient.directUsernameMentionCount(username: viewer.login, in: body) > 0
    }

    // MARK: Relevance

    /// Relevance reasons for one event. Returns an empty array when the event stays
    /// history-only. Never uses AI and never guesses an unknown relationship.
    static func relevance(
        for event: PRActivityEvent,
        pr: MonitoredPR,
        viewer: MonitorViewerIdentity
    ) -> [(reason: PRActionReason, action: PRActionKind)] {
        var results: [(PRActionReason, PRActionKind)] = []

        guard pr.lifecycle == .open else { return results }
        guard !event.isFromViewer else { return results }
        // Bot chatter stays in history unless it is a direct request to the user or a
        // failure of the current revision.
        if event.isBotActor, !event.containsDirectMention, event.kind != .ciCheckFailed {
            return results
        }

        switch event.kind {
        case .reviewSubmitted:
            guard pr.origins.contains(.authored) else { break }
            results.append((.authoredPRReviewFeedback, .reviewFeedback))
        case .reviewCommentAdded, .threadReplyAdded:
            if event.containsDirectMention {
                results.append((.authoredPRDirectMention, .respondToMention))
            } else if pr.origins.contains(.authored) {
                results.append((.authoredPRReviewFeedback, .reviewFeedback))
            } else if event.subjectIsViewer {
                results.append((.myThreadReply, .respondToMention))
            }
        case .threadResolved:
            if event.subjectIsViewer, !pr.origins.contains(.authored) {
                results.append((.myThreadResolved, .resolveThread))
            }
        case .threadReopened:
            if event.subjectIsViewer {
                results.append((.myThreadReply, .respondToMention))
            }
        case .conversationCommentAdded, .conversationCommentEdited:
            if event.containsDirectMention {
                results.append((.authoredPRDirectMention, .respondToMention))
            }
        case .reviewDismissed:
            if event.subjectIsViewer {
                results.append((.myApprovalDismissed, .reReview))
            }
        case .pushedNewCommit:
            if needsRereview(pr: pr, headOID: event.revision.headOID, viewer: viewer) {
                results.append((.myReviewNeedsRereview, .reReview))
            }
        case .reviewRequested:
            if event.subjectIsViewer {
                results.append((.reviewRequestedDirectly, .review))
            }
        case .ciCheckFailed:
            if pr.origins.contains(.authored) {
                results.append((.authoredPRCIFailure, .fixCI))
            }
        case .directMention:
            results.append((.authoredPRDirectMention, .respondToMention))
        case .ciCheckRecovered, .ciCheckRerunStarted, .prClosed, .prMerged, .prReopened:
            break
        }
        // Tracking widens which events are actionable. It must not add a second
        // reminder for an event that already has a more specific reason. This has to
        // happen before the return: a defer runs after `return results` has copied
        // the array, so it cannot change what the caller sees.
        if results.isEmpty, pr.origins.contains(.explicit), explicitlyTracked(pr: pr, kind: event.kind) {
            results.append((.explicitlyTracked, actionKind(for: event.kind)))
        }
        return results
    }

    private static func actionKind(for kind: PRActivityEventKind) -> PRActionKind {
        switch kind {
        case .reviewSubmitted, .reviewCommentAdded, .conversationCommentAdded, .conversationCommentEdited:
            return .reviewFeedback
        case .threadReplyAdded, .threadReopened, .directMention:
            return .respondToMention
        case .threadResolved:
            return .resolveThread
        case .reviewDismissed, .pushedNewCommit:
            return .reReview
        case .reviewRequested:
            return .review
        case .ciCheckFailed:
            return .fixCI
        case .ciCheckRecovered, .ciCheckRerunStarted:
            return .confirmCI
        case .prClosed, .prMerged, .prReopened:
            return .confirmCI
        }
    }

    private static func explicitlyTracked(pr: MonitoredPR, kind: PRActivityEventKind) -> Bool {
        guard let tracked = pr.trackedEventKinds else { return true }
        return tracked.contains(kind)
    }

    /// True when the viewer reviewed an older revision of this PR and has not yet
    /// reviewed the new head. A dismissed review never counts as having reviewed it.
    static func needsRereview(pr: MonitoredPR, headOID: String?, viewer: MonitorViewerIdentity) -> Bool {
        guard let headOID else { return false }
        guard pr.origins.contains(.reviewed) || pr.origins.contains(.requested) else { return false }
        let reviews = pr.checkpoint(for: .reviews)?.reviews ?? []
        let mine = reviews.filter { $0.authorNodeID == viewer.nodeID }
        guard let latest = mine.last else { return true }
        if latest.state == ReviewState.dismissed.rawValue { return true }
        return latest.commitOID != headOID
    }

    // MARK: Action item merging

    /// Merges newly derived events into the action-item list.
    ///
    /// One item per (PR, reason). New events reopen a handled/snoozed item while the
    /// covered event IDs keep a record of exactly what the user already dismissed.
    static func mergeActionItems(
        existing: [PRActionItem],
        newEvents: [PRActivityEvent],
        prs: [MonitoredPR],
        viewer: MonitorViewerIdentity,
        now: Date
    ) -> [PRActionItem] {
        var items = existing
        let prsByNodeID = Dictionary(prs.map { ($0.prNodeID, $0) }, uniquingKeysWith: { first, _ in first })

        for event in newEvents {
            guard let pr = prsByNodeID[event.prNodeID] else { continue }
            for (reason, action) in relevance(for: event, pr: pr, viewer: viewer) {
                let itemID = PRActionItem.identity(prNodeID: event.prNodeID, reason: reason)
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    var item = items[index]
                    if !item.eventIDs.contains(event.id) {
                        item.eventIDs.append(event.id)
                    }
                    if !item.actionKinds.contains(action) {
                        item.actionKinds.append(action)
                    }
                    item.revision = event.revision
                    if let url = event.url, !item.evidenceURLs.contains(url) {
                        item.evidenceURLs.append(url)
                    }
                    if !item.pendingEventIDs.isEmpty {
                        item.state = .open
                        item.snoozedUntil = nil
                        item.stateUpdatedAt = now
                    }
                    items[index] = item
                } else {
                    items.append(
                        PRActionItem(
                            id: itemID,
                            prNodeID: event.prNodeID,
                            reference: event.reference,
                            reasons: [reason],
                            actionKinds: [action],
                            eventIDs: [event.id],
                            revision: event.revision,
                            state: .open,
                            createdAt: now,
                            stateUpdatedAt: now,
                            snoozedUntil: nil,
                            coveredEventIDs: [],
                            evidenceURLs: event.url.map { [$0] } ?? []
                        )
                    )
                }
            }
        }
        return items
    }

    /// Retires action items that no longer apply.
    ///
    /// A CI failure is invalidated when that check passed, a later attempt of the same
    /// job replaced it, or the failure belongs to a head that is no longer current.
    /// A rereview reminder is invalidated once the viewer has reviewed the current head.
    /// Other events on the same item stay open.
    static func retireActionItems(
        _ items: [PRActionItem],
        prs: [MonitoredPR],
        recentEvents: [PRActivityEvent],
        viewer: MonitorViewerIdentity,
        now: Date
    ) -> [PRActionItem] {
        let prsByNodeID = Dictionary(prs.map { ($0.prNodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let eventsByID = Dictionary(recentEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eventsByPR = Dictionary(grouping: recentEvents, by: \.prNodeID)

        return items.map { item in
            guard item.state == .open || item.state == .snoozed || item.state == .rerunInProgress else { return item }
            guard let pr = prsByNodeID[item.prNodeID] else { return item }
            var updated = item

            if pr.lifecycle != .open {
                updated.state = .superseded
                updated.coveredEventIDs = item.eventIDs
                updated.snoozedUntil = nil
                updated.stateUpdatedAt = now
                return updated
            }

            let prEvents = eventsByPR[item.prNodeID] ?? []
            let stale = staleEventIDs(on: item, pr: pr, prEvents: prEvents, eventsByID: eventsByID, viewer: viewer)
            if stale.isEmpty {
                return markRerunIfNeeded(item, prEvents: prEvents, now: now)
            }

            for id in stale where !updated.coveredEventIDs.contains(id) {
                updated.coveredEventIDs.append(id)
            }
            if updated.pendingEventIDs.isEmpty {
                let staleEvents = stale.compactMap { eventsByID[$0] }
                updated.state = resolutionState(for: staleEvents, pr: pr)
                updated.snoozedUntil = nil
                updated.stateUpdatedAt = now
            }
            return updated
        }
    }

    /// Event IDs that must not be announced. Covered events and events on a retired
    /// item are included; an event still pending on another open item is not.
    static func eventsNoLongerNotifiable(_ items: [PRActionItem], now: Date) -> Set<String> {
        let pending = Set(items.filter { $0.isActionable(now: now) }.flatMap(\.pendingEventIDs))
        let dropped = items.flatMap { item -> [String] in
            item.isActionable(now: now) ? item.coveredEventIDs : item.eventIDs
        }
        return Set(dropped).subtracting(pending)
    }

    struct DigestResolution {
        var batches: [DigestBatch]
        var announcedEventIDs: [String]
        var withdrawBatchIDs: [String]
    }

    /// Drops resolved events from digests that have not been sent, and names delivered
    /// batches whose notification should be withdrawn because nothing in them still applies.
    static func resolveStaleDigests(
        batches: [DigestBatch],
        announcedEventIDs: [String],
        invalidated: Set<String>,
        events: [PRActivityEvent],
        items: [PRActionItem]
    ) -> DigestResolution {
        guard !invalidated.isEmpty else {
            return DigestResolution(batches: batches, announcedEventIDs: announcedEventIDs, withdrawBatchIDs: [])
        }
        var announced = Set(announcedEventIDs)
        announced.formUnion(invalidated)
        var withdraw: [String] = []
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let resolved = batches.map { batch -> DigestBatch in
            let live = batch.coveredEventIDs.filter { !invalidated.contains($0) }
            if live.isEmpty {
                if batch.deliveries.contains(where: { $0.channel == .macOS && $0.status == .delivered }) {
                    withdraw.append(batch.id)
                }
                var cancelled = batch
                cancelled.coveredEventIDs = []
                cancelled.entries = []
                cancelled.deliveries = batch.deliveries.map { delivery in
                    guard delivery.status != .delivered else { return delivery }
                    var updated = delivery
                    updated.status = .superseded
                    updated.failureMessage = String(localized: "No longer applies.")
                    updated.completedAt = updated.completedAt ?? Date()
                    return updated
                }
                return cancelled
            }
            guard live.count != batch.coveredEventIDs.count else { return batch }
            var updated = batch
            updated.coveredEventIDs = live
            updated.entries = scrubbedEntries(batch.entries, live: Set(live), eventsByID: eventsByID, items: items)
            return updated
        }
        return DigestResolution(
            batches: resolved,
            announcedEventIDs: Array(announced).sorted(),
            withdrawBatchIDs: withdraw
        )
    }

    /// The batch to send, or nil when every covered event has been resolved.
    static func deliverableBatch(
        _ batch: DigestBatch,
        invalidated: Set<String>,
        events: [PRActivityEvent],
        items: [PRActionItem]
    ) -> DigestBatch? {
        let live = batch.coveredEventIDs.filter { !invalidated.contains($0) }
        guard !live.isEmpty else { return nil }
        guard live.count != batch.coveredEventIDs.count else { return batch }
        var updated = batch
        updated.coveredEventIDs = live
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        updated.entries = scrubbedEntries(batch.entries, live: Set(live), eventsByID: eventsByID, items: items)
        return updated.entries.isEmpty ? nil : updated
    }

    private static func staleEventIDs(
        on item: PRActionItem,
        pr: MonitoredPR,
        prEvents: [PRActivityEvent],
        eventsByID: [String: PRActivityEvent],
        viewer: MonitorViewerIdentity
    ) -> Set<String> {
        var stale = Set<String>()
        let itemEvents = item.eventIDs.compactMap { eventsByID[$0] }
        stale.formUnion(staleCIFailureIDs(in: itemEvents, pr: pr, prEvents: prEvents))

        if item.reasons.contains(.myReviewNeedsRereview),
           let head = pr.headOID,
           !needsRereview(pr: pr, headOID: head, viewer: viewer) {
            stale.formUnion(itemEvents.filter { $0.kind == .pushedNewCommit }.map(\.id))
        }
        return stale
    }

    private static func staleCIFailureIDs(
        in itemEvents: [PRActivityEvent],
        pr: MonitoredPR,
        prEvents: [PRActivityEvent]
    ) -> Set<String> {
        guard let checks = pr.checkpoint(for: .ci)?.ci?.checks else { return [] }
        let checksByID = Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let successors = rerunSuccessors(in: prEvents)
        let currentHead = pr.headOID
        var stale = Set<String>()

        for event in itemEvents where event.kind == .ciCheckFailed {
            let checkID = event.revision.checkID
            if let checkID, let check = checksByID[checkID] {
                if check.isSuccessful || successorReplaced(checkID, successors: successors, checksByID: checksByID, head: currentHead) {
                    stale.insert(event.id)
                }
                continue
            }
            if let checkID, successorReplaced(checkID, successors: successors, checksByID: checksByID, head: currentHead) {
                stale.insert(event.id)
                continue
            }
            if let failedHead = event.revision.headOID, let currentHead, failedHead != currentHead {
                stale.insert(event.id)
            }
        }
        return stale
    }

    /// True when a later attempt of this check has finished. An in-progress rerun does
    /// not count: that stays a rerun, and only a finished attempt replaces the failure.
    private static func successorReplaced(
        _ checkID: String,
        successors: [String: String],
        checksByID: [String: CheckpointCheck],
        head: String?
    ) -> Bool {
        var seen = Set<String>()
        var current = checkID
        while let next = successors[current], seen.insert(next).inserted {
            if let check = checksByID[next],
               check.headOID == nil || head == nil || check.headOID == head,
               check.isSuccessful || check.isFailed {
                return true
            }
            current = next
        }
        return false
    }

    private static func rerunSuccessors(in events: [PRActivityEvent]) -> [String: String] {
        var map: [String: String] = [:]
        let marker = ":rerun:"
        for event in events where event.kind == .ciCheckRerunStarted && event.identityKey.hasPrefix("ci:") {
            guard let range = event.identityKey.range(of: marker) else { continue }
            let oldID = String(event.identityKey[event.identityKey.index(event.identityKey.startIndex, offsetBy: 3)..<range.lowerBound])
            let newID = String(event.identityKey[range.upperBound...])
            if !oldID.isEmpty, !newID.isEmpty {
                map[oldID] = newID
            }
        }
        return map
    }

    private static func resolutionState(for stale: [PRActivityEvent], pr: MonitoredPR) -> PRActionState {
        let passedOnCurrentHead = stale.contains { event in
            event.kind == .ciCheckFailed && (event.revision.headOID == nil || event.revision.headOID == pr.headOID)
        }
        return passedOnCurrentHead ? .recovered : .superseded
    }

    private static func markRerunIfNeeded(
        _ item: PRActionItem,
        prEvents: [PRActivityEvent],
        now: Date
    ) -> PRActionItem {
        guard item.actionKinds == [.fixCI], item.revision.runAttempt != nil else { return item }
        let attemptKey = "\(item.revision.runID ?? "")#\(item.revision.runAttempt ?? -1)"
        let rerunning = prEvents.contains { event in
            guard event.kind == .ciCheckRerunStarted || event.kind == .pushedNewCommit else { return false }
            return "\(event.revision.runID ?? "")#\(event.revision.runAttempt ?? -1)" == attemptKey
        }
        guard rerunning else { return item }
        var updated = item
        updated.state = .rerunInProgress
        updated.stateUpdatedAt = now
        return updated
    }

    private static func scrubbedEntries(
        _ entries: [DigestEntry],
        live: Set<String>,
        eventsByID: [String: PRActivityEvent],
        items: [PRActionItem]
    ) -> [DigestEntry] {
        entries.compactMap { entry in
            let liveItems = items.filter { item in
                entry.actionItemIDs.contains(item.id) && item.pendingEventIDs.contains { live.contains($0) }
            }
            let liveEventIDs = dedupe(liveItems.flatMap { $0.pendingEventIDs.filter { live.contains($0) } })
            guard !liveEventIDs.isEmpty else { return nil }
            var copy = entry
            copy.reasons = dedupe(liveItems.flatMap(\.reasons))
            copy.actionKinds = dedupe(liveItems.flatMap(\.actionKinds))
            copy.changeKinds = dedupe(liveEventIDs.compactMap { eventsByID[$0]?.kind })
            copy.eventCount = liveEventIDs.count
            copy.actionItemIDs = dedupe(liveItems.map(\.id))
            return copy
        }
    }

    /// Builds the next digest batch, or nil when nothing deserves a notification.
    ///
    /// An event is announced at most once. Events already delivered, and events
    /// already owned by an existing batch, stay out, so a later window cannot clone
    /// the same reminder. A failed batch is retried in place instead of copied.
    /// `mutedNodeIDs` carries the PR mute preference resolved by the caller.
    static func makeDigest(
        state: PRActivityAccountState,
        configuration: Configuration,
        now: Date,
        mutedNodeIDs: Set<String>
    ) -> DigestBatch? {
        let actionable = state.actionableItems(now: now)
        guard !actionable.isEmpty else { return nil }

        let eventsByID = Dictionary(state.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Owned by a batch that is in flight, already sent, failed, or of unknown
        // outcome. Cloning those IDs into a new batch is how the same event gets
        // notified twice.
        var suppressed = Set(state.digest.announcedEventIDs)
        for batch in state.digest.batches {
            suppressed.formUnion(batch.coveredEventIDs)
        }
        let announced = suppressed
        let allowedKinds = configuration.notificationEventKindFilter
        let prsByNodeID = Dictionary(state.monitoredPRs.map { ($0.prNodeID, $0) }, uniquingKeysWith: { first, _ in first })

        struct CandidatePR {
            var prNodeID: String
            var reference: PullRequestReference
            var title: String
            var reasons: [PRActionReason] = []
            var actionKinds: [PRActionKind] = []
            var changeKinds: [PRActivityEventKind] = []
            var eventIDs: [String] = []
            var itemIDs: [String] = []
            var evidenceURLs: [URL] = []
            var latestEventAt: Date
        }

        var candidates: [String: CandidatePR] = [:]
        for item in actionable {
            let tracked = prsByNodeID[item.prNodeID]?.isExplicitlyTracked ?? false
            guard !mutedNodeIDs.contains(item.prNodeID) else { continue }
            guard configuration.isRepositoryNotified(item.reference.repoFullName, explicitlyTracked: tracked) else { continue }
            let unannounced = item.pendingEventIDs.filter { !announced.contains($0) }
            let relevant = unannounced.compactMap { eventsByID[$0] }.filter { event in
                allowedKinds.isEmpty || allowedKinds.contains(event.kind)
            }
            guard !relevant.isEmpty else { continue }
            let latestEventAt = relevant.map(\.occurredAt).max() ?? now
            var candidate = candidates[item.prNodeID] ?? CandidatePR(
                prNodeID: item.prNodeID,
                reference: item.reference,
                title: prsByNodeID[item.prNodeID]?.title ?? "",
                latestEventAt: latestEventAt
            )
            candidate.latestEventAt = max(candidate.latestEventAt, latestEventAt)
            candidate.reasons.append(contentsOf: item.reasons)
            candidate.actionKinds.append(contentsOf: item.actionKinds)
            for event in relevant where !candidate.eventIDs.contains(event.id) {
                candidate.eventIDs.append(event.id)
            }
            if !candidate.itemIDs.contains(item.id) {
                candidate.itemIDs.append(item.id)
            }
            candidate.evidenceURLs.append(contentsOf: item.evidenceURLs)
            for event in relevant where !candidate.changeKinds.contains(event.kind) {
                candidate.changeKinds.append(event.kind)
            }
            candidates[item.prNodeID] = candidate
        }

        guard !candidates.isEmpty else { return nil }

        let ordered = candidates.values.sorted { lhs, rhs in
            if lhs.latestEventAt != rhs.latestEventAt { return lhs.latestEventAt > rhs.latestEventAt }
            return PullRequestReference.ordered(lhs.reference, rhs.reference, newestFirst: true)
        }
        let maxEntries = 5
        let included = ordered.prefix(maxEntries)
        let omitted = ordered.count - included.count

        let entries = included.map { candidate in
            DigestEntry(
                prNodeID: candidate.prNodeID,
                reference: candidate.reference,
                title: candidate.title,
                reasons: dedupe(candidate.reasons),
                actionKinds: dedupe(candidate.actionKinds),
                changeKinds: candidate.changeKinds,
                eventCount: candidate.eventIDs.count,
                actionItemIDs: candidate.itemIDs,
                evidenceURLs: dedupeURLs(candidate.evidenceURLs)
            )
        }

        let coveredEventIDs = dedupe(included.flatMap(\.eventIDs))
        let deliveries = configuration.digestChannels.map { channel in
            DigestDelivery(
                channel: channel,
                status: .pending,
                attemptedAt: nil,
                completedAt: nil,
                receipt: nil,
                failureMessage: nil,
                targetWorkspace: nil,
                targetUserID: nil
            )
        }
        guard !deliveries.isEmpty else { return nil }

        return DigestBatch(
            id: "digest_\(UUID().uuidString)",
            createdAt: now,
            entries: entries,
            coveredEventIDs: coveredEventIDs,
            coveredActionItemIDs: entries.flatMap(\.actionItemIDs),
            omittedEntryCount: max(omitted, 0),
            deliveries: deliveries
        )
    }

    private static func dedupe<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func dedupeURLs(_ urls: [URL]) -> [URL] {
        dedupe(urls)
    }

    /// One visible reminder per set of items that cite the same event. Distinct
    /// events on the same PR stay separate; a shared event is not shown twice.
    static func reminders(from items: [PRActionItem]) -> [ActivityReminder] {
        guard !items.isEmpty else { return [] }
        var parent = Array(items.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            if left != right { parent[right] = left }
        }

        var ownerByEvent: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            for eventID in item.eventIDs {
                if let owner = ownerByEvent[eventID] {
                    union(owner, index)
                } else {
                    ownerByEvent[eventID] = index
                }
            }
        }

        var grouped: [Int: [PRActionItem]] = [:]
        for (index, item) in items.enumerated() {
            grouped[find(index), default: []].append(item)
        }

        return grouped.values.map { group in
            let sorted = group.sorted { $0.stateUpdatedAt > $1.stateUpdatedAt }
            let itemIDs = dedupe(sorted.map(\.id))
            let state: PRActionState = sorted.contains { $0.state == .open } ? .open : (sorted.first?.state ?? .open)
            return ActivityReminder(
                id: itemIDs.sorted().joined(separator: "|"),
                itemIDs: itemIDs,
                reasons: dedupe(sorted.flatMap(\.reasons)),
                actionKinds: dedupe(sorted.flatMap(\.actionKinds)),
                eventIDs: dedupe(sorted.flatMap(\.eventIDs)),
                evidenceURLs: dedupeURLs(sorted.flatMap(\.evidenceURLs)),
                state: state,
                stateUpdatedAt: sorted.map(\.stateUpdatedAt).max() ?? .distantPast
            )
        }
        .sorted { $0.stateUpdatedAt > $1.stateUpdatedAt }
    }
}

// MARK: - Digest text

enum PRActivityDigestFormatter {
    static func nativeTitle(for batch: DigestBatch) -> String {
        if batch.omittedEntryCount > 0 {
            return String(localized: "\(batch.entries.count) PRs need attention (+\(batch.omittedEntryCount) more)")
        }
        return batch.entries.count == 1 ? String(localized: "1 PR needs attention") : String(localized: "\(batch.entries.count) PRs need attention")
    }

    static func nativeBody(for batch: DigestBatch) -> String {
        var lines: [String] = []
        for entry in batch.entries.prefix(3) {
            let reasons = entry.reasons.map(reasonLabel).joined(separator: ", ")
            lines.append("\(entry.reference.repoFullName)#\(entry.reference.number) — \(reasons)")
        }
        let remaining = max(0, batch.entries.count - 3) + batch.omittedEntryCount
        if remaining > 0 {
            lines.append(String(localized: "\(remaining) more PRs in Activity"))
        }
        return lines.joined(separator: "\n")
    }

    static func nativeUserInfo(for batch: DigestBatch) -> [String: String] {
        ["digestBatchID": batch.id]
    }

    static func slackText(for batch: DigestBatch) -> String {
        let title = batch.entries.count == 1 ? String(localized: "1 PR needs attention") : String(localized: "\(batch.entries.count) PRs need attention")
        var lines: [String] = ["*\(title)*"]
        for entry in batch.entries {
            let escapedTitle = SlackNotificationClient.escapedForSlack(entry.title)
            let reasons = entry.reasons.map(reasonLabel).joined(separator: ", ")
            let actions = entry.actionKinds.map(actionLabel).joined(separator: ", ")
            var line = "• <\(entry.evidenceURLs.first?.absoluteString ?? prURLString(entry))|\(entry.reference.repoFullName)#\(entry.reference.number)> \(escapedTitle)\n    _\(reasons)_ → \(actions)"
            if entry.eventCount > 1 {
                line += " (\(entry.eventCount) changes)"
            }
            lines.append(line)
        }
        if batch.omittedEntryCount > 0 {
            lines.append("_…and \(batch.omittedEntryCount) more in ghpr._")
        }
        return lines.joined(separator: "\n")
    }

    private static func prURLString(_ entry: DigestEntry) -> String {
        "https://github.com/\(entry.reference.repoFullName)/pull/\(entry.reference.number)"
    }

    static func reasonLabel(_ reason: PRActionReason) -> String {
        switch reason {
        case .authoredPRReviewFeedback: return String(localized: "review feedback on your PR")
        case .authoredPRCIFailure: return String(localized: "CI failure on your PR")
        case .authoredPRDirectMention: return String(localized: "you were mentioned")
        case .myApprovalDismissed: return String(localized: "your approval was dismissed")
        case .myThreadReply: return String(localized: "reply in your thread")
        case .myThreadResolved: return String(localized: "your thread was resolved")
        case .myReviewNeedsRereview: return String(localized: "new revision after your review")
        case .reviewRequestedDirectly: return String(localized: "you were asked to review")
        case .explicitlyTracked: return String(localized: "tracked by you")
        }
    }

    static func actionLabel(_ action: PRActionKind) -> String {
        switch action {
        case .reviewFeedback: return String(localized: "respond to review")
        case .fixCI: return String(localized: "fix CI")
        case .respondToMention: return String(localized: "reply")
        case .reReview: return String(localized: "review again")
        case .resolveThread: return String(localized: "close the thread")
        case .confirmCI: return String(localized: "confirm CI")
        case .review: return String(localized: "review")
        }
    }

    static func changeLabel(_ kind: PRActivityEventKind) -> String {
        switch kind {
        case .reviewSubmitted: return String(localized: "new review")
        case .reviewDismissed: return String(localized: "review dismissed")
        case .reviewCommentAdded: return String(localized: "new review comment")
        case .threadReplyAdded: return String(localized: "thread reply")
        case .threadResolved: return String(localized: "thread resolved")
        case .threadReopened: return String(localized: "thread reopened")
        case .conversationCommentAdded: return String(localized: "new comment")
        case .conversationCommentEdited: return String(localized: "comment edited")
        case .reviewRequested: return String(localized: "review requested")
        case .pushedNewCommit: return String(localized: "new commit")
        case .prClosed: return String(localized: "PR closed")
        case .prMerged: return String(localized: "PR merged")
        case .prReopened: return String(localized: "PR reopened")
        case .directMention: return String(localized: "you were mentioned")
        case .ciCheckFailed: return String(localized: "CI check failed")
        case .ciCheckRecovered: return String(localized: "CI check recovered")
        case .ciCheckRerunStarted: return String(localized: "CI rerun started")
        }
    }

    static func stateLabel(_ state: PRActionState) -> String {
        switch state {
        case .open: return String(localized: "open")
        case .handled: return String(localized: "handled")
        case .snoozed: return String(localized: "snoozed")
        case .superseded: return String(localized: "superseded")
        case .recovered: return String(localized: "CI recovered")
        case .rerunInProgress: return String(localized: "rerun in progress")
        }
    }

    static func sourceLabel(_ source: MonitorSourceKind) -> String {
        switch source {
        case .header: return String(localized: "PR header")
        case .reviews: return String(localized: "reviews")
        case .conversationComments: return String(localized: "comments")
        case .reviewThreads: return String(localized: "review threads")
        case .reviewRequests: return String(localized: "review requests")
        case .ci: return String(localized: "CI")
        }
    }

    static func deliveryLabel(_ status: DigestDeliveryStatus) -> String {
        switch status {
        case .pending: return String(localized: "pending")
        case .sending: return String(localized: "sending")
        case .delivered: return String(localized: "delivered")
        case .failed: return String(localized: "failed")
        case .unknown: return String(localized: "unknown")
        case .superseded: return String(localized: "no longer applies")
        }
    }
}

extension PRActionItem {
    static func identity(prNodeID: String, reason: PRActionReason) -> String {
        "\(prNodeID)|\(reason.rawValue)"
    }
}

// MARK: - Monitor

/// Owns the local PR activity monitor: account binding, acquisition passes, event
/// checkpoints, action items and digest delivery.
///
/// Guarantees:
/// - Nothing is committed to memory before the store accepted it: a failed write keeps
///   the previous committed observation, and the next pass re-derives the same events
///   with the same IDs, so a retry can never double-notify.
/// - Passes do not overlap. An event already owned by a digest batch is not cloned
///   into another batch; a failed batch is retried in place.
/// - A corrupt store file is reported and left in place instead of being reset.
/// - Every awaited step re-checks its generation, so an account, endpoint or
///   configuration switch discards in-flight results from the old generation.
@MainActor
final class PRActivityMonitor: ObservableObject {
    @Published private(set) var snapshot: PRActivitySnapshot = .idle

    /// Observation passes are no closer together than this, independent of the UI
    /// refresh interval.
    static let minimumObservationInterval: TimeInterval = 300
    /// At most one automated digest per window.
    static let digestWindow: TimeInterval = 1800
    /// Upper bound on PRs observed per pass, keeping rate-limit cost bounded.
    static let maxPRsPerPass = 25
    /// Closed or merged PRs are re-checked at most this often, to notice a reopen.
    static let closedPRObservationInterval: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRActivityMonitor")
    private let store: PRActivityStore
    private let clock: () -> Date
    private var configuration: Configuration
    private var isMuted: (PullRequestReference) -> Bool

    private var acquisition: MonitorAcquisitionProviding?
    private var channels: [PRActivityDigestChannel] = []
    private var state: PRActivityAccountState?
    private var viewer: MonitorViewerIdentity?
    private var generation = 0
    private var isRunning = false
    private var isPaused = false
    private var passTask: Task<Void, Never>?
    private var passInFlight = false
    private var queuedPass = false
    private var deliveringBatchIDs: Set<String> = []
    private var storeErrorMessage: String?

    init(
        store: PRActivityStore = .shared,
        configuration: Configuration = .default,
        clock: @escaping () -> Date = Date.init,
        isMuted: @escaping (PullRequestReference) -> Bool = { _ in false }
    ) {
        self.store = store
        self.configuration = configuration
        self.clock = clock
        self.isMuted = isMuted
    }

    // MARK: Wiring

    func setAcquisition(_ acquisition: MonitorAcquisitionProviding) {
        self.acquisition = acquisition
    }

    func setChannels(_ channels: [PRActivityDigestChannel]) {
        self.channels = channels
    }

    func setMutedProvider(_ provider: @escaping (PullRequestReference) -> Bool) {
        self.isMuted = provider
    }

    /// Applies a configuration change. Returns true when the observation timer must be
    /// rebuilt because the effective interval changed.
    @discardableResult
    func applyConfiguration(_ newConfiguration: Configuration) -> Bool {
        let previousInterval = observationInterval
        configuration = newConfiguration
        let withdrawIDs = dropUndeliverableDigests()
        publish()
        for id in withdrawIDs {
            channels.forEach { $0.withdrawDeliveredDigest(id: id) }
        }
        guard newConfiguration.monitorEnabled else {
            stop()
            return true
        }
        if isRunning, observationInterval != previousInterval {
            restartLoop()
            return true
        }
        return false
    }

    var observationInterval: TimeInterval {
        max(configuration.refreshInterval, Self.minimumObservationInterval)
    }

    // MARK: Lifecycle

    /// Starts monitoring without waiting for the popover to be opened.
    func start() {
        guard configuration.monitorEnabled, acquisition != nil, !isRunning else { return }
        isRunning = true
        restartLoop()
    }

    func stop() {
        isRunning = false
        generation += 1
        passTask?.cancel()
        passTask = nil
        publish()
    }

    /// Sign-out: cancel in-flight work and forget the bound account so the next account
    /// loads its own history. The signed-out account's stored state is never deleted.
    func handleSignOut() {
        stop()
        viewer = nil
        state = nil
        storeErrorMessage = nil
        publish()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            generation += 1
            passTask?.cancel()
            passTask = nil
        } else if isRunning {
            restartLoop()
        }
        publish()
    }

    /// Forces an immediate pass (used by the activity UI refresh action).
    func refreshNow() {
        guard configuration.monitorEnabled, acquisition != nil else { return }
        if isPaused { return }
        guard !isRunning else {
            // Already looping: schedule an immediate extra pass without touching timers.
            let currentGeneration = generation
            Task { [weak self] in
                await self?.performPass(generation: currentGeneration)
            }
            return
        }
        isRunning = true
        restartLoop()
    }

    private func restartLoop() {
        generation += 1
        let currentGeneration = generation
        passTask?.cancel()
        passTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    private func runLoop(generation loopGeneration: Int) async {
        await performPass(generation: loopGeneration)
        while !Task.isCancelled {
            let interval = observationInterval
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, generation == loopGeneration else { return }
            await performPass(generation: loopGeneration)
        }
    }

    // MARK: Pass

    /// Runs one discovery + observation pass. `generation` is re-checked after every
    /// await so a stale pass can never commit into a newer account or configuration.
    func performPass(generation passGeneration: Int) async {
        guard passGeneration == generation else { return }
        if passInFlight {
            queuedPass = true
            return
        }
        passInFlight = true
        defer {
            passInFlight = false
            let shouldContinue = queuedPass
            queuedPass = false
            if shouldContinue {
                let generation = self.generation
                Task { [weak self] in
                    await self?.performPass(generation: generation)
                }
            }
        }
        guard let acquisition, !isPaused, configuration.monitorEnabled else { return }
        guard passGeneration == generation else { return }

        let identity: MonitorViewerIdentity
        do {
            identity = try await resolveViewer(using: acquisition)
        } catch {
            logger.error("Monitor viewer identity unavailable: \(self.describe(error), privacy: .public)")
            publish(errorMessage: describe(error))
            return
        }
        guard passGeneration == generation else { return }
        viewer = identity

        let account = MonitorAccountKey(
            endpoint: configuration.graphQLEndpoint,
            viewerNodeID: identity.nodeID,
            login: identity.login
        )
        guard loadStateIfNeeded(for: account) else {
            publish()
            return
        }
        guard var candidate = state else { return }
        candidate.account.login = identity.login

        let now = clock()

        do {
            let discovery = try await acquisition.fetchMonitorDiscovery(scope: .all)
            guard passGeneration == generation else { return }
            applyDiscovery(discovery, to: &candidate, now: now)
        } catch {
            guard passGeneration == generation else { return }
            candidate.discoveryCoverage = MonitorDiscoveryCoverage(
                queries: MonitorOrigin.allCases.map { origin in
                    MonitorDiscoveryCoverage.QueryResult(
                        origin: origin,
                        isComplete: false,
                        incompleteReason: MonitorIncompleteReason(
                            kind: .unavailable,
                            statusCode: nil,
                            detail: error.localizedDescription
                        ),
                        referenceCount: 0
                    )
                },
                attemptedAt: now
            )
        }

        let targets = observationTargets(from: candidate.monitoredPRs, now: now)
        var newEvents: [PRActivityEvent] = []
        if !targets.isEmpty {
            let outcome = await acquisition.fetchMonitorObservations(
                for: targets,
                viewer: identity,
                sources: Set(MonitorSourceKind.allCases)
            )
            guard passGeneration == generation else { return }
            apply(observations: outcome, to: &candidate, viewer: identity, newEvents: &newEvents, now: now)
            if let deferral = outcome.deferralReason {
                logger.warning("Monitor pass deferred: \(deferral.kind.rawValue, privacy: .public) \(deferral.detail ?? "", privacy: .public)")
            }
        }

        var seenEventIDs = Set(candidate.events.map(\.id))
        newEvents = newEvents.filter { seenEventIDs.insert($0.id).inserted }
        candidate.actionItems = PRActivityEngine.mergeActionItems(
            existing: candidate.actionItems,
            newEvents: newEvents,
            prs: candidate.monitoredPRs,
            viewer: identity,
            now: now
        )
        candidate.events.append(contentsOf: newEvents)
        candidate.actionItems = PRActivityEngine.retireActionItems(
            candidate.actionItems,
            prs: candidate.monitoredPRs,
            recentEvents: candidate.events,
            viewer: identity,
            now: now
        )
        let invalidated = undeliverableEventIDs(in: candidate)
        let resolution = PRActivityEngine.resolveStaleDigests(
            batches: candidate.digest.batches,
            announcedEventIDs: candidate.digest.announcedEventIDs,
            invalidated: invalidated,
            events: candidate.events,
            items: candidate.actionItems
        )
        candidate.digest.batches = resolution.batches
        candidate.digest.announcedEventIDs = resolution.announcedEventIDs
        let withdrawIDs = resolution.withdrawBatchIDs
        candidate.hasEstablishedBaseline = true
        candidate.updatedAt = now

        guard commit(candidate) else {
            publish(errorMessage: storeErrorMessage ?? String(localized: "Activity history could not be saved."))
            return
        }
        let unhealthy = candidate.monitoredPRs.reduce(0) { $0 + $1.unhealthySources.count }
        let reasonHistogram = Dictionary(grouping: candidate.monitoredPRs.flatMap { $0.unhealthySources.values }, by: \.kind)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let firstDetail = candidate.monitoredPRs
            .flatMap { $0.unhealthySources.values }
            .compactMap { $0.detail }
            .first ?? ""
        let detailsByKind = Dictionary(grouping: candidate.monitoredPRs.flatMap { $0.unhealthySources.values }, by: \.kind)
            .compactMap { kind, reasons -> String? in
                guard let detail = reasons.compactMap({ $0.detail }).first else { return nil }
                return "\(kind.rawValue): \(detail.prefix(160))"
            }
            .sorted()
            .joined(separator: " | ")
        logger.info(
            "Monitor pass complete: prs=\(candidate.monitoredPRs.count, privacy: .public) observed=\(targets.count, privacy: .public) events=\(newEvents.count, privacy: .public) actionable=\(candidate.actionableItems(now: now).count, privacy: .public) unhealthySources=\(unhealthy, privacy: .public) discoveryComplete=\((candidate.discoveryCoverage?.isComplete ?? false), privacy: .public) reasons=\(reasonHistogram, privacy: .public) details=\(detailsByKind, privacy: .public)"
        )
        publish(lastPassAt: now)
        for id in withdrawIDs {
            channels.forEach { $0.withdrawDeliveredDigest(id: id) }
        }
        deliverDueDigest(generation: passGeneration)
    }

    private func resolveViewer(using acquisition: MonitorAcquisitionProviding) async throws -> MonitorViewerIdentity {
        if let viewer { return viewer }
        return try await acquisition.fetchViewerIdentity()
    }

    /// Loads persisted state once per account. Returns false when the stored history
    /// could not be read; monitoring then stops with a visible error instead of
    /// silently restarting from an empty checkpoint.
    private func loadStateIfNeeded(for account: MonitorAccountKey) -> Bool {
        if let state, state.account == account { return true }
        do {
            if let loaded = try store.load(account: account) {
                state = loaded
            } else {
                state = PRActivityAccountState(account: account, updatedAt: clock())
            }
            storeErrorMessage = nil
            reconcileAbandonedSendingDeliveries()
            return true
        } catch {
            storeErrorMessage = describe(error)
            isRunning = false
            generation += 1
            passTask?.cancel()
            passTask = nil
            logger.error("Monitor history unreadable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A crash between the `.sending` mark and the saved receipt must not leave a
    /// delivery that startup would either resend or ignore forever.
    private func reconcileAbandonedSendingDeliveries() {
        guard var candidate = state else { return }
        let now = clock()
        var changed = false
        for batchIndex in candidate.digest.batches.indices {
            for deliveryIndex in candidate.digest.batches[batchIndex].deliveries.indices {
                guard candidate.digest.batches[batchIndex].deliveries[deliveryIndex].status == .sending else { continue }
                candidate.digest.batches[batchIndex].deliveries[deliveryIndex].status = .unknown
                candidate.digest.batches[batchIndex].deliveries[deliveryIndex].failureMessage = "Delivery was interrupted before a receipt was saved."
                candidate.digest.batches[batchIndex].deliveries[deliveryIndex].completedAt = now
                changed = true
            }
        }
        guard changed else { return }
        candidate.updatedAt = now
        _ = commit(candidate)
    }

    // MARK: Applying results

    private func applyDiscovery(
        _ outcome: MonitorDiscoveryOutcome,
        to candidate: inout PRActivityAccountState,
        now: Date
    ) {
        candidate.discoveryCoverage = outcome.coverage
        for discovered in outcome.discovered {
            let existing = candidate.monitoredPRs.first { $0.prNodeID == discovered.prNodeID }
            guard configuration.collectsActivity(
                for: discovered.reference.repoFullName,
                explicitlyTracked: existing?.isExplicitlyTracked ?? false
            ) else { continue }
            if let index = candidate.monitoredPRs.firstIndex(where: { $0.prNodeID == discovered.prNodeID }) {
                var pr = candidate.monitoredPRs[index]
                pr.origins.formUnion(discovered.origins)
                if !discovered.title.isEmpty { pr.title = discovered.title }
                if let url = discovered.url { pr.url = url }
                candidate.monitoredPRs[index] = pr
            } else {
                // A newly discovered PR keeps its discovery metadata but no committed
                // checkpoint: the first complete observation establishes the baseline
                // silently. `lastObservedAt` on purpose stays in the past so the new PR
                // is observed first in the rotation.
                candidate.monitoredPRs.append(
                    MonitoredPR(
                        prNodeID: discovered.prNodeID,
                        reference: discovered.reference,
                        origins: discovered.origins,
                        lifecycle: discovered.lifecycle,
                        title: discovered.title,
                        url: discovered.url,
                        discoveredAt: now,
                        lastObservedAt: .distantPast
                    )
                )
            }
        }
    }

    private func observationTargets(from prs: [MonitoredPR], now: Date) -> [MonitoredPR] {
        let eligible = prs.filter { pr in
            guard configuration.collectsActivity(
                for: pr.reference.repoFullName,
                explicitlyTracked: pr.isExplicitlyTracked
            ) else { return false }
            guard pr.lifecycle != .open else { return true }
            return now.timeIntervalSince(pr.lastObservedAt) >= Self.closedPRObservationInterval
        }
        // Stalest first: rotation bounded by `maxPRsPerPass` keeps cost predictable.
        return Array(eligible.sorted { $0.lastObservedAt < $1.lastObservedAt }.prefix(Self.maxPRsPerPass))
    }

    private func undeliverableEventIDs(in state: PRActivityAccountState) -> Set<String> {
        PRActivityEngine.eventsNoLongerNotifiable(state.actionItems, now: clock())
            .union(outOfScopeEventIDs(in: state))
    }

    /// Cancels digests whose events are outside the current repository filter, without
    /// waiting for the next observation pass.
    private func dropUndeliverableDigests() -> [String] {
        guard var candidate = state else { return [] }
        let resolution = PRActivityEngine.resolveStaleDigests(
            batches: candidate.digest.batches,
            announcedEventIDs: candidate.digest.announcedEventIDs,
            invalidated: undeliverableEventIDs(in: candidate),
            events: candidate.events,
            items: candidate.actionItems
        )
        guard resolution.batches != candidate.digest.batches
            || resolution.announcedEventIDs != candidate.digest.announcedEventIDs else {
            return []
        }
        candidate.digest.batches = resolution.batches
        candidate.digest.announcedEventIDs = resolution.announcedEventIDs
        candidate.updatedAt = clock()
        guard commit(candidate) else { return [] }
        return resolution.withdrawBatchIDs
    }

    private func outOfScopeEventIDs(in state: PRActivityAccountState) -> Set<String> {
        let tracked = Set(state.monitoredPRs.filter(\.isExplicitlyTracked).map(\.prNodeID))
        return Set(state.events.compactMap { event in
            configuration.isRepositoryNotified(event.reference.repoFullName, explicitlyTracked: tracked.contains(event.prNodeID))
                ? nil
                : event.id
        })
    }

    private func apply(
        observations outcome: MonitorSnapshotOutcome,
        to candidate: inout PRActivityAccountState,
        viewer: MonitorViewerIdentity,
        newEvents: inout [PRActivityEvent],
        now: Date
    ) {
        for observation in outcome.observations {
            guard let index = candidate.monitoredPRs.firstIndex(where: { $0.prNodeID == observation.prNodeID }) else { continue }
            var pr = candidate.monitoredPRs[index]
            var sawCompleteSource = false

            // Header first: the committed head must be current before the
            // revision-bound sources are derived.
            if let headerObservation = observation.observation(for: .header) {
                if let payload = headerObservation.payload, let header = payload.header, headerObservation.isComplete {
                    let derivation = PRActivityEngine.derive(
                        observation: headerObservation,
                        pr: pr,
                        viewer: viewer,
                        now: now
                    )
                    if let derivation {
                        apply(derivation, source: .header, to: &pr, newEvents: &newEvents)
                        pr.headOID = header.headOID ?? pr.headOID
                        pr.lifecycle = header.state
                        pr.title = header.title.isEmpty ? pr.title : header.title
                        pr.url = header.url ?? pr.url
                        sawCompleteSource = true
                    } else {
                        pr.setUnhealthy(MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: "missing header payload"), for: .header)
                    }
                } else {
                    pr.setUnhealthy(headerObservation.incompleteReason ?? MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: nil), for: .header)
                }
            }

            for source in [MonitorSourceKind.reviews, .conversationComments, .reviewThreads, .reviewRequests, .ci] {
                guard let sourceObservation = observation.observation(for: source) else { continue }
                if let derivation = PRActivityEngine.derive(
                    observation: sourceObservation,
                    pr: pr,
                    viewer: viewer,
                    now: now
                ) {
                    apply(derivation, source: source, to: &pr, newEvents: &newEvents)
                    sawCompleteSource = true
                } else if sourceObservation.isComplete {
                    pr.setUnhealthy(MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: "missing \(source.rawValue) payload"), for: source)
                } else {
                    pr.setUnhealthy(
                        sourceObservation.incompleteReason ?? MonitorIncompleteReason(kind: .unavailable, statusCode: nil, detail: nil),
                        for: source
                    )
                }
            }

            pr.lastObservedAt = now
            if sawCompleteSource { pr.lastCompleteObservationAt = now }
            candidate.monitoredPRs[index] = pr
        }
    }

    private func apply(
        _ derivation: PRActivityEngine.SourceDerivation,
        source: MonitorSourceKind,
        to pr: inout MonitoredPR,
        newEvents: inout [PRActivityEvent]
    ) {
        pr.setCheckpoint(derivation.checkpoint, for: source)
        pr.setUnhealthy(nil, for: source)
        guard !derivation.events.isEmpty else { return }
        // A source change sequence advances only with committed events, inside the same
        // transaction. Re-reading an unchanged source therefore produces no new events.
        pr.setSequence(pr.sequence(for: source) + 1, for: source)
        newEvents.append(contentsOf: derivation.events)
    }

    /// Persists first, then advances in-memory state. Returns false when the write
    /// failed; the caller then keeps the previous committed observation.
    private func commit(_ candidate: PRActivityAccountState) -> Bool {
        do {
            try store.persist(candidate)
            state = candidate
            storeErrorMessage = nil
            return true
        } catch {
            storeErrorMessage = describe(error)
            logger.error("Monitor commit failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Digest

    private func deliverDueDigest(generation passGeneration: Int) {
        guard configuration.notificationsEnabled, let state else { return }
        let now = clock()
        let windowElapsed = state.digest.lastAutoDigestAt.map { now.timeIntervalSince($0) >= Self.digestWindow } ?? true
        let available = channels.filter(\.isAvailable)
        guard !available.isEmpty else { return }

        // One automated send per window. A failed batch is retried as itself; its
        // events are not copied into a second notification.
        if windowElapsed, let batchID = newestRetryableFailedBatchID(in: state) {
            guard retryFailedBatch(batchID, now: now) else { return }
            startDelivery(batchID: batchID, generation: passGeneration)
            return
        }

        startPendingDeliveries(generation: passGeneration)
        guard windowElapsed else { return }

        // Mute is a delivery preference: resolve it here so the pure digest builder
        // never needs UI state, and collection stays unaffected.
        let mutedNodeIDs = Set(state.monitoredPRs.filter { isMuted($0.reference) }.map(\.prNodeID))
        guard var batch = PRActivityEngine.makeDigest(
            state: state,
            configuration: configuration,
            now: now,
            mutedNodeIDs: mutedNodeIDs
        ) else { return }

        batch.deliveries = batch.deliveries.compactMap { delivery in
            guard let channel = available.first(where: { $0.channel == delivery.channel }) else { return nil }
            var bound = delivery
            bound.targetWorkspace = channel.targetBinding["workspace"]
            bound.targetUserID = channel.targetBinding["user"]
            return bound
        }
        guard !batch.deliveries.isEmpty else { return }

        var candidate = state
        candidate.digest.batches.append(batch)
        if candidate.digest.batches.count > 20 {
            candidate.digest.batches = Array(candidate.digest.batches.suffix(20))
        }
        candidate.digest.lastAutoDigestAt = now
        candidate.digest.lastAutoDigestBatchID = batch.id
        candidate.updatedAt = now
        guard commit(candidate) else { return }
        logger.info("Digest batch queued: \(batch.entries.count, privacy: .public) entries across \(batch.deliveries.count, privacy: .public) channel(s)")
        publish()
        startDelivery(batchID: batch.id, generation: passGeneration)
    }

    /// Newest failed batch that still has an event the user has not been told about.
    /// Older clones of the same event are left alone so a retry cannot fan out.
    private func newestRetryableFailedBatchID(in state: PRActivityAccountState) -> String? {
        let announced = Set(state.digest.announcedEventIDs)
        return state.digest.batches.reversed().first { batch in
            let failed = batch.deliveries.contains { $0.status == .failed }
            let unannounced = batch.coveredEventIDs.contains { !announced.contains($0) }
            return failed && unannounced
        }?.id
    }

    private func retryFailedBatch(_ batchID: String, now: Date) -> Bool {
        guard var candidate = state, let index = candidate.digest.batches.firstIndex(where: { $0.id == batchID }) else { return false }
        var reset = false
        for deliveryIndex in candidate.digest.batches[index].deliveries.indices {
            guard candidate.digest.batches[index].deliveries[deliveryIndex].status == .failed else { continue }
            candidate.digest.batches[index].deliveries[deliveryIndex].status = .pending
            candidate.digest.batches[index].deliveries[deliveryIndex].failureMessage = nil
            reset = true
        }
        guard reset else { return false }
        candidate.digest.lastAutoDigestAt = now
        candidate.updatedAt = now
        guard commit(candidate) else { return false }
        publish()
        return true
    }

    /// Finishes a batch that was committed but never sent (for example after a crash).
    /// Does not create a new batch, so the same events are not announced twice.
    private func startPendingDeliveries(generation passGeneration: Int) {
        guard let state else { return }
        for batch in state.digest.batches where batch.deliveries.contains(where: { $0.status == .pending }) {
            startDelivery(batchID: batch.id, generation: passGeneration)
        }
    }

    private func startDelivery(batchID: String, generation passGeneration: Int) {
        guard deliveringBatchIDs.insert(batchID).inserted else { return }
        Task { [weak self] in
            await self?.deliver(batchID: batchID, generation: passGeneration)
            self?.deliveringBatchIDs.remove(batchID)
        }
    }

    /// User-initiated retry of a batch whose delivery failed or ended unknown.
    func retryDigestBatch(id: String) {
        guard var candidate = state, let batchIndex = candidate.digest.batches.firstIndex(where: { $0.id == id }) else { return }
        let invalidated = undeliverableEventIDs(in: candidate)
        guard PRActivityEngine.deliverableBatch(
            candidate.digest.batches[batchIndex],
            invalidated: invalidated,
            events: candidate.events,
            items: candidate.actionItems
        ) != nil else { return }
        for index in candidate.digest.batches[batchIndex].deliveries.indices {
            let status = candidate.digest.batches[batchIndex].deliveries[index].status
            guard status == .failed || status == .unknown else { continue }
            candidate.digest.batches[batchIndex].deliveries[index].status = .pending
            candidate.digest.batches[batchIndex].deliveries[index].failureMessage = nil
        }
        guard commit(candidate) else { return }
        startDelivery(batchID: id, generation: generation)
    }

    /// Delivers the pending channels of one batch. Each channel commits its own receipt;
    /// a failure never marks the batch delivered and never marks another channel as
    /// successful.
    func deliver(batchID: String, generation passGeneration: Int) async {
        while true {
            guard let current = state,
                  let batchIndex = current.digest.batches.firstIndex(where: { $0.id == batchID }) else { return }
            let batch = current.digest.batches[batchIndex]
            guard let pendingIndex = batch.deliveries.firstIndex(where: { $0.status == .pending }) else { return }
            let delivery = batch.deliveries[pendingIndex]
            guard let channel = channels.first(where: { $0.channel == delivery.channel }) else {
                mark(delivery: pendingIndex, in: batchID, status: .failed, message: String(localized: "Delivery channel is not configured."), receipt: nil)
                continue
            }
            if delivery.targetWorkspace != channel.targetBinding["workspace"]
                || delivery.targetUserID != channel.targetBinding["user"] {
                mark(
                    delivery: pendingIndex,
                    in: batchID,
                    status: .failed,
                    message: String(localized: "The delivery target changed after this batch was created."),
                    receipt: nil
                )
                continue
            }

            let invalidated = undeliverableEventIDs(in: current)
            guard let sendable = PRActivityEngine.deliverableBatch(
                batch,
                invalidated: invalidated,
                events: current.events,
                items: current.actionItems
            ) else {
                mark(delivery: pendingIndex, in: batchID, status: .superseded, message: String(localized: "No longer applies."), receipt: nil)
                continue
            }

            mark(delivery: pendingIndex, in: batchID, status: .sending, message: nil, receipt: nil)
            if passGeneration != generation {
                mark(delivery: pendingIndex, in: batchID, status: .pending, message: nil, receipt: nil)
                return
            }

            do {
                let receipt = try await channel.deliver(sendable)
                let resolvedDuringSend = undeliverableEventIDs(in: state ?? current)
                if sendable.coveredEventIDs.allSatisfy({ resolvedDuringSend.contains($0) }) {
                    channel.withdrawDeliveredDigest(id: batchID)
                    mark(delivery: pendingIndex, in: batchID, status: .superseded, message: String(localized: "No longer applies."), receipt: nil)
                    continue
                }
                mark(delivery: pendingIndex, in: batchID, status: .delivered, message: nil, receipt: receipt)
                if state != nil {
                    recordAnnouncedEvents(sendable.coveredEventIDs, batchID: batchID)
                }
                if passGeneration != generation {
                    return
                }
            } catch let error as SlackClientError {
                switch error {
                case .rateLimited(let retryAfter):
                    let message = retryAfter.map { String(localized: "Slack rate limited; retry after \(Int($0))s.") }
                        ?? String(localized: "Slack rate limited.")
                    mark(delivery: pendingIndex, in: batchID, status: .failed, message: message, receipt: nil)
                case .responseLost:
                    mark(
                        delivery: pendingIndex,
                        in: batchID,
                        status: .unknown,
                        message: String(localized: "Slack did not answer; the message may or may not have been delivered."),
                        receipt: nil
                    )
                case .cancelled:
                    mark(delivery: pendingIndex, in: batchID, status: .unknown, message: String(localized: "Delivery cancelled."), receipt: nil)
                default:
                    mark(delivery: pendingIndex, in: batchID, status: .failed, message: error.localizedDescription, receipt: nil)
                }
            } catch {
                mark(
                    delivery: pendingIndex,
                    in: batchID,
                    status: .unknown,
                    message: error.localizedDescription,
                    receipt: nil
                )
            }
        }
    }

    private func mark(
        delivery deliveryIndex: Int,
        in batchID: String,
        status: DigestDeliveryStatus,
        message: String?,
        receipt: DigestReceipt?
    ) {
        guard var candidate = state,
              let batchIndex = candidate.digest.batches.firstIndex(where: { $0.id == batchID }),
              deliveryIndex < candidate.digest.batches[batchIndex].deliveries.count else { return }
        var delivery = candidate.digest.batches[batchIndex].deliveries[deliveryIndex]
        delivery.status = status
        delivery.failureMessage = message
        if let receipt { delivery.receipt = receipt }
        if status == .sending { delivery.attemptedAt = clock() }
        if status == .delivered || status == .failed || status == .unknown || status == .superseded { delivery.completedAt = clock() }
        candidate.digest.batches[batchIndex].deliveries[deliveryIndex] = delivery
        candidate.updatedAt = clock()
        guard commit(candidate) else { return }
        publish()
    }

    private func recordAnnouncedEvents(_ eventIDs: [String], batchID: String) {
        guard var candidate = state else { return }
        var announced = Set(candidate.digest.announcedEventIDs)
        announced.formUnion(eventIDs)
        candidate.digest.announcedEventIDs = Array(announced).sorted()
        candidate.updatedAt = clock()
        guard commit(candidate) else { return }
        logger.info("Digest delivered: batch=\(batchID, privacy: .public) events=\(eventIDs.count, privacy: .public)")
        publish()
    }

    // MARK: User actions

    func markHandled(itemID: String, now: Date? = nil) {
        markHandled(itemIDs: [itemID], now: now)
    }

    func markHandled(itemIDs: [String], now: Date? = nil) {
        let timestamp = now ?? clock()
        updateItems(itemIDs) { item in
            item.state = .handled
            item.coveredEventIDs = item.eventIDs
            item.snoozedUntil = nil
            item.stateUpdatedAt = timestamp
        }
    }

    func snooze(itemID: String, until: Date) {
        snooze(itemIDs: [itemID], until: until)
    }

    func snooze(itemIDs: [String], until: Date) {
        let timestamp = clock()
        updateItems(itemIDs) { item in
            item.state = .snoozed
            item.coveredEventIDs = item.eventIDs
            item.snoozedUntil = until
            item.stateUpdatedAt = timestamp
        }
    }

    func reopen(itemID: String) {
        updateItem(itemID) { item in
            item.state = .open
            item.snoozedUntil = nil
            item.stateUpdatedAt = self.clock()
        }
    }

    func setExplicitTracking(prNodeID: String, eventKinds: Set<PRActivityEventKind>?) {
        guard var candidate = state, let index = candidate.monitoredPRs.firstIndex(where: { $0.prNodeID == prNodeID }) else { return }
        var pr = candidate.monitoredPRs[index]
        pr.isExplicitlyTracked = true
        pr.trackedEventKinds = eventKinds
        pr.origins.insert(.explicit)
        candidate.monitoredPRs[index] = pr
        candidate.updatedAt = clock()
        guard commit(candidate) else { return }
        publish()
    }

    /// Stops following a PR. Pin/read state elsewhere is untouched.
    func stopTracking(prNodeID: String) {
        guard var candidate = state, let index = candidate.monitoredPRs.firstIndex(where: { $0.prNodeID == prNodeID }) else { return }
        var pr = candidate.monitoredPRs[index]
        pr.isExplicitlyTracked = false
        pr.trackedEventKinds = nil
        pr.origins.remove(.explicit)
        if pr.origins.isEmpty {
            candidate.monitoredPRs.remove(at: index)
        } else {
            candidate.monitoredPRs[index] = pr
        }
        candidate.updatedAt = clock()
        guard commit(candidate) else { return }
        publish()
    }

    private func updateItem(_ itemID: String, transform: (inout PRActionItem) -> Void) {
        updateItems([itemID], transform: transform)
    }

    private func updateItems(_ itemIDs: [String], transform: (inout PRActionItem) -> Void) {
        guard var candidate = state else { return }
        let wanted = Set(itemIDs)
        var changed = false
        for index in candidate.actionItems.indices where wanted.contains(candidate.actionItems[index].id) {
            var item = candidate.actionItems[index]
            transform(&item)
            candidate.actionItems[index] = item
            changed = true
        }
        guard changed else { return }
        candidate.updatedAt = clock()
        guard commit(candidate) else {
            publish()
            return
        }
        publish()
    }

    // MARK: Publishing

    private func publish(lastPassAt: Date? = nil, errorMessage: String? = nil) {
        var next = snapshot
        next.isRunning = isRunning && !isPaused
        next.isPaused = isPaused
        next.account = state?.account ?? viewer.map {
            MonitorAccountKey(endpoint: configuration.graphQLEndpoint, viewerNodeID: $0.nodeID, login: $0.login)
        }
        if let lastPassAt { next.lastPassAt = lastPassAt }
        next.lastDigestAt = state?.digest.lastAutoDigestAt
        next.coverage = state?.discoveryCoverage
        next.monitoredPRs = state?.monitoredPRs ?? []
        next.actionItems = state?.actionItems ?? []
        next.events = state?.events ?? []
        next.batches = state?.digest.batches ?? []
        next.isEstablishingBaseline = !(state?.hasEstablishedBaseline ?? false)
        next.errorMessage = errorMessage ?? storeErrorMessage
        snapshot = next
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Snapshot helpers for the UI

    /// Actionable items grouped per PR, most recent first.
    func actionableItemsByPR(now: Date? = nil) -> [(pr: MonitoredPR, items: [PRActionItem])] {
        let items = snapshot.actionItems.filter { $0.isActionable(now: now ?? clock()) }
        let grouped = Dictionary(grouping: items, by: \.prNodeID)
        let prs = snapshot.monitoredPRs
        return grouped
            .compactMap { nodeID, items -> (MonitoredPR, [PRActionItem])? in
                guard let pr = prs.first(where: { $0.prNodeID == nodeID }) else { return nil }
                return (pr, items.sorted { $0.stateUpdatedAt > $1.stateUpdatedAt })
            }
            .sorted { lhs, rhs in
                PullRequestReference.ordered(lhs.0.reference, rhs.0.reference, newestFirst: true)
            }
            .map { (pr: $0.0, items: $0.1) }
    }

    func events(forPR prNodeID: String, limit: Int = 20) -> [PRActivityEvent] {
        snapshot.events
            .filter { $0.prNodeID == prNodeID }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    #if DEBUG
    /// Test seam: installs a state without going through acquisition.
    func setStateForTesting(_ state: PRActivityAccountState, viewer: MonitorViewerIdentity) {
        self.state = state
        self.viewer = viewer
        publish()
    }

    func currentStateForTesting() -> PRActivityAccountState? { state }

    /// Test seam: runs one pass with the current generation, bypassing the timer.
    func runPassForTesting() async {
        await performPass(generation: generation)
    }

    /// Test seam: runs the digest scheduling decision with the current generation.
    func runDigestForTesting() {
        deliverDueDigest(generation: generation)
    }

    func setViewerForTesting(_ viewer: MonitorViewerIdentity) {
        self.viewer = viewer
    }

    func loadStateForTesting(account: MonitorAccountKey) -> Bool {
        loadStateIfNeeded(for: account)
    }
    #endif
}

