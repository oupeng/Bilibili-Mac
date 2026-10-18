import BiliApplication
import Foundation

/// 已应用到搜索上的排序与筛选，由 `VideoSearchSession` 持有；与查询词组合成 `VideoSearchCriteria`。
///
/// 只因 `SearchFilterSelection.resolvedFilters()` 公开（App 的筛选弹窗据它校验日期）而是 public 类型，成员仍只在本
/// Feature 内使用。
public struct AppliedVideoSearchFilters: Hashable, Sendable {
    var order: VideoSearchOrder = .relevance
    var duration: VideoDurationFilter = .all
    var publicationRange: VideoPublicationTimeRange?

    func criteria(query: String) -> VideoSearchCriteria {
        VideoSearchCriteria(
            query: query,
            order: order,
            duration: duration,
            publicationRange: publicationRange
        )
    }
}

/// 工具栏排序菜单与筛选弹窗编辑的选择；自定义日期在应用时才解析为时间范围。
public struct SearchFilterSelection: Hashable, Sendable {
    public var order: VideoSearchOrder = .relevance
    public var publication = VideoPublicationFilter.all
    public var duration = VideoDurationFilter.all
    public var customStart =
        Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    public var customEnd = Date()

    public init() {}

    /// 启用中的筛选数（排序不算）。
    public var activeFilterCount: Int {
        (publication == .all ? 0 : 1) + (duration == .all ? 0 : 1)
    }

    public mutating func resetFilters() {
        publication = .all
        duration = .all
    }

    /// 按此刻与当前日历解析；自定义日期不合法（开始晚于结束、晚于今天、早于 1970 年、日历换算失败）时抛出
    /// `DateRangeFilterError`。
    public func resolvedFilters() throws -> AppliedVideoSearchFilters {
        AppliedVideoSearchFilters(
            order: order,
            duration: duration,
            publicationRange: try VideoPublicationRangeResolver.resolve(
                filter: publication,
                customStart: customStart,
                customEnd: customEnd,
                now: Date(),
                calendar: .current
            )
        )
    }
}
