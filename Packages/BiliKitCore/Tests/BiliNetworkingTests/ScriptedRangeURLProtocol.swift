import Foundation
import Synchronization

/// BiliNetworkingTests 唯一的 URLProtocol 替身：按脚本返回状态、响应头与分块正文，并记录请求、
/// 启动与停止。
///
/// 每个 suite 使用自己的子类取得独立 state，避免并行 suite 互相覆盖脚本。
class ScriptedRangeURLProtocol: URLProtocol, @unchecked Sendable {
    class var state: ScriptedRangeURLProtocolState {
        preconditionFailure("子类必须提供独立 state")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.state
        let script = state.begin(request: request)
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 闸门关闭时正文不送达，任务只能由 client 取消后经 `stopLoading` 结束。
        guard !script.withholdsBody else { return }
        for chunk in script.chunks {
            guard !state.wasStopped else { return }
            state.markDelivered(chunk.count)
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.state.markStopped() }
}

struct RangeURLProtocolScript: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    /// 只发响应头、始终不放行正文（不读取 `chunks`），用于证明 client 不等待正文即可拒绝或取消。
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
        var stopped = false
        var delivered = 0
        var capturedRequest: URLRequest?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var deliveryWaiters: [(bytes: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var wasStopped: Bool { state.withLock { $0.stopped } }
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

    func begin(request: URLRequest) -> RangeURLProtocolScript {
        let (script, waiters) = state.withLock { state in
            state.capturedRequest = request
            defer { state.startWaiters.removeAll() }
            return (state.script, state.startWaiters)
        }
        for waiter in waiters { waiter.resume() }
        return script
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

    func markStopped() {
        let waiters = state.withLock { state in
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
