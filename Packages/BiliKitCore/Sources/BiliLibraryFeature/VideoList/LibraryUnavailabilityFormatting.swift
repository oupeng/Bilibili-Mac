import BiliModels
import Foundation

/// 资料库不可用卡片（稍后再看）共用的文字：不可用原因的角标与缺标题时的占位标题，只在这里。
enum LibraryUnavailabilityFormatting {
    /// 番剧与影视用接口给的分类原文（如“电影”），没有分类时写“番剧”；课程写“课程”；失效写“已失效”。
    static func reason(
        _ unavailability: LibraryItemUnavailability,
        locale: Locale = .current
    ) -> String {
        switch unavailability {
        case .pgc(let label):
            label ?? LibraryFeatureStrings.localized("番剧", locale: locale)
        case .course:
            LibraryFeatureStrings.localized("课程", locale: locale)
        case .invalid:
            LibraryFeatureStrings.localized("已失效", locale: locale)
        }
    }

    /// 不可用条目缺标题时的占位：失效写“已失效视频”，其余写“无标题视频”。
    ///
    /// 可播放条目总有标题。
    static func placeholderTitle(
        _ unavailability: LibraryItemUnavailability?,
        locale: Locale = .current
    ) -> String {
        switch unavailability {
        case .invalid:
            LibraryFeatureStrings.localized("已失效视频", locale: locale)
        case .pgc, .course, nil:
            LibraryFeatureStrings.localized("无标题视频", locale: locale)
        }
    }
}
