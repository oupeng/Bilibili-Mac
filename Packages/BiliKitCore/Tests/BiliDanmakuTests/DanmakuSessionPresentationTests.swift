import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕会话与呈现端的契约：当前 identity 的每个快照原样交给呈现端；分段到达时交出整份缓存；
/// 开关、模式与停止同步转给呈现端；暂停时一个分段加载完就继续请求还缺的分段，不等下一个快照。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionPresentationTests {
    @Test
    func presentationSinkReceivesEveryAcceptedSnapshot() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let (session, timeline, sink) = makeSession(repository: StubDanmakuRepository())

        session.start(for: identity)
        let paused = snapshot(
            identity: identity,
            position: 1,
            generation: 7,
            rate: 0,
            state: .paused
        )
        let playing = snapshot(identity: identity, position: 1, generation: 7, rate: 2)
        timeline.publish(paused)
        try await sink.waitForUpdateCount(1, identity: identity)
        timeline.publish(
            snapshot(
                identity: PlaybackItemIdentity(bvid: "BV1Other", cid: 1),
                position: 3,
                generation: 1
            )
        )
        timeline.publish(playing)
        try await sink.waitForUpdateCount(2, identity: identity)

        #expect(sink.snapshots.filter { $0.identity == identity } == [paused, playing])
        #expect(sink.snapshots.allSatisfy { $0.identity == identity })
        session.stop()
    }

    @Test
    func controlsReachThePresentationSynchronously() throws {
        let (session, _, sink) = makeSession(repository: StubDanmakuRepository())

        session.setEnabled(false)
        session.setEnabled(false)
        #expect(sink.enabledChanges == [false])

        session.setModeVisibility(scrolling: false, top: true, bottom: true)
        #expect(sink.filters == [DanmakuFilter(showsScrolling: false)])

        session.stop()
        #expect(sink.stopCount == 1)
    }

    /// 暂停中只来一个快照：分段到达后整份缓存交给呈现端，腾出的名额立即用来请求还缺的分段。
    @Test
    func pausedSessionDeliversSegmentsAndKeepsLoadingWithoutAnotherSnapshot() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PausedSegments", cid: 5)
        let events: [Int: [DanmakuEvent]] = [
            1: [timedEvent(id: "previous", time: 350)],
            2: [timedEvent(id: "current", time: 370)],
            3: [timedEvent(id: "next", time: 730)]
        ]
        let repository = StubDanmakuRepository(eventsBySegment: events)
        let (session, timeline, sink) = makeSession(repository: repository)

        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 365, generation: 1, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            sink.segmentDeliveries.last?.segments.count == 3
        }

        #expect(sink.snapshots.count == 1)
        #expect(sink.segmentDeliveries.allSatisfy { $0.identity == identity })
        let delivered = try #require(sink.segmentDeliveries.last?.segments)
        #expect(delivered.mapValues { $0.map(\.id) } == events.mapValues { $0.map(\.id) })
        session.stop()
    }

    private func makeSession(
        repository: StubDanmakuRepository
    ) -> (DanmakuSession, SessionTimeline, SessionPresentationSink) {
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        return (session, timeline, sink)
    }
}
