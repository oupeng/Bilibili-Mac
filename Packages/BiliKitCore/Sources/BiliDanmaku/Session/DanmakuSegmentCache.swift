import BiliApplication
import BiliModels
import Foundation

/// 一个播放 identity 的有界弹幕分段缓存，并决定此刻需要哪些分段。
///
/// 请求按最近快照的位置 h 决定：快照代表意图，拖进未缓冲区时比画面早 0.2～4 秒到达落点。淘汰要同时照顾
/// 两边：屏上弹幕按呈现端的显示时间 D 运动，h 跳远而 D 还停在原处时，D 那边的分段仍在屏上。受保护的是
/// `desiredSegmentIndices(at: h) ∪ desiredSegmentIndices(at: D)`，用同一个函数算，所以刚按 h 请求到的分段
/// 不会一到就被淘汰（按 D 单独淘汰会形成「到达即淘汰、再按 h 请求」的循环）；h 移走之后，不再需要的分段
/// 也不会被再次请求。代价是上限变软：h 与 D 分开时最多 6 段。读不到 D 时只保护 h 那边，结果与只按快照淘汰
/// 相同。淘汰只在存入时发生。不关心哪些弹幕在屏上，所以没有投递游标、去重或补位。由 `DanmakuSession` 持有，
/// 换 identity 时清空。
struct DanmakuSegmentCache: Sendable {
    /// 弹幕分段的时长：B 站按每 6 分钟一段提供 protobuf 分段，分段号从 1 开始。
    static let segmentDurationSeconds = 360.0
    /// 同时缓存的分段数，够放当前分段与前后各一段；超出时离显示时间（读不到时为快照位置）最远、又不受保护的
    /// 先淘汰，受保护的分段多于它时暂时超出。
    ///
    /// 调大占用更多内存，调小则来回拖动时更常重新请求分段。
    static let maximumCachedSegments = 3
    /// 位置在分段开头这么久之内时一并请求上一分段。
    ///
    /// 车道布局接着上一段末尾的占用排；上一段最长的滚动弹幕在本段开头这么久之内还可能在屏上、影响本段
    /// 开头的车道，取运动时长的上限。调小会让 seek 到分段开头时更常缺上一段，开头的车道与连续播放不同。
    static let previousSegmentLookbackSeconds = DanmakuMotionPolicy.maximumScrollingSeconds

    private(set) var identity: PlaybackItemIdentity?
    /// 按分段号缓存的事件，保持分段里的原始顺序；排序由车道布局负责。
    private(set) var segments: [Int: [DanmakuEvent]] = [:]
    /// 最近一个快照的位置与时长，拖动中随每一步更新。
    ///
    /// 淘汰时保护这个位置需要的分段。
    private var positionSeconds: Double?
    private var durationSeconds: Double?

    mutating func begin(for identity: PlaybackItemIdentity) {
        self.identity = identity
        segments.removeAll(keepingCapacity: false)
        positionSeconds = nil
        durationSeconds = nil
    }

    mutating func reset() {
        identity = nil
        segments.removeAll(keepingCapacity: false)
        positionSeconds = nil
        durationSeconds = nil
    }

    func contains(index: Int) -> Bool {
        segments[index] != nil
    }

    /// 记下当前 identity 的快照位置；拖动中也要更新，否则拖到远处时落点分段一到就被淘汰。
    mutating func observe(_ snapshot: PlaybackTimelineSnapshot) {
        guard snapshot.identity == identity else { return }
        positionSeconds = snapshot.positionSeconds
        durationSeconds = snapshot.durationSeconds
    }

    /// 缓存一个分段，超出上限时按类型说明淘汰；identity 不符或分段号无效时返回 false。
    ///
    /// `displayTime` 是呈现端此刻的显示时间 D，读不到时为 nil。
    @discardableResult
    mutating func store(
        _ segment: DanmakuSegment,
        for identity: PlaybackItemIdentity,
        displayTime: Double?
    ) -> Bool {
        guard self.identity == identity, segment.index > 0 else { return false }
        segments[segment.index] = segment.events
        trim(displayTime: displayTime)
        return true
    }

    /// 快照时刻需要的分段；快照不属于当前 identity 时为空。
    func desiredSegmentIndices(
        for snapshot: PlaybackTimelineSnapshot
    ) -> [Int] {
        guard snapshot.identity == identity else { return [] }
        return Self.desiredSegmentIndices(
            at: snapshot.positionSeconds,
            duration: snapshot.durationSeconds
        )
    }

    /// 位置 `position` 需要的分段。
    ///
    /// 当前分段在前，开头 `previousSegmentLookbackSeconds` 之内加上一分段，未到结尾时加下一分段。请求（按
    /// 快照）与淘汰保护（快照与显示时间两边）共用这一个判断。
    static func desiredSegmentIndices(at position: Double, duration: Double?) -> [Int] {
        let current = segmentIndex(at: position)
        var indices = [current]
        let previous = current - 1
        let currentStart = Double(current - 1) * segmentDurationSeconds
        if previous >= 1, position - currentStart < previousSegmentLookbackSeconds {
            indices.append(previous)
        }
        let next = current + 1
        if next <= DanmakuSegmentUseCase.maximumSegmentIndex,
            duration.map({ Double(current) * segmentDurationSeconds < $0 }) ?? true
        {
            indices.append(next)
        }
        return indices
    }

    /// 超出上限时，从不受保护的分段里按离中心（D，读不到时为快照位置）由远到近淘汰，直到不超出上限或只剩
    /// 受保护的分段；距离相同时先淘汰分段号大的。
    private mutating func trim(displayTime: Double?) {
        guard segments.count > Self.maximumCachedSegments else { return }
        let observed = positionSeconds ?? 0
        var protected = Set(Self.desiredSegmentIndices(at: observed, duration: durationSeconds))
        if let displayTime {
            protected.formUnion(
                Self.desiredSegmentIndices(at: displayTime, duration: durationSeconds)
            )
        }
        let centre = Self.segmentIndex(at: displayTime ?? observed)
        let evictable = segments.keys
            .filter { !protected.contains($0) }
            .sorted {
                let leftDistance = abs($0 - centre)
                let rightDistance = abs($1 - centre)
                return leftDistance == rightDistance ? $0 > $1 : leftDistance > rightDistance
            }
        let excess = segments.count - Self.maximumCachedSegments
        for index in evictable.prefix(excess) {
            segments[index] = nil
        }
    }

    static func segmentIndex(at positionSeconds: Double) -> Int {
        let normalized =
            positionSeconds.isFinite
            ? max(positionSeconds, 0)
            : 0
        return Int(normalized / segmentDurationSeconds) + 1
    }
}
