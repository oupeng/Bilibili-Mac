import BiliApplication
import BiliModels
import Foundation

/// 一个播放 identity 的有界弹幕分段缓存，并决定此刻需要哪些分段。
///
/// 只按时间线快照的位置判断要哪些分段、淘汰哪些分段；不关心哪些弹幕在屏上（呈现端按媒体时间自己决定），
/// 所以没有投递游标、去重或补位。由 `DanmakuSession` 持有，换 identity 时清空。
struct DanmakuSegmentCache: Sendable {
    /// 弹幕分段的时长：B 站按每 6 分钟一段提供 protobuf 分段，分段号从 1 开始。
    static let segmentDurationSeconds = 360.0
    /// 同时缓存的分段数，够放当前分段与前后各一段；超出时离当前位置最远的先淘汰。
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
    /// 最近一个快照的位置，淘汰分段时以它为中心；拖动中随每一步更新。
    private var positionSeconds: Double?

    mutating func begin(for identity: PlaybackItemIdentity) {
        self.identity = identity
        segments.removeAll(keepingCapacity: false)
        positionSeconds = nil
    }

    mutating func reset() {
        identity = nil
        segments.removeAll(keepingCapacity: false)
        positionSeconds = nil
    }

    func contains(index: Int) -> Bool {
        segments[index] != nil
    }

    /// 记下当前 identity 的快照位置；拖动中也要更新，否则拖到远处时落点分段一到就被淘汰。
    mutating func observe(_ snapshot: PlaybackTimelineSnapshot) {
        guard snapshot.identity == identity else { return }
        positionSeconds = snapshot.positionSeconds
    }

    /// 缓存一个分段并淘汰离当前位置最远的；identity 不符或分段号无效时返回 false。
    @discardableResult
    mutating func store(
        _ segment: DanmakuSegment,
        for identity: PlaybackItemIdentity
    ) -> Bool {
        guard self.identity == identity, segment.index > 0 else { return false }
        segments[segment.index] = segment.events
        trim()
        return true
    }

    /// 此刻需要的分段：当前分段在前，开头 `previousSegmentLookbackSeconds` 之内加上一分段，未到结尾时
    /// 加下一分段。
    func desiredSegmentIndices(
        for snapshot: PlaybackTimelineSnapshot
    ) -> [Int] {
        guard snapshot.identity == identity else { return [] }
        let current = Self.segmentIndex(at: snapshot.positionSeconds)
        var indices = [current]
        let previous = current - 1
        let currentStart = Double(current - 1) * Self.segmentDurationSeconds
        if previous >= 1,
            snapshot.positionSeconds - currentStart < Self.previousSegmentLookbackSeconds
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

    private mutating func trim() {
        guard segments.count > Self.maximumCachedSegments else { return }
        let current = Self.segmentIndex(at: positionSeconds ?? 0)
        let ordered = segments.keys.sorted {
            let leftDistance = abs($0 - current)
            let rightDistance = abs($1 - current)
            return leftDistance == rightDistance
                ? $0 < $1
                : leftDistance < rightDistance
        }
        let keep = Set(ordered.prefix(Self.maximumCachedSegments))
        segments = segments.filter { keep.contains($0.key) }
    }

    static func segmentIndex(at positionSeconds: Double) -> Int {
        let normalized =
            positionSeconds.isFinite
            ? max(positionSeconds, 0)
            : 0
        return Int(normalized / segmentDurationSeconds) + 1
    }
}
