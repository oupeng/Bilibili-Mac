import Foundation

/// 本 target 共用的等待替身；各测试文件不再各自复制。

/// 可等待的事件计数：记录端 `signal()`，等待端挂起到计数达到目标；等待所在 Task 被取消时抛出
/// `CancellationError`。
actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
