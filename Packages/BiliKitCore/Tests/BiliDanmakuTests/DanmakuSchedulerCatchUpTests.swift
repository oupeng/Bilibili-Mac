import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定调度器只消费 seek 事实的补位契约：seeking 时清屏一次且不投递；落地代号变化时同一 batch 清屏并在
/// 落点补位，不看播放状态；同代位置倒退不清屏不投递；迟到分段在补位前并入、补位后去重追加；打开弹幕
/// 立即重补；画面不可用时补位留到可用。
struct DanmakuSchedulerCatchUpTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1CatchUpFixture", cid: 700_101)
    private let window = 10.0

    /// seeking：进入时清屏一次，之后位置怎么变都不投递，也不补位。
    @Test
    func seekingClearsOnceAndDeliversNothing() throws {
        var scheduler = makeScheduler(events: [
            timedEvent(id: "before", time: 20), timedEvent(id: "during", time: 31)
        ])
        _ = scheduler.consume(at: 21, generation: 1)

        let enteringValue = scheduler.consume(at: 30, generation: 1, seekPhase: .seeking)
        let entering = try #require(enteringValue)
        let during = scheduler.consume(at: 32, generation: 1, seekPhase: .seeking)

        #expect(entering.clearsExisting)
        #expect(entering.events.isEmpty)
        #expect(during == nil)
    }

    /// 落地：同一 batch 先清屏再按落点补回看窗口内的弹幕，播放、暂停与缓冲都一样；窗口外的不补。
    @Test(arguments: [PlaybackTimelineState.playing, .paused, .buffering])
    func landingClearsAndCatchesUpInOneBatch(state: PlaybackTimelineState) throws {
        var scheduler = makeScheduler(events: [
            timedEvent(id: "too-old", time: 85),
            timedEvent(id: "in-window", time: 95),
            timedEvent(id: "at-landing", time: 100),
            timedEvent(id: "after", time: 100.5)
        ])
        _ = scheduler.consume(at: 3, generation: 1)
        _ = scheduler.consume(at: 3, generation: 1, seekPhase: .seeking)

        let landedValue = scheduler.consume(at: 100, generation: 2, state: state)
        let landed = try #require(landedValue)

        #expect(landed.clearsExisting)
        #expect(landed.catchesUp)
        #expect(landed.events.map(\.id) == ["in-window", "at-landing"])
    }

    /// 暂停中落地补位后开播：同一位置不重补，之后只投递新出现的弹幕。
    @Test
    func playbackAfterAPausedLandingDoesNotCatchUpAgain() throws {
        var scheduler = makeScheduler(events: [
            timedEvent(id: "in-window", time: 95), timedEvent(id: "after", time: 100.5)
        ])
        _ = scheduler.consume(at: 100, generation: 2, state: .paused)

        let started = scheduler.consume(at: 100, generation: 2)
        let nextValue = scheduler.consume(at: 100.6, generation: 2)
        let next = try #require(nextValue)

        #expect(started == nil)
        #expect(!next.clearsExisting)
        #expect(!next.catchesUp)
        #expect(next.events.map(\.id) == ["after"])
    }

    /// 同代位置倒退是采样抖动：不清屏、不投递，上一位置不倒退，已投递的不会重来。
    @Test
    func sameGenerationBackwardStepIsJitter() throws {
        var scheduler = makeScheduler(events: [
            timedEvent(id: "a", time: 10.1), timedEvent(id: "b", time: 10.4)
        ])
        _ = scheduler.consume(at: 9, generation: 1)
        let firstValue = scheduler.consume(at: 10.2, generation: 1)
        let first = try #require(firstValue)

        let backward = scheduler.consume(at: 9.6, generation: 1)
        let forwardValue = scheduler.consume(at: 10.5, generation: 1)
        let forward = try #require(forwardValue)

        #expect(first.events.map(\.id) == ["a"])
        #expect(backward == nil)
        #expect(!forward.clearsExisting)
        #expect(forward.events.map(\.id) == ["b"])
    }

    /// seeking 期间到达的分段并入落地时的那一次补位，不会单独追加。
    @Test
    func segmentArrivingBeforeTheCatchUpIsMergedIntoIt() throws {
        var scheduler = makeScheduler(events: [])
        _ = scheduler.consume(at: 100, generation: 1, seekPhase: .seeking)

        let canCatchUpWhileSeeking = scheduler.store(
            DanmakuSegment(index: 1, events: [timedEvent(id: "late", time: 95)]),
            for: identity
        )
        let landedValue = scheduler.consume(at: 100, generation: 2, state: .paused)
        let landed = try #require(landedValue)

        #expect(!canCatchUpWhileSeeking)
        #expect(landed.clearsExisting)
        #expect(landed.events.map(\.id) == ["late"])
    }

    /// 补位之后才到的分段只追加窗口内的弹幕：不清屏，已补过的按 ID 去重；暂停与播放中相同。
    @Test(arguments: [PlaybackTimelineState.playing, .paused])
    func segmentArrivingAfterTheCatchUpIsAppended(state: PlaybackTimelineState) throws {
        var scheduler = makeScheduler(
            index: 2,
            events: [timedEvent(id: "current", time: 362)]
        )
        let landedValue = scheduler.consume(at: 365, generation: 2, state: state)
        let landed = try #require(landedValue)

        let canCatchUp = scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [timedEvent(id: "previous", time: 358), timedEvent(id: "old", time: 300)]
            ),
            for: identity
        )
        let appendedValue = scheduler.consume(at: 365, generation: 2, state: state)
        let appended = try #require(appendedValue)
        scheduler.store(
            DanmakuSegment(index: 2, events: [timedEvent(id: "current", time: 362)]),
            for: identity
        )
        let repeated = scheduler.consume(at: 365, generation: 2, state: .paused)

        #expect(landed.events.map(\.id) == ["current"])
        #expect(canCatchUp)
        #expect(!appended.clearsExisting)
        #expect(appended.catchesUp)
        #expect(appended.events.map(\.id) == ["previous"])
        #expect(repeated == nil)
    }

    /// 打开弹幕后的第一个快照就清屏补位，暂停时同样补。
    @Test(arguments: [PlaybackTimelineState.playing, .paused])
    func enablingDanmakuCatchesUpOnTheNextSnapshot(state: PlaybackTimelineState) throws {
        var scheduler = makeScheduler(events: [timedEvent(id: "visible", time: 45)])
        _ = scheduler.consume(at: 40, generation: 1)
        scheduler.setEnabled(false)
        _ = scheduler.consume(at: 50, generation: 1, state: state)

        scheduler.setEnabled(true)
        let enabledValue = scheduler.consume(at: 50, generation: 1, state: state)
        let enabled = try #require(enabledValue)

        #expect(enabled.clearsExisting)
        #expect(enabled.catchesUp)
        #expect(enabled.events.map(\.id) == ["visible"])
    }

    /// 弹幕关闭时落地只清屏、不补位；迟到的分段也不要求补位。
    @Test
    func disabledDanmakuLandingOnlyClears() throws {
        var scheduler = makeScheduler(events: [timedEvent(id: "visible", time: 95)])
        scheduler.setEnabled(false)

        let landedValue = scheduler.consume(at: 100, generation: 2, state: .paused)
        let landed = try #require(landedValue)
        let canCatchUp = scheduler.store(
            DanmakuSegment(index: 1, events: [timedEvent(id: "late", time: 96)]),
            for: identity
        )

        #expect(landed.clearsExisting)
        #expect(landed.events.isEmpty)
        #expect(!canCatchUp)
    }

    /// 呈现端没有可用的画面尺寸时落地只清屏，补位与窗口内弹幕的投递记录都留到窗口可用之后。
    @Test
    func unavailableCatchUpWindowKeepsTheCatchUpForLater() throws {
        var scheduler = makeScheduler(events: [timedEvent(id: "visible", time: 95)])
        scheduler.setCatchUpWindow(nil)

        let landedValue = scheduler.consume(at: 100, generation: 2, state: .paused)
        let landed = try #require(landedValue)
        let stillUnavailable = scheduler.consume(at: 100, generation: 2, state: .paused)
        scheduler.setCatchUpWindow(window)
        let availableValue = scheduler.consume(at: 100, generation: 2, state: .paused)
        let available = try #require(availableValue)

        #expect(landed.clearsExisting)
        #expect(landed.events.isEmpty)
        #expect(stillUnavailable == nil)
        #expect(available.catchesUp)
        #expect(available.events.map(\.id) == ["visible"])
    }

    private func makeScheduler(index: Int = 1, events: [DanmakuEvent]) -> DanmakuScheduler {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setCatchUpWindow(window)
        scheduler.store(DanmakuSegment(index: index, events: events), for: identity)
        return scheduler
    }
}

extension DanmakuScheduler {
    /// 以本文件 fixture 的 identity 消费一个快照；播放状态的速率为 1，其余为 0。
    fileprivate mutating func consume(
        at position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing,
        seekPhase: PlaybackSeekPhase = .settled
    ) -> DanmakuBatch? {
        consume(
            snapshot(
                identity: PlaybackItemIdentity(bvid: "BV1CatchUpFixture", cid: 700_101),
                position: position,
                generation: generation,
                rate: state == .playing ? 1 : 0,
                state: state,
                seekPhase: seekPhase
            )
        )
    }
}
