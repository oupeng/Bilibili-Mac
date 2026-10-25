import Foundation
import Synchronization

/// BiliNetworkingTests 唯一的 URLProtocol 替身：按脚本返回状态、响应头与分块正文，并记录请求、
/// 启动与停止。
///
/// 每个 suite 使用自己的子类取得独立 state，避免并行 suite 互相覆盖脚本。
///
/// 停止按实例记：URLSession 在 client 取消或结束之后异步调用 `stopLoading`，上一个请求的停止可能晚于
/// 下一个用例的 `configure` 才到；共享一个停止标志的话，它会让下一个请求的正文提前中断、永远不报告
/// 加载结束，没有 `Content-Type` 的响应头（等内容嗅探）或 3xx（等正文传完）就一直不交给 delegate。
class ScriptedRangeURLProtocol: URLProtocol, @unchecked Sendable {
    class var state: ScriptedRangeURLProtocolState {
        preconditionFailure("子类必须提供独立 state")
    }

    /// 本实例在 state 里的请求序号与是否已被停止；`startLoading` 与 `stopLoading` 之外不读写。
    private let lifecycle = Mutex((requestID: 0, isStopped: false))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.state
        let (script, requestID) = state.begin(request: request)
        lifecycle.withLock { $0.requestID = requestID }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: script.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: script.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // 与真实 HTTP 一致：带 Location 的 3xx 先作为重定向交给 session。被拒绝的重定向响应在正文传完后才
        // 作为最终响应交付，所以闸门关闭时连响应头也不送达。
        if (300..<400).contains(script.statusCode),
            let location = script.headers["Location"].flatMap(URL.init(string:))
        {
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: location),
                redirectResponse: response
            )
            guard !script.withholdsBody else { return }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 闸门关闭时正文不送达，任务只能由 client 取消后经 `stopLoading` 结束。
        guard !script.withholdsBody else { return }
        for chunk in script.chunks {
            guard !lifecycle.withLock({ $0.isStopped }) else { return }
            state.markDelivered(chunk.count)
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let requestID = lifecycle.withLock { lifecycle in
            lifecycle.isStopped = true
            return lifecycle.requestID
        }
        Self.state.markStopped(requestID: requestID)
    }
}

struct RangeURLProtocolScript: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    /// 只发响应头、始终不放行正文（不读取 `chunks`），用于证明 client 不等待正文即可拒绝或取消；
    /// 带 Location 的 3xx 只报告重定向。
    let withholdsBody: Bool
}

final class ScriptedRangeURLProtocolState: Sendable {
    private struct State {
        var script = RangeURLProtocolScript(
            statusCode: 500,
            headers: [:],
            chunks: [],
            withholdsBody: false
        )
        /// 最近一次开始的请求序号；只有它的停止计入 `stopped`。
        var latestRequestID = 0
        /// 最近一次开始的请求是否已被停止。
        var stopped = false
        var delivered = 0
        var capturedRequest: URLRequest?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var deliveryWaiters: [(bytes: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var lastRequest: URLRequest? { state.withLock { $0.capturedRequest } }

    func configure(
        statusCode: Int,
        headers: [String: String],
        chunks: [Data],
        withholdsBody: Bool = false
    ) {
        state.withLock { state in
            state.script = RangeURLProtocolScript(
                statusCode: statusCode,
                headers: headers,
                chunks: chunks,
                withholdsBody: withholdsBody
            )
            state.stopped = false
            state.delivered = 0
            state.capturedRequest = nil
        }
    }

    /// 登记一次开始的请求，返回它要执行的脚本与请求序号；序号交回 `markStopped(requestID:)`。
    func begin(request: URLRequest) -> (RangeURLProtocolScript, requestID: Int) {
        let (script, requestID, waiters) = state.withLock { state in
            state.capturedRequest = request
            state.latestRequestID += 1
            state.stopped = false
            defer { state.startWaiters.removeAll() }
            return (state.script, state.latestRequestID, state.startWaiters)
        }
        for waiter in waiters { waiter.resume() }
        return (script, requestID)
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let isStarted = state.withLock { state in
                guard state.capturedRequest == nil else { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if isStarted { continuation.resume() }
        }
    }

    /// 迟到的、属于更早请求的停止不计入，`waitUntilStopped` 只等最近一次开始的请求。
    func markStopped(requestID: Int) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard requestID == state.latestRequestID else { return [] }
            state.stopped = true
            defer { state.stopWaiters.removeAll() }
            return state.stopWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let isStopped = state.withLock { state in
                guard !state.stopped else { return true }
                state.stopWaiters.append(continuation)
                return false
            }
            if isStopped { continuation.resume() }
        }
    }

    func markDelivered(_ count: Int) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.delivered += count
            let delivered = state.delivered
            let ready = state.deliveryWaiters.filter { $0.bytes <= delivered }.map(\.continuation)
            state.deliveryWaiters.removeAll { $0.bytes <= delivered }
            return ready
        }
        for waiter in ready { waiter.resume() }
    }

    /// 等到脚本已向 URLSession 交付至少 `bytes` 字节正文。
    func waitUntilDelivered(bytes: Int) async {
        await withCheckedContinuation { continuation in
            let isDelivered = state.withLock { state in
                guard state.delivered < bytes else { return true }
                state.deliveryWaiters.append((bytes, continuation))
                return false
            }
            if isDelivered { continuation.resume() }
        }
    }
}
