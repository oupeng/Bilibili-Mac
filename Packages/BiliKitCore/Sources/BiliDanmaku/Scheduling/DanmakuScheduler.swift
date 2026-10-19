import BiliApplication
import BiliModels
import Foundation

/// 调度前按弹幕模式可见性与权重筛掉事件的值类型；模式开关来自用户偏好，由弹幕会话写入。
public struct DanmakuFilter: Sendable, Equatable {
    public var showsScrolling: Bool
    public var showsTop: Bool
    public var showsBottom: Bool

    public init(
        showsScrolling: Bool = true,
        showsTop: Bool = true,
        showsBottom: Bool = true
    ) {
        self.showsScrolling = showsScrolling
        self.showsTop = showsTop
        self.showsBottom = showsBottom
    }

    /// 权重为负的弹幕不显示；下限固定为 0，不随偏好变化。
    private static let minimumWeight = 0

    func allows(_ event: DanmakuEvent) -> Bool {
        guard event.weight >= Self.minimumWeight else { return false }
        return switch event.mode {
        case .scrolling: showsScrolling
        case .top: showsTop
        case .bottom: showsBottom
        }
    }
}

/// 某一播放 identity／落地代号的增量呈现指令；`clearsExisting` 表示先清掉屏上的弹幕。
///
/// `catchesUp` 表示这批弹幕是补位：每条都按自己的时间点进场，呈现时从已经走过的位置开始，
/// 而不是从当前时刻重新进场。两者可以同时为真：同一 batch 里先清屏，再按同一快照补位。
public struct DanmakuBatch: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    /// 生成这批指令的快照的 `landingGeneration`；呈现端只接受与当前快照一致的 batch。
    public let landingGeneration: UInt64
    public let events: [DanmakuEvent]
    public let clearsExisting: Bool
    public let catchesUp: Bool

    public init(
        identity: PlaybackItemIdentity,
        landingGeneration: UInt64,
        events: [DanmakuEvent],
        clearsExisting: Bool,
        catchesUp: Bool
    ) {
        self.identity = identity
        self.landingGeneration = landingGeneration
        self.events = events
        self.clearsExisting = clearsExisting
        self.catchesUp = catchesUp
    }
}

/// 以统一媒体时间线调度弹幕，并维护有界分段缓存与去重游标。
///
/// 只消费时间线给出的 seek 事实，不从位置序列推断跳转：`seeking` 时清屏一次、之后不投递；
/// `landingGeneration` 变化（落地、换项、续播起点、clear）时在同一 batch 里清屏并在落点补发回看窗口
/// （`setCatchUpWindow`）内本应仍在屏上的弹幕，不看播放状态，暂停、缓冲时由呈现端静止显示；其余时候
/// 播放中的相邻快照只投递两者之间首次出现的弹幕。同一落地代号内位置倒退是采样抖动，不投递、不清屏，
/// 上一位置也不倒退。打开弹幕时清屏重补，覆盖回看窗口的分段迟到时按 ID 去重追加。暂停和倍速直接
/// 使用 timeline 快照，不创建独立 wall-clock timer。
public struct DanmakuScheduler: Sendable {
    /// 弹幕分段的时长：B 站按每 6 分钟一段提供 protobuf 分段，分段号从 1 开始。
    public static let segmentDurationSeconds = 360.0
    /// 同时缓存的分段数，够放当前分段与前后各一段；超出时离当前位置最远的先淘汰，已投递 ID
    /// 也只保留当前及之前的这么多段。
    ///
    /// 调大占用更多内存，调小则来回拖动时更常重新请求分段。
    public static let maximumCachedSegments = 3

    /// 待处理的补位种类。
    private enum PendingCatchUp {
        case none
        /// 清屏后重新补回看窗口：落地、seek 开始与打开弹幕。
        case replacing
        /// 只追加迟到分段里窗口内的弹幕，按 ID 去重、不清屏：屏上已是同一落点的结果。
        case supplementing
    }

    private var identity: PlaybackItemIdentity?
    private var filter = DanmakuFilter()
    private var isEnabled = true
    /// 按分段号缓存、已按时间排序的事件。
    private var segments: [Int: [DanmakuEvent]] = [:]
    /// 每个分段下一条待投递事件的下标；落地、seek、暂停或开关弹幕时清空，下次按位置重新定位。
    private var nextEventIndexBySegment: [Int: Int] = [:]
    /// 已投递的事件 ID，按分段记录；补位与迟到分段据此去重。
    private var deliveredIDsBySegment: [Int: Set<String>] = [:]
    /// 上一个快照的位置；它与本次位置之间出现的事件是这次要投递的，分段缓存也按它裁剪。
    ///
    /// settled 时同一落地代号内只增不减；seeking 期间跟随每次跳变的位置。
    private var previousPositionSeconds: Double?
    /// 最近一次见到的落地代号；快照带来的值不同时清屏并补位。
    private var landingGeneration: UInt64?
    /// 上一个快照是否处于 seeking；由 settled 进入 seeking 时清屏一次。
    private var isSeeking = false
    /// 补位回看的时长，由呈现端按画面宽度与弹幕速度给出；为 0 时不补位。
    ///
    /// nil 表示呈现端暂时没有可用的画面尺寸：这时不补位，也不清除 `pendingCatchUp`，等窗口可用后再补。
    private var catchUpWindowSeconds: Double? = 0
    /// 下一次处理快照时要做的补位。
    ///
    /// 落地、进入 seeking 与打开弹幕置为 `.replacing`；覆盖回看窗口的分段迟到时，若没有待处理的重新
    /// 补位，置为 `.supplementing`。弹幕打开、窗口可用且不在 seeking 时处理任一快照（不论播放状态）
    /// 后清除，否则保留。
    private var pendingCatchUp = PendingCatchUp.none

    public init() {}

    public mutating func begin(for identity: PlaybackItemIdentity) {
        self.identity = identity
        resetTimelineState()
    }

    public mutating func reset() {
        identity = nil
        resetTimelineState()
    }

    /// 打开时置位重新补位；调用方在暂停时应主动再处理一次最近的快照，补位才不必等到继续播放。
    public mutating func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        nextEventIndexBySegment.removeAll(keepingCapacity: true)
        deliveredIDsBySegment.removeAll(keepingCapacity: true)
        previousPositionSeconds = nil
        pendingCatchUp = enabled ? .replacing : .none
    }

    /// nil 表示呈现端暂时没有可用的画面尺寸，待补的补位保留到窗口可用。
    public mutating func setCatchUpWindow(_ seconds: Double?) {
        catchUpWindowSeconds = seconds.map { $0.isFinite ? max($0, 0) : 0 }
    }

    public mutating func setFilter(_ filter: DanmakuFilter) {
        self.filter = filter
    }

    public func containsSegment(index: Int) -> Bool {
        segments[index] != nil
    }

    /// 缓存一个分段；返回这次之后是否有可以立即处理的补位（窗口不可用、弹幕关闭或 seeking 时为
    /// false，之后再补）。
    ///
    /// 返回 true 时调用方若不会很快收到下一个快照（暂停、缓冲），应主动再处理一次最近的快照。
    @discardableResult
    public mutating func store(
        _ segment: DanmakuSegment,
        for identity: PlaybackItemIdentity
    ) -> Bool {
        guard self.identity == identity, segment.index > 0 else { return false }
        let events = segment.events.sorted(by: Self.eventOrder)
        segments[segment.index] = events
        nextEventIndexBySegment[segment.index] = Self.firstEventIndex(
            after: previousPositionSeconds ?? -.infinity,
            in: events
        )
        // 迟到的分段若覆盖回看窗口，补上其中本应仍在屏上的弹幕；已投递的按 ID 去重。还有待处理的
        // 重新补位时并入它。
        if let previousPositionSeconds,
            catchUpWindowOverlaps(segmentIndex: segment.index, endingAt: previousPositionSeconds),
            pendingCatchUp == .none
        {
            pendingCatchUp = .supplementing
        }
        trimCache()
        return hasCatchUpReadyToProcess
    }

    public func desiredSegmentIndices(
        for snapshot: PlaybackTimelineSnapshot
    ) -> [Int] {
        guard snapshot.identity == identity else { return [] }
        let current = Self.segmentIndex(at: snapshot.positionSeconds)
        var indices = [current]
        // 回看窗口跨进上一分段时一并请求（排在当前分段之后），补位才不会在分段边界缺一截。
        let previous = current - 1
        if previous >= 1,
            catchUpWindowOverlaps(segmentIndex: previous, endingAt: snapshot.positionSeconds)
        {
            indices.append(previous)
        }
        let next = current + 1
        if next <= DanmakuSegmentUseCase.maximumSegmentIndex,
            snapshot.durationSeconds.map({
                Double(current) * Self.segmentDurationSeconds < $0
            }) ?? true
        {
            indices.append(next)
        }
        return indices
    }

    /// 消费一个时间线快照，给出这次要呈现的 batch。
    public mutating func consume(
        _ snapshot: PlaybackTimelineSnapshot
    ) -> DanmakuBatch? {
        guard let identity, snapshot.identity == identity else { return nil }

        var clearsExisting = false
        if landingGeneration != snapshot.landingGeneration {
            landingGeneration = snapshot.landingGeneration
            restartDelivery(at: snapshot.positionSeconds)
            clearsExisting = true
        }

        guard snapshot.seekPhase == .settled else {
            // seek 期间空屏：进入时清屏一次，之后不投递，等落地再补位。
            if !isSeeking {
                isSeeking = true
                restartDelivery(at: snapshot.positionSeconds)
                clearsExisting = true
            }
            // 拖动中位置随每次跳变更新；分段缓存按它裁剪，否则 seeking 期间到达的落点分段会因离
            // 进入 seek 时的位置太远被立刻淘汰。seeking 期间它不参与投递与去重，落地时被重新设定。
            previousPositionSeconds = snapshot.positionSeconds
            return clearsExisting ? batch(identity, snapshot, clearsExisting: true) : nil
        }
        isSeeking = false

        // 同一落地代号内位置倒退是采样抖动：按上一位置处理，不投递、不清屏。
        let position =
            previousPositionSeconds.map { max($0, snapshot.positionSeconds) }
            ?? snapshot.positionSeconds
        let isAdvancing = isEnabled && snapshot.state == .playing && snapshot.rate > 0

        var pending = PendingCatchUp.none
        if hasCatchUpReadyToProcess {
            pending = pendingCatchUp
            pendingCatchUp = .none
        }
        let catchesUp = pending != .none && (catchUpWindowSeconds ?? 0) > 0
        if catchesUp, pending == .replacing {
            // 重新补位一律清屏：窗口内的都要重新给出，去重记录作废。
            clearsExisting = true
            nextEventIndexBySegment.removeAll(keepingCapacity: true)
            deliveredIDsBySegment.removeAll(keepingCapacity: true)
        }
        let lowerBound: Double
        if catchesUp {
            // 补位从回看窗口起点收集；播放中还要接上相邻快照之间的区间，已投递的按 ID 去重。
            lowerBound = min(
                catchUpWindowStart(endingAt: position),
                previousPositionSeconds ?? position
            )
        } else if isAdvancing, let previousPositionSeconds {
            lowerBound = previousPositionSeconds
        } else {
            previousPositionSeconds = position
            nextEventIndexBySegment.removeAll(keepingCapacity: true)
            return clearsExisting ? batch(identity, snapshot, clearsExisting: true) : nil
        }

        let emitted = collectEvents(after: lowerBound, through: position, catchesUp: catchesUp)
        previousPositionSeconds = position
        guard !emitted.isEmpty || clearsExisting else { return nil }
        return batch(
            identity,
            snapshot,
            events: emitted,
            clearsExisting: clearsExisting,
            catchesUp: catchesUp && !emitted.isEmpty
        )
    }

    /// 弹幕打开、窗口可用、不在 seeking 且有待处理的补位。
    private var hasCatchUpReadyToProcess: Bool {
        isEnabled && pendingCatchUp != .none && catchUpWindowSeconds != nil && !isSeeking
    }

    private mutating func resetTimelineState() {
        segments.removeAll(keepingCapacity: false)
        nextEventIndexBySegment.removeAll(keepingCapacity: false)
        deliveredIDsBySegment.removeAll(keepingCapacity: false)
        previousPositionSeconds = nil
        landingGeneration = nil
        isSeeking = false
        pendingCatchUp = .none
    }

    /// 时间不再连续：作废投递游标与去重记录，从 `position` 重新开始，之后清屏重新补位。
    private mutating func restartDelivery(at position: Double) {
        previousPositionSeconds = position
        nextEventIndexBySegment.removeAll(keepingCapacity: true)
        deliveredIDsBySegment.removeAll(keepingCapacity: true)
        pendingCatchUp = .replacing
    }

    /// 收集 (`lowerBound`, `position`] 内通过筛选、尚未投递的事件，按时间排序，并推进各分段游标。
    ///
    /// 非补位时游标从上一个快照的位置接着走；补位时从 `lowerBound` 重新定位。
    private mutating func collectEvents(
        after lowerBound: Double,
        through position: Double,
        catchesUp: Bool
    ) -> [DanmakuEvent] {
        let lowerIndex = Self.segmentIndex(at: lowerBound)
        let upperIndex = Self.segmentIndex(at: position)
        trimDeliveredIDs(through: upperIndex)
        var emitted: [DanmakuEvent] = []
        if lowerIndex <= upperIndex {
            for index in lowerIndex...upperIndex {
                guard let events = segments[index] else { continue }
                var nextEventIndex =
                    catchesUp
                    ? Self.firstEventIndex(after: lowerBound, in: events)
                    : nextEventIndexBySegment[index]
                        ?? Self.firstEventIndex(after: lowerBound, in: events)
                if !catchesUp,
                    nextEventIndex < events.count,
                    events[nextEventIndex].timeSeconds <= lowerBound
                {
                    nextEventIndex = Self.firstEventIndex(after: lowerBound, in: events)
                }
                while nextEventIndex < events.count {
                    let event = events[nextEventIndex]
                    guard event.timeSeconds <= position else { break }
                    nextEventIndex += 1
                    guard filter.allows(event) else { continue }

                    let wasDelivered = hasDelivered(event.id)
                    deliveredIDsBySegment[index, default: []].insert(event.id)
                    guard !wasDelivered else { continue }

                    emitted.append(event)
                }
                nextEventIndexBySegment[index] = nextEventIndex
            }
        }
        trimDeliveredIDs(through: upperIndex)
        emitted.sort(by: Self.eventOrder)
        return emitted
    }

    private func batch(
        _ identity: PlaybackItemIdentity,
        _ snapshot: PlaybackTimelineSnapshot,
        events: [DanmakuEvent] = [],
        clearsExisting: Bool,
        catchesUp: Bool = false
    ) -> DanmakuBatch {
        DanmakuBatch(
            identity: identity,
            landingGeneration: snapshot.landingGeneration,
            events: events,
            clearsExisting: clearsExisting,
            catchesUp: catchesUp
        )
    }

    /// 截至 `position` 的回看窗口起点；窗口为 0 或不可用时等于 `position`。
    private func catchUpWindowStart(endingAt position: Double) -> Double {
        max(max(position, 0) - (catchUpWindowSeconds ?? 0), 0)
    }

    /// 回看窗口 [起点, `position`) 是否落进该分段；窗口为 0 或不可用时为空，不触发补位或额外请求。
    private func catchUpWindowOverlaps(segmentIndex: Int, endingAt position: Double) -> Bool {
        let window = catchUpWindowStart(endingAt: position)..<max(position, 0)
        let start = Double(segmentIndex - 1) * Self.segmentDurationSeconds
        return (start..<(start + Self.segmentDurationSeconds)).overlaps(window)
    }

    private mutating func trimCache() {
        guard segments.count > Self.maximumCachedSegments else { return }
        let current = Self.segmentIndex(at: previousPositionSeconds ?? 0)
        let ordered = segments.keys.sorted {
            let leftDistance = abs($0 - current)
            let rightDistance = abs($1 - current)
            return leftDistance == rightDistance
                ? $0 < $1
                : leftDistance < rightDistance
        }
        let keep = Set(ordered.prefix(Self.maximumCachedSegments))
        segments = segments.filter { keep.contains($0.key) }
        nextEventIndexBySegment = nextEventIndexBySegment.filter {
            keep.contains($0.key)
        }
    }

    private func hasDelivered(_ id: String) -> Bool {
        deliveredIDsBySegment.values.contains { $0.contains(id) }
    }

    private mutating func trimDeliveredIDs(through segmentIndex: Int) {
        let firstRetainedIndex = max(
            segmentIndex - Self.maximumCachedSegments + 1,
            1
        )
        deliveredIDsBySegment = deliveredIDsBySegment.filter {
            (firstRetainedIndex...segmentIndex).contains($0.key)
        }
    }

    private static func segmentIndex(at positionSeconds: Double) -> Int {
        let normalized =
            positionSeconds.isFinite
            ? max(positionSeconds, 0)
            : 0
        return Int(normalized / segmentDurationSeconds) + 1
    }

    private static func firstEventIndex(
        after positionSeconds: Double,
        in events: [DanmakuEvent]
    ) -> Int {
        var lowerBound = 0
        var upperBound = events.count
        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            if events[candidate].timeSeconds <= positionSeconds {
                lowerBound = candidate + 1
            } else {
                upperBound = candidate
            }
        }
        return lowerBound
    }

    private static func eventOrder(
        _ left: DanmakuEvent,
        _ right: DanmakuEvent
    ) -> Bool {
        left.timeSeconds == right.timeSeconds
            ? left.id < right.id
            : left.timeSeconds < right.timeSeconds
    }
}
