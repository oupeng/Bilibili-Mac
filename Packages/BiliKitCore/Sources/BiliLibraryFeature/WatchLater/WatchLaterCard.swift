import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation

/// 稍后再看卡片的已格式化文字、缩略图地址、可用性与读屏标签，由列表网格映射为原生卡片（`nativeCard`）。
///
/// 封面右下角：看完显示“已看完”，看过一部分显示进度，否则显示时长；页脚左侧 UP 主名、右侧加入时间。
/// 番剧／影视、课程与已失效的条目是不可用卡片，角标与读屏标签写出原因。作者没有头像地址时不显示头像位。
public struct WatchLaterCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let coverTrailingText: String
    public let footerLeadingText: String
    public let footerTrailingText: String
    /// 不可用的原因（角标文字）；可以播放时为 nil。
    public let unavailableReason: String?
    public let accessibilityLabel: String

    public init(item: WatchLaterItem, locale: Locale = .current) {
        let addedAt = LibraryCardFormatting.timestamp(item.addedAt, locale: locale)
        let reason = item.unavailability.map {
            WatchLaterCardFormatting.reason($0, locale: locale)
        }
        let coverText: String
        let spokenProgress: String
        switch item.progress {
        case .finished:
            coverText = LibraryCardFormatting.finished(locale: locale)
            spokenProgress = coverText
        case .watched(let seconds):
            coverText = LibraryCardFormatting.progress(
                progressSeconds: seconds,
                durationSeconds: item.durationSeconds,
                locale: locale
            )
            spokenProgress = LibraryFeatureStrings.localized("观看进度 \(coverText)", locale: locale)
        case .notStarted:
            coverText = VideoDurationFormatting.string(
                seconds: max(0, item.durationSeconds),
                locale: locale
            )
            spokenProgress = LibraryFeatureStrings.localized("时长 \(coverText)", locale: locale)
        }
        bvid = item.bvid
        title = item.title
        coverURL = BiliImageThumbnail.url(item.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(item.owner.avatarURL, size: .avatar)
        showsAvatar = item.owner.avatarURL != nil
        coverTrailingText = coverText
        footerLeadingText = item.owner.name
        footerTrailingText = addedAt
        unavailableReason = reason
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                item.title,
                reason,
                item.owner.name,
                spokenProgress,
                LibraryFeatureStrings.localized("加入于 \(addedAt)", locale: locale)
            ].compactMap(\.self)
        )
    }

    var nativeCard: NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: bvid,
            title: title,
            coverURL: coverURL,
            avatarURL: avatarURL,
            showsAvatar: showsAvatar,
            coverTrailingText: coverTrailingText,
            footerLeadingText: footerLeadingText,
            footerTrailingText: footerTrailingText,
            accessibilityLabel: accessibilityLabel,
            availability: unavailableReason.map { .unavailable(badge: $0) } ?? .available
        )
    }
}

/// 稍后再看卡片特有的文字规则：不可用原因的角标文字。
enum WatchLaterCardFormatting {
    /// 番剧与影视用接口给的分类原文（如“电影”），没有分类时写“番剧”；课程写“课程”；失效写“已失效”。
    static func reason(
        _ unavailability: WatchLaterUnavailability,
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
}
