import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var oauthManager: GitHubOAuthManager?
    var prManager: PRManager?
    var notificationManager: NotificationManager?
    var prLinkOpener: PRLinkOpener?
    var onboardingManager: OnboardingManager?
    var updateManager: UpdateManager?
    var localSocketServer: LocalSocketServer?
    var settingsWindow: NSWindow?
    var updateWindow: NSWindow?
    var jiraSetupWindow: NSWindow?
    var activityWindow: NSWindow?
    /// Activity or Settings switched this menu-bar app to a regular Dock icon.
    /// Closing the last of those windows restores the menu-bar-only policy.
    private var promotedDockIcon = false
    /// Bumped when a Dock window opens, so an earlier close cannot hide the icon after a reopen.
    private var dockPromotionGeneration = 0
    var viewModel: PRListViewModel?
    var jiraSetupCoordinator: JiraSetupCoordinator?
    var presentationCoordinator: AppPresentationCoordinator?
    let settingsNavigation = SettingsNavigation()
    let activityNavigation = ActivityNavigation()
    var extensionPlatformController: ExtensionPlatformController?
    let panelInteraction = PanelInteractionCoordinator()
    #if DEBUG
    private var uiuxFixtureHost: UIUXFixtureHost?
    #endif
    var browserPairingWindow: NSWindow?
    var extensionPlatformUITestWindow: NSWindow?
    private var jiraClient: JiraAPIClient?
    private var cancellables = Set<AnyCancellable>()



    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-testing-uiux") {
            let host = UIUXFixtureHost()
            uiuxFixtureHost = host
            host.start()
            return
        }
        #endif
        let isExtensionPlatformUITest = CommandLine.arguments.contains {
            $0.hasPrefix("--ui-testing-browser-")
        }
        // Smoke runs use an isolated activity store and install no delivery channel,
        // so observing the monitor never touches real history or sends notifications.
        let isActivitySmokeTest = CommandLine.arguments.contains("--ui-testing-activity-store")

        // 1. Create OAuth manager (loads saved auth automatically outside deterministic UI tests)
        oauthManager = GitHubOAuthManager(loadSavedAuth: !isExtensionPlatformUITest && !isActivitySmokeTest)

        // 2. Create notification manager and request permission
        notificationManager = NotificationManager()
        let jiraClient = JiraAPIClient()
        self.jiraClient = jiraClient
        // 3. Create API client
        let apiClient = GitHubAPIClient(token: oauthManager?.authState.accessToken ?? "")

        // 4. Create PR manager
        prManager = PRManager(
            apiClient: apiClient,
            jiraClient: jiraClient,
            notificationManager: notificationManager!,
            oauthManager: oauthManager!,
            cmuxStatusProvider: CmuxBrowserRouter(),
            loadKeychainSecrets: !isExtensionPlatformUITest,
            activityMonitor: isActivitySmokeTest
                ? PRActivityMonitor(
                    store: PRActivityStore(directoryURL: Self.activitySmokeStoreURL()),
                    configuration: .default
                )
                : nil
        )
        updateManager = UpdateManager(configuration: prManager!.configuration)
        updateManager?.onRequestPresentation = { [weak self] in
            self?.openUpdateWindow()
        }
        prLinkOpener = PRLinkOpener(configurationProvider: { [weak self] in
            self?.prManager?.configuration ?? .default
        })
        notificationManager?.openURL = { [weak self] url in
            Task { @MainActor in
                await self?.prLinkOpener?.open(url)
            }
        }
        // Digest channels are installed below and rebuilt whenever configuration
        // (proxy, Slack binding) changes.
        configureActivityChannels()
        notificationManager?.openActivity = { [weak self] batchID in
            self?.openActivityWindow(digestBatchID: batchID)
        }

        // 4.1 Load cached PR data for immediate display
        // 5. Create view model
        let viewModel = PRListViewModel(
            prManager: prManager!,
            oauthManager: oauthManager!,
            linkOpener: prLinkOpener!
        )
        self.viewModel = viewModel
        onboardingManager = OnboardingManager()

        presentationCoordinator = AppPresentationCoordinator { [weak self, weak viewModel] presentation in
            guard let self, let viewModel else { return }
            switch presentation {
            case .settings(let tab):
                self.openSettingsWindow(viewModel: viewModel, tab: tab)
            case .jiraSetup(let context):
                self.openJiraSetupWindow(context: context, viewModel: viewModel)
            }
        }

        viewModel.openSettings = { [weak self] in
            self?.presentationCoordinator?.present(.settings(.general))
        }

        viewModel.openActivity = { [weak self] in
            self?.openActivityWindow()
        }

        #if DEBUG
        if isActivitySmokeTest,
           let token = ProcessInfo.processInfo.environment["GHPR_SMOKE_TOKEN"],
           !token.isEmpty {
            oauthManager?.applySmokeAuth(
                token: token,
                username: ProcessInfo.processInfo.environment["GHPR_SMOKE_USERNAME"]
            )
        }
        #endif

        let isPRActionsUITest = CommandLine.arguments.contains("--ui-testing-browser-pr-actions") ||
            CommandLine.arguments.contains("--ui-testing-browser-pr-actions-passing")
        let extensionPlatformController = ExtensionPlatformController(
            snapshotProvider: { [weak self] in
#if DEBUG
                if isPRActionsUITest {
                    return ExtensionPlatformUITestFixture.snapshot(
                        hasFailedCI: CommandLine.arguments.contains("--ui-testing-browser-pr-actions")
                    )
                }
#endif
                return AppDelegate.makeLocalSnapshot(
                    oauthManager: self?.oauthManager,
                    prManager: self?.prManager
                )
            },
            rerunFailedJobs: { [weak self] snapshot in
                guard let self,
                      let pr = self.prManager?.prList.allPRs.first(where: {
                          $0.repoFullName.caseInsensitiveCompare(snapshot.repository) == .orderedSame &&
                              $0.number == snapshot.number
                      }),
                      let prManager = self.prManager else {
                    throw BrowserBridgeActionError.pullRequestUnavailable
                }
                return try await prManager.rerunFailedCI(for: pr).rerunCount
            },
            commentShortcut: { [weak self] request in
                guard let prManager = self?.prManager else {
                    throw CommentShortcutPreparationError.shortcutUnavailable
                }
                return try await prManager.prepareCommentShortcut(request)
            },
            commentShortcutCatalog: { [weak self] in
                self?.prManager?.commentShortcutCatalog() ?? []
            },
            storageURL: isExtensionPlatformUITest ? nil : defaultExtensionPlatformStorageURL(),
            appVersion: Self.appInfoValue("CFBundleShortVersionString"),
            ports: isExtensionPlatformUITest ? [0] : Array(48120...48129)
        )
        self.extensionPlatformController = extensionPlatformController
#if DEBUG
        if CommandLine.arguments.contains("--ui-testing-browser-settings") {
            ExtensionPlatformUITestFixture.seedSurfaceHealth(in: extensionPlatformController.store)
        }
#endif

        // 6. Create main view
        let mainView = MainView(
            viewModel: viewModel,
            onboardingManager: onboardingManager!,
            presentationCoordinator: presentationCoordinator,
            extensionPlatformController: extensionPlatformController,
            interaction: panelInteraction
        )

        // 7. Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: mainView)
        // The panel grows downward inside whatever the window top leaves.
        panelInteraction.bind(popover: popover)

        // 8. Create status bar controller
        statusBarController = StatusBarController(
            popover: popover,
            onWillShow: { [weak self] in
                self?.prManager?.enablePolling(true)
                self?.panelInteraction.prepareForPresentation(
                    keyboard: self?.statusBarController?.openingFromKeyboard == true
                )
                self?.panelInteraction.setPresented(true)
            },
            onWillClose: { [weak self] in
                self?.panelInteraction.setPresented(false)
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(userInitiated: true)
            }
        )
        panelInteraction.onRequestClose = { [weak self] in
            guard let statusBar = self?.statusBarController else { return }
            statusBar.hidePopover(statusBar, restoringFocus: true)
        }

        // Observe PR list changes to update menu bar notification badge
        prManager?.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.statusBarController?.updateBadge(prList: prList)
            }
            .store(in: &cancellables)

        prManager?.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in
                self?.updateManager?.updateConfiguration(configuration)
                // The Slack session follows the proxy preference, so channels are
                // rebuilt whenever configuration changes.
                self?.configureActivityChannels()
            }
            .store(in: &cancellables)

        localSocketServer = LocalSocketServer(
            snapshotProvider: { [weak self] in
                AppDelegate.makeLocalSnapshot(
                    oauthManager: self?.oauthManager,
                    prManager: self?.prManager
                )
            },
            reviewImporter: { [weak extensionPlatformController] repository, number, payload in
                guard let extensionPlatformController else {
                    throw CocoaError(.featureUnsupported)
                }
                return try extensionPlatformController.importReview(
                    repository: repository,
                    number: number,
                    payload: payload
                )
            }
        )
        localSocketServer?.start()
        extensionPlatformController.onPendingPairing = { [weak self] approval in
            self?.openBrowserPairingWindow(approval: approval)
        }
        extensionPlatformController.start()

        // 10. Request notification permission if authenticated
        if oauthManager?.authState.isAuthenticated == true {
            notificationManager?.requestPermission()
            // Monitoring starts with the app, not with the popover: a saved sign-in is
            // enough to observe PR activity in the background.
            prManager?.startActivityMonitoring()
        }

        // 11. Request notification permission after sign-in
        oauthManager?.$authState
            .dropFirst()  // Skip initial value
            .filter { $0.isAuthenticated }
            .sink { [weak self] _ in
                self?.notificationManager?.requestPermission()
            }
            .store(in: &cancellables)

        updateManager?.start()

        configureExtensionPlatformUITestIfRequested(viewModel: viewModel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        localSocketServer?.stop()
        localSocketServer = nil
        extensionPlatformController?.stop()
        extensionPlatformController = nil
    }
    private func configureExtensionPlatformUITestIfRequested(viewModel: PRListViewModel) {
        guard let extensionPlatformController else { return }
        if CommandLine.arguments.contains("--ui-testing-browser-settings") {
            for client in extensionPlatformController.store.pairedClients {
                extensionPlatformController.store.revokeClient(id: client.id)
            }
            let descriptor = BrowserClientDescriptor(
                id: "dev.ghpr.ui-test-client",
                name: "UI Test Client",
                version: "1.0.0",
                requestedScopes: [.prRead, .analysisRead]
            )
            if let pairing = try? extensionPlatformController.store.startPairing(
                descriptor: descriptor,
                bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
            ) {
                _ = try? extensionPlatformController.store.approvePairingFromNative(
                    id: pairing.requestID,
                    approvedScopes: descriptor.requestedScopes
                )
            }
            browserPairingWindow?.close()
            browserPairingWindow = nil
            presentationCoordinator?.present(.settings(.integrations))
        } else if CommandLine.arguments.contains("--ui-testing-browser-pairing") ||
            CommandLine.arguments.contains("--ui-testing-browser-permission-upgrade") {
            let isUpgrade = CommandLine.arguments.contains("--ui-testing-browser-permission-upgrade")
            let descriptor = BrowserClientDescriptor(
                id: "com.example.team-ci-helper",
                name: "Team CI Helper",
                version: "1.2.0",
                requestedScopes: [
                    .prRead,
                    .analysisRead,
                    .uiContribute,
                    .skillRun
                ],
                requiredScopes: isUpgrade ? [.skillRun] : []
            )
            _ = try? extensionPlatformController.store.startPairing(
                descriptor: descriptor,
                bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
            )
        }
#if DEBUG
        let hasFailedCI = CommandLine.arguments.contains("--ui-testing-browser-pr-actions")
        let simulateMenuUpdate = CommandLine.arguments.contains(
            "--ui-testing-browser-pr-actions-updating"
        )
        let hasPassingCI = CommandLine.arguments.contains("--ui-testing-browser-pr-actions-passing") ||
            simulateMenuUpdate
        if hasFailedCI || hasPassingCI {
            openExtensionPlatformUITestWindow(
                controller: extensionPlatformController,
                hasFailedCI: hasFailedCI,
                simulateMenuUpdate: simulateMenuUpdate
            )
        }
#endif
    }

#if DEBUG
    private func openExtensionPlatformUITestWindow(
        controller: ExtensionPlatformController,
        hasFailedCI: Bool,
        simulateMenuUpdate: Bool
    ) {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: ExtensionPlatformPRActionsUITestView(
                    controller: controller,
                    hasFailedCI: hasFailedCI
                )
            )
        )
        window.title = "PR Actions"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 190))
        window.center()
        extensionPlatformUITestWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard simulateMenuUpdate else { return }
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .compactMap { $0.object as? NSMenu }
            .filter { menu in
                menu.items.contains { $0.title == "Run Skill" }
            }
            .prefix(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller, weak window] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let controller else { return }
                    let pr = ExtensionPlatformUITestFixture.passingPullRequest
                    controller.store.setTag(
                        .needsInvestigation,
                        pageKey: GitHubPageContext.pullRequest(
                            repository: pr.repoFullName,
                            number: pr.number
                        ).key,
                        clientID: nil
                    )
                    window?.title = "PR Actions Updated"
                }
            }
            .store(in: &cancellables)
    }
#endif

    private func openJiraSetupWindow(context: JiraSetupContext, viewModel: PRListViewModel) {
        if let jiraSetupWindow {
            jiraSetupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let jiraClient else { return }
        let config = viewModel.configuration
        let initialServerURL = context.initialServerURL ?? config.jiraServerURL
        let coordinator = JiraSetupCoordinator(
            context: context,
            connectionState: viewModel.jiraConnectionState,
            savedServerURL: initialServerURL,
            savedEmail: config.jiraEmail,
            savedAPIToken: Keychain.loadJiraAPIToken(),
            testConnection: { serverURL, email, token in
                try await jiraClient.testConnection(serverURL: serverURL, email: email, apiToken: token)
            },
            commit: { [weak viewModel] serverURL, email, token in
                viewModel?.updateJiraCredentials(
                    serverURL: serverURL,
                    email: email,
                    apiToken: token,
                    refreshInterval: viewModel?.configuration.jiraRefreshInterval ?? 1800
                )
            },
            openExternalURL: { url in
                NSWorkspace.shared.open(url)
            },
            dismiss: { [weak self] in
                self?.jiraSetupWindow?.close()
                self?.jiraSetupWindow = nil
                self?.jiraSetupCoordinator = nil
            }
        )
        jiraSetupCoordinator = coordinator
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: JiraSetupView(coordinator: coordinator))
        )
        window.title = String(localized: "Connect Jira")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        jiraSetupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func activitySmokeStoreURL() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-activity-smoke", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func openActivityWindow(digestBatchID: String? = nil) {
        guard let viewModel else { return }
        activityNavigation.digestBatchID = digestBatchID
        promoteDockIcon()

        if activityWindow == nil {
            let hostingController = NSHostingController(rootView: PRActivityView(viewModel: viewModel, navigation: activityNavigation))
            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Activity")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 560))
            window.minSize = NSSize(width: 520, height: 420)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            activityWindow = window
        }

        if activityWindow?.isMiniaturized == true {
            activityWindow?.deminiaturize(nil)
        }
        activityWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu-bar apps have no Dock icon. Activity and Settings are real windows, so they share one until the last closes.
    private func promoteDockIcon() {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-testing-browser-") }) {
            return
        }
        dockPromotionGeneration &+= 1
        guard NSApp.activationPolicy() != .regular else { return }
        guard NSApp.setActivationPolicy(.regular) else { return }
        promotedDockIcon = true
        NSApp.unhide(nil)
    }

    private func scheduleDockIconRestore() {
        let generation = dockPromotionGeneration
        // Let the close finish before dropping the Dock icon; changing policy mid-close can cancel it.
        DispatchQueue.main.async { [weak self] in
            self?.restoreMenuBarIfIdle(generation: generation)
        }
    }

    private func restoreMenuBarIfIdle(generation: Int) {
        guard promotedDockIcon, generation == dockPromotionGeneration else { return }
        if keepsDockIcon(activityWindow) || keepsDockIcon(settingsWindow) {
            return
        }
        promotedDockIcon = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func keepsDockIcon(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// Installs the digest channels. Rebuilt on configuration changes so the Slack
    /// session picks up proxy and binding changes instead of staying stale.
    private func configureActivityChannels() {
        guard let notificationManager, let prManager else { return }
        if CommandLine.arguments.contains("--ui-testing-activity-store") {
            // Smoke runs collect activity but never deliver it.
            prManager.activityMonitor.setChannels([])
            return
        }
        let configuration = prManager.configuration
        let slackClient = SlackNotificationClient(
            proxy: GitHubAPIClient.resolvedProxyConfig(
                urlString: configuration.httpProxyURL,
                username: configuration.httpProxyUsername,
                password: Keychain.loadProxyPassword()
            )
        )
        prManager.activityMonitor.setChannels([
            MacOSActivityDigestChannel(notificationManager: notificationManager),
            SlackActivityDigestChannel(
                client: slackClient,
                configurationProvider: { [weak self] in
                    self?.prManager?.configuration ?? .default
                }
            ),
        ])
    }

    private func openSettingsWindow(viewModel: PRListViewModel, tab: SettingsTab) {
        guard let onboardingManager,
              let updateManager,
              let extensionPlatformController else {
            return
        }

        promoteDockIcon()

        if settingsWindow == nil {
            let settingsView = SettingsView(
                viewModel: viewModel,
                onboardingManager: onboardingManager,
                updateManager: updateManager,
                extensionPlatformController: extensionPlatformController,
                navigation: settingsNavigation,
                presentationCoordinator: presentationCoordinator
            )
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height))
            window.contentMinSize = NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }

        settingsNavigation.tab = tab
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openBrowserPairingWindow(approval: PendingPairingApproval) {
        browserPairingWindow?.close()

        let pairingView = BrowserPairingApprovalView(
            controller: extensionPlatformController!,
            approval: approval
        ) { [weak self] in
            self?.browserPairingWindow?.close()
            self?.browserPairingWindow = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Browser Client Permission")
        window.contentViewController = NSHostingController(rootView: pairingView)
        window.center()
        window.isReleasedWhenClosed = false
        browserPairingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openUpdateWindow() {
        guard let updateManager else { return }

        if updateWindow == nil {
            let updateView = UpdateView(updateManager: updateManager)
            let hostingController = NSHostingController(rootView: updateView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Software Update")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.center()
            updateWindow = window
        }

        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            openUpdateWindow()
        }

        updateManager?.checkForUpdates(userInitiated: userInitiated)
    }

    private static func makeLocalSnapshot(
        oauthManager: GitHubOAuthManager?,
        prManager: PRManager?
    ) -> LocalSnapshot {
        let refreshStatus: String
        let refreshError: String?
        switch prManager?.refreshState ?? .idle {
        case .idle:
            refreshStatus = "idle"
            refreshError = prManager?.prList.error?.localizedDescription
        case .loading:
            refreshStatus = "loading"
            refreshError = nil
        case .error(let error):
            refreshStatus = "error"
            refreshError = error.localizedDescription
        }

        return LocalSnapshotFactory.makeSnapshot(
            input: LocalSnapshotInput(
                appVersion: appInfoValue("CFBundleShortVersionString"),
                buildVersion: appInfoValue("CFBundleVersion"),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                authState: oauthManager?.authState ?? .empty,
                prList: prManager?.prList ?? .empty,
                rateLimitInfo: prManager?.rateLimitInfo ?? .empty,
                pinnedPRIdentifiers: prManager?.pinnedPRIdentifiers ?? [],
                minimumApprovalsForReadyToMerge: prManager?.configuration.minimumApprovalsForReadyToMerge ??
                    Configuration.default.minimumApprovalsForReadyToMerge,
                refreshStatus: refreshStatus,
                refreshError: refreshError
            )
        )
    }

    private static func appInfoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}

@MainActor
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === jiraSetupWindow {
            jiraSetupWindow = nil
            jiraSetupCoordinator = nil
            // The red button must not reuse the coordinator.
            return
        }
        if window === activityWindow {
            activityWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else {
            return
        }
        // Do not treat isMiniaturized here as still-open. This callback can run while that flag is still true.
        scheduleDockIconRestore()
    }

    @objc func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard promotedDockIcon else { return true }
        if activityWindow != nil {
            openActivityWindow()
        } else if settingsWindow != nil, let viewModel {
            openSettingsWindow(viewModel: viewModel, tab: settingsNavigation.tab)
        } else {
            openActivityWindow()
        }
        return false
    }
}

#if DEBUG
private enum ExtensionPlatformUITestFixture {
    static let pullRequest = makePullRequest(hasFailedCI: true)
    static let passingPullRequest = makePullRequest(hasFailedCI: false)
    @MainActor
    static func seedSurfaceHealth(in store: ExtensionPlatformStore) {
        store.reportSurfaceHealth(
            surface: BrowserSurfaceV2.checksJobTrailing.rawValue,
            state: .missing,
            detail: "UI fixture: exact Checks job anchor missing"
        )
        store.reportSurfaceHealth(
            surface: BrowserSurfaceV2.actionsJobAfterFailureSummary.rawValue,
            state: .ambiguous,
            detail: "UI fixture: multiple Actions failure summaries matched"
        )
    }


    private static func makePullRequest(hasFailedCI: Bool) -> PullRequest {
        PullRequest(
            id: 1238,
            number: 1238,
            title: hasFailedCI ? "UI fixture failed check" : "UI fixture passing checks",
            author: "octocat",
            authorAvatarURL: nil,
            repositoryOwner: "example-org",
            repositoryName: "example-repo",
            url: URL(string: "https://github.com/example-org/example-repo/pull/1238")!,
            state: .open,
            isDraft: false,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_100),
            mergedAt: nil,
            body: nil,
            conversationComments: [],
            lastCommitAt: Date(timeIntervalSince1970: 1_775_000_100),
            headCommitOid: "0123456789abcdef",
            reviewThreads: [],
            category: .authored,
            hasBaseConflicts: false,
            ciStatus: hasFailedCI ? .failure : .success,
            checkSuccessCount: hasFailedCI ? 3 : 4,
            checkFailureCount: hasFailedCI ? 1 : 0,
            checkPendingCount: 0,
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: true,
            approvalCount: 2,
            changesRequestedCount: 0,
            ciExtendedInfo: CIExtendedInfo(
                isRunning: false,
                workflows: [
                    CIWorkflowInfo(
                        name: "unit-test",
                        isWorkflow: true,
                        successCount: hasFailedCI ? 3 : 4,
                        failureCount: hasFailedCI ? 1 : 0,
                        pendingCount: 0
                    )
                ]
            )
        )
    }

    static func snapshot(hasFailedCI: Bool) -> LocalSnapshot {
        let fixture = hasFailedCI ? pullRequest : passingPullRequest
        return LocalSnapshotFactory.makeSnapshot(
            input: LocalSnapshotInput(
                appVersion: "1.0.0",
                buildVersion: "1",
                bundleIdentifier: "com.example.ghpr-ui-test",
                authState: AuthState(accessToken: nil, username: "octocat", authMethod: nil),
                prList: PRList(
                    lastUpdated: Date(timeIntervalSince1970: 1_775_000_100),
                    pullRequests: [fixture],
                    isLoading: false,
                    error: nil
                ),
                rateLimitInfo: RateLimitInfo(
                    limit: 5_000,
                    remaining: 4_999,
                    resetDate: Date(timeIntervalSince1970: 1_775_003_600)
                ),
                pinnedPRIdentifiers: [],
                minimumApprovalsForReadyToMerge: 2,
                refreshStatus: "idle",
                refreshError: nil
            ),
            now: Date(timeIntervalSince1970: 1_775_000_100)
        )
    }
}

@MainActor
private struct ExtensionPlatformPRActionsUITestView: View {
    @ObservedObject var controller: ExtensionPlatformController
    let hasFailedCI: Bool

    private var pullRequest: PullRequest {
        hasFailedCI
            ? ExtensionPlatformUITestFixture.pullRequest
            : ExtensionPlatformUITestFixture.passingPullRequest
    }

    private var latestRun: SkillRun? {
        controller.store.runs(
            pageKey: GitHubPageContext.pullRequest(
                repository: pullRequest.repoFullName,
                number: pullRequest.number
            ).key
        ).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PR Actions")
                .font(.headline)
            PRRowView(
                pr: pullRequest,
                onOpen: {},
                onOpenJira: { _ in },
                onCopyURL: {},
                onRerunFailedCI: {},
                onAnalyzeCIFailure: {},
                onOpenRawDiagnostics: {},
                onRunSkill: { skillID in
                    Task { @MainActor in
                        _ = try? await controller.runRevisionSkill(
                            id: skillID,
                            repository: pullRequest.repoFullName,
                            number: pullRequest.number
                        )
                    }
                },
                onInstallBrowserUserscript: {},
                runnableSkills: controller.runnableRevisionSkills(),
                extensionRun: controller.activeRun(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                ),
                extensionAnalysis: controller.latestAnalysis(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                ),
                extensionTags: controller.tags(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                )
            )
            Text("Tags: \(controller.tags(repository: pullRequest.repoFullName, number: pullRequest.number).map(\.displayName).sorted().joined(separator: ", "))")
                .accessibilityIdentifier("pr-action-tags")
            Text(
                "Analysis: \(controller.latestAnalysis(repository: pullRequest.repoFullName, number: pullRequest.number)?.verdict.displayName ?? "None")"
            )
            .accessibilityIdentifier("pr-action-analysis")
            Text("Last run: \(latestRun?.status.displayName ?? "None")")
                .accessibilityIdentifier("pr-action-last-run")
        }
        .padding()
        .frame(width: 420, height: 190)
    }
}
#endif
