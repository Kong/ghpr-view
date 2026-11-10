import Foundation
import SwiftUI

// A role is part of display identity; pin/repository placement is not.
enum PRSectionID: String, CaseIterable {
    case authored, reviewRequests, mentioned, directMentions, mergedToday

    var title: LocalizedStringKey {
        switch self {
        case .authored: return "My PRs"
        case .reviewRequests: return "Review Requests"
        case .mentioned: return "Mentioned PRs"
        case .directMentions: return "Direct Mentions"
        case .mergedToday: return "Merged Today"
        }
    }
}

/// How a category names the role sections above its rows.
enum PRSectionHeaderStyle: Equatable {
    /// All keeps one collapsible header per role section.
    case collapsible
    /// Mentions keeps fixed labels that separate roles without hiding rows.
    case fixed
    /// My PRs and Reviews are named by the selected tab itself.
    case hidden
}

enum PRPanelCategory: String, CaseIterable, Identifiable {
    case all, myPRs, reviews, mentions

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .myPRs: return "My PRs"
        case .reviews: return "Reviews"
        case .mentions: return "Mentions"
        }
    }

    var sections: [PRSectionID] {
        switch self {
        case .all: return PRSectionID.allCases
        case .myPRs: return [.authored]
        case .reviews: return [.reviewRequests]
        case .mentions: return [.mentioned, .directMentions]
        }
    }

    /// Only All owns per-section disclosure; scoped tabs always show their rows.
    var sectionHeaderStyle: PRSectionHeaderStyle {
        switch self {
        case .all: return .collapsible
        case .mentions: return .fixed
        case .myPRs, .reviews: return .hidden
        }
    }
}

struct PRPanelRowID: Hashable {
    let section: PRSectionID
    let prID: Int
}

/// Materialized once per presentation revision. Never compare PullRequest values to
/// detect changes: their equality intentionally compares IDs only.
struct PRPanelProjection {
    let filteredPRs: [PullRequest]
    let authoredPRs: [PullRequest]
    let pinnedAuthoredPRs: [PullRequest]
    let unpinnedAuthoredPRs: [PullRequest]
    let reviewRequestPRs: [PullRequest]
    let pinnedReviewRequestPRs: [PullRequest]
    let unpinnedReviewRequestPRs: [PullRequest]
    let mentionedPRs: [PullRequest]
    let directMentionPRs: [PullRequest]
    let mergedLast24hPRs: [PullRequest]
    let groupedAuthoredPRs: [(String, [PullRequest])]
    let groupedReviewPRs: [(String, [PullRequest])]
    let groupedMentionedPRs: [(String, [PullRequest])]
    let groupedDirectMentionPRs: [(String, [PullRequest])]
    let groupedMergedLast24hPRs: [(String, [PullRequest])]
    let summaryReadyToMerge: Int
    let summaryChangesRequested: Int
    let summaryCIFailing: Int
    let summaryCIRunning: Int
    let summaryWaitingForMyReview: Int
    let sourcePRs: [PullRequest]
    let facetChips: [FacetChip]
    let facetOptions: [FacetFieldID: [FacetOption]]
    let searchLabelSuggestions: [FacetOption]
    fileprivate let nextMergedExpiry: Date?
    private let rowsByID: [PRPanelRowID: PullRequest]
    private let rowIDsBySection: [PRSectionID: [PRPanelRowID]]

    func displayedRowIDs(for section: PRSectionID) -> [PRPanelRowID] {
        rowIDsBySection[section] ?? []
    }

    func displayedRowIDs(for category: PRPanelCategory) -> [PRPanelRowID] {
        category.sections.flatMap { displayedRowIDs(for: $0) }
    }

    func pr(for id: PRPanelRowID) -> PullRequest? { rowsByID[id] }

    static func make(
        prList: PRList,
        searchText: String,
        selections: [FacetFieldID: Set<String>],
        pinnedIdentifiers: Set<String>,
        configuration: Configuration,
        now: Date
    ) -> PRPanelProjection {
        let parsedSearch = PRSearchScope.parse(searchText)
        func filter(_ prs: [PullRequest]) -> [PullRequest] {
            prs.filter { FacetPredicate.matches($0, parsedSearch: parsedSearch, selections: selections) }
        }
        func group(_ prs: [PullRequest], merged: Bool = false) -> [(String, [PullRequest])] {
            Dictionary(grouping: prs, by: \.repoFullName)
                .map { repo, prs in
                    (repo, prs.sorted {
                        let lhsDate = merged ? ($0.mergedAt ?? $0.updatedAt) : $0.updatedAt
                        let rhsDate = merged ? ($1.mergedAt ?? $1.updatedAt) : $1.updatedAt
                        return lhsDate > rhsDate
                    })
                }
                .sorted { $0.0 < $1.0 }
        }
        let filtered = filter(prList.pullRequests)
        let authored = filtered.filter { $0.category == .authored }
        let pinnedAuthored = authored.filter { pinnedIdentifiers.contains($0.pinIdentifier) }
        let unpinnedAuthored = authored.filter { !pinnedIdentifiers.contains($0.pinIdentifier) }
        let reviews = filtered.filter { $0.category == .reviewRequest }
        let pinnedReviews = reviews.filter { pinnedIdentifiers.contains($0.pinIdentifier) }
        let unpinnedReviews = reviews.filter { !pinnedIdentifiers.contains($0.pinIdentifier) }
        let mentioned = filter(prList.mentionedPullRequests)
        let directMentions = filter(prList.directMentionPullRequests)
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var mergedSeen = Set<Int>()
        var nextMergedExpiry: Date?
        let merged = filter(prList.mergedPullRequests).filter { pr in
            guard let mergedAt = pr.mergedAt, mergedAt >= cutoff else { return false }
            let expiry = mergedAt.addingTimeInterval(24 * 60 * 60)
            nextMergedExpiry = min(nextMergedExpiry ?? expiry, expiry)
            return true
        }.filter { mergedSeen.insert($0.id).inserted }
            .sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }
        let groupedAuthored = group(unpinnedAuthored)
        let groupedReviews = group(unpinnedReviews)
        let groupedMentioned = group(mentioned)
        let groupedDirectMentions = group(directMentions)
        let groupedMerged = group(merged, merged: true)
        var sourceSeen = Set<Int>()
        let source = (prList.pullRequests + prList.mentionedPullRequests + prList.directMentionPullRequests + prList.mergedPullRequests)
            .filter { sourceSeen.insert($0.id).inserted }
        let builder = FacetIndexBuilder(sourcePRs: source, searchText: searchText, selections: selections)
        let options = Dictionary(uniqueKeysWithValues: FacetFieldID.allCases.map { ($0, builder.options(for: $0)) })
        let chips = selections.flatMap { field, keys in
            let names = Dictionary(uniqueKeysWithValues: (options[field] ?? []).map { ($0.key, $0.displayName) })
            return keys.sorted().map { key in
                FacetChip(field: field, key: key, displayName: names[key] ?? key, provider: field.provider)
            }
        }.sorted { $0.field.rawValue < $1.field.rawValue }
        let query = FacetValues.normalized(parsedSearch.term)
        var labelSuggestions: [FacetOption] = []
        if parsedSearch.kind == .all && !query.isEmpty {
            let labelBuilder = FacetIndexBuilder(sourcePRs: source, searchText: "", selections: selections)
            labelSuggestions = Array([FacetFieldID.githubLabel, .jiraLabel]
                .flatMap { labelBuilder.options(for: $0) }
                .filter { !(selections[$0.field] ?? []).contains($0.key) && FacetValues.normalized($0.displayName).contains(query) }
                .sorted { lhs, rhs in
                    let lhsStarts = FacetValues.normalized(lhs.displayName).hasPrefix(query)
                    let rhsStarts = FacetValues.normalized(rhs.displayName).hasPrefix(query)
                    if lhsStarts != rhsStarts { return lhsStarts }
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }.prefix(6))
        }
        let sectionRows: [(PRSectionID, [PullRequest])] = [
            (.authored, pinnedAuthored + groupedAuthored.flatMap { $0.1 }),
            (.reviewRequests, pinnedReviews + groupedReviews.flatMap { $0.1 }),
            (.mentioned, groupedMentioned.flatMap { $0.1 }),
            (.directMentions, groupedDirectMentions.flatMap { $0.1 }),
            (.mergedToday, groupedMerged.flatMap { $0.1 })
        ]
        var rowsByID: [PRPanelRowID: PullRequest] = [:]
        var rowIDsBySection: [PRSectionID: [PRPanelRowID]] = [:]
        for (section, prs) in sectionRows {
            rowIDsBySection[section] = prs.map { PRPanelRowID(section: section, prID: $0.id) }
            for pr in prs { rowsByID[PRPanelRowID(section: section, prID: pr.id)] = pr }
        }
        return PRPanelProjection(
            filteredPRs: filtered, authoredPRs: authored,
            pinnedAuthoredPRs: pinnedAuthored, unpinnedAuthoredPRs: unpinnedAuthored,
            reviewRequestPRs: reviews, pinnedReviewRequestPRs: pinnedReviews, unpinnedReviewRequestPRs: unpinnedReviews,
            mentionedPRs: mentioned, directMentionPRs: directMentions, mergedLast24hPRs: merged,
            groupedAuthoredPRs: groupedAuthored, groupedReviewPRs: groupedReviews,
            groupedMentionedPRs: groupedMentioned, groupedDirectMentionPRs: groupedDirectMentions,
            groupedMergedLast24hPRs: groupedMerged,
            summaryReadyToMerge: authored.filter { $0.meetsReadyToMergeCriteria(minimumApprovals: configuration.minimumApprovalsForReadyToMerge) }.count,
            summaryChangesRequested: authored.filter { ($0.changesRequestedCount ?? 0) > 0 }.count,
            summaryCIFailing: filtered.filter { $0.ciStatus == .failure || $0.ciStatus == .unknown }.count,
            summaryCIRunning: filtered.filter { $0.ciIsRunning }.count,
            summaryWaitingForMyReview: reviews.filter { $0.myReviewStatus == .waiting }.count,
            sourcePRs: source, facetChips: chips, facetOptions: options, searchLabelSuggestions: labelSuggestions,
            nextMergedExpiry: nextMergedExpiry,
            rowsByID: rowsByID, rowIDsBySection: rowIDsBySection
        )
    }
}

/// Reuses materialized rows until a source revision or the rolling merged window changes.
struct PRPanelProjectionCache {
    private var cached: (revision: UInt64, materializedAt: Date, projection: PRPanelProjection)?
    private(set) var publicationGeneration: UInt64 = 0

    mutating func projection(
        revision: UInt64,
        now: Date,
        make: (Date) -> PRPanelProjection
    ) -> PRPanelProjection {
        if let cached, cached.revision == revision, now >= cached.materializedAt,
           cached.projection.nextMergedExpiry.map({ now <= $0 }) ?? true {
            return cached.projection
        }
        let projection = make(now)
        cached = (revision, now, projection)
        publicationGeneration &+= 1
        return projection
    }
}

struct PRRowExtensionState {
    var runnableSkills: [SkillDefinition] = []
    var extensionRun: SkillRun?
    var extensionAnalysis: CIAnalysis?
    var extensionTags: Set<PRTag> = []
}

struct PRPanelSnapshot {
    var prList: PRList
    var projection: PRPanelProjection
    var rateLimitInfo: RateLimitInfo
    var restRateLimitInfo: RateLimitInfo
    var configuration: Configuration
    var jiraConnectionState: JiraConnectionState
    var pinnedIdentifiers: Set<String>
    var activeFacetSelections: [FacetFieldID: Set<String>]
    var activityReminderCount: Int
    var openingPRIDs: Set<Int>
    var updatingBranchPRIDs: Set<Int>
    var loadingHoverDetailPRIDs: Set<Int>
    var facetChips: [FacetChip]
    var facetOptions: [FacetFieldID: [FacetOption]]
    var labelSuggestions: [FacetOption]
    var savedViews: [SavedView]
    var now: Date
    var rowExtensions: [Int: PRRowExtensionState] = [:]
    var actionError: String?
    var presentationRevision: UInt64 = 0
}

enum PRPanelActionError: Error, Equatable {
    case unavailable
    case changedRevision

    var message: String {
        switch self {
        case .unavailable: return "PR no longer available"
        case .changedRevision: return "PR changed. Reopen the menu and try again."
        }
    }
}

enum PRPanelActionResolver {
    static func latestPR(id: Int, in list: PRList) -> PullRequest? {
        list.pullRequests.first { $0.id == id }
            ?? list.mentionedPullRequests.first { $0.id == id }
            ?? list.directMentionPullRequests.first { $0.id == id }
            ?? list.mergedPullRequests.first { $0.id == id }
    }

    static func jiraIssueKey(requested: String, for pr: PullRequest) -> String? {
        guard let current = pr.jiraTicket,
              current.caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
            return nil
        }
        return current
    }

    static func resolve(
        id: Int, capturedHeadCommitOID: String?, requiresUnchangedHead: Bool, in list: PRList
    ) -> Result<PullRequest, PRPanelActionError> {
        guard let pr = latestPR(id: id, in: list) else { return .failure(.unavailable) }
        guard !requiresUnchangedHead || pr.headCommitOid == capturedHeadCommitOID else {
            return .failure(.changedRevision)
        }
        return .success(pr)
    }
}

struct PRRowActions {
    var onOpen: () -> Void
    var onOpenJira: (String) -> Void
    var onCopyURL: () -> Void
    var onMarkReviewCommentsRead: (() -> Void)?
    var onMarkReviewCommentsUnread: (() -> Void)?
    var onRerunFailedCI: (() -> Void)?
    var onUpdateBranchWithRebase: (() -> Void)?
    var onLoadHoverDetail: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onAnalyzeCIFailure: (() -> Void)?
    var onOpenRawDiagnostics: (() -> Void)?
    var onRunSkill: ((String) -> Void)?
    var onInstallBrowserUserscript: (() -> Void)?
    var onOpenBrowserIntegrationSettings: (() -> Void)?
    var showDetails: (() -> Void)?
}

struct PRPanelActions {
    var refresh: () -> Void
    var openActivity: () -> Void
    var openSettings: () -> Void
    var rowActions: (Int) -> PRRowActions
    var toggleFacet: (FacetFieldID, String) -> Void
    var clearFacetField: (FacetFieldID) -> Void
    var clearAllFacets: () -> Void
    var selectLabelSuggestion: (FacetOption) -> Void
    var saveCurrentView: (String) -> SavedView?
    var applySavedView: (SavedView) -> Void
    var renameSavedView: (SavedView, String) -> Void
    var deleteSavedView: (SavedView) -> Void
    var dismissActionError: () -> Void
}
