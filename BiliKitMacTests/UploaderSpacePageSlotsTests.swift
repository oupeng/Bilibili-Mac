import Testing

@testable import BiliKit

struct UploaderSpacePageSlotsTests {
    @Test(
        arguments: [
            // 首页、末页与当前页前后各两页；中间断开处是省略号。
            (7, 32, [p(1), gap(2...4), p(5), p(6), p(7), p(8), p(9), gap(10...31), p(32)]),
            // 只省略一页时直接显示那一页。
            (4, 32, [p(1), p(2), p(3), p(4), p(5), p(6), gap(7...31), p(32)]),
            (1, 3, [p(1), p(2), p(3)]),
            (1, 1, [p(1)]),
            (32, 32, [p(1), gap(2...29), p(30), p(31), p(32)]),
            // 越界的当前页夹进有效范围，页数为 0 时没有页码。
            (99, 5, [p(1), p(2), p(3), p(4), p(5)]),
            (1, 0, [])
        ] as [(Int, Int, [UploaderSpacePageSlot])]
    )
    func slotsShowEdgesNeighborsAndCollapsedGaps(
        currentPage: Int,
        pageCount: Int,
        expected: [UploaderSpacePageSlot]
    ) {
        #expect(
            UploaderSpacePageSlots.slots(currentPage: currentPage, pageCount: pageCount) == expected
        )
    }
}

private func p(_ page: Int) -> UploaderSpacePageSlot {
    .page(page)
}

private func gap(_ range: ClosedRange<Int>) -> UploaderSpacePageSlot {
    .gap(range)
}
