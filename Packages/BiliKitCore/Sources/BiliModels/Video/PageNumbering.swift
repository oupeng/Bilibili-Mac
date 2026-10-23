/// 按页码翻页的列表由总条数与每页条数得出的总页数与某页的条数；UP 主空间投稿、评论楼中楼与收藏夹内容的总页数、
/// 收藏夹加载骨架的本页条数只在这里算。
///
/// 调用方是同一 Package 里的 BiliApplication 与 VideoDetail，所以是 `package`。
package enum PageNumbering {
    /// 至少为 1：没有条目时也有一页（空页）；每页条数不是正数时按一页。
    package static func pageCount(totalCount: Int, pageSize: Int) -> Int {
        guard totalCount > 0, pageSize > 0 else { return 1 }
        let (quotient, remainder) = totalCount.quotientAndRemainder(dividingBy: pageSize)
        return quotient + (remainder == 0 ? 0 : 1)
    }

    /// 第 `page` 页（从 1 开始）应有的条数。
    ///
    /// 不超过每页条数，落在总数之后的页为 0；每页条数不是正数时为 0。
    package static func itemCount(onPage page: Int, totalCount: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else { return 0 }
        let preceding = max(0, page - 1) * pageSize
        return min(pageSize, max(0, totalCount - preceding))
    }
}
