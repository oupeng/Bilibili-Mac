import Foundation
import Synchronization

/// 按上限累积响应正文；追加后会超过上限时拒绝，由 delegate 失败并取消该请求。
struct NativeVideoImageResponseAccumulator {
    private(set) var data = Data()
    let maximumBytes: Int

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= maximumBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

/// 通过响应头校验并在上限内收齐的响应正文。
struct NativeVideoImageResponse: Sendable {
    let data: Data
}

/// 响应头校验失败或正文超过上限。
private enum NativeVideoImageTransferError: Error {
    case invalidResponse
    case responseTooLarge
}

/// 一次请求的 data task 与取消标记：取消先于 task 创建到达时，task 一创建就被取消。
///
/// 状态只经 `Mutex` 访问；`URLSessionTask.cancel()` 在锁外调用。
private final class NativeVideoImageTaskBox: Sendable {
    /// data task 与取消标记，只在外层 `Mutex` 内读写。
    private struct State {
        var task: URLSessionTask?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func store(_ task: URLSessionTask) {
        let isCancelled = state.withLock { state in
            if !state.isCancelled { state.task = task }
            return state.isCancelled
        }
        if isCancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// session 的失效闸门：失效之后不再在该 session 上创建 task。
///
/// 创建 task 与 `invalidateAndCancel()` 在同一把锁里执行，所以 `shutdown()` 与在途请求竞争时不会
/// 在已失效的 session 上创建 task（那会抛出 Objective-C 异常）。
final class NativeVideoImageSessionGate: Sendable {
    private let isInvalidated = Mutex(false)

    func register(_ operation: () -> Void) -> Bool {
        isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return false }
            operation()
            return true
        }
    }

    func invalidate(_ session: URLSession) {
        isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return }
            isInvalidated = true
            session.invalidateAndCancel()
        }
    }
}

/// 图片 session 的 delegate：按 task 登记在途请求的 continuation 与累积正文，校验响应头、限制正文
/// 大小并拒绝 redirect。
///
/// 每个 continuation 只 resume 一次：完成、校验失败或超限时先从登记表移除再在锁外 resume。登记表
/// 只经 `Mutex` 访问；session 由 `NativeVideoImagePipeline` 持有并经 `NativeVideoImageSessionGate`
/// 失效。
final class NativeVideoImageSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    /// 一个在途 data task 的登记：请求主机（同主机校验用）、continuation、
    /// 响应头是否通过与累积的正文。
    ///
    /// 只在 `pending` 的 `Mutex` 内读写；完成、校验失败或超限时先从登记表移除，再在锁外 resume。
    private struct Pending {
        let expectedHost: String
        let continuation: CheckedContinuation<NativeVideoImageResponse, Error>
        var isAccepted = false
        var accumulator: NativeVideoImageResponseAccumulator
    }

    private let pending = Mutex<[Int: Pending]>([:])

    func response(
        for request: URLRequest,
        maximumBytes: Int,
        using session: URLSession,
        gate: NativeVideoImageSessionGate
    ) async throws -> NativeVideoImageResponse {
        guard let expectedHost = request.url?.host?.lowercased() else {
            throw NativeVideoImageTransferError.invalidResponse
        }
        let taskBox = NativeVideoImageTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var task: URLSessionDataTask?
                let registered = gate.register {
                    let dataTask = session.dataTask(with: request)
                    pending.withLock {
                        $0[dataTask.taskIdentifier] = Pending(
                            expectedHost: expectedHost,
                            continuation: continuation,
                            accumulator: NativeVideoImageResponseAccumulator(
                                maximumBytes: maximumBytes
                            )
                        )
                    }
                    taskBox.store(dataTask)
                    task = dataTask
                }
                guard registered, let task else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 图片请求不跟随 redirect，跳转目标不经来源校验，见 SECURITY-MODEL §4。
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let isAccepted = pending.withLock { pending in
            guard let http, var transfer = pending[dataTask.taskIdentifier] else {
                return false
            }
            // 只接受 2xx、HTTPS、与请求同主机、image/* 且声明长度不超上限的响应，见 SECURITY-MODEL §4。
            transfer.isAccepted =
                (200..<300).contains(http.statusCode)
                && http.url?.scheme?.lowercased() == "https"
                && http.url?.host?.lowercased() == transfer.expectedHost
                && http.mimeType?.lowercased().hasPrefix("image/") == true
                && NativeVideoImagePipeline.acceptsExpectedLength(
                    http.expectedContentLength,
                    maximumBytes: transfer.accumulator.maximumBytes
                )
            pending[dataTask.taskIdentifier] = transfer
            return transfer.isAccepted
        }
        if isAccepted {
            completionHandler(.allow)
        } else {
            fail(dataTask, with: .invalidResponse)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let accepted = pending.withLock { pending in
            guard var transfer = pending[dataTask.taskIdentifier] else { return true }
            guard transfer.accumulator.append(data) else { return false }
            pending[dataTask.taskIdentifier] = transfer
            return true
        }
        guard !accepted else { return }
        fail(dataTask, with: .responseTooLarge)
        dataTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let transfer = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) })
        else { return }
        if let error {
            transfer.continuation.resume(throwing: error)
        } else if transfer.isAccepted {
            transfer.continuation.resume(
                returning: NativeVideoImageResponse(data: transfer.accumulator.data)
            )
        } else {
            transfer.continuation.resume(
                throwing: NativeVideoImageTransferError.invalidResponse
            )
        }
    }

    private func fail(_ task: URLSessionTask, with error: NativeVideoImageTransferError) {
        pending.withLock { $0.removeValue(forKey: task.taskIdentifier) }?
            .continuation.resume(throwing: error)
    }
}
