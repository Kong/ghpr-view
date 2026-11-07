import Foundation

/// Identities bound to one Slack DM delivery target.
///
/// The bot token is never part of this value: it is supplied per call by the
/// caller (loaded from the keychain) and never stored here.
struct SlackConnection: Codable, Equatable {
    let workspaceID: String
    let workspaceName: String
    let botUserID: String
    let botName: String
    let channelID: String
    let channelName: String?
    let userID: String
}

/// Receipt of an accepted `chat.postMessage` call.
///
/// A receipt only means Slack accepted the message, not that the user read or
/// handled it.
struct SlackPostResult: Equatable {
    let channelID: String
    let messageTimestamp: String
}

/// Slack failures as the user-facing boundary sees them. A failing call is
/// never converted into a success, and no description ever contains the token.
enum SlackClientError: LocalizedError, Equatable {
    /// Token missing, revoked, or rejected by Slack.
    case invalidAuth
    /// Slack app lacks the named OAuth scope.
    case missingScope(String)
    /// The configured workspace recipient or DM channel is not usable.
    case targetUnavailable(String)
    /// Slack throttled this app; `retryAfter` is the server-provided delay.
    case rateLimited(retryAfter: TimeInterval?)
    /// Unexpected HTTP status from Slack.
    case httpStatus(Int)
    /// HTTP 200 whose body is not a usable Slack response.
    case malformedResponse(String)
    /// The request never reached Slack.
    case transportUnavailable(String)
    /// The request was sent but no usable response arrived; the message may or
    /// may not have been delivered.
    case responseLost(String)
    /// The request was cancelled before it completed.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAuth:
            return String(localized: "Slack rejected the bot token. Save a valid bot token for the target workspace and try again.")
        case .missingScope(let scope):
            return String(localized: "The Slack app is missing the \"\(scope)\" permission. Add that scope to the app, reinstall it, then save the new bot token.")
        case .targetUnavailable(let reason):
            return String(localized: "Slack could not deliver to the configured target (\(reason)). Check the Slack user ID and that the app can open a direct message with that person.")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return String(localized: "Slack is rate limiting this app. Retry in about \(Int(retryAfter.rounded())) seconds.")
            }
            return String(localized: "Slack is rate limiting this app. Retry after the delay Slack asks for.")
        case .httpStatus(let code):
            return String(localized: "Slack returned HTTP \(code).")
        case .malformedResponse(let reason):
            return String(localized: "Slack returned an unexpected response: \(reason).")
        case .transportUnavailable(let reason):
            return String(localized: "Could not reach the Slack API (\(reason)). Check the network connection and the HTTP proxy setting.")
        case .responseLost(let reason):
            return String(localized: "The Slack request did not complete after it was sent (\(reason)). The message may or may not have been delivered; check the direct message before retrying.")
        case .cancelled:
            return String(localized: "The Slack request was cancelled before it completed.")
        }
    }
}

enum SlackVerificationFailurePolicy: Equatable {
    case keepExistingConnection
    case clearStoredConnection

    static func policy(for error: Error) -> SlackVerificationFailurePolicy {
        if case SlackClientError.invalidAuth = error { return .clearStoredConnection }
        return .keepExistingConnection
    }
}

private final class SlackProxyAuthDelegate: NSObject, URLSessionDelegate {
    var credential: URLCredential?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isProxyBasic = (space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || space.authenticationMethod == NSURLAuthenticationMethodDefault)
            && [NSURLProtectionSpaceHTTPProxy, NSURLProtectionSpaceHTTPSProxy].contains(space.proxyType ?? "")
        if isProxyBasic, let credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// The only component that talks to the Slack Web API.
///
/// Scope: read-only handshake (`auth.test`, `users.info`, `conversations.open`)
/// plus DM delivery (`chat.postMessage`). The bot token is passed on every call
/// and is never stored, logged, or returned in an error. Nothing here retries
/// automatically: a failed or unknown outcome is reported to the caller, which
/// owns outbox and retry policy.
final class SlackNotificationClient {
    private static let apiBaseURL = URL(string: "https://slack.com/api/")!
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let session: URLSession
    private let proxyDelegate: SlackProxyAuthDelegate?
    private let clock: () -> Date

    init(session: URLSession? = nil, proxy: HTTPProxyConfig? = nil, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        if let session {
            self.session = session
            self.proxyDelegate = nil
        } else {
            // `connectionProxyDictionary` cannot carry credentials, so proxy
            // Basic auth is answered by the delegate instead.
            let delegate = SlackProxyAuthDelegate()
            if let proxy, !proxy.username.isEmpty {
                delegate.credential = URLCredential(
                    user: proxy.username,
                    password: proxy.password,
                    persistence: .none
                )
            }
            self.proxyDelegate = delegate
            self.session = Self.makeSession(proxy: proxy, delegate: delegate)
        }
    }

    // MARK: - Handshake

    /// Verifies the bot token, the target human user, and the DM channel, then
    /// returns the identities a digest batch is bound to.
    func verifyAndConnect(token: String, userID: String) async throws -> SlackConnection {
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty else {
            throw SlackClientError.targetUnavailable("no Slack user ID was provided")
        }

        let auth = try await post("auth.test", body: [:], token: token)
        guard auth.isOK else {
            throw auth.failure(unknown: .targetUnavailable(auth.errorCode ?? "auth.test did not succeed"))
        }
        guard let workspaceID = auth.string("team_id"), !workspaceID.isEmpty,
              let workspaceName = auth.string("team"), !workspaceName.isEmpty,
              let botUserID = auth.string("user_id"), !botUserID.isEmpty,
              let botName = auth.string("user"), !botName.isEmpty else {
            throw SlackClientError.malformedResponse("auth.test did not return the workspace and bot identities")
        }

        let user = try await post("users.info", body: [:], query: ["user": trimmedUserID], token: token)
        guard user.isOK else {
            throw user.failure(unknown: .targetUnavailable(user.errorCode ?? "users.info failed"))
        }
        guard let target = user.object["user"] as? [String: Any] else {
            throw SlackClientError.targetUnavailable("user_not_found")
        }
        if (target["is_bot"] as? Bool) == true {
            throw SlackClientError.targetUnavailable("the configured Slack user ID belongs to a bot")
        }
        if (target["deleted"] as? Bool) == true {
            throw SlackClientError.targetUnavailable("the configured Slack user is deactivated in this workspace")
        }
        guard let targetID = target["id"] as? String, !targetID.isEmpty else {
            throw SlackClientError.targetUnavailable("Slack did not return an ID for the configured user")
        }

        let conversation = try await post("conversations.open", body: ["users": trimmedUserID], token: token)
        guard conversation.isOK else {
            throw conversation.failure(unknown: .targetUnavailable(conversation.errorCode ?? "conversations.open failed"))
        }
        guard let channel = conversation.object["channel"] as? [String: Any],
              let channelID = channel["id"] as? String, !channelID.isEmpty else {
            throw SlackClientError.malformedResponse("conversations.open did not return a channel ID")
        }

        return SlackConnection(
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            botUserID: botUserID,
            botName: botName,
            channelID: channelID,
            channelName: (channel["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            userID: trimmedUserID
        )
    }

    // MARK: - Delivery

    /// Posts one digest to the bound DM channel.
    ///
    /// `text` is sent as-is: the digest composer owns Slack mrkdwn (including
    /// intentional `<url|label>` links) and must run user-supplied fragments
    /// through `escapedForSlack(_:)` before joining them.
    func postDigest(_ text: String, connection: SlackConnection, token: String) async throws -> SlackPostResult {
        let response = try await post(
            "chat.postMessage",
            body: [
                "channel": connection.channelID,
                "text": text,
                "unfurl_links": "false",
                "unfurl_media": "false",
                "mrkdwn": "true"
            ],
            token: token
        )
        guard response.isOK else {
            let code = response.errorCode ?? "unknown_error"
            throw response.failure(unknown: .malformedResponse(code))
        }
        guard let channel = response.string("channel"), !channel.isEmpty,
              let timestamp = response.string("ts"), !timestamp.isEmpty else {
            throw SlackClientError.malformedResponse("chat.postMessage did not return a channel and timestamp")
        }
        return SlackPostResult(channelID: channel, messageTimestamp: timestamp)
    }

    /// Manual connection test: a message the user can recognise as a test and
    /// never mistake for a PR digest.
    func sendTestMessage(token: String, connection: SlackConnection) async throws -> SlackPostResult {
        let sentAt = Self.iso8601Formatter.string(from: clock())
        let text = """
        *ghpr connection test* - this is a manual test message you asked ghpr to send at \(sentAt). \
        It is not a PR digest, it links no pull request, and no action is required.
        """
        return try await postDigest(text, connection: connection, token: token)
    }

    // MARK: - Text escaping

    /// Escapes user- and GitHub-supplied text for Slack mrkdwn and makes
    /// mention tokens inert: `&`, `<`, `>` become entities, and a word joiner is
    /// inserted after every `@` so `@channel`, `@here`, and user handles cannot
    /// ping anyone. Escaped text can never produce `<@U...>` or `<#C...>`.
    static func escapedForSlack(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "@", with: "@\u{2060}")
    }

    // MARK: - Transport

    private static func makeSession(proxy: HTTPProxyConfig?, delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        if let proxy {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as AnyHashable: 1,
                kCFNetworkProxiesHTTPProxy as AnyHashable: proxy.host,
                kCFNetworkProxiesHTTPPort as AnyHashable: proxy.port,
                "HTTPSEnable" as AnyHashable: 1,
                "HTTPSProxy" as AnyHashable: proxy.host,
                "HTTPSPort" as AnyHashable: proxy.port
            ]
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func post(
        _ method: String,
        body: [String: String],
        query: [String: String] = [:],
        token: String
    ) async throws -> SlackAPIResponse {
        var components = URLComponents(
            url: Self.apiBaseURL.appendingPathComponent(method),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw SlackClientError.malformedResponse("could not build the \(method) request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.transportError(error)
        } catch is CancellationError {
            throw SlackClientError.cancelled
        } catch {
            throw SlackClientError.transportUnavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SlackClientError.malformedResponse("\(method) did not return an HTTP response")
        }
        let retryAfter = Self.retryAfter(of: http)

        if http.statusCode == 429 {
            throw SlackClientError.rateLimited(retryAfter: retryAfter ?? 60)
        }
        let slack = SlackAPIResponse(data: data)
        if http.statusCode == 401 || http.statusCode == 403, slack.errorCode != nil {
            throw slack.failure(unknown: .httpStatus(http.statusCode), retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else {
            throw SlackClientError.httpStatus(http.statusCode)
        }
        guard slack.hasBody else {
            throw SlackClientError.malformedResponse("\(method) returned a body that is not a Slack response")
        }
        return slack
    }

    private static func formEncoded(_ parameters: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = parameters.sorted { $0.key < $1.key }.map { key, value -> String in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let content = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(content)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    private static func retryAfter(of response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return TimeInterval(raw)
    }

    private static func transportError(_ error: URLError) -> SlackClientError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            // The request was sent and timed out: Slack may have delivered it.
            return .responseLost("the request timed out")
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
            return .transportUnavailable(error.localizedDescription)
        default:
            return .transportUnavailable(error.localizedDescription)
        }
    }
}

/// One parsed Slack Web API response body.
private struct SlackAPIResponse {
    let object: [String: Any]

    init(data: Data) {
        self.object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var hasBody: Bool { !object.isEmpty }

    var isOK: Bool { (object["ok"] as? Bool) == true }

    var errorCode: String? {
        guard let code = object["error"] as? String, !code.isEmpty else { return nil }
        return code
    }

    func string(_ key: String) -> String? { object[key] as? String }

    /// Maps a Slack `error` code onto the boundary error, falling back to
    /// `unknown` for codes this client does not interpret.
    func failure(unknown: SlackClientError, retryAfter: TimeInterval? = nil) -> SlackClientError {
        guard object["ok"] as? Bool != nil else {
            return .malformedResponse("the response did not contain a boolean ok field")
        }
        guard let code = errorCode else {
            return .malformedResponse("the response reported ok:false without an error code")
        }
        switch code {
        case "invalid_auth", "not_authed", "token_revoked":
            return .invalidAuth
        case "missing_scope":
            return .missingScope(code)
        case "ratelimited":
            return .rateLimited(retryAfter: retryAfter ?? 60)
        case "channel_not_found", "user_not_found", "not_in_channel", "is_archived", "cannot_dm_bot":
            return .targetUnavailable(code)
        default:
            return unknown
        }
    }
}

/// `PRActivityDigestChannel` adapter that posts digests as a direct message.
///
/// The token is read from the credential store on every delivery and never stored on
/// the channel, so it cannot leak through configuration, snapshots or logs.
@MainActor
final class SlackActivityDigestChannel: PRActivityDigestChannel {
    let channel: DigestChannel = .slack

    private let client: SlackNotificationClient
    private let configurationProvider: () -> Configuration
    private let tokenProvider: () -> String

    init(
        client: SlackNotificationClient,
        configurationProvider: @escaping () -> Configuration,
        tokenProvider: @escaping () -> String = { Keychain.loadSlackBotToken() }
    ) {
        self.client = client
        self.configurationProvider = configurationProvider
        self.tokenProvider = tokenProvider
    }

    var isAvailable: Bool {
        configurationProvider().isSlackDeliveryConfigured && !tokenProvider().isEmpty
    }

    /// Bound at batch creation time; delivery refuses a batch whose binding no longer
    /// matches, so a connection change can never redirect an old message.
    var targetBinding: [String: String] {
        let configuration = configurationProvider()
        return [
            "workspace": configuration.slackWorkspaceID,
            "user": configuration.slackUserID,
        ]
    }

    func deliver(_ batch: DigestBatch) async throws -> DigestReceipt {
        let configuration = configurationProvider()
        guard configuration.isSlackDeliveryConfigured else {
            throw SlackClientError.targetUnavailable("Slack delivery is not connected")
        }
        let token = tokenProvider()
        guard !token.isEmpty else {
            throw SlackClientError.invalidAuth
        }
        let connection = SlackConnection(
            workspaceID: configuration.slackWorkspaceID,
            workspaceName: configuration.slackWorkspaceName,
            botUserID: "",
            botName: "",
            channelID: configuration.slackDMChannelID,
            channelName: nil,
            userID: configuration.slackUserID
        )
        let result = try await client.postDigest(
            PRActivityDigestFormatter.slackText(for: batch),
            connection: connection,
            token: token
        )
        return DigestReceipt(
            channelID: result.channelID,
            workspace: configuration.slackWorkspaceName,
            messageTimestamp: result.messageTimestamp,
            recipientUserID: configuration.slackUserID
        )
    }
}
