import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature
@testable import BiliUI

struct WatchHistoryCardFormattingTests {
    /// 固定的观看时刻 2023-11-14 22:13:20 UTC，与执行日期相隔多年。
    ///
    /// 比较两份展示的读屏文字时，两份各自按构造时的 now 格式化时间；这个时刻在任何 now 下都落在「更早、跨年」
    /// 分支，两份相同。用 `.now` 时两次构造若跨过本地午夜，「今天」与「昨天」不同，比较就会失败。
    private static let fixedViewedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// 日期前按观看设备显示图标，读屏在最后读出设备；设备未知时都不显示。
    @Test(arguments: [
        (WatchHistoryDevice?.some(.phone), "smartphone" as String?),
        (.pad, "ipad"),
        (.web, "desktopcomputer"),
        (.tv, "tv"),
        (nil, nil)
    ])
    func deviceShowsAnIconBeforeTheDateAndInTheAccessibilityLabel(
        device: WatchHistoryDevice?,
        symbolName: String?
    ) {
        let locale = Locale(identifier: "zh-Hans")
        let item = WatchHistoryItem(
            bvid: "BV1HistoryDevice",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: Self.fixedViewedAt,
            device: device
        )
        let presentation = WatchHistoryCardPresentation(item: item, locale: locale)
        let withoutDevice = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: item.bvid,
                title: item.title,
                coverURL: nil,
                owner: item.owner,
                progressSeconds: item.progressSeconds,
                durationSeconds: item.durationSeconds,
                viewedAt: item.viewedAt
            ),
            locale: locale
        )

        #expect(presentation.footerTrailingSymbolName == symbolName)
        if let device {
            let spoken = WatchHistoryCardFormatting.deviceLabel(device, locale: locale)
            #expect(presentation.accessibilityLabel.hasSuffix(spoken))
        } else {
            #expect(presentation.accessibilityLabel == withoutDevice.accessibilityLabel)
        }
    }

    @Test
    func loadedAndLoadingMoreProjectToTheSameStableSurface() {
        let item = WatchHistoryItem(
            bvid: "BV1HistorySurface",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: .now
        )
        let continuation = WatchHistoryContinuation(rawValue: "opaque")
        let loaded = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: nil
            ),
            requiresManualLoadMore: false
        )
        let loadingMore = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loadingMore(items: [item], continuation: continuation),
            requiresManualLoadMore: false
        )
        let retry = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: .transportFailure
            ),
            requiresManualLoadMore: false
        )

        #expect(loaded?.items == loadingMore?.items)
        #expect(loaded?.canLoadMore == true)
        #expect(loadingMore?.canLoadMore == true)
        #expect(loaded?.isLoadingMore == false)
        #expect(loadingMore?.isLoadingMore == true)
        #expect(retry?.loadMoreError == .transportFailure)
    }

    @Test
    func historyImagesUseBoundedCDNVariantsWithoutRewritingUnknownOrigins() throws {
        let trusted = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: "BV1HistoryImages",
                title: "历史图片",
                coverURL: URL(string: "https://i0.hdslb.com/cover.jpg"),
                owner: VideoOwner(
                    id: 7,
                    name: "作者",
                    avatarURL: URL(string: "https://i1.hdslb.com/avatar.jpg")
                ),
                progressSeconds: 1,
                durationSeconds: 10,
                viewedAt: .now
            )
        )
        let unknownURL = try #require(URL(string: "https://images.example/avatar.jpg"))
        let unknown = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: "BV1HistoryUnknown",
                title: "未知图片源",
                coverURL: unknownURL,
                owner: VideoOwner(id: 8, name: "作者", avatarURL: unknownURL),
                progressSeconds: 1,
                durationSeconds: 10,
                viewedAt: .now
            )
        )

        #expect(trusted.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true)
        #expect(trusted.avatarURL?.absoluteString.hasSuffix("@96w_96h_1c.webp") == true)
        #expect(unknown.coverURL == unknownURL)
        #expect(unknown.avatarURL == unknownURL)
    }

    @Test(arguments: [
        (progress: 65, duration: 600, expected: "1:05/10:00"),
        (progress: 3_661, duration: 7_322, expected: "1:01:01/2:02:02"),
        (progress: 0, duration: 0, expected: "0:00/0:00"),
        (progress: 600, duration: 600, expected: completedText)
    ])
    func progressShowsElapsedDurationOrCompletedState(
        progress: Int,
        duration: Int,
        expected: String
    ) {
        #expect(
            LibraryCardFormatting.progress(
                progressSeconds: progress,
                durationSeconds: duration
            ) == expected
        )
    }

    /// 东京时间 2026-07-24 13:00 为 now；日界按日历时区而不是 UTC 判定。
    @Test(arguments: [
        (day: 24, hour: 9, minute: 5, expected: localized("今天 \("9:05")")),
        // 东京 7/24 08:00 在 UTC 仍是 7/23，必须按日历时区归入今天。
        (day: 24, hour: 8, minute: 0, expected: localized("今天 \("8:00")")),
        (day: 23, hour: 23, minute: 59, expected: localized("昨天 \("23:59")")),
        (day: 23, hour: 22, minute: 7, expected: localized("昨天 \("22:07")")),
        (day: 20, hour: 8, minute: 3, expected: localized("\(monthDay(7, 20)) \("8:03")"))
    ])
    func viewedAtUsesCalendarDayBoundaries(
        day: Int,
        hour: Int,
        minute: Int,
        expected: String
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 13))
        )
        let viewedAt = try #require(
            calendar.date(
                from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute)
            )
        )

        #expect(
            LibraryCardFormatting.timestamp(
                viewedAt,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == expected
        )
    }
}

/// 资料库卡片的时间跨年时显示年份：12 月 31 日之后的 1 月 1 日，前一年的日期带年份，同年的只有月日；时区固定为
/// 东京，年界与日界都按日历时区判定。
struct LibraryTimestampYearTests {
    @Test
    func earlierDatesFromAnotherYearShowTheYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let locale = Locale(identifier: "zh-Hans")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
            try #require(
                calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
            )
        }
        func timestamp(_ value: Date, now: Date) -> String {
            LibraryCardFormatting.timestamp(value, now: now, calendar: calendar, locale: locale)
        }
        let newYear = try date(2026, 1, 1, 10)

        // 12 月 31 日是昨天，不带年份；12 月 30 日已是上一年的更早日期，带年份。
        #expect(timestamp(try date(2025, 12, 31, 23), now: newYear) == localized("昨天 \("23:00")"))
        let lastYear = timestamp(try date(2025, 12, 30, 8), now: newYear)
        #expect(lastYear.contains("2025"))
        #expect(lastYear == localized("\("2025年12月30日") \("8:00")"))
        // 同一年里的更早日期只有月日。
        let sameYear = timestamp(try date(2026, 1, 1, 9), now: try date(2026, 12, 31, 20))
        #expect(sameYear == localized("\(monthDay(1, 1)) \("9:00")"))
        #expect(!sameYear.contains("2026"))
    }
}

private let completedText = localized("已看完")

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: LibraryFeatureStrings.bundle)
}

/// 同年的「M月D日」只在 BiliUI 的字符串目录里（`DateDisplayFormatting.calendarDate`）。
private func monthDay(_ month: Int, _ day: Int) -> String {
    String(localized: "\(month)月\(day)日", bundle: BiliUIStrings.bundle)
}
