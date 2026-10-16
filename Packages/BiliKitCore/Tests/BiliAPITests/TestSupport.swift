import BiliAPI
import BiliNetworking
import Foundation
import Testing

// BiliAPITests 共用的 fixture 读取与 HTTP 测试替身：每个 port 在本 target 内只保留一份可配置 stub。

func fixtureResponse(
    _ name: String,
    extension fileExtension: String = "json",
    contentType: String = "application/json; charset=utf-8"
) throws -> HTTPResponse {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        )
    )
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": contentType],
        body: try Data(contentsOf: url)
    )
}

/// 把十六进制文本 fixture 还原为 protobuf 正文。
func hexFixtureResponse(_ name: String) throws -> HTTPResponse {
    let text = try fixtureResponse(name, extension: "hex").body
    let digits = String(decoding: text, as: UTF8.self).filter(\.isHexDigit)
    var body = Data()
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        body.append(try #require(UInt8(digits[index..<next], radix: 16)))
        index = next
    }
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/octet-stream"],
        body: body
    )
}

func jsonResponse(_ source: String, statusCode: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json"],
        body: Data(source.utf8)
    )
}

/// 以 2xx 返回的 HTML 风控页；各域都应视为请求受限，而不是解析失败。
func htmlRiskControlResponse() -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/html; charset=utf-8"],
        body: Data("<!doctype html><title>fixture</title>".utf8)
    )
}

/// 修改 fixture 顶层 `data` 对象后重新编码，保持其余字段不变。
func mutatedFixture(
    _ name: String,
    mutate: (inout [String: Any]) throws -> Void
) throws -> HTTPResponse {
    let fixture = try fixtureResponse(name)
    var root = try #require(
        JSONSerialization.jsonObject(with: fixture.body) as? [String: Any]
    )
    var data = try #require(root["data"] as? [String: Any])
    try mutate(&data)
    root["data"] = data
    return HTTPResponse(
        statusCode: fixture.statusCode,
        headers: fixture.headers,
        body: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    )
}

/// 按顺序回放 reply 并记录请求；可挂起一次请求，也记录 invalidate。
///
/// `answersWBINavOnce` 开启时，第一个 WBI key 的 nav 请求直接得到 nav fixture，不消费顺序队列，
/// 但照常记录（`waitForRequests` 的计数也包含它）。之后再取 nav 记为测试失败并按无响应抛错：
/// 同一 client 的多个签名请求必须复用 key，多取 nav 就是风控要避免的请求放大。
/// 只把 nav 当作签名前置的测试用它；验证 WBI key 取用、刷新、顺序或匿名性的测试仍显式排 nav。
final class StubTransport: HTTPTransport, HTTPTransportInvalidating, @unchecked Sendable {
    enum Reply: Sendable {
        case response(HTTPResponse)
        /// 挂起到 `resumeSuspendedRequest()`；等待期间任务取消则抛出 `CancellationError`。
        case suspended(HTTPResponse)
        /// 返回响应前取消调用方任务。
        case cancellingCaller(HTTPResponse)
        case cancellation
    }

    private enum Gate {
        case closed
        case open
        case waiting(CheckedContinuation<Void, any Error>)
    }

    static let wbiNavPath = "/x/web-interface/nav"

    private let lock = NSLock()
    private let answersWBINavOnce: Bool
    private var answeredWBINav = false
    private var replies: [Reply]
    private var requests: [HTTPRequest] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var gate = Gate.closed
    private var invalidated = false

    init(_ replies: [Reply], answersWBINavOnce: Bool = false) {
        self.replies = replies
        self.answersWBINavOnce = answersWBINavOnce
    }

    convenience init(responses: [HTTPResponse], answersWBINavOnce: Bool = false) {
        self.init(responses.map(Reply.response), answersWBINavOnce: answersWBINavOnce)
    }

    var wasInvalidated: Bool { lock.withLock { invalidated } }

    func capturedRequests() -> [HTTPRequest] { lock.withLock { requests } }

    /// 去掉 WBI key 的 nav 请求，只留下业务请求。
    func businessRequests() -> [HTTPRequest] {
        capturedRequests().filter { $0.url.path != Self.wbiNavPath }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let isAutoAnsweredNav = answersWBINavOnce && request.url.path == Self.wbiNavPath
        let (reply, isRepeatedNav, ready) = lock.withLock {
            requests.append(request)
            let count = requests.count
            let ready = requestWaiters.filter { $0.count <= count }.map(\.continuation)
            requestWaiters.removeAll { $0.count <= count }
            let isRepeatedNav = isAutoAnsweredNav && answeredWBINav
            answeredWBINav = answeredWBINav || isAutoAnsweredNav
            let reply = isAutoAnsweredNav || replies.isEmpty ? nil : replies.removeFirst()
            return (reply, isRepeatedNav, ready)
        }
        for waiter in ready { waiter.resume() }
        if isRepeatedNav {
            Issue.record("同一 transport 上再次请求了 WBI nav")
            throw StubTransportError.noReply
        }
        if isAutoAnsweredNav {
            return try fixtureResponse("nav")
        }
        switch reply {
        case nil:
            throw StubTransportError.noReply
        case .response(let response):
            return response
        case .cancellation:
            throw CancellationError()
        case .cancellingCaller(let response):
            withUnsafeCurrentTask { $0?.cancel() }
            return response
        case .suspended(let response):
            try await waitForGate()
            return response
        }
    }

    func invalidateAndCancel() {
        lock.withLock { invalidated = true }
    }

    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = lock.withLock {
                guard requests.count < count else { return true }
                requestWaiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }

    func resumeSuspendedRequest() {
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            defer { gate = .open }
            guard case .waiting(let continuation) = gate else { return nil }
            return continuation
        }
        waiting?.resume()
    }

    private func waitForGate() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Void, any Error>? = lock.withLock {
                    if case .open = gate { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    gate = .waiting(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard case .waiting(let continuation) = gate else { return nil }
                gate = .closed
                return continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }
}

enum StubTransportError: Error {
    case noReply
}

extension BiliAPIClient {
    /// 只用一个 stub transport 的 client：认证会话失效时 invalidate 这个 stub 后继续沿用它。
    ///
    /// 验证失效后换入新 transport 的测试直接传 `transportFactory`。
    init(
        transport: any HTTPTransport,
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        historyWriteAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        self.init(
            requestAuthorizer: requestAuthorizer,
            historyWriteAuthorizer: historyWriteAuthorizer,
            transportFactory: { transport },
            timestampProvider: timestampProvider
        )
    }
}

/// 按调用次序给出授权结果（最后一项重复）并记录请求；可挂起第 N 次授权。
actor StubAuthorizer: HTTPRequestAuthorizing {
    enum Outcome: Sendable {
        case authorize
        case fail(HTTPRequestAuthorizationFailureKind)
    }

    static let cookie = "FIXTURE_AUTHORIZED"

    private let outcomes: [Outcome]
    private let suspendingCall: Int?
    private var requests: [HTTPRequest] = []
    private var reachedSuspension = false
    private var resumed = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspension: CheckedContinuation<Void, Never>?

    init(_ outcomes: Outcome..., suspendingCall: Int? = nil) {
        self.outcomes = outcomes.isEmpty ? [.authorize] : outcomes
        self.suspendingCall = suspendingCall
    }

    var authorizationCount: Int { requests.count }

    func capturedRequests() -> [HTTPRequest] { requests }

    func capturedPaths() -> [String] { requests.map(\.url.path) }

    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        requests.append(request)
        let call = requests.count
        if call == suspendingCall {
            reachedSuspension = true
            for waiter in suspensionWaiters { waiter.resume() }
            suspensionWaiters.removeAll()
            if !resumed {
                await withCheckedContinuation { suspension = $0 }
            }
        }
        switch outcomes[min(call, outcomes.count) - 1] {
        case .fail(let kind):
            throw StubAuthorizationFailure(authorizationFailureKind: kind)
        case .authorize:
            var headers = request.headers
            headers["Cookie"] = Self.cookie
            return HTTPRequest(
                url: request.url,
                method: request.method,
                headers: headers,
                body: request.body
            )
        }
    }

    func waitUntilSuspended() async {
        guard !reachedSuspension else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumed = true
        suspension?.resume()
        suspension = nil
    }
}

struct StubAuthorizationFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind: HTTPRequestAuthorizationFailureKind
}
