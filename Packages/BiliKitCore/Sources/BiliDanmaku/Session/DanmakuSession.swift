import BiliApplication
import BiliModels
import Foundation

@MainActor
/// 弹幕数据、时间线订阅、分段加载与 presentation 的会话 owner。
///
/// 同时最多加载两个 segment；失败的 segment 在当前 identity 内不再重试（被 412 间歇风控时的一次
/// 延迟重试在 API 客户端内完成，等待期间占用加载名额）。generation 阻止切视频或 stop 后的迟到结果
/// 写回。`stop` 必须取消所有任务（含等待中的重试）并清空 scheduler/presentation。
public final class DanmakuSession: DanmakuPresentationControlling {
    private let useCase: DanmakuSegmentUseCase
    private let timeline: any PlaybackTimelineProviding
    private weak var presentationSink: (any DanmakuPresentationSink)?
    private var authenticationInvalidationHandler: @MainActor () -> Void = {}
    private var scheduler = DanmakuScheduler()
    private var presentationEnabled = true
    private var presentationFilter = DanmakuFilter()
    private var identity: PlaybackItemIdentity?
    private var generation = 0
    private var timelineTask: Task<Void, Never>?
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    private var failedSegmentIndices: Set<Int> = []
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
            && loadTasks.count < 2
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
