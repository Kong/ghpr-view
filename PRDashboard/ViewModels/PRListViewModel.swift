import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "PRListViewModel")

/// Parses and matches PR search queries. Shared between the ViewModel (filtering)
/// and PRRowView (highlight rendering) so a `jira:` scope and a typed term are
/// interpreted identically in both places.
enum PRSearchScope {
    static let jiraPrefix = "jira:"
    static let ciPrefix = "ci:"
    static let prPrefix = "pr:"
    static let approvalPrefix = "approval:"

    enum Kind {
        case all
        case jira
        case ci
        case pr
        case approval
    }

    struct Parsed {
        let kind: Kind
        /// Trimmed, original-case term (may be empty when the user typed only the scope prefix).
        let term: String
    }

    struct Suggestion: Equatable, Identifiable {
        let title: String
        let query: String
        let systemImage: String

        var id: String { query }
    }

    private struct EnumValueSuggestion {
        let value: String
        let systemImage: String
    }

    private enum CIValue: String, CaseIterable {
        case pass
        case failure
        case running

        var suggestion: EnumValueSuggestion {
            switch self {
            case .pass:
                return EnumValueSuggestion(value: rawValue, systemImage: "checkmark.circle")
            case .failure:
                return EnumValueSuggestion(value: rawValue, systemImage: "xmark.circle")
            case .running:
                return EnumValueSuggestion(value: rawValue, systemImage: "clock")
            }
        }
    }

    private enum PRValue: String, CaseIterable {
        case conflict

        var suggestion: EnumValueSuggestion {
            switch self {
            case .conflict:
                return EnumValueSuggestion(value: rawValue, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private enum EnumSuggestionScope: CaseIterable {
        case ci
        case pr

        var prefix: String {
            switch self {
            case .ci:
                return PRSearchScope.ciPrefix
            case .pr:
                return PRSearchScope.prPrefix
            }
        }

        var values: [EnumValueSuggestion] {
            switch self {
            case .ci:
                return CIValue.allCases.map(\.suggestion)
            case .pr:
                return PRValue.allCases.map(\.suggestion)
            }
        }
    }

    static func parse(_ rawSearchText: String) -> Parsed {
        let trimmed = rawSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(jiraPrefix) {
            let term = String(trimmed.dropFirst(jiraPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .jira, term: term)
        }
        if trimmed.lowercased().hasPrefix(ciPrefix) {
            let term = String(trimmed.dropFirst(ciPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .ci, term: term)
        }
        if trimmed.lowercased().hasPrefix(prPrefix) {
            let term = String(trimmed.dropFirst(prPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .pr, term: term)
        }
        if trimmed.lowercased().hasPrefix(approvalPrefix) {
            let term = String(trimmed.dropFirst(approvalPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .approval, term: term)
        }
        return Parsed(kind: .all, term: trimmed)
    }

    static func suggestions(for rawSearchText: String) -> [Suggestion] {
        let trimmed = rawSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard let scope = EnumSuggestionScope.allCases.first(where: { lowered.hasPrefix($0.prefix) }) else {
            return []
        }

        let typedValue = String(lowered.dropFirst(scope.prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = "\(scope.prefix)\(typedValue)"

        let matches = scope.values.filter { typedValue.isEmpty || $0.value.hasPrefix(typedValue) }
        let values = matches.isEmpty && validationMessage(for: rawSearchText) != nil ? scope.values : matches
        return values
            .map { value in
                Suggestion(
                    title: value.value,
                    query: "\(scope.prefix)\(value.value)",
                    systemImage: value.systemImage
                )
            }
            .filter { suggestion in
                suggestion.query != normalizedQuery
            }
    }

    enum CIFilter {
        case any, pass, failure, running
    }

    static func ciFilter(_ term: String) -> CIFilter? {
        switch term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "any", "value": return .any
        case "pass", "passed", "success", "green": return .pass
        case "failure", "fail", "failed", "failing", "red": return .failure
        case "running", "pending", "inflight", "in-flight": return .running
        default: return nil
        }
    }

    static func isConflictFilter(_ term: String) -> Bool {
        ["conflict", "conflicts"].contains(term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    struct ApprovalFilter {
        let operation: String
        let expected: Int

        func matches(_ count: Int) -> Bool {
            switch operation {
            case ">=": return count >= expected
            case ">": return count > expected
            case "<=": return count <= expected
            case "<": return count < expected
            default: return count == expected
            }
        }
    }

    static func approvalFilter(_ term: String) -> ApprovalFilter? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ApprovalFilter(operation: ">", expected: 0) }
        let operation = [">=", "<=", "==", ">", "<", "="].first { trimmed.hasPrefix($0) }
        let number = String(trimmed.dropFirst(operation?.count ?? 0))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = Int(number) else { return nil }
        return ApprovalFilter(operation: operation ?? "=", expected: expected)
    }

    static func validationMessage(for query: String) -> String? {
        let parsed = parse(query)
        switch parsed.kind {
        case .ci where ciFilter(parsed.term) == nil:
            return "Unknown CI filter"
        case .pr where parsed.term.isEmpty:
            return "Use pr:conflict"
        case .pr where !isConflictFilter(parsed.term):
            return "Unknown PR filter"
        case .approval where approvalFilter(parsed.term) == nil:
            return "Use approval:<number> or a comparison such as approval:>=2"
        default:
            return nil
        }
    }

    static func contains(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        return text.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

enum JiraIssueOpenDecision: Equatable {
    case open(URL)
    case confirmSetup(issueKey: String)
    case confirmReconnect(issueKey: String)

    static func resolve(
        state: JiraConnectionState,
        serverURL: String,
        issueKey: String
    ) -> JiraIssueOpenDecision {
        let key = issueKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .unauthorized:
            return .confirmReconnect(issueKey: key)
        case .notConfigured:
            return .confirmSetup(issueKey: key)
        case .configured:
            guard let url = JiraAPIClient.issueURL(serverURL: serverURL, issueKey: key),
                  JiraAPIClient.isSupportedCloudServerURL(serverURL) else {
                return .confirmSetup(issueKey: key)
            }
            return .open(url)
        }
    }
}

enum JiraPrompt: Identifiable, Equatable {
    case setup(issueKey: String)
    case reconnect(issueKey: String)

    var id: String {
        switch self {
        case .setup(let key): return "setup-\(key)"
        case .reconnect(let key): return "reconnect-\(key)"
        }
    }
}

struct MenuTrackingUpdateBuffer<Value> {
    private var isTracking = false
    private var pendingValue: Value?

    mutating func setTracking(_ newValue: Bool) -> Value? {
        guard newValue != isTracking else { return nil }
        isTracking = newValue
        guard !newValue else { return nil }

        defer { pendingValue = nil }
        return pendingValue
    }

    mutating func receive(_ value: Value) -> Value? {
        guard isTracking else { return value }
        pendingValue = value
        return nil
    }
}

@MainActor
final class PRListViewModel: ObservableObject {
    @Published var prList: PRList = .empty { didSet { invalidatePresentation() } }
    @Published var searchText: String = "" { didSet { invalidatePresentation() } }
    @Published private(set) var activeFacetSelections: [FacetFieldID: Set<String>] = [:] { didSet { invalidatePresentation() } }
    @Published private(set) var savedViews: [SavedView] { didSet { invalidateSnapshot() } }
    @Published var isFacetPanelPresented = false
    @Published private(set) var authState: AuthState = .empty
    @Published private(set) var pinnedPRIdentifiers: Set<String> = [] { didSet { invalidatePresentation() } }
    @Published private(set) var deviceCode: DeviceCodeInfo?
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authError: Error?
    @Published private(set) var isValidatingPAT: Bool = false
    @Published private(set) var patError: Error?
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty { didSet { invalidateSnapshot() } }
    @Published private(set) var restRateLimitInfo: RateLimitInfo = .empty { didSet { invalidateSnapshot() } }
    @Published private(set) var openingPRIDs: Set<Int> = [] { didSet { invalidateSnapshot() } }
    @Published private(set) var updatingBranchPRIDs: Set<Int> = [] { didSet { invalidateSnapshot() } }
    @Published private(set) var loadingHoverDetailPRIDs: Set<Int> = [] { didSet { invalidateSnapshot() } }
    @Published private(set) var jiraConnectionState: JiraConnectionState = .notConfigured { didSet { invalidateSnapshot() } }
    @Published var jiraPrompt: JiraPrompt?
    @Published private(set) var jiraCredentialRevision: Int = 0
    /// Local activity monitor state: open action items, coverage, delivery receipts.
    @Published private(set) var activity: PRActivitySnapshot = .idle { didSet { invalidateSnapshot() } }

    private let prManager: PRManager
    private let oauthManager: GitHubOAuthManager
    private let linkOpener: PRLinkOpening
    private let jiraURLOpener: (URL) -> Void
    private let savedViewStore: SavedViewStore
    private var cancellables = Set<AnyCancellable>()
    private let menuTracker: MenuTracker
    private var prListUpdateBuffer = MenuTrackingUpdateBuffer<PRList>()
    private var rateLimitUpdateBuffer = MenuTrackingUpdateBuffer<RateLimitInfo>()
    private var restRateLimitUpdateBuffer = MenuTrackingUpdateBuffer<RateLimitInfo>()

    private(set) var presentationRevision: UInt64 = 0
    private(set) var snapshotRevision: UInt64 = 0
    private var projectionCache = PRPanelProjectionCache()
    /// Read after materializing panelProjection so clock expiry is included in delivery.
    var panelPublicationRevision: UInt64 { snapshotRevision &+ projectionCache.publicationGeneration }
    @Published private var presentationConfiguration: Configuration

    private func invalidateSnapshot() {
        snapshotRevision &+= 1
    }

    private func invalidatePresentation() {
        presentationRevision &+= 1
        invalidateSnapshot()
    }

    var panelProjection: PRPanelProjection {
        projectionCache.projection(revision: presentationRevision, now: Date()) { now in
            PRPanelProjection.make(
                prList: prList, searchText: searchText, selections: activeFacetSelections,
                pinnedIdentifiers: pinnedPRIdentifiers, configuration: presentationConfiguration, now: now
            )
        }
    }

    /// Uses live manager facts even while menu tracking buffers visible publication.
    func latestPR(id: Int) -> PullRequest? {
        PRPanelActionResolver.latestPR(id: id, in: prManager.prList)
    }

    func resolvePRAction(
        id: Int, capturedHeadCommitOID: String?, requiresUnchangedHead: Bool
    ) -> Result<PullRequest, PRPanelActionError> {
        PRPanelActionResolver.resolve(
            id: id, capturedHeadCommitOID: capturedHeadCommitOID,
            requiresUnchangedHead: requiresUnchangedHead, in: prManager.prList
        )
    }

    var isJiraConfigured: Bool { jiraConnectionState == .configured }
    var openSettings: (() -> Void)?
    var openActivity: (() -> Void)?
    init(
        prManager: PRManager,
        oauthManager: GitHubOAuthManager,
        linkOpener: PRLinkOpening,
        menuTracker: MenuTracker = .shared,
        jiraURLOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        savedViewStore: SavedViewStore = SavedViewStore()
    ) {
        self.prManager = prManager
        self.presentationConfiguration = prManager.configuration
        self.oauthManager = oauthManager
        self.linkOpener = linkOpener
        self.menuTracker = menuTracker
        self.jiraURLOpener = jiraURLOpener
        self.savedViewStore = savedViewStore
        self.savedViews = savedViewStore.views
        setupBindings()
    }

    private func setupBindings() {
        prManager.$configuration
            .sink { [weak self] configuration in
                guard let self else { return }
                self.presentationConfiguration = configuration
                self.invalidatePresentation()
            }
            .store(in: &cancellables)

        // SwiftUI rebuilds an active context menu when its observed row tree changes.
        // Keep refresh publications stable until the complete menu hierarchy closes.
        menuTracker.$isTracking
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTracking in
                guard let self else { return }
                if let pendingPRList = self.prListUpdateBuffer.setTracking(isTracking) {
                    self.prList = pendingPRList
                }
                if let pendingRateLimit = self.rateLimitUpdateBuffer.setTracking(isTracking) {
                    self.rateLimitInfo = pendingRateLimit
                }
                if let pendingRestRateLimit = self.restRateLimitUpdateBuffer.setTracking(isTracking) {
                    self.restRateLimitInfo = pendingRestRateLimit
                }
            }
            .store(in: &cancellables)

        prManager.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                guard let self,
                      let visiblePRList = self.prListUpdateBuffer.receive(prList) else {
                    return
                }
                self.prList = visiblePRList
            }
            .store(in: &cancellables)

        prManager.activityMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.activity = snapshot
            }
            .store(in: &cancellables)

        prManager.$rateLimitInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self,
                      let visibleInfo = self.rateLimitUpdateBuffer.receive(info) else {
                    return
                }
                self.rateLimitInfo = visibleInfo
            }
            .store(in: &cancellables)
        prManager.$restRateLimitInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self,
                      let visibleInfo = self.restRateLimitUpdateBuffer.receive(info) else {
                    return
                }
                self.restRateLimitInfo = visibleInfo
            }
            .store(in: &cancellables)

        // Bind auth state
        oauthManager.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authState in
                self?.authState = authState
            }
            .store(in: &cancellables)

        // Bind device code
        oauthManager.$deviceCode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceCode in
                self?.deviceCode = deviceCode
            }
            .store(in: &cancellables)

        // Bind authenticating state
        oauthManager.$isAuthenticating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthenticating in
                self?.isAuthenticating = isAuthenticating
            }
            .store(in: &cancellables)

        // Bind auth error
        oauthManager.$authError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authError in
                self?.authError = authError
            }
            .store(in: &cancellables)

        // Bind PAT validating state
        oauthManager.$isValidatingPAT
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isValidating in
                self?.isValidatingPAT = isValidating
            }
            .store(in: &cancellables)

        // Bind PAT error
        oauthManager.$patError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.patError = error
            }
            .store(in: &cancellables)

        // Keep pin-related manager updates synchronous on the main actor so rows
        // can move sections immediately after a context-menu action.
        prManager.$pinnedPRIdentifiers
            .sink { [weak self] identifiers in
                self?.pinnedPRIdentifiers = identifiers
            }
            .store(in: &cancellables)

        prManager.$updatingBranchPRIDs
            .removeDuplicates()
            .sink { [weak self] updatingIDs in
                self?.updatingBranchPRIDs = updatingIDs
            }
            .store(in: &cancellables)

        prManager.$loadingHoverDetailPRIDs
            .removeDuplicates()
            .sink { [weak self] loadingIDs in
                self?.loadingHoverDetailPRIDs = loadingIDs
            }
            .store(in: &cancellables)

        prManager.$jiraConnectionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.jiraConnectionState = state
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    var filteredPRs: [PullRequest] { panelProjection.filteredPRs }
    var authoredPRs: [PullRequest] { panelProjection.authoredPRs }
    var pinnedAuthoredPRs: [PullRequest] { panelProjection.pinnedAuthoredPRs }
    var unpinnedAuthoredPRs: [PullRequest] { panelProjection.unpinnedAuthoredPRs }
    var reviewRequestPRs: [PullRequest] { panelProjection.reviewRequestPRs }
    var pinnedReviewRequestPRs: [PullRequest] { panelProjection.pinnedReviewRequestPRs }
    var unpinnedReviewRequestPRs: [PullRequest] { panelProjection.unpinnedReviewRequestPRs }
    var mentionedPRs: [PullRequest] { panelProjection.mentionedPRs }
    var directMentionPRs: [PullRequest] { panelProjection.directMentionPRs }
    var groupedAuthoredPRs: [(String, [PullRequest])] { panelProjection.groupedAuthoredPRs }
    var groupedReviewPRs: [(String, [PullRequest])] { panelProjection.groupedReviewPRs }
    var groupedMentionedPRs: [(String, [PullRequest])] { panelProjection.groupedMentionedPRs }
    var groupedDirectMentionPRs: [(String, [PullRequest])] { panelProjection.groupedDirectMentionPRs }
    var mergedLast24hPRs: [PullRequest] { panelProjection.mergedLast24hPRs }
    var groupedMergedLast24hPRs: [(String, [PullRequest])] { panelProjection.groupedMergedLast24hPRs }
    var summaryReadyToMerge: Int { panelProjection.summaryReadyToMerge }
    var summaryChangesRequested: Int { panelProjection.summaryChangesRequested }
    var summaryCIFailing: Int { panelProjection.summaryCIFailing }
    var summaryCIRunning: Int { panelProjection.summaryCIRunning }
    var sourcePRs: [PullRequest] { panelProjection.sourcePRs }
    var facetChips: [FacetChip] { panelProjection.facetChips }
    var searchLabelSuggestions: [FacetOption] { panelProjection.searchLabelSuggestions }

    func selectLabelSuggestion(_ option: FacetOption) {
        guard option.field == .githubLabel || option.field == .jiraLabel else { return }
        toggleFacet(field: option.field, key: option.key)
        searchText = ""
    }


    func facetOptions(for field: FacetFieldID) -> [FacetOption] {
        panelProjection.facetOptions[field] ?? []
    }

    func toggleFacet(field: FacetFieldID, key: String) {
        var updated = activeFacetSelections
        var keys = updated[field] ?? []
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        if keys.isEmpty { updated.removeValue(forKey: field) } else { updated[field] = keys }
        activeFacetSelections = updated
    }

    func clearFacetField(_ field: FacetFieldID) {
        var updated = activeFacetSelections
        updated.removeValue(forKey: field)
        activeFacetSelections = updated
    }

    func clearAllFacets() { activeFacetSelections = [:] }

    @discardableResult
    func saveCurrentView(name: String) -> SavedView? {
        guard let view = savedViewStore.create(
            name: name,
            selections: activeFacetSelections.map {
                ActiveFacetSelection(field: $0.key, selectedKeys: $0.value)
            },
            searchText: searchText
        ) else {
            return nil
        }
        savedViews = savedViewStore.views
        return view
    }

    func applySavedView(_ view: SavedView) {
        searchText = view.searchText
        var restored: [FacetFieldID: Set<String>] = [:]
        for selection in view.selections {
            restored[selection.field, default: []].formUnion(selection.selectedKeys)
        }
        activeFacetSelections = restored
    }

    func renameSavedView(_ view: SavedView, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = view
        updated.name = trimmed
        savedViewStore.update(updated)
        savedViews = savedViewStore.views
    }

    func deleteSavedView(_ view: SavedView) {
        savedViewStore.delete(view)
        savedViews = savedViewStore.views
    }

    var summaryWaitingForMyReview: Int { panelProjection.summaryWaitingForMyReview }


    var totalUnresolvedCount: Int {
        prList.totalUnresolvedCount
    }

    var lastUpdatedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: prList.lastUpdated, relativeTo: Date())
    }

    var isLoading: Bool {
        prList.isLoading
    }

    var error: Error? {
        prList.error
    }

    var configuration: Configuration {
        get { prManager.configuration }
        set { prManager.updateConfiguration(newValue) }
    }

    var hasAnyJiraTicket: Bool {
        let lists = [
            prList.pullRequests,
            prList.mentionedPullRequests,
            prList.directMentionPullRequests,
            prList.mergedPullRequests
        ]
        for list in lists {
            if list.contains(where: { $0.jiraTicket?.isEmpty == false }) {
                return true
            }
        }
        return false
    }

    func updateJiraCredentials(
        serverURL: String,
        email: String,
        apiToken: String,
        refreshInterval: TimeInterval
    ) {
        prManager.updateJiraCredentials(
            serverURL: serverURL,
            email: email,
            apiToken: apiToken,
            refreshInterval: refreshInterval
        )
        jiraCredentialRevision += 1
    }


    func openJiraIssue(_ issueKey: String) {
        let decision = JiraIssueOpenDecision.resolve(
            state: jiraConnectionState,
            serverURL: prManager.configuration.jiraServerURL,
            issueKey: issueKey
        )
        switch decision {
        case .open(let url):
            jiraURLOpener(url)
        case .confirmSetup(let key):
            jiraPrompt = .setup(issueKey: key)
        case .confirmReconnect(let key):
            jiraPrompt = .reconnect(issueKey: key)
        }
    }

    // MARK: - Actions

    func refresh() {
        prManager.refresh()
    }

    func clearCaches() {
        prManager.clearDirectMentionTracking()
        PRCache.shared.clear()
        PRDetailCache.shared.clear()
        AvatarCache.shared.clear()
        JiraMetadataCache.shared.clear()
        prManager.refresh()
    }

    func showSettings() {
        openSettings?()
    }

    func openPR(_ pr: PullRequest) {
        guard linkOpener.opensAtCmuxFirst else {
            Task { @MainActor [linkOpener] in
                await linkOpener.open(pr.url)
            }
            return
        }

        guard !openingPRIDs.contains(pr.id) else { return }
        markOpeningPR(pr.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearOpeningPR(pr.id) }
            await self.linkOpener.open(pr.url)
        }
    }

    func openPRChecks(_ pr: PullRequest) {
        let checksURL = pr.url.appendingPathComponent("checks")
        Task { @MainActor [linkOpener] in
            await linkOpener.open(checksURL)
        }
    }

    func copyURL(_ pr: PullRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
    }

    func signIn() {
        oauthManager.signIn()
    }

    func signOut() {
        oauthManager.signOut()
    }

    func cancelSignIn() {
        oauthManager.cancelSignIn()
    }

    func openVerificationURL() {
        oauthManager.openVerificationURL()
    }

    func copyUserCode() {
        oauthManager.copyUserCode()
    }

    func signInWithPAT(_ token: String) {
        Task {
            await oauthManager.signInWithPAT(token)
        }
    }

    func clearPATError() {
        oauthManager.clearPATError()
    }

    func isPinned(_ pr: PullRequest) -> Bool {
        pinnedPRIdentifiers.contains(pr.pinIdentifier)
    }

    func isOpeningPR(_ pr: PullRequest) -> Bool {
        openingPRIDs.contains(pr.id)
    }

    func isUpdatingBranch(_ pr: PullRequest) -> Bool {
        updatingBranchPRIDs.contains(pr.id)
    }

    func isLoadingHoverDetail(_ pr: PullRequest) -> Bool {
        loadingHoverDetailPRIDs.contains(pr.id)
    }

    func togglePin(_ pr: PullRequest) {
        let identifier = pr.pinIdentifier
        prManager.togglePinPR(identifier)
        pinnedPRIdentifiers = prManager.pinnedPRIdentifiers
        logger.info("Pin toggled: \(identifier) → pinned=\(self.pinnedPRIdentifiers.contains(identifier)), total=\(self.pinnedPRIdentifiers.count)")
    }

    // MARK: - Activity monitor

    func showActivity() {
        openActivity?()
    }

    func activityEvents(forPR prNodeID: String, limit: Int = 5) -> [PRActivityEvent] {
        prManager.activityMonitor.events(forPR: prNodeID, limit: limit)
    }

    func refreshActivity() {
        prManager.activityMonitor.refreshNow()
    }

    /// Items grouped per monitored PR, newest activity first.
    var activityItemsByPR: [(pr: MonitoredPR, items: [PRActionItem])] {
        let items = activity.actionItems.filter { $0.isActionable(now: Date()) }
        let grouped = Dictionary(grouping: items, by: \.prNodeID)
        return grouped
            .compactMap { nodeID, items -> (MonitoredPR, [PRActionItem])? in
                guard let pr = activity.pr(nodeID) else { return nil }
                guard configuration.collectsActivity(
                    for: pr.reference.repoFullName,
                    explicitlyTracked: pr.isExplicitlyTracked
                ) else { return nil }
                return (pr, items.sorted { $0.stateUpdatedAt > $1.stateUpdatedAt })
            }
            .sorted { lhs, rhs in
                PullRequestReference.ordered(lhs.0.reference, rhs.0.reference, newestFirst: true)
            }
    }

    var actionableActivityCount: Int {
        activityItemsByPR.reduce(0) { count, group in
            count + PRActivityEngine.reminders(from: group.items).count
        }
    }

    func markActivityHandled(_ item: PRActionItem) {
        markActivityHandled([item.id])
    }

    func markActivityHandled(_ itemIDs: [String]) {
        prManager.activityMonitor.markHandled(itemIDs: itemIDs)
    }

    func snoozeActivity(_ item: PRActionItem, until: Date) {
        snoozeActivity([item.id], until: until)
    }

    func snoozeActivity(_ itemIDs: [String], until: Date) {
        prManager.activityMonitor.snooze(itemIDs: itemIDs, until: until)
    }

    func reopenActivity(_ item: PRActionItem) {
        prManager.activityMonitor.reopen(itemID: item.id)
    }

    func setActivityTracking(_ pr: MonitoredPR, tracked: Bool, eventKinds: Set<PRActivityEventKind>? = nil) {
        if tracked {
            prManager.activityMonitor.setExplicitTracking(prNodeID: pr.prNodeID, eventKinds: eventKinds)
        } else {
            prManager.activityMonitor.stopTracking(prNodeID: pr.prNodeID)
        }
    }

    func isActivityMuted(_ pr: MonitoredPR) -> Bool {
        prManager.isPRMuted(reference: pr.reference)
    }

    func setActivityMuted(_ muted: Bool, pr: MonitoredPR) {
        prManager.setPRMuted(muted, reference: pr.reference)
    }

    func retryActivityDigest(_ batch: DigestBatch) {
        prManager.activityMonitor.retryDigestBatch(id: batch.id)
    }

    func markReviewCommentsRead(_ pr: PullRequest) {
        prManager.markReviewCommentsRead(for: pr)
    }

    func markReviewCommentsUnread(_ pr: PullRequest) {
        prManager.markReviewCommentsUnread(for: pr)
    }

    func rerunFailedCI(_ pr: PullRequest) {
        Task {
            do {
                let result = try await prManager.rerunFailedCI(for: pr)
                if !result.failures.isEmpty {
                    logger.error("\(result.failures.joined(separator: "; "))")
                }
                logger.info("Re-triggered \(result.rerunCount) failed workflow(s) for PR #\(pr.number)")
            } catch {
                logger.error("Failed to rerun CI for PR #\(pr.number): \(error.localizedDescription)")
            }
        }
    }

    func updateBranchWithRebase(_ pr: PullRequest) {
        Task {
            do {
                try await prManager.updateBranchWithRebase(for: pr)
                logger.info("Requested branch rebase update for PR #\(pr.number)")
            } catch {
                logger.error("Failed to update branch for PR #\(pr.number): \(error.localizedDescription)")
            }
        }
    }

    func loadHoverDetailIfNeeded(_ pr: PullRequest) {
        prManager.loadHoverDetailIfNeeded(for: pr)
    }

    // MARK: - Private

    private func markOpeningPR(_ id: Int) {
        var updated = openingPRIDs
        updated.insert(id)
        openingPRIDs = updated
    }

    private func clearOpeningPR(_ id: Int) {
        var updated = openingPRIDs
        updated.remove(id)
        openingPRIDs = updated
    }

}
