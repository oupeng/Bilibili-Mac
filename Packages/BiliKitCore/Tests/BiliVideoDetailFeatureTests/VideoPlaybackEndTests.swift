import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播完的处理只作用于此刻呈现、也是最新请求的那一项：单集循环时重播它，不循环、时间线还没到结尾、
/// 或结束来自别的 item 时不动作。
@Suite(.timeLimit(.minutes(1)))
struct VideoPlaybackEndTests {
    @Test
    @MainActor
    func onlyTheEndOfThePresentedItemReplaysUnderRepeatOne() async throws {
        let fixture = ContentFixtures()
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture, pages: fixture.twoPages)
            ),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)
        let intent = try #require(player.loadedIntents.last)
        let otherPage = PlaybackItemIdentity(bvid: fixture.bvid, cid: 900_002)

        func handles(
            _ snapshot: PlaybackTimelineSnapshot,
            _ behavior: PlaybackEndBehavior = .repeatOne
        ) async -> Bool {
            await model.handlePlaybackEnded(snapshot, behavior: behavior)
        }
        #expect(await !handles(snapshot(identity, intent, .ended), .stop))
        #expect(await !handles(snapshot(identity, intent, .paused)))
        #expect(await !handles(snapshot(otherPage, intent, .ended)))
        #expect(await !handles(snapshot(identity, PlaybackLoadIntent(), .ended)))
        #expect(player.replayedIdentities.isEmpty)

        #expect(await handles(snapshot(identity, intent, .ended)))
        #expect(player.replayedIdentities == [identity])
    }

    private func snapshot(
        _ identity: PlaybackItemIdentity,
        _ intent: PlaybackLoadIntent,
        _ state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 120,
            durationSeconds: 120,
            rate: 0,
            state: state,
            discontinuityGeneration: 0,
            loadIntent: intent
        )
    }
}
