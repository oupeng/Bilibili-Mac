import BiliModels
import Testing

@testable import BiliApplication

/// 按页整体替换的翻页规则：总页数由总数与每页条数算出（`has_more` 可延长），越界、正在显示或正在加载的页不请求，
/// 失败的页可重试，总数与总页数在加载与失败期间保留，总数变少时退回最后一页，越界页没有总数时先回第 1 页再到最后
/// 一页，且一次意图里的改请求有上限。
struct PageReplacementPagingTests {
    typealias Paging = PageReplacementPaging<String>

    @Test(
        arguments: [
            (0, 30, 1),
            (30, 30, 1),
            (61, 30, 3),
            (60, 30, 2),
            (-5, 30, 1),
            (10, 0, 1),
            (Int.max, 30, Int.max / 30 + 1)
        ]
    )
    func pageCountDerivesFromTotalAndPageSize(totalCount: Int, pageSize: Int, expected: Int) {
        #expect(PageNumbering.pageCount(totalCount: totalCount, pageSize: pageSize) == expected)
    }

    @Test
    func startsOnTheFirstPageWithoutTotals() {
        let paging = Paging()

        #expect(paging.phase == .idle)
        #expect(paging.currentPage == 1)
        #expect(paging.pageCount == 1)
        #expect(paging.totalCount == nil)
        #expect(paging.accepts(1))
        #expect(!paging.accepts(2))
    }

    @Test
    func outOfRangeShownAndLoadingPagesAreNotRequested() {
        var paging = loaded(page: 1, totalCount: 61)

        #expect(!paging.accepts(0))
        #expect(!paging.accepts(4))
        #expect(!paging.accepts(1))
        #expect(paging.accepts(3))

        paging.beginLoading(page: 2)
        #expect(!paging.accepts(2))
        #expect(paging.accepts(3))
    }

    @Test
    func totalsSurviveLoadingAndFailureAndTheFailedPageIsRetryable() {
        var paging = loaded(page: 1, totalCount: 61)

        paging.beginLoading(page: 2)
        #expect(paging.pageCount == 3)
        #expect(paging.totalCount == 61)

        paging.fail(page: 2, error: .transportFailure)
        #expect(paging.phase == .failed(page: 2, error: .transportFailure))
        #expect(paging.currentPage == 2)
        #expect(paging.pageCount == 3)
        #expect(paging.totalCount == 61)
        #expect(paging.accepts(2))
    }

    @Test
    func shrinkingTotalRedirectsToTheLastPage() {
        var paging = loaded(page: 1, totalCount: 61)
        paging.beginLoading(page: 3)

        let outcome = paging.succeed(page: 3, content: "3", totalCount: 59, pageSize: 30)

        #expect(outcome == .request(page: 2))
        #expect(paging.phase == .loading(page: 2))
        #expect(paging.pageCount == 2)
        #expect(paging.succeed(page: 2, content: "2", totalCount: 59, pageSize: 30) == .show)
        #expect(paging.phase == .loaded(page: 2, content: "2"))
    }

    @Test
    func pageWithoutTotalBeyondTheEndGoesThroughTheFirstPageToTheLastPage() {
        var paging = loaded(page: 1, totalCount: 200, pageSize: 40)
        paging.beginLoading(page: 5)

        #expect(
            paging.succeed(page: 5, content: "", totalCount: nil, pageSize: 40) == .request(page: 1)
        )
        #expect(paging.totalCount == 200)
        #expect(
            paging.succeed(page: 1, content: "1", totalCount: 100, pageSize: 40)
                == .request(page: 3)
        )
        #expect(paging.succeed(page: 3, content: "3", totalCount: 100, pageSize: 40) == .show)
        #expect(paging.phase == .loaded(page: 3, content: "3"))
        #expect(paging.pageCount == 3)
    }

    @Test
    func redirectsStopAfterTheLimitWithinOneIntent() {
        var paging = loaded(page: 1, totalCount: 200, pageSize: 40)
        paging.beginLoading(page: 5)

        #expect(
            paging.succeed(page: 5, content: "", totalCount: nil, pageSize: 40) == .request(page: 1)
        )
        #expect(
            paging.succeed(page: 1, content: "1", totalCount: 200, pageSize: 40)
                == .request(page: 5)
        )
        #expect(paging.succeed(page: 5, content: "", totalCount: nil, pageSize: 40) == .show)
        #expect(paging.phase == .loaded(page: 5, content: ""))
    }

    @Test
    func hasMoreExtendsThePageCountBeyondTheTotal() {
        var paging = Paging()
        paging.beginLoading(page: 1)

        #expect(
            paging.succeed(page: 1, content: "1", totalCount: 10, pageSize: 40, hasMore: true)
                == .show
        )

        #expect(paging.pageCount == 2)
        #expect(paging.accepts(2))
    }

    @Test
    func resetClearsPhaseAndTotals() {
        var paging = loaded(page: 2, totalCount: 61)

        paging.reset()

        #expect(paging == Paging())
    }

    private func loaded(page: Int, totalCount: Int, pageSize: Int = 30) -> Paging {
        var paging = Paging()
        paging.beginLoading(page: page)
        _ = paging.succeed(
            page: page,
            content: "\(page)",
            totalCount: totalCount,
            pageSize: pageSize
        )
        return paging
    }
}
