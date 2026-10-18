import BiliApplication
import BiliModels
import Foundation
import Testing

/// 稍后再看用例不为非正页码或不合法的条件发请求，并拒收页码与请求不符或下一页不紧接着的响应。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterUseCaseTests {
    @Test
    func returnsTheRequestedPage() async throws {
        let repository = WatchLaterRepositoryStub(page: page(2, next: 3))
        let request = WatchLaterRequest(criteria: WatchLaterCriteria(keyword: "猫"), page: 2)

        let result = try await WatchLaterUseCase(repository: repository).load(request)

        #expect(result.nextPageNumber == 3)
        #expect(await repository.requests == [request])
    }

    @Test(arguments: [
        WatchLaterRequest(page: 0),
        WatchLaterRequest(page: -1),
        WatchLaterRequest(criteria: WatchLaterCriteria(keyword: String(repeating: "长", count: 101)))
    ])
    func invalidRequestSendsNothing(request: WatchLaterRequest) async {
        let repository = WatchLaterRepositoryStub(page: page(1, next: nil))

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await WatchLaterUseCase(repository: repository).load(request)
        }
        #expect(await repository.requests.isEmpty)
    }

    @Test(arguments: [page(3, next: nil), page(2, next: 2), page(2, next: 5)])
    func misplacedPageIsAnInvalidResponse(response: WatchLaterPage) async {
        let repository = WatchLaterRepositoryStub(page: response)

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await WatchLaterUseCase(repository: repository).load(WatchLaterRequest(page: 2))
        }
    }
}

/// 加入时间按本地日历解析：今天与近一周止于明天 0 点（午夜也不为空，之后加入的也在区间内），昨天是昨天整日，
/// 自定义含结束日当天；日界按日历时区，跨夏令时按日历日计算；早于 1970 年的区间被拒绝。
struct WatchLaterAddedTimeRangeTests {
    @Test
    func relativeRangesEndAtTomorrowOrAtTodaysStart() throws {
        let calendar = try calendar("Asia/Tokyo")
        let now = try date(calendar, 2026, 7, 24, hour: 13)

        let today = try resolve(.today, now: now, calendar: calendar)
        let yesterday = try resolve(.yesterday, now: now, calendar: calendar)
        let lastWeek = try resolve(.lastSevenDays, now: now, calendar: calendar)

        // 东京 7/24 0 点在 UTC 仍是 7/23，必须按日历时区取日界。
        let tomorrow = try date(calendar, 2026, 7, 25)
        #expect(today == range(try date(calendar, 2026, 7, 24), tomorrow))
        #expect(
            yesterday == range(try date(calendar, 2026, 7, 23), try date(calendar, 2026, 7, 24))
        )
        #expect(lastWeek == range(now.addingTimeInterval(-7 * 86_400), tomorrow))
        // 区间结束不是解析时刻：解析之后才加入的视频，刷新时也落在区间内。
        let laterToday = now.addingTimeInterval(3_600)
        #expect(today.map { Int64(laterToday.timeIntervalSince1970) < $0.endTimestamp } == true)
        #expect(try resolve(.all, now: now, calendar: calendar) == nil)
    }

    /// 自定义范围从开始日 0 点到结束日次日 0 点；跨夏令时开始的那一天只有 23 小时。
    @Test
    func customRangeIncludesTheEndDayAcrossDaylightSaving() throws {
        let calendar = try calendar("America/New_York")
        let start = try date(calendar, 2026, 3, 7, hour: 15)
        let end = try date(calendar, 2026, 3, 8, hour: 9)

        let resolved = try #require(
            try WatchLaterAddedTimeRangeResolver.resolve(
                filter: .custom,
                customStart: start,
                customEnd: end,
                now: try date(calendar, 2026, 3, 20),
                calendar: calendar
            )
        )

        #expect(resolved == range(try date(calendar, 2026, 3, 7), try date(calendar, 2026, 3, 9)))
        #expect(resolved.endTimestamp - resolved.startTimestamp == 47 * 3_600)
    }

    /// 午夜整点解析“今天”也不是空区间。
    @Test
    func todayIsNotEmptyAtMidnight() throws {
        let calendar = try calendar("Asia/Shanghai")
        let midnight = try date(calendar, 2026, 7, 24)

        let today = try #require(try resolve(.today, now: midnight, calendar: calendar))

        #expect(today.startTimestamp < today.endTimestamp)
        #expect(today.endTimestamp - today.startTimestamp == 86_400)
    }

    /// 早于 1970 年的自定义区间与搜索的发布日期一样被拒绝（同一校验规则）。
    @Test
    func rangeBeforeTheEpochFails() throws {
        let calendar = try calendar("UTC")
        let early = try date(calendar, 1969, 12, 30)

        #expect(throws: DateRangeFilterError.beforeEpoch) {
            try WatchLaterAddedTimeRangeResolver.resolve(
                filter: .custom,
                customStart: early,
                customEnd: early,
                now: try date(calendar, 2026, 7, 24),
                calendar: calendar
            )
        }
        #expect(throws: DateRangeFilterError.beforeEpoch) {
            try VideoPublicationRangeResolver.resolve(
                filter: .custom,
                customStart: early,
                customEnd: early,
                now: try date(calendar, 2026, 7, 24),
                calendar: calendar
            )
        }
    }

    @Test
    func customRangeStartingAfterItsEndFails() throws {
        let calendar = try calendar("Asia/Shanghai")

        #expect(throws: DateRangeFilterError.startAfterEnd) {
            try WatchLaterAddedTimeRangeResolver.resolve(
                filter: .custom,
                customStart: try date(calendar, 2026, 7, 25),
                customEnd: try date(calendar, 2026, 7, 24),
                now: try date(calendar, 2026, 7, 26),
                calendar: calendar
            )
        }
    }

    private func resolve(
        _ filter: WatchLaterAddedTimeFilter,
        now: Date,
        calendar: Calendar
    ) throws -> WatchLaterAddedTimeRange? {
        try WatchLaterAddedTimeRangeResolver.resolve(
            filter: filter,
            customStart: now,
            customEnd: now,
            now: now,
            calendar: calendar
        )
    }

    private func range(_ start: Date, _ end: Date) -> WatchLaterAddedTimeRange {
        WatchLaterAddedTimeRange(
            startTimestamp: Int64(start.timeIntervalSince1970),
            endTimestamp: Int64(end.timeIntervalSince1970)
        )
    }

    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0
    ) throws -> Date {
        try #require(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
        )
    }
}

private func page(_ number: Int, next: Int?) -> WatchLaterPage {
    WatchLaterPage(items: [], pageNumber: number, nextPageNumber: next, totalCount: 0)
}

/// 本 target 唯一的稍后再看仓库替身：总是返回同一页并记录请求。
private actor WatchLaterRepositoryStub: WatchLaterRepository {
    private let page: WatchLaterPage
    private(set) var requests: [WatchLaterRequest] = []

    init(page: WatchLaterPage) {
        self.page = page
    }

    func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage {
        requests.append(request)
        return page
    }
}
