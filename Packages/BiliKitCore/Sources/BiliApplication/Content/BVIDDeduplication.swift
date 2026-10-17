/// 首页推荐、热门、搜索与观看历史一次分页会话的上限（`PagedVideoList`）；达到任一项即停止翻页。
package enum VideoListRetention {
    /// 内存中最多保留的条目数。
    package static let maximumItemCount = 1_000
    /// 显式继续策略（历史）一次分页会话最多加载更多的页数。
    ///
    /// 无进展即停止的来源每页至少并入一条，页数已随条目上限有界，不受此约束；历史没有新条目的页要用户显式
    /// 继续，不受条目上限约束，另以此封顶，已消费游标的线性查找随之有界。按每页 20 条，1000 条约 50 页，
    /// 这里留出同样多的空页或全重复页余量；调小会让历史在空页较多时提前停止。
    package static let maximumLoadedPages = 100
}

/// 一页条目并入已有列表的结果。
package struct VideoListAppend<Element> {
    /// 已有条目加上本页新增、且不超过上限的条目。
    package let items: [Element]
    /// 实际并入的新条目数；为 0 表示本页没有新内容（或已经没有余量）。
    package let appendedCount: Int

    /// 已达到 `VideoListRetention.maximumItemCount`，调用方不再请求下一页。
    package var isAtCapacity: Bool {
        items.count >= VideoListRetention.maximumItemCount
    }

    /// 本页有新内容且仍有余量：推荐、热门与搜索据此决定是否继续翻页。
    package var continuesPagination: Bool {
        appendedCount > 0 && !isAtCapacity
    }
}

extension Array {
    /// 按 BVID 去重：丢弃与 `existing` 或自身前文重复的条目，保持原顺序。
    ///
    /// Feed 与历史分页共用；"本页没有新增条目"时怎样停止分页仍由各 Feature 自行决定。
    package func uniquedByBVID(
        after existing: [Element] = [],
        _ bvid: (Element) -> String
    ) -> [Element] {
        var seen = Set(existing.map(bvid))
        return filter { seen.insert(bvid($0)).inserted }
    }

    /// 把一页条目按 BVID 去重后接在本列表之后，总数截到 `VideoListRetention.maximumItemCount`。
    ///
    /// 第一页以空列表调用。四个列表来源共用同一上限与截断方式。
    package func appendingVideoPage(
        _ page: [Element],
        _ bvid: (Element) -> String
    ) -> VideoListAppend<Element> {
        let remainingCapacity = Swift.max(0, VideoListRetention.maximumItemCount - count)
        let appended = page.uniquedByBVID(after: self, bvid).prefix(remainingCapacity)
        return VideoListAppend(items: self + appended, appendedCount: appended.count)
    }
}
