import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 自动连播与列表循环的下一项：先按分 P，再按合集当前分部的下一集，不跨分部；到了末尾自动连播停下，
/// 列表循环回到分部第一集（第一集就是当前视频时回到它的 P1），没有合集时回到 P1，只有一个分 P 时从头再播；
/// 认不出当前是哪一集时按没有合集处理。
struct PlaybackNextItemTests {
    private let pages = [makeTestPage(1), makeTestPage(2)]

    @Test
    func pagesComeFirstThenTheEndOfAVideoWithoutACollection() {
        let context = context(pages: pages)
        #expect(next(after: pages[0], in: context, wraps: false) == .page(pages[1]))
        #expect(next(after: pages[1], in: context, wraps: false) == nil)
        #expect(next(after: pages[1], in: context, wraps: true) == .page(pages[0]))

        let single = self.context(pages: [pages[0]])
        #expect(next(after: pages[0], in: single, wraps: false) == nil)
        #expect(next(after: pages[0], in: single, wraps: true) == .replay)
    }

    @Test
    func collectionAdvancesWithinTheCurrentSectionAndWrapsToItsFirstEpisode() {
        let first = makeTestEpisode(ordinal: 0, bvid: "BVFirst", pages: [makeTestPage(7)])
        let current = makeTestEpisode(ordinal: 1, bvid: "BVCurrent", pages: pages)
        let following = makeTestEpisode(ordinal: 2, bvid: "BVNext", pages: [makeTestPage(8)])
        let otherSection = makeTestEpisode(
            ordinal: 3,
            bvid: "BVOther",
            pages: [makeTestPage(9)],
            section: 1
        )
        let middle = context(
            pages: pages,
            collection: makeTestCollection(sections: [[first, current, following], [otherSection]])
        )
        let firstOfCurrent = next(after: pages[0], in: middle, episode: current, wraps: false)
        #expect(firstOfCurrent == .page(pages[1]))
        #expect(
            next(after: pages[1], in: middle, episode: current, wraps: false) == .episode(following)
        )

        let last = context(
            pages: pages,
            collection: makeTestCollection(sections: [[first, current], [otherSection]])
        )
        #expect(next(after: pages[1], in: last, episode: current, wraps: false) == nil)
        #expect(next(after: pages[1], in: last, episode: current, wraps: true) == .episode(first))
        #expect(next(after: pages[1], in: last, episode: nil, wraps: true) == .page(pages[0]))

        let alone = context(
            pages: pages,
            collection: makeTestCollection(sections: [[current], [otherSection]])
        )
        #expect(next(after: pages[1], in: alone, episode: current, wraps: true) == .page(pages[0]))
    }

    private func next(
        after page: VideoPage,
        in context: VideoContext,
        episode: VideoCollectionEpisode? = nil,
        wraps: Bool
    ) -> PlaybackNextItem? {
        PlaybackNextItem.after(page: page, in: context, episode: episode, wraps: wraps)
    }

    private func context(pages: [VideoPage], collection: VideoCollection? = nil) -> VideoContext {
        makeVideoContext(
            detail: makeVideoDetail(durationSeconds: 20, pages: pages, collection: collection)
        )
    }
}
