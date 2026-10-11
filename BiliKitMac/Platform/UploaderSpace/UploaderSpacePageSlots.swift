/// 页码条展开后显示的页码：首页、末页、当前页前后各 `neighborCount` 页，中间断开处用省略号。
enum UploaderSpacePageSlot: Hashable, Sendable {
    case page(Int)
    case gap(ClosedRange<Int>)
}

enum UploaderSpacePageSlots {
    static let neighborCount = 2

    /// 只省略一页时直接显示那一页：省略号并不比数字更短。
    static func slots(currentPage: Int, pageCount: Int) -> [UploaderSpacePageSlot] {
        guard pageCount > 0 else { return [] }
        let current = min(max(1, currentPage), pageCount)
        let lower = max(1, current - neighborCount)
        let upper = min(pageCount, current + neighborCount)
        let pages = Set(lower...upper).union([1, pageCount]).sorted()
        var slots: [UploaderSpacePageSlot] = []
        var previous: Int?
        for page in pages {
            if let previous, page - previous > 1 {
                let hidden = (previous + 1)...(page - 1)
                slots.append(hidden.count == 1 ? .page(hidden.lowerBound) : .gap(hidden))
            }
            slots.append(.page(page))
            previous = page
        }
        return slots
    }
}
