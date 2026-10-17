import Foundation

/// 视频卡片、投稿行、相关推荐、播放页详情与评论共用的计数和发布日期文字。
///
/// 只拥有格式与对应文案；用到哪些字段、如何拼进卡片由各 Feature 的 presentation 决定。
package enum VideoMetadataFormatting {
    /// “12万播放”：播放数与单位文字的本地化组合。
    package static func viewCountText(_ count: Int64, locale: Locale = .current) -> String {
        viewCountText(compactText: compactCount(count, locale: locale), locale: locale)
    }

    /// 已经算好紧凑计数（如卡片封面上的“12万”）时直接组合，不再重复格式化。
    package static func viewCountText(compactText: String, locale: Locale = .current) -> String {
        BiliUIStrings.localized("\(compactText)播放", locale: locale)
    }

    /// “3000弹幕”：弹幕数与单位文字的本地化组合。
    package static func danmakuCountText(_ count: Int64, locale: Locale = .current) -> String {
        danmakuCountText(compactText: compactCount(count, locale: locale), locale: locale)
    }

    package static func danmakuCountText(compactText: String, locale: Locale = .current) -> String {
        BiliUIStrings.localized("\(compactText)弹幕", locale: locale)
    }

    package static func compactCount(_ count: Int64, locale: Locale = .current) -> String {
        let normalizedCount = max(0, count)
        if locale.language.languageCode?.identifier == "en" {
            if normalizedCount >= 1_000_000_000 {
                return compactUnit(normalizedCount, divisor: 1_000_000_000, suffix: "B")
            }
            if normalizedCount >= 1_000_000 {
                return compactUnit(normalizedCount, divisor: 1_000_000, suffix: "M")
            }
            if normalizedCount >= 1_000 {
                return compactUnit(normalizedCount, divisor: 1_000, suffix: "K")
            }
            return normalizedCount.formatted(.number.locale(locale))
        }
        if normalizedCount >= 100_000_000 {
            return compactUnit(
                normalizedCount,
                divisor: 100_000_000,
                suffix: BiliUIStrings.localized("亿", locale: locale)
            )
        }
        if normalizedCount >= 10_000 {
            return compactUnit(
                normalizedCount,
                divisor: 10_000,
                suffix: BiliUIStrings.localized("万", locale: locale)
            )
        }
        return String(normalizedCount)
    }

    /// 发布日期：当天“N小时前”、前一天“昨天”、同年“M月D日”，更早给完整日期。
    package static func publishedDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch DateDisplayFormatting.dayRelation(of: date, relativeTo: now, calendar: calendar) {
        case .today:
            let elapsedHours = calendar.dateComponents([.hour], from: date, to: now).hour ?? 0
            let hours = max(1, elapsedHours)
            return BiliUIStrings.localized("\(hours)小时前", locale: locale)
        case .yesterday:
            return BiliUIStrings.localized("昨天", locale: locale)
        case .earlier:
            break
        }

        let sameYear =
            calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        if sameYear {
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            return BiliUIStrings.localized("\(month)月\(day)日", locale: locale)
        }
        return DateDisplayFormatting.formatted(
            date,
            date: .long,
            time: .omitted,
            calendar: calendar,
            locale: locale
        )
    }

    /// 播放页详情里的完整发布时间（日期与时分秒）。
    package static func fullPublishedDate(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        DateDisplayFormatting.formatted(
            date,
            date: .long,
            time: .standard,
            calendar: calendar,
            locale: locale
        )
    }

    private static func compactUnit(
        _ count: Int64,
        divisor: Int64,
        suffix: String
    ) -> String {
        let whole = count / divisor
        let fraction = count % divisor * 10 / divisor
        if fraction == 0 {
            return "\(whole)\(suffix)"
        }
        return "\(whole).\(fraction)\(suffix)"
    }
}
