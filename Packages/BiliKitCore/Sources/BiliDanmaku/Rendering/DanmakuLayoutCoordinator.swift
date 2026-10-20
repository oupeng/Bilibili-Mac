import BiliModels
import Foundation

/// 弹幕布局表的 owner：在后台测量并排车道，完成后在主线程一次性替换布局表。
///
/// 拥有已缓存分段的事件、当前布局设置、布局表、测量缓存与后台布局任务；不拥有分段加载（交给
/// `DanmakuSession`），也不拥有 layer（交给 `DanmakuMaterializer`）。布局本身由
/// `DanmakuLayoutPlanner` 计算。
///
/// 同一时刻最多一个布局任务：测量缓存在任务运行时整份移交给它、完成时交回，所以任务必须串行。
/// 设置变化与 `reset` 递增 `generation` 并取消在途任务；任务完成时（含被取消）回到主线程交回缓存，
/// generation 不等的结果整份丢弃，然后按待办开始下一个任务。设置变化后重排全部分段（传空的已有布局），
/// 只有新分段时沿用仍有效的布局、只排新分段及其后受影响的分段。窗口 live resize 时尺寸变化去抖
/// `resizeRelayoutDelay` 后才重排，期间屏上沿用旧布局。`deinit` 与 `reset` 取消任务与去抖计时。
@MainActor
final class DanmakuLayoutCoordinator {
    /// live resize 时尺寸变化的去抖时长：最后一次尺寸变化之后这么久才按新尺寸整屏重排。
    ///
    /// 拖动窗口边缘时尺寸每帧都变，逐帧重排会反复替换整屏；调小在拖动中途就开始重排，调大则松手后
    /// 旧布局多停留一会儿。
    static let resizeRelayoutDelay = Duration.milliseconds(200)

    /// 布局表被替换后在主线程调用；调用时 `layouts` 已是新表。
    var tableDidChange: (@MainActor () -> Void)?
    /// 当前布局表：按分段号，只含已缓存的分段，全部按 `layoutParameters` 计算。
    private(set) var layouts: [Int: DanmakuSegmentLayout] = [:]
    /// `layouts` 对应的设置；还没有布局表时为 nil。
    private(set) var layoutParameters: DanmakuLayoutParameters?

    private var segments: [Int: [DanmakuEvent]] = [:]
    /// 下一个布局任务使用的设置；画面尺寸还不可用时为 nil，不布局。
    private var parameters: DanmakuLayoutParameters?
    /// 设置变化与 `reset` 时递增；任务带上开始时的值，完成时不等就丢弃结果。
    private var generation: UInt64 = 0
    /// 设置变化后置位：下一个任务不沿用已有布局。
    private var needsFullRelayout = false
    /// 在途的布局任务；完成时由 `finish` 置 nil，取消后也要等它回来交还测量缓存。
    private var job: Task<Void, Never>?
    /// 测量缓存；任务运行期间移交给任务，此处为 nil。
    private var measurementCache: DanmakuTextMeasurementCache? = DanmakuTextMeasurementCache()
    /// 去抖中的尺寸变化；到点后按 `pendingParameters` 重排，期间的新变化重新计时。
    private var debounceTask: Task<Void, Never>?
    private var pendingParameters: DanmakuLayoutParameters?

    deinit {
        job?.cancel()
        debounceTask?.cancel()
    }

    /// 换上会话当前缓存的全部分段；新分段排进布局表，被淘汰或内容变了的分段的布局随之丢弃。
    func setSegments(_ segments: [Int: [DanmakuEvent]]) {
        let previous = self.segments
        self.segments = segments
        layouts = layouts.filter { index, _ in
            segments[index].map { $0 == previous[index] } ?? false
        }
        startIfNeeded()
    }

    /// 换上新的布局设置；与当前设置相同时什么都不做。
    ///
    /// `debounced` 为 true（画面尺寸变化）且已有布局表时去抖，否则立即作废在途任务并全部重排。
    func setParameters(
        _ parameters: DanmakuLayoutParameters?,
        debounced: Bool
    ) {
        if debounced, layoutParameters != nil, parameters != nil {
            guard parameters != (pendingParameters ?? self.parameters) else { return }
            pendingParameters = parameters
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.resizeRelayoutDelay)
                guard !Task.isCancelled else { return }
                self?.applyPendingParameters()
            }
            return
        }
        cancelDebounce()
        apply(parameters)
    }

    /// 换视频或会话结束：丢弃分段、布局表与在途结果；设置保留，去抖中的设置立即生效。
    func reset() {
        applyPendingParameters()
        generation &+= 1
        job?.cancel()
        segments.removeAll(keepingCapacity: false)
        layouts.removeAll(keepingCapacity: false)
        layoutParameters = nil
        needsFullRelayout = false
    }

    private func applyPendingParameters() {
        guard let pending = pendingParameters else { return }
        cancelDebounce()
        apply(pending)
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingParameters = nil
    }

    private func apply(_ parameters: DanmakuLayoutParameters?) {
        guard parameters != self.parameters else { return }
        self.parameters = parameters
        generation &+= 1
        job?.cancel()
        needsFullRelayout = true
        if parameters == nil, layoutParameters != nil {
            layouts.removeAll(keepingCapacity: false)
            layoutParameters = nil
            tableDidChange?()
        }
        startIfNeeded()
    }

    /// 没有在途任务、设置可用且有待办（设置变化，或有分段还没有布局）时开始下一个任务。
    private func startIfNeeded() {
        guard job == nil,
            let parameters,
            let cache = measurementCache,
            !segments.isEmpty,
            needsFullRelayout || segments.keys.contains(where: { layouts[$0] == nil })
        else {
            return
        }
        let existing = needsFullRelayout ? [:] : layouts
        needsFullRelayout = false
        measurementCache = nil
        let jobGeneration = generation
        let segments = segments
        job = Task { [weak self] in
            let (result, cache) = await Self.computeLayouts(
                segments: segments,
                existing: existing,
                parameters: parameters,
                cache: cache
            )
            self?.finish(
                result,
                parameters: parameters,
                segments: segments,
                cache: cache,
                generation: jobGeneration
            )
        }
    }

    /// 后台排车道；被取消时结果为 nil，测量缓存照样交回。
    ///
    /// `@concurrent` 明确要求离开主线程：测量最坏要几百毫秒，即使将来启用
    /// `NonisolatedNonsendingByDefault`，也不能继承调用方的 MainActor。
    @concurrent
    private nonisolated static func computeLayouts(
        segments: [Int: [DanmakuEvent]],
        existing: [Int: DanmakuSegmentLayout],
        parameters: DanmakuLayoutParameters,
        cache: DanmakuTextMeasurementCache
    ) async -> ([Int: DanmakuSegmentLayout]?, DanmakuTextMeasurementCache) {
        var cache = cache
        let result = DanmakuLayoutPlanner.layouts(
            for: segments,
            reusing: existing,
            parameters: parameters
        ) { event in
            cache.metrics(for: event, backingScale: parameters.backingScale)
        }
        return (result, cache)
    }

    private func finish(
        _ result: [Int: DanmakuSegmentLayout]?,
        parameters: DanmakuLayoutParameters,
        segments jobSegments: [Int: [DanmakuEvent]],
        cache: DanmakuTextMeasurementCache,
        generation jobGeneration: UInt64
    ) {
        job = nil
        measurementCache = cache
        if let result, jobGeneration == generation {
            // 任务期间被淘汰或换了内容的分段不进布局表；换了内容的随后由下一个任务重排。
            layouts = result.filter { index, _ in
                segments[index].map { $0 == jobSegments[index] } ?? false
            }
            layoutParameters = parameters
            tableDidChange?()
        }
        startIfNeeded()
    }
}
