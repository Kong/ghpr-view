import XCTest
@testable import PRDashboard

/// The browser-bridge comment shortcut slice: canonical context resolution, refusals
/// and the guarantee that preparing a draft never writes to GitHub.
@MainActor
final class CommentShortcutPreparerTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        CommentShortcutFixtureProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentShortcutFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        CommentShortcutFixtureProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func makeClient() -> GitHubAPIClient {
        GitHubAPIClient(token: "fixture-token", session: session)
    }

    private func makeRequest(
        shortcutID: String = "shortcut-1",
        repository: String = "owner/repo",
        number: Int = 42,
        commentPermalink: String? = nil,
        expectedHeadSHA: String? = nil
    ) -> BrowserBridgeRouter.BrowserCommentShortcutRequest {
        BrowserBridgeRouter.BrowserCommentShortcutRequest(
            shortcutID: shortcutID,
            page: .pullRequest(repository: repository, number: number),
            commentPermalink: commentPermalink,
            expectedHeadSHA: expectedHeadSHA
        )
    }

    private func configuration(
        template: String = "{{repository}}#{{pr_number}} at {{head_sha}} — {{diff_url}}",
        contexts: Set<CommentShortcutContext> = [],
        scopes: [String] = [],
        enabled: Bool = true
    ) -> Configuration {
        var configuration = Configuration.default
        configuration.commentShortcuts = [
            CommentShortcut(
                id: "shortcut-1",
                displayName: "Ask",
                template: template,
                contexts: contexts,
                repositoryScopes: scopes,
                isEnabled: enabled
            )
        ]
        return configuration
    }

    // MARK: - Happy path

    func testPullRequestDraftUsesCanonicalContext() async throws {
        CommentShortcutFixtureProtocol.reset { request in
            guard request.url?.path == "/repos/owner/repo/pulls/42" else {
                return (Self.response(for: request, status: 404), Data())
            }
            return (Self.response(for: request, status: 200), Data(#"{"head":{"sha":"sha-head"}}"#.utf8))
        }

        let draft = try await CommentShortcutPreparer.prepare(
            request: makeRequest(),
            configuration: configuration(),
            apiClient: makeClient()
        )

        XCTAssertEqual(draft.repository, "owner/repo")
        XCTAssertEqual(draft.prNumber, 42)
        XCTAssertEqual(draft.context, .pullRequest)
        XCTAssertEqual(draft.headSHA, "sha-head")
        XCTAssertEqual(draft.prURL, "https://github.com/owner/repo/pull/42")
        XCTAssertEqual(draft.diffURL, "https://github.com/owner/repo/pull/42/files")
        XCTAssertEqual(draft.draft, "owner/repo#42 at sha-head — https://github.com/owner/repo/pull/42/files")
        XCTAssertTrue(
            CommentShortcutFixtureProtocol.recordedRequests.allSatisfy { $0.httpMethod == "GET" },
            "Preparing a draft must never issue a write request"
        )
    }

    func testCommentReplyUsesTheCanonicalCommentBody() async throws {
        CommentShortcutFixtureProtocol.reset { request in
            switch request.url?.path {
            case "/repos/owner/repo/pulls/42":
                return (Self.response(for: request, status: 200), Data(#"{"head":{"sha":"sha-head"}}"#.utf8))
            case "/repos/owner/repo/pulls/comments/123":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"body":"Can you add a test for this branch?","html_url":"https://github.com/owner/repo/pull/42#discussion_r123","pull_request_url":"https://api.github.com/repos/owner/repo/pulls/42"}"#.utf8)
                )
            default:
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let draft = try await CommentShortcutPreparer.prepare(
            request: makeRequest(
                commentPermalink: "https://github.com/owner/repo/pull/42#discussion_r123"
            ),
            configuration: configuration(template: "Re: {{comment_body}}\n{{comment_url}}"),
            apiClient: makeClient()
        )

        XCTAssertEqual(draft.context, .reviewComment)
        XCTAssertEqual(draft.commentBody, "Can you add a test for this branch?")
        XCTAssertEqual(draft.commentURL, "https://github.com/owner/repo/pull/42#discussion_r123")
        XCTAssertEqual(draft.draft, "Re: Can you add a test for this branch?\nhttps://github.com/owner/repo/pull/42#discussion_r123")
    }

    // MARK: - Refusals

    func testHeadChangeRefusesToPrepareADraft() async {
        CommentShortcutFixtureProtocol.reset { request in
            (Self.response(for: request, status: 200), Data(#"{"head":{"sha":"sha-new"}}"#.utf8))
        }

        do {
            _ = try await CommentShortcutPreparer.prepare(
                request: makeRequest(expectedHeadSHA: "sha-old"),
                configuration: configuration(),
                apiClient: makeClient()
            )
            XCTFail("A page showing another revision must not get a draft")
        } catch {
            XCTAssertEqual(
                error as? CommentShortcutPreparationError,
                .headChanged(expected: "sha-old", actual: "sha-new")
            )
        }
    }

    func testCommentFromAnotherPullRequestIsRefused() async {
        CommentShortcutFixtureProtocol.reset { request in
            switch request.url?.path {
            case "/repos/owner/repo/pulls/42":
                return (Self.response(for: request, status: 200), Data(#"{"head":{"sha":"sha-head"}}"#.utf8))
            case "/repos/owner/repo/issues/comments/999":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"body":"other","html_url":"https://github.com/owner/repo/pull/7#issuecomment-999"}"#.utf8)
                )
            default:
                return (Self.response(for: request, status: 404), Data())
            }
        }

        do {
            _ = try await CommentShortcutPreparer.prepare(
                request: makeRequest(commentPermalink: "https://github.com/owner/repo/pull/42#issuecomment-999"),
                configuration: configuration(template: "{{comment_body}}"),
                apiClient: makeClient()
            )
            XCTFail("A permalink for another PR must be refused")
        } catch {
            guard case .contextMismatch = (error as? CommentShortcutPreparationError) else {
                return XCTFail("Expected a context mismatch, got \(error)")
            }
        }
    }

    func testUnknownShortcutAndWrongContextAreRefused() async {
        CommentShortcutFixtureProtocol.reset { request in
            (Self.response(for: request, status: 200), Data(#"{"head":{"sha":"sha-head"}}"#.utf8))
        }

        do {
            _ = try await CommentShortcutPreparer.prepare(
                request: makeRequest(shortcutID: "missing"),
                configuration: configuration(),
                apiClient: makeClient()
            )
            XCTFail("An unconfigured shortcut must be refused")
        } catch {
            XCTAssertEqual(error as? CommentShortcutPreparationError, .shortcutUnavailable)
        }

        do {
            _ = try await CommentShortcutPreparer.prepare(
                request: makeRequest(commentPermalink: "https://github.com/owner/repo/pull/42#discussion_r1"),
                configuration: configuration(contexts: [.pullRequest]),
                apiClient: makeClient()
            )
            XCTFail("A shortcut scoped to PR comments must not apply to a review comment")
        } catch {
            XCTAssertEqual(error as? CommentShortcutPreparationError, .shortcutNotApplicable)
        }
    }

    func testDisabledShortcutIsNeverOffered() async {
        XCTAssertTrue(
            CommentShortcutPreparer.catalog(from: configuration(enabled: false)).isEmpty,
            "A disabled shortcut must not be advertised to the page"
        )
    }

    func testCatalogExposesMetadataOnly() async {
        let catalog = CommentShortcutPreparer.catalog(from: configuration())

        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.first?.id, "shortcut-1")
        XCTAssertEqual(catalog.first?.displayName, "Ask")
        XCTAssertEqual(catalog.first?.contexts.count, CommentShortcutContext.allCases.count)
    }

    // MARK: - Helpers

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.github.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private final class CommentShortcutFixtureProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var requests: [URLRequest] = []

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset(handler: Handler? = nil) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = Self.materializedRequest(from: request)
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func materializedRequest(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var copy = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        copy.httpBody = data
        copy.httpBodyStream = nil
        return copy
    }
}
