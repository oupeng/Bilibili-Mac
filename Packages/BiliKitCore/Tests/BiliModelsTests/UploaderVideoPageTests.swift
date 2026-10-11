import Testing

@testable import BiliModels

struct UploaderVideoPageTests {
    @Test(
        arguments: [
            (0, 1, 1, false),
            (30, 1, 1, false),
            (61, 1, 3, true),
            (61, 3, 3, false),
            (60, 2, 2, false),
            (-5, 1, 1, false),
            (Int.max, 1, Int.max / 30 + 1, true)
        ]
    )
    func pageCountAndHasMoreDeriveFromTotal(
        totalCount: Int,
        pageNumber: Int,
        expectedPageCount: Int,
        expectedHasMore: Bool
    ) {
        let page = UploaderVideoPage(
            videos: [],
            pageNumber: pageNumber,
            pageSize: 30,
            totalCount: totalCount
        )

        #expect(page.pageCount == expectedPageCount)
        #expect(page.hasMore == expectedHasMore)
    }
}
