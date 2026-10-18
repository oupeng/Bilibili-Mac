import BiliUI
import Foundation

/// 资料库卡片（观看历史、稍后再看）共用的文字规则：观看进度（看完显示“已看完”）与时间点（今天、昨天或
/// 月日，加时刻）。观看历史的观看时间与稍后再看的加入时间都经 `timestamp`，同一格式只在这里。
enum LibraryCardFormatting {
    static func progress(
        progressSeconds: Int,
        durationSeconds: Int,
        locale: Locale = .current
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
        locale: Locale = .current
    ) -> String {
        let time = DateDisplayFormatting.formatted(
            date,
            date: .omitted,
            time: .shortened,
            calendar: calendar,
            locale: locale
        )
        switch DateDisplayFormatting.dayRelation(of: date, relativeTo: now, calendar: calendar) {
        case .today:
            return LibraryFeatureStrings.localized("今天 \(time)", locale: locale)
        case .yesterday:
            return LibraryFeatureStrings.localized("昨天 \(time)", locale: locale)
        case .earlier:
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            return LibraryFeatureStrings.localized(
                "\(month)月\(day)日 \(time)",
                locale: locale
            )
        }
    }
}
