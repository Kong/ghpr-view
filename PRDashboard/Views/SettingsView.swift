import SwiftUI
import ServiceManagement

enum SettingsWindowMetrics {
    static let width: CGFloat = 620
    static let height: CGFloat = 620
    static let sidebarWidth: CGFloat = 156
}

/// Settings pages. Add a preference to an existing page unless it is its own product surface.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case pullRequests
    case alerts
    case integrations
    case advanced

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .pullRequests: return "Pull Requests"
        case .alerts: return "Alerts"
        case .integrations: return "Integrations"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .pullRequests: return "list.bullet.rectangle"
        case .alerts: return "bell"
        case .integrations: return "puzzlepiece.extension"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}


struct SettingsDraft {
    var refreshInterval: Double = 60
    var refreshOnOpen: Bool = true
    var repositories: String = ""
    var showDrafts: Bool = true
    var minimumApprovalsForReadyToMerge: Int = 1
    var notificationsEnabled: Bool = true
    var ciStatusExcludeFilter: String = "review"
    var pausePollingInLowPowerMode: Bool = true
    var pausePollingOnExpensiveNetwork: Bool = true
    var showMyReviewStatus: Bool = false
    var automaticallyCheckForUpdates: Bool = true
    var openAtCmuxFirst: Bool = false
    var graphQLEndpoint: String = ""
    var httpProxyURL: String = ""
    var httpProxyUsername: String = ""
    var httpProxyPassword: String = ""
    var jiraServerURL: String = ""
    var newPATToken = ""
    var monitorEnabled: Bool = true
    var notificationTargets: Set<DigestChannel> = [.macOS]
    var notificationEventKinds: Set<PRActivityEventKind> = Set(PRActivityEventKind.allCases)
    var notificationRepositories: String = ""
    var slackEnabled = false
    var slackMessageTemplate = "{{digest}}"
    var slackBotToken: String = ""
    var slackUserID: String = ""
    var commentShortcuts: [CommentShortcut] = []
}

enum SlackSetupState: Equatable {
    case idle
    case verifying
    case connected(String)
    case failure(String)
}

enum JiraConnectionTestState: Equatable {
    case idle
    case testing
    case success(String?)
    case failure(String)
}

struct SettingsStatus {
    var authState: AuthState
    var launchAtLogin: Bool
    var isValidatingPAT: Bool
    var patErrorMessage: String?
    var currentVersionDescription: String
    var updateCheckButtonTitle: LocalizedStringKey
    var isUpdateBusy: Bool
    var isUpdateCheckInProgress: Bool
    var jiraConnectionState: JiraConnectionState
    var jiraTest: JiraConnectionTestState
    var slack: SlackSetupState
    var isSlackDeliveryConfigured: Bool
    var slackWorkspaceName: String
    var connectedSlackUserID: String
    var browser: BrowserIntegrationPresentation
}

struct SettingsActions {
    var save: (SettingsDraft) -> Void
    var cancel: () -> Void
    var signOut: () -> Void
    var signIn: () -> Void
    var switchToOAuth: () -> Void
    var clearPATError: () -> Void
    var checkForUpdates: () -> Void
    var resetOnboarding: () -> Void
    var clearCaches: () -> Void
    var resetJiraTest: () -> Void
    var sendSlackTest: () -> Void
    var switchToPAT: (String) -> Void
    var setLaunchAtLogin: (Bool) -> Void
    var openJiraSetup: (String) -> Void
    var testJira: (String) -> Void
    var verifySlack: (String, String) -> Void
    var browser: BrowserIntegrationActions
}

struct SettingsView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject var onboardingManager: OnboardingManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var extensionPlatformController: ExtensionPlatformController
    @ObservedObject var navigation: SettingsNavigation
    var presentationCoordinator: AppPresentationCoordinator? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var draft = SettingsDraft()
    @State private var jiraConnectionTestState: JiraConnectionTestState = .idle
    @State private var jiraConnectionTestTask: Task<Void, Never>?
    @State private var slackState: SlackSetupState = .idle
    @State private var slackTask: Task<Void, Never>?
    @State private var agentInstallStatuses = BrowserIntegrationView.loadAgentStatuses()
    @State private var agentInstallError: String?

    var body: some View {
        SettingsContent(draft: $draft, status: status, navigation: navigation, actions: actions,
                        raftExternalAgentIntegration: RaftExternalAgentIntegration.shared)
            .onAppear(perform: loadCurrentSettings)
            .onDisappear {
                jiraConnectionTestTask?.cancel()
                jiraConnectionTestTask = nil
                slackTask?.cancel()
                slackTask = nil
            }
    }

    private var status: SettingsStatus {
        SettingsStatus(
            authState: viewModel.authState,
            launchAtLogin: launchAtLogin,
            isValidatingPAT: viewModel.isValidatingPAT,
            patErrorMessage: viewModel.patError?.localizedDescription,
            currentVersionDescription: currentVersionDescription,
            updateCheckButtonTitle: updateCheckButtonTitle,
            isUpdateBusy: isUpdateBusy,
            isUpdateCheckInProgress: isUpdateCheckInProgress,
            jiraConnectionState: viewModel.jiraConnectionState,
            jiraTest: jiraConnectionTestState,
            slack: slackState,
            isSlackDeliveryConfigured: viewModel.configuration.isSlackDeliveryConfigured,
            slackWorkspaceName: viewModel.configuration.slackWorkspaceName,
            connectedSlackUserID: viewModel.configuration.slackUserID,
            browser: BrowserIntegrationView.presentation(
                controller: extensionPlatformController,
                agentInstallStatuses: agentInstallStatuses,
                agentInstallError: agentInstallError
            )
        )
    }

    private var actions: SettingsActions {
        SettingsActions(
            save: save,
            cancel: { dismiss() },
            signOut: { viewModel.signOut(); dismiss() },
            signIn: { viewModel.signIn(); dismiss() },
            switchToOAuth: { viewModel.signOut(); viewModel.signIn(); dismiss() },
            clearPATError: { viewModel.clearPATError() },
            checkForUpdates: { updateManager.checkForUpdates(userInitiated: true) },
            resetOnboarding: { onboardingManager.reset(); dismiss() },
            clearCaches: { viewModel.clearCaches(); dismiss() },
            resetJiraTest: resetJiraConnectionTest,
            sendSlackTest: sendSlackTestMessage,
            switchToPAT: { token in viewModel.signOut(); viewModel.signInWithPAT(token) },
            setLaunchAtLogin: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = enabled
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            },
            openJiraSetup: openJiraSetupGuide,
            testJira: testStoredJiraConnection,
            verifySlack: verifySlackConnection,
            browser: BrowserIntegrationView.actions(
                controller: extensionPlatformController,
                installForAllAgents: {
                    do {
                        agentInstallStatuses = try BrowserIntegrationView.installAgents()
                        agentInstallError = nil
                    } catch {
                        agentInstallStatuses = BrowserIntegrationView.loadAgentStatuses()
                        agentInstallError = error.localizedDescription
                    }
                }
            )
        )
    }

    private var currentVersionDescription: String {
        let version = updateManager.currentVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = updateManager.currentBuildString.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionPrefix = version.hasPrefix("v") ? version : "v\(version)"

        if build.isEmpty {
            return "\(versionPrefix) [\(GitVersion.displayString)]"
        }

        return "\(versionPrefix) (\(build)) [\(GitVersion.displayString)]"
    }

    private var updateCheckButtonTitle: LocalizedStringKey {
        switch updateManager.state {
        case .checking:
            return "Checking…"
        case .refreshingHomebrew:
            return "Checking Homebrew…"
        case .downloading:
            return "Downloading…"
        case .readyToInstall:
            return "Ready to Install"
        case .installing:
            return "Installing…"
        case .idle, .upToDate, .available, .homebrewAvailable, .unsupportedInstallLocation, .error:
            return "Check for Updates…"
        }
    }
    private func testStoredJiraConnection(_ serverURL: String) {
        guard let normalizedJiraServerURL = JiraAPIClient.normalizedServerURL(serverURL) else { return }
        let email = viewModel.configuration.jiraEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiToken = Keychain.loadJiraAPIToken()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !apiToken.isEmpty else { return }

        jiraConnectionTestTask?.cancel()
        jiraConnectionTestState = .testing
        jiraConnectionTestTask = Task {
            do {
                let result = try await JiraAPIClient().testConnection(
                    serverURL: normalizedJiraServerURL,
                    email: email,
                    apiToken: apiToken
                )
                guard !Task.isCancelled else { return }
                jiraConnectionTestState = .success(
                    result.displayName ?? result.emailAddress
                )
            } catch {
                guard !Task.isCancelled else { return }
                jiraConnectionTestState = .failure(error.localizedDescription)
            }
            jiraConnectionTestTask = nil
        }
    }

    private func resetJiraConnectionTest() {
        jiraConnectionTestTask?.cancel()
        jiraConnectionTestTask = nil
        jiraConnectionTestState = .idle
    }

    private func openJiraSetupGuide(_ serverURL: String) {
        guard let normalizedJiraServerURL = JiraAPIClient.normalizedServerURL(serverURL),
              JiraAPIClient.isSupportedCloudServerURL(normalizedJiraServerURL)
        else { return }
        draft.jiraServerURL = normalizedJiraServerURL
        presentationCoordinator?.present(
            .jiraSetup(
                JiraSetupContext(
                    source: .settings,
                    initialServerURL: normalizedJiraServerURL
                )
            )
        )
    }


    private var isUpdateCheckInProgress: Bool {
        if case .checking = updateManager.state {
            return true
        }

        return false
    }

    private var isUpdateBusy: Bool {
        switch updateManager.state {
        case .checking, .refreshingHomebrew, .downloading, .readyToInstall, .installing:
            return true
        case .idle, .upToDate, .available, .homebrewAvailable, .unsupportedInstallLocation, .error:
            return false
        }
    }

    private func loadCurrentSettings() {
        let config = viewModel.configuration
        draft.refreshInterval = config.refreshInterval
        draft.refreshOnOpen = config.refreshOnOpen
        draft.repositories = config.repositories.joined(separator: ", ")
        draft.showDrafts = config.showDrafts
        draft.minimumApprovalsForReadyToMerge = config.minimumApprovalsForReadyToMerge
        draft.notificationsEnabled = config.notificationsEnabled
        draft.ciStatusExcludeFilter = config.ciStatusExcludeFilter
        draft.pausePollingInLowPowerMode = config.pausePollingInLowPowerMode
        draft.pausePollingOnExpensiveNetwork = config.pausePollingOnExpensiveNetwork
        draft.showMyReviewStatus = config.showMyReviewStatus
        draft.automaticallyCheckForUpdates = config.automaticallyCheckForUpdates
        draft.openAtCmuxFirst = config.openAtCmuxFirst
        draft.graphQLEndpoint = config.graphQLEndpoint
        draft.httpProxyURL = config.httpProxyURL
        draft.httpProxyUsername = config.httpProxyUsername
        draft.httpProxyPassword = Keychain.loadProxyPassword()
        draft.jiraServerURL = config.jiraServerURL
        draft.monitorEnabled = config.monitorEnabled
        draft.notificationTargets = Set(config.digestChannels.filter { $0 == .macOS })
        draft.notificationEventKinds = config.notificationEventKindFilter
        draft.notificationRepositories = config.notificationRepositories.joined(separator: ", ")
        draft.slackBotToken = Keychain.loadSlackBotToken()
        draft.slackUserID = config.slackUserID
        draft.slackEnabled = config.slackEnabled
        draft.slackMessageTemplate = config.slackMessageTemplate
        draft.commentShortcuts = config.commentShortcuts
        slackState = config.isSlackDeliveryConfigured
            ? .connected(config.slackWorkspaceName)
            : .idle
    }
    private func verifySlackConnection(_ botToken: String, _ slackUserID: String) {
        let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = slackUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        slackTask?.cancel()
        slackState = .verifying
        slackTask = Task { @MainActor in
            let client = SlackNotificationClient(
                proxy: GitHubAPIClient.resolvedProxyConfig(
                    urlString: viewModel.configuration.httpProxyURL,
                    username: viewModel.configuration.httpProxyUsername,
                    password: Keychain.loadProxyPassword()
                )
            )
            do {
                let connection = try await client.verifyAndConnect(token: token, userID: userID)
                guard !Task.isCancelled else { return }
                Keychain.saveSlackBotToken(token)
                var config = viewModel.configuration
                config.slackEnabled = true
                config.slackWorkspaceID = connection.workspaceID
                config.slackWorkspaceName = connection.workspaceName
                config.slackUserID = connection.userID
                config.slackDMChannelID = connection.channelID
                viewModel.configuration = config
                slackState = .connected(connection.workspaceName)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                switch SlackVerificationFailurePolicy.policy(for: error) {
                case .clearStoredConnection:
                    Keychain.deleteSlackBotToken()
                    var config = viewModel.configuration
                    config.slackEnabled = false
                    config.slackWorkspaceID = ""
                    config.slackWorkspaceName = ""
                    config.slackDMChannelID = ""
                    viewModel.configuration = config
                case .keepExistingConnection:
                    break
                }
                slackState = .failure(message)
            }
        }
    }

    private func sendSlackTestMessage() {
        let token = Keychain.loadSlackBotToken()
        let configuration = viewModel.configuration
        guard configuration.isSlackDeliveryConfigured, !token.isEmpty else {
            slackState = .failure(String(localized: "Connect Slack before sending a test message."))
            return
        }
        slackTask?.cancel()
        slackState = .verifying
        slackTask = Task { @MainActor in
            let client = SlackNotificationClient(
                proxy: GitHubAPIClient.resolvedProxyConfig(
                    urlString: configuration.httpProxyURL,
                    username: configuration.httpProxyUsername,
                    password: Keychain.loadProxyPassword()
                )
            )
            let connection = SlackConnection(
                workspaceID: configuration.slackWorkspaceID,
                workspaceName: configuration.slackWorkspaceName,
                botUserID: "",
                botName: "",
                channelID: configuration.slackDMChannelID,
                channelName: nil,
                userID: configuration.slackUserID
            )
            do {
                _ = try await client.sendTestMessage(token: token, connection: connection)
                guard !Task.isCancelled else { return }
                slackState = .connected(configuration.slackWorkspaceName)
            } catch {
                guard !Task.isCancelled else { return }
                slackState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
    private func save(_ draft: SettingsDraft) {
        let repos = draft.repositories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmedProxyURL = draft.httpProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProxyUsername = draft.httpProxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJiraServerURL = draft.jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build config carrying current (pre-save) Jira fields; updateJiraCredentials
        // overwrites them atomically below so cache invalidation + refresh fire once.
        let existingJira = viewModel.configuration
        let config = Configuration(
            refreshInterval: draft.refreshInterval,
            repositories: repos,
            showDrafts: draft.showDrafts,
            minimumApprovalsForReadyToMerge: draft.minimumApprovalsForReadyToMerge,
            notificationsEnabled: draft.notificationsEnabled,
            refreshOnOpen: draft.refreshOnOpen,
            ciStatusExcludeFilter: draft.ciStatusExcludeFilter,
            pausePollingInLowPowerMode: draft.pausePollingInLowPowerMode,
            pausePollingOnExpensiveNetwork: draft.pausePollingOnExpensiveNetwork,
            showMyReviewStatus: draft.showMyReviewStatus,
            automaticallyCheckForUpdates: draft.automaticallyCheckForUpdates,
            openAtCmuxFirst: draft.openAtCmuxFirst,
            graphQLEndpoint: draft.graphQLEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            httpProxyURL: trimmedProxyURL,
            httpProxyUsername: trimmedProxyUsername,
            jiraServerURL: existingJira.jiraServerURL,
            jiraEmail: existingJira.jiraEmail,
            jiraRefreshInterval: existingJira.jiraRefreshInterval,
            monitorEnabled: draft.monitorEnabled,
            notificationTargets: draft.notificationTargets.map(\.rawValue).sorted(),
            notificationEventKinds: draft.notificationEventKinds.isEmpty
                ? [Configuration.noNotificationEventKinds]
                : draft.notificationEventKinds.map(\.rawValue).sorted(),
            notificationRepositories: draft.notificationRepositories
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            slackEnabled: draft.slackEnabled,
            slackWorkspaceName: existingJira.slackWorkspaceName,
            slackWorkspaceID: existingJira.slackWorkspaceID,
            slackUserID: existingJira.slackUserID,
            slackDMChannelID: existingJira.slackDMChannelID,
            slackMessageTemplate: draft.slackMessageTemplate,
            commentShortcuts: draft.commentShortcuts
        )

        if trimmedProxyURL.isEmpty {
            Keychain.deleteProxyPassword()
        } else {
            Keychain.saveProxyPassword(draft.httpProxyPassword)
        }
        viewModel.configuration = config
        viewModel.updateJiraCredentials(
            serverURL: trimmedJiraServerURL,
            email: existingJira.jiraEmail,
            apiToken: Keychain.loadJiraAPIToken(),
            refreshInterval: existingJira.jiraRefreshInterval
        )
        dismiss()
    }
}

struct SettingsContent: View {
    @Binding var draft: SettingsDraft
    var status: SettingsStatus
    @ObservedObject var navigation: SettingsNavigation
    var actions: SettingsActions
    var raftExternalAgentIntegration: RaftExternalAgentIntegration? = nil
    @State private var showPATSwitchSheet = false
    @State private var showClearCacheConfirmation = false
    @State private var showAllEventCategories = false

    private let refreshIntervalOptions: [(LocalizedStringKey, Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800)
    ]

    private var sidebarSelection: Binding<SettingsTab?> {
        Binding(
            get: { navigation.tab },
            set: { if let tab = $0 { navigation.tab = tab } }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: sidebarSelection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                        .accessibilityIdentifier("settings-page-\(tab.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .frame(width: SettingsWindowMetrics.sidebarWidth)
            .accessibilityIdentifier("settings-sidebar")

            Divider()

            VStack(spacing: 0) {
                Text(navigation.tab.title)
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()

                settingsForm
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()

                HStack {
                    Button("Cancel", role: .cancel, action: actions.cancel)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { actions.save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(showPATSwitchSheet)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: SettingsWindowMetrics.width, minHeight: SettingsWindowMetrics.height)
        .sheet(isPresented: $showPATSwitchSheet) { patSwitchSheet }
        .environment(\.openURL, OpenURLAction { url in
            actions.browser.openURL(url)
            return .handled
        })
    }

    private var settingsForm: some View {
        Form {
            switch navigation.tab {
            case .general:
                generalSettings
            case .pullRequests:
                pullRequestSettings
            case .alerts:
                alertSettings
            case .integrations:
                integrationSettings
            case .advanced:
                advancedSettings
            }
        }
        .formStyle(.grouped)
    }
    @ViewBuilder
    private var generalSettings: some View {
        Section("Account") {
            if status.authState.isAuthenticated {
                HStack {
                    CachedAvatarView(
                        url: status.authState.username.flatMap {
                            URL(string: "https://github.com/\($0).png?size=64")
                        },
                        authorInitial: status.authState.username ?? "Signed in"
                    )
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.authState.username ?? "Signed in")
                            .font(.headline)

                        HStack(spacing: 4) {
                            Image(systemName: status.authState.authMethod == .pat ? "key" : "person.badge.shield.checkmark")
                                .font(.system(size: 10))
                            Text(status.authState.authMethod == .pat ? "Personal Access Token" : "GitHub OAuth")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Sign Out") {
                        actions.signOut()
                    }
                    .foregroundColor(.red)
                }
                .padding(.vertical, 4)

                Divider()

                if status.authState.authMethod == .pat {
                    Button("Switch to GitHub OAuth") {
                        actions.switchToOAuth()
                    }
                    .font(.system(size: 12))
                } else {
                    Button("Switch to Personal Access Token") {
                        showPATSwitchSheet = true
                    }
                    .font(.system(size: 12))
                }
            } else {
                Button("Sign in with GitHub") {
                    actions.signIn()
                }
                .buttonStyle(.borderedProminent)
            }
        }

        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { status.launchAtLogin },
                set: actions.setLaunchAtLogin
            ))
            .accessibilityIdentifier("settings-launch-at-login")

            HStack {
                Toggle("Open PRs in cmux first", isOn: $draft.openAtCmuxFirst)
                HelpHint("If the same PR is already open in cmux, switch to it and reload it. Otherwise, open the PR in your default browser.\n\nRequires cmux → Settings → Socket Control set to “Automation” (the default “cmux only” rejects connections from other apps).")
            }
        }

        Section("Refresh") {
            Picker("Refresh Interval", selection: $draft.refreshInterval) {
                ForEach(refreshIntervalOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }

            Toggle("Refresh when opened", isOn: $draft.refreshOnOpen)
        }

        Section("Power & Network") {
            Toggle("Pause background refresh in Low Power Mode", isOn: $draft.pausePollingInLowPowerMode)
            Toggle("Pause background refresh on cellular/hotspot", isOn: $draft.pausePollingOnExpensiveNetwork)
        }

        Section("Updates") {
            HStack {
                Text("Current version")
                Spacer()
                Text(status.currentVersionDescription)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Toggle("Automatically check for updates", isOn: $draft.automaticallyCheckForUpdates)

            HStack {
                Button {
                    actions.checkForUpdates()
                } label: {
                    Label(status.updateCheckButtonTitle, systemImage: "arrow.clockwise")
                }
                .disabled(status.isUpdateBusy)

                if status.isUpdateCheckInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var pullRequestSettings: some View {
        Section("Filters") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Repositories (comma-separated, leave empty for all)")
                    HelpHint("Filter PRs to specific repos. Format: owner/repo, comma-separated (e.g., owner/repo1, owner/repo2). Leave empty to show PRs from all repos.")
                    Spacer()
                }
                TextField("", text: $draft.repositories)
                    .labelsHidden()
                    .accessibilityLabel("Repositories (comma-separated, leave empty for all)")
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Show draft PRs", isOn: $draft.showDrafts)
                .accessibilityIdentifier("settings-show-drafts")
                .accessibilityValue(draft.showDrafts ? "1" : "0")

            Toggle("Show my review status badges", isOn: $draft.showMyReviewStatus)

            VStack(alignment: .leading, spacing: 6) {
                Stepper(
                    "Minimum approvals for “Ready to merge”: \(draft.minimumApprovalsForReadyToMerge)",
                    value: $draft.minimumApprovalsForReadyToMerge,
                    in: 1...10
                )
                HelpHint("Only PRs with at least this many approvals, successful CI, and no change requests are counted as ready to merge.")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CI status exclude filter")
                    HelpHint("Exclude CI status checks whose name contains this keyword (e.g., \"review\" hides checks like \"code-review\"). Leave empty to include all checks.")
                    Spacer()
                }
                TextField("", text: $draft.ciStatusExcludeFilter)
                    .labelsHidden()
                    .accessibilityLabel("CI status exclude filter")
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var alertSettings: some View {
        Section("Notifications") {
            Toggle("Enable notifications", isOn: $draft.notificationsEnabled)
                .accessibilityIdentifier("settings-enable-notifications")
            Text("Notifications are digests of activity that needs your attention, not one alert per event.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Activity Monitoring") {
            Toggle("Monitor PR activity in the background", isOn: $draft.monitorEnabled)
            Text("Collects reviews, comments, thread state, review requests and CI for PRs you author, review or comment on. It only runs while PR Dashboard is running; nothing is stored outside this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Deliver digests to")
                    .font(.caption)
                Toggle("macOS notification", isOn: digestChannelBinding(.macOS))
                    .toggleStyle(.checkbox)
            }

            Text("At most one digest every 30 minutes, and only when there is new work. Muting a PR or turning notifications off affects delivery only; activity keeps being collected.")
                .font(.caption)
                .foregroundColor(.secondary)

            eventCategoryPicker

            TextField(
                "Only these repositories (empty = the PR list filter)",
                text: $draft.notificationRepositories,
                prompt: Text("owner/repo")
            )
            .textFieldStyle(.roundedBorder)
        }
        Section("Slack") {
            Toggle("Enable Slack notifications", isOn: $draft.slackEnabled)
                .accessibilityIdentifier("settings-slack-enabled")
            if draft.slackEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a Slack app with chat:write, im:write and users:read, install it, then enter its bot token and your Slack user ID. ghpr only sends a direct message to you.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("Bot token", text: $draft.slackBotToken, prompt: Text("xoxb-…"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    TextField("Your Slack user ID", text: $draft.slackUserID, prompt: Text("U0123ABCDEF"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)

                    HStack(spacing: 8) {
                        Button {
                            actions.verifySlack(draft.slackBotToken, draft.slackUserID)
                        } label: {
                            Label("Verify and Connect", systemImage: "checkmark.seal")
                        }
                        .disabled(status.slack == .verifying
                                  || draft.slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || draft.slackUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            actions.sendSlackTest()
                        } label: {
                            Label("Send test DM", systemImage: "paperplane")
                        }
                        .disabled(status.slack == .verifying || !status.isSlackDeliveryConfigured)

                        if status.slack == .verifying {
                            ProgressView().controlSize(.small)
                        }
                    }

                    slackStatusView
                    if status.isSlackDeliveryConfigured {
                        Text("Connected: \(status.slackWorkspaceName) · \(status.connectedSlackUserID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Message template")
                            .font(.caption)
                        TextEditor(text: $draft.slackMessageTemplate)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 72, maxHeight: 120)
                            .accessibilityLabel("Slack message template")
                        Text("Use {{digest}} for the generated activity digest.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        if let raftExternalAgentIntegration {
            RaftExternalAgentSettingsSection(integration: raftExternalAgentIntegration)
        }
    }

    @ViewBuilder
    private var integrationSettings: some View {
        Section("Jira") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Jira server")
                        .accessibilityIdentifier("settings-jira")
                    HelpHint("Jira Cloud server URL, for example https://company.atlassian.net. Email, API token, and connection testing are completed in the setup guide.")
                    Spacer()
                }
                TextField(
                    "",
                    text: $draft.jiraServerURL,
                    prompt: Text("https://company.atlassian.net")
                )
                .labelsHidden()
                .accessibilityLabel("Jira server")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .onChange(of: draft.jiraServerURL) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        draft.jiraServerURL = trimmed
                    }
                    actions.resetJiraTest()
                }

                if let jiraServerValidationMessage {
                    Label(jiraServerValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Button(jiraSetupButtonTitle) {
                actions.openJiraSetup(draft.jiraServerURL)
            }
            .disabled(!canOpenJiraSetupGuide)
            HStack(spacing: 8) {
                Button {
                    actions.testJira(draft.jiraServerURL)
                } label: {
                    Label("Test Connection", systemImage: "checkmark.seal")
                }
                .disabled(
                    !hasStoredJiraCredentials ||
                        status.jiraTest == .testing
                )

                if status.jiraTest == .testing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            jiraConnectionTestResultView

            Text("Enter the Jira site here, then use the guide to add your Atlassian email and API token and test the connection.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Browser Integration") {
            BrowserIntegrationContent(presentation: status.browser, actions: actions.browser)
        }

        Section("Comment Shortcuts") {
            CommentShortcutSettingsSection(shortcuts: $draft.commentShortcuts)
        }

    }

    @ViewBuilder
    private var advancedSettings: some View {
        Section("Developer Options") {
            Button("Show onboarding again") {
                actions.resetOnboarding()
            }
            .accessibilityIdentifier("settings-show-onboarding-again")

            Button("Clear cached PR data") {
                showClearCacheConfirmation = true
            }
            .foregroundColor(.red)
            .confirmationDialog(
                "Clear cached PR data?",
                isPresented: $showClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    actions.clearCaches()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all cached PRs, details, mentions, and avatars. The next refresh will refetch everything from GitHub.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("GraphQL endpoint override")
                    HelpHint("Route GitHub GraphQL requests through a proxy URL. Leave empty to use https://api.github.com/graphql. OAuth endpoints are not affected.")
                    Spacer()
                }
                TextField(
                    "",
                    text: $draft.graphQLEndpoint,
                    prompt: Text("https://example.com/graphql")
                )
                .labelsHidden()
                .accessibilityLabel("GraphQL endpoint override")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: draft.graphQLEndpoint) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        draft.graphQLEndpoint = trimmed
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HTTP proxy")
                    HelpHint("Route GitHub API requests through an HTTP proxy. Format: http://host:port. Leave empty to connect directly. Username and password are optional.")
                    Spacer()
                }
                TextField(
                    "",
                    text: $draft.httpProxyURL,
                    prompt: Text("http://proxy.example.com:8080")
                )
                .labelsHidden()
                .accessibilityLabel("HTTP proxy URL")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .onChange(of: draft.httpProxyURL) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        draft.httpProxyURL = trimmed
                    }
                }

                TextField(
                    "",
                    text: $draft.httpProxyUsername,
                    prompt: Text("Proxy username (optional)")
                )
                .labelsHidden()
                .accessibilityLabel("HTTP proxy username")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)

                SecureField(
                    "",
                    text: $draft.httpProxyPassword,
                    prompt: Text("Proxy password (optional)")
                )
                .labelsHidden()
                .accessibilityLabel("HTTP proxy password")
                .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var patSwitchSheet: some View {
        VStack(spacing: 20) {
            Text("Switch to Personal Access Token")
                .font(.headline)

            Text("This will sign you out and use a new token for authentication.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Enter Personal Access Token", text: $draft.newPATToken)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let error = status.patErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showPATSwitchSheet = false
                    draft.newPATToken = ""
                    actions.clearPATError()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Switch") {
                    actions.switchToPAT(draft.newPATToken)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.newPATToken.isEmpty || status.isValidatingPAT)
            }

            if status.isValidatingPAT {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .frame(width: 350, height: 250)
        .padding()
        .onChange(of: status.authState.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                showPATSwitchSheet = false
                draft.newPATToken = ""
                actions.cancel()
            }
        }
    }
    private var jiraSetupButtonTitle: LocalizedStringKey {
        switch status.jiraConnectionState {
        case .notConfigured: return "Connect Jira…"
        case .unauthorized: return "Reconnect Jira…"
        case .configured: return "Guided Jira Setup…"
        }
    }
    private var normalizedJiraServerURL: String? {
        JiraAPIClient.normalizedServerURL(draft.jiraServerURL)
    }

    private var jiraServerValidationMessage: String? {
        let trimmed = draft.jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let normalizedJiraServerURL else {
            return "Enter a valid Jira site URL."
        }
        guard JiraAPIClient.isSupportedCloudServerURL(normalizedJiraServerURL) else {
            return "Only Jira Cloud sites (*.atlassian.net) are supported."
        }
        return nil
    }

    private var canOpenJiraSetupGuide: Bool {
        normalizedJiraServerURL != nil &&
            jiraServerValidationMessage == nil
    }
    private var hasStoredJiraCredentials: Bool {
        status.jiraConnectionState != .notConfigured && canOpenJiraSetupGuide
    }

    @ViewBuilder
    private var jiraConnectionTestResultView: some View {
        switch status.jiraTest {
        case .idle, .testing:
            EmptyView()
        case .success(let account):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Jira connected")
                if let account, !account.isEmpty {
                    Text(account)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
        case .failure(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jira connection failed")
                    Text(message)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.caption)
        }
    }

    private func digestChannelBinding(_ channel: DigestChannel) -> Binding<Bool> {
        Binding(
            get: { draft.notificationTargets.contains(channel) },
            set: { isOn in
                if isOn {
                    draft.notificationTargets.insert(channel)
                } else {
                    draft.notificationTargets.remove(channel)
                }
            }
        )
    }


    private var eventCategoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Event categories")
                    .font(.caption)
                Spacer()
                Button("Select all") {
                    draft.notificationEventKinds = Set(PRActivityEventKind.allCases)
                }
                .buttonStyle(.borderless)
                Button("Select none") {
                    draft.notificationEventKinds = []
                }
                .buttonStyle(.borderless)
            }

            EventCategoryFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(visibleEventKinds, id: \.self) { kind in
                    eventCategoryChip(kind)
                }
            }

            if PRActivityEventKind.allCases.count > 8 {
                Button(showAllEventCategories ? "Show fewer" : "Show all (\(PRActivityEventKind.allCases.count))") {
                    showAllEventCategories.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.top, 4)
    }

    private var visibleEventKinds: [PRActivityEventKind] {
        showAllEventCategories ? PRActivityEventKind.allCases : Array(PRActivityEventKind.allCases.prefix(8))
    }

    private func eventCategoryChip(_ kind: PRActivityEventKind) -> some View {
        let isSelected = draft.notificationEventKinds.contains(kind)
        return Button {
            if isSelected {
                draft.notificationEventKinds.remove(kind)
            } else {
                draft.notificationEventKinds.insert(kind)
            }
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(PRActivityDigestFormatter.changeLabel(kind))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: isSelected ? 1.2 : 1, dash: isSelected ? [] : [3, 3])
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var slackStatusView: some View {
        Group {
            switch status.slack {
            case .idle:
                EmptyView()
            case .verifying:
                Text("Checking the token and the DM target…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .connected(let workspace):
                Label("Connected to \(workspace)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    struct HelpHint: View {
        let text: String
        @State private var isShown = false
        @State private var hoverTask: Task<Void, Never>?

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Button {
                hoverTask?.cancel()
                hoverTask = nil
                isShown.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .frame(minWidth: 20, minHeight: 20)
            }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("Help"))
                .accessibilityHint(Text(text))
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !Task.isCancelled {
                                await MainActor.run { isShown = true }
                            }
                        }
                    } else {
                        isShown = false
                    }
                }
                .popover(isPresented: $isShown, arrowEdge: .top) {
                    Text(text)
                        .font(.system(size: 12))
                        .padding(10)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onDisappear {
                    hoverTask?.cancel()
                    hoverTask = nil
                    isShown = false
                }
        }
    }
}

private struct EventCategoryFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews, width: proposal.width ?? .infinity)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x - horizontalSpacing)
        }

        return (CGSize(width: min(contentWidth, width), height: subviews.isEmpty ? 0 : y + rowHeight), frames)
    }
}
