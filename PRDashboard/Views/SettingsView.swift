import SwiftUI
import ServiceManagement

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


struct SettingsView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject var onboardingManager: OnboardingManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var extensionPlatformController: ExtensionPlatformController
    @ObservedObject var navigation: SettingsNavigation
    var presentationCoordinator: AppPresentationCoordinator? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var refreshInterval: Double = 60
    @State private var refreshOnOpen: Bool = true
    @State private var repositories: String = ""
    @State private var showDrafts: Bool = true
    @State private var minimumApprovalsForReadyToMerge: Int = 1
    @State private var notificationsEnabled: Bool = true
    @State private var ciStatusExcludeFilter: String = "review"
    @State private var pausePollingInLowPowerMode: Bool = true
    @State private var pausePollingOnExpensiveNetwork: Bool = true
    @State private var showMyReviewStatus: Bool = false
    @State private var automaticallyCheckForUpdates: Bool = true
    @State private var openAtCmuxFirst: Bool = false
    @State private var graphQLEndpoint: String = ""
    @State private var httpProxyURL: String = ""
    @State private var httpProxyUsername: String = ""
    @State private var httpProxyPassword: String = ""
    @State private var jiraServerURL: String = ""
    @State private var jiraConnectionTestState: JiraConnectionTestState = .idle
    @State private var jiraConnectionTestTask: Task<Void, Never>?
    @State private var showPATSwitchSheet = false
    @State private var newPATToken = ""
    @State private var showClearCacheConfirmation = false
    @State private var isTabRailCollapsed = false
    @State private var monitorEnabled: Bool = true
    @State private var notificationTargets: Set<DigestChannel> = [.macOS]
    @State private var notificationEventKinds: Set<PRActivityEventKind> = []
    @State private var notificationRepositories: String = ""
    @State private var slackBotToken: String = ""
    @State private var slackUserID: String = ""
    @State private var slackState: SlackSetupState = .idle
    @State private var slackTask: Task<Void, Never>?
    @State private var commentShortcuts: [CommentShortcut] = []

    private enum SlackSetupState: Equatable {
        case idle
        case verifying
        case connected(String)
        case failure(String)
    }

    private let refreshIntervalOptions: [(LocalizedStringKey, Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800)
    ]
    private enum JiraConnectionTestState: Equatable {
        case idle
        case testing
        case success(String?)
        case failure(String)
    }


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    save()
                }
                .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 0) {
                settingsTabRail
                Divider()
                settingsForm
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 688, height: 720)
        .onAppear {
            loadCurrentSettings()
        }
        .onDisappear {
            jiraConnectionTestTask?.cancel()
        }
        .sheet(isPresented: $showPATSwitchSheet) {
            patSwitchSheet
        }
    }

    private var settingsTabRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                settingsTabButton(tab)
            }
            Spacer(minLength: 0)
            tabRailCollapseButton
        }
        .padding(6)
        .frame(width: isTabRailCollapsed ? 44 : 168, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = navigation.tab == tab
        return Button {
            navigation.tab = tab
        } label: {
            settingsTabLabel(tab)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: isTabRailCollapsed ? .center : .leading)
                .padding(.horizontal, isTabRailCollapsed ? 4 : 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.title)
    }

    @ViewBuilder
    private func settingsTabLabel(_ tab: SettingsTab) -> some View {
        // iconOnly removes the title from layout. Narrowing the rail alone still
        // reserves the localized string and clips half a character in either language.
        if isTabRailCollapsed {
            Label(tab.title, systemImage: tab.symbol)
                .labelStyle(.iconOnly)
        } else {
            Label(tab.title, systemImage: tab.symbol)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var tabRailCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isTabRailCollapsed.toggle()
            }
        } label: {
            Image(systemName: isTabRailCollapsed ? "chevron.forward" : "chevron.backward")
                .frame(width: 18)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .accessibilityIdentifier("settings-tab-rail-toggle")
        .accessibilityLabel(isTabRailCollapsed ? Text("Show tab names") : Text("Hide tab names"))
        .accessibilityValue(isTabRailCollapsed ? Text("Collapsed") : Text("Expanded"))
        .help(isTabRailCollapsed ? Text("Show tab names") : Text("Hide tab names"))
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
            if viewModel.authState.isAuthenticated {
                HStack {
                    CachedAvatarView(
                        url: viewModel.authState.username.flatMap {
                            URL(string: "https://github.com/\($0).png?size=64")
                        },
                        authorInitial: viewModel.authState.username ?? "Signed in"
                    )
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.authState.username ?? "Signed in")
                            .font(.headline)

                        HStack(spacing: 4) {
                            Image(systemName: viewModel.authState.authMethod == .pat ? "key" : "person.badge.shield.checkmark")
                                .font(.system(size: 10))
                            Text(viewModel.authState.authMethod == .pat ? "Personal Access Token" : "GitHub OAuth")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Sign Out") {
                        viewModel.signOut()
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
                .padding(.vertical, 4)

                Divider()

                if viewModel.authState.authMethod == .pat {
                    Button("Switch to GitHub OAuth") {
                        viewModel.signOut()
                        viewModel.signIn()
                        dismiss()
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
                    viewModel.signIn()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }

        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }

            HStack {
                Toggle("Open PRs in cmux first", isOn: $openAtCmuxFirst)
                HelpHint("If the same PR is already open in cmux, switch to it and reload it. Otherwise, open the PR in your default browser.\n\nRequires cmux → Settings → Socket Control set to “Automation” (the default “cmux only” rejects connections from other apps).")
            }
        }

        Section("Refresh") {
            Picker("Refresh Interval", selection: $refreshInterval) {
                ForEach(refreshIntervalOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }

            Toggle("Refresh when opened", isOn: $refreshOnOpen)
        }

        Section("Power & Network") {
            Toggle("Pause background refresh in Low Power Mode", isOn: $pausePollingInLowPowerMode)
            Toggle("Pause background refresh on cellular/hotspot", isOn: $pausePollingOnExpensiveNetwork)
        }

        Section("Updates") {
            HStack {
                Text("Current version")
                Spacer()
                Text(currentVersionDescription)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Toggle("Automatically check for updates", isOn: $automaticallyCheckForUpdates)

            HStack {
                Button {
                    updateManager.checkForUpdates(userInitiated: true)
                } label: {
                    Label(updateCheckButtonTitle, systemImage: "arrow.clockwise")
                }
                .disabled(isUpdateBusy)

                if isUpdateCheckInProgress {
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
                TextField("", text: $repositories)
                    .labelsHidden()
                    .accessibilityLabel("Repositories (comma-separated, leave empty for all)")
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Show draft PRs", isOn: $showDrafts)

            Toggle("Show my review status badges", isOn: $showMyReviewStatus)

            HStack {
                Stepper(
                    "Minimum approvals for “Ready to merge”: \(minimumApprovalsForReadyToMerge)",
                    value: $minimumApprovalsForReadyToMerge,
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
                TextField("", text: $ciStatusExcludeFilter)
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
            Toggle("Enable notifications", isOn: $notificationsEnabled)
            Text("Notifications are digests of activity that needs your attention, not one alert per event.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Activity Monitoring") {
            Toggle("Monitor PR activity in the background", isOn: $monitorEnabled)
            Text("Collects reviews, comments, thread state, review requests and CI for PRs you author, review or comment on. It only runs while PR Dashboard is running; nothing is stored outside this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Deliver digests to")
                    .font(.caption)
                ForEach(DigestChannel.allCases, id: \.self) { channel in
                    Toggle(digestChannelTitle(channel), isOn: digestChannelBinding(channel))
                        .toggleStyle(.checkbox)
                }
            }

            Text("At most one digest every 30 minutes, and only when there is new work. Muting a PR or turning notifications off affects delivery only; activity keeps being collected.")
                .font(.caption)
                .foregroundColor(.secondary)

            DisclosureGroup("Event categories") {
                ForEach(PRActivityEventKind.allCases, id: \.self) { kind in
                    Toggle(PRActivityDigestFormatter.changeLabel(kind), isOn: eventKindBinding(kind))
                        .toggleStyle(.checkbox)
                }
            }

            TextField(
                "Only these repositories (empty = the PR list filter)",
                text: $notificationRepositories,
                prompt: Text("owner/repo")
            )
            .textFieldStyle(.roundedBorder)
        }

        Section("Slack Direct Message") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create a Slack app in your workspace with the chat:write, im:write and users:read scopes, install it, then paste its bot token and your own Slack user ID. ghpr only sends a direct message to you; it never posts to a channel.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SecureField("Bot token", text: $slackBotToken, prompt: Text("xoxb-…"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                TextField("Your Slack user ID", text: $slackUserID, prompt: Text("U0123ABCDEF"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)

                HStack(spacing: 8) {
                    Button {
                        verifySlackConnection()
                    } label: {
                        Label("Verify and Connect", systemImage: "checkmark.seal")
                    }
                    .disabled(slackState == .verifying
                              || slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || slackUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        sendSlackTestMessage()
                    } label: {
                        Label("Send test DM", systemImage: "paperplane")
                    }
                    .disabled(slackState == .verifying || !viewModel.configuration.isSlackDeliveryConfigured)

                    if slackState == .verifying {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                slackStatusView

                if viewModel.configuration.isSlackDeliveryConfigured {
                    HStack {
                        Text("Connected workspace")
                            .font(.caption)
                        Spacer()
                        Text("\(viewModel.configuration.slackWorkspaceName) · \(viewModel.configuration.slackUserID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var integrationSettings: some View {
        Section("Jira") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Jira server")
                    HelpHint("Jira Cloud server URL, for example https://company.atlassian.net. Email, API token, and connection testing are completed in the setup guide.")
                    Spacer()
                }
                TextField(
                    "",
                    text: $jiraServerURL,
                    prompt: Text("https://company.atlassian.net")
                )
                .labelsHidden()
                .accessibilityLabel("Jira server")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .onChange(of: jiraServerURL) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        jiraServerURL = trimmed
                    }
                    resetJiraConnectionTest()
                }

                if let jiraServerValidationMessage {
                    Label(jiraServerValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Button(jiraSetupButtonTitle) {
                openJiraSetupGuide()
            }
            .disabled(!canOpenJiraSetupGuide)
            HStack(spacing: 8) {
                Button {
                    testStoredJiraConnection()
                } label: {
                    Label("Test Connection", systemImage: "checkmark.seal")
                }
                .disabled(
                    !hasStoredJiraCredentials ||
                        jiraConnectionTestState == .testing
                )

                if jiraConnectionTestState == .testing {
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
            BrowserIntegrationView(controller: extensionPlatformController)
        }

        Section("Comment Shortcuts") {
            CommentShortcutSettingsSection(shortcuts: $commentShortcuts)
        }
    }

    @ViewBuilder
    private var advancedSettings: some View {
        Section("Developer Options") {
            Button("Show onboarding again") {
                onboardingManager.reset()
                dismiss()
            }

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
                    viewModel.clearCaches()
                    dismiss()
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
                    text: $graphQLEndpoint,
                    prompt: Text("https://example.com/graphql")
                )
                .labelsHidden()
                .accessibilityLabel("GraphQL endpoint override")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: graphQLEndpoint) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        graphQLEndpoint = trimmed
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
                    text: $httpProxyURL,
                    prompt: Text("http://proxy.example.com:8080")
                )
                .labelsHidden()
                .accessibilityLabel("HTTP proxy URL")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .onChange(of: httpProxyURL) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != newValue {
                        httpProxyURL = trimmed
                    }
                }

                TextField(
                    "",
                    text: $httpProxyUsername,
                    prompt: Text("Proxy username (optional)")
                )
                .labelsHidden()
                .accessibilityLabel("HTTP proxy username")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)

                SecureField(
                    "",
                    text: $httpProxyPassword,
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

            SecureField("Enter Personal Access Token", text: $newPATToken)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let error = viewModel.patError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showPATSwitchSheet = false
                    newPATToken = ""
                    viewModel.clearPATError()
                }
                .buttonStyle(.bordered)

                Button("Switch") {
                    viewModel.signOut()
                    viewModel.signInWithPAT(newPATToken)
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPATToken.isEmpty || viewModel.isValidatingPAT)
            }

            if viewModel.isValidatingPAT {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .frame(width: 350, height: 250)
        .padding()
        .onChange(of: viewModel.authState.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                showPATSwitchSheet = false
                newPATToken = ""
                dismiss()
            }
        }
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
        case .downloading:
            return "Downloading…"
        case .readyToInstall:
            return "Ready to Install"
        case .installing:
            return "Installing…"
        case .idle, .upToDate, .available, .unsupportedInstallLocation, .error:
            return "Check for Updates…"
        }
    }
    private var jiraSetupButtonTitle: LocalizedStringKey {
        switch viewModel.jiraConnectionState {
        case .notConfigured: return "Connect Jira…"
        case .unauthorized: return "Reconnect Jira…"
        case .configured: return "Guided Jira Setup…"
        }
    }
    private var normalizedJiraServerURL: String? {
        JiraAPIClient.normalizedServerURL(jiraServerURL)
    }

    private var jiraServerValidationMessage: String? {
        let trimmed = jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        presentationCoordinator != nil &&
            normalizedJiraServerURL != nil &&
            jiraServerValidationMessage == nil
    }
    private var hasStoredJiraCredentials: Bool {
        viewModel.jiraConnectionState != .notConfigured &&
            jiraServerValidationMessage == nil &&
            normalizedJiraServerURL != nil
    }

    @ViewBuilder
    private var jiraConnectionTestResultView: some View {
        switch jiraConnectionTestState {
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

    private func testStoredJiraConnection() {
        guard let normalizedJiraServerURL else { return }
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

    private func openJiraSetupGuide() {
        guard let normalizedJiraServerURL,
              JiraAPIClient.isSupportedCloudServerURL(normalizedJiraServerURL)
        else { return }
        jiraServerURL = normalizedJiraServerURL
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
        case .checking, .downloading, .readyToInstall, .installing:
            return true
        case .idle, .upToDate, .available, .unsupportedInstallLocation, .error:
            return false
        }
    }

    private func loadCurrentSettings() {
        let config = viewModel.configuration
        refreshInterval = config.refreshInterval
        refreshOnOpen = config.refreshOnOpen
        repositories = config.repositories.joined(separator: ", ")
        showDrafts = config.showDrafts
        minimumApprovalsForReadyToMerge = config.minimumApprovalsForReadyToMerge
        notificationsEnabled = config.notificationsEnabled
        ciStatusExcludeFilter = config.ciStatusExcludeFilter
        pausePollingInLowPowerMode = config.pausePollingInLowPowerMode
        pausePollingOnExpensiveNetwork = config.pausePollingOnExpensiveNetwork
        showMyReviewStatus = config.showMyReviewStatus
        automaticallyCheckForUpdates = config.automaticallyCheckForUpdates
        openAtCmuxFirst = config.openAtCmuxFirst
        graphQLEndpoint = config.graphQLEndpoint
        httpProxyURL = config.httpProxyURL
        httpProxyUsername = config.httpProxyUsername
        httpProxyPassword = Keychain.loadProxyPassword()
        jiraServerURL = config.jiraServerURL
        monitorEnabled = config.monitorEnabled
        notificationTargets = Set(config.digestChannels)
        notificationEventKinds = config.notificationEventKindFilter
        notificationRepositories = config.notificationRepositories.joined(separator: ", ")
        slackBotToken = Keychain.loadSlackBotToken()
        slackUserID = config.slackUserID
        commentShortcuts = config.commentShortcuts
        slackState = config.isSlackDeliveryConfigured
            ? .connected(config.slackWorkspaceName)
            : .idle
    }

    private func digestChannelTitle(_ channel: DigestChannel) -> String {
        switch channel {
        case .macOS: return String(localized: "macOS notification")
        case .slack: return String(localized: "Slack direct message")
        }
    }

    private func digestChannelBinding(_ channel: DigestChannel) -> Binding<Bool> {
        Binding(
            get: { notificationTargets.contains(channel) },
            set: { isOn in
                var updated = notificationTargets
                if isOn {
                    updated.insert(channel)
                } else {
                    // At least one delivery target has to stay selected, otherwise a
                    // digest could never be delivered.
                    guard updated.count > 1 else { return }
                    updated.remove(channel)
                }
                notificationTargets = updated
            }
        )
    }

    private func eventKindBinding(_ kind: PRActivityEventKind) -> Binding<Bool> {
        Binding(
            get: {
                let filter = notificationEventKinds
                return filter.isEmpty || filter.contains(kind)
            },
            set: { isOn in
                var filter = notificationEventKinds
                if filter.isEmpty {
                    // Empty means "all categories"; materialize it before removing one.
                    filter = Set(PRActivityEventKind.allCases)
                }
                if isOn {
                    filter.insert(kind)
                } else {
                    guard filter.count > 1 else { return }
                    filter.remove(kind)
                }
                notificationEventKinds = filter == Set(PRActivityEventKind.allCases) ? [] : filter
            }
        )
    }

    private var slackStatusView: some View {
        Group {
            switch slackState {
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

    private func verifySlackConnection() {
        let token = slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    slackState = .failure(message)
                case .keepExistingConnection:
                    slackState = .failure(message)
                }
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
                slackState = .connected(configuration.slackWorkspaceName)
            } catch {
                slackState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }


    private struct HelpHint: View {
        let text: String
        @State private var isShown = false
        @State private var hoverTask: Task<Void, Never>?

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Image(systemName: "questionmark.circle")
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
                }
        }
    }

    private func save() {
        let repos = repositories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmedProxyURL = httpProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProxyUsername = httpProxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJiraServerURL = jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build config carrying current (pre-save) Jira fields; updateJiraCredentials
        // overwrites them atomically below so cache invalidation + refresh fire once.
        let existingJira = viewModel.configuration
        let config = Configuration(
            refreshInterval: refreshInterval,
            repositories: repos,
            showDrafts: showDrafts,
            minimumApprovalsForReadyToMerge: minimumApprovalsForReadyToMerge,
            notificationsEnabled: notificationsEnabled,
            refreshOnOpen: refreshOnOpen,
            ciStatusExcludeFilter: ciStatusExcludeFilter,
            pausePollingInLowPowerMode: pausePollingInLowPowerMode,
            pausePollingOnExpensiveNetwork: pausePollingOnExpensiveNetwork,
            showMyReviewStatus: showMyReviewStatus,
            automaticallyCheckForUpdates: automaticallyCheckForUpdates,
            openAtCmuxFirst: openAtCmuxFirst,
            graphQLEndpoint: graphQLEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            httpProxyURL: trimmedProxyURL,
            httpProxyUsername: trimmedProxyUsername,
            jiraServerURL: existingJira.jiraServerURL,
            jiraEmail: existingJira.jiraEmail,
            jiraRefreshInterval: existingJira.jiraRefreshInterval,
            monitorEnabled: monitorEnabled,
            notificationTargets: notificationTargets.map(\.rawValue).sorted(),
            notificationEventKinds: notificationEventKinds.map(\.rawValue).sorted(),
            notificationRepositories: notificationRepositories
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            slackEnabled: existingJira.slackEnabled,
            slackWorkspaceName: existingJira.slackWorkspaceName,
            slackWorkspaceID: existingJira.slackWorkspaceID,
            slackUserID: existingJira.slackUserID,
            slackDMChannelID: existingJira.slackDMChannelID,
            commentShortcuts: commentShortcuts
        )

        if trimmedProxyURL.isEmpty {
            Keychain.deleteProxyPassword()
        } else {
            Keychain.saveProxyPassword(httpProxyPassword)
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
