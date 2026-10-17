import BiliModels
import Foundation

/// 弹幕纹理的有界准备 owner：拥有后台栅格化队列、在途请求、已准备待消费的记录与 LRU 纹理缓存。
///
/// 不拥有 layer 与上屏（交给 `CoreAnimationDanmakuRenderer`），也不自己监听系统内存压力：
/// 进程级 DispatchSource 由 App 组装层持有，经 renderer 转到 `handleMemoryPressure()`。
/// 释放时只取消队列中的 operation，不等待后台栅格化结束。
@MainActor
final class DanmakuTexturePreparationOwner {
    typealias Rasterize =
        @Sendable (DanmakuTextureCacheKey) -> DanmakuTexturePayload?

    struct Configuration: Sendable, Equatable {
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
        let generation: UInt64
        let key: DanmakuTextureCacheKey
        let completion: Completion
    }

    private struct Prepared {
        let generation: UInt64
        let key: DanmakuTextureCacheKey
    }

    private struct Inflight {
        let operation: Operation
        var requestIDs: [UInt64]
    }

    private var cache: DanmakuTextureLRUCache
    private var requests: [UInt64: Request] = [:]
    private var prepared: [UInt64: Prepared] = [:]
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

    var outstandingRequestCount: Int { requests.count + prepared.count }

    func prepare(
        event: DanmakuEvent,
        backingScale: Double,
        preparationID: UInt64,
        generation: UInt64,
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
                generation: generation,
                key: key
            )
            completion(.ready(payload.metrics))
            return
        }

        requests[preparationID] = Request(
            generation: generation,
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
            // Keep this OperationQueue slot occupied until MainActor either accepts
            // or discards the pixels. Otherwise queued Tasks can retain one full
            // payload per request while the main thread is busy. MainActor teardown
            // must remain cancellation-only and never wait for this queue.
            handoff.wait()
        }
        inflight[key] = Inflight(
            operation: operation,
            requestIDs: [preparationID]
        )
        queue.addOperation(operation)
    }

    func consume(
        preparationID: UInt64,
        generation: UInt64,
        expectedKey: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        guard let value = prepared.removeValue(forKey: preparationID),
            value.generation == generation,
            value.key == expectedKey
        else {
            return nil
        }
        return cache.value(for: expectedKey)
    }

    func discard(preparationID: UInt64) {
        requests.removeValue(forKey: preparationID)
        prepared.removeValue(forKey: preparationID)
    }

    func cancelAllPreparations() {
        requests.removeAll(keepingCapacity: false)
        prepared.removeAll(keepingCapacity: false)
        let operations = inflight.values.map(\.operation)
        inflight.removeAll(keepingCapacity: false)
        for operation in operations {
            operation.cancel()
        }
    }

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
                generation: request.generation,
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
