import BiliUI
import Foundation

/// 评论时间的相对写法：一天内按刚刚／分钟／小时，昨天带时刻，三天内按天，更早按日期（跨年带年份）。
public enum CommentTimeFormatter {
    public static func string(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(date))
        if elapsed < 60 {
            return VideoDetailFeatureStrings.localized("刚刚", locale: locale)
        }
        if elapsed < 3_600 {
            let minutes = Int(elapsed / 60)
            return VideoDetailFeatureStrings.localized("\(minutes)分钟前", locale: locale)
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3_600)
            return VideoDetailFeatureStrings.localized("\(hours)小时前", locale: locale)
        }

        let referenceDay = calendar.startOfDay(for: referenceDate)
        let commentDay = calendar.startOfDay(for: date)
        let dayDifference =
            calendar.dateComponents(
                [.day],
                from: commentDay,
                to: referenceDay
            ).day ?? 0
        if dayDifference == 1 {
            let time = DateDisplayFormatting.formatted(
                date,
                date: .omitted,
                time: .shortened,
                calendar: calendar,
                locale: locale
            )
            return VideoDetailFeatureStrings.localized("昨天\(time)", locale: locale)
        }
        if dayDifference == 2 || dayDifference == 3 {
            return VideoDetailFeatureStrings.localized("\(dayDifference)天前", locale: locale)
        }
        return DateDisplayFormatting.calendarDate(
            date,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )
    }
}
