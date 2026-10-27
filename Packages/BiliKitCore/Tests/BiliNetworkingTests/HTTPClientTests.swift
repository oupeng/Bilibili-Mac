import Foundation
import Testing

@testable import BiliNetworking

/// HTTP 边界只放行可接受状态码、拒绝 redirect；session 基线不带 Cookie、凭据与缓存，
/// transport 释放时失效自有 session；失效之后的请求不在已失效的 session 上建 task，与被失效打断的在途请求一样
/// 报 `URLError(.cancelled)`，只有调用方自己被取消才是 `CancellationError`。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPClientTests {
    @Test
    func credentialFreeBaselineCarriesNoCookieCredentialOrCacheAndInteractiveTimeouts() {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()

        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(
            configuration.timeoutIntervalForRequest
                == URLSessionConfiguration.interactiveRequestTimeout
        )
        #expect(
            configuration.timeoutIntervalForResource
                == URLSessionConfiguration.interactiveResourceTimeout
        )
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
    func transportReturnsRedirectResponseWithoutFollowingIt() async throws {
        TransportURLProtocol.state.configure(
            statusCode: 302,
            headers: ["Location": "https://cdn.example.com/private", "Content-Type": "text/plain"],
            chunks: [Data("moved".utf8)]
        )
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.protocolClasses = [TransportURLProtocol.self]
        let transport = URLSessionTransport(configuration: configuration)
        let original = try #require(URL(string: "https://api.example.com/private"))

        let response = try await transport.send(HTTPRequest(url: original))

        #expect(response.statusCode == 302)
        #expect(TransportURLProtocol.state.lastRequest?.url == original)
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

    @Test
    func sendAfterInvalidationFailsLikeAnInterruptedRequestWithoutCreatingTask() async throws {
        let transport = URLSessionTransport(configuration: .credentialFreeEphemeral())
        let request = HTTPRequest(url: try #require(URL(string: "https://example.com")))

        transport.invalidateAndCancel()

        let error = await #expect(throws: URLError.self) {
            try await transport.send(request)
        }
        #expect(error?.code == .cancelled)
    }

    @Test
    func invalidationInterruptsInFlightRequestAsTransportCancellation() async throws {
        let (transport, request) = try makeStalledTransport()

        let pending = Task { try await transport.send(request) }
        await TransportURLProtocol.state.waitUntilStarted()
        transport.invalidateAndCancel()

        let error = await #expect(throws: URLError.self) {
            try await pending.value
        }
        #expect(error?.code == .cancelled)
    }

    @Test
    func callerCancellationEndsInFlightRequestAsCancellationError() async throws {
        let (transport, request) = try makeStalledTransport()

        let pending = Task { try await transport.send(request) }
        await TransportURLProtocol.state.waitUntilStarted()
        pending.cancel()

        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
        transport.invalidateAndCancel()
    }

    /// 只发响应头、正文永远不到的 transport，请求只能被取消或失效结束。
    private func makeStalledTransport() throws -> (URLSessionTransport, HTTPRequest) {
        TransportURLProtocol.state.configure(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            chunks: [],
            withholdsBody: true
        )
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.protocolClasses = [TransportURLProtocol.self]
        return (
            URLSessionTransport(configuration: configuration),
            HTTPRequest(url: try #require(URL(string: "https://api.example.com/slow")))
        )
    }
}

private final class TransportURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
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
