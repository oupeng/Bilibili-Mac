import Foundation

/// 界面日期文字共用的底层规则：按日历时区判定“今天／昨天”，并按日历时区套用系统日期样式。
///
/// 提供日界判定、系统样式与“日历日期”的唯一写法；“N小时前”“今天 12:30”等带产品语义的组合由各自的格式化类型
/// 决定。
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

    /// 日历日期的唯一写法：与 `now` 在同一日历年时为「M月D日」（BiliUI 字符串目录），否则为带年份的系统 `.long`
    /// 日期；年份与时区都按 `calendar` 判定。
    ///
    /// 发布日期、评论时间与资料库卡片的时间共用，跨年时都显示年份。
    package static func calendarDate(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let sameYear =
            calendar.component(.year, from: date) == calendar.component(.year, from: now)
        guard sameYear else {
            return formatted(date, date: .long, time: .omitted, calendar: calendar, locale: locale)
        }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return BiliUIStrings.localized("\(month)月\(day)日", locale: locale)
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
