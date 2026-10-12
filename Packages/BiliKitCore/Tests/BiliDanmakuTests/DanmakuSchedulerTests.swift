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
            discontinuityGeneration: 1
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
        #expect(scheduler.retainedDeliveredIDCount == 1)

        let forwardSeekValue = scheduler.consume(
            snapshot(position: 100, rate: 1, generation: 2)
        )
        let forwardSeek = try #require(forwardSeekValue)
        #expect(forwardSeek.clearsExisting)
        #expect(forwardSeek.events.isEmpty)
        #expect(scheduler.retainedDeliveredIDCount == 0)

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
        #expect(scheduler.retainedDeliveredIDCount == 1)
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
        #expect(scheduler.retainedDeliveredIDCount == 0)
        let disabled = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 1)
        )
        #expect(disabled == nil)
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

        #expect(scheduler.cachedSegmentCount == DanmakuScheduler.maximumCachedSegments)
        let oldIdentity = scheduler.consume(
            PlaybackTimelineSnapshot(
                identity: other,
                positionSeconds: 2,
                durationSeconds: nil,
                rate: 1,
                state: .playing,
                discontinuityGeneration: 1
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
    func forwardPlaybackBoundsDeliveredIDsAndDeduplicatesAdjacentSegments() throws {
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
            #expect(
                scheduler.retainedDeliveredSegmentCount
                    <= DanmakuScheduler.maximumCachedSegments
            )
            #expect(
                scheduler.retainedDeliveredIDCount
                    <= DanmakuScheduler.maximumCachedSegments * 4
            )
        }

        #expect(
            scheduler.retainedDeliveredSegmentCount
                == DanmakuScheduler.maximumCachedSegments
        )
        #expect(
            scheduler.retainedDeliveredIDCount
                == DanmakuScheduler.maximumCachedSegments * 4
        )
        scheduler.reset()
        #expect(scheduler.retainedDeliveredSegmentCount == 0)
        #expect(scheduler.retainedDeliveredIDCount == 0)
    }

    /// seek 后第一个播放中的快照补发回看窗口内本应仍在屏上的弹幕；窗口外的不补，之后恢复增量投递。
    @Test
    func seekCatchesUpOnlyTheWindowBeforeThePlayhead() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setCatchUpWindow(10)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "too-old", time: 85),
                    event(id: "in-window", time: 95),
                    event(id: "at-seek", time: 100),
                    event(id: "after", time: 100.5)
                ]
            ),
            for: identity
        )

        let clearValue = scheduler.consume(snapshot(position: 100, rate: 1, generation: 2))

        let clear = try #require(clearValue)
        let catchUpValue = scheduler.consume(snapshot(position: 100.2, rate: 1, generation: 2))
        let catchUp = try #require(catchUpValue)
        let nextValue = scheduler.consume(snapshot(position: 100.6, rate: 1, generation: 2))
        let next = try #require(nextValue)

        #expect(clear.clearsExisting)
        #expect(!clear.catchesUp)
        #expect(catchUp.catchesUp)
        #expect(catchUp.events.map(\.id) == ["in-window", "at-seek"])
        #expect(!next.catchesUp)
        #expect(next.events.map(\.id) == ["after"])
    }

    /// 暂停时 seek 不补位；继续播放后的第一个快照才补。
    @Test
    func pausedSeekCatchesUpWhenPlaybackResumes() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setCatchUpWindow(10)
        scheduler.store(
            DanmakuSegment(index: 1, events: [event(id: "visible", time: 95)]),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 100, rate: 0, state: .paused, generation: 2))
        let paused = scheduler.consume(
            snapshot(position: 100, rate: 0, state: .paused, generation: 2)
        )
        let resumedValue = scheduler.consume(snapshot(position: 100.1, rate: 1, generation: 2))
        let resumed = try #require(resumedValue)

        #expect(paused == nil)
        #expect(resumed.catchesUp)
        #expect(resumed.events.map(\.id) == ["visible"])
    }

    /// 播放中打开弹幕时补上当前应在屏上的弹幕。
    @Test
    func enablingDanmakuCatchesUp() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setCatchUpWindow(10)
        scheduler.store(
            DanmakuSegment(index: 1, events: [event(id: "visible", time: 45)]),
            for: identity
        )
        _ = scheduler.consume(snapshot(position: 40, rate: 1, generation: 1))
        scheduler.setEnabled(false)
        _ = scheduler.consume(snapshot(position: 50, rate: 1, generation: 1))

        scheduler.setEnabled(true)
        let first = scheduler.consume(snapshot(position: 50.1, rate: 1, generation: 1))
        let catchUpValue = scheduler.consume(snapshot(position: 50.2, rate: 1, generation: 1))
        let catchUp = try #require(catchUpValue)

        #expect(first == nil)
        #expect(catchUp.catchesUp)
        #expect(catchUp.events.map(\.id) == ["visible"])
    }

    /// 补位所需的分段晚到时再补一次，已经补过的按 ID 去重。
    @Test
    func lateSegmentInTheWindowCatchesUpWithoutDuplicates() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setCatchUpWindow(10)
        scheduler.store(
            DanmakuSegment(index: 2, events: [event(id: "current", time: 362)]),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 365, rate: 1, generation: 2))
        let firstValue = scheduler.consume(snapshot(position: 365.1, rate: 1, generation: 2))
        let first = try #require(firstValue)
        scheduler.store(
            DanmakuSegment(index: 1, events: [event(id: "previous", time: 358)]),
            for: identity
        )
        let lateValue = scheduler.consume(snapshot(position: 365.2, rate: 1, generation: 2))
        let late = try #require(lateValue)

        #expect(first.events.map(\.id) == ["current"])
        #expect(late.catchesUp)
        #expect(late.events.map(\.id) == ["previous"])
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
            discontinuityGeneration: generation
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
