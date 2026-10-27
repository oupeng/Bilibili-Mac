import BiliApplication
import Testing

@testable import BiliVideoDetailFeature

/// 楼中楼页码条的总页数：按总数推算，没读到总数时用根评论给的回复数；末页就是当前页，否则至少还有下一页。
@Suite
@MainActor
struct PlaybackCommentReplyPagerTests {
    @Test(arguments: [
        (25, 1, false, 0, 3),
        (0, 1, false, 25, 3),
        (25, 3, true, 0, 3),
        (25, 3, false, 0, 4),
        (10, 2, true, 0, 2)
    ])
    func pageCountFollowsTotalsAndTheKnownEnd(
        totalCount: Int,
        pageNumber: Int,
        isEnd: Bool,
        replyCount: Int,
        expected: Int
    ) {
        var state = PlaybackCommentReplyState()
        state.totalCount = totalCount
        state.pageNumber = pageNumber
        state.isEnd = isEnd
        #expect(
            NativePlaybackCommentReplyPager.pageCount(for: state, replyCount: replyCount)
                == expected
        )
    }
}
