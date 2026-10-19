import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕会话与呈现端的契约：每个被接受的时间线更新都交给呈现端，
/// 开关与模式控制同步清空或停止呈现；暂停时迟到的分段、打开弹幕与画面完成布局都不等后续快照就补位。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionPresentationTests {
    @Test
    func presentationSinkReceivesEveryAcceptedTimelineUpdate() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let repository = StubDanmakuRepository()
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 0,
                state: .paused
            )
        )
        try await sink.waitForUpdateCount(1, identity: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 2,
                state: .playing
            )
        )
        try await sink.waitForUpdateCount(2, identity: identity)

        let accepted = sink.updates.filter {
            $0.snapshot.identity == identity
        }
        try #require(accepted.count == 2)
        #expect(accepted[0].snapshot.state == .paused)
        #expect(accepted[0].batch?.clearsExisting == true)
        #expect(accepted[1].snapshot.rate == 2)
        #expect(accepted[1].batch == nil)
    }

    @Test
    func controlsClearOrStopPresentationSynchronously() throws {
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: StubDanmakuRepository()),
            timeline: SessionTimeline(),
            presentationSink: sink
        )

        session.setEnabled(false)
        #expect(sink.clearCount == 1)

        session.setModeVisibility(scrolling: false, top: true, bottom: true)
        #expect(sink.clearCount == 2)

        session.setSpeedLevel(.five)
        session.setOpacity(try #require(DanmakuOpacity(0.55)))
        session.setDisplayArea(.quarter)
        session.setDensity(.overlapping)
        #expect(sink.clearCount == 2)

        session.stop()
        #expect(sink.stopCount == 1)
    }

    /// 暂停中落地时分段还没到：落地只清屏，分段到达后会话用最近的快照再处理，补位不等继续播放。
    @Test
    func pausedLandingCatchesUpALateSegmentWithoutAnotherSnapshot() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PausedLateSegment", cid: 5)
        let (session, timeline, sink) = makeCatchUpSession()
        let paused = snapshot(
            identity: identity,
            position: 100,
            generation: 2,
            rate: 0,
            state: .paused
        )

        session.start(for: identity)
        timeline.publish(paused)
        try await sink.waitForUpdates { [unowned sink] in
            sink.updates.contains { $0.batch?.events.isEmpty == false }
        }

        let updates = sink.updates.filter { $0.snapshot.identity == identity }
        let catchUps = updates.compactMap(\.batch).filter(\.catchesUp)
        #expect(updates[0].batch?.clearsExisting == true)
        #expect(updates.allSatisfy { $0.snapshot == paused })
        #expect(catchUps.map { $0.events.map(\.id) } == [["visible"]])
        session.stop()
    }

    /// 拖动进度条：seeking 期间只清屏，落地后补位一次。
    @Test
    func draggingCatchesUpOnlyAfterTheLanding() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DragSession", cid: 9)
        let (session, timeline, sink) = makeCatchUpSession()

        session.start(for: identity)
        for position in [60.0, 80.0] {
            timeline.publish(
                snapshot(
                    identity: identity,
                    position: position,
                    generation: 1,
                    rate: 0,
                    state: .paused,
                    seekPhase: .seeking
                )
            )
        }
        timeline.publish(
            snapshot(identity: identity, position: 100, generation: 2, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            sink.updates.contains { $0.batch?.events.isEmpty == false }
        }

        let catchUps = sink.updates.compactMap(\.batch).filter(\.catchesUp)
        #expect(catchUps.map(\.landingGeneration) == [2])
        #expect(catchUps.map { $0.events.map(\.id) } == [["visible"]])
        session.stop()
    }

    /// 播放中分段迟到时由之后的快照补位，同一条弹幕只补一次。
    @Test
    func lateSegmentCatchesUpOnceWhilePlaying() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PlayingLateSegment", cid: 6)
        let (session, timeline, sink) = makeCatchUpSession()

        session.start(for: identity)
        var position = 100.0
        while !sink.updates.contains(where: { $0.batch?.events.isEmpty == false }) {
            let nextUpdate = sink.updateCount(for: identity) + 1
            timeline.publish(snapshot(identity: identity, position: position, generation: 2))
            try await sink.waitForUpdateCount(nextUpdate, identity: identity)
            position += 0.1
        }
        let nextUpdate = sink.updateCount(for: identity) + 1
        timeline.publish(snapshot(identity: identity, position: position, generation: 2))
        try await sink.waitForUpdateCount(nextUpdate, identity: identity)

        let delivered = sink.updates.compactMap(\.batch).flatMap(\.events).map(\.id)
        #expect(delivered == ["visible"])
        #expect(sink.updates.compactMap(\.batch).contains { $0.catchesUp })
        session.stop()
    }

    /// 暂停时打开弹幕立即补位，不等继续播放。
    @Test
    func enablingWhilePausedCatchesUpImmediately() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PausedEnable", cid: 7)
        let (session, timeline, sink) = makeCatchUpSession()
        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 100, generation: 2, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            sink.updates.contains { $0.batch?.events.isEmpty == false }
        }
        let updateCount = sink.updateCount(for: identity)

        session.setEnabled(false)
        session.setEnabled(true)

        let last = try #require(sink.updates.last)
        #expect(sink.updateCount(for: identity) == updateCount + 1)
        #expect(last.batch?.clearsExisting == true)
        #expect(last.batch?.catchesUp == true)
        #expect(last.batch?.events.map(\.id) == ["visible"])
        session.stop()
    }

    /// 画面尚未布局（没有补位窗口）时暂停中落地不补位；布局完成后会话用最近的快照补上，不等继续播放。
    @Test
    func pausedCatchUpWaitsForTheSurfaceAndHappensOnceItHasASize() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PausedNoSurface", cid: 8)
        let (session, timeline, sink) = makeCatchUpSession()
        sink.catchUpWindowSeconds = nil
        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 100, generation: 2, rate: 0, state: .paused)
        )
        try await sink.waitForUpdateCount(1, identity: identity)
        #expect(sink.updates.allSatisfy { $0.batch?.events.isEmpty ?? true })

        sink.makeCatchUpWindowAvailable(10)
        try await sink.waitForUpdates { [unowned sink] in
            sink.updates.contains { $0.batch?.catchesUp == true }
        }

        let catchUps = sink.updates.compactMap(\.batch).filter(\.catchesUp)
        #expect(catchUps.map { $0.events.map(\.id) } == [["visible"]])
        session.stop()
    }

    /// 回看窗口 10 秒、第 1 段在 95 秒有一条弹幕的会话：在 100 秒处补位时它应在屏上。
    private func makeCatchUpSession()
        -> (DanmakuSession, SessionTimeline, SessionPresentationSink)
    {
        let repository = StubDanmakuRepository(
            eventsBySegment: [1: [timedEvent(id: "visible", time: 95)]]
        )
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        sink.catchUpWindowSeconds = 10
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        return (session, timeline, sink)
    }
}
