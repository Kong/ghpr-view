import XCTest
@testable import PRDashboard

final class SlackNotificationClientTests: XCTestCase {
    private static let connection = SlackConnection(
        workspaceID: "T123",
        workspaceName: "Acme",
        botUserID: "UBOT",
        botName: "ghprbot",
        channelID: "D456",
        channelName: nil,
        userID: "UUSER"
    )

    // MARK: - Handshake

    func testVerifyAndConnectPerformsHandshakeInOrderAndReturnsBoundIdentities() async throws {
        MockSlackURLProtocol.reset { request in
            switch request.url?.path {
            case "/api/auth.test":
                return Self.json(request, #"{"ok":true,"url":"https://acme.slack.com/","team":"Acme","user":"ghprbot","team_id":"T123","user_id":"UBOT"}"#)
            case "/api/users.info":
                return Self.json(request, #"{"ok":true,"user":{"id":"UUSER","is_bot":false,"deleted":false}}"#)
            case "/api/conversations.open":
                return Self.json(request, #"{"ok":true,"channel":{"id":"D456","is_im":true}}"#)
            default:
                return Self.json(request, #"{"ok":false,"error":"unknown_method"}"#)
            }
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let connection = try await makeClient().verifyAndConnect(token: "xoxb-test-token", userID: " UUSER ")

        XCTAssertEqual(
            connection,
            Self.connection,
            "The connection should carry workspace, bot, channel, and trimmed user identities"
        )

        let requests = MockSlackURLProtocol.requests
        XCTAssertEqual(
            requests.map(\.path),
            ["/api/auth.test", "/api/users.info", "/api/conversations.open"],
            "The handshake must call auth.test, then users.info, then conversations.open"
        )
        XCTAssertEqual(
            requests[1].query["user"],
            "UUSER",
            "users.info must query the trimmed Slack user ID"
        )
        XCTAssertFalse(
            requests[1].body.contains("UUSER"),
            "The users.info target must travel in the query string, not the body"
        )
        XCTAssertEqual(
            requests[2].body,
            "users=UUSER",
            "conversations.open must open a DM with the trimmed user ID"
        )
        XCTAssertTrue(
            requests.allSatisfy { $0.authorization == "Bearer xoxb-test-token" },
            "Every Slack call must authenticate with the supplied bot token"
        )
        XCTAssertTrue(
            requests.allSatisfy { $0.method == "POST" },
            "Slack Web API calls must be POST requests"
        )
    }

    func testVerifyAndConnectRejectsBotUser() async throws {
        MockSlackURLProtocol.reset { request in
            if request.url?.path == "/api/auth.test" {
                return Self.json(request, #"{"ok":true,"team":"Acme","team_id":"T123","user":"ghprbot","user_id":"UBOT"}"#)
            }
            return Self.json(request, #"{"ok":true,"user":{"id":"UBOT","is_bot":true,"deleted":false}}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().verifyAndConnect(token: "xoxb-test-token", userID: "UBOT")
        }
        let failure = try XCTUnwrap(error, "A bot user must not be accepted as a DM target")

        guard case .targetUnavailable(let reason) = failure else {
            XCTFail("A bot user must fail with targetUnavailable, got \(failure)")
            return
        }
        XCTAssertTrue(reason.contains("bot"), "The reason should say the target is a bot, got: \(reason)")
        XCTAssertEqual(
            MockSlackURLProtocol.requests.map(\.path),
            ["/api/auth.test", "/api/users.info"],
            "A rejected target must not reach conversations.open"
        )
    }

    func testVerifyAndConnectRejectsDeactivatedUser() async throws {
        MockSlackURLProtocol.reset { request in
            if request.url?.path == "/api/auth.test" {
                return Self.json(request, #"{"ok":true,"team":"Acme","team_id":"T123","user":"ghprbot","user_id":"UBOT"}"#)
            }
            return Self.json(request, #"{"ok":true,"user":{"id":"UUSER","is_bot":false,"deleted":true}}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().verifyAndConnect(token: "xoxb-test-token", userID: "UUSER")
        }
        let failure = try XCTUnwrap(error, "A deactivated user must not be accepted as a DM target")

        guard case .targetUnavailable(let reason) = failure else {
            XCTFail("A deactivated user must fail with targetUnavailable, got \(failure)")
            return
        }
        XCTAssertTrue(reason.contains("deactivated"), "The reason should say the user is deactivated, got: \(reason)")
    }

    func testVerifyAndConnectRejectsInvalidAuth() async throws {
        MockSlackURLProtocol.reset { request in
            Self.json(request, #"{"ok":false,"error":"invalid_auth"}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().verifyAndConnect(token: "xoxb-stale", userID: "UUSER")
        }
        let failure = try XCTUnwrap(error, "auth.test ok:false must fail the handshake")

        XCTAssertEqual(failure, .invalidAuth, "invalid_auth must map to invalidAuth")
        XCTAssertEqual(
            MockSlackURLProtocol.requests.map(\.path),
            ["/api/auth.test"],
            "A rejected token must stop the handshake after auth.test"
        )
    }

    func testVerifyAndConnectRejectsUnusableUserInfoResponse() async throws {
        MockSlackURLProtocol.reset { request in
            if request.url?.path == "/api/auth.test" {
                return Self.json(request, #"{"ok":true,"team":"Acme","team_id":"T123","user":"ghprbot","user_id":"UBOT"}"#)
            }
            return Self.json(request, #"{"ok":true}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().verifyAndConnect(token: "xoxb-test-token", userID: "UUSER")
        }
        let failure = try XCTUnwrap(error, "A users.info response without a user object must not be treated as connected")

        guard case .targetUnavailable = failure else {
            XCTFail("A missing user object must fail with targetUnavailable, got \(failure)")
            return
        }
    }

    // MARK: - Delivery

    func testPostDigestTreatsHTTP200WithOkFalseAsFailure() async throws {
        MockSlackURLProtocol.reset { request in
            Self.json(request, #"{"ok":false,"error":"missing_scope","needed":"chat:write","provided":"identity.basic"}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "HTTP 200 with ok:false must never be reported as a delivered digest")

        XCTAssertEqual(failure, .missingScope("missing_scope"), "ok:false with missing_scope must surface the missing scope")
    }

    func testPostDigestSuccessReturnsSlackChannelAndTimestampAndDisablesUnfurling() async throws {
        MockSlackURLProtocol.reset { request in
            Self.json(request, #"{"ok":true,"channel":"D456","ts":"1728800000.000100","message":{"text":"digest"}}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let result = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")

        XCTAssertEqual(result.channelID, "D456", "The receipt must carry the channel Slack accepted")
        XCTAssertEqual(result.messageTimestamp, "1728800000.000100", "The receipt must carry Slack's message timestamp")

        let request = try XCTUnwrap(MockSlackURLProtocol.requests.first, "postDigest must issue one request")
        XCTAssertEqual(request.path, "/api/chat.postMessage", "The digest must be posted through chat.postMessage")
        XCTAssertTrue(request.body.contains("channel=D456"), "The digest must target the bound DM channel, body was: \(request.body)")
        XCTAssertTrue(request.body.contains("unfurl_links=false"), "Link unfurling must be disabled, body was: \(request.body)")
        XCTAssertTrue(request.body.contains("unfurl_media=false"), "Media unfurling must be disabled, body was: \(request.body)")
        XCTAssertTrue(request.body.contains("mrkdwn=true"), "Digest text is sent as mrkdwn, body was: \(request.body)")
    }

    func testPostDigestUnknownSlackErrorIsNotReportedAsSuccess() async throws {
        MockSlackURLProtocol.reset { request in
            Self.json(request, #"{"ok":false,"error":"weird_new_error"}"#)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "An unrecognized Slack error must still fail the delivery")

        XCTAssertEqual(failure, .malformedResponse("weird_new_error"), "An unknown error code must be surfaced with its code")
    }

    func testPostDigestRateLimitedHonorsRetryAfterHeader() async throws {
        MockSlackURLProtocol.reset { request in
            (
                Self.response(request, statusCode: 429, headers: ["Retry-After": "42"]),
                Data(#"{"ok":false,"error":"ratelimited"}"#.utf8)
            )
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "HTTP 429 must fail the delivery")

        XCTAssertEqual(failure, .rateLimited(retryAfter: 42), "The server-provided Retry-After delay must be reported")
    }

    func testPostDigestTimeoutIsReportedAsResponseLost() async throws {
        MockSlackURLProtocol.reset { _ -> (HTTPURLResponse, Data) in
            throw URLError(.timedOut)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "A timed-out digest must not be reported as delivered")

        guard case .responseLost = failure else {
            XCTFail("A request that timed out after being sent is an unknown outcome, got \(failure)")
            return
        }
        XCTAssertEqual(
            MockSlackURLProtocol.requests.count,
            1,
            "A failed delivery must not be retried internally"
        )
    }

    func testOfflineFailsWithTransportUnavailable() async throws {
        MockSlackURLProtocol.reset { _ -> (HTTPURLResponse, Data) in
            throw URLError(.notConnectedToInternet)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "A delivery attempted while offline must fail")

        guard case .transportUnavailable = failure else {
            XCTFail("A request that never reached Slack is a transport failure, got \(failure)")
            return
        }
    }

    func testUnauthorizedHTTPStatusWithSlackErrorBodyIsInvalidAuth() async throws {
        MockSlackURLProtocol.reset { request in
            (
                Self.response(request, statusCode: 401),
                Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)
            )
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "HTTP 401 must fail the delivery")

        XCTAssertEqual(failure, .invalidAuth, "HTTP 401 with invalid_auth must map to invalidAuth")
    }

    func testServerErrorFailsWithHTTPStatus() async throws {
        MockSlackURLProtocol.reset { request in
            (
                Self.response(request, statusCode: 503),
                Data("<!DOCTYPE html><html>Service Unavailable</html>".utf8)
            )
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: "xoxb-test-token")
        }
        let failure = try XCTUnwrap(error, "HTTP 503 must fail the delivery")

        XCTAssertEqual(failure, .httpStatus(503), "Non-200, non-429 responses must be surfaced with their status code")
    }

    // MARK: - Escaping

    func testEscapedForSlackNeutralizesMentionsAndEscapesMarkup() {
        let escaped = SlackNotificationClient.escapedForSlack("R&D <b> @channel @here <!here> <@U123>")

        XCTAssertFalse(escaped.contains("@channel"), "@channel must not survive escaping, got: \(escaped)")
        XCTAssertFalse(escaped.contains("@here"), "@here must not survive escaping, got: \(escaped)")
        XCTAssertFalse(escaped.contains("<!here>"), "<!here> must not survive escaping, got: \(escaped)")
        XCTAssertFalse(escaped.contains("<@U123>"), "A user mention must not survive escaping, got: \(escaped)")
        XCTAssertFalse(escaped.contains("<"), "No raw '<' may remain, got: \(escaped)")
        XCTAssertFalse(escaped.contains(">"), "No raw '>' may remain, got: \(escaped)")
        XCTAssertTrue(escaped.contains("R&amp;D"), "& must become &amp;, got: \(escaped)")
        XCTAssertTrue(escaped.contains("&lt;b&gt;"), "< and > must be escaped, got: \(escaped)")
        XCTAssertTrue(escaped.contains("@\u{2060}channel"), "A word joiner must break the mention token, got: \(escaped)")
    }

    // MARK: - Token handling

    func testFailuresNeverExposeTheBotToken() async throws {
        let token = "xoxb-do-not-leak-me"
        MockSlackURLProtocol.reset { _ -> (HTTPURLResponse, Data) in
            throw URLError(.cannotConnectToHost)
        }
        defer { MockSlackURLProtocol.reset(handler: nil) }

        let error = await captureError {
            _ = try await makeClient().postDigest("digest", connection: Self.connection, token: token)
        }
        let failure = try XCTUnwrap(error, "A transport failure must be reported")

        XCTAssertFalse(
            (failure.errorDescription ?? "").contains(token),
            "The bot token must never appear in a failure description"
        )
        XCTAssertFalse(
            (failure.localizedDescription).contains(token),
            "The bot token must never appear in a localized description"
        )

        let everyFailure: [SlackClientError] = [
            .invalidAuth,
            .missingScope("missing_scope"),
            .targetUnavailable("user_not_found"),
            .rateLimited(retryAfter: 42),
            .rateLimited(retryAfter: nil),
            .httpStatus(500),
            .malformedResponse("unexpected body"),
            .transportUnavailable("cannot connect"),
            .responseLost("timed out"),
            .cancelled
        ]
        for failure in everyFailure {
            let description = failure.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(failure) must describe the failure actionably")
            XCTAssertFalse(description.contains(token), "\(failure) must not carry the token")
        }

        XCTAssertTrue(
            MockSlackURLProtocol.requests.allSatisfy { ($0.url?.absoluteString ?? "").contains(token) == false },
            "The token must not be placed in a request URL"
        )
        XCTAssertTrue(
            MockSlackURLProtocol.requests.allSatisfy { $0.authorization == "Bearer \(token)" },
            "The token must travel in the Authorization header"
        )
    }

    // MARK: - Helpers

    private func makeClient() -> SlackNotificationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSlackURLProtocol.self]
        return SlackNotificationClient(session: URLSession(configuration: configuration))
    }

    private func captureError(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> SlackClientError? {
        do {
            try await operation()
            XCTFail("Expected a SlackClientError, but the call succeeded", file: file, line: line)
            return nil
        } catch let error as SlackClientError {
            return error
        } catch {
            XCTFail("Expected a SlackClientError, got \(error)", file: file, line: line)
            return nil
        }
    }

    private static func response(
        _ request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://slack.com/api/unknown")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private static func json(
        _ request: URLRequest,
        _ body: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        (response(request, statusCode: statusCode, headers: headers), Data(body.utf8))
    }
}

private struct RecordedSlackRequest {
    let method: String?
    let url: URL?
    let query: [String: String]
    let body: String
    let authorization: String?

    var path: String { url?.path ?? "" }
}

/// File-private Slack API stand-in: records every request and answers from a
/// static handler, so no test ever reaches the network.
private final class MockSlackURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: RequestHandler?
    private static var records: [RecordedSlackRequest] = []

    static var requests: [RecordedSlackRequest] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    static func reset(handler: RequestHandler?) {
        lock.lock()
        self.handler = handler
        records = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = Self.materializedRequest(from: request)
        Self.record(request)

        guard let handler = Self.currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static var currentHandler: RequestHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private static func record(_ request: URLRequest) {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let record = RecordedSlackRequest(
            method: request.httpMethod,
            url: request.url,
            query: query,
            body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )

        lock.lock()
        records.append(record)
        lock.unlock()
    }

    private static func materializedRequest(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }

        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var body = Data()
        while true {
            let count = stream.read(buffer, maxLength: capacity)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }

        var materialized = request
        materialized.httpBodyStream = nil
        materialized.httpBody = body
        return materialized
    }
}
