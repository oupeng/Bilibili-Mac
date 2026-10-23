import BiliModels
import Foundation

/// 弹幕纹理的有界准备 owner：拥有后台栅格化队列、在途请求、已准备待消费的记录与 LRU 纹理缓存。
///
/// 不拥有 layer 与挂上（交给 `CoreAnimationDanmakuRenderer`），也不自己监听系统内存压力：监听由
/// App 的窗口 adapter（`WindowAdapters.live`）持有，经 renderer 转到 `handleMemoryPressure()`。
/// 状态只在 MainActor 上读写；栅格化在后台队列执行，结果经 `Task { @MainActor }` 交回，同一 key
/// 的并发请求共用一个 operation。作废的准备由调用方按准备 ID 丢弃（准备 ID 单调递增、不复用），
/// owner 不另做 generation 校验。释放时只取消队列中的 operation，不等待后台栅格化结束。
@MainActor
final class DanmakuTexturePreparationOwner {
    typealias Rasterize =
        @Sendable (DanmakuTextureCacheKey) -> DanmakuTexturePayload?

    /// 准备队列的并发数与未完成请求上限，以及纹理缓存的字节上限。
    struct Configuration: Sendable, Equatable {
        /// 栅格化最多 2 个并发；未完成请求（排队中加已就绪未取走）的上限与活动弹幕硬上限同为 640。
        ///
        /// 并发越高 seek 或整屏替换时缺的纹理准备得越快，但同时占用的 CPU 与像素缓冲越多；
        /// 请求上限低于活动上限会让高峰期在准备阶段就以容量不足丢弃。
        static let production = Configuration(
            maximumConcurrentOperations: 2,
            maximumOutstandingRequests:
                DanmakuLaneConfiguration.hardMaximumActiveCount,
            cacheLimits: .production
        )

        let maximumConcurrentOperations: Int
        let maximumOutstandingRequests: Int
        let cacheLimits: DanmakuTextureLRUCache.Limits
    }

    typealias Completion =
        @MainActor @Sendable (
            DanmakuPreparationResult
        ) -> Void

    private struct Request {
        let key: DanmakuTextureCacheKey
        let completion: Completion
    }

    private struct Prepared {
        let key: DanmakuTextureCacheKey
    }

    /// 同一 key 正在栅格化的 operation，以及等它结果的全部准备 ID。
    private struct Inflight {
        let operation: Operation
        var requestIDs: [UInt64]
    }

    private var cache: DanmakuTextureLRUCache
    /// 已发起、等待栅格化结果的请求，按准备 ID。
    private var requests: [UInt64: Request] = [:]
    /// 已就绪、等 `consume` 取走的准备；像素本身只在 `cache` 里。
    private var prepared: [UInt64: Prepared] = [:]
    /// 按 key 去重的在途栅格化。
    private var inflight: [DanmakuTextureCacheKey: Inflight] = [:]
    private let configuration: Configuration
    private let queue: OperationQueue
    private let rasterize: Rasterize

    init(
        configuration: Configuration = .production,
        rasterize: @escaping Rasterize = {
            DanmakuTextureRasterizer.rasterize(key: $0)
        }
    ) {
        precondition(configuration.maximumConcurrentOperations > 0)
        precondition(configuration.maximumOutstandingRequests > 0)
        self.configuration = configuration
        self.rasterize = rasterize
        cache = DanmakuTextureLRUCache(limits: configuration.cacheLimits)
        queue = OperationQueue()
        queue.name = "com.shirokyan.BiliKit.danmaku-texture-preparation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount =
            configuration.maximumConcurrentOperations
    }

    deinit {
        queue.cancelAllOperations()
    }

    /// 排队与已就绪未取走的请求总数，对照 `maximumOutstandingRequests`。
    var outstandingRequestCount: Int { requests.count + prepared.count }

    /// 发起一次准备：缓存命中或立即拒绝时同步回调，否则栅格化完成后在 MainActor 回调。
    ///
    /// 同一准备 ID 尚未结束时再次发起按容量拒绝。
    func prepare(
        event: DanmakuEvent,
        backingScale: Double,
        preparationID: UInt64,
        completion: @escaping Completion
    ) {
        guard requests[preparationID] == nil,
            prepared[preparationID] == nil,
            outstandingRequestCount
                < configuration.maximumOutstandingRequests
        else {
            completion(.rejected(.capacity))
            return
        }
        guard
            let key = DanmakuTextureRasterizer.key(
                event: event,
                backingScale: backingScale
            )
        else {
            completion(.rejected(.invalidInput))
            return
        }
        if let payload = cache.value(for: key) {
            prepared[preparationID] = Prepared(
                key: key
            )
            completion(.ready(payload.metrics))
            return
        }

        requests[preparationID] = Request(
            key: key,
            completion: completion
        )
        if var existing = inflight[key] {
            existing.requestIDs.append(preparationID)
            inflight[key] = existing
            return
        }

        let rasterize = rasterize
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            guard operation?.isCancelled == false else { return }
            let payload = rasterize(key)
            guard operation?.isCancelled == false else { return }
            let handoff = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { handoff.signal() }
                self?.finish(key: key, payload: payload)
            }
            // 让这个 operation 一直占着队列槽位，直到 MainActor 接收或丢弃像素；
            // 否则主线程忙时排队的 Task 各自持有一份完整像素，堆积不再受并发数限制。MainActor
            // 上的拆除只能取消、绝不能等待这个队列，否则会与这里的等待互相阻塞。
            handoff.wait()
        }
        inflight[key] = Inflight(
            operation: operation,
            requestIDs: [preparationID]
        )
        queue.addOperation(operation)
    }

    /// 取走已就绪的纹理；key 与发起时不一致、或纹理已被缓存淘汰时返回 nil，
    /// 准备记录都会被移除。
    func consume(
        preparationID: UInt64,
        expectedKey: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        guard let value = prepared.removeValue(forKey: preparationID),
            value.key == expectedKey
        else {
            return nil
        }
        return cache.value(for: expectedKey)
    }

    /// 丢弃一次准备；它所在 key 的在途栅格化已没有任何请求在等时一并取消。
    ///
    /// 拖动进度条时每一步都会作废上一步的准备，不取消的话排队的 operation 仍会逐个栅格化作废的纹理，
    /// 新的准备排在它们后面被拖慢。已在执行的 operation 收到取消后丢弃结果，不交回主线程。
    func discard(preparationID: UInt64) {
        prepared.removeValue(forKey: preparationID)
        guard let request = requests.removeValue(forKey: preparationID),
            let work = inflight[request.key],
            !work.requestIDs.contains(where: { requests[$0] != nil })
        else {
            return
        }
        inflight[request.key] = nil
        work.operation.cancel()
    }

    /// 取消全部请求、已就绪记录与在途 operation；被取消的请求不再回调，缓存保留。
    func cancelAllPreparations() {
        requests.removeAll(keepingCapacity: false)
        prepared.removeAll(keepingCapacity: false)
        let operations = inflight.values.map(\.operation)
        inflight.removeAll(keepingCapacity: false)
        for operation in operations {
            operation.cancel()
        }
    }

    /// 栅格化结果交回：放进缓存并通知该 key 的全部等待请求；栅格化失败或放不进缓存都按 `oversized`
    /// 拒绝。
    ///
    /// 在途记录已被取消清掉时直接丢弃结果。
    private func finish(
        key: DanmakuTextureCacheKey,
        payload: DanmakuTexturePayload?
    ) {
        guard let work = inflight.removeValue(forKey: key) else { return }
        let acceptedPayload = payload.flatMap { value in
            cache.insert(value, for: key) ? value : nil
        }
        for preparationID in work.requestIDs {
            guard let request = requests.removeValue(forKey: preparationID)
            else {
                continue
            }
            guard let acceptedPayload else {
                request.completion(.rejected(.oversized))
                continue
            }
            prepared[preparationID] = Prepared(
                key: request.key
            )
            request.completion(.ready(acceptedPayload.metrics))
        }
    }

    /// 系统内存压力时丢弃缓存与未完成请求；等待中的调用方收到 `.capacity` 拒绝。
    func handleMemoryPressure() {
        let completions = requests.values.map(\.completion)
        requests.removeAll(keepingCapacity: false)
        prepared.removeAll(keepingCapacity: false)
        let operations = inflight.values.map(\.operation)
        inflight.removeAll(keepingCapacity: false)
        cache.removeAll()
        for operation in operations {
            operation.cancel()
        }
        for completion in completions {
            completion(.rejected(.capacity))
        }
    }
}
