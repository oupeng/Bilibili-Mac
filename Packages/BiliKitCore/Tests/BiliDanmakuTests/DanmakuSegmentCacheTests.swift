import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定分段缓存的契约：当前分段先要，分段开头一并要上一段，未到结尾才要下一段；缓存最多三段，淘汰离
/// 最近观察到的位置（含拖动中的位置）最远的；其他 identity 的分段不进缓存。
@Suite
struct DanmakuSegmentCacheTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1SegmentCache", cid: 1)

    @Test(
        arguments: [
            (5.0, nil, [1, 2]),
            (365.0, nil, [2, 1, 3]),
            (450.0, nil, [2, 3]),
            (725.0, 800.0, [3, 2]),
            (500.0, 700.0, [2])
        ] as [(Double, Double?, [Int])]
    )
    func desiredSegmentsFollowThePosition(
        position: Double,
        duration: Double?,
        expected: [Int]
    ) {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)

        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: duration,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 1
        )
        #expect(cache.desiredSegmentIndices(for: snapshot) == expected)
    }

    @Test
    func cacheKeepsTheThreeSegmentsNearestTheObservedPosition() {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)
        for index in 1...3 {
            cache.store(DanmakuSegment(index: index, events: []), for: identity)
        }

        // 拖动到第 6 段附近：落点分段到达时不因离起拖位置远而被淘汰。
        cache.observe(
            snapshot(identity: identity, position: 1_900, generation: 1, seekPhase: .seeking)
        )
        cache.store(
            DanmakuSegment(index: 6, events: [timedEvent(id: "far", time: 1_900)]),
            for: identity
        )

        #expect(cache.contains(index: 6))
        #expect(cache.segments.keys.sorted() == [2, 3, 6])
        #expect(cache.segments[6]?.map(\.id) == ["far"])
    }

    @Test
    func otherIdentitiesAndInvalidIndicesAreNotCached() {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)

        let otherIdentity = PlaybackItemIdentity(bvid: "BV1Other", cid: 2)
        let storedOther = cache.store(DanmakuSegment(index: 1, events: []), for: otherIdentity)
        let storedInvalid = cache.store(DanmakuSegment(index: 0, events: []), for: identity)

        #expect(!storedOther)
        #expect(!storedInvalid)
        #expect(cache.segments.isEmpty)
    }
}
