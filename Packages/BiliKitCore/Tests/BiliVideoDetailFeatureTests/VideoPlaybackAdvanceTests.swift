import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 连播在合集里认出正在播放的那一集：同一 BV 的各集各是一个分 P 时按 CID 认，在当前视频里换过分 P 也不回头；
/// 选集菜单里另选、解析失败的一集不算当前；下一集缺少播放身份时停下并说明。
@Suite(.timeLimit(.minutes(1)))
struct VideoPlaybackAdvanceTests {
    private let pages = [makeTestPage(1), makeTestPage(2), makeTestPage(3)]

    @Test
    @MainActor
    func pagesOfOneVideoListedAsEpisodesAreNotReplayed() async throws {
        let episodes = pages.enumerated().map { ordinal, page in
            makeTestEpisode(ordinal: ordinal, bvid: "BVCurrent", pages: [page])
        }
        let next = makeTestEpisode(ordinal: 3, bvid: "BVNext", pages: [makeTestPage(9)])
        let (model, player) = await loaded(collection: [episodes + [next]])

        model.selectPage(cid: pages[2].cid)
        await waitUntilSettled(model)

        #expect(await ended(model, player) == .advance(.episode(next)))
    }

    @Test
    @MainActor
    func aFailedSelectionOfAnotherEpisodeIsNotTheCurrentOne() async throws {
        let current = makeTestEpisode(ordinal: 0, bvid: "BVCurrent", pages: pages)
        let next = makeTestEpisode(ordinal: 1, bvid: "BVNext", pages: [makeTestPage(8)])
        let failing = makeTestEpisode(ordinal: 2, bvid: "BVFailing", pages: nil)
        let last = makeTestEpisode(ordinal: 3, bvid: "BVLast", pages: [makeTestPage(9)])
        let (model, player) = await loaded(collection: [[current, next, failing, last]])
        model.selectPage(cid: pages[2].cid)
        await waitUntilSettled(model)

        model.selectCollectionEpisode(failing) { _, _ in }
        await waitForObservedState {
            if case .failed = model.collectionEpisodePageStates[failing.id] { return true }
            return false
        }

        #expect(await ended(model, player) == .advance(.episode(next)))
    }

    @Test
    @MainActor
    func nextEpisodeWithoutAPlaybackIdentityStops() async throws {
        let current = makeTestEpisode(ordinal: 0, bvid: "BVCurrent", pages: pages)
        let broken = makeTestEpisode(
            ordinal: 1,
            bvid: "BVBroken",
            pages: [makeTestPage(9)],
            isConsistent: false
        )
        let (model, player) = await loaded(collection: [[current, broken]])
        model.selectPage(cid: pages[2].cid)
        await waitUntilSettled(model)

        #expect(await ended(model, player) == .nextUnavailable)
    }

    /// 载入 `BVCurrent`（三个分 P）；合集里 `BVFailing` 的分 P 读取失败。
    @MainActor
    private func loaded(
        collection sections: [[VideoCollectionEpisode]]
    ) async -> (VideoViewModel, PlayerStub) {
        let detail = makeVideoDetail(
            bvid: "BVCurrent",
            pages: pages,
            collection: makeTestCollection(sections: sections)
        )
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(
            detail: { bvid, _ in
                guard bvid != "BVFailing" else { throw ContentApplicationError.transportFailure }
                return detail
            },
            pages: { [pages] _, _ in pages },
            playback: { _, _ in fixture.playback }
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo("BVCurrent")
        await waitUntilSettled(model)
        return (model, player)
    }

    @MainActor
    private func ended(_ model: VideoViewModel, _ player: PlayerStub) async -> PlaybackEndHandling {
        guard let identity = model.presentedPlaybackIdentity,
            let intent = player.loadedIntents.last
        else { return .none }
        return await model.handlePlaybackEnded(
            PlaybackTimelineSnapshot(
                identity: identity,
                positionSeconds: 10,
                durationSeconds: 10,
                rate: 0,
                state: .ended,
                discontinuityGeneration: 0,
                loadIntent: intent
            ),
            behavior: .autoAdvance
        )
    }
}
