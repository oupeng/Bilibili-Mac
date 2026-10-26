import Foundation
import Testing

@testable import BiliUI

/// 发布时间与评论时间共用一份相对时间规则：刚刚 → N 分钟前 → 当天 N 小时前 → 昨天（评论带时刻）→ 日历日期（跨年带
/// 年份）；日界与年界按日历时区（固定东京），单位与词序随传入的 locale，不随进程语言。
struct DateDisplayFormattingTests {
    @Test(arguments: [
        (secondsAgo: -30, expected: justNow),
        (secondsAgo: 0, expected: justNow),
        (secondsAgo: 59, expected: justNow),
        (secondsAgo: 60, expected: "1分钟前"),
        (secondsAgo: 3_599, expected: "59分钟前"),
        (secondsAgo: 3_600, expected: "1小时前"),
        (secondsAgo: 43_199, expected: "11小时前"),
        // 前天与更早不再按天计数，直接给日期。
        (secondsAgo: 2 * 86_400, expected: "8月9日")
    ])
    func elapsedSegmentsShareOneRule(secondsAgo: Int, expected: String) throws {
        let now = try tokyoDate(2026, 8, 11, 12)
        let date = now.addingTimeInterval(-Double(secondsAgo))

        #expect(published(date, now: now) == expected)
        #expect(comment(date, now: now) == expected)
    }

    @Test(arguments: [
        // 跨零点不足一小时仍按分钟。
        (date: (2026, 8, 10, 23, 50), now: (2026, 8, 11, 0, 20), expected: "30分钟前"),
        (date: (2026, 7, 1, 12, 0), now: (2026, 8, 11, 12, 0), expected: "7月1日"),
        (date: (2025, 12, 31, 23, 0), now: (2026, 1, 2, 10, 0), expected: "2025年12月31日")
    ])
    func calendarSegmentsUseCalendarTimeZone(
        date: (Int, Int, Int, Int, Int),
        now: (Int, Int, Int, Int, Int),
        expected: String
    ) throws {
        let date = try tokyoDate(date.0, date.1, date.2, date.3, date.4)
        let now = try tokyoDate(now.0, now.1, now.2, now.3, now.4)

        #expect(published(date, now: now) == expected)
        #expect(comment(date, now: now) == expected)
    }

    @Test(arguments: [
        (identifier: "zh-Hant", minutes: "5分鐘前", monthDay: "7月1日"),
        (identifier: "ja", minutes: "5 分前", monthDay: "7月1日"),
        (identifier: "en", minutes: "5 min. ago", monthDay: "Jul 1"),
        (identifier: "en_GB", minutes: "5 min ago", monthDay: "1 Jul")
    ])
    func unitsFollowTheLocale(identifier: String, minutes: String, monthDay: String) throws {
        let now = try tokyoDate(2026, 8, 11, 12)
        let locale = Locale(identifier: identifier)

        #expect(published(now.addingTimeInterval(-300), now: now, locale: locale) == minutes)
        #expect(published(try tokyoDate(2026, 7, 1, 12), now: now, locale: locale) == monthDay)
    }

    @Test
    func yesterdayFollowsCalendarDayAndCommentsAddTime() throws {
        // 「昨天」「今天」的写法来自 `DateFormatter` 的相对日期，它只认设备当前的日期，所以这一段以真实的今天为基准，
        // 时刻仍固定；跨零点超过一小时按日历日算作昨天。
        let today = tokyoCalendar.startOfDay(for: .now)
        let now = try #require(tokyoCalendar.date(byAdding: .hour, value: 1, to: today))
        let lateYesterday = try #require(tokyoCalendar.date(byAdding: .minute, value: -90, to: now))
        let yesterdayMorning = try #require(
            tokyoCalendar.date(byAdding: DateComponents(day: -1, hour: 9, minute: 5), to: today)
        )

        #expect(published(lateYesterday, now: now) == "昨天")
        #expect(comment(lateYesterday, now: now) == "昨天 23:30")
        #expect(comment(yesterdayMorning, now: now) == "昨天 09:05")
        #expect(
            DateDisplayFormatting.relativeDay(
                try #require(tokyoCalendar.date(byAdding: .minute, value: 30, to: today)),
                includesTime: true,
                calendar: tokyoCalendar,
                locale: zhHans
            ) == "今天 00:30"
        )
    }

    @Test
    func dayRelationUsesCalendarTimeZone() throws {
        // 东京 8:00 在 UTC 仍是前一天，必须按日历时区归入今天；跨年的 12 月 31 日仍是昨天。
        #expect(
            DateDisplayFormatting.dayRelation(
                of: try tokyoDate(2026, 7, 24, 8),
                relativeTo: try tokyoDate(2026, 7, 24, 13),
                calendar: tokyoCalendar
            ) == .today
        )
        #expect(
            DateDisplayFormatting.dayRelation(
                of: try tokyoDate(2025, 12, 31, 23),
                relativeTo: try tokyoDate(2026, 1, 1, 10),
                calendar: tokyoCalendar
            ) == .yesterday
        )
        #expect(
            DateDisplayFormatting.dayRelation(
                of: try tokyoDate(2025, 12, 30, 23),
                relativeTo: try tokyoDate(2026, 1, 1, 10),
                calendar: tokyoCalendar
            ) == .earlier
        )
    }

    private func published(_ date: Date, now: Date, locale: Locale = zhHans) -> String {
        VideoMetadataFormatting.publishedDate(
            date,
            relativeTo: now,
            calendar: tokyoCalendar,
            locale: locale
        )
    }

    private func comment(_ date: Date, now: Date) -> String {
        VideoMetadataFormatting.commentDate(
            date,
            relativeTo: now,
            calendar: tokyoCalendar,
            locale: zhHans
        )
    }

    private func tokyoDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) throws -> Date {
        try #require(
            tokyoCalendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            )
        )
    }
}

private let zhHans = Locale(identifier: "zh-Hans")

private let tokyoCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
    return calendar
}()

/// 「刚刚」是唯一留在字符串目录里的相对时间文字；目录按进程语言查表，期望值同样从目录取。
private let justNow = String(localized: "刚刚", bundle: BiliUIStrings.bundle)
