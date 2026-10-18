import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕会话与呈现端的契约：每个被接受的时间线更新都交给呈现端，
/// 开关与模式控制同步清空或停止呈现。
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
}
