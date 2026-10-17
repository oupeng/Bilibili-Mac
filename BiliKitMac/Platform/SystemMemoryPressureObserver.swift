import Foundation

/// 系统内存压力（warning 与 critical）的监听：拥有一个 `DispatchSourceMemoryPressure`，
/// 只把事件转给创建时给定的处理；释放哪些缓存由处理所指的对象决定。
///
/// 持有者在自己的清理点调用 `cancel()`，`deinit` 再兜底取消。取消先换成空处理再 cancel，
/// 已投递到队列的事件不会再触达已关闭的对象。`@unchecked Sendable`：只有一个 `let` source，
/// DispatchSource 的 `setEventHandler` 与 `cancel` 可以在任意线程调用。
final class SystemMemoryPressureObserver: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    /// `handler` 在 `queue` 上执行；需要 MainActor 的持有者传 `.main`。
    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func cancel() {
        source.setEventHandler {}
        source.cancel()
    }

    deinit {
        cancel()
    }
}
