import Foundation
import Testing

@testable import BiliNetworking

/// HTTP 边界只放行可接受状态码、拒绝 redirect；session 基线不带 Cookie、凭据与缓存，
/// transport 释放时失效自有 session。
@Suite(.timeLimit(.minutes(1)))
struct HTTPClientTests {
    @Test
    func credentialFreeBaselineCarriesNoCookieCredentialOrCache() {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()

        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func rejectsUnexpectedStatusCode() async throws {
        let client = HTTPClient(
            transport: StubTransport(
                responses: [HTTPResponse(statusCode: 403, body: Data())]
            )
        )
        let request = HTTPRequest(url: try #require(URL(string: "https://example.com")))

        await #expect(throws: HTTPClientError.unacceptableStatusCode(403)) {
            try await client.send(request)
        }
    }

    @Test
    func rejectRedirectDelegateStopsCrossHostRedirect() async throws {
        let delegate = RejectHTTPRedirectDelegate()
        let original = try #require(URL(string: "https://api.example.com/private"))
        let redirected = try #require(URL(string: "https://cdn.example.com/private"))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        let response = try #require(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirected.absoluteString]
            )
        )

        await confirmation { completed in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: redirected)
            ) { request in
                #expect(request == nil)
                completed()
            }
        }
        session.invalidateAndCancel()
    }

    @Test
    func ownedSessionIsInvalidatedWhenTransportIsReleased() async {
        let observer = SessionInvalidationObserver()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: observer,
            delegateQueue: nil
        )

        _ = URLSessionTransport(session: session)

        await observer.waitUntilInvalidated()
    }
}

private final class SessionInvalidationObserver: NSObject, URLSessionDelegate, Sendable {
    private let invalidated = OneShotResult<Void>()

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        invalidated.resolve(.success(()))
    }

    func waitUntilInvalidated() async {
        try? await invalidated.value()
    }
}
