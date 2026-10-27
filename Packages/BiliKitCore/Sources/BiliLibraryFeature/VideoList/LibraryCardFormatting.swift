import BiliUI
import Foundation

/// 资料库卡片（观看历史、稍后再看、收藏夹）共用的文字规则：观看进度（看完显示“已看完”）与时间点（今天、昨天，更早为
/// 日历日期：同年月日、跨年带年份；都加时刻，写法取系统的相对日期与日期模板）。
///
/// 观看历史的观看时间、稍后再看的加入时间与收藏夹的收藏时间都经 `timestamp`，同一格式只在这里。
enum LibraryCardFormatting {
    static func progress(
        progressSeconds: Int,
        durationSeconds: Int,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return finished(locale: locale)
        }
        return "\(VideoDurationFormatting.string(seconds: progress))/"
            + VideoDurationFormatting.string(seconds: duration)
    }

    static func finished(locale: Locale = .current) -> String {
        LibraryFeatureStrings.localized("已看完", locale: locale)
    }

    static func timestamp(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        switch DateDisplayFormatting.dayRelation(of: date, relativeTo: now, calendar: calendar) {
        case .today, .yesterday:
            return DateDisplayFormatting.relativeDay(
                date,
                includesTime: true,
                calendar: calendar,
                locale: locale
            )
        case .earlier:
            return DateDisplayFormatting.calendarDate(
                date,
                relativeTo: now,
                includesTime: true,
                calendar: calendar,
                locale: locale
            )
        }
    }
}
