import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@Suite
struct DanmakuSchedulerTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1DanmakuFixture",
        cid: 700_001
    )

    @Test
    func virtualTimelineHandlesPauseRateAndSegmentBoundary() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "a", time: 1.0),
                    event(id: "during-pause", time: 1.3),
                    event(id: "b", time: 2.0),
                    event(id: "boundary", time: 360.1)
                ]
            ),
            for: identity
        )
        scheduler.store(
            DanmakuSegment(
                index: 2,
                events: [event(id: "boundary", time: 360.1)]
            ),
            for: identity
        )

        let initialValue = scheduler.consume(
            snapshot(position: 0, rate: 1, generation: 1)
        )
        let initial = try #require(initialValue)
        #expect(initial.clearsExisting)

        let firstValue = scheduler.consume(
            snapshot(position: 1.1, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["a"])

        let paused = scheduler.consume(
            snapshot(position: 1.5, rate: 0, state: .paused, generation: 1)
        )
        #expect(paused == nil)
        let doubledValue = scheduler.consume(
            snapshot(position: 2.1, rate: 2, generation: 1)
        )
        let doubled = try #require(doubledValue)
        #expect(doubled.events.map(\.id) == ["b"])

        let boundaryValue = scheduler.consume(
            snapshot(position: 360.2, rate: 2, generation: 1)
        )
        let boundary = try #require(boundaryValue)
        #expect(boundary.events.map(\.id) == ["boundary"])
        #expect(
            scheduler.desiredSegmentIndices(
                for: snapshot(position: 360.2, rate: 2, generation: 1)
            ) == [2, 3]
        )
    }

    @Test
    func finalSegmentDoesNotPrefetchBeyondKnownDuration() {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 2_200,
            durationSeconds: 2_327,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 1,
            landingGeneration: 1
        )

        #expect(scheduler.desiredSegmentIndices(for: snapshot) == [7])
    }

    @Test
    func discontinuityClearsWithoutBackfillAndBackwardSeekCanReemit() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [event(id: "repeat", time: 5)]
            ),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let firstValue = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["repeat"])

        let forwardSeekValue = scheduler.consume(
            snapshot(position: 100, rate: 1, generation: 2)
        )
        let forwardSeek = try #require(forwardSeekValue)
        #expect(forwardSeek.clearsExisting)
        #expect(forwardSeek.events.isEmpty)

        let backwardSeekValue = scheduler.consume(
            snapshot(position: 0, rate: 1, generation: 3)
        )
        let backwardSeek = try #require(backwardSeekValue)
        #expect(backwardSeek.clearsExisting)
        let replayValue = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 3)
        )
        let replay = try #require(replayValue)
        #expect(replay.events.map(\.id) == ["repeat"])
    }

    @Test
    func filterAndDisabledStatePreventEmission() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setFilter(
            DanmakuFilter(
                showsScrolling: true,
                showsTop: false,
                showsBottom: true
            )
        )
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "top", time: 2, mode: .top),
                    event(id: "negative-weight", time: 3, weight: -1),
                    event(id: "allowed", time: 4),
                    event(id: "zero-weight", time: 4.5, weight: 0)
                ]
            ),
            for: identity
        )
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let batchValue = scheduler.consume(
            snapshot(position: 5, rate: 1, generation: 1)
        )
        let batch = try #require(batchValue)
        #expect(batch.events.map(\.id) == ["allowed", "zero-weight"])

        scheduler.setEnabled(false)
        let disabled = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 1)
        )
        #expect(disabled == nil)

        // 关闭时屏幕已清空，投递记录随之作废：重新打开后的第一个快照就补位，再次给出仍在窗口内的弹幕。
        scheduler.setCatchUpWindow(10)
        scheduler.setEnabled(true)
        let reenabledValue = scheduler.consume(
            snapshot(position: 6.1, rate: 1, generation: 1)
        )
        let reenabled = try #require(reenabledValue)
        #expect(reenabled.catchesUp)
        #expect(reenabled.events.map(\.id) == ["allowed", "zero-weight"])
    }

    @Test
    func oldIdentityAndCacheGrowthStayBounded() {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        let other = PlaybackItemIdentity(bvid: "BV1OtherFixture", cid: 8)
        scheduler.store(
            DanmakuSegment(index: 1, events: [event(id: "old", time: 1)]),
            for: other
        )
        for index in 1...8 {
            scheduler.store(
                DanmakuSegment(index: index, events: []),
                for: identity
            )
        }

        // 只保留离当前位置（尚无快照时为第 1 段）最近的 `maximumCachedSegments` 段。
        let cached = (1...8).filter { scheduler.containsSegment(index: $0) }
        #expect(cached == Array(1...DanmakuScheduler.maximumCachedSegments))
        let oldIdentity = scheduler.consume(
            PlaybackTimelineSnapshot(
                identity: other,
                positionSeconds: 2,
                durationSeconds: nil,
                rate: 1,
                state: .playing,
                discontinuityGeneration: 1,
                landingGeneration: 1
            )
        )
        #expect(oldIdentity == nil)
    }

    @Test
    func identityReplacementReemitsSameIDAndReenableDoesNotBackfill() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [event(id: "same-id", time: 1)]
            ),
            for: identity
        )
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let firstValue = scheduler.consume(
            snapshot(position: 2, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["same-id"])

        let other = PlaybackItemIdentity(bvid: "BV1OtherFixture", cid: 8)
        scheduler.begin(for: other)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "same-id", time: 1),
                    event(id: "while-disabled", time: 3),
                    event(id: "after-enabled", time: 5)
                ]
            ),
            for: other
        )
        _ = scheduler.consume(
            snapshot(
                position: 0,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let replacementValue = scheduler.consume(
            snapshot(
                position: 2,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let replacement = try #require(replacementValue)
        #expect(replacement.events.map(\.id) == ["same-id"])

        scheduler.setEnabled(false)
        let disabled = scheduler.consume(
            snapshot(
                position: 4,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        #expect(disabled == nil)
        scheduler.setEnabled(true)
        let resumedAnchor = scheduler.consume(
            snapshot(
                position: 4.5,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        #expect(resumedAnchor == nil)
        let resumedValue = scheduler.consume(
            snapshot(
                position: 6,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let resumed = try #require(resumedValue)
        #expect(resumed.events.map(\.id) == ["after-enabled"])
    }

    @Test
    func replacingCurrentSegmentReanchorsCursorWithoutBackfill() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "initial", time: 1),
                    event(id: "old-future", time: 4)
                ]
            ),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let initialValue = scheduler.consume(
            snapshot(position: 2, rate: 1, generation: 1)
        )
        let initial = try #require(initialValue)
        #expect(initial.events.map(\.id) == ["initial"])

        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "late-past", time: 1.5),
                    event(id: "new-window", time: 2.5),
                    event(id: "old-future", time: 4)
                ]
            ),
            for: identity
        )

        let replacementValue = scheduler.consume(
            snapshot(position: 3, rate: 1, generation: 1)
        )
        let replacement = try #require(replacementValue)
        #expect(replacement.events.map(\.id) == ["new-window"])

        let futureValue = scheduler.consume(
            snapshot(position: 5, rate: 1, generation: 1)
        )
        let future = try #require(futureValue)
        #expect(future.events.map(\.id) == ["old-future"])
    }

    @Test
    func prefetchedSegmentDoesNotBackfillEventsOlderThanPlaybackWindow() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        scheduler.store(
            DanmakuSegment(
                index: 2,
                events: [
                    event(id: "stale-prefetch", time: 2),
                    event(id: "current", time: 361)
                ]
            ),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 300, rate: 1, generation: 1))
        let crossingValue = scheduler.consume(
            snapshot(position: 362, rate: 1, generation: 1)
        )
        let crossing = try #require(crossingValue)
        #expect(crossing.events.map(\.id) == ["current"])
    }

    @Test
    func forwardPlaybackDeduplicatesAdjacentSegments() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))

        for index in 1...8 {
            let start =
                Double(index - 1)
                * DanmakuScheduler.segmentDurationSeconds
            var events = [
                event(id: "unique-\(index)", time: start + 1),
                event(id: "rolling-duplicate", time: start + 2),
                event(
                    id: "boundary-\(index)",
                    time: start
                        + DanmakuScheduler.segmentDurationSeconds
                        - 0.1
                )
            ]
            if index > 1 {
                events.append(
                    event(id: "boundary-\(index - 1)", time: start + 0.1)
                )
            }
            scheduler.store(
                DanmakuSegment(index: index, events: events),
                for: identity
            )

            let value = scheduler.consume(
                snapshot(
                    position: start
                        + DanmakuScheduler.segmentDurationSeconds
                        - 0.05,
                    rate: 1,
                    generation: 1
                )
            )
            let batch = try #require(value)
            #expect(
                batch.events.map(\.id)
                    == (index == 1
                        ? [
                            "unique-1",
                            "rolling-duplicate",
                            "boundary-1"
                        ]
                        : [
                            "unique-\(index)",
                            "boundary-\(index)"
                        ])
            )
        }
    }

    /// 去重记录只覆盖最近 `maximumCachedSegments` 段：更早分段投递过的 ID 已被遗忘，再次出现时
    /// 重新投递；窗口内分段投递过的 ID 仍去重。
    @Test
    func deliveredIDMemoryCoversOnlyTheCachedSegmentWindow() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let segmentCount = DanmakuScheduler.maximumCachedSegments + 1
        let duration = DanmakuScheduler.segmentDurationSeconds
        var emitted: [[String]] = []

        for index in 1...segmentCount {
            let start = Double(index - 1) * duration
            let events: [DanmakuEvent] =
                switch index {
                case 1: [event(id: "outside-window", time: start + 1)]
                case 2: [event(id: "inside-window", time: start + 1)]
                case segmentCount:
                    [
                        event(id: "outside-window", time: start + 1),
                        event(id: "inside-window", time: start + 2)
                    ]
                default: []
                }
            scheduler.store(DanmakuSegment(index: index, events: events), for: identity)
            let batch = scheduler.consume(
                snapshot(position: start + duration - 0.05, rate: 1, generation: 1)
            )
            emitted.append(batch?.events.map(\.id) ?? [])
        }

        #expect(
            emitted
                == [["outside-window"], ["inside-window"]]
                + Array(repeating: [], count: segmentCount - 3)
                + [["outside-window"]]
        )
    }

    /// 回看窗口跨进上一分段时一并请求上一分段；没有窗口时请求不变。
    @Test
    func catchUpWindowAcrossASegmentBoundaryRequestsThePreviousSegment() {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)

        #expect(
            scheduler.desiredSegmentIndices(for: snapshot(position: 365, rate: 1, generation: 1))
                == [2, 3]
        )
        scheduler.setCatchUpWindow(10)
        #expect(
            scheduler.desiredSegmentIndices(for: snapshot(position: 365, rate: 1, generation: 1))
                == [2, 1, 3]
        )
        #expect(
            scheduler.desiredSegmentIndices(for: snapshot(position: 380, rate: 1, generation: 1))
                == [2, 3]
        )
        #expect(
            scheduler.desiredSegmentIndices(for: snapshot(position: 5, rate: 1, generation: 1)) == [
                1, 2
            ]
        )
    }

    private func snapshot(
        position: Double,
        rate: Double,
        state: PlaybackTimelineState = .playing,
        generation: UInt64,
        identity: PlaybackItemIdentity? = nil
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity ?? self.identity,
            positionSeconds: position,
            durationSeconds: 900,
            rate: rate,
            state: state,
            discontinuityGeneration: generation,
            landingGeneration: generation
        )
    }

    private func event(
        id: String,
        time: Double,
        mode: DanmakuPresentationMode = .scrolling,
        weight: Int = 5
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "fixture",
            fontSize: 25,
            colorRGB: 0xFF_FF_FF,
            colorStyle: .solid,
            weight: weight
        )
    }
}
