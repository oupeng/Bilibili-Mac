import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放器动作菜单的分享地址：多 P 带当前分 P、单 P 不带，播放位置属于当前分 P 且不在开头或片尾 5 秒内时带时间；
/// 时间线属于别的 item 时不带时间，旧详情不可操作时没有可操作的 BV 号与地址。
@Suite(.timeLimit(.minutes(1)))
struct VideoShareLinkTests {
    @Test(
        arguments: [(4.9, nil), (5, 5), (95.7, 95), (114.9, 114), (115, nil), (120, nil)]
            as [(Double, Int?)]
    )
    func startSecondsSkipTheOpeningAndTheEnding(position: Double, expected: Int?) {
        #expect(
            PlaybackShareLinkPolicy.startSeconds(positionSeconds: position, durationSeconds: 120)
                == expected
        )
    }

    @Test
    @MainActor
    func linkCarriesThePresentedPageAndOnlyItsOwnTimeline() async throws {
        let fixture = ContentFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture, pages: fixture.twoPages)
            ),
            playback: PlayerStub()
        )
        model.loadVideo(fixture.bvid, preferredCID: 900_002)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        let base = "https://www.bilibili.com/video/\(fixture.bvid)?p=2"
        let current = model.shareURL(timeline: snapshot(identity, position: 42))
        #expect(current?.absoluteString == base + "&t=42")
        let other = PlaybackItemIdentity(bvid: fixture.bvid, cid: 900_001)
        #expect(model.shareURL(timeline: snapshot(other, position: 42))?.absoluteString == base)

        model.reset()
        #expect(model.shareURL(timeline: snapshot(identity, position: 42)) == nil)
    }

    @Test
    @MainActor
    func singlePageLinkHasNoPageNumber() async throws {
        let fixture = ContentFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: VideoRepositoryStub(fixture)),
            playback: PlayerStub()
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        let url = model.shareURL(timeline: snapshot(identity, position: 42))
        #expect(url?.absoluteString == "https://www.bilibili.com/video/\(fixture.bvid)?t=42")
    }

    /// 换到另一个视频失败后旧详情仍保留显示，但不可操作：没有 BV 号也没有地址。
    @Test
    @MainActor
    func retainedDetailOfAFailedSwitchIsNotOperable() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(
            detail: { bvid, _ in
                guard bvid == fixture.bvid else { throw ContentApplicationError.invalidRequest }
                return fixture.detail
            },
            pages: { _, _ in [fixture.page] },
            playback: { _, _ in fixture.playback }
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        model.loadVideo("BV1Unavailable")
        await waitUntilSettled(model)

        #expect(model.presentedBVID == fixture.bvid)
        #expect(model.operableBVID == nil)
        #expect(model.shareURL(timeline: snapshot(identity, position: 42)) == nil)
    }

    private func snapshot(
        _ identity: PlaybackItemIdentity,
        position: Double
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 180,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 0
        )
    }
}
