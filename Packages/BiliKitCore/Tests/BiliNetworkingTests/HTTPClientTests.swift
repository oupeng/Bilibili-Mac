import Foundation
import Testing

@testable import BiliNetworking

@Suite(.timeLimit(.minutes(1)))
struct HTTPClientTests {
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

        _ = URLSessionTransport(session: session, ownsSession: true)

        await observer.waitUntilInvalidated()
    }

    @Test
    func injectedSessionStaysUsableAfterTransportIsReleased() async throws {
        TransportURLProtocol.state.configure(statusCode: 204, headers: [:], chunks: [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://api.example.com/x"))

        _ = URLSessionTransport(session: session)
        // 失效的 session 不能再创建任务；注入方仍持有的 session 必须继续可用。
        let response = try await URLSessionTransport(session: session).send(
            HTTPRequest(url: url)
        )

        #expect(response.statusCode == 204)
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

private final class TransportURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
}
