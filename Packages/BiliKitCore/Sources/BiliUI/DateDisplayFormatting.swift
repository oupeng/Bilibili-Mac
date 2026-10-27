import Foundation

/// 界面日期文字的唯一规则：相对时间（发布与评论时间）、日历日期、“今天／昨天”加时刻，以及按日历时区套用系统样式。
///
/// 只拥有分段与格式；单位与词序全部交给系统格式（`RelativeDateTimeFormatter`、`DateFormatter` 的相对日期与
/// `Date.FormatStyle` 模板），字符串目录只存没有系统对应的「刚刚」。日界与年份都按 `calendar` 的时区判定。
package enum DateDisplayFormatting {
    /// 日期相对 `now` 落在哪个日历日。
    package enum DayRelation: Equatable {
        case today
        case yesterday
        case earlier
    }

    /// 日界按 `calendar` 的时区而不是 UTC：东京早上八点在 UTC 仍是前一天，必须归入今天。
    package static func dayRelation(
        of date: Date,
        relativeTo now: Date,
        calendar: Calendar
    ) -> DayRelation {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return .yesterday
        }
        return .earlier
    }

    /// 发布时间与评论时间共用的相对时间：1 分钟内「刚刚」，1 小时内「N 分钟前」，同一日历日「N 小时前」，前一个日历日
    /// 「昨天」（`yesterdayIncludesTime` 时带时刻），更早为日历日期。
    ///
    /// 分钟与小时按经过的秒数向下取整；晚于 `now` 的日期按「刚刚」。跨零点不足一小时仍是「N 分钟前」，超过一小时就按
    /// 日历日算作昨天。
    package static func relativeDate(
        _ date: Date,
        relativeTo now: Date,
        yesterdayIncludesTime: Bool,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 {
            return BiliUIStrings.localized("刚刚", locale: locale)
        }
        if elapsed < 3_600 {
            return elapsedText(
                DateComponents(minute: -Int(elapsed / 60)),
                calendar: calendar,
                locale: locale
            )
        }
        switch dayRelation(of: date, relativeTo: now, calendar: calendar) {
        case .today:
            return elapsedText(
                DateComponents(hour: -Int(elapsed / 3_600)),
                calendar: calendar,
                locale: locale
            )
        case .yesterday:
            return relativeDay(
                date,
                includesTime: yesterdayIncludesTime,
                calendar: calendar,
                locale: locale
            )
        case .earlier:
            return calendarDate(date, relativeTo: now, calendar: calendar, locale: locale)
        }
    }

    /// 「今天」「昨天」，`includesTime` 时加时刻（「昨天 12:30」「Yesterday at 12:30 PM」），词与词序取系统相对日期。
    ///
    /// 只给已由 `dayRelation` 判定为今天或昨天的日期调用：`DateFormatter` 的相对日期按设备当前的日期判断，没有参照日
    /// 参数，`now` 管不到它；生产里 `now` 就是当前时间，两者一致。
    package static func relativeDay(
        _ date: Date,
        includesTime: Bool,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = includesTime ? .short : .none
        return formatter.string(from: date)
    }

    /// 日历日期的唯一写法：与 `now` 同一日历年时只有月日，跨年加年份，`includesTime` 时加时分。
    ///
    /// 月日顺序与写法取系统模板，随 locale 的语言与地区（zh「3月7日」、en「Mar 7」、en_GB「7 Mar」）。
    package static func calendarDate(
        _ date: Date,
        relativeTo now: Date,
        includesTime: Bool = false,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        .month(.abbreviated)
        .day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        if includesTime {
            style = style.hour().minute()
        }
        return date.formatted(style)
    }

    /// 系统日期样式，时区取自 `calendar`，与 `dayRelation` 的日界一致。
    package static func formatted(
        _ dateValue: Date,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle)
            .locale(locale)
        style.timeZone = calendar.timeZone
        return dateValue.formatted(style)
    }

    /// 「5分钟前」「3 hr. ago」：单位、复数与词序取系统的简短数字式相对时间。
    private static func elapsedText(
        _ components: DateComponents,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }
}
