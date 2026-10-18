import Foundation

/// 稍后再看的排序：按加入时间从新到旧（默认）或从旧到新。BiliAPI 把它映射为 `asc`。
public enum WatchLaterOrder: Sendable, Hashable, CaseIterable, Identifiable {
    case newestAdded
    case oldestAdded

    public var id: Self { self }
}

/// 稍后再看的观看进度筛选：全部（默认）或只看未看完的。BiliAPI 把它映射为 `viewed`。
public enum WatchLaterProgressFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case unfinished

    public var id: Self { self }
}

/// 稍后再看的加入时间筛选选项；由 `WatchLaterAddedTimeRangeResolver` 解析为冻结的区间后才进入 criteria。
public enum WatchLaterAddedTimeFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case lastSevenDays
    case custom

    public var id: Self { self }
}

/// 已冻结的加入时间区间（Unix 秒，含开始、不含结束）；相对时间在应用筛选时解析为该值，之后翻页不再变化。
public struct WatchLaterAddedTimeRange: Sendable, Hashable {
    public let startTimestamp: Int64
    public let endTimestamp: Int64

    public init(startTimestamp: Int64, endTimestamp: Int64) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// `WatchLaterAddedTimeRangeResolver` 无法给出区间的原因：自定义的开始日晚于结束日，或日历无法推算日期。
public enum WatchLaterAddedTimeRangeError: Error, Sendable, Equatable {
    case startAfterEnd
    case invalidCalendarRange
}

/// 把加入时间选项按 `now` 与 `calendar`（含时区）解析为区间。
///
/// 今天是今天 0 点到现在；昨天是昨天 0 点到今天 0 点；近一周是现在往前 7 天到现在；自定义是开始日 0 点到结束日
/// 次日 0 点（含结束日当天）。与搜索的发布日期（`VideoPublicationRangeResolver`，整日闭区间、结束日不得晚于今天）
/// 语义不同，所以不共用：稍后再看网页端按“到现在”与“往前 7×24 小时”取区间。
public enum WatchLaterAddedTimeRangeResolver {
    public static func resolve(
        filter: WatchLaterAddedTimeFilter,
        customStart: Date,
        customEnd: Date,
        now: Date,
        calendar: Calendar
    ) throws -> WatchLaterAddedTimeRange? {
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch filter {
        case .all:
            return nil
        case .today:
            start = today
            end = now
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                throw WatchLaterAddedTimeRangeError.invalidCalendarRange
            }
            start = yesterday
            end = today
        case .lastSevenDays:
            start = now.addingTimeInterval(-7 * 24 * 60 * 60)
            end = now
        case .custom:
            let startDay = calendar.startOfDay(for: customStart)
            let endDay = calendar.startOfDay(for: customEnd)
            guard startDay <= endDay else {
                throw WatchLaterAddedTimeRangeError.startAfterEnd
            }
            guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
                throw WatchLaterAddedTimeRangeError.invalidCalendarRange
            }
            start = startDay
            end = endExclusive
        }
        return WatchLaterAddedTimeRange(
            startTimestamp: Int64(start.timeIntervalSince1970),
            endTimestamp: Int64(end.timeIntervalSince1970)
        )
    }
}

/// 稍后再看一个列表的完整条件：排序、观看进度、加入时间、时长与关键词。
///
/// 关键词在初始化时去掉首尾空白，空串表示不按关键词过滤（由服务端匹配）。
public struct WatchLaterCriteria: Sendable, Hashable {
    /// 关键词长度上限（按字符计）：远超网页端输入框的实际用途，只用来拒绝异常输入；超出时不发请求。
    public static let maximumKeywordLength = 100

    public let order: WatchLaterOrder
    public let progress: WatchLaterProgressFilter
    public let addedTime: WatchLaterAddedTimeRange?
    public let duration: VideoDurationFilter
    public let keyword: String

    public init(
        order: WatchLaterOrder = .newestAdded,
        progress: WatchLaterProgressFilter = .all,
        addedTime: WatchLaterAddedTimeRange? = nil,
        duration: VideoDurationFilter = .all,
        keyword: String = ""
    ) {
        self.order = order
        self.progress = progress
        self.addedTime = addedTime
        self.duration = duration
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 关键词不超过上限，加入时间区间不为负且开始早于结束。
    public var isValid: Bool {
        guard keyword.count <= Self.maximumKeywordLength else { return false }
        guard let addedTime else { return true }
        return addedTime.startTimestamp >= 0 && addedTime.startTimestamp < addedTime.endTimestamp
    }

    /// 有筛选或关键词在起作用（排序不算）：结果为空时说明是条件筛掉了，而不是列表本身为空。
    public var narrowsResults: Bool {
        progress != .all || addedTime != nil || duration != .all || !keyword.isEmpty
    }
}

/// 稍后再看的一次请求：完整条件加页码。也是分页游标，翻页只改变 `page`，旧条件的页因此不会并入新条件的列表。
public struct WatchLaterRequest: Sendable, Hashable {
    public let criteria: WatchLaterCriteria
    public let page: Int

    public init(criteria: WatchLaterCriteria = WatchLaterCriteria(), page: Int = 1) {
        self.criteria = criteria
        self.page = page
    }
}
