import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播完的处理只作用于此刻呈现、也是最新请求的那一项：单集循环时重播它，不循环、时间线还没到结尾、
/// 或结束来自别的 item 时不动作；重播成功后断点浮层收起，失败时保留并报告没有重播；自动连播把下一项交给导航，
/// 列表里只有当前一个分 P 时列表循环从头再播、自动连播停下。
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
            await model.handlePlaybackEnded(snapshot, behavior: behavior) == .replayed
        }
        #expect(await !handles(snapshot(identity, intent, .ended), .stop))
        #expect(await !handles(snapshot(identity, intent, .paused)))
        #expect(await !handles(snapshot(otherPage, intent, .ended)))
        #expect(await !handles(snapshot(identity, PlaybackLoadIntent(), .ended)))
        #expect(player.replayedIdentities.isEmpty)

        #expect(await handles(snapshot(identity, intent, .ended)))
        #expect(player.replayedIdentities == [identity])
    }

    /// 自动连播在多 P 视频里给出下一个分 P 交由导航跳转、不在这里重播；列表循环在只有一个分 P 时从头再播。
    @Test
    @MainActor
    func autoAdvanceHandsTheNextPageToNavigationAndListLoopReplaysASinglePage() async throws {
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
        let advance = await model.handlePlaybackEnded(
            snapshot(identity, intent, .ended),
            behavior: .autoAdvance
        )
        #expect(advance == .advance(.page(bvid: fixture.bvid, page: fixture.twoPages[1])))
        #expect(player.replayedIdentities.isEmpty)

        let singlePlayer = PlayerStub()
        let single = makeVideoViewModel(
            useCase: VideoUseCase(repository: VideoRepositoryStub(fixture)),
            playback: singlePlayer
        )
        single.loadVideo(fixture.bvid)
        await waitUntilSettled(single)
        let singleIdentity = try #require(single.presentedPlaybackIdentity)
        let singleIntent = try #require(singlePlayer.loadedIntents.last)
        let looped = await single.handlePlaybackEnded(
            snapshot(singleIdentity, singleIntent, .ended),
            behavior: .repeatList
        )
        #expect(looped == .replayed)
        #expect(
            await single.handlePlaybackEnded(
                snapshot(singleIdentity, singleIntent, .ended),
                behavior: .autoAdvance
            ) == .none
        )
    }

    @Test(arguments: [true, false])
    @MainActor
    func replayClearsTheResumeNoticeOnlyWhenItSucceeds(succeeds: Bool) async throws {
        let fixture = ContentFixtures()
        let metadata = try #require(
            PlaybackResumeMetadata(lastPlayedCID: 900_001, positionMilliseconds: 42_500)
        )
        let player = PlayerStub(
            startOutcome: .resumed(positionSeconds: 42.5, token: PlaybackResumeToken()),
            replaySucceeds: succeeds
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    playback: { _, _ in fixture.playback(resuming: metadata) }
                )
            ),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)
        let intent = try #require(player.loadedIntents.last)
        #expect(model.resumeNotice != nil)

        let replayed = await model.handlePlaybackEnded(
            snapshot(identity, intent, .ended),
            behavior: .repeatOne
        )

        #expect(replayed == (succeeds ? .replayed : .replayFailed))
        #expect((model.resumeNotice == nil) == succeeds)
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
