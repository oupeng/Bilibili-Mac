import BiliApplication
import BiliModels
import Foundation

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

    /// 负权重的弹幕不显示，与删除可配置 `minimumWeight`（默认 0）之前的行为一致。
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

/// 某一播放 identity/generation 的增量呈现指令；`clearsExisting` 表示时间不再连续。
///
/// `catchesUp` 表示这批弹幕是补位：每条都按自己的时间点进场，呈现时从已经走过的位置开始，
/// 而不是从当前时刻重新进场。
public struct DanmakuBatch: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let discontinuityGeneration: UInt64
    public let events: [DanmakuEvent]
    public let clearsExisting: Bool
    public let catchesUp: Bool

    public init(
        identity: PlaybackItemIdentity,
        discontinuityGeneration: UInt64,
        events: [DanmakuEvent],
        clearsExisting: Bool,
        catchesUp: Bool
    ) {
        self.identity = identity
        self.discontinuityGeneration = discontinuityGeneration
        self.events = events
        self.clearsExisting = clearsExisting
        self.catchesUp = catchesUp
    }
}

/// 以统一媒体时间线调度弹幕，并维护有界分段缓存与去重游标。
///
/// identity、discontinuity 或时间回跳会清除投递记录并先发清屏 batch；之后第一个播放中的快照
/// 补发回看窗口（`setCatchUpWindow`）内本应仍在屏上的弹幕，打开弹幕或覆盖窗口的分段迟到时同样
/// 补位。暂停和倍速直接使用 timeline 快照，不创建独立 wall-clock timer。
public struct DanmakuScheduler: Sendable {
    public static let segmentDurationSeconds = 360.0
    public static let maximumCachedSegments = 3

    private var identity: PlaybackItemIdentity?
    private var filter = DanmakuFilter()
    private var isEnabled = true
    private var segments: [Int: [DanmakuEvent]] = [:]
    private var nextEventIndexBySegment: [Int: Int] = [:]
    private var deliveredIDsBySegment: [Int: Set<String>] = [:]
    private var previousPositionSeconds: Double?
    private var discontinuityGeneration: UInt64?
    /// 补位回看的时长，由呈现端按画面宽度与弹幕速度给出；为 0 时不补位。
    private var catchUpWindowSeconds = 0.0
    private var needsCatchUp = false

    public init() {}

    public mutating func begin(for identity: PlaybackItemIdentity) {
        self.identity = identity
        segments.removeAll(keepingCapacity: false)
        nextEventIndexBySegment.removeAll(keepingCapacity: false)
        deliveredIDsBySegment.removeAll(keepingCapacity: false)
        previousPositionSeconds = nil
        discontinuityGeneration = nil
        needsCatchUp = false
    }

    public mutating func reset() {
        identity = nil
        segments.removeAll(keepingCapacity: false)
        nextEventIndexBySegment.removeAll(keepingCapacity: false)
        deliveredIDsBySegment.removeAll(keepingCapacity: false)
        previousPositionSeconds = nil
        discontinuityGeneration = nil
        needsCatchUp = false
    }

    public mutating func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        nextEventIndexBySegment.removeAll(keepingCapacity: true)
        deliveredIDsBySegment.removeAll(keepingCapacity: true)
        previousPositionSeconds = nil
        needsCatchUp = enabled
    }

    public mutating func setCatchUpWindow(_ seconds: Double) {
        catchUpWindowSeconds = seconds.isFinite ? max(seconds, 0) : 0
    }

    public mutating func setFilter(_ filter: DanmakuFilter) {
        self.filter = filter
    }

    public func containsSegment(index: Int) -> Bool {
        segments[index] != nil
    }

    public mutating func store(
        _ segment: DanmakuSegment,
        for identity: PlaybackItemIdentity
    ) {
        guard self.identity == identity, segment.index > 0 else { return }
        let events = segment.events.sorted(by: Self.eventOrder)
        segments[segment.index] = events
        nextEventIndexBySegment[segment.index] = Self.firstEventIndex(
            after: previousPositionSeconds ?? -.infinity,
            in: events
        )
        // 迟到的分段若覆盖回看窗口，补上其中本应仍在屏上的弹幕；已投递的按 ID 去重。
        if let previousPositionSeconds,
            catchUpWindowOverlaps(segmentIndex: segment.index, endingAt: previousPositionSeconds)
        {
            needsCatchUp = true
        }
        trimCache()
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

    /// 消费相邻快照之间首次出现的事件；不连续时先返回清屏指令，之后只补回看窗口内的弹幕，不补喷跨越区间。
    public mutating func consume(
        _ snapshot: PlaybackTimelineSnapshot
    ) -> DanmakuBatch? {
        guard let identity, snapshot.identity == identity else { return nil }

        if discontinuityGeneration != snapshot.discontinuityGeneration {
            discontinuityGeneration = snapshot.discontinuityGeneration
            previousPositionSeconds = snapshot.positionSeconds
            nextEventIndexBySegment.removeAll(keepingCapacity: true)
            deliveredIDsBySegment.removeAll(keepingCapacity: true)
            needsCatchUp = true
            return DanmakuBatch(
                identity: identity,
                discontinuityGeneration: snapshot.discontinuityGeneration,
                events: [],
                clearsExisting: true,
                catchesUp: false
            )
        }

        guard isEnabled,
            snapshot.state == .playing,
            snapshot.rate > 0
        else {
            previousPositionSeconds = snapshot.positionSeconds
            nextEventIndexBySegment.removeAll(keepingCapacity: true)
            return nil
        }
        guard let previousPositionSeconds else {
            self.previousPositionSeconds = snapshot.positionSeconds
            return nil
        }
        guard snapshot.positionSeconds >= previousPositionSeconds else {
            self.previousPositionSeconds = snapshot.positionSeconds
            nextEventIndexBySegment.removeAll(keepingCapacity: true)
            deliveredIDsBySegment.removeAll(keepingCapacity: true)
            needsCatchUp = true
            return DanmakuBatch(
                identity: identity,
                discontinuityGeneration: snapshot.discontinuityGeneration,
                events: [],
                clearsExisting: true,
                catchesUp: false
            )
        }

        // 补位时从回看窗口起点开始收集，已投递的按 ID 去重；否则只收集相邻快照之间新出现的。
        let catchesUp = needsCatchUp && catchUpWindowSeconds > 0
        needsCatchUp = false
        let lowerBound =
            catchesUp
            ? min(
                catchUpWindowStart(endingAt: snapshot.positionSeconds),
                previousPositionSeconds
            )
            : previousPositionSeconds
        let lowerIndex = Self.segmentIndex(at: lowerBound)
        let upperIndex = Self.segmentIndex(at: snapshot.positionSeconds)
        trimDeliveredIDs(through: upperIndex)
        var emitted: [DanmakuEvent] = []
        if lowerIndex <= upperIndex {
            for index in lowerIndex...upperIndex {
                guard let events = segments[index] else { continue }
                var nextEventIndex =
                    catchesUp
                    ? Self.firstEventIndex(after: lowerBound, in: events)
                    : nextEventIndexBySegment[index]
                        ?? Self.firstEventIndex(
                            after: previousPositionSeconds,
                            in: events
                        )
                if !catchesUp,
                    nextEventIndex < events.count,
                    events[nextEventIndex].timeSeconds <= previousPositionSeconds
                {
                    nextEventIndex = Self.firstEventIndex(
                        after: previousPositionSeconds,
                        in: events
                    )
                }
                while nextEventIndex < events.count {
                    let event = events[nextEventIndex]
                    guard event.timeSeconds <= snapshot.positionSeconds else {
                        break
                    }
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
        self.previousPositionSeconds = snapshot.positionSeconds
        guard !emitted.isEmpty else { return nil }
        emitted.sort(by: Self.eventOrder)
        return DanmakuBatch(
            identity: identity,
            discontinuityGeneration: snapshot.discontinuityGeneration,
            events: emitted,
            clearsExisting: false,
            catchesUp: catchesUp
        )
    }

    /// 截至 `position` 的回看窗口起点；窗口为 0 时等于 `position`。
    private func catchUpWindowStart(endingAt position: Double) -> Double {
        max(max(position, 0) - catchUpWindowSeconds, 0)
    }

    /// 回看窗口 [起点, `position`) 是否落进该分段；窗口为 0 时为空，不触发补位或额外请求。
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
