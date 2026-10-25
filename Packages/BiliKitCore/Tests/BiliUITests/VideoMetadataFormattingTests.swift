import Foundation
import Testing

@testable import BiliUI

/// 紧凑计数按 locale 的语言给单位、最多一位小数且向下截断；地区只决定小数点。
struct VideoMetadataFormattingTests {
    @Test(arguments: [
        (
            "zh-Hans",
            ["0", "999", "1000", "9999", "1万", "1.2万", "9.9万", "9999.9万", "1亿", "1.2亿", "12.3亿"]
        ),
        (
            "zh-Hant",
            ["0", "999", "1000", "9999", "1萬", "1.2萬", "9.9萬", "9999.9萬", "1億", "1.2億", "12.3億"]
        ),
        (
            "ja",
            ["0", "999", "1000", "9999", "1万", "1.2万", "9.9万", "9999.9万", "1億", "1.2億", "12.3億"]
        ),
        (
            "en",
            ["0", "999", "1K", "9.9K", "10K", "12.3K", "99.9K", "99.9M", "100M", "123.4M", "1.2B"]
        ),
        (
            "zh-Hans_FR",
            ["0", "999", "1000", "9999", "1万", "1,2万", "9,9万", "9999,9万", "1亿", "1,2亿", "12,3亿"]
        )
    ])
    func compactCountsTruncateToOneFractionDigit(localeIdentifier: String, expected: [String]) {
        let counts: [Int64] = [
            -1, 999, 1000, 9999, 10_000, 12_345, 99_999, 99_999_999, 100_000_000, 123_456_789,
            1_234_567_890
        ]
        let locale = Locale(identifier: localeIdentifier)

        #expect(counts.map { VideoMetadataFormatting.compactCount($0, locale: locale) } == expected)
    }

    /// 东京时间 2026-07-24 10:30 为 now；同日按小时、前一日为“昨天”、同年省略年份。
    @Test(arguments: [
        (year: 2026, month: 7, day: 24, hour: 10, minute: 0, expected: localized("\(1)小时前")),
        (year: 2026, month: 7, day: 24, hour: 8, minute: 30, expected: localized("\(2)小时前")),
        (year: 2026, month: 7, day: 24, hour: 0, minute: 5, expected: localized("\(10)小时前")),
        (year: 2026, month: 7, day: 23, hour: 23, minute: 59, expected: localized("昨天")),
        (year: 2026, month: 7, day: 1, hour: 12, minute: 0, expected: localized("\(7)月\(1)日")),
        (year: 2025, month: 12, day: 31, hour: 12, minute: 0, expected: "2025年12月31日")
    ])
    func publicationDateUsesCalendarDayBoundaries(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        expected: String
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 10, minute: 30))
        )
        let published = try #require(
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            )
        )

        #expect(
            VideoMetadataFormatting.publishedDate(
                published,
                relativeTo: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == expected
        )
    }
}

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: BiliUIStrings.bundle)
}
