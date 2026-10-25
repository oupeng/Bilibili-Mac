import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation

/// 稍后再看卡片的已格式化文字、缩略图地址、可用性与读屏标签，由列表网格映射为原生卡片（`nativeCard`）。
///
/// 封面右下角：看完显示“已看完”，看过一部分显示进度，否则显示时长；页脚左侧 UP 主名、右侧加入时间。
/// 番剧／影视、课程与已失效的条目是不可用卡片，角标与读屏标签写出原因。不可用条目缺的字段由卡片省略：没有标题
/// 时用占位标题，没有作者时不显示头像与作者名，没有加入时间或时长时不显示对应文字，读屏也不读空的部分。作者没有
/// 头像地址时不显示头像位。
public struct WatchLaterCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let coverTrailingText: String?
    public let footerLeadingText: String
    public let footerTrailingText: String?
    /// 不可用的原因（角标文字）；可以播放时为 nil。
    public let unavailableReason: String?
    public let accessibilityLabel: String

    public init(item: WatchLaterItem, locale: Locale = InterfaceLocale.current) {
        let addedAt = item.addedAt.map { LibraryCardFormatting.timestamp($0, locale: locale) }
        let reason = item.unavailability.map {
            LibraryUnavailabilityFormatting.reason($0, locale: locale)
        }
        let title =
            item.title
            ?? LibraryUnavailabilityFormatting.placeholderTitle(item.unavailability, locale: locale)
        let coverText: String?
        let spokenProgress: String?
        switch (item.progress, item.durationSeconds) {
        case (.finished, _):
            coverText = LibraryCardFormatting.finished(locale: locale)
            spokenProgress = coverText
        case (.watched(let seconds), .some(let duration)):
            let progress = LibraryCardFormatting.progress(
                progressSeconds: seconds,
                durationSeconds: duration,
                locale: locale
            )
            coverText = progress
            spokenProgress = LibraryFeatureStrings.localized("观看进度 \(progress)", locale: locale)
        case (.notStarted, .some(let duration)):
            let text = VideoDurationFormatting.string(seconds: max(0, duration), locale: locale)
            coverText = text
            spokenProgress = VideoCardAccessibilityText.duration(text, locale: locale)
        case (.watched, nil), (.notStarted, nil):
            coverText = nil
            spokenProgress = nil
        }
        bvid = item.bvid
        self.title = title
        coverURL = BiliImageThumbnail.url(item.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(item.owner?.avatarURL, size: .avatar)
        showsAvatar = item.owner?.avatarURL != nil
        coverTrailingText = coverText
        footerLeadingText = item.owner?.name ?? ""
        footerTrailingText = addedAt
        unavailableReason = reason
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                title,
                reason,
                item.owner?.name,
                spokenProgress,
                addedAt.map { LibraryFeatureStrings.localized("加入于 \($0)", locale: locale) }
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
