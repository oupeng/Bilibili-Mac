import Foundation

/// 搜索结果的排序方式；BiliAPI 把它映射为接口的 `order` 参数，rawValue 不进入请求。
public enum VideoSearchOrder: String, Sendable, Hashable, CaseIterable, Identifiable {
    case relevance
    case mostPlayed
    case newest
    case mostDanmaku
    case mostFavorited

    public var id: Self { self }
}

/// 视频时长的四档筛选，搜索与稍后再看共用；每档的秒数边界只在 `secondsRange`。
///
/// 搜索把 rawValue 原样作为接口的 `duration` 参数（1–4 正是这四档），稍后再看把 `secondsRange` 映射为
/// `arc_min_duration`／`arc_max_duration`；改动 rawValue 或边界会改变请求含义。
public enum VideoDurationFilter: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case all = 0
    case underTenMinutes = 1
    case tenToThirtyMinutes = 2
    case thirtyToSixtyMinutes = 3
    case overSixtyMinutes = 4

    public var id: Self { self }

    /// 这一档的时长下限与上限（秒）；nil 表示该侧不限，`all` 两侧都不限。
    public var secondsRange: (minimum: Int?, maximum: Int?) {
        switch self {
        case .all: (nil, nil)
        case .underTenMinutes: (nil, 600)
        case .tenToThirtyMinutes: (600, 1_800)
        case .thirtyToSixtyMinutes: (1_800, 3_600)
        case .overSixtyMinutes: (3_600, nil)
        }
    }
}

/// 已冻结的闭区间；相对日期在进入搜索 criteria 前解析为该值，避免跨午夜改变请求含义。
public struct VideoPublicationTimeRange: Sendable, Hashable {
    public let beginTimestamp: Int64
    public let endTimestamp: Int64

    public init(beginTimestamp: Int64, endTimestamp: Int64) {
        self.beginTimestamp = beginTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// 搜索页的发布时间筛选选项；由 `VideoPublicationRangeResolver` 解析为冻结的闭区间后才进入
/// criteria。
public enum VideoPublicationFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case last180Days
    case custom

    public var id: Self { self }
}

/// `VideoPublicationRangeResolver` 无法给出区间的原因：起始晚于结束、结束晚于今天，
/// 或日历无法推算日期。
public enum VideoPublicationRangeError: Error, Sendable, Equatable {
    case startAfterEnd
    case futureDate
    case invalidCalendarRange
}

/// 将日期选择集中转换为 API 使用的整日 Unix 秒闭区间。
public enum VideoPublicationRangeResolver {
    public static func resolve(
        filter: VideoPublicationFilter,
        customStart: Date,
        customEnd: Date,
        now: Date,
        calendar: Calendar
    ) throws -> VideoPublicationTimeRange? {
        guard filter != .all else { return nil }

        let today = calendar.startOfDay(for: now)
        let endDay = filter == .custom ? calendar.startOfDay(for: customEnd) : today
        guard endDay <= today else {
            throw VideoPublicationRangeError.futureDate
        }

        let beginDay: Date
        switch filter {
        case .all:
            return nil
        case .today:
            beginDay = today
        case .lastSevenDays:
            guard let value = calendar.date(byAdding: .day, value: -6, to: today) else {
                throw VideoPublicationRangeError.invalidCalendarRange
            }
            beginDay = value
        case .last180Days:
            guard let value = calendar.date(byAdding: .day, value: -179, to: today) else {
                throw VideoPublicationRangeError.invalidCalendarRange
            }
            beginDay = value
        case .custom:
            beginDay = calendar.startOfDay(for: customStart)
        }

        guard beginDay <= endDay else {
            throw VideoPublicationRangeError.startAfterEnd
        }
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            throw VideoPublicationRangeError.invalidCalendarRange
        }
        return VideoPublicationTimeRange(
            beginTimestamp: Int64(beginDay.timeIntervalSince1970),
            endTimestamp: Int64(endExclusive.timeIntervalSince1970) - 1
        )
    }
}

/// 一个搜索工作集的完整 identity。
///
/// `query` 在初始化时即完成空白规范化。
public struct VideoSearchCriteria: Sendable, Hashable {
    /// 搜索每页条数；`isValid` 要求请求使用这一固定值，调整会改变每次加载更多的条数，
    /// 以及达到列表条目上限所需的页数。
    public static let pageSize = 20

    public let query: String
    public let order: VideoSearchOrder
    public let duration: VideoDurationFilter
    public let publicationRange: VideoPublicationTimeRange?
    public let pageSize: Int

    public init(
        query: String,
        order: VideoSearchOrder = .relevance,
        duration: VideoDurationFilter = .all,
        publicationRange: VideoPublicationTimeRange? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.order = order
        self.duration = duration
        self.publicationRange = publicationRange
        self.pageSize = Self.pageSize
    }

    /// 查询词长度上限（按字符计）；超过的输入不发搜索或联想请求，联想会发送未提交的输入，见
    /// SECURITY-MODEL §3。
    public static let maximumQueryLength = 100

    /// 查询非空且不超过上限、使用固定页大小、发布时间范围不为负且不倒置。
    public var isValid: Bool {
        guard !query.isEmpty,
            query.count <= Self.maximumQueryLength,
            pageSize == Self.pageSize
        else { return false }
        guard let range = publicationRange else { return true }
        return range.beginTimestamp >= 0 && range.beginTimestamp <= range.endTimestamp
    }
}

extension VideoSearchCriteria {
    /// 按搜索规则规范化一组候选词：丢弃不能搜索的词与规范化后重复的词，保持原顺序，最多 `limit` 个。
    public static func uniqueQueries(from candidates: [String], limit: Int) -> [String] {
        var queries: [String] = []
        for candidate in candidates {
            guard queries.count < limit else { break }
            let criteria = VideoSearchCriteria(query: candidate)
            guard criteria.isValid, !queries.contains(criteria.query) else { continue }
            queries.append(criteria.query)
        }
        return queries
    }
}

/// 单次网络请求 identity；分页只改变 `page`，其余条件完整保留。
public struct VideoSearchRequest: Sendable, Hashable {
    public let criteria: VideoSearchCriteria
    public let page: Int

    public init(criteria: VideoSearchCriteria, page: Int) {
        self.criteria = criteria
        self.page = page
    }
}
