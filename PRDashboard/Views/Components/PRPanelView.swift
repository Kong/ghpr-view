import AppKit
import SwiftUI

struct PRPanelView: View {
    let snapshot: PRPanelSnapshot
    let actions: PRPanelActions
    @Binding var searchText: String
    @Binding var isFacetPanelPresented: Bool
    @ObservedObject var interaction: PanelInteractionCoordinator
    var onboardingManager: OnboardingManager? = nil
    var searchFocusRequest: UInt64 = 0
    var onSearchCompositionChanged: (Bool) -> Void = { _ in }
    var onSearchEscape: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showSyncDetails = false
    @StateObject private var tooltipPresenter = HoverTooltipPresenter()
    @State private var firstVisibleApprovalPRID: Int?
    @State private var firstVisibleReviewStatusPRID: Int?
    @State private var showSaveViewSheet = false
    @State private var savedViewName = ""
    // AppKit/SwiftUI focus binding mirrors the coordinator's authoritative target.
    @FocusState private var nativeControlFocus: PanelFocusTarget?

    private var layoutSnapshot: PRPanelSnapshot { interaction.displayedSnapshot ?? snapshot }
    private var layoutProjection: PRPanelProjection { interaction.displayedStructure ?? layoutSnapshot.projection }

    private var searchSuggestions: [PRSearchScope.Suggestion] {
        PRSearchScope.suggestions(for: interaction.displayedSearchText)
    }
    var body: some View {
        VStack(spacing: 0) {
            let snapshot = layoutSnapshot
            Group {
                // Header
                headerView
                if interaction.displayedFacetPanel {
                    FacetFilterPanel(facetOptions: snapshot.facetOptions, activeFacetSelections: snapshot.activeFacetSelections, savedViews: snapshot.savedViews, actions: actions) { showSaveViewSheet = true }
                }
                Divider()

                if snapshot.prList.isLoading && !snapshot.prList.hasUsableData {
                    // Loading state
                    loadingView
                } else if !snapshot.prList.hasUsableData, let error = snapshot.prList.error {
                    // Error state
                    errorView(error)
                } else if !snapshot.prList.hasUsableData {
                    // Empty state
                    emptyView
                } else {
                    // PR list
                    prListView
                }


                Divider()

                // Footer
                footerView
            }
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if contrast == .increased {
                Rectangle().stroke(Color.primary, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: HoverTooltipCoordinateSpace.name)
        .coordinateSpace(name: "panel-layout")
        .background(PanelWindowBinding(interaction: interaction))
        .onPreferenceChange(PanelGeometryPreferenceKey.self) { interaction.recordGeometrySamples($0) }
        .environment(\.hoverTooltipPresenter, tooltipPresenter)
        .environment(\.panelGeometryInteraction, interaction)
        .overlay(alignment: .topLeading) {
            HoverTooltipOverlay(presenter: tooltipPresenter)
        }
        .overlay(alignment: .bottom) {
            if let actionError = layoutSnapshot.actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(actionError).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(action: actions.dismissActionError) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss action error")
                }
                .font(.system(size: PanelMetrics.metadataSize))
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().stroke(Color.secondary, lineWidth: 1))
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.bottom, PanelMetrics.footerHeight + 4)
            }
        }
        .onAppear {
            configureInteraction()
            interaction.updateSearchText(searchText)
            interaction.updateFacetPanel(isFacetPanelPresented)
            interaction.receive(snapshot: snapshot, reason: .userIntent)
            syncOnboardingState()
        }
        .onChange(of: snapshot.presentationRevision) { _ in interaction.receive(snapshot: snapshot) }
        .onChange(of: searchText) { interaction.updateSearchText($0) }
        .onChange(of: isFacetPanelPresented) { interaction.updateFacetPanel($0) }
        .onChange(of: interaction.focusTarget) { target in
            switch target {
            case .section, .refresh: nativeControlFocus = target
            case .row:
                nativeControlFocus = nil
                DispatchQueue.main.async {
                    if interaction.isPresented { interaction.restoreRowFocus() }
                }
            case nil: nativeControlFocus = nil
            }
        }
        .onChange(of: interaction.isPresented) { presented in
            if !presented {
                tooltipPresenter.dismissAll()
                showSyncDetails = false
            }
        }
        .onChange(of: interaction.isWindowActive) { active in
            if !active { tooltipPresenter.dismissAll() }
        }
        .onDisappear { tooltipPresenter.dismissAll() }
        .onReceive(NotificationCenter.default.publisher(for: .panelFocusedDetailsDidClose)) { note in
            interaction.restoreRowFocus(origin: note.userInfo?["originRowID"] as? PRPanelRowID, in: note.object as? NSWindow)
        }
        .onChange(of: onboardingAvailableSteps) { _ in
            syncOnboardingState()
        }
        .onPreferenceChange(FirstApprovalBadgeIDPreferenceKey.self) { firstVisibleApprovalPRID = $0 }
        .sheet(isPresented: $showSaveViewSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Current Filters").font(.headline)
                TextField("View name", text: $savedViewName)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        savedViewName = ""
                        showSaveViewSheet = false
                    }
                    Button("Save") {
                        guard actions.saveCurrentView(savedViewName) != nil else { return }
                        savedViewName = ""
                        showSaveViewSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(savedViewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 280)
        }
        .onPreferenceChange(FirstReviewStatusBadgeIDPreferenceKey.self) { firstVisibleReviewStatusPRID = $0 }
    }
    // MARK: - Header

    private var headerView: some View {
        let snapshot = layoutSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PanelSearchField(
                    text: Binding(get: { searchText }, set: updateQuery),
                    focusRequest: searchFocusRequest &+ interaction.searchFocusRequest,
                    onCompositionChanged: { composing in
                        interaction.setInteraction(.composition, active: composing)
                        onSearchCompositionChanged(composing)
                    },
                    onEscape: { if let onSearchEscape { onSearchEscape() } else { interaction.escape() } }
                )
                .frame(maxWidth: .infinity)
                .frame(height: PanelMetrics.toolSize)

                Button {
                    isFacetPanelPresented.toggle()
                    interaction.updateFacetPanel(isFacetPanelPresented)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: PanelMetrics.symbolSize))
                        .frame(minWidth: PanelMetrics.toolSize, minHeight: PanelMetrics.toolSize)
                }
                .tint(isFacetPanelPresented ? .accentColor : nil)
                .panelToolButton()
                .help(isFacetPanelPresented ? "Close Filters" : "Filter")
                .accessibilityLabel("Filter")
                .accessibilityValue(isFacetPanelPresented ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("panel-filter")
                .panelOnboardingAnchor(onboardingManager, step: .filter)

                Button(action: actions.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: PanelMetrics.symbolSize))
                        .frame(minWidth: PanelMetrics.toolSize, minHeight: PanelMetrics.toolSize)
                }
                .panelToolButton()
                .keyboardShortcut("r", modifiers: .command)
                .disabled(snapshot.prList.isLoading)
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("panel-refresh")
                .focused($nativeControlFocus, equals: .refresh)
            }
            .frame(minHeight: PanelMetrics.toolbarHeight)

            if !searchSuggestions.isEmpty || !snapshot.labelSuggestions.isEmpty || !snapshot.facetChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(searchSuggestions) { suggestion in
                            Button { updateQuery(suggestion.query) } label: {
                                Label(suggestion.title, systemImage: suggestion.systemImage)
                            }
                            .buttonStyle(.borderless)
                            .help("Filter by \(suggestion.query)")
                        }
                        ForEach(snapshot.labelSuggestions) { option in
                            Button { actions.selectLabelSuggestion(option) } label: {
                                Label("\(option.displayName) · \(option.field.providerTitle) · \(option.count)", systemImage: option.field.symbolName)
                            }
                            .buttonStyle(.borderless)
                            .help("Filter by \(option.field.providerTitle) label \(option.displayName)")
                        }
                        ForEach(snapshot.facetChips) { chip in
                            Button { actions.toggleFacet(chip.field, chip.key) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: chip.field.symbolName)
                                    Text(chip.displayName)
                                    Image(systemName: "xmark")
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(chip.displayName) filter")
                        }
                    }
                    .font(.system(size: PanelMetrics.metadataSize))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.bottom, 8)
            }
            if let message = PRSearchScope.validationMessage(for: interaction.displayedSearchText) {
                Text(message)
                    .font(.system(size: PanelMetrics.metadataSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("panel-query-diagnostic")
                    .padding(.bottom, 6)
                    .opacity(interaction.isComposing ? 0 : 1)
                    .accessibilityHidden(interaction.isComposing)
            }
        }
        .padding(.horizontal, PanelMetrics.inset)
    }
    private var prListView: some View {
        let snapshot = layoutSnapshot
        let summary = interaction.latestSnapshot?.projection ?? snapshot.projection
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = snapshot.prList.error { staleDataBanner(error).panelGeometry(.error) }
                    PRSummaryView(
                        readyToMerge: summary.summaryReadyToMerge,
                        changesRequested: summary.summaryChangesRequested,
                        ciFailing: summary.summaryCIFailing,
                        ciRunning: summary.summaryCIRunning,
                        toReview: summary.summaryWaitingForMyReview
                    )
                    .frame(height: interaction.protectsLayout ? interaction.protectedGeometry[.summary]?.height : nil, alignment: .top)
                    .clipped()
                    .panelGeometry(.summary)
                    if PRSectionID.allCases.allSatisfy({ layoutProjection.displayedRowIDs(for: $0).isEmpty }) {
                        noMatchingPRs
                    }
                    ForEach(PRSectionID.allCases, id: \.self) { section in
                        let rows = layoutProjection.displayedRowIDs(for: section)
                        collapsibleSection(section, count: rows.count, onboardingStep: onboardingStep(for: section)) {
                            ForEach(rows, id: \.self) { id in
                                if let pr = layoutProjection.pr(for: id) {
                                    rowSlot(id, pr: pr)
                                        .id(PanelFocusTarget.row(id))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(PanelScrollViewBinding(interaction: interaction))
            }
            .panelGeometry(.list)
            .onHover { interaction.setPointerInsideList($0) }
            .onChange(of: interaction.commitRevision) { _ in
                DispatchQueue.main.async {
                    // Unchanged geometry produces no preference notification. Complete
                    // its zero-displacement restoration after this layout turn as well.
                    interaction.recordGeometry(interaction.geometry)
                }
            }
            .onPreferenceChange(PanelGeometryPreferenceKey.self) { frames in
                guard !interaction.protectsLayout, let target = interaction.pendingAnchorRestoration else { return }
                let key: PanelGeometryID
                switch target {
                case let .row(id): key = .row(id)
                case let .section(id): key = .section(id)
                case .refresh: return
                }
                // Realized anchors are corrected by exact clip-view displacement. A lazy
                // offscreen anchor needs materializing first, then the same correction.
                if frames[key] == nil { reader.scrollTo(target) }
            }
            .onChange(of: interaction.keyboardRevealRevision) { _ in
                guard !interaction.protectsLayout, let target = interaction.keyboardRevealTarget else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { reader.scrollTo(target) }
            }
        }
    }


    private var noMatchingPRs: some View {
        VStack(spacing: 8) {
            Text("No matching PRs").font(.headline)
            if !searchText.isEmpty { Button("Clear query") { updateQuery("") } }
            if !snapshot.activeFacetSelections.isEmpty { Button("Clear filters", action: actions.clearAllFacets) }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private func rowSlot(_ id: PRPanelRowID, pr: PullRequest) -> some View {
        let available = interaction.isAvailable(id)
        let displayedPR = interaction.renderedFact(for: id.prID, fallback: pr)
        return makeRow(id, pr: displayedPR)
            .environment(\.panelDisplayRowID, id)
            .disabled(!available)
            .allowsHitTesting(available)
            .frame(height: interaction.protectsLayout ? interaction.protectedGeometry[.row(id)]?.height : nil, alignment: .top)
            .clipped()
            .opacity(available ? 1 : 0)
            .accessibilityHidden(!available)
            .overlay {
                if !available {
                    Text("PR no longer available")
                        .font(.system(size: PanelMetrics.metadataSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("pr-unavailable-\(id.prID)")
                }
            }
            .overlay {
                if interaction.focusTarget == .row(id) {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .panelGeometry(.row(id))
    }

    private func configureInteraction() {
        interaction.onRefresh = {
            guard interaction.latestSnapshot?.prList.isLoading != true else { return }
            actions.refresh()
        }
        interaction.onOpenSettings = actions.openSettings
        interaction.onOpenRow = { actions.rowActions($0).onOpen() }
        interaction.searchIsEmpty = { searchText.isEmpty }
        interaction.onClearSearch = { updateQuery("") }
    }

    private func updateQuery(_ query: String) {
        searchText = query
        interaction.updateSearchText(query)
    }

    private func onboardingStep(for section: PRSectionID) -> OnboardingManager.Step? {
        switch section {
        case .authored: return .myPRs
        case .reviewRequests: return .reviewRequests
        case .mergedToday: return .mergedToday
        case .mentioned, .directMentions: return nil
        }
    }

    private func makeRow(_ id: PRPanelRowID, pr: PullRequest) -> PRRowView {
        let snapshot = layoutSnapshot
        let row = interaction.rowActions(for: id, factory: actions.rowActions)
        let extensions = snapshot.rowExtensions[id.prID] ?? PRRowExtensionState()
        let latest = interaction.latestFacts[id.prID] ?? pr
        let latestDescription = "\(latest.title), CI \(latest.ciStatus?.rawValue.lowercased() ?? "unavailable"), \(latest.unresolvedCount) unresolved threads, your review \(latest.myReviewStatus.map { String(describing: $0) } ?? "not requested")"
        let canPin = id.section == .authored || id.section == .reviewRequests
        return PRRowView(
            pr: pr,
            onOpen: row.onOpen,
            onOpenJira: row.onOpenJira,
            onCopyURL: row.onCopyURL,
            onMarkReviewCommentsRead: id.section == .authored ? row.onMarkReviewCommentsRead : nil,
            onMarkReviewCommentsUnread: id.section == .authored ? row.onMarkReviewCommentsUnread : nil,
            onRerunFailedCI: row.onRerunFailedCI,
            onUpdateBranchWithRebase: row.onUpdateBranchWithRebase,
            onLoadHoverDetail: row.onLoadHoverDetail,
            onTogglePin: canPin ? row.onTogglePin : nil,
            onAnalyzeCIFailure: row.onAnalyzeCIFailure,
            onOpenRawDiagnostics: row.onOpenRawDiagnostics,
            onRunSkill: row.onRunSkill,
            onInstallBrowserUserscript: row.onInstallBrowserUserscript,
            onOpenBrowserIntegrationSettings: row.onOpenBrowserIntegrationSettings,
            runnableSkills: extensions.runnableSkills,
            extensionRun: extensions.extensionRun,
            extensionAnalysis: extensions.extensionAnalysis,
            extensionTags: extensions.extensionTags,
            isPinned: canPin && snapshot.pinnedIdentifiers.contains(pr.pinIdentifier),
            isOpening: snapshot.openingPRIDs.contains(pr.id),
            isUpdatingBranch: snapshot.updatingBranchPRIDs.contains(pr.id),
            isLoadingHoverDetail: snapshot.loadingHoverDetailPRIDs.contains(pr.id),
            showCIStatus: id.section != .mergedToday,
            showConflictStatus: id.section != .mergedToday,
            showMyReviewStatus: snapshot.configuration.showMyReviewStatus,
            showCmuxStatus: snapshot.configuration.openAtCmuxFirst,
            jiraMetadataEnabled: snapshot.jiraConnectionState == .configured,
            searchText: interaction.displayedSearchText,
            onboardingManager: onboardingManager,
            approvalOnboardingPRID: firstVisibleApprovalPRID,
            reviewStatusOnboardingPRID: firstVisibleReviewStatusPRID,
            now: snapshot.now,
            latestFactsDescription: latestDescription
        )
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ section: PRSectionID,
        count: Int,
        onboardingStep: OnboardingManager.Step? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if count > 0 || interaction.focusTarget == .section(section) || interaction.scrollAnchor == .section(section) {
            sectionHeader(section, count: count, onboardingStep: onboardingStep)

            if isExpanded(section) {
                content()
                    .transition(.opacity)
            }
        }
    }

    private func sectionHeader(
        _ section: PRSectionID,
        count: Int,
        onboardingStep: OnboardingManager.Step? = nil
    ) -> some View {
        let expanded = isExpanded(section)
        let header = Button {
            toggleSection(section)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)

                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section == .mergedToday ? "Merged in the last 24 hours. \(expanded ? "Collapse section" : "Expand section")" : (expanded ? "Collapse section" : "Expand section"))
        .accessibilityLabel(Text(section.title))
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .focused($nativeControlFocus, equals: .section(section))
        .id(PanelFocusTarget.section(section))
        .panelGeometry(.section(section))
        .overlay {
            if interaction.focusTarget == .section(section) {
                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1).allowsHitTesting(false)
            }
        }

        return Group {
            if let onboardingStep {
                header.panelOnboardingAnchor(onboardingManager, step: onboardingStep)
            } else {
                header
            }
        }
    }

    private func isExpanded(_ section: PRSectionID) -> Bool {
        interaction.expandedSections.contains(section)
    }

    private func toggleSection(_ section: PRSectionID) {
        withAnimation(PanelMotion.disclosure(reduceMotion: reduceMotion)) {
            interaction.toggleSection(section)
        }
    }
    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            if !reduceMotion { ProgressView().controlSize(.small) }
            Text("Loading PRs…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            Text("Failed to load PRs")
                .font(.headline)

            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                actions.refresh()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func staleDataBanner(_ error: Error) -> some View {
        let snapshot = layoutSnapshot
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh failed")
                    .font(.system(size: 12, weight: .semibold))

                Text("Showing data updated \(formatRelativeTime(snapshot.prList.lastUpdated)).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(error.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Retry") {
                actions.refresh()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No pull requests")
                .font(.headline)

            Text("You have no open PRs or review requests")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Button { showSyncDetails.toggle() } label: {
                HStack(spacing: 4) {
                    if interaction.hasPendingOrder {
                        Text("List order pending")
                        if let error = snapshot.actionError { Image(systemName: "exclamationmark.triangle").help(error) }
                    } else if let error = snapshot.actionError, error != layoutSnapshot.actionError {
                        Text("Action needs attention").help(error)
                    } else if snapshot.prList.isLoading {
                        if !reduceMotion { ProgressView().controlSize(.mini) }
                        Text("Updating…")
                    } else if snapshot.rateLimitInfo.limit > 0 && snapshot.rateLimitInfo.isLow {
                        Image(systemName: "exclamationmark.triangle")
                        Text("API limited")
                        if snapshot.rateLimitInfo.resetDate > snapshot.now {
                            Text(snapshot.rateLimitInfo.resetDate, style: .time)
                        }
                    } else {
                        syncLabel(relativeTo: snapshot.now)
                    }
                    Image(systemName: "info.circle")
                }
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Synchronization and API details")
            .accessibilityLabel("Synchronization details")
            .accessibilityValue(interaction.hasPendingOrder ? "List order pending" : (snapshot.actionError ?? ""))
            .panelOnboardingAnchor(onboardingManager, step: .unresolvedComments, arrow: .top)
            .popover(isPresented: $showSyncDetails, arrowEdge: .top) { syncDetails }

            Spacer(minLength: 0)

            Button(action: actions.openActivity) {
                HStack(spacing: 3) {
                    Image(systemName: "tray.full")
                        .font(.system(size: PanelMetrics.symbolSize))
                    if interaction.activityReminderCountForLayout > 0 {
                        Text("\(interaction.activityReminderCountForLayout)").monospacedDigit()
                    }
                }
                .frame(minWidth: PanelMetrics.toolSize, minHeight: PanelMetrics.toolSize)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .delayedHoverTooltip(String(localized: "Activity reminders"))
            .accessibilityLabel("Activity")
            .accessibilityValue("\(snapshot.activityReminderCount) reminders")
            .accessibilityIdentifier("panel-activity")

            Button(action: actions.openSettings) {
                Image(systemName: "gear")
                    .font(.system(size: PanelMetrics.symbolSize))
                    .frame(minWidth: PanelMetrics.toolSize, minHeight: PanelMetrics.toolSize)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .delayedHoverTooltip(String(localized: "Settings"))
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("panel-settings")
            .panelOnboardingAnchor(onboardingManager, step: .repoFilter)
        }
        .font(.system(size: PanelMetrics.metadataSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PanelMetrics.inset)
        .frame(minHeight: PanelMetrics.footerHeight)
    }

    private func syncLabel(relativeTo now: Date) -> some View {
        Text("Updated \(Self.relativeDateFormatter.localizedString(for: snapshot.prList.lastUpdated, relativeTo: now))")
    }

    private var syncDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synchronization").font(.headline)
            Text("Last updated: \(Self.absoluteDateFormatter.string(from: snapshot.prList.lastUpdated))")
            if snapshot.rateLimitInfo.limit > 0 {
                Text("API: \(snapshot.rateLimitInfo.remaining) remaining of \(snapshot.rateLimitInfo.limit)")
                if snapshot.rateLimitInfo.resetDate > snapshot.now {
                    Text("API reset: \(Self.absoluteDateFormatter.string(from: snapshot.rateLimitInfo.resetDate))")
                }
            } else {
                Text("API quota unavailable")
            }
            Divider()
            Text("\(snapshot.prList.totalUnresolvedCount) unresolved threads")
            Text("\(snapshot.prList.authoredUnreadUnresolvedCount) unread unresolved threads on your PRs")
            Text("\(snapshot.prList.unansweredDirectMentionCount) unanswered direct mentions")
            Text("\(snapshot.activityReminderCount) Activity reminders")
        }
        .font(.system(size: PanelMetrics.metadataSize))
        .padding(PanelMetrics.inset)
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .long
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formatRelativeTime(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: snapshot.now)
    }


    private var onboardingAvailableSteps: Set<OnboardingManager.Step> {
        guard snapshot.prList.hasUsableData else {
            return []
        }

        var steps: Set<OnboardingManager.Step> = [.filter, .repoFilter]

        if !snapshot.projection.authoredPRs.isEmpty {
            steps.insert(.myPRs)
        }
        if !snapshot.projection.reviewRequestPRs.isEmpty {
            steps.insert(.reviewRequests)
        }
        if !snapshot.projection.mergedLast24hPRs.isEmpty {
            steps.insert(.mergedToday)
        }
        if snapshot.prList.totalUnresolvedCount > 0 {
            steps.insert(.unresolvedComments)
        }
        if firstVisibleReviewStatusPRID != nil {
            steps.insert(.myReviewStatus)
        }
        if firstVisibleApprovalPRID != nil {
            steps.insert(.approvals)
        }

        return steps
    }

    private func syncOnboardingState() {
        onboardingManager?.updateAvailableSteps(onboardingAvailableSteps)

        if snapshot.prList.hasUsableData {
            onboardingManager?.startIfNeeded()
        }
    }
}

private extension View {
    @ViewBuilder
    func panelOnboardingAnchor(
        _ manager: OnboardingManager?,
        step: OnboardingManager.Step,
        arrow: Edge = .bottom
    ) -> some View {
        if let manager {
            onboardingAnchor(manager, step: step, arrow: arrow)
        } else {
            self
        }
    }
}
