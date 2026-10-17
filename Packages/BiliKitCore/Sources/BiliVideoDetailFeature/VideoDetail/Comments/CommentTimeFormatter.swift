import BiliUI
import Foundation

public enum CommentTimeFormatter {
    public static func string(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
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
        let sameYear =
            calendar.component(.year, from: date)
            == calendar.component(.year, from: referenceDate)
        if sameYear {
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            return VideoDetailFeatureStrings.localized("\(month)月\(day)日", locale: locale)
        }
        return DateDisplayFormatting.formatted(
            date,
            date: .long,
            time: .omitted,
            calendar: calendar,
            locale: locale
        )
    }
}
