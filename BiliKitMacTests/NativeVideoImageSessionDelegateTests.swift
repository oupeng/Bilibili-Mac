import BiliNetworking
import Foundation
import Synchronization
import Testing

@testable import BiliKit

/// 图片 session delegate 拒绝 redirect 时不等 3xx 正文：立即让请求失败并取消 task，正文卡住也不拖到空闲超时。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeVideoImageSessionDelegateTests {
    @Test
    func redirectFailsImmediatelyAndCancelsTaskWithoutWaitingForBody() async throws {
        let delegate = NativeVideoImageSessionDelegate()
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.protocolClasses = [StalledRedirectURLProtocol.self]
        // 空闲超时远长于测试时限：请求只有在重定向回调里结束才能在时限内完成。
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let gate = NativeVideoImageSessionGate()
        let stopped = StalledRedirectURLProtocol.begin()
        let request = URLRequest(url: try #require(URL(string: "https://i0.hdslb.com/bfs/a.jpg")))

        await #expect(throws: (any Error).self) {
            try await delegate.response(
                for: request,
                maximumBytes: 1_024,
                using: session,
                gate: gate
            )
        }
        try await stopped.value()
        gate.invalidate(session)
    }
}

/// 只报告一次 302 重定向、之后既不交付响应也不交付正文的 URLProtocol，模拟 3xx 正文卡住。
///
/// 每个测试先 `begin()` 取得本次请求的停止信号；`stopLoading` 说明 task 已被取消。
private final class StalledRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stopSignal = Mutex<OneShotResult<Void>?>(nil)

    static func begin() -> OneShotResult<Void> {
        let signal = OneShotResult<Void>()
        stopSignal.withLock { $0 = signal }
        return signal
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let location = URL(string: "https://example.com/elsewhere.jpg"),
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString]
            )
        else { return }
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: location),
            redirectResponse: response
        )
    }

    override func stopLoading() {
        Self.stopSignal.withLock { $0 }?.resolve(.success(()))
    }
}
