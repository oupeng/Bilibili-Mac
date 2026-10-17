import AppKit
import BiliNetworking
import BiliVideoCollectionUI
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

enum NativeVideoImageLoadOrigin: Equatable {
    case memoryCache
    case network

    /// 刚从网络到达的图片淡入；内存缓存命中直接显示。
    var shouldFadeIn: Bool { self == .network }
}

/// 动图的原始编码数据，由 `NativeAnimatedImagePlayback` 边解码边播放；不预先解出所有帧。
///
/// 用引用类型：缓存命中返回同一个实例，播放端按身份判断是不是同一张动图，不比较数据字节。
final class NativeAnimatedImage: Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

struct NativeVideoImageLoadResult: Sendable {
    /// 第一帧（静态图就是整张图），按用途限制解码尺寸。
    let image: CGImage
    let origin: NativeVideoImageLoadOrigin
    /// 只有保留动图的用途、且源图是可播放的多帧图时才有。
    let animation: NativeAnimatedImage?
}

/// 评论动图的播放门槛：超过任一上限只显示第一帧，避免逐帧解码持续占用 CPU 与内存。
enum NativeAnimatedImagePolicy {
    /// 帧数上限，超过时只显示第一帧。
    static let maximumFrameCount = 1_000
    /// 每帧像素数上限：动图按原尺寸逐帧解码，过大的原图只显示第一帧，避免持续占用 CPU。
    static let maximumPixelCount = 2_048 * 2_048

    static func animation(from data: Data, source: CGImageSource) -> NativeAnimatedImage? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1, frameCount <= maximumFrameCount,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumPixelCount else { return nil }
        return NativeAnimatedImage(data: data)
    }
}

enum NativeVideoImageVariant: Hashable, Sendable {
    case cover
    case avatar
    case commentEmote
    case commentPicture
    case commentPicturePreview
    case trendingSearchIcon

    /// 是否保留动图数据：评论图片的列表格子与预览会播放动图，其余用途只用第一帧。
    var retainsAnimation: Bool {
        switch self {
        case .commentPicture, .commentPicturePreview:
            true
        case .cover, .avatar, .commentEmote, .trendingSearchIcon:
            false
        }
    }

    var maximumDecodedPixelSize: Int {
        switch self {
        case .cover:
            640
        case .avatar:
            96
        case .commentEmote:
            128
        case .commentPicture:
            1_024
        case .commentPicturePreview:
            3_840
        case .trendingSearchIcon:
            96
        }
    }

    /// 单次响应允许的最大字节数。
    ///
    /// 只有评论图片预览请求原图，按 B 站评论图片 20 MB 的上传上限放宽；其余用途请求的是缩小图或
    /// 小图，保持较低上限。
    var maximumResponseBytes: Int {
        switch self {
        case .commentPicturePreview:
            20 * 1_024 * 1_024
        case .cover, .avatar, .commentEmote, .commentPicture, .trendingSearchIcon:
            8 * 1_024 * 1_024
        }
    }
}

struct NativeVideoImageKey: Hashable, Sendable {
    let url: URL
    let variant: NativeVideoImageVariant
}

struct NativeVideoImageResponseAccumulator {
    private(set) var data = Data()
    let maximumBytes: Int

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= maximumBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

private struct NativeVideoImageResponse: Sendable {
    let data: Data
}

private enum NativeVideoImageTransferError: Error {
    case invalidResponse
    case responseTooLarge
}

private final class NativeVideoImageTaskBox: Sendable {
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

/// 一个等待者只 resume 一次：先完成则缓存结果，先挂起则由 `finish` 恢复；两边都在锁外 resume。
final class NativeVideoImageWaiter: Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<NativeVideoImageLoadResult?, Never>)
        case completed(NativeVideoImageLoadResult?)
    }

    private let state = Mutex(State.waiting)

    func value() async -> NativeVideoImageLoadResult? {
        await withCheckedContinuation { continuation in
            let completed: NativeVideoImageLoadResult?? = state.withLock { state in
                switch state {
                case .waiting:
                    state = .suspended(continuation)
                    return nil
                case .suspended:
                    preconditionFailure("image waiter may only be awaited once")
                case .completed(let result):
                    return .some(result)
                }
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    func finish(with result: NativeVideoImageLoadResult?) {
        let continuation: CheckedContinuation<NativeVideoImageLoadResult?, Never>? =
            state.withLock { state in
                switch state {
                case .waiting:
                    state = .completed(result)
                    return nil
                case .suspended(let continuation):
                    state = .completed(result)
                    return continuation
                case .completed:
                    return nil
                }
            }
        continuation?.resume(returning: result)
    }
}

private final class NativeVideoImageSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
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

/// 原生界面远端图片的加载与解码缓存：同一 URL 与 variant 的并发请求合并为一次下载。
///
/// 拥有无 Cookie 的 ephemeral session、做响应校验与大小上限的 session delegate、内存缓存与在途下载
/// Task；不拥有显示与动图播放（交给视图层）。`shutdown()` 先取消在途 Task 并唤醒等待者，再经
/// `sessionGate` 失效 session；deinit 兜底失效。可变状态由 `Mutex` 隔离。
final class NativeVideoImagePipeline: Sendable {
    private struct InFlight {
        let id: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: NativeVideoImageWaiter]
    }

    private struct State {
        var cache: NativeVideoImageCache
        var inFlight: [NativeVideoImageKey: InFlight] = [:]
        var nextRequestID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var isShutdown = false
    }

    private enum Lookup {
        case unavailable
        case cached(CGImage, NativeAnimatedImage?)
        case request(
            requestID: UInt64,
            waiterID: UInt64,
            NativeVideoImageWaiter,
            startsNetwork: Bool
        )
    }

    private let state: Mutex<State>
    private let sessionGate = NativeVideoImageSessionGate()
    private let sessionDelegate = NativeVideoImageSessionDelegate()
    private let session: URLSession

    init(cacheLimits: NativeVideoImageCacheLimits) {
        state = Mutex(State(cache: NativeVideoImageCache(limits: cacheLimits)))
        session = URLSession(
            configuration: .credentialFreeEphemeral(),
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        sessionGate.invalidate(session)
    }

    func cachedImage(
        for url: URL,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        state.withLock { state in
            guard !state.isShutdown else { return nil }
            return state.cache.image(for: NativeVideoImageKey(url: url, variant: variant))
        }
    }

    /// 已缓存图片的动图数据；静态图或没有缓存时为 nil。
    func cachedAnimation(
        for url: URL,
        variant: NativeVideoImageVariant
    ) -> NativeAnimatedImage? {
        state.withLock { state in
            guard !state.isShutdown else { return nil }
            return state.cache.animation(for: NativeVideoImageKey(url: url, variant: variant))
        }
    }

    func image(
        for url: URL,
        variant: NativeVideoImageVariant
    ) async -> NativeVideoImageLoadResult? {
        guard !Task.isCancelled, Self.acceptsRequestURL(url) else { return nil }

        let key = NativeVideoImageKey(url: url, variant: variant)

        switch lookup(for: key) {
        case .unavailable:
            return nil
        case .cached(let image, let animation):
            return NativeVideoImageLoadResult(
                image: image,
                origin: .memoryCache,
                animation: animation
            )
        case .request(let requestID, let waiterID, let waiter, let startsNetwork):
            if startsNetwork {
                startRequest(key: key, requestID: requestID)
            }
            let result = await withTaskCancellationHandler {
                await waiter.value()
            } onCancel: {
                self.cancelWaiter(key: key, requestID: requestID, waiterID: waiterID)
            }
            guard isActive, !Task.isCancelled else {
                return nil
            }
            return result
        }
    }

    /// 用户保存原图时取原始响应数据：不解码、不缓存，响应校验与大小上限与图片请求相同；失败、取消
    /// 或已关闭时为 nil。
    func originalData(
        for url: URL,
        variant: NativeVideoImageVariant
    ) async -> Data? {
        guard isActive, !Task.isCancelled, Self.acceptsRequestURL(url) else { return nil }
        let data = try? await fetchData(for: url, maximumBytes: variant.maximumResponseBytes)
        guard isActive, !Task.isCancelled, let data, Self.isBitmapImage(data) else { return nil }
        return data
    }

    /// 只请求过公开 HTTPS 基线的地址（拒绝 IP、本机与内网域名、非 443 端口）；图片加载与保存原图共用。
    nonisolated static func acceptsRequestURL(_ url: URL) -> Bool {
        PublicHTTPSURLPolicy().allows(url)
    }

    /// 数据能被 ImageIO 识别为位图（JPEG、PNG、GIF、WebP 等）；SVG、HTML 等不算，保存时拒绝。
    nonisolated static func isBitmapImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) != nil
        else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// 无 Cookie 的请求经同一个 session delegate 做响应校验与大小上限；图片加载与保存原图共用。
    private func fetchData(for url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        return try await sessionDelegate.response(
            for: request,
            maximumBytes: maximumBytes,
            using: session,
            gate: sessionGate
        ).data
    }

    /// 系统内存压力时清空已解码的缓存；在途请求照常完成并写回，之后的请求照常进行。
    func discardCachedImages() {
        state.withLock { state in
            guard !state.isShutdown else { return }
            state.cache.removeAll()
        }
    }

    func shutdown() {
        let inFlight: [InFlight]? = state.withLock { state in
            guard !state.isShutdown else { return nil }
            state.isShutdown = true
            state.cache.removeAll()
            let requests = Array(state.inFlight.values)
            state.inFlight.removeAll()
            return requests
        }
        guard let inFlight else { return }
        for request in inFlight { request.task?.cancel() }
        for waiter in inFlight.flatMap({ $0.waiters.values }) { waiter.finish(with: nil) }
        sessionGate.invalidate(session)
    }

    nonisolated static func acceptsExpectedLength(_ length: Int64, maximumBytes: Int) -> Bool {
        length < 0 || length <= maximumBytes
    }

    nonisolated static func decodeImage(
        _ data: Data,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: variant.maximumDecodedPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        )
    }

    /// 保留动图的用途里，多帧且在播放门槛内的源图返回动图数据。
    nonisolated static func decodeAnimation(
        _ data: Data,
        variant: NativeVideoImageVariant
    ) -> NativeAnimatedImage? {
        guard variant.retainsAnimation,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return NativeAnimatedImagePolicy.animation(from: data, source: source)
    }

    private func loadNetworkImage(
        for key: NativeVideoImageKey
    ) async -> NativeVideoImageLoadResult? {
        do {
            let data = try await fetchData(
                for: key.url,
                maximumBytes: key.variant.maximumResponseBytes
            )
            guard
                !Task.isCancelled,
                let image = Self.decodeImage(data, variant: key.variant)
            else { return nil }
            let animation = Self.decodeAnimation(data, variant: key.variant)
            guard store(image, animation: animation, for: key) else { return nil }
            return NativeVideoImageLoadResult(image: image, origin: .network, animation: animation)
        } catch {
            return nil
        }
    }

    private func lookup(for key: NativeVideoImageKey) -> Lookup {
        state.withLock { state in
            guard !state.isShutdown else { return .unavailable }
            if let image = state.cache.image(for: key) {
                return .cached(image, state.cache.animation(for: key))
            }
            state.nextWaiterID &+= 1
            let waiterID = state.nextWaiterID
            let waiter = NativeVideoImageWaiter()
            if var existing = state.inFlight[key] {
                existing.waiters[waiterID] = waiter
                state.inFlight[key] = existing
                return .request(
                    requestID: existing.id,
                    waiterID: waiterID,
                    waiter,
                    startsNetwork: false
                )
            }
            state.nextRequestID &+= 1
            let requestID = state.nextRequestID
            state.inFlight[key] = InFlight(
                id: requestID,
                task: nil,
                waiters: [waiterID: waiter]
            )
            return .request(
                requestID: requestID,
                waiterID: waiterID,
                waiter,
                startsNetwork: true
            )
        }
    }

    /// 在锁外创建网络 Task；请求已被取消或关闭时立即取消刚创建的 Task。
    private func startRequest(key: NativeVideoImageKey, requestID: UInt64) {
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await loadNetworkImage(for: key)
            finishRequest(key: key, requestID: requestID, result: result)
        }
        let isAttached = state.withLock { state in
            guard var active = state.inFlight[key], active.id == requestID else {
                return false
            }
            active.task = task
            state.inFlight[key] = active
            return true
        }
        if !isAttached { task.cancel() }
    }

    private var isActive: Bool {
        state.withLock { !$0.isShutdown }
    }

    private func cancelWaiter(
        key: NativeVideoImageKey,
        requestID: UInt64,
        waiterID: UInt64
    ) {
        let removed: (NativeVideoImageWaiter, Task<Void, Never>?)? = state.withLock { state in
            guard var request = state.inFlight[key], request.id == requestID,
                let waiter = request.waiters.removeValue(forKey: waiterID)
            else { return nil }
            guard request.waiters.isEmpty else {
                state.inFlight[key] = request
                return (waiter, nil)
            }
            state.inFlight[key] = nil
            return (waiter, request.task)
        }
        guard let (waiter, task) = removed else { return }
        waiter.finish(with: nil)
        task?.cancel()
    }

    private func finishRequest(
        key: NativeVideoImageKey,
        requestID: UInt64,
        result: NativeVideoImageLoadResult?
    ) {
        let waiters: [NativeVideoImageWaiter] = state.withLock { state in
            guard let request = state.inFlight[key], request.id == requestID else {
                return []
            }
            state.inFlight[key] = nil
            return Array(request.waiters.values)
        }
        for waiter in waiters { waiter.finish(with: result) }
    }

    private func store(
        _ image: CGImage,
        animation: NativeAnimatedImage?,
        for key: NativeVideoImageKey
    ) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            state.cache.insert(image, animation: animation, for: key)
            return true
        }
    }
}

/// 卡片与网格经 `NativeVideoImageLoading` 取图：只用封面与头像两种用途，结果只带第一帧与是否淡入。
extension NativeVideoImagePipeline: NativeVideoImageLoading {
    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        cachedImage(for: url, variant: NativeVideoImageVariant(kind))
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        guard let result = await image(for: url, variant: NativeVideoImageVariant(kind)) else {
            return nil
        }
        return NativeVideoCardImage(image: result.image, fadesIn: result.origin.shouldFadeIn)
    }
}

extension NativeVideoImageVariant {
    init(_ kind: NativeVideoCardImageKind) {
        switch kind {
        case .cover: self = .cover
        case .avatar: self = .avatar
        }
    }
}

/// 管线的生命周期 owner：持有系统内存压力监听，shutdown 时先取消监听再关闭管线。
final class NativeVideoImagePipelineOwner {
    let pipeline: NativeVideoImagePipeline
    private let memoryPressure: SystemMemoryPressureObserver

    init(cacheLimits: NativeVideoImageCacheLimits) {
        let pipeline = NativeVideoImagePipeline(cacheLimits: cacheLimits)
        self.pipeline = pipeline
        memoryPressure = SystemMemoryPressureObserver(
            queue: .global(qos: .utility)
        ) { [weak pipeline] in
            pipeline?.discardCachedImages()
        }
    }

    func shutdown() {
        memoryPressure.cancel()
        pipeline.shutdown()
    }

    deinit {
        shutdown()
    }
}
