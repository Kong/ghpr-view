import Foundation

struct Configuration: Codable, Equatable {
    var refreshInterval: TimeInterval  // seconds, minimum 15
    var repositories: [String]         // ["owner/repo", ...] - empty means all
    var showDrafts: Bool
    var minimumApprovalsForReadyToMerge: Int
    var notificationsEnabled: Bool
    var refreshOnOpen: Bool            // refresh immediately when popover opens
    var ciStatusExcludeFilter: String  // keywords to exclude from CI status (e.g., "review")
    var pausePollingInLowPowerMode: Bool  // pause background polling when Low Power Mode is enabled
    var pausePollingOnExpensiveNetwork: Bool  // pause background polling on cellular/hotspot
    var showMyReviewStatus: Bool  // show my review status badges on review-requested PRs
    var automaticallyCheckForUpdates: Bool
    var openAtCmuxFirst: Bool  // switch to an existing cmux PR browser tab before falling back to the default browser
    var graphQLEndpoint: String  // developer override for GitHub GraphQL URL; empty = default
    var httpProxyURL: String     // e.g. "http://host:port"; empty = no proxy
    var httpProxyUsername: String  // empty = no auth; password stored in the credential store
    var jiraServerURL: String    // e.g. "https://company.atlassian.net"; empty = disabled
    var jiraEmail: String        // Atlassian account email; token stored in the credential store
    var jiraRefreshInterval: TimeInterval  // seconds
    var monitorEnabled: Bool             // run the local PR activity monitor
    var notificationTargets: [String]    // DigestChannel raw values; default macOS only
    var notificationEventKinds: [String] // PRActivityEventKind raw values; empty = defaults
    var notificationRepositories: [String]  // ["owner/repo", ...] - empty means all repos
    var slackEnabled: Bool               // Slack DM digest enabled (token lives in the credential store)
    var slackWorkspaceName: String       // display only, verified through auth.test
    var slackWorkspaceID: String
    var slackUserID: String              // recipient Slack user ID (DM target)
    var slackDMChannelID: String         // resolved through conversations.open
    var commentShortcuts: [CommentShortcut]  // user-defined comment templates; empty by default

    static var `default`: Configuration {
        Configuration(
            refreshInterval: 300,  // 5 minutes
            repositories: [],
            showDrafts: true,
            minimumApprovalsForReadyToMerge: 1,
            notificationsEnabled: true,
            refreshOnOpen: false,
            ciStatusExcludeFilter: "review",
            pausePollingInLowPowerMode: true,
            pausePollingOnExpensiveNetwork: true,
            showMyReviewStatus: false,
            automaticallyCheckForUpdates: true,
            openAtCmuxFirst: false,
            graphQLEndpoint: "",
            httpProxyURL: "",
            httpProxyUsername: "",
            jiraServerURL: "",
            jiraEmail: "",
            jiraRefreshInterval: 1800,
            monitorEnabled: true,
            notificationTargets: [DigestChannel.macOS.rawValue],
            notificationEventKinds: [],
            notificationRepositories: [],
            slackEnabled: false,
            slackWorkspaceName: "",
            slackWorkspaceID: "",
            slackUserID: "",
            slackDMChannelID: "",
            commentShortcuts: []
        )
    }

    init(
        refreshInterval: TimeInterval,
        repositories: [String],
        showDrafts: Bool,
        minimumApprovalsForReadyToMerge: Int,
        notificationsEnabled: Bool,
        refreshOnOpen: Bool,
        ciStatusExcludeFilter: String,
        pausePollingInLowPowerMode: Bool,
        pausePollingOnExpensiveNetwork: Bool,
        showMyReviewStatus: Bool,
        automaticallyCheckForUpdates: Bool,
        openAtCmuxFirst: Bool,
        graphQLEndpoint: String,
        httpProxyURL: String,
        httpProxyUsername: String,
        jiraServerURL: String,
        jiraEmail: String,
        jiraRefreshInterval: TimeInterval,
        monitorEnabled: Bool = true,
        notificationTargets: [String] = [DigestChannel.macOS.rawValue],
        notificationEventKinds: [String] = [],
        notificationRepositories: [String] = [],
        slackEnabled: Bool = false,
        slackWorkspaceName: String = "",
        slackWorkspaceID: String = "",
        slackUserID: String = "",
        slackDMChannelID: String = "",
        commentShortcuts: [CommentShortcut] = []
    ) {
        self.refreshInterval = refreshInterval
        self.repositories = repositories
        self.showDrafts = showDrafts
        self.minimumApprovalsForReadyToMerge = minimumApprovalsForReadyToMerge
        self.notificationsEnabled = notificationsEnabled
        self.refreshOnOpen = refreshOnOpen
        self.ciStatusExcludeFilter = ciStatusExcludeFilter
        self.pausePollingInLowPowerMode = pausePollingInLowPowerMode
        self.pausePollingOnExpensiveNetwork = pausePollingOnExpensiveNetwork
        self.showMyReviewStatus = showMyReviewStatus
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.openAtCmuxFirst = openAtCmuxFirst
        self.graphQLEndpoint = graphQLEndpoint
        self.httpProxyURL = httpProxyURL
        self.httpProxyUsername = httpProxyUsername
        self.jiraServerURL = jiraServerURL
        self.jiraEmail = jiraEmail
        self.jiraRefreshInterval = jiraRefreshInterval
        self.monitorEnabled = monitorEnabled
        self.notificationTargets = notificationTargets
        self.notificationEventKinds = notificationEventKinds
        self.notificationRepositories = notificationRepositories
        self.slackEnabled = slackEnabled
        self.slackWorkspaceName = slackWorkspaceName
        self.slackWorkspaceID = slackWorkspaceID
        self.slackUserID = slackUserID
        self.slackDMChannelID = slackDMChannelID
        self.commentShortcuts = commentShortcuts
    }

    enum CodingKeys: String, CodingKey {
        case refreshInterval
        case repositories
        case showDrafts
        case minimumApprovalsForReadyToMerge
        case notificationsEnabled
        case refreshOnOpen
        case ciStatusExcludeFilter
        case pausePollingInLowPowerMode
        case pausePollingOnExpensiveNetwork
        case showMyReviewStatus
        case automaticallyCheckForUpdates
        case openAtCmuxFirst
        case graphQLEndpoint
        case httpProxyURL
        case httpProxyUsername
        case jiraServerURL
        case jiraEmail
        case jiraRefreshInterval
        case monitorEnabled
        case notificationTargets
        case notificationEventKinds
        case notificationRepositories
        case slackEnabled
        case slackWorkspaceName
        case slackWorkspaceID
        case slackUserID
        case slackDMChannelID
        case commentShortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Configuration.default

        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        repositories = try container.decodeIfPresent([String].self, forKey: .repositories) ?? defaults.repositories
        showDrafts = try container.decodeIfPresent(Bool.self, forKey: .showDrafts) ?? defaults.showDrafts
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        refreshOnOpen = try container.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? defaults.refreshOnOpen
        ciStatusExcludeFilter = try container.decodeIfPresent(String.self, forKey: .ciStatusExcludeFilter) ?? defaults.ciStatusExcludeFilter
        pausePollingInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pausePollingInLowPowerMode) ?? defaults.pausePollingInLowPowerMode
        pausePollingOnExpensiveNetwork = try container.decodeIfPresent(Bool.self, forKey: .pausePollingOnExpensiveNetwork) ?? defaults.pausePollingOnExpensiveNetwork
        showMyReviewStatus = try container.decodeIfPresent(Bool.self, forKey: .showMyReviewStatus) ?? defaults.showMyReviewStatus
        minimumApprovalsForReadyToMerge = min(
            max(
                try container.decodeIfPresent(Int.self, forKey: .minimumApprovalsForReadyToMerge)
                    ?? defaults.minimumApprovalsForReadyToMerge,
                1
            ),
            10
        )
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? defaults.automaticallyCheckForUpdates
        openAtCmuxFirst = try container.decodeIfPresent(Bool.self, forKey: .openAtCmuxFirst) ?? defaults.openAtCmuxFirst
        graphQLEndpoint = try container.decodeIfPresent(String.self, forKey: .graphQLEndpoint) ?? defaults.graphQLEndpoint
        httpProxyURL = try container.decodeIfPresent(String.self, forKey: .httpProxyURL) ?? defaults.httpProxyURL
        httpProxyUsername = try container.decodeIfPresent(String.self, forKey: .httpProxyUsername) ?? defaults.httpProxyUsername
        jiraServerURL = try container.decodeIfPresent(String.self, forKey: .jiraServerURL) ?? defaults.jiraServerURL
        jiraEmail = try container.decodeIfPresent(String.self, forKey: .jiraEmail) ?? defaults.jiraEmail
        jiraRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .jiraRefreshInterval) ?? defaults.jiraRefreshInterval
        monitorEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitorEnabled) ?? defaults.monitorEnabled
        notificationTargets = try container.decodeIfPresent([String].self, forKey: .notificationTargets) ?? defaults.notificationTargets
        notificationEventKinds = try container.decodeIfPresent([String].self, forKey: .notificationEventKinds) ?? defaults.notificationEventKinds
        notificationRepositories = try container.decodeIfPresent([String].self, forKey: .notificationRepositories) ?? defaults.notificationRepositories
        slackEnabled = try container.decodeIfPresent(Bool.self, forKey: .slackEnabled) ?? defaults.slackEnabled
        slackWorkspaceName = try container.decodeIfPresent(String.self, forKey: .slackWorkspaceName) ?? defaults.slackWorkspaceName
        slackWorkspaceID = try container.decodeIfPresent(String.self, forKey: .slackWorkspaceID) ?? defaults.slackWorkspaceID
        slackUserID = try container.decodeIfPresent(String.self, forKey: .slackUserID) ?? defaults.slackUserID
        slackDMChannelID = try container.decodeIfPresent(String.self, forKey: .slackDMChannelID) ?? defaults.slackDMChannelID
        commentShortcuts = try container.decodeIfPresent([CommentShortcut].self, forKey: .commentShortcuts) ?? defaults.commentShortcuts
    }

    var isValid: Bool {
        refreshInterval >= 60
    }
}

// MARK: - Digest preferences

extension Configuration {
    /// Delivery destinations for automated digests, in a stable order.
    var digestChannels: [DigestChannel] {
        var result: [DigestChannel] = []
        for raw in notificationTargets {
            guard let channel = DigestChannel(rawValue: raw), !result.contains(channel) else { continue }
            result.append(channel)
        }
        return result
    }

    /// Event kinds the user wants in digests. Empty means "use the built-in defaults".
    var notificationEventKindFilter: Set<PRActivityEventKind> {
        Set(notificationEventKinds.compactMap(PRActivityEventKind.init(rawValue:)))
    }

    func isRepositoryNotified(_ repoFullName: String) -> Bool {
        guard !notificationRepositories.isEmpty else { return true }
        let normalized = repoFullName.lowercased()
        return notificationRepositories.contains { $0.lowercased() == normalized }
    }

    /// A Slack digest requires a verified DM binding; a bare token is not enough.
    var isSlackDeliveryConfigured: Bool {
        slackEnabled && !slackUserID.isEmpty && !slackDMChannelID.isEmpty
    }
}

enum ConfigurationError: LocalizedError {
    case invalidRefreshInterval

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval:
            return String(localized: "Refresh interval must be at least 1 minute")
        }
    }
}

// Authentication method
enum AuthMethod: String, Codable {
    case oauth
    case pat  // Personal Access Token
}

// OAuth tokens stored separately from the general configuration.
struct AuthState: Codable, Equatable {
    var accessToken: String?
    var username: String?
    var authMethod: AuthMethod?

    var isAuthenticated: Bool {
        accessToken != nil
    }

    static var empty: AuthState {
        AuthState(accessToken: nil, username: nil, authMethod: nil)
    }
}
