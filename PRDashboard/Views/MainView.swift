import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject var onboardingManager: OnboardingManager
    var presentationCoordinator: AppPresentationCoordinator? = nil
    @ObservedObject var extensionPlatformController: ExtensionPlatformController
    @ObservedObject var interaction: PanelInteractionCoordinator
    @State private var extensionActionError: String?
    @State private var localPresentationRevision: UInt64 = 0
    @State private var panelClock = Date()

    var body: some View {
        Group {
            if viewModel.authState.isAuthenticated {
                PRPanelView(
                    snapshot: panelSnapshot,
                    actions: panelActions,
                    searchText: Binding(
                        get: { viewModel.searchText },
                        set: { query in
                            viewModel.searchText = query
                            submitUserIntent()
                        }
                    ),
                    isFacetPanelPresented: $viewModel.isFacetPanelPresented,
                    interaction: interaction,
                    onboardingManager: onboardingManager
                )
            } else {
                AuthView(viewModel: viewModel)
                    .frame(width: 400, height: 500)
            }
        }
        .background {
            if interaction.isPresented && interaction.isWindowActive {
                TimelineView(.periodic(from: panelClock, by: 10)) { context in
                    Color.clear
                        .onChange(of: context.date) { panelClock = $0 }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onReceive(extensionPlatformController.objectWillChange) { _ in
            localPresentationRevision &+= 1
        }
        .onChange(of: extensionActionError) { _ in
            localPresentationRevision &+= 1
        }
        .alert(item: $viewModel.jiraPrompt) { prompt in
            switch prompt {
            case .setup(let key):
                return Alert(
                    title: Text("Jira is not connected"),
                    message: Text("This PR references \(key), but Jira has not been configured."),
                    primaryButton: .default(Text("Connect Jira")) {
                        viewModel.jiraPrompt = nil
                        presentationCoordinator?.present(
                            .jiraSetup(JiraSetupContext(source: .jiraIssue(key: key)))
                        )
                    },
                    secondaryButton: .cancel(Text("Not Now")) {
                        viewModel.jiraPrompt = nil
                    }
                )
            case .reconnect(let key):
                return Alert(
                    title: Text("Jira credentials are no longer valid."),
                    message: Text("Please reconnect to continue accessing Jira."),
                    primaryButton: .default(Text("Reconnect")) {
                        viewModel.jiraPrompt = nil
                        presentationCoordinator?.present(
                            .jiraSetup(JiraSetupContext(source: .jiraIssue(key: key)))
                        )
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        viewModel.jiraPrompt = nil
                    }
                )
            }
        }
    }

    private var panelSnapshot: PRPanelSnapshot {
        let projection = viewModel.panelProjection
        let runnableSkills = extensionPlatformController.runnableRevisionSkills()
        var rowExtensions: [Int: PRRowExtensionState] = [:]
        for section in PRSectionID.allCases {
            for id in projection.displayedRowIDs(for: section) {
                guard rowExtensions[id.prID] == nil, let pr = projection.pr(for: id) else { continue }
                rowExtensions[id.prID] = PRRowExtensionState(
                    runnableSkills: runnableSkills,
                    extensionRun: extensionPlatformController.activeRun(repository: pr.repoFullName, number: pr.number),
                    extensionAnalysis: extensionPlatformController.latestAnalysis(repository: pr.repoFullName, number: pr.number),
                    extensionTags: extensionPlatformController.tags(repository: pr.repoFullName, number: pr.number)
                )
            }
        }
        return PRPanelSnapshot(
            prList: viewModel.prList,
            projection: projection,
            rateLimitInfo: viewModel.rateLimitInfo,
            configuration: viewModel.configuration,
            jiraConnectionState: viewModel.jiraConnectionState,
            pinnedIdentifiers: viewModel.pinnedPRIdentifiers,
            activeFacetSelections: viewModel.activeFacetSelections,
            activityReminderCount: viewModel.actionableActivityCount,
            openingPRIDs: viewModel.openingPRIDs,
            updatingBranchPRIDs: viewModel.updatingBranchPRIDs,
            loadingHoverDetailPRIDs: viewModel.loadingHoverDetailPRIDs,
            facetChips: projection.facetChips,
            facetOptions: projection.facetOptions,
            labelSuggestions: projection.searchLabelSuggestions,
            savedViews: viewModel.savedViews,
            now: Date(),
            rowExtensions: rowExtensions,
            actionError: extensionActionError,
            presentationRevision: viewModel.panelPublicationRevision &+ localPresentationRevision
        )
    }

    private var panelActions: PRPanelActions {
        PRPanelActions(
            refresh: {
                viewModel.refresh()
                submitUserIntent()
            },
            openActivity: { viewModel.showActivity() },
            openSettings: { viewModel.showSettings() },
            rowActions: rowActions,
            toggleFacet: { field, key in
                viewModel.toggleFacet(field: field, key: key)
                submitUserIntent()
            },
            clearFacetField: {
                viewModel.clearFacetField($0)
                submitUserIntent()
            },
            clearAllFacets: {
                viewModel.clearAllFacets()
                submitUserIntent()
            },
            selectLabelSuggestion: {
                viewModel.selectLabelSuggestion($0)
                submitUserIntent()
            },
            saveCurrentView: { viewModel.saveCurrentView(name: $0) },
            applySavedView: {
                viewModel.applySavedView($0)
                submitUserIntent()
            },
            renameSavedView: { viewModel.renameSavedView($0, name: $1) },
            deleteSavedView: { viewModel.deleteSavedView($0) },
            dismissActionError: { extensionActionError = nil }
        )
    }

    private func submitUserIntent() {
        interaction.receive(snapshot: panelSnapshot, reason: .userIntent)
    }

    private func withLatestPR(
        _ id: Int, capturedHead: String? = nil, write: Bool = false,
        menuCapture: PanelMenuCapture? = nil,
        perform: (PullRequest) -> Void
    ) {
        let head = capturedMenuHead(id, fallback: capturedHead, capture: menuCapture)
        switch viewModel.resolvePRAction(id: id, capturedHeadCommitOID: head, requiresUnchangedHead: write) {
        case .success(let pr): perform(pr)
        case .failure(let error): extensionActionError = error.message
        }
    }
    private func capturedMenuHead(_ id: Int, fallback: String?, capture: PanelMenuCapture?) -> String? {
        if let menuPR = capture?.fact(for: id) { return menuPR.headCommitOid }
        return fallback
    }

    private func rowActions(_ id: Int) -> PRRowActions {
        let menuCapture = interaction.menuCapture
        let displayed = menuCapture.fact(for: id)
            ?? PRPanelActionResolver.latestPR(id: id, in: viewModel.prList)
        let head = displayed?.headCommitOid
        let analysisAvailable = displayed.map {
            extensionPlatformController.latestAnalysis(repository: $0.repoFullName, number: $0.number) != nil
        } ?? false
        return PRRowActions(
            onOpen: { withLatestPR(id) { viewModel.openPR($0) } },
            onOpenJira: { requestedKey in
                withLatestPR(id) { pr in
                    guard let key = PRPanelActionResolver.jiraIssueKey(requested: requestedKey, for: pr) else {
                        extensionActionError = "Jira issue no longer available for this PR"
                        return
                    }
                    viewModel.openJiraIssue(key)
                }
            },
            onCopyURL: { withLatestPR(id) { viewModel.copyURL($0) } },
            onMarkReviewCommentsRead: (displayed?.unreadUnresolvedCount ?? 0) > 0 ? {
                withLatestPR(id, capturedHead: head, write: true, menuCapture: menuCapture) { pr in
                    guard pr.unreadUnresolvedCount > 0 else { return }
                    viewModel.markReviewCommentsRead(pr)
                }
            } : nil,
            onMarkReviewCommentsUnread: (displayed?.readUnresolvedCount ?? 0) > 0 ? {
                withLatestPR(id, capturedHead: head, write: true, menuCapture: menuCapture) { pr in
                    guard pr.readUnresolvedCount > 0 else { return }
                    viewModel.markReviewCommentsUnread(pr)
                }
            } : nil,
            onRerunFailedCI: displayed?.category == .authored && ((displayed?.checkFailureCount ?? 0) > 0 || analysisAvailable) ? {
                withLatestPR(id, capturedHead: head, write: true, menuCapture: menuCapture) { pr in
                    guard pr.category == .authored,
                          pr.checkFailureCount > 0 || extensionPlatformController.latestAnalysis(repository: pr.repoFullName, number: pr.number) != nil else { return }
                    viewModel.rerunFailedCI(pr)
                }
            } : nil,
            onUpdateBranchWithRebase: displayed?.category == .authored ? {
                withLatestPR(id, capturedHead: head, write: true, menuCapture: menuCapture) { pr in
                    guard pr.category == .authored else { return }
                    viewModel.updateBranchWithRebase(pr)
                }
            } : nil,
            onLoadHoverDetail: { withLatestPR(id) { viewModel.loadHoverDetailIfNeeded($0) } },
            onTogglePin: {
                withLatestPR(id, capturedHead: head, write: true, menuCapture: menuCapture) {
                    viewModel.togglePin($0)
                    submitUserIntent()
                }
            },
            onAnalyzeCIFailure: (displayed?.checkFailureCount ?? 0) > 0 ? {
                withLatestPR(id) { pr in
                    guard pr.checkFailureCount > 0 else { return }
                    viewModel.openPRChecks(pr)
                }
            } : nil,
            onOpenRawDiagnostics: analysisAvailable ? { withLatestPR(id) { openRawDiagnostics(for: $0) } } : nil,
            onRunSkill: extensionPlatformController.runnableRevisionSkills().isEmpty ? nil : { skillID in
                runExtensionSkill(skillID, prID: id, capturedHead: head, menuCapture: menuCapture)
            },
            onInstallBrowserUserscript: browserUserscriptInstallAction,
            onOpenBrowserIntegrationSettings: browserIntegrationSettingsAction
        )
    }
    private var browserUserscriptInstallAction: (() -> Void)? {
        guard extensionPlatformController.officialUserscriptClient == nil,
              let url = extensionPlatformController.installUserscriptURL() else {
            return nil
        }
        return {
            NSWorkspace.shared.open(url)
        }
    }

    private var browserIntegrationSettingsAction: (() -> Void)? {
        guard let presentationCoordinator else {
            return nil
        }
        return {
            presentationCoordinator.present(.settings(.integrations))
        }
    }

    private func runExtensionSkill(_ skillID: String, prID: Int, capturedHead: String?, menuCapture: PanelMenuCapture) {
        let head = capturedMenuHead(prID, fallback: capturedHead, capture: menuCapture)
        Task { @MainActor in
            do {
                let pr = try viewModel.resolvePRAction(
                    id: prID, capturedHeadCommitOID: head, requiresUnchangedHead: true
                ).get()
                guard extensionPlatformController.runnableRevisionSkills().contains(where: { $0.id == skillID }) else { return }
                try await extensionPlatformController.runRevisionSkill(
                    id: skillID,
                    repository: pr.repoFullName,
                    number: pr.number
                )
                extensionActionError = nil
            } catch let error as PRPanelActionError {
                extensionActionError = error.message
            } catch {
                extensionActionError = error.localizedDescription
            }
        }
    }

    private func openRawDiagnostics(for pr: PullRequest) {
        guard let url = extensionPlatformController.latestAnalysisURL(
            repository: pr.repoFullName,
            number: pr.number
        ) else {
            extensionActionError = "No CI analysis is available for this pull request."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Auth View

struct AuthView: View {
    @ObservedObject var viewModel: PRListViewModel
    @State private var showPATInput = false
    @State private var patToken = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App Icon
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            // Title
            VStack(spacing: 8) {
                Text("PR Dashboard")
                    .font(.system(size: 20, weight: .semibold))

                Text("Track your GitHub pull requests\nand unresolved comments")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let deviceCode = viewModel.deviceCode {
                // Device code view (existing OAuth flow)
                deviceCodeView(deviceCode)
            } else if showPATInput {
                // PAT input view
                PATInputView(
                    token: $patToken,
                    isValidating: viewModel.isValidatingPAT,
                    error: viewModel.patError,
                    onSubmit: {
                        viewModel.signInWithPAT(patToken)
                    },
                    onCancel: {
                        showPATInput = false
                        patToken = ""
                        viewModel.clearPATError()
                    },
                    onClearError: {
                        viewModel.clearPATError()
                    }
                )
            } else {
                // Auth method selection
                authMethodSelection
            }

            // General error display (for OAuth errors)
            if !showPATInput, let error = viewModel.authError {
                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: viewModel.authState.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                // Clear PAT input on successful auth
                showPATInput = false
                patToken = ""
            }
        }
    }

    private var authMethodSelection: some View {
        VStack(spacing: 12) {
            // OAuth button (primary)
            Button(action: { viewModel.signIn() }) {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle")
                    Text("Sign in with GitHub")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .disabled(viewModel.isAuthenticating)

            // Divider with "or"
            HStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                Text("or")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }
            .padding(.horizontal, 60)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Flow (recommended)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("No setup needed. Works for most personal & public accounts.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Use PAT (classic) if your org requires separate SSO authorization")
                        .font(.system(size: 12, weight: .semibold))
                    Text("After creating the token, click \"Configure SSO\" on GitHub to authorize it for your organization.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 40)

            // PAT button (secondary)
            Button(action: { showPATInput = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "key")
                    Text("Use Personal Access Token")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
    }

    private func deviceCodeView(_ deviceCode: DeviceCodeInfo) -> some View {
        VStack(spacing: 16) {
            // Instructions
            Text("Enter this code on GitHub:")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // User code display
            HStack(spacing: 4) {
                Text(deviceCode.userCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)

                Button(action: { viewModel.copyUserCode() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Open link button
            Button(action: { viewModel.openVerificationURL() }) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Open github.com/login/device")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            // Waiting indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for authorization...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Cancel button
            Button("Cancel") {
                viewModel.cancelSignIn()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.system(size: 12))
        }
    }
}
