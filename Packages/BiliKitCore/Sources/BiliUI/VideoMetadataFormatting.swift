import Foundation

/// 视频卡片、投稿行、相关推荐、播放页详情与评论共用的计数和发布日期文字。
///
/// 只拥有格式与对应文案；用到哪些字段、如何拼进卡片由各 Feature 的 presentation 决定。`locale` 默认取
/// `InterfaceLocale.current`，与文案同一种语言。
package enum VideoMetadataFormatting {
    /// “12万播放”：播放数与单位文字的本地化组合。
    package static func viewCountText(
        _ count: Int64,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        viewCountText(compactText: compactCount(count, locale: locale), locale: locale)
    }

    /// 已经算好紧凑计数（如卡片封面上的“12万”）时直接组合，不再重复格式化。
    package static func viewCountText(
        compactText: String,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        BiliUIStrings.localized("\(compactText)播放", locale: locale)
    }

    /// “3000弹幕”：弹幕数与单位文字的本地化组合。
    package static func danmakuCountText(
        _ count: Int64,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        danmakuCountText(compactText: compactCount(count, locale: locale), locale: locale)
    }

    package static func danmakuCountText(
        compactText: String,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        BiliUIStrings.localized("\(compactText)弹幕", locale: locale)
    }

    /// 紧凑计数：系统按语言给单位（万／萬／億、K／M／B），最多一位小数且向下截断，负数按 0。
    ///
    /// 截断是 B 站的惯例：默认的紧凑格式四舍五入、只留两位有效数字，99,999 会显示成「10万」、123,456 成「12万」。
    package static func compactCount(
        _ count: Int64,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        max(0, count).formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .rounded(rule: .down)
                .locale(locale)
        )
    }

    /// 发布时间：规则见 `DateDisplayFormatting.relativeDate`，昨天不带时刻。
    package static func publishedDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        DateDisplayFormatting.relativeDate(
            date,
            relativeTo: now,
            yesterdayIncludesTime: false,
            calendar: calendar,
            locale: locale
        )
    }

    /// 评论时间：与发布时间同一规则，昨天带时刻（「昨天 12:30」），在一天里看得出先后。
    package static func commentDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        DateDisplayFormatting.relativeDate(
            date,
            relativeTo: now,
            yesterdayIncludesTime: true,
            calendar: calendar,
            locale: locale
        )
    }

    /// 播放页详情里的完整发布时间（日期与时分秒）。
    package static func fullPublishedDate(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        DateDisplayFormatting.formatted(
            date,
            date: .long,
            time: .standard,
            calendar: calendar,
            locale: locale
        )
    }
}
