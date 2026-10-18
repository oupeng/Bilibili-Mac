import BiliApplication
import BiliModels
import Foundation

/// 弹幕数据、时间线订阅、分段加载与 presentation 的会话 owner。
///
/// 同时最多加载两个 segment；失败的 segment 在当前 identity 内不再重试（被 412 间歇风控时的一次
/// 延迟重试在 API 客户端内完成，等待期间占用加载名额）。generation 阻止切视频或 stop 后的迟到结果
/// 写回。`stop` 必须取消所有任务（含等待中的重试）并清空 scheduler/presentation。
///
/// 拥有时间线订阅 Task 与各分段的加载 Task，取消点是 `stop`（换视频时由 `start` 先调用）与
/// `deinit`；`stop` 先停止 presentation，再递增 generation、取消任务、清空 scheduler。只弱引用
/// presentation sink：呈现控制器由 App 的窗口组装持有。
@MainActor
public final class DanmakuSession: DanmakuPresentationControlling {
    /// 同时在途的分段请求上限。
    ///
    /// 调度一次最多要当前、上一（补位时）与下一分段，当前分段总排在最前，两个名额让当前分段与紧随其后的
    /// 一个并行；调大会让这三段同时在途。
    private static let maximumConcurrentSegmentLoads = 2

    private let useCase: DanmakuSegmentUseCase
    private let timeline: any PlaybackTimelineProviding
    /// 弱引用：呈现控制器由 App 的窗口组装持有，会话不延长它的生命周期。
    private weak var presentationSink: (any DanmakuPresentationSink)?
    private var authenticationInvalidationHandler: @MainActor () -> Void = {}
    private var scheduler = DanmakuScheduler()
    private var presentationEnabled = true
    private var presentationFilter = DanmakuFilter()
    private var identity: PlaybackItemIdentity?
    /// `start` 与 `stop` 时递增；加载 Task 带上发起时的值，返回后比对，不等就丢弃分段、
    /// 失败记录与账户复核报告。
    private var generation = 0
    /// 订阅时间线的 Task；弱引用 self，`stop` 与 `deinit` 时取消。
    private var timelineTask: Task<Void, Never>?
    /// 按分段号的加载 Task；完成或失败时由 Task 自己移除，`stop` 与 `deinit` 时取消。
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    /// 当前 identity 内失败过的分段，不再请求；`stop` 时清空。
    private var failedSegmentIndices: Set<Int> = []
    /// 同一会话只报告一次需要复核账户，`stop` 时重置。
    private var authenticationInvalidationReported = false

    public init(
        useCase: DanmakuSegmentUseCase,
        timeline: any PlaybackTimelineProviding,
        presentationSink: (any DanmakuPresentationSink)? = nil
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.presentationSink = presentationSink
    }

    deinit {
        timelineTask?.cancel()
        for task in loadTasks.values {
            task.cancel()
        }
    }

    public func start(for identity: PlaybackItemIdentity) {
        guard self.identity != identity else { return }
        stop()
        generation &+= 1
        self.identity = identity
        scheduler.begin(for: identity)
        let updates = timeline.timelineUpdates()
        timelineTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.handle(snapshot)
            }
        }
    }

    public func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        authenticationInvalidationHandler = handler
    }

    public func setEnabled(_ enabled: Bool) {
        guard presentationEnabled != enabled else { return }
        presentationEnabled = enabled
        scheduler.setEnabled(enabled)
        if !enabled {
            presentationSink?.clearPresentation()
        }
    }

    public func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {
        let filter = DanmakuFilter(
            showsScrolling: scrolling,
            showsTop: top,
            showsBottom: bottom
        )
        guard presentationFilter != filter else { return }
        presentationFilter = filter
        scheduler.setFilter(filter)
        presentationSink?.clearPresentation()
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        presentationSink?.setSpeedLevel(speedLevel)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        presentationSink?.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        presentationSink?.setDisplayArea(displayArea)
    }

    public func setDensity(_ density: DanmakuDensity) {
        presentationSink?.setDensity(density)
    }

    /// 幂等结束整个会话，而不只是隐藏弹幕图层。
    public func stop() {
        presentationSink?.stopPresentation()
        generation &+= 1
        timelineTask?.cancel()
        timelineTask = nil
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll(keepingCapacity: false)
        failedSegmentIndices.removeAll(keepingCapacity: false)
        authenticationInvalidationReported = false
        identity = nil
        scheduler.reset()
    }

    private func handle(_ snapshot: PlaybackTimelineSnapshot) {
        guard let identity, snapshot.identity == identity else { return }
        if let presentationSink {
            scheduler.setCatchUpWindow(presentationSink.catchUpWindowSeconds)
        }
        let batch = scheduler.consume(snapshot)
        presentationSink?.apply(
            DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
        )
        let required = scheduler.desiredSegmentIndices(for: snapshot)
        for index in required
        where
            !scheduler.containsSegment(index: index)
            && !failedSegmentIndices.contains(index)
            && loadTasks[index] == nil
            && loadTasks.count < Self.maximumConcurrentSegmentLoads
        {
            load(index: index, identity: identity, generation: generation)
        }
    }

    private func load(
        index: Int,
        identity: PlaybackItemIdentity,
        generation requestGeneration: Int
    ) {
        loadTasks[index] = Task { [weak self, useCase] in
            do {
                let segment = try await useCase.segment(index: index, for: identity)
                try Task.checkCancellation()
                guard let self,
                    self.generation == requestGeneration,
                    self.identity == identity
                else { return }
                self.scheduler.store(segment, for: identity)
                self.loadTasks[index] = nil
            } catch is CancellationError {
                guard let self,
                    self.generation == requestGeneration
                else { return }
                self.loadTasks[index] = nil
            } catch {
                guard let self,
                    self.generation == requestGeneration,
                    self.identity == identity
                else { return }
                self.loadTasks[index] = nil
                self.failedSegmentIndices.insert(index)
                if (error as? DanmakuApplicationError)?.requiresAccountRevalidation == true,
                    !self.authenticationInvalidationReported
                {
                    self.authenticationInvalidationReported = true
                    self.authenticationInvalidationHandler()
                }
            }
        }
    }
}
