import Foundation

/// 界面日期文字共用的底层规则：按日历时区判定“今天／昨天”，并按日历时区套用系统日期样式。
///
/// 只提供日界判定与系统样式；“N小时前”“今天 12:30”等带产品语义的组合由各自的格式化类型决定。
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
}
